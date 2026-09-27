-- Access-rule test. Creates fake people and tools, checks what each can see and do,
-- then aborts on purpose so everything is rolled back. The results appear as the error message.
begin;
create temp table t_res(n serial, test text, expected text, actual text);
grant all on t_res to authenticated;
grant usage on sequence t_res_n_seq to authenticated;

create or replace function pg_temp.as_user(uid uuid) returns void language plpgsql as $f$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
  execute 'set local role authenticated';
end $f$;
create or replace function pg_temp.as_admin() returns void language plpgsql as $f$
begin execute 'reset role'; end $f$;

do $t$
declare
  o uuid := gen_random_uuid(); m uuid := gen_random_uuid(); s uuid := gen_random_uuid();
  s2 uuid := gen_random_uuid(); x uuid := gen_random_uuid();
  sales uuid; ops uuid; c_sales uuid; c_ops uuid; c_secret uuid;
  t1 uuid; t2 uuid; t3 uuid; t4 uuid; n int; ok text;
begin
  -- setup as database admin
  insert into teams(name) values ('T-Sales') returning id into sales;
  insert into teams(name) values ('T-Ops') returning id into ops;
  insert into invites(email, role, team_id) values
    ('mgr@test.local','manager',sales), ('staff@test.local','staff',sales), ('staff2@test.local','staff',ops);
  insert into auth.users(id, email, aud, role, raw_user_meta_data) values
    (o,  owner_email(),       'authenticated','authenticated','{}'),
    (m,  'mgr@test.local',    'authenticated','authenticated','{}'),
    (s,  'staff@test.local',  'authenticated','authenticated','{}'),
    (s2, 'staff2@test.local', 'authenticated','authenticated','{}'),
    (x,  'stranger@test.local','authenticated','authenticated','{}');
  insert into categories(name) values ('C-Sales') returning id into c_sales;
  insert into categories(name) values ('C-Ops') returning id into c_ops;
  insert into categories(name) values ('C-Secret') returning id into c_secret;
  insert into tools(name,url,category_id) values ('Sales tool','https://a.test',c_sales) returning id into t1;
  insert into tools(name,url,category_id) values ('Ops tool','https://b.test',c_ops) returning id into t2;
  insert into tools(name,url,category_id) values ('Secret tool','https://c.test',c_secret) returning id into t3;
  insert into tools(name,url,category_id) values ('Secret shared','https://d.test',c_secret) returning id into t4;
  insert into grants(team_id,category_id) values (sales,c_sales),(ops,c_ops);
  insert into grants(user_id,tool_id) values (s2,t4);

  insert into t_res(test,expected,actual) select 'sign-up roles', 'owner/manager/staff/staff/staff(pending)',
    (select string_agg(role||case when status<>'active' then '('||status||')' else '' end, '/' order by case id when o then 1 when m then 2 when s then 3 when s2 then 4 else 5 end) from profiles);
  insert into t_res(test,expected,actual) select 'invites used up', '0', (select count(*)::text from invites);

  -- visibility
  perform pg_temp.as_user(o);  select count(*) into n from tools; insert into t_res(test,expected,actual) values ('owner sees tools','4',n);
  perform pg_temp.as_user(m);  select count(*) into n from tools; insert into t_res(test,expected,actual) values ('sales manager sees tools','1',n);
  perform pg_temp.as_user(s);  select count(*) into n from tools; insert into t_res(test,expected,actual) values ('sales staff sees tools','1',n);
  perform pg_temp.as_user(s2); select count(*) into n from tools; insert into t_res(test,expected,actual) values ('ops staff + 1 shared tool','2',n);
  perform pg_temp.as_user(s2); select count(*) into n from categories; insert into t_res(test,expected,actual) values ('ops staff sees categories','2',n);
  perform pg_temp.as_user(x);  select count(*) into n from tools; insert into t_res(test,expected,actual) values ('uninvited sees tools','0',n);
  perform pg_temp.as_user(s);  select count(*) into n from profiles; insert into t_res(test,expected,actual) values ('staff sees people','1',n);
  perform pg_temp.as_user(m);  select count(*) into n from profiles; insert into t_res(test,expected,actual) values ('manager sees people','2',n);
  perform pg_temp.as_user(s);  select count(*) into n from teams; insert into t_res(test,expected,actual) values ('staff sees teams','1',n);

  -- manager powers
  perform pg_temp.as_user(m);
  begin insert into tools(name,url,category_id) values ('Mgr new','https://e.test',c_sales); ok:='allowed';
  exception when others then ok:='blocked'; end;
  insert into t_res(test,expected,actual) values ('manager adds tool in own category','allowed',ok);
  begin insert into tools(name,url,category_id) values ('Mgr bad','https://f.test',c_ops); ok:='allowed';
  exception when others then ok:='blocked'; end;
  insert into t_res(test,expected,actual) values ('manager adds tool in other category','blocked',ok);
  begin insert into grants(user_id,tool_id) values (s2,t1); ok:='allowed';
  exception when others then ok:='blocked'; end;
  insert into t_res(test,expected,actual) values ('manager shares tool outside team','blocked',ok);
  begin insert into grants(team_id,category_id) values (sales,c_secret); ok:='allowed';
  exception when others then ok:='blocked'; end;
  insert into t_res(test,expected,actual) values ('manager grants category','blocked',ok);
  begin update profiles set role='owner' where id=s; get diagnostics n = row_count; ok:=case when n>0 then 'allowed' else 'blocked' end;
  exception when others then ok:='blocked'; end;
  insert into t_res(test,expected,actual) values ('manager promotes staff','blocked',ok);

  -- staff limits
  perform pg_temp.as_user(s);
  begin insert into tools(name,url,category_id) values ('Staff new','https://g.test',c_sales); ok:='allowed';
  exception when others then ok:='blocked'; end;
  insert into t_res(test,expected,actual) values ('staff adds tool','blocked',ok);
  begin update profiles set role='owner', status='active' where id=s; ok:='allowed';
  exception when others then ok:='blocked'; end;
  insert into t_res(test,expected,actual) values ('staff promotes self','blocked',ok);
  begin insert into pins(user_id,tool_id) values (s,t1); ok:='allowed';
  exception when others then ok:='blocked'; end;
  insert into t_res(test,expected,actual) values ('staff pins own tool','allowed',ok);
  begin insert into pins(user_id,tool_id) values (s,t3); ok:='allowed';
  exception when others then ok:='blocked'; end;
  insert into t_res(test,expected,actual) values ('staff pins hidden tool','blocked',ok);
  begin insert into grants(user_id,tool_id) values (s,t3); ok:='allowed';
  exception when others then ok:='blocked'; end;
  insert into t_res(test,expected,actual) values ('staff grants self access','blocked',ok);

  -- owner suspends staff
  perform pg_temp.as_user(o);
  update profiles set status='suspended' where id=s;
  perform pg_temp.as_user(s); select count(*) into n from tools; insert into t_res(test,expected,actual) values ('suspended staff sees tools','0',n);
  perform pg_temp.as_user(o);
  begin update profiles set role='staff' where id=o; ok:='allowed';
  exception when others then ok:='blocked'; end;
  insert into t_res(test,expected,actual) values ('owner role removable','blocked',ok);
  perform pg_temp.as_admin();
end $t$;

do $r$
declare msg text;
begin
  select 'RESULTS ' || count(*) filter (where expected=actual) || '/' || count(*) || ' passed. ' ||
         coalesce(string_agg(case when expected<>actual then 'FAIL: '||test||' expected '||expected||' got '||actual end, ' | '), '')
    into msg from t_res;
  raise exception '%', msg;   -- aborts on purpose: rolls back every test row
end $r$;

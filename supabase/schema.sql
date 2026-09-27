-- NegoTrip HQ — members & access control
-- Run once in the Supabase SQL editor (or via migration).
--
-- Model
--   profiles      one row per signed-in person (role: owner | manager | staff)
--   invites       emails allowed to join, with their starting role and team
--   teams         e.g. Sales, Operations
--   team_members  who is in which team; is_manager marks the team's manager(s)
--   categories    launcher sections
--   tools         launcher tiles
--   grants        who can see what: (team OR person) × (category OR tool)
--   pins          each person's own pinned tools
--   tool_opens    activity log (phase 4)
--
-- Rules
--   • Nothing is visible by default. Staff see only tools granted to them or their team.
--   • Only the owner manages members, teams, categories and team-level grants.
--   • A manager may add/edit tools inside categories granted to a team they manage,
--     and may give or remove single-tool access for people in that team.
--   • Suspended or uninvited people see nothing.

create extension if not exists pgcrypto;

-- The owner's Google account. The first sign-in with this email becomes owner.
create or replace function public.owner_email() returns text
language sql immutable as $$ select 'kn0733@gmail.com'::text $$;

-- ---------- tables ----------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null unique,
  name        text,
  role        text not null default 'staff' check (role in ('owner','manager','staff')),
  status      text not null default 'pending' check (status in ('active','suspended','pending')),
  created_at  timestamptz not null default now(),
  last_seen   timestamptz
);

create table public.teams (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (char_length(name) between 1 and 40),
  created_at  timestamptz not null default now()
);

create table public.invites (
  email       text primary key check (email = lower(email)),
  role        text not null default 'staff' check (role in ('manager','staff')),
  team_id     uuid references public.teams(id) on delete set null,
  invited_at  timestamptz not null default now()
);

create table public.team_members (
  team_id     uuid not null references public.teams(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  is_manager  boolean not null default false,
  primary key (team_id, user_id)
);

create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (char_length(name) between 1 and 40),
  color       smallint not null default 0 check (color between 0 and 9),
  sort_order  double precision not null default extract(epoch from now()),
  created_at  timestamptz not null default now()
);

create table public.tools (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 60),
  url         text not null check (url ~* '^https?://'),
  note        text check (char_length(note) <= 90),
  category_id uuid references public.categories(id) on delete set null,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

create table public.grants (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid references public.teams(id) on delete cascade,
  user_id     uuid references public.profiles(id) on delete cascade,
  category_id uuid references public.categories(id) on delete cascade,
  tool_id     uuid references public.tools(id) on delete cascade,
  granted_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  check ((team_id is null) <> (user_id is null)),          -- exactly one subject
  check ((category_id is null) <> (tool_id is null))       -- exactly one object
);
create unique index grants_unique on public.grants
  (coalesce(team_id, user_id), coalesce(category_id, tool_id));

create table public.pins (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  tool_id     uuid not null references public.tools(id) on delete cascade,
  primary key (user_id, tool_id)
);

create table public.tool_opens (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  tool_id     uuid not null references public.tools(id) on delete cascade,
  opened_at   timestamptz not null default now()
);

-- ---------- helper functions (run with definer rights so policies can use them) ----------
create or replace function public.is_active() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and status = 'active')
$$;

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'owner' and status = 'active')
$$;

-- Teams the current person manages
create or replace function public.managed_teams() returns setof uuid
language sql stable security definer set search_path = public as $$
  select tm.team_id from team_members tm
  join profiles p on p.id = tm.user_id
  where tm.user_id = auth.uid() and tm.is_manager and p.status = 'active'
$$;

-- Categories a manager may add/edit tools in
create or replace function public.manages_category(cat uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from grants g where g.category_id = cat and g.team_id in (select managed_teams()))
$$;

create or replace function public.can_see_tool(t uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_owner() or (is_active() and exists (
    select 1 from tools tl
    join grants g on (g.tool_id = tl.id or (tl.category_id is not null and g.category_id = tl.category_id))
    where tl.id = t
      and (g.user_id = auth.uid()
           or g.team_id in (select team_id from team_members where user_id = auth.uid()))
  ))
$$;

create or replace function public.can_see_category(cat uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_owner() or (is_active() and (
    exists (select 1 from grants g where g.category_id = cat
            and (g.user_id = auth.uid() or g.team_id in (select team_id from team_members where user_id = auth.uid())))
    or exists (select 1 from tools tl where tl.category_id = cat and can_see_tool(tl.id))
  ))
$$;

-- ---------- sign-up: create the profile, apply the invite ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv invites%rowtype; em text := lower(new.email);
begin
  if em = owner_email() then
    insert into profiles (id, email, name, role, status)
    values (new.id, em, new.raw_user_meta_data->>'full_name', 'owner', 'active');
    return new;
  end if;
  select * into inv from invites where email = em;
  if found then
    insert into profiles (id, email, name, role, status)
    values (new.id, em, new.raw_user_meta_data->>'full_name', inv.role, 'active');
    if inv.team_id is not null then
      insert into team_members (team_id, user_id, is_manager)
      values (inv.team_id, new.id, inv.role = 'manager');
    end if;
    delete from invites where email = em;
  else
    -- Not invited: recorded as pending, sees nothing until the owner approves.
    insert into profiles (id, email, name, status)
    values (new.id, em, new.raw_user_meta_data->>'full_name', 'pending');
  end if;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

-- People may not change their own role or status
create or replace function public.guard_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not is_owner() and (new.role <> old.role or new.status <> old.status or new.email <> old.email) then
    raise exception 'Only the owner can change roles or status';
  end if;
  if old.role = 'owner' and new.role <> 'owner' then
    raise exception 'The owner role cannot be removed';
  end if;
  return new;
end $$;
create trigger profiles_guard before update on public.profiles
for each row execute function public.guard_profile();

-- ---------- row level security ----------
alter table public.profiles     enable row level security;
alter table public.invites      enable row level security;
alter table public.teams        enable row level security;
alter table public.team_members enable row level security;
alter table public.categories   enable row level security;
alter table public.tools        enable row level security;
alter table public.grants       enable row level security;
alter table public.pins         enable row level security;
alter table public.tool_opens   enable row level security;

-- profiles
create policy "see self, owner sees all, managers see their team"
  on public.profiles for select using (
    id = auth.uid() or is_owner()
    or id in (select user_id from team_members where team_id in (select managed_teams()))
  );
create policy "update self name; owner updates anyone"
  on public.profiles for update using (id = auth.uid() or is_owner());
create policy "owner removes people"
  on public.profiles for delete using (is_owner() and role <> 'owner');

-- invites, teams, team membership: owner manages; members read their own teams
create policy "owner manages invites" on public.invites for all using (is_owner()) with check (is_owner());
create policy "read own teams" on public.teams for select using (
  is_owner() or id in (select team_id from team_members where user_id = auth.uid()));
create policy "owner manages teams" on public.teams for all using (is_owner()) with check (is_owner());
create policy "read own team rosters" on public.team_members for select using (
  is_owner() or user_id = auth.uid() or team_id in (select managed_teams()));
create policy "owner manages membership" on public.team_members for all using (is_owner()) with check (is_owner());

-- categories
create policy "see permitted categories" on public.categories for select using (can_see_category(id));
create policy "owner manages categories" on public.categories for all using (is_owner()) with check (is_owner());

-- tools
create policy "see permitted tools" on public.tools for select using (can_see_tool(id));
create policy "owner or category manager adds tools" on public.tools for insert with check (
  is_owner() or (category_id is not null and manages_category(category_id)));
create policy "owner or category manager edits tools" on public.tools for update
  using (is_owner() or (category_id is not null and manages_category(category_id)))
  with check (is_owner() or (category_id is not null and manages_category(category_id)));
create policy "owner or category manager deletes tools" on public.tools for delete using (
  is_owner() or (category_id is not null and manages_category(category_id)));

-- grants
create policy "see own grants; managers see their team's; owner sees all" on public.grants for select using (
  is_owner() or user_id = auth.uid()
  or team_id in (select team_id from team_members where user_id = auth.uid())
  or user_id in (select user_id from team_members where team_id in (select managed_teams())));
create policy "owner manages all grants" on public.grants for all using (is_owner()) with check (is_owner());
create policy "manager gives single tools to own team members" on public.grants for insert with check (
  user_id in (select user_id from team_members where team_id in (select managed_teams()))
  and tool_id is not null
  and exists (select 1 from tools t where t.id = tool_id and t.category_id is not null and manages_category(t.category_id)));
create policy "manager removes single-tool grants they could give" on public.grants for delete using (
  user_id in (select user_id from team_members where team_id in (select managed_teams()))
  and tool_id is not null
  and exists (select 1 from tools t where t.id = tool_id and t.category_id is not null and manages_category(t.category_id)));

-- pins: each person's own, only on tools they can see
create policy "own pins" on public.pins for select using (user_id = auth.uid());
create policy "pin visible tools" on public.pins for insert with check (user_id = auth.uid() and can_see_tool(tool_id));
create policy "unpin" on public.pins for delete using (user_id = auth.uid());

-- activity log: people log their own opens; owner reads all, managers read their team's
create policy "log own opens" on public.tool_opens for insert with check (user_id = auth.uid() and can_see_tool(tool_id));
create policy "read activity" on public.tool_opens for select using (
  is_owner() or user_id = auth.uid()
  or user_id in (select user_id from team_members where team_id in (select managed_teams())));

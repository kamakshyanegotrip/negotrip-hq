# NegoTrip HQ

One launcher for all NegoTrip tools. Works on a computer and installs on a phone like an app.

**Live page:** https://kamakshyanegotrip.github.io/negotrip-hq/

## Who can do what

| Role | Can do |
| --- | --- |
| **Owner** (kn0733@gmail.com) | Everything: tools, categories, people, teams, access |
| **Manager** | Add and edit tools in the categories their team has; share single tools with people in their team; see their team's activity |
| **Staff** | Open and pin only the tools they've been given |

Nothing is visible by default. People who sign in without an invite wait as "pending" and see nothing until the owner approves them. Access rules are enforced by the database (Supabase row-level security), not by the page.

## Everyday tasks (owner)

- **Invite someone:** People → + Invite. Enter their Google email, role and team, then send them the live link.
- **Make a team:** People → + Team. Tick members and pick who manages it.
- **Give a team a category:** Access → tick the box where the team's row meets the category's column.
- **Share one extra tool:** open the tool's ⋯ menu → "Also share this one tool with".
- **Someone leaves:** People → their name → Pause access. Then remove them inside each tool too; pausing only hides the links.

## Install on your phone

- **Android (Chrome):** open the live page, tap ⋮ → **Install app** or **Add to Home screen**.
- **iPhone (Safari):** open the live page, tap Share → **Add to Home Screen**.

## Technical notes

- Hosting: GitHub Pages (this repository, `main` branch).
- Sign-in and data: Supabase project `negotrip-hq` (Mumbai), in the NegoTrip organization. Google sign-in uses the "NegoTrip HQ" client in Google Cloud project `negotripin`.
- `supabase/schema.sql` holds the tables and access rules. `supabase/test_access.sql` runs 23 permission checks and rolls itself back.
- The key in `index.html` is Supabase's public browser key; it is safe to publish because the database rules decide what each person can read or change.

| File | Purpose |
| --- | --- |
| `index.html` | The whole app |
| `manifest.webmanifest` | Name, colours and icons for installing on a phone |
| `sw.js` | Lets the app open without internet |
| `icon.svg`, `icon-192.png`, `icon-512.png` | App icons |
| `supabase/` | Database design and tests |
| `shorts-studio/` | Shorts Studio: AI travel Shorts made in the browser. Uses the HQ sign-in; the backend is the "Shorts Studio API" and "Destination Shorts Engine" workflows in n8n. Access = owner, or anyone who can see a tool whose link contains `shorts-studio`. |

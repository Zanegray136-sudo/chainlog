# ChainLog — chain motor inspections & maintenance

Scan a motor's QR sticker → see whether it's cleared for use → inspect, load test, log faults and repairs.

## What it does
- **Periodic inspections** (every 6 months by default) with a pass / fail / N/A checklist and a **chain wear** gauge measurement checked against the motor's wear limit.
- **Load tests** (every 12 months) with test load and results.
- A failed inspection **automatically tags the motor Out of service**.
- **Cleared for use** banner on every motor; dashboard and Inspections page flag anything overdue or with no inspection on record.
- Faults, repairs, notes and photos per motor; **spare parts** with check-outs to people and motors and an order list.
- **Inspection register** export (CSV / print), motor list, due list, team log-ins, works offline.

Change the intervals or the checklist in `config.js`.

## Setup
The database is already set up (Supabase project "ChainLog"). In Supabase:
1. Authentication → Sign In / Providers → Email: turn **Confirm email** off.
2. Authentication → URL Configuration → **Site URL** = `https://zanegray136-sudo.github.io/chainlog/`

Then open the site and **Create account** — the first account becomes Admin. Approve the team on the Team page.

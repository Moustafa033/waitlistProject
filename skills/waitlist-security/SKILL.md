---
name: waitlist-security
description: Security rules and tested reference code for the Brand AI waitlist website (static site, Turnstile, Supabase Edge Function, double opt-in email). Use for ANY change to the site, the waitlist functions, the database, email sending, DNS or the export.
---

# Waitlist security skill

1. Read `AGENTS.md` (owner policies W-1..W-10 + hard rules). They override anything else you think is better.
2. Open the matching section of `docs/WAITLIST_SECURITY_GUIDE.md`:
   - page / JS / CSS / headers → §2 A-1, §3, §9 W14–W16, W28, W31
   - signup / confirm / unsubscribe endpoints → §3.1–3.4
   - database, limits, retention → §4
   - email sending, launch, deliverability → §5, §11 "Launch-day send"
   - domain, DNS, hosting → §6
   - keys and secrets → §7
   - privacy / consent text → §8
   - anything you want to add (referrals, analytics, SSR, IP limits) → §10 first: it is probably deliberately not done
3. Reuse the reference code instead of writing new security logic:
   `_shared/validate.ts` (email), `_shared/turnstile.ts`, `_shared/http.ts` (origin, body cap, keys),
   `_shared/mailer.ts` (confirmation + launch mails, RFC 8058), `_shared/svix.ts` (webhooks), `_shared/csv.ts` (export).
4. Every change: add or extend a test (SQL in `tests/`, race in `tests/race_parallel.sh`, Deno in
   `supabase/functions/tests/`, browser in `e2e/`), then run the "Done means" commands from AGENTS.md.
5. Before you finish, walk the red-team list (§12) for the part you touched and say in your summary which items you checked.
6. Numbers are examples; never raise a limit, TTL or retention period without the owner.

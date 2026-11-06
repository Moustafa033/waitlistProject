# AGENTS.md — Brand AI waitlist website

You are working on the **public waitlist page** of Brand AI: a static site that collects email
addresses with double opt-in. Security matters more than speed. Read
`docs/WAITLIST_SECURITY_GUIDE.md` (the full spec) — at least the section for your task — before coding.

## Owner policies (locked — never change them yourself)
- W-1 No IP-based rules, no IP stored, no `remoteip` to Turnstile.
- W-2 Identity = exact email lower+trim. Never fold dots or `+tags` (different people).
- W-3 Double opt-in. Only `confirmed` rows are exported or emailed for launch.
- W-4 Minimum age 16 (required checkbox).
- W-5 Consent: explicit, unticked by default, versioned; no consent = no row.
- W-6 The product says it is AI ("Brand AI").
- W-7 Separate Supabase project for the waitlist.
- W-8 Email only, no phone/SMS.
- W-9 Collect the minimum: email, locale, optional source, consent version. No trackers.
- W-10 You never touch production, never see secret keys, never connect a Supabase MCP to production.
- All numbers (limits, TTLs, retention) are EXAMPLES. Change them only in `private.settings`, and only when the owner says.

## Hard rules for code
1. The site is static files only. No SSR, no middleware, no server actions, no npm runtime deps.
2. No inline `<script>`, inline style or `on*=` handlers; output with `textContent` only; CSP in `site/_headers` stays strict (no `unsafe-*`, no wildcards). Only Turnstile may be loaded from a third party.
3. Nothing secret in `site/`. Only the function URL and the Turnstile *site* key are public.
4. The browser never calls the database. All access goes through `public.waitlist_*` RPCs, EXECUTE for `service_role` only, SECURITY DEFINER with `set search_path = ''`. Tables stay in `private` with RLS enabled and forced, no grants.
5. Limits are enforced by the database with single-statement atomic counters, never by the function or the browser.
6. Signup always returns the same 202 body; the email is sent in the background. Never reveal whether an address exists.
7. Confirm and unsubscribe never change state on GET. No auto-submit on page load. Tokens travel in the URL fragment.
8. Turnstile is verified server-side once per token, with hostname AND action checks, failing closed.
9. Validate email with the strict ASCII rule (TS and SQL); refuse control/zero-width/bidi chars, never "clean" them.
10. `verify_jwt = false` only for `waitlist` and `email-events`. CORS: one exact origin, never `*`, never reflected.
11. Logs: function name, status, reason code. Never emails, tokens, keys, bodies, IPs, user agents.
12. Bulk emails carry RFC 8058 `List-Unsubscribe` + `List-Unsubscribe-Post` and a visible link; send only to `waitlist_export_confirmed()`.
13. Exports a human opens go through `toCsv()` (formula-injection safe).
14. You may improve the reference code; you may not weaken it. Never edit a test just to make it pass.
15. If something here seems wrong, or you find a new attack/rule online, stop and tell the owner with the source.

## Done means
`bash ci/check-site.sh site && bash ci/check-functions.sh supabase && bash ci/check-migrations.sh supabase/migrations && deno test supabase/functions/tests && bash tests/run_all.sh` — and `bash e2e/run.sh` for site or flow changes. New behavior needs a new test.

# Brand AI — waitlist website security pack

Tested reference implementation + guide for a pre-launch page that only collects emails.

| Path | What |
|---|---|
| `docs/WAITLIST_SECURITY_GUIDE.md` | the full spec for the coding models (start here) |
| `AGENTS.md`, `CLAUDE.md` | rules loaded automatically by Codex / Claude Code |
| `skills/waitlist-security/SKILL.md` | move to `.claude/skills/waitlist-security/SKILL.md` |
| `site/` | static page (Cloudflare Pages): signup, confirm, unsubscribe, privacy, `_headers` CSP |
| `supabase/migrations/0001_waitlist.sql` | the whole database side (separate project) |
| `supabase/functions/waitlist/` | the one public endpoint (signup / confirm / unsubscribe / count) |
| `supabase/functions/email-events/` | signed bounce/complaint webhook → suppression |
| `supabase/config.toml` | `verify_jwt=false` only for those two functions |
| `tests/` | SQL attack tests + real concurrency races (Postgres 16) |
| `supabase/functions/tests/` | Deno unit/handler tests (no network) |
| `e2e/` | real Chrome: signup → email → scanner check → confirm → one-click unsubscribe → XSS/CSP |
| `ci/` | site / function / migration checks + GitHub workflow |

## Run the tests
```
bash tests/run_all.sh                 # needs Postgres on port 5433 (PGHOST/PGPORT to change)
deno test supabase/functions/tests
bash ci/check-site.sh site && bash ci/check-functions.sh supabase && bash ci/check-migrations.sh supabase/migrations
bash e2e/run.sh                       # also needs node + playwright + Chrome
```
Results when this pack was built (2026-11-06): 75 SQL checks + 5 race checks, 19 Deno tests,
12 browser checks, 3 CI checks — all passing.

## Owner setup (summary — details in the guide §11)
1. New Supabase project (spend cap ON). Run the migration. Insert two different 32+ char random
   values into `private.app_secrets` (`email_pepper`, `unsub_key`). Schedule `waitlist_maintenance()` daily.
2. `supabase secrets set SITE_ORIGIN=… WAITLIST_FUNCTION_URL=… TURNSTILE_SECRET=… TURNSTILE_HOSTNAMES=…
   RESEND_API_KEY=… MAIL_FROM=… MAIL_REPLY_TO=… CONSENT_VERSION=waitlist-v4 RESEND_WEBHOOK_SECRET=…`, deploy both functions.
   (`MAIL_REPLY_TO` = a real mailbox you read, e.g. your Hostinger address.)
3. Turnstile widget (free Cloudflare account; the domain does NOT move) for your domain only. Put the
   site key + function URL in `site/assets/config.js`, the project URL in the CSP `connect-src` of
   **both** `site/_headers` and `site/.htaccess`.
4. Email: sending subdomain, SPF/DKIM/DMARC, sending-only API key, webhook for bounced + complained.
5. Domain: registrar lock, MFA, DNSSEC, CAA, no dangling CNAMEs.
6. Finish `site/privacy.html`. Deploy:
   - **Hostinger:** set `YOUR-DOMAIN` in `site/.htaccess`, upload the *contents* of `site/` (including
     `.htaccess` and `.well-known/`) into `public_html/`, turn on hPanel "Force HTTPS", then check the
     headers at https://securityheaders.com and that `/confirm` opens the confirm page.
   - or **Cloudflare Pages:** deploy `site/` (uses `site/_headers`).

# Key and connection inventory — waitlist site (guide §7b)

**Names and places only. Never write a key, password or token value in this file.**
Review every quarter: revoke anything unused for 90 days; rotate when a tool or person stops using it.
If malware is suspected on your computer: from a clean device sign out everywhere, then rotate every row.

| Name | What it is | Stored in | Used by | Scope | Created | Last rotated | How to revoke / rotate |
|---|---|---|---|---|---|---|---|
| `RESEND_API_KEY` | send email | Supabase function secrets | `waitlist` function | sending only, one domain | | | Resend → API keys → revoke, create new, `supabase secrets set` |
| `RESEND_WEBHOOK_SECRET` | verify bounce/complaint webhooks | Supabase function secrets | `email-events` | — | | | Resend → Webhooks → rotate secret |
| `TURNSTILE_SECRET` | verify the captcha | Supabase function secrets | `waitlist` | one widget | | | Cloudflare → Turnstile → rotate secret key |
| `CRON_SECRET` | unlocks `/drain` | Supabase function secrets **and** Vault `waitlist_cron_key` | pg_cron job | — | | | new random value in both places at once |
| `email_pepper` | keyed email hashes | `private.app_secrets` | SQL | — | | never (re-hashes everything) | only with a migration plan |
| `unsub_key` | unsubscribe links | `private.app_secrets` | SQL | — | | | invalidates every link already sent |
| Supabase access token (CLI) | deploy functions/migrations | your computer (CLI login) | you | whole account | | | Supabase → Account → Access tokens |
| GitHub tokens / OAuth apps | repo access | GitHub | | | | | GitHub → Settings → Applications / Tokens |
| Hostinger login | site hosting | password manager | you | | | | MFA on; review active sessions |
| Registrar login | domain + DNS | password manager | you | | | | MFA + registrar lock |
| Cloudflare API tokens | (if any) | | | | | | Cloudflare → API tokens |

# Waitlist Website — Security Guide (for the coding models)

Version 1 — 2026-11-06. Applies to the **waitlist / email-collection website** of Brand AI
(the public pre-launch page). The mobile app has its own guide (`C:\saigenai\docs\SECURITY_GUIDE.md`).

## 0. How to use this guide

- Read the section for your task **before** you write code. The reference code in this folder is
  **tested** (SQL tests, race tests, Deno unit tests, a real-browser end-to-end test). It is a
  **reference**: you may improve it, you may not weaken it.
- "Weaken" means: removing a check, widening a permission, making a limit bigger without the owner,
  turning on something listed in §10 "Deliberately not done", or changing a test so that it passes.
- **Every number is an EXAMPLE** (48h link, 3 emails per address, 500 emails/hour, 30-day retention…).
  The owner decides the real values. They live in `private.settings` — change them there, not in code.
- If a rule here looks wrong, illogical or outdated: **stop and tell the owner**. Do not "fix" it silently.
- If you find a new attack or a new official rule (Google, Yahoo, Microsoft, Supabase, Cloudflare,
  GDPR) that is not in this guide, report it to the owner with the source link.

## 1. Owner policies (locked)

| ID | Policy |
|----|--------|
| W-1 | **No IP-based rules.** No rate limit, block or score by IP. No IP stored. (Same as app policy P-1: one mobile IP can be thousands of people.) Do not send `remoteip` to Turnstile. |
| W-2 | **Identity = the exact email, lower-cased and trimmed.** `ahmed@x.com`, `a.hmed@x.com` and `ahmed+1@x.com` are three different people. Never fold dots or plus tags. (App P-2.) |
| W-3 | **Double opt-in.** Nobody is "on the list" until they press the Confirm button in our email. Only confirmed rows are ever exported or emailed for launch. |
| W-4 | **Minimum age 16** (checkbox, required). (App P-9.) |
| W-5 | **Consent is explicit, specific, unticked by default, versioned.** No consent → no row. (App P-10.) |
| W-6 | **The product says it is AI.** The page names "Brand AI" and states it is an AI product. (App P-11.) |
| W-7 | **Separate Supabase project** for the waitlist. It shares no keys, no database and no users with the app project. |
| W-8 | **No SMS / phone collection.** Email only. (App P-8.) |
| W-9 | **Collect the minimum:** email, locale, optional campaign source, consent version. No name, no phone, no trackers, no analytics cookies. |
| W-10 | Agents never touch the production project, never see the secret keys, never connect a Supabase MCP to production. (Same as the app.) |

## 2. Architecture

```
Visitor's browser
  │  static HTML/CSS/JS from Cloudflare Pages (no server code, no framework runtime)
  │  Turnstile widget (Cloudflare)
  ▼
Edge Function "waitlist"  (separate Supabase project, verify_jwt = false on purpose)
  │  exact-Origin check → body cap → strict schema → honeypot/time trap →
  │  consent+age → email validation → disposable check → Turnstile siteverify
  │  (hostname + action) → RPC
  ▼
Postgres (schema private, RLS forced, no table reachable by any API role)
  RPCs public.waitlist_* — EXECUTE granted to service_role only
  ▲
Edge Function "email-events"  ← signed webhooks from the email provider (bounces, complaints)

Email provider (Resend in the reference): sending-only API key, restricted to the sending subdomain.
```

**A-1 Static site, no framework server.** The site is plain files. There is no server-side
rendering, no middleware, no server actions. Reason: a waitlist does not need them, and they are a
large attack surface. In May 2026 alone, Next.js and React Server Components shipped a coordinated
release of 12–13 advisories (middleware/proxy bypass, SSRF, XSS with CSP nonces, cache poisoning,
DoS — e.g. CVE-2026-44574, CVE-2026-44575, CVE-2026-23870); earlier, CVE-2025-29927 (middleware
bypass) and CVE-2025-55182 (RSC RCE). A static page has none of these. If the owner later wants a
framework, use it in **static export** mode only, and keep the dependency patched.

**A-2 The browser never talks to the database.** The site contains only two public values: the
function URL and the Turnstile **site** key. No Supabase key at all — not even the publishable one.

**A-3 One public function, everything bounded.** `verify_jwt = false` is required (visitors have no
account). That means anyone on the internet can call it, so every request is cheap to refuse and
every expensive step (Turnstile call, DB, email) happens only after cheap checks pass. The **database**
enforces every limit (atomic counters), not the function.

**A-4 Separate project + spend cap ON.** A bug, a leaked key, or a flood here cannot affect app
users or app billing. Keep the Supabase **spend cap ON** for this organization: Edge Function
invocations are billed even when the function refuses the request in its first line ("denial of
wallet"). The spend cap does not cover compute — choose the smallest compute size.

**A-5 Cloudflare in front.** Cloudflare Pages serves the site. Optional: put a Cloudflare zone rate
rule in front of the function URL via a custom domain — but rate by **path**, never by IP (W-1); in
practice the global caps in the DB are the real protection.

## 3. Gateways — what each endpoint must do, in this order

### 3.1 `POST /signup` (browser only)
1. `Origin` must equal `SITE_ORIGIN` exactly → else 403. (Stops cross-site form posts. It is **not**
   bot protection: bots can fake headers. Turnstile is the bot gate.)
2. `Content-Type: application/json` → else 415. (A plain HTML form from another site cannot send JSON
   without a CORS preflight, which we deny.)
3. Body read with a hard cap (4 KB) **before** parsing.
4. Only known keys allowed (`email, consent, age_16_plus, consent_version, locale, source, website,
   elapsed_ms, turnstile`) → anything else 400. No mass assignment (`status: "confirmed"` is refused).
5. Bot traps: honeypot `website` filled, or `elapsed_ms` below the minimum → return the **normal
   202** and do nothing (do not teach the bot what failed).
6. `consent === true` and `age_16_plus === true` (literal booleans) → else 400.
7. `consent_version` must equal the server's `CONSENT_VERSION` → else 409 "reload page". This
   guarantees the stored version matches the text the person actually saw.
8. Email validation (§4.2) → 400 `invalid_email`. Disposable domain → 400 `use_another_email`.
9. Turnstile siteverify: exactly once per token, with `idempotency_key`, timeout 5s; require
   `success`, `hostname ∈ TURNSTILE_HOSTNAMES` and `action === "waitlist_signup"`. Network error →
   **503, fail closed** (never "let it through when Cloudflare is down").
10. RPC `waitlist_signup` → `{action:"send", token, …}` or `{action:"none", reason}`.
11. If `send`: the email is sent **in the background after the response** (`EdgeRuntime.waitUntil`),
    with `Idempotency-Key: confirm/<signup_id>/<send_no>`. Reason: if the response waited for the
    provider, a "new address" answer would be ~0.3 s slower than "already on the list" — a timing
    side channel that defeats the identical body. If the provider was
    **never reached** (network/timeout), call `waitlist_send_failed` to give the global unit back. If
    the provider answered with an error, do **not** refund (it may have sent).
12. Always the **same 202 body** `{"ok":true,"message":"check_inbox"}` for new / pending / confirmed /
    suppressed / rate-limited / bot. `reason` goes to logs only. (No email enumeration.)

### 3.2 `POST /confirm` (browser only, explicit button)
- The confirmation link is `https://<site>/confirm#t=<token>`. The token is in the **fragment**:
  browsers never send fragments to servers, so the token is not in any log, proxy, CDN or `Referer`.
- Opening the page changes nothing. Microsoft Safe Links, Proofpoint, Mimecast, Barracuda and
  similar scanners fetch every link and often run its JavaScript. So: **no confirm on GET, no
  auto-submit, no confirm on page load.** Only a person pressing the button sends the POST.
- The page removes the fragment from the address bar (`history.replaceState`) right away.
- The POST needs exact Origin + JSON + a Turnstile token with `action === "waitlist_confirm"` (a
  token solved on the signup widget is refused). Malformed token → `{ok:false}` with **no** outside
  call at all.
- `waitlist_confirm` is a single UPDATE … WHERE token_hash AND not expired AND pending → single use,
  race-safe (20 parallel clicks → exactly one confirmation, tested).

### 3.3 `POST /unsubscribe`
- **RFC 8058 one-click** (Gmail/Yahoo/Microsoft requirement for bulk mail): the mailbox provider POSTs
  `List-Unsubscribe=One-Click` (form-encoded) to the URL from the `List-Unsubscribe` header. No Origin,
  no login, no Turnstile, no confirmation page — it must just work.
- Our own page `/unsubscribe#id=…&t=…` uses the JSON path (needs Origin) behind a button.
- GET never unsubscribes (scanners again).
- Token = HMAC(signup_id, `unsub_key`) computed in SQL: stateless, works for every email we ever send,
  cannot be guessed, cannot be reused for another person. Unsubscribe is idempotent and honored
  immediately (the rules allow up to 2 days; we do it at once).

### 3.3b `POST /erase` — self-service "Delete my data" (migration 0003)
- Same signed personal link as unsubscribe (`/unsubscribe#id=…&t=…`, also included in the
  confirmation email). Button on our page only: exact Origin + JSON + known keys; **no** one-click /
  form path and never on GET, so mail providers and link scanners can never delete anyone.
- The page asks for a second click (deletion cannot be undone).
- `waitlist_erase_by_token` verifies the HMAC in SQL, deletes the row at once, keeps only the keyed
  hash in `suppressions` (never emailed again) and an anonymous `erased` consent event. Idempotent.

### 3.4 `GET /count` (optional)
- Rounded down to the nearest 10 so a watcher cannot detect one specific signup. `Cache-Control:
  public, max-age=300`. Delete the endpoint if the page does not show a counter.

### 3.5 `email-events` webhook
- Verify the Svix signature on the **raw** body before parsing; 5-minute replay window; accept
  rotated multi-signature headers; constant-time compare.
- `email.complained` → suppress. `email.bounced` → suppress only if permanent/hard (soft bounces are
  retried by the provider). Check the provider's current payload fields before go-live.

### 3.6 `POST /drain` — scheduled job only (migration 0005)
- Called every ~10 min by pg_cron + pg_net (setup in §11). Auth: header `x-cron-key` compared in
  constant time with the `CRON_SECRET` function secret (32+ chars, letters/digits/`-`/`_`).
  Missing secret, missing key or wrong key → **404, same as an unknown route** (invisible to scanners).
  No Origin, no CORS: no browser ever calls it.
- Runs `waitlist_drain_queue()` (same limits as a live signup, batch of `drain_batch`), sends each
  confirmation, gives units back if the provider is not reached and **stops trying the rest of the
  batch** after the first "not reached" (the run stays short).
- Then `waitlist_take_alerts()` and, if `ALERT_TO` is set, one email to the owner. The alert email
  is built only from fixed alert names and numbers: **never a visitor's address**.

## 4. Data model and rules

### 4.1 Tables (all in `private`, RLS enabled **and forced**, no policies, no grants)
- `signups` — one row per exact email. `status ∈ pending | confirmed | unsubscribed`. Stores only the
  **SHA-256 of the confirmation token**, its expiry, how many confirmation emails were sent, when.
- `consent_events` — append-only proof of consent (trigger blocks UPDATE/DELETE; the only allowed
  change is the FK being cut on erasure). Events: requested, resubscribe_requested, confirmed,
  unsubscribed, suppressed, erased. Logged only when an email is really sent (no growth from repeats).
- `suppressions` — keyed HMAC of the email (no plaintext): hard bounces, complaints, erasure requests.
  A suppressed address is never emailed again, and a pending link dies when its address is suppressed.
- `counters` — atomic `INSERT … ON CONFLICT DO UPDATE … WHERE used < cap` (single statement, no
  read-then-write race). Buckets: `send_hour` (global confirmation emails per hour), `new_day` (new
  rows per day).
- `send_queue` (0005) — signup id + time only (no copy of the address), cascade-deleted with the
  signup, bounded by `queue_max`, entries older than `queue_ttl_hours` dropped.
- `alerts` (0005) — one row per alert kind per window (hits counted), counts only, kept 30 days.
- `settings`, `app_secrets` (only HMAC keys: `email_pepper`, `unsub_key` — never API keys).

Even `service_role` has **no direct table access**: everything goes through the RPCs, so every rule
always runs. Tested.

Because RLS is **forced** with no policies, the RPCs (SECURITY DEFINER, run as the table owner) only
work if the owner role has `BYPASSRLS` or is a superuser. The migration checks this and refuses to
install otherwise. The local tests run as a superuser, so this check is the only proof on real
Supabase — run the migration on a **staging** project first.

### 4.2 Email validation (same rule in TypeScript and SQL)
Conservative ASCII only: local part 1–64 of `a-z0-9.!#$%&'*+/=?^_\`{|}~-`, no leading/trailing/double
dot, domain labels `a-z0-9-` (no leading/trailing hyphen), letters-only TLD, total ≤ 254. Any control
character (CR, LF, TAB, NUL), zero-width or bidi character → **refuse, never clean**. Non-ASCII
domains are refused (homographs). This blocks header injection, CSV formulas and look-alike domains.
It refuses a few exotic-but-valid addresses; that is accepted on purpose.
Also refused: MIME **encoded-word** local parts (`=?charset?enc?…?=`, migration 0004 + validate.ts).
Some mail software decodes these and re-targets delivery (PortSwigger, "Splitting the email atom"),
so a `=?` in the local part is rejected by both the Edge Function and `private.email_ok`.

Optional, not in the reference: an MX lookup. If added, do it with a short timeout and treat a
lookup failure as "allow" (DNS hiccups must not lose real people) — it only removes typo domains.

### 4.3 Anti subscription-bombing (our form used to flood a victim's inbox)
Attackers submit a victim's address into thousands of forms to bury a real alert email. Our limits:
- per address: minimum gap between confirmation emails (example 30 min) and a **lifetime** cap
  (example 3) that is never reset — not by re-signup, not by unsubscribe.
- global: confirmation emails per hour (example 500) **and per day** (example 90, migration 0002 —
  must stay below the email plan's daily limit, e.g. Resend free = 100/day), new rows per day (example 5000).
- per **mailbox** (migration 0004): all `+tag` variants of one inbox share a cap
  (`mailbox_sends_per_day`, example 3). Identity stays the EXACT address (every variant is still its
  own person / its own row), but the SEND throttle is keyed by the real delivery mailbox:
  `local` with the `+tag` stripped, `googlemail.com` folded to `gmail.com`, **dots left alone** (owner
  choice — dots are a smaller vector and the global daily cap still bounds them; folding Gmail dots is
  a future flag). The key is HMAC-hashed before it touches `private.counters`, so no plaintext address
  is stored. This never merges two different-letter addresses (`ahmedmohamed@` ≠ `ahmedsayed@`).
- Turnstile on signup, identical answers, nothing user-controlled in the email.
Result: one inbox gets at most `mailbox_sends_per_day` confirmation emails regardless of how many
`+tag` or exact-address variants are tried (tested: 5 `+tag` variants → 3 emails; 50 parallel submits
of one address → 1 email). Before 0004 the per-address cap could be multiplied by using `victim+1@`,
`victim+2@`… — each counted as a different person. Note: the 30-day deletion of never-confirmed rows
resets counters, so the true ceiling is per-mailbox-per-~30-days — accepted trade-off for data minimization.

### 4.3b Send-cap safety net (migration 0005)
The caps in §4.3 protect the domain, but on their own they **silently drop real people** when a
burst (a post going viral, or a bot) fills the hourly/daily cap. 0005 adds:
- **Queue, not drop.** A *pending* person refused only by a **global** cap is queued; the scheduled
  drain sends them when room frees up, through exactly the same caps. Per-address and per-mailbox
  refusals are **never** queued (the queue must not become a way around them). Re-signing up while
  queued does not add a second entry, and nobody gets two emails (tested under 10 parallel drains +
  30 parallel re-signups).
- **Kill switch.** `select public.waitlist_set_paused(true);` stops every confirmation email at once.
  Signups are still recorded and queued; `waitlist_set_paused(false)` resumes and the next drain
  sends the queue. Resuming is always a human decision.
- **Auto-pause.** After each new hard bounce or complaint, the last 24 h are checked: pause when
  complaints ≥ `complaint_pause_min` (example 2), or hard bounces ≥ `bounce_pause_min` (example 5)
  **and** ≥ `bounce_pause_pct` (example 5%) of the last 24 h of sends. A repeated webhook for the
  same address counts once. Trade-off (owner-accepted): someone feeding fake addresses can pause our
  emails — that only *delays* real people (they wait in the queue) and the owner is alerted; a burned
  sending domain takes weeks to recover.
- **Owner alerts.** First hit per window of: hourly cap, daily cap, new-signup cap, queue full,
  signups while paused, auto-pause → one `alerts` row; the drain emails a summary to `ALERT_TO`.
- **Lock rule (for any future change).** Once the drain holds the global hour/day counters it must
  never *wait* on a per-person lock (signup row, mailbox counter) — it only tries them and skips a
  busy person. Waiting there deadlocks with a live signup (proven by race test #4 before the fix).

### 4.4 Lifecycle and retention (examples)
- pending, never confirmed → deleted 30 days after the **last confirmation email** (not after
  `created_at`: a returning person re-joining an old row must not lose their fresh link that night)
  (`waitlist_maintenance`, daily via pg_cron).
- unsubscribed → deleted after 365 days.
- confirmed → kept until launch use ends; then the owner decides (delete or keep with the same consent).
- erasure request → `waitlist_erase(email)`: row deleted, consent events unlinked, a keyed hash kept in
  `suppressions` so we never email them again (say this in the privacy notice).

## 5. Email deliverability and sender rules (Gmail, Yahoo, Microsoft)

- Send from a **subdomain** (e.g. `mail.brand.com`), so a reputation problem does not hit the main domain.
- **SPF, DKIM and DMARC** all set and **aligned** with the From domain. Start DMARC at `p=none` with
  reports, move to `quarantine`/`reject` once reports are clean.
- Bulk (launch) emails carry `List-Unsubscribe: <https://…/unsubscribe?id=…&t=…>` and
  `List-Unsubscribe-Post: List-Unsubscribe=One-Click` plus a visible unsubscribe link (`launchMail()`).
- Keep the spam-complaint rate **below 0.3%** (target under 0.1%) in Google Postmaster Tools.
- "Bulk sender" threshold is about 5,000 messages/day to Gmail; Microsoft (Outlook/Hotmail) enforces
  the same family of rules since May 2025. Treat the launch as bulk from day one.
- New domain warm-up: Resend suggests ~150 emails on day 1 for a new domain; send the launch in
  batches over days, confirmed addresses only, oldest first.
- Confirmation emails are transactional: no marketing content in them.
- Email provider API key: **sending-only** permission, restricted to the sending domain. It cannot
  read contacts, domains or logs if it leaks. Rotate it if it is ever pasted anywhere.

## 6. Domain and DNS security

- Registrar: account with MFA (hardware key if possible), **registrar/transfer lock ON**, auto-renew ON,
  expiry alerts to two people. Domain expiry = someone else owns your email links.
- DNSSEC ON (Cloudflare can do it in one click).
- CAA record allowing only the CA(s) you use (Cloudflare Pages uses Let's Encrypt / Google Trust Services —
  check before setting).
- **Dangling DNS / subdomain takeover:** every CNAME must point to something we still own. When you
  delete a Pages project, a Vercel/Netlify site, an S3 bucket or an email-provider domain, delete the DNS
  record **the same day**. Takeover campaigns (e.g. Hazy Hawk, 2025–2026) hijack forgotten subdomains of
  universities and agencies to host scam/porn pages under a trusted name. Audit the zone monthly.
- Redirect `*.pages.dev` to the custom domain (or rely on the Origin + Turnstile hostname checks, which
  already reject it).
- HSTS is set without `preload`. Add `preload` only when every subdomain is HTTPS-only forever.

## 6b. Hosting (Hostinger) and the live site
The code can be perfect and still leak if the hosting is weak or a file is uploaded wrong. Hostinger
was hardened by the owner (Nov 2026). These are the rules that keep it that way:
- H-1 (MUST) 2FA on the Hostinger account. Hosting, domain and email sit behind that one login.
- H-2 (MUST) Force HTTPS on (hPanel → Security → SSL). HSTS is in `.htaccess`.
- H-3 (MUST) **Upload the `.htaccess` with every release.** It carries all security headers, blocks
  hidden files and sends `www` to the one real address (the backend accepts only `SITE_ORIGIN`).
  The site without it still "works" but has no protection: always run `ci/check-live-site.sh` after upload.
- H-4 (MUST) Malware Scanner (Websites → Manage → Security → Malware Scanner) shows clean. It runs by
  itself. If it ever finds something: do **not** clean files one by one. Replace everything in
  `public_html` with the files from the repo (`site/` + `.htaccess`), change the Hostinger password,
  then rotate the keys in `docs/KEYS.md` (§7b).
- H-5 (MUST) Only the site's files live on Hostinger: no database, no secrets, no WordPress, no test
  sites, no unused FTP accounts. File access by SFTP only. The repo is the master copy; Hostinger's
  backups are a convenience, not the backup.
- H-6 (MUST) Domain: registrar transfer lock on, WHOIS privacy on (also §6).
- H-7 (MUST) Mailboxes on the domain (e.g. `security@`) have their own strong password: whoever
  controls a mailbox can reset other accounts.

**Live check after every upload or deploy** (the code tests cannot see the live server):
- `bash ci/check-live-site.sh` must pass. It is read-only: it never signs anyone up or sends
  an email. It checks:
  - the CSP is identical to the repo, and every security header is present;
  - http→https and www→apex redirects;
  - hidden files return 403/404, and `security.txt` is published;
  - the function refuses junk (no Origin, another site, extra fields, injection text, a huge body,
    the wrong content type, `/drain` with a wrong key) and CORS never allows another site.
- By hand:
  - securityheaders.com grade **A+**;
  - Supabase **Advisors → Security Advisor: 0 errors** (read every warning before changing anything);
  - hPanel Malware Scanner clean.

## 7. Keys and secrets

| Secret | Where | Who may see it |
|---|---|---|
| `SUPABASE_SECRET_KEYS` (sb_secret_) | auto-injected into the functions | nobody; never copied |
| `RESEND_API_KEY` (sending-only) | `supabase secrets set` | owner only |
| `TURNSTILE_SECRET` | `supabase secrets set` | owner only |
| `RESEND_WEBHOOK_SECRET` (whsec_) | `supabase secrets set` | owner only |
| `CRON_SECRET` (0005, 32+ random chars) | `supabase secrets set` **and** Vault (`waitlist_cron_key`) | owner only |
| `email_pepper`, `unsub_key` | `private.app_secrets` (insert via SQL editor) | owner only |
| Turnstile **site** key, function URL | `site/assets/config.js` | public (fine) |

Never paste any secret into an AI chat, an issue, a commit or a screenshot. Legacy `anon`/`service_role`
JWT keys are refused by the code. Rotating `unsub_key` invalidates every unsubscribe link already sent —
only do it with a new launch email ready.

## 7b. Your computer, your keys, your connections (2026 breach lessons)
The 2026 breaches that hurt small projects the most came in through the owner's side, not the code:
- infostealer malware copied live dashboard sessions from a developer's computer;
- a credential forgotten for years still worked;
- an AI agent in CI obeyed instructions hidden in a GitHub issue title.

The same rules as the gym guide (DEV-1…6), applied to this project:
- **Computer (DEV-1).**
  - Use a separate browser profile only for Supabase, Resend, Cloudflare, Hostinger, the registrar
    and GitHub, and sign out when done.
  - No cracked software or unknown extensions.
  - Suspected malware: from a clean device, sign out of all sessions everywhere, then rotate
    everything in the inventory below.
- **Inventory (DEV-2)** in `docs/KEYS.md`: names and places only, **never values**. For this project:
  - `RESEND_API_KEY`, `RESEND_WEBHOOK_SECRET`, `TURNSTILE_SECRET`, `CRON_SECRET` (+ its Vault copy);
  - `email_pepper`, `unsub_key`;
  - Supabase access tokens (CLI);
  - GitHub tokens and connected OAuth apps;
  - Hostinger and registrar logins, Cloudflare API tokens.

  Revoke anything unused for 90 days. Rotate when a tool or person stops using it.
- **AI agents on the repo (DEV-3).**
  - No CI job lets an agent read issue/PR/comment text while holding a write token or a secret.
  - No `pull_request_target` + checkout of PR code.
  - Making the repo private does not remove this rule: collaborators and bots still write issues.
- **No packages (slopsquatting).** The site and the functions import **nothing** from npm, jsr or a URL.
  Keep it that way: a new import needs the owner, and must never be a name an AI remembered.
  `.npmrc` (`ignore-scripts`, `min-release-age=3`) guards any test tool that is ever approved.
- **Unused Supabase features are switched off.** This project has no user accounts and no live updates:
  - Auth → **turn off "Allow new users to sign up"** (and every provider). The waitlist never uses
    Auth, so an open signup endpoint is only attack surface.
  - Realtime → **turn off "Allow public access"**, and keep every table out of the `supabase_realtime`
    publication. All tables are in `private` anyway.
  - Storage → no buckets.
- **Redirects.** The confirmation and unsubscribe links are built only from `SITE_ORIGIN` (exact,
  validated) and a random token. There is no "return to" parameter anywhere; never add one
  (open redirect = phishing that looks like us).
- **Backups (DEV-6).**
  - Check which backups your Supabase plan includes. Free projects may have none you can restore.
  - Before launch, export the confirmed list (`waitlist_export_confirmed()`) to an encrypted place,
    not a plain file on the laptop.
  - After any restore, re-run erasures made since the backup time. `suppressions` keeps their hashes,
    so they are never emailed again, but their rows must be deleted again.

## 8. Privacy (GDPR) — what the code does and what the owner must do

Code does: unticked consent box with exact text + version, age box, double opt-in, append-only consent
events (what version, when, which step), one-click unsubscribe, retention deletes, erasure with
suppression hash, minimal data, no IP, no trackers, no third-party scripts except Turnstile.
Owner must: finish `site/privacy.html` (controller identity, processors and regions, retention numbers),
sign DPAs with Supabase, the email provider and Cloudflare, choose the Supabase region (EU if the
audience is EU), and answer access/deletion requests (template in the privacy page).
Bump `current_consent_version` + `CONSENT_VERSION` + the `data-consent-version` attribute **together**
whenever the consent text changes.

## 9. Attack catalogue (each with its defense and test)

| # | Attack | Defense | Test |
|---|---|---|---|
| W1 | Read/export the list with the browser key | no key in the site; anon/authenticated execute nothing; schema private closed | test_01 |
| W2 | Call RPCs directly / read tables with service_role | service_role has no table grants; RPCs only | test_01 |
| W3 | Email enumeration ("is X on the list?") | identical 202 for every case; rounded counter | Deno "byte-identical" |
| W4 | Subscription bombing a victim | per-address gap + lifetime cap, **per-mailbox cap (0004)**, global hour/day caps, Turnstile | test_02, test_04, test_05, race 1 |
| W4b | `+tag` variants multiply the per-address cap (`victim+1@`, `victim+2@`…) | per-mailbox cap folds `+tag` to one inbox (0004) | test_05 |
| W4c | Encoded-word address re-targets delivery (`=?…?=@…`) | refused by validate.ts + `private.email_ok` (0004) | test_05 |
| W5 | Bot farm filling the table / burning sender reputation | Turnstile (hostname+action), honeypot, time trap, disposable list, global caps | Deno refusals, test_04, race 2 |
| W6 | Turnstile token from another site/widget, or replayed | hostname + action check, single verify per token | Deno refusals, confirm test |
| W7 | Turnstile outage used as a bypass | fail closed (503) | Deno |
| W8 | Link scanners auto-confirming (fake consent) | fragment token, button POST, no auto-submit, Turnstile on confirm | e2e scanner test |
| W9 | Token theft from logs/Referer | fragment, `Referrer-Policy: no-referrer`, only hash stored | e2e, test_02 |
| W10 | Guessing / reusing confirmation tokens | 256-bit random, hashed, single use, expiry, rotation | test_02, race 3 |
| W11 | Header/SMTP injection via the email field | CR/LF and control chars refused (TS + SQL), nothing user-controlled in headers/subject/body | test_02, Deno |
| W12 | Homograph / IDN look-alike domains | ASCII-only domains | test_02, Deno |
| W13 | CSV/formula injection when the owner opens the export | strict email rule + `csvCell()` prefixes `= + - @ TAB CR` with `'` and quotes every cell | Deno csv |
| W14 | XSS on the site | static files, strict CSP (no inline, no eval, only self + Turnstile), textContent only, CI grep for sinks | check-site.sh, e2e XSS probe |
| W15 | Clickjacking | `frame-ancestors 'none'`, `X-Frame-Options: DENY` | check-site.sh |
| W16 | CSRF / cross-site form posts | exact Origin, JSON only, CORS for one origin, never reflected | Deno |
| W17 | Mass assignment (`status:"confirmed"` in the body) | only known keys | Deno |
| W18 | Huge bodies / slow memory exhaustion | 4 KB cap read before parsing | Deno |
| W19 | Forged bounce/complaint webhooks (suppress someone, or spam the endpoint) | Svix signature on raw body, replay window | Deno webhook |
| W20 | Forged unsubscribe of another person | HMAC per id, checked in SQL | test_03 |
| W21 | Ignoring unsubscribes / complaints → spam folder, legal risk | one-click, suppression, export excludes both | test_03, e2e |
| W22 | Concurrency races (same address 50×, same link 20×, cap overshoot) | single-statement counters, row locks, conditional UPDATE | race_parallel.sh |
| W23 | Denial of wallet (millions of calls to the public function) | spend cap ON, separate project, cheap early refusals | owner setting |
| W24 | Subdomain takeover / domain hijack | §6 | owner checklist |
| W25 | Sender spoofing (phishing "from" our domain) | SPF/DKIM/DMARC aligned, DMARC to reject | owner checklist |
| W26 | Leaked email-provider key | sending-only + domain-restricted key, rotate | owner checklist |
| W27 | Framework/server CVEs (middleware bypass, RSC RCE) | no server code at all (A-1) | architecture |
| W28 | Supply chain on the site | zero npm dependencies in the site; CI blocks third-party scripts | check-site.sh |
| W29 | Agent mistakes (an AI turns on `verify_jwt=false` elsewhere, adds wildcard CORS, logs emails, uses IPs) | CI checks + this guide + tests | check-functions.sh |
| W30 | Stale consent text (page changed, old version stored) | version must match the server | Deno 409 |
| W31 | Pre-ticked consent box | CI refuses `checked` on checkboxes | check-site.sh |
| W32 | Privacy leaks in logs | logs carry only function, status, reason code; raw paths never logged | check-functions.sh |
| W33 | Timing side channel ("new address" answers slower because an email is sent) | email sent in the background after the response | Deno latency test |
| W34 | Flood of `GET /count` turning into DB load | 60 s per-instance cache, rounded value | Deno cache test |
| W36 | Burst fills the global cap → real people silently get no email | queue + scheduled drain (0005), owner alert | test_06, race 4 |
| W37 | Bot feeds fake/non-existent addresses → hard-bounce spike burns the sending domain | auto-pause on bounce/complaint spike, owner alert, queue keeps real people | test_06 |
| W38 | Scheduler endpoint abused (force sends, read alerts) | secret header, constant-time compare, 404 when wrong or unset, same caps as live | Deno drain, test_06 |
| W39 | Infostealer copies the owner's live dashboard session | admin-only browser profile, sign out everywhere from a clean device, rotate from the inventory | §7b (owner) |
| W40 | Forgotten old key / OAuth app still has access | `docs/KEYS.md` inventory, 90-day unused revoke | §7b (owner) |
| W41 | Prompt injection through an issue title into a CI agent | no agent job with write token + untrusted text | §7b |
| W42 | Supabase Auth signup left open on a project that needs no accounts | Auth signup off, Realtime public access off, no buckets | §7b checklist |
| W35 | Catch-all domain farm (one domain, thousands of "real" confirmed addresses) | Turnstile + global caps limit the speed; **owner option:** per-domain daily cap for non-major domains (not by IP) | — (not built) |

## 10. Deliberately NOT done (do not add without the owner)

- **IP rate limiting / IP storage** — W-1.
- **Single opt-in** — W-3.
- **"You're already on the list" message** — enumeration (W3).
- **Confirm on page load / auto-submit** — scanners (W8).
- **Referral leaderboard / "move up the list"** — invites fake-account farming and position gaming. If
  the owner wants it later: count only *confirmed* referrals, cap rewards per referrer, never show
  other people's emails, add it as a separate reviewed feature.
- **Analytics / pixels / chat widgets** — trackers need a cookie banner and add third-party script risk.
- **Showing the email back in the confirmation page or email** — not needed, avoids injection surfaces.
- **A framework with SSR** — A-1.

## 11. Checklists

### Definition of done for any change
`bash ci/check-site.sh site`, `bash ci/check-functions.sh supabase`, `bash ci/check-migrations.sh
supabase/migrations`, `deno test supabase/functions/tests`, `bash tests/run_all.sh`, and for site/flow
changes `bash e2e/run.sh` — all green. New behavior = new test.

### Before go-live (owner)
- [ ] Separate Supabase project, region chosen, spend cap ON, smallest compute.
- [ ] Migration applied; `email_pepper` and `unsub_key` inserted (32+ random chars each, different).
- [ ] pg_cron daily: `select public.waitlist_maintenance();`
- [ ] Safety net (0005): set function secrets `CRON_SECRET` (`openssl rand -hex 32`) and `ALERT_TO`
      (your real inbox), store the same key in Vault and schedule the drain every 10 min:
      ```sql
      select vault.create_secret('<the CRON_SECRET value>', 'waitlist_cron_key');
      select cron.schedule('waitlist-drain', '*/10 * * * *', $$
        select net.http_post(
          url     := 'https://<project-ref>.supabase.co/functions/v1/waitlist/drain',
          headers := jsonb_build_object('content-type', 'application/json', 'x-cron-key',
                       (select decrypted_secret from vault.decrypted_secrets where name = 'waitlist_cron_key')),
          body    := '{}'::jsonb, timeout_milliseconds := 60000) $$);
      ```
      Then test once: `select public.waitlist_set_paused(true);`, sign up with your own address
      (no email), `select public.waitlist_set_paused(false);`, wait for the next run (email arrives).
- [ ] Secrets set; `config.toml` has `verify_jwt=false` only for `waitlist` and `email-events`.
- [ ] Unused features off (§7b): Auth "Allow new users to sign up" OFF, Realtime "Allow public access" OFF, no Storage buckets.
- [ ] Supabase Advisors → Security Advisor: 0 errors.
- [ ] Hostinger rules H-1…H-7 (§6b) done; `.htaccess` uploaded; `bash ci/check-live-site.sh` passes; securityheaders.com A+.
- [ ] `docs/KEYS.md` inventory written (names and places only); admin-only browser profile in use.
- [ ] Backups: know what your plan restores; encrypted export of the confirmed list before launch.
- [ ] Turnstile widget: hostname = the real domain only; site key in `config.js`, secret in Supabase.
- [ ] `_headers` connect-src = the real project URL.
- [ ] Sending subdomain verified; SPF, DKIM, DMARC; sending-only key; webhook for bounced/complained.
- [ ] Registrar lock, MFA, DNSSEC, CAA, no dangling records, `security.txt` contact filled.
- [ ] Privacy page completed; DPAs signed.
- [ ] Test with a real Outlook/Microsoft 365 address (Safe Links) that opening the link does NOT confirm.
- [ ] Postmaster Tools (Google) and SNDS (Microsoft) set up before the launch send.

### Launch-day send
Export with `waitlist_export_confirmed()` (owner, SQL editor), CSV through `toCsv()` if a human opens
it, send with `launchMail()` (one-click headers, idempotency key per campaign), in batches, watch
complaints and bounces, stop if complaints approach 0.1% (`select public.waitlist_set_paused(true);` stops confirmation
emails too; auto-pause does this by itself on a spike).

## 12. Red-team list (try these before every release)
Submit the same address 100× in parallel; submit 1,000 random addresses with a valid captcha; reuse one
Turnstile token twice; use a signup token on confirm; open the confirm link with curl and with a
headless browser and check the DB stays pending; POST confirm with no Origin; send `status` in the body;
send a 1 MB body; put `\r\nBcc:` and `=HYPERLINK()` in the email; use a Cyrillic domain; forge a
webhook; replay an old webhook; unsubscribe someone else with your own token; turn Turnstile off
(network block) and check signups fail closed; check the export contains no pending/suppressed rows;
grep the logs for any `@`; fill the hourly cap and check the next person is queued and emailed
after the next drain (once); call `/drain` with no key and a wrong key (404); feed 5 hard bounces and
check sending pauses and an alert arrives with no address in it.
After every upload: `bash ci/check-live-site.sh` and the by-hand checks in §6b.

## 13. Sources
- Cloudflare Turnstile server-side validation: https://developers.cloudflare.com/turnstile/get-started/server-side-validation/
- RFC 8058 one-click unsubscribe: https://www.rfc-editor.org/rfc/rfc8058
- Google email sender guidelines: https://support.google.com/a/answer/81126
- Yahoo sender best practices: https://senders.yahooinc.com/best-practices/
- Next.js / React security release, May 2026 (Netlify summary): https://www.netlify.com/changelog/2026-05-08-react-nextjs-security-vulnerabilities/
- Supabase spend cap: https://supabase.com/docs/guides/platform/spend-cap
- Supabase Edge Function invocation billing: https://supabase.com/docs/guides/platform/manage-your-usage/edge-function-invocations
- OWASP CSV injection: https://owasp.org/www-community/attacks/CSV_Injection
- AWS — subdomain takeover: https://aws.amazon.com/blogs/security/threat-tactic-spotlight-subdomain-takeover/
- Microsoft — prevent dangling DNS: https://learn.microsoft.com/azure/security/fundamentals/subdomain-takeover
- Resend API keys, idempotency, webhooks: https://resend.com/docs
- GDPR consent records (Art. 7(1) "demonstrate consent"): https://gdpr-info.eu/art-7-gdpr/

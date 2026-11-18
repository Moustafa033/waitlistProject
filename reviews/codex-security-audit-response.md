# Response to the Codex security audit (2026-11-18)

Author: Claude. Every finding was checked against the code before deciding. "Fixed" items have a test
that performs the attack; the tests fail without the fix (checked by running them without 0008).

## Fixed (migration 0008, Edge Function, CI)

| # | Finding | Fix | Proof |
|---|---|---|---|
| 3 | `+tag` variants of one inbox each get a partner acknowledgement | Partner acks take one unit of the per-mailbox daily cap, shared with waitlist confirmations. Refused tries store nothing and use no daily slot. | `test_09` audit #3 (fails without 0008) |
| 5 | A full daily cap answers `busy` only for new addresses, revealing applied/deleted ones | "Cap full?" is decided first, before anything about the address. | `test_09` audit #5 |
| 11 | Erasure and the bounce webhook take locks in opposite order (deadlock) | Erasure writes the suppression row first, the same order as `waitlist_suppress`. "Delete my data" now also deletes a partner application of that address. | `test_09` audit #11, race: 20 x (erase + bounce) at once |
| 12 | Simultaneous `/count` refreshes each start a query | The refresh promise is shared per instance. | Deno: 20 parallel requests, 1 query |
| 13 | Database on another consent version: visitor told "check your inbox" | The function maps the database's `stale_consent_version` to `409 reload_page`. | Deno audit #13 |
| 14 | Phishing text in the owner email | Every applicant field is labelled "(unverified)"; a warning block comes before the visitor text. | Deno audit #14 |
| 15 | Refused requeue silent; queue cap racy | Requeue failures are logged (`requeue_failed`); admission is serialised with an advisory lock. | Deno audit #15; `test_09` (4 requeues, cap 2, exactly 2) |
| 23 | Lowercasing before the ASCII check lets the Kelvin sign etc. become ASCII | ASCII-only check on the raw input, before lowercasing. | Deno audit #23 |
| 25 | `check-site.sh` passes without `.htaccess` | Missing `.htaccess` now fails the site check. | Verified on a copy of `site/` without it |

## Fixed after the owner's decision (migration 0009)

| # | Finding | Fix | Proof |
|---|---|---|---|
| 1 | Anyone can apply with someone else's email and take that address's one slot | An application is stored as **pending**; the applicant gets ONE fixed "Confirm your application" email (token in the URL fragment, hash only in the database). Only `POST /partner-confirm` (Origin + Turnstile action `partner_confirm`, never on GET) confirms it; only then is the one-per-address slot used and the owner notified. A pending row never blocks the real person: a new application replaces the details and sends a new link (rate-limited: `resend_min_minutes`, max 3 links), and unconfirmed rows are deleted after 48 h. The separate "we received" email is gone (the confirm page says it), so each step is 1 email. | `test_10_partner_confirm.sql` (fake applicant replaced by the real one; guessed/expired/used/suppressed links refused; 3-link cap; expiry frees the address); race: 20 clicks on one link -> 1 confirmation; Deno: confirm route refusals, captcha actions not interchangeable, fixed email |

## Planned (before a specific event)

| # | Finding | When |
|---|---|---|
| 6 | The unsubscribe credential also authorises erasure | Before the first launch/news email: give erasure its own purpose-bound credential. Today only the confirmation email exists, where both links live in the fragment of one personal page. |
| 7, 10 | Shared send limits starve queues; ambiguous timeouts refunded | Resend Pro + raising the caps (already planned before the owner's video) removes the starvation in practice; an exact accounting of ambiguous sends is not worth its complexity at this volume. |
| 26 | Restoring an old backup could bring back erased addresses | Owner runbook: after any restore, pause sending and re-apply erasures before resuming. |

## Accepted, with the reason

| # | Finding | Why accepted |
|---|---|---|
| 2 | A send already claimed by the worker can still go out if an erasure/pause lands in the same seconds | The window is the time between claim and handoff (seconds). Every mail system has this window; an email already handed off can never be recalled. Suppression, erasure and pause are all re-checked at claim time. Rated low, not high. |
| 4 | Transient failures can strand queued work | Provider-down is handled (requeue, refunds). A waitlist person whose confirmation failed can sign up again. HTTP-error retries would need attempt counters to avoid infinite loops on permanent errors. |
| 8 | Someone can use up a pending address's 3 confirmation emails | Bounded by the per-address and per-mailbox caps; the address is freed after the pending retention. Rare and cheap to resolve by hand. |
| 9 | Auto-pause can miss events in a race | Resend also enforces its own reputation limits; the pause is an extra layer. |
| 16 | After 12-month retention an address can apply again | Intended: "once" means once per retention period. |
| 17 | A bounce without a subtype counts as hard | Deliberate: unknown bounces suppress (fails safe for the sending reputation). |
| 18, 19, 22 | Slow uploads, timing differences, comparison timing | Behind Turnstile and the Supabase gateway; not practically measurable over the internet. |
| 20 | Suppression is per exact address, not per mailbox | Owner policy W-2: exact address is the identity. |
| 21 | The server role can call owner functions | That role is the secret key; whoever has it already controls everything. It never leaves Supabase. |
| 24 | CSV export safety depends on the owner using `toCsv()` | No export is in use yet; documented in the guide. |
| 27 | Form attestations are soft | Correct and intended; Turnstile and the database enforce. |

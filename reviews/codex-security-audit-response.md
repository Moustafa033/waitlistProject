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

# Response to the Codex re-check (reviews/codex-recheck.md)

0008 and 0009 were not yet applied in production, so 0009 was corrected in place.

## Fixed

| Item | Fix | Proof |
|---|---|---|
| R1 (blocker) | Replacing a pending application's details clears its token in every branch (live, paused, cap full, queue full). A link approves only the details it was issued for. | `test_11` R1 (old link refused after a paused replacement); breaking the fix makes it fail |
| #2 (blocker) | `waitlist_send_allowed(email)` is asked right before EVERY queued email (waitlist and partner) is handed to the provider: `suppressed` -> never sent, unit refunded; `paused` -> unit refunded, partner work requeued. Fails closed on any other answer or error. | Deno re-check #2 (both queues, both verdicts, garbage answer); `test_11` #2 |
| R2 | Rows from before 0009 are NOT confirmed: they become pending with no possible link and are deleted by maintenance after 48 h. Legacy queue entries are dropped. | Reviewed; the local suite starts from an empty database |
| R3 | One lock order: application row -> mailbox advisory lock -> mailbox counter -> global counters -> queue admission. Partner apply takes the same mailbox advisory lock as waitlist signup; the partner drain only TRIES the application row and the mailbox lock; requeue locks the row before admission. | Race: 40 mixed partner/waitlist requests + both drains on one inbox, 3 runs, no deadlock |
| R4 | A live link or live owner notice deletes any older queue entry of the same application; the drain re-checks status, cooldown and attempt cap under the row lock. | `test_11` R4 |
| R5 | A queued link gives its mailbox unit back; the drain charges the mailbox allowance on the dispatch day (try-lock), and leaves the row queued if the inbox already had its emails today. | `test_11` R5 |
| R6 | A refused queue admission (apply, confirm, requeue) raises `queue_full`; the worker counts only successful requeues as waiting. | `test_11` R6; Deno re-check R6 |
| R7 | The drain deletes pending rows past the 48 h deadline instead of sending a new link; cleanup no longer exempts queued rows; a requeued link that never reached the provider gives its attempt back and its token is cleared. | `test_11` R7 |
| R8 | The confirm page distinguishes "link refused" (expired/used/replaced) from temporary errors, which keep the button usable with a fresh Turnstile token. | `node --check`; logic reviewed (no browser harness for this page yet) |

## Still open (owner decision, low impact at current volume)
- #5: a fresh address can still get `busy` while capacity fills concurrently (a narrow race; no address state is read before the first capacity check).
- #12: `/count` across instances and well-formed unsubscribe/erase credentials still reach the database without a CAPTCHA (cheap indexed queries).
- #13: the waitlist queue keeps the pending row's original consent version on a resubmission (all versions currently grant the same emails); fix before the next consent-text change.
- #4, #7, #9, #10, #17, #18: Codex disagrees with accepting them. They concern retries, starvation, auto-pause precision, refund accounting, webhook scope and slow uploads. The owner decides; none lets anyone read, change or delete data.

# Response to Codex re-check 2

| Item | Fix | Proof |
|---|---|---|
| 1 (High) send after erasure / unsubscribe / pause | ONE send path for live and queued mail (waitlist and partner). Right before every handoff, `waitlist_send_allowed(email, kind, id)` checks the do-not-email list, the kill switch AND the current state of the exact signup/application (`signup` pending, `partner_confirm` pending, `partner_owner` confirmed, address must match). Anything unexpected fails closed. | Deno: live signup and live partner with `cancelled`/`suppressed` send nothing; `test_11` state checks incl. "unsubscribed meanwhile -> cancelled" |
| 2 (Medium) lost work | A paused/errored waitlist email goes back in its queue (`waitlist_signup_requeue`), also after a provider outage. Confirmed applications' owner notices bypass the queue cap. | Deno re-check 2 #2; `test_11` (owner notice admitted at cap 0, unsubscribed signup not requeued) |
| 3 (Medium) retry invalidates a valid link / key reuse | Requeue no longer clears the current link. Every confirmation email's idempotency key carries 8 bytes of its token HASH (`partner-confirm/<id>/<send_no>/<tag>`), so a retry with a new link never reuses an earlier key. | `test_11` (link still confirms after requeue); Deno (rows without a valid tag are never sent) |
| 4 (Medium) drain vs live deadlock | Live paths remove queue entries with `partner_dequeue_nowait` (`for update skip locked`), never waiting on a row the drain holds. | Race on a populated queue: the old blocking delete deadlocked 3/3 runs; the fix passed 3/3 |

Changed existing assertions (behaviour changed on purpose, documented): the waitlist signup happy-path step order now includes `waitlist_send_allowed` before the email (Turnstile-before-database unchanged); `test_11` R6 now expects the owner notice to be queued instead of a `queue_full` alert.

# Response to Codex re-check 3 (findings pasted by the owner; no report file was written)

| Item | Fix | Proof |
|---|---|---|
| 1 mail can start after cancellation | Order in the one send path is now: prepare everything (unsubscribe link, the email itself) -> `waitlist_send_allowed` as the LAST call -> provider. The check takes the link that is inside the email (`p_token`) and requires it to be the row's CURRENT, unexpired link, so an email whose link was replaced, used or expired is never sent, even while the row is still pending. | Deno re-check 3 #1 (the check is the call directly before the provider, with the token, for waitlist and partner); `test_11` (wrong / missing / replaced / expired link -> cancelled); breaking the token check fails the suite |
| 2 live waitlist email lost | The shared path handles it: not handed over (prepare failed, paused, provider not reached) -> send unit refunded and `waitlist_signup_requeue(id, token)`. The requeue restores the allowance: the attempt no longer counts toward `max_confirm_sends`, the resend wait is lifted, and the inbox's daily unit is returned (the drain takes it again at dispatch). The drain no longer requeues separately. | Deno re-check 3 #2 (live: down / paused / prepare-failed are requeued once; cancelled and provider-error are not); `test_11` (3 failed handoffs use 1 of the address's emails; inbox unit back) |
| 3 partner retry invalidates a delivered link | Confirmation links are derived, not random: `private.confirm_token(scope, id, details_rev, number)` = HMAC with the existing key and a `confirm-link:` prefix (can never equal an unsubscribe token). A retry has the same revision and number, so the drain rebuilds the SAME link and the SAME idempotency key (`partner-confirm/<id>/<number>/<tag>`, waitlist `confirm/<id>/<number>`); the provider drops the duplicate and a delivered link keeps working. New details bump `details_rev`, a genuinely new email bumps the number: both give a new link. Only the hash is stored. `waitlist_signup` and `waitlist_drain_queue` are re-stated from 0005 with that one line changed (diff verified). | `test_11` re-check 3 #3 (retry = same token, same tag, same number; replaced details after a failed handoff still get a different link and the old one is refused); replacing the derived link with a random one fails the suite |
| 4 waitlist requeue lock order | `waitlist_signup_requeue` locks the signup row first (`for update`), then inserts into the queue: the same order as a live signup. | Race: 20 live re-signups + 20 requeues + 20 drains for the same people, 3 full runs, no deadlock |

Limit of item 1, stated plainly: the check is the last database call before the provider request, but the request itself is a network hop to another company's system. A deletion or pause that commits during those milliseconds cannot stop an email that is already on the wire, and no design can recall an email the provider has accepted. Closing it further would need the provider inside the database transaction, which does not exist.

Changed existing assertion (behaviour changed on purpose): the waitlist signup step order is now `waitlist_unsub_token` -> `waitlist_send_allowed` -> mail (the check moved to be last).

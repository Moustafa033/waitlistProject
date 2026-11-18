# Creating in Public security recheck

Reviewed 18 November 2026 at `7558e8a`, including `2d56417`, against `reviews/codex-security-audit.md` and `reviews/codex-security-audit-response.md`. The review used source analysis, existing local tests, and an offline CI check on a disposable copy of the static site. Production was outside scope.

The main release blocker is the binding between a partner confirmation link and the submitted details. A valid link can approve details that another visitor supplied after the link was issued. Mail dispatch after a committed erasure or pause remains open from the original audit.

## Findings marked fixed in the response

| Audit finding | Recheck | Evidence and remaining work |
| --- | --- | --- |
| **1. Unverified partner applications** | **Partly fixed** | Fresh applications stay pending and send only a fixed confirmation email. The owner gets details after confirmation. A pending replacement that gets queued can change what an older link approves. Migration 0009 also treats every historical application as confirmed. See R1 and R2. |
| **3. Mail to one inbox through aliases** | **Partly fixed** | The live path shares the waitlist mailbox counter. `test_09` passed for plus aliases and shared live limits. The queued path skips the send-day mailbox check. See R5. |
| **5. Enumeration at full daily capacity** | **Partly fixed** | The already-full condition now returns `429 busy` before looking up the address. `test_09` passed. When capacity is filling concurrently, a fresh address can fail the later atomic reservation and get `429`. Suppressed and existing ineligible addresses can exit with `202` after the initial capacity read. Make the response independent of address state across both capacity checks. `supabase/migrations/0009_partner_confirmation.sql:65`, `:70`, `:95`, `supabase/functions/waitlist/handler.ts:124`. |
| **11. Erasure and webhook deadlock** | **Fixed for the reported pair** | Both operations write the suppression before touching the signup. The 20 erase/webhook pairs in `tests/race_parallel.sh:71` completed without error, and the SQL suite confirmed that self-service erasure now also removes the partner row. Concurrent self-erasure can record the anonymous event twice because both transactions can read the address before either deletion completes. R3 covers mixed queue locks. `supabase/migrations/0008_audit_fixes.sql:106`, `:118`, `:126`, `supabase/migrations/0005_send_safety_net.sql:300`. |
| **12. Unauthenticated database work** | **Partly fixed** | The existing 20-request test got one query from a cold cache within a handler instance. Public count still reaches the database across instances, and well-formed invalid unsubscribe or erase credentials still reach the RPC without a CAPTCHA. The unused count route is a candidate for removal. `supabase/functions/waitlist/handler.ts:200`, `:224`, `:312`, `supabase/functions/tests/waitlist_test.ts:700`. |
| **13. Consent version drift** | **Partly fixed** | A database version mismatch during signup now returns `409 reload_page`, verified by Deno. The waitlist can still queue a resubmission under the current version without updating an existing pending row's version. The drain uses the old row version in the consent event. Store the accepted version with the queued work. `supabase/functions/waitlist/handler.ts:61`, `supabase/migrations/0005_send_safety_net.sql:141`, `:165`, `:261`. |
| **14. Phishing in owner email** | **Mitigated** | The warning, unverified labels, fixed subject, and HTML escaping held in the mail test. An applicant with a confirmed mailbox can still send deceptive text and links into the owner inbox. Treat mailbox control separately from claims about the person, and review full pitches in a restricted view if the email must carry less untrusted content. `supabase/functions/_shared/mailer.ts:193`, `supabase/functions/tests/waitlist_test.ts:534`. |
| **15. Queue admission and silent requeue failures** | **Partly fixed** | The advisory lock serializes admission, and a refused requeue is logged. `test_09` asserts the cap within one SQL session, so it does not exercise parallel admissions. The worker still increments `partner_left` on refusal, and confirmation can report queued even when admission returned false. See R6. `supabase/migrations/0008_audit_fixes.sql:14`, `tests/test_09_audit_fixes.sql:80`, `supabase/functions/waitlist/handler.ts:155`. |
| **23. Unicode input before case normalization** | **Fixed at the public Edge boundary** | Deno confirmed raw non-ASCII input is refused before lowercasing. SQL still normalizes before its allowlist, so equivalent defense for direct privileged RPC callers is absent. ASCII-encoded internationalized domain labels remain allowed under ASCII TLDs. Decide whether those labels are supported, and enforce raw ASCII in SQL if both layers must guarantee the policy. `supabase/functions/_shared/validate.ts:16`, `supabase/migrations/0001_waitlist.sql:78`, `supabase/migrations/0009_partner_confirmation.sql:50`. |
| **25. Missing Hostinger header file** | **Fixed** | The normal site check passed. The same check returned exit 1 and reported the missing file when run against a disposable copy of the site without `.htaccess`. `ci/check-site.sh:34`. |

## New and residual findings in partner confirmation

### R1. High — An existing link can approve replacement details

The apply RPC updates a pending application's name, handles, pitch, and consent version before deciding whether to send or queue. Its paused and mail-cap branches leave the existing token hash and expiry in place. Confirmation consumes that token and reads the current details. The page shows no summary of what the recipient is approving. A real mailbox owner can use the link they received for their own application and cause someone else's details to be delivered to the owner.

The replacement test in `tests/test_10_partner_confirm.sql:57` uses an immediate send and confirms that it rotates the token. The paused and capped branches need the same binding guarantee. Give each submitted revision its own authorization. An outstanding link should approve only the details it was issued for, including if a later submission queues or queue admission fails. `supabase/migrations/0009_partner_confirmation.sql:109`, `:115`, `:130`, `:155`, `:181`, `site/assets/partners-confirm.js:38`.

### R2. Medium — Previous unverified applications are grandfathered as confirmed

Migration 0009 marks every existing application confirmed and fills its confirmation timestamp with the creation timestamp. Previous versions allowed public applicants to supply someone else's address. Any such row that exists at migration time keeps the address's slot, and a queued historical row is eligible for an owner notice. This depends on what was stored before migration. The local SQL suite starts with a fresh database.

Keep independent verification evidence for legacy rows or require reconfirmation before they can occupy a verified slot or be sent to the owner. Verify upgrade behavior using seeded pre-migration data. `supabase/migrations/0008_audit_fixes.sql:55`, `supabase/migrations/0009_partner_confirmation.sql:26`, `:74`, `:227`.

### R3. Medium — Mixed partner and waitlist activity can deadlock

The waitlist drain uses a nonblocking mailbox advisory lock so it can skip a busy recipient while holding global send counters. The partner apply path writes the same mailbox counter without taking that advisory lock and later needs the global counters. The partner drain also holds a queue row and send counters before it waits on a pending application update. Live apply and confirm lock that application first, and erasure can lock it before cascading to the queue. Requeue can also hold the admission lock while its foreign-key insert waits for an application locked by a live request that needs admission. PostgreSQL can roll back a request or drain when these paths overlap.

The passing race suite covers parallel drain claims, multiple clicks on one link, and erasure versus suppression. These mixed paths are supported by source analysis. Use one compatible lock order across writers and avoid a blocking application or mailbox lock after a drain takes the send counters. `supabase/migrations/0005_send_safety_net.sql:219`, `supabase/migrations/0009_partner_confirmation.sql:74`, `:89`, `:120`, `:156`, `:169`, `:200`, `:218`, `supabase/migrations/0007_partner_mail_queue.sql:21`, `:155`, `supabase/migrations/0008_audit_fixes.sql:14`.

### R4. Medium — Outstanding queue work can rotate a fresh link or duplicate a send attempt

The queue stores only an application ID. A successful live send leaves an older queue item eligible, and the drain chooses the message using the row's status at drain time. It can rotate a confirmation link inside the live resend gap or spend another send unit on an owner notice already handled directly. The drain also reads a pending row without locking it and later updates by ID alone. An intervening state change can make this update mint a token for a now-confirmed row or increment a counter that has already reached its cap. The stable owner-mail idempotency key may prevent a second delivery. The extra provider attempt and quota use are possible without a duplicate delivery.

Queue a specific message and revision, and invalidate superseded work when a live send claims that message. Check status, cooldown, and send budget under the lock used for the claim. Verify that a live send and an outstanding queue item produce one current dispatch. `supabase/migrations/0007_partner_mail_queue.sql:21`, `supabase/migrations/0009_partner_confirmation.sql:130`, `:165`, `:181`, `:204`, `:218`, `supabase/functions/_shared/mailer.ts:214`.

### R5. Medium — A queued confirmation can exceed the mailbox allowance on the delivery day

The shared mailbox counter is charged when a partner request is admitted. The partner drain checks only global sending caps when it claims a pending confirmation. Reservations made on different days can all send on one later day, including alongside waitlist and live partner messages to that same mailbox. A provider error can also put a pending application back in the queue without a new mailbox check on its next claim.

Apply the shared mailbox allowance to each applicant dispatch on its actual reservation day. Keep limits on pending work as well, and avoid double-charging when a reservation is reused. Verify the combined allowance across live, delayed, and retried messages in both streams. `supabase/migrations/0009_partner_confirmation.sql:51`, `:89`, `:211`, `:216`, `supabase/functions/waitlist/handler.ts:165`.

### R6. Medium — A successful confirmation can leave the owner with no notice

Confirmation clears the token and commits the application as confirmed. In the paused or mail-cap branches it calls queue admission and discards its Boolean result. A full queue can therefore leave the user seeing success, the owner's notice missing, and the application already holding the address's slot. The generic alert says delayed messages are queued and will go out automatically. The Edge worker also reports requeues as pending even when its helper logged a refusal.

Keep durable owner-notification work when accepting a confirmation. Give failed admissions accurate metrics and an actionable alert. Verify that a confirmed application's notice stays recoverable with a full queue and that refused requeues are excluded from the queued count. `supabase/migrations/0009_partner_confirmation.sql:165`, `:169`, `:175`, `supabase/migrations/0008_audit_fixes.sql:14`, `supabase/functions/waitlist/handler.ts:155`, `:277`, `:292`, `supabase/functions/_shared/mailer.ts:125`.

### R7. Medium — A pending application can block the real person past the stated expiry

A public submission can start the cooldown and use the address's limited send attempts before the mailbox owner confirms. A legitimate repeat can get the same accepted response without replacing the details or sending mail. Drains also increment attempt counts and rotate tokens before contacting the provider, including items that the Edge worker later skips during an outage. Requeueing those items does not restore the count. Once the count is exhausted, a later drain can discard the item. The 48-hour cleanup explicitly exempts rows still queued, and the drain can generate a new link for an old pending row. The public notice says unconfirmed applications are deleted after 48 hours.

Enforce an explicit pending-data deadline across admission, dispatch, and cleanup. Retry a stable message through transient failures. Preserve an address owner's recovery path while keeping unsolicited email bounded. `supabase/migrations/0009_partner_confirmation.sql:79`, `:204`, `:216`, `:255`, `supabase/functions/waitlist/handler.ts:165`, `:277`, `site/privacy.html:116`.

### R8. Low — Temporary confirmation errors look like expired links

The confirmation page treats every non-success HTTP response as an expired or used link and leaves the button disabled. A temporary verification or database error can therefore send the visitor back to the application form even when their original token remains valid. The existing cooldown can then block a replacement.

Distinguish temporary errors from an invalid token result. Give the visitor a fresh Turnstile verification and a retry on the same page. `site/assets/partners-confirm.js:38`, `:48`, `supabase/functions/waitlist/handler.ts:140`, `:344`.

## What held in the new confirmation flow

- The database stores a hash of a random 32-byte token. The expiry and pending-state checks rejected guessed, malformed, expired, used, and suppressed tokens in the local SQL suite. Twenty concurrent clicks on the same token yielded one successful confirmation. Browser roles were denied direct RPC execution. `supabase/migrations/0001_waitlist.sql:109`, `supabase/migrations/0009_partner_confirmation.sql:148`, `tests/test_10_partner_confirm.sql:20`, `tests/race_parallel.sh:85`.
- The confirmation POST accepts a token and CAPTCHA, with no caller-selected target address. The SQL lookup selects the application by token hash. Altering input to name another application is blocked by the key allowlist. A forwarded or otherwise exposed live link remains a bearer credential. R1 concerns modifying what a genuine link approves. `supabase/functions/waitlist/handler.ts:134`, `supabase/migrations/0009_partner_confirmation.sql:155`.
- GET, foreign Origin, an unexpected JSON key, and a CAPTCHA for the apply action were refused in Deno. The static page strips the fragment and waits for a button press before sending. The applicant email contains fixed text and the site's own link. Pitches are escaped in owner HTML. `supabase/functions/tests/waitlist_test.ts:450`, `:484`, `:534`, `site/assets/partners-confirm.js:11`, `:64`.
- Same-address live concurrency produced one initial link claim. The existing parallel drain test claimed each of 30 queued records once. Malformed or invalid confirmation attempts return no application details. The stable full-cap response held in SQL. R3–R7 cover cases outside those tests. `tests/race_parallel.sh:48`, `:60`, `tests/test_09_audit_fixes.sql:41`, `supabase/functions/waitlist/handler.ts:139`, `:152`.

## Planned decisions

| Audit finding | Assessment |
| --- | --- |
| **6. Separate unsubscribe and erasure credentials** | **Agree with the release gate.** Require purpose-bound credentials before the first bulk or news send using one-click unsubscribe. Since 0008, erasure also deletes the application for the matching address, increasing the scope of a leaked one-click credential. Live use of the bulk template remains unverified. `supabase/functions/_shared/mailer.ts:92`, `supabase/migrations/0008_audit_fixes.sql:118`. |
| **7. Starvation under shared caps** | **Disagree that raising caps closes it.** Extra capacity helps normal traffic. Live requests can still consume capacity before either queue gets it, and waitlist mail still takes priority over the partner drain. A guaranteed minimum for queued work or deliberate backpressure is needed to establish progress. `supabase/functions/waitlist/handler.ts:237`, `:264`, `supabase/migrations/0009_partner_confirmation.sql:211`. |
| **10. Accounting for ambiguous sends** | **Disagree.** A timeout can follow provider acceptance and still be refunded. A retried partner confirmation can get a new token and provider idempotency key. Alerts also sit outside the shared budget. A larger provider plan changes throughput and leaves these accounting gaps. `supabase/functions/_shared/mailer.ts:19`, `:185`, `supabase/functions/waitlist/handler.ts:165`, `:298`. |
| **26. Restoring erased addresses** | **Agree if there is a recoverable external record of changes.** Pausing and reapplying erasures works when the changes after the snapshot can be recovered independently. Restoring an older copy can also restore an older suppression list. Reconcile it before resuming sends or exporting. `docs/WAITLIST_SECURITY_GUIDE.md:371`. |

## Accepted decisions

| Audit finding | Assessment |
| --- | --- |
| **2. Send after erasure, suppression, or pause** | **Disagree with the downgrade.** The finding concerns starting a provider request after the change has committed. The worker may have claimed a whole batch and still be processing earlier recipients. 0009 feeds partner details into that same gap, and apply also reads suppression separately from writing the pending application. Add a cancellable claim and an eligibility check at handoff. `supabase/functions/waitlist/handler.ts:237`, `:272`, `supabase/migrations/0009_partner_confirmation.sql:70`, `:100`. |
| **4. Transient failures strand work** | **Disagree.** An HTTP error leaves no retry. A waitlist batch is removed before send, and the refund path does not requeue those items. Partner requeue can be refused or burn the remaining confirmation attempts. Alert rows are marked before mail is attempted. Recovery needs durable per-message state and bounded retries. `supabase/migrations/0005_send_safety_net.sql:251`, `:277`, `supabase/functions/waitlist/handler.ts:165`, `:255`, `:298`. |
| **8. Someone else can spend a confirmation budget** | **Accept as a bounded waitlist trade-off if the owner provides a recovery path.** For partners, R7 shows how caps and queued retention can leave the legitimate applicant blocked beyond the published window. |
| **9. Auto-pause misses concurrent events** | **Disagree that the provider limit is sufficient.** This site's pause can still miss overlapping events, and its bounce-rate denominator includes send reservations. A provider limit is a separate safeguard. `supabase/migrations/0005_send_safety_net.sql:316`. |
| **16. Applications after retention** | **Agree with once per retention period.** The public partner page and notice still say an address can apply once. Make the time limit explicit. `site/partners.html:197`, `site/privacy.html:120`. |
| **17. Missing bounce subtype suppresses** | **Conditionally agree with fail-closed classification.** That policy relies on receiving authentic, relevant events. The code still lacks correlation to site sends and event-ID deduplication before the RPC. Verify the event scope and actual subtype data before treating the risk as accepted. `supabase/functions/email-events/handler.ts:16`, `:22`, `:29`. |
| **18. Slow uploads** | **Disagree with the Turnstile rationale.** Body reads occur before Turnstile on the public forms and before signature verification on the webhook. Gateway buffering and upload deadlines remain unverified. Keep the risk low pending deployment evidence. `supabase/functions/_shared/http.ts:37`, `supabase/functions/email-events/handler.ts:15`. |
| **19. Response timing** | **Agree it is a low priority.** The database branches still do different work before the public response. Internet-level distinguishability remains unmeasured. `supabase/functions/waitlist/handler.ts:59`, `:61`, `:118`, `:120`. |
| **20. Exact-address suppression** | **Agree with the owner's identity policy.** State clearly that a suppression applies to the exact address. Mailbox send limits are a separate control, and R5 shows why they still matter. `supabase/migrations/0001_waitlist.sql:98`. |
| **21. Runtime role has owner privileges** | **Accept as low residual risk.** A server-side key limits exposure. The explicit grants still expand the impact of a compromised public-function runtime. Keep owner rights separate when the database role boundary is revised. `supabase/migrations/0001_waitlist.sql:420`, `supabase/migrations/0005_send_safety_net.sql:357`. |
| **22. Bearer comparison timing** | **Agree it is a low priority.** Practical recovery is unverified. Some of these credential checks are outside Turnstile, so the comparison itself remains a hardening concern. `supabase/migrations/0008_audit_fixes.sql:122`, `supabase/functions/waitlist/handler.ts:200`, `:237`. |
| **24. Spreadsheet-safe export** | **Agree with deferring to the first human-facing export.** Make that export use the safe writer by default when it is introduced. `supabase/functions/_shared/csv.ts:7`, `docs/WAITLIST_SECURITY_GUIDE.md:486`. |
| **27. Self-attested age and consent** | **Agree these are soft controls.** Turnstile checks abuse signals, and the link checks mailbox possession. The age assertion still comes from the submitter. Confirmation should bind the applicant's consent to the specific details approved, as in R1. `supabase/functions/waitlist/handler.ts:109`, `:118`, `:140`. |

## Local verification

- **Deno 2.9.7** — 50 tests passed. Network access was disabled and providers were mocked. Lint and type checks passed for the Edge Functions and local harness. Node syntax check passed for `site/assets/partners-confirm.js`.
- **PostgreSQL 16.16** — `tests/run_all.sh` passed on a disposable loopback database. All nine migrations, ten SQL test files, and the existing concurrency suite ran.
- **Offline CI** — Site, functions, migrations, and hidden Unicode checks passed. The static site check rejected the disposable fixture with the required Hostinger file missing.
- The browser harness requires a local Playwright installation and a Unix socket. Its checked-in flow covers waitlist confirmation. Browser behavior for the new partner route, live Hostinger headers, real Turnstile and mail-provider behavior, and production migration data remain unverified. The new findings above are based on source analysis.

Safe to go live: NO

The site can credit someone else's application details to a real applicant and start sending mail after an erasure or pause takes effect.

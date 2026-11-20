# Creating in Public security recheck 4

Reviewed commit `fe0a0df` on 20 November 2026 against the four items in “Response to Codex re-check 3,” including its stated provider-handoff limit. All four fixes address their original cases. The retry changes introduce one release blocker in waitlist consent. Evidence comes from the source and the existing offline suites.

## 1. Mail starting after cancellation — Closed within the stated limit

The waitlist now prepares the unsubscribe link and email body before the eligibility check. The partner paths prepare the message before the same final check. The database checks the record ID, address, status, suppression, and pause state. For confirmation emails it also requires the exact current, unexpired token. Deno verified the call order and SQL rejected a missing, wrong, replaced, or expired link.

This closes the earlier extra database call between the gate and the request to the provider. A cancellation that commits after the final database read can still race with the provider handoff. That is the stated limit for this item. The gate exposes no new public data access. It will accept a token the database has made current again, which is the separate regression in item 3.

Sources — `supabase/functions/waitlist/handler.ts:85`, `:211`, `supabase/migrations/0009_partner_confirmation.sql:398`, `supabase/functions/tests/waitlist_test.ts:783`, `reviews/codex-security-audit-response.md:94`.

## 2. Live waitlist mail lost on handoff failure — Closed for the reported path

The same helper now handles live and queued mail. A preparation failure, pause, or transport failure requests a refund and requeue. The database checks that the signup is pending and its token still matches before restoring the address and mailbox allowance. Requeue refusal is logged. Recovery still depends on queue admission and the requeue call succeeding. A provider HTTP error remains outside the chosen retry behavior.

This change adds no direct public access to another person's data or mail. The refundable counter also supplies the link number, which contributes to the new credential reuse in item 3.

Sources — `supabase/functions/waitlist/handler.ts:85`, `supabase/migrations/0009_partner_confirmation.sql:367`, `supabase/functions/tests/waitlist_test.ts:802`, `:829`, `tests/test_11_recheck_fixes.sql:187`.

## 3. Partner retry replacing a delivered link — Closed for the same message, with a new high-severity waitlist regression

The local SQL suite showed that an ordinary partner retry keeps the same token, send number, and idempotency tag. Replaced partner details advance the revision and make the older link unusable. The HMAC helper is private, purpose-separated from unsubscribe, and explicitly denied to public API roles and the service role. Actual provider deduplication remains unverified.

**New hole. A revoked waitlist confirmation link can become valid again.** A new waitlist request derives its credential from the existing signup ID, a fixed revision, and the next send number. Requeue can roll that number back. Unsubscribe revokes the stored token and leaves the signup ID and send count intact. A fresh opt-in on that retained record can therefore reproduce the revoked token and give it a new expiry. Someone who still holds the earlier link can confirm the later request, changing the signup and its consent record without obtaining a fresh link from the mailbox. This requires an earlier link that reached a holder despite an ambiguous delivery result. The same reuse can also revive an expired link on a retained pending signup. The regression grants confirmation authority. The reviewed source showed no new read or delete access.

**Fix for Claude.** Give each new waitlist confirmation a generation that never moves backward when send allowance is refunded. Keep each retry attached to its original generation, link, expiry, and idempotency key. Retire that generation on unsubscribe, erasure, expiry, or replacement. Apply refunds once to the matching attempt. Verify that a fresh opt-in uses a new credential and that revoked and expired links stay invalid, while a retry of the same eligible message keeps its link and key.

The existing tests cover token rotation when the send number advances and token reuse within a retry. They leave revocation followed by fresh opt-in with a refunded counter uncovered. The new finding comes from source review.

Sources — `supabase/migrations/0009_partner_confirmation.sql:61`, `:140`, `:275`, `:367`, `:504`, `:580`, `supabase/migrations/0001_waitlist.sql:302`, `:335`, `tests/test_11_recheck_fixes.sql:187`, `:226`.

## 4. Waitlist requeue lock order — Closed for the reported inversion

Requeue now locks the signup row before checking it, refunding the mailbox allowance, and inserting a queue entry. This matches the existing live path's signup-before-queue order. The PostgreSQL case with 20 live signups, 20 requeues, and 20 drains completed without an error. The lock change adds no public access to other people's data or mail.

Sources — `supabase/migrations/0009_partner_confirmation.sql:367`, `:449`, `:499`, `tests/race_parallel.sh:117`.

## Local checks

- All 59 Deno tests passed with external services mocked and network access disabled. Lint and type checks passed.
- The PostgreSQL 16.16 suite passed on a disposable loopback database, including the added lock-order race.
- All four offline CI checks passed. Browser end-to-end and live provider behavior remain unverified. The report is the only repository change.

An old waitlist link can approve a later signup after the subscriber has unsubscribed.

Safe to go live: NO

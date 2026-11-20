# Creating in Public security recheck 5

Reviewed `35ec1a0` against the revoked-link finding in `reviews/codex-recheck-4.md` and Claude's response. This verdict covers that finding and the security effects of the fix. The review used source and existing offline tests. `reviews/codex-security-audit-response.md:98`.

## Revoked or expired confirmation links — Closed

The link generation is separate from the refundable send allowance. Issuing a fresh waitlist confirmation advances the generation on the existing record, and unsubscribe clears the older token from that record. Its old link stays invalid even when the last send was refunded. The queue reuses a generation only for a pending retry whose original link is still current and unexpired. That retry keeps the same link, expiry, and idempotency key. An expired queued link gets a new generation. Partner confirmations follow the same rule and retain their application revision. `supabase/migrations/0001_waitlist.sql:302`, `:335`, `supabase/migrations/0009_partner_confirmation.sql:180`, `:291`, `:554`, `:632`.

The PostgreSQL regression test rejected the revoked link after fresh opt-in and left the signup pending. The new link confirmed it. The suite also verified expiry for both forms, preserved the original expiry on a queued retry of an unexpired message, and showed that repeated requeue calls refunded one allowance without rolling back the generation. `tests/test_11_recheck_fixes.sql:264`, `:279`, `:299`, `:316`, `:345`.

## Security regression check — No new hole found

- **Read, change, or delete someone else's data.** The changed retry RPC remains restricted to the service role. A pending partner retry requires the application's current token. Browser roles still lack direct access to the functions and tables. `supabase/migrations/0009_partner_confirmation.sql:373`, `:706`, `tests/test_01_privileges.sql:10`, `tests/test_08_partner_queue.sql:60`.
- **Confirm a fresh signup with an older link.** Confirmation still requires the current, unexpired token hash on a pending row. New consent uses a fresh generation, and retries cannot extend the expiry of their existing credential. `supabase/migrations/0001_waitlist.sql:302`, `supabase/migrations/0009_partner_confirmation.sql:554`, `:632`, `tests/test_11_recheck_fixes.sql:279`.
- **Email people who did not ask.** The fix adds no recipient-selection or public send route. Retry stays tied to the original record and recipient. The queue and final gate still enforce eligibility, suppression, and pause, and new links are subject to the existing mailing limits. Deno confirmed that partner retry sends the failed link to the database for verification. `supabase/migrations/0009_partner_confirmation.sql:446`, `:596`, `supabase/functions/waitlist/handler.ts:185`, `supabase/functions/tests/waitlist_test.ts:839`.

## Local checks

- All 60 Deno tests passed with external services mocked and network access disabled. Lint and type checks passed.
- The PostgreSQL 16.16 suite passed on a disposable loopback database, including the revoked-link regression and the concurrency suite.
- All four offline CI checks passed. Browser end-to-end, deployed migration state, and live mail-provider behavior remain unverified.

Safe to go live: YES

# Creating in Public security audit

Reviewed 18 November 2026 at commit `4f7fffd`. Scope covered the static site and its two header configurations, migrations 0001–0007, both Edge Functions and their shared modules, the test suites, and CI. Findings cite source evidence and give defensive criteria for verifying fixes. No production systems were contacted.

## Local checks

| Check | Result |
| --- | --- |
| `deno test supabase/functions/tests` | 43 passed, 0 failed on Deno 2.9.7. Network access was disabled and external services were mocked. |
| `deno lint supabase/functions` | Passed, 14 files. |
| `deno check` for the waitlist and email-events entry points | Both passed. |
| `bash tests/run_all.sh` | Passed on disposable PostgreSQL 16.16 bound to `127.0.0.1:5433`. All seven migrations, eight SQL test files, and the concurrency suite ran. |
| `check-site.sh`, `check-functions.sh`, `check-migrations.sh`, `check-hidden-unicode.sh` | All four passed in Git Bash. |

The browser harness was outside the executed suite. Its Playwright dependency was unavailable locally, and its database calls assume a Unix socket. The existing checks establish the specific behaviors they assert.

## Findings

### 1. high: An unverified submission can take someone else's partner application slot

- **Where** `supabase/functions/waitlist/handler.ts:104`, `supabase/functions/waitlist/handler.ts:113`, `supabase/migrations/0007_partner_mail_queue.sql:65`, `supabase/migrations/0007_partner_mail_queue.sql:71`, `supabase/functions/_shared/mailer.ts:156`.
- **What an attacker can do** File an application under someone else's email address, choose the name, social handles, and pitch the owner sees, and occupy the address's only slot while the row is retained. The real person gets an unsolicited acknowledgement and a later application of their own appears successful without reaching the owner. Turnstile checks the submission and the acknowledgement has no mailbox-ownership step.
- **How to verify the fix** An unverified submission leaves the real mailbox owner able to complete an application and keeps the unverified details out of the owner's inbox.
- **Proof test** none. The existing happy-path tests accept mailbox ownership as implicit.
- **Suggested fix** Verify control of the address before claiming the application slot or emailing the owner. Use an expiring pending record and a rate-limited, fixed verification email. Make repeat submissions safe for the mailbox owner.

### 2. high: Claimed mail can still be sent after erasure, suppression, or pause

- **Where** `supabase/migrations/0005_send_safety_net.sql:111`, `supabase/migrations/0005_send_safety_net.sql:215`, `supabase/migrations/0005_send_safety_net.sql:251`, `supabase/migrations/0001_waitlist.sql:329`, `supabase/migrations/0007_partner_mail_queue.sql:119`, `supabase/migrations/0007_partner_mail_queue.sql:140`, `supabase/functions/waitlist/handler.ts:63`, `supabase/functions/waitlist/handler.ts:132`, `supabase/functions/waitlist/handler.ts:202`.
- **What an attacker can do** Mail that overlaps a privacy or safety state change can still be handed to the provider. A person can get a confirmation after unsubscribing, erasing their signup, or being suppressed. A claimed partner notification can disclose application details to the owner after an owner-side erasure. The kill switch also leaves already-claimed mail eligible in the worker. The waitlist's token lookup signs an ID without checking whether the row still exists. Admission checks have a related race because they read suppression separately from the later insert or update.
- **How to verify the fix** When erasure, suppression, unsubscribe, or a pause commits before a new provider handoff, pending work obeys the new state, including work already claimed by a worker.
- **Proof test** none. The SQL suites cover suppression and erasure before a drain claims the row.
- **Suggested fix** Keep a cancellable outbox. Coordinate admission, suppression, and erasure on a common recipient lock, and gate each provider handoff on current eligibility and pause state. Define how the worker handles a send already in progress.

### 3. medium: Partner applications can send repeated acknowledgements to one inbox

- **Where** `supabase/migrations/0007_partner_mail_queue.sql:65`, `supabase/migrations/0007_partner_mail_queue.sql:84`, `supabase/migrations/0007_partner_mail_queue.sql:119`, `supabase/migrations/0004_mailbox_throttle.sql:52`, `supabase/migrations/0006_partner_applications.sql:18`.
- **What an attacker can do** Multiple addresses that deliver to a single mailbox can each receive a fixed acknowledgement. Partner applications lack the waitlist's mailbox send throttle. They also consume the shared mail budget and, with an owner inbox configured, generate a separate owner email per application. The global application cap bounds the volume but a single inbox can still receive the whole allowance over time.
- **How to verify the fix** Equivalent delivery aliases share an applicant mail allowance in both live and queued sending, while exact addresses remain separate identities.
- **Proof test** none. `tests/test_05_mailbox.sql` covers mailbox limits only on the waitlist.
- **Suggested fix** Apply the mailbox send budget to partner acknowledgements and bound partner use of the shared sending budget. Preserve exact-address identity.

### 4. medium: Transient mail failures can permanently strand accepted work

- **Where** `supabase/migrations/0005_send_safety_net.sql:251`, `supabase/migrations/0005_send_safety_net.sql:277`, `supabase/migrations/0007_partner_mail_queue.sql:140`, `supabase/functions/waitlist/handler.ts:76`, `supabase/functions/waitlist/handler.ts:132`, `supabase/functions/waitlist/handler.ts:202`, `supabase/functions/waitlist/handler.ts:252`.
- **What an attacker can do** A backlog amplifies the impact of ordinary provider failures. The worker removes queue items before sending. One connection failure leaves remaining claimed waitlist entries off the queue. A temporary HTTP error leaves the failed partner message without a retry. The scheduler can also be interrupted after claiming a batch. Alerts receive a notification timestamp before the mail attempt, so the owner can miss the warning that sending paused. Partner retries rerun both sends after a connection failure, even if one succeeded, and rely on the provider to deduplicate them.
- **How to verify the fix** Interrupted workers and transient provider responses leave recoverable work. Retrying the failed half of an application preserves the completed half, and a failed alert remains pending.
- **Proof test** none. The Deno suite asserts refunds and requeue calls within a single invocation.
- **Suggested fix** Store a claim lease, retry schedule, and delivery state per message. Record success after provider acceptance. Reconcile ambiguous sends and use persistent idempotency for each recipient and message. Track alert delivery separately from alert claims.

### 5. medium: A full partner cap reveals protected address state

- **Where** `supabase/migrations/0007_partner_mail_queue.sql:62`, `supabase/migrations/0007_partner_mail_queue.sql:65`, `supabase/migrations/0007_partner_mail_queue.sql:68`, `supabase/functions/waitlist/handler.ts:117`.
- **What an attacker can do** Observe different responses depending on the address when the daily application cap is full. A new eligible address gets `429 busy`. An already-applied or suppressed address gets `202 application_received`. The response reveals membership in the combined set of already-applied and suppressed addresses.
- **How to verify the fix** At full capacity, the public response is indistinguishable across new, already-applied, and suppressed fixture addresses.
- **Proof test** none. The existing byte-identical-response test omits the full-cap comparison. A separate test asserts the `429`.
- **Suggested fix** Make the capacity response independent of the address. Keep per-address outcomes internal and handle the user-facing capacity message consistently.

### 6. medium: The bulk unsubscribe credential also authorizes permanent erasure

- **Where** `supabase/functions/_shared/mailer.ts:92`, `supabase/functions/_shared/mailer.ts:102`, `supabase/migrations/0001_waitlist.sql:329`, `supabase/migrations/0003_self_service_erase.sql:14`, `supabase/functions/waitlist/handler.ts:184`.
- **What an attacker can do** Someone who obtains a recipient's one-click credential can permanently remove that signup and suppress future mail to the address. The bulk template puts the same non-expiring credential in a URL query string for mail systems that the database accepts for erasure. This exposure depends on use of that template and access to the credential, such as via a forwarded message or URL logging. The browser's second click is a user-interface check.
- **How to verify the fix** A credential issued for one-click unsubscribe has authority only to unsubscribe that signup. Erasure requires its own valid authorization.
- **Proof test** none. The existing tests verify one-click and erasure independently.
- **Suggested fix** Issue separate purpose-bound credentials, with an expiring or single-use credential for erasure. Preserve one-click unsubscribe and redact bearer values from gateway and provider logs where configurable.

### 7. medium: Shared send limits can starve both queues

- **Where** `supabase/migrations/0005_send_safety_net.sql:20`, `supabase/migrations/0005_send_safety_net.sql:141`, `supabase/migrations/0005_send_safety_net.sql:165`, `supabase/migrations/0005_send_safety_net.sql:212`, `supabase/migrations/0002_daily_send_cap.sql:15`, `supabase/migrations/0007_partner_mail_queue.sql:129`, `supabase/functions/waitlist/handler.ts:223`.
- **What an attacker can do** Sustained submissions that pass Turnstile can use the shared sending capacity before queued people get it. A full waitlist queue can quietly refuse new entries or let queued entries expire. Partner mail comes after the waitlist batch and requires two available send units. With the example settings, the waitlist queue can hold 2,000 entries for 48 hours, with only 90 total mail units available per day. During a pause, waitlist entries are admitted before the mailbox check, which lets one mailbox's aliases take up queue capacity. The guide accepts temporary delays from auto-pause.
- **How to verify the fix** Under sustained valid traffic and during recovery from a pause, legitimate queued entries make progress, and mailbox aliases cannot monopolize admission.
- **Proof test** none. The existing queue tests use small batches with capacity restored.
- **Suggested fix** Reserve some capacity for queued work and both mail streams, bound pending work per mailbox, and size queue admission and expiry to achievable throughput. Surface an address-independent unavailable state when a queue cannot accept more work.

### 8. medium: Someone else can use up a waitlist address's confirmation budget

- **Where** `supabase/migrations/0005_send_safety_net.sql:133`, `supabase/migrations/0005_send_safety_net.sql:170`, `supabase/migrations/0006_partner_applications.sql:167`, `supabase/migrations/0001_waitlist.sql:335`.
- **What an attacker can do** Cause a pending address to receive unsolicited confirmation emails and use up its send allowance. Each replacement invalidates the previous link. If the last link expires before the real recipient acts, the recipient cannot request a new one until retention removes the pending row or the owner intervenes. Ordinary unsubscribe also permits a subsequent transactional confirmation under the current rejoin policy.
- **How to verify the fix** An address owner can recover after abuse of the public resend allowance, while repeat traffic remains bounded and suppressed addresses stay blocked.
- **Proof test** none. `tests/test_02_flow.sql` verifies rotation and cap exhaustion as separate expected behaviors.
- **Suggested fix** Keep still-valid confirmations usable across replacement requests where consent and eligibility are unchanged. Provide a bounded mailbox-owner recovery path without resetting the cap for arbitrary public callers.

### 9. medium: The auto-pause decision can miss a burst of complaints or bounces

- **Where** `supabase/migrations/0005_send_safety_net.sql:300`, `supabase/migrations/0005_send_safety_net.sql:316`, `supabase/migrations/0007_partner_mail_queue.sql:84`, `tests/test_06_safety_net.sql:101`.
- **What an attacker can do** Harm sender reputation while the intended pause may be missed. Concurrent valid events for distinct recipients are inserted and counted without serializing the threshold decision, so each transaction can count without seeing the others. The first suppression reason wins, which excludes a later complaint for an address previously recorded as a bounce or manual suppression. The bounce denominator includes send reservations and owner notices, so it can overstate accepted mail in the affected stream.
- **How to verify the fix** Concurrent distinct events, redelivered events, and a complaint following a bounce all produce the intended health decision for each stream.
- **Proof test** none. The existing SQL auto-pause cases deliver events sequentially and use seeded send counters.
- **Suggested fix** Atomically update health counters from a deduplicated event ledger, separate from the address suppression table. Measure accepted sends and apply the pause decision consistently across concurrent events.

### 10. medium: The database mail budget can undercount provider sends

- **Where** `supabase/functions/_shared/mailer.ts:19`, `supabase/functions/waitlist/handler.ts:76`, `supabase/functions/waitlist/handler.ts:132`, `supabase/functions/waitlist/handler.ts:254`, `supabase/migrations/0002_daily_send_cap.sql:97`.
- **What an attacker can do** Use valid submissions to drive mail near the caps while the accounting can report fewer sends than the provider accepted. A transport timeout can happen after acceptance. Every fetch exception is classified as "provider not reached" and refunded. Owner alerts also send outside these counters. The effect on the current provider plan limit remains unverified.
- **How to verify the fix** All mail streams fit the overall budget, and a send with an unknown provider outcome remains charged until reconciled.
- **Proof test** none. Existing tests distinguish a rejected fetch from an HTTP error without modeling acceptance before the response is lost.
- **Suggested fix** Tie a refund to a specific reservation and documented outcome. Keep ambiguous sends charged until reconciled and include alert mail in a bounded reserve.

### 11. medium: Erasure and suppression can deadlock on the same address

- **Where** `supabase/migrations/0003_self_service_erase.sql:22`, `supabase/migrations/0006_partner_applications.sql:155`, `supabase/migrations/0005_send_safety_net.sql:305`, `supabase/migrations/0005_send_safety_net.sql:308`.
- **What an attacker can do** Cause disruption when a valid erase and provider event for the same recipient overlap. Erasure takes the signup row before it writes the suppression. The webhook can take the suppression entry before it updates that signup. Each transaction can wait for the other, forcing PostgreSQL to abort one and leaving the affected operation dependent on a retry.
- **How to verify the fix** Concurrent erasure and verified suppression for one address both complete with the intended final state and without deadlock.
- **Proof test** none. This lock order follows from the source. The existing race suite exercises the queue drain and signup lock order.
- **Suggested fix** Use the same lock order for erasure and suppression, ideally a common transaction-scoped recipient lock also used by admission.

### 12. medium: Unauthenticated traffic can drive database work

- **Where** `supabase/functions/waitlist/handler.ts:160`, `supabase/functions/waitlist/handler.ts:184`, `supabase/functions/waitlist/handler.ts:266`, `supabase/functions/waitlist/handler.ts:277`, `supabase/migrations/0001_waitlist.sql:395`.
- **What an attacker can do** Consume Edge Function and database capacity without receiving email or solving Turnstile. Well-shaped management requests reach PostgreSQL for MAC verification even when the MAC is wrong. The public count makes a database request at cache refresh; simultaneous refreshes can all start a count because the cache is filled only after the awaited call. The homepage has no counter.
- **How to verify the fix** Unsupported or unauthenticated requests have bounded database cost. If retained, concurrent count refreshes for an instance share one query.
- **Proof test** none. The existing count test awaits each request sequentially.
- **Suggested fix** Remove the unused count route or serve a shared cached aggregate with coalesced refresh. Reject invalid management credentials closer to the edge. Enforce non-IP workload limits on the exact accepted routes.

### 13. medium: Consent version drift can silently drop signups or record outdated terms

- **Where** `site/index.html:41`, `supabase/migrations/0001_waitlist.sql:43`, `supabase/migrations/0005_send_safety_net.sql:105`, `supabase/migrations/0005_send_safety_net.sql:141`, `supabase/migrations/0005_send_safety_net.sql:174`, `supabase/migrations/0005_send_safety_net.sql:261`, `supabase/functions/waitlist/handler.ts:51`, `supabase/functions/waitlist/handler.ts:84`.
- **What an attacker can do** This is a release and record-integrity fault. If the deployed form and Edge Function agree on a new version but the database still uses the older one, the database declines the signup and the visitor is told to check their inbox. The initial migrations default to `waitlist-v1` and the checked-in page uses `waitlist-v4`. Also, when an older pending signup is resubmitted under current terms and queued, the queue can preserve the old row's consent version and use it in the next requested event.
- **How to verify the fix** Version drift yields a clear retry or reload outcome. Queued delivery and consent evidence both use the terms accepted for the request being fulfilled.
- **Proof test** none. Existing tests either use one matching version end to end or check the SQL refusal in isolation.
- **Suggested fix** Make release checks compare the form, function, and database versions. Surface a database version mismatch explicitly and bind each queued confirmation to its validated consent version.

### 14. medium: Partner pitches can carry phishing content into the owner inbox

- **Where** `supabase/functions/_shared/validate.ts:61`, `supabase/functions/_shared/validate.ts:81`, `supabase/migrations/0006_partner_applications.sql:75`, `supabase/functions/_shared/mailer.ts:185`.
- **What an attacker can do** Put deceptive instructions, links, and look-alike names in a legitimate-looking internal application notice. The owner can be led to follow a link or reply to an unverified address. The pitch permits multiline free text, the Unicode filter is a finite blocklist, and the email includes the submitted address as `reply_to`. HTML escaping protects against injected markup. Mail-client linkification remains client-dependent.
- **How to verify the fix** The owner can distinguish every applicant-supplied field from trusted metadata and verify the contact before replying, including when text contains look-alikes, default-ignorable characters, or link-like content.
- **Proof test** none. The Deno owner-mail test verifies HTML escaping.
- **Suggested fix** Keep pitches in a restricted review view and send a short notification. Clearly mark unverified social claims and mail contacts. Review text rendering and Unicode handling while retaining legitimate international names.

### 15. low: A partner requeue can fail silently and the queue cap can race

- **Where** `supabase/migrations/0007_partner_mail_queue.sql:30`, `supabase/migrations/0007_partner_mail_queue.sql:155`, `supabase/functions/waitlist/handler.ts:143`, `supabase/functions/waitlist/handler.ts:235`, `supabase/functions/waitlist/handler.ts:247`.
- **What an attacker can do** During high load or provider trouble, additional applications can worsen queue pressure. Requeue returns `false` when full. The worker ignores that result and can report the item as waiting. Concurrent requeues also do a count followed by an insert with no shared capacity lock. A failed requeue can lose mail recovery for an application that remains in the database.
- **How to verify the fix** Full-queue rejections stay visible and recoverable. Parallel requeues preserve the configured cap and accurate pending counts.
- **Proof test** none. The existing queue-full SQL test is sequential and the Deno requeue mock returns success.
- **Suggested fix** Enforce admission atomically and handle unsuccessful requeues explicitly. A retry should retain its reserved outbox entry.

### 16. low: Retention resets the one-application-ever rule

- **Where** `supabase/migrations/0006_partner_applications.sql:25`, `supabase/migrations/0006_partner_applications.sql:178`, `supabase/migrations/0007_partner_mail_queue.sql:65`, `tests/test_07_partners.sql:113`.
- **What an attacker can do** Apply again and trigger another acknowledgement with the same exact address after routine retention deletes the application. Uniqueness lives only in the application row. The permanent suppression written on owner-initiated erasure is separate from routine retention.
- **How to verify the fix** The exact-address policy remains in effect after ordinary retention, or the public promise explicitly defines when a new application is allowed.
- **Proof test** none. The retention test checks deletion without checking subsequent eligibility.
- **Suggested fix** Resolve the lifetime and retention requirements together. If lifetime uniqueness is required, retain only a purpose-specific keyed marker under an explicit retention policy.

### 17. low: needs confirmation for provider event scope and bounce classification

- **Where** `supabase/functions/email-events/handler.ts:16`, `supabase/functions/email-events/handler.ts:22`, `supabase/functions/email-events/handler.ts:29`, `supabase/functions/_shared/svix.ts:29`, `supabase/migrations/0005_send_safety_net.sql:305`.
- **What an attacker can do** A correctly signed event with a missing bounce subtype is classified as a hard bounce. The handler accepts a signed recipient without checking that the provider message belongs to a recorded send from this site. A replay within the timestamp window can repeat database work while the suppression row remains unique. Production impact depends on actual event schemas, webhook scoping, and access to a signed event.
- **How to verify the fix** Authenticated fixtures for unrelated mail, unknown or missing bounce categories, and duplicate event IDs produce the intended scoped outcomes.
- **Proof test** none. The existing webhook test covers one transient category, signature changes, and an expired timestamp.
- **Suggested fix** Validate the provider schema and allowlist permanent categories. Match events to eligible outbound messages and deduplicate by provider event ID before side effects. Verify the exact signed bytes.

### 18. low: needs confirmation for slow request handling at the gateway

- **Where** `supabase/functions/_shared/http.ts:37`, `supabase/functions/email-events/handler.ts:15`.
- **What an attacker can do** If the gateway streams inbound bodies, a slow upload can keep a handler waiting below the byte cap. The reader has no time limit, and the webhook reads the body before checking even the presence and freshness of signature headers. The buffering and timeout behavior of the production gateway is unknown.
- **How to verify the fix** The ingress or handler rejects incomplete uploads within a fixed deadline, and invalid webhook metadata takes the cheap path.
- **Proof test** none. Existing tests cover size and signature enforcement using complete in-memory bodies.
- **Suggested fix** Enforce an upload deadline at ingress or in the reader. Reject missing or stale webhook metadata before reading the bounded body, then verify the full signature before processing.

### 19. low: needs confirmation for waitlist timing enumeration

- **Where** `supabase/functions/waitlist/handler.ts:58`, `supabase/migrations/0005_send_safety_net.sql:111`, `supabase/migrations/0005_send_safety_net.sql:115`, `supabase/migrations/0005_send_safety_net.sql:148`, `supabase/functions/tests/waitlist_test.ts:353`.
- **What an attacker can do** Potentially distinguish address states from response timing. The response waits for a database RPC whose work differs across suppressed, confirmed, existing pending, and fresh addresses. Contention can make the work differ further. Practical distinguishability through Turnstile and network noise remains unmeasured.
- **How to verify the fix** Controlled latency distributions for synthetic signup states remain indistinguishable under representative database load.
- **Proof test** none. The passing latency test introduces mail-provider delay and uses a mock database.
- **Suggested fix** Move address-specific work off the public response path or make database admission work uniform. Compare timing distributions before making a privacy guarantee.

### 20. low: Exact-address suppression has a narrower scope than mailbox delivery

- **Where** `supabase/migrations/0001_waitlist.sql:98`, `supabase/migrations/0004_mailbox_throttle.sql:54`, `supabase/migrations/0005_send_safety_net.sql:111`, `supabase/migrations/0007_partner_mail_queue.sql:62`.
- **What an attacker can do** Trigger fresh mail routed to the same underlying mailbox through a different exact address, even if the first address was erased or bounced. The waitlist's send cap groups common plus aliases, while its documented policy leaves Gmail dot variants in separate buckets. Suppression itself is exact-address in both flows.
- **How to verify the fix** The documented address or mailbox scope matches what happens to every supported alias on both mail paths.
- **Proof test** none. The existing tests confirm exact-address suppression and the intentional separation of dot variants.
- **Suggested fix** Keep exact identity. Have the owner decide which proved delivery aliases share send controls or mailbox-level suppression, and describe the resulting promise precisely.

### 21. low: The runtime database role can perform administrator actions

- **Where** `supabase/migrations/0001_waitlist.sql:420`, `supabase/migrations/0005_send_safety_net.sql:357`, `supabase/migrations/0006_partner_applications.sql:190`, `supabase/functions/_shared/db.ts:4`, `tests/test_01_privileges.sql:20`.
- **What an attacker can do** If the trusted runtime database identity is compromised, it can export confirmed addresses, mint management credentials, erase arbitrary addresses, or change the sending pause. Forced RLS and table revokes protect direct table access. The wider permissions come from the explicit RPC grants to the runtime role.
- **How to verify the fix** The public-facing workload's database identity can call only the RPCs it requires. Owner-only export, manual erasure, and pause control remain restricted.
- **Proof test** none. The existing privilege test explicitly expects the broader list of RPC grants.
- **Suggested fix** Separate owner-only and scheduler privileges from public request handling, using narrower database identities or an equivalent enforcement boundary.

### 22. low: needs confirmation for timing of bearer comparisons

- **Where** `supabase/migrations/0001_waitlist.sql:335`, `supabase/migrations/0003_self_service_erase.sql:18`, `supabase/functions/_shared/svix.ts:15`, `supabase/functions/waitlist/handler.ts:197`.
- **What an attacker can do** SQL compares the fixed-format MAC with ordinary text equality. The scheduler's JavaScript comparison visits every byte up to the longer input, so its loop count depends on input lengths. Practical remote significance and key recovery remain unverified.
- **How to verify the fix** Bearer validation uses vetted fixed-length comparisons, with no match-dependent early return for well-formed credentials.
- **Proof test** none. Existing tests cover correctness and refusal of wrong-length keys.
- **Suggested fix** Use a vetted constant-time comparison over fixed-length token values or digests, and fix the scheduler credential format at generation.

### 23. low: Email normalization can accept non-ASCII input before the ASCII check

- **Where** `supabase/functions/_shared/validate.ts:16`, `supabase/migrations/0001_waitlist.sql:78`, `supabase/migrations/0004_mailbox_throttle.sql:39`.
- **What an attacker can do** Submit text that appears different from the ASCII address used for delivery. Lowercasing runs before the ASCII allowlist, so some Unicode characters can normalize to ASCII and pass. The DNS label check also permits ASCII-encoded internationalized labels under ordinary ASCII TLDs. These behaviors matter if the stated email policy is relied on to reject look-alike addresses. The same normalization still applies to the exact-address limits.
- **How to verify the fix** The original input meets the documented character policy before case conversion, and the treatment of encoded internationalized domains is explicit.
- **Proof test** none. The supplied Unicode cases test characters that the current checks already reject.
- **Suggested fix** Enforce the allowed input alphabet before lowercasing in both layers and explicitly decide how to handle internationalized domain labels.

### 24. low: Spreadsheet-safe export depends on a manual step

- **Where** `supabase/migrations/0001_waitlist.sql:383`, `supabase/migrations/0004_mailbox_throttle.sql:43`, `supabase/functions/_shared/csv.ts:5`, `docs/WAITLIST_SECURITY_GUIDE.md:486`.
- **What an attacker can do** Supply an otherwise accepted address starting with a spreadsheet formula marker. A raw SQL or dashboard export can carry that value to a spreadsheet. The repository's `toCsv()` helper neutralizes common markers and is currently called only from tests. Actual formula interpretation depends on the export path and spreadsheet application.
- **How to verify the fix** The owner's supported export path always opens applicant-controlled fields as text in the spreadsheet applications they use.
- **Proof test** none. The existing CSV test verifies the helper in isolation.
- **Suggested fix** Provide one supported owner export that always calls a spreadsheet-safe writer or uses typed text cells. Include partner fields if they are added to an export.

### 25. low: The CI site check can pass without Hostinger's header file

- **Where** `ci/check-site.sh:34`, `site/.htaccess:31`, `docs/WAITLIST_SECURITY_GUIDE.md:287`.
- **What an attacker can do** If a future release loses `.htaccess`, visitors can lose CSP, framing protections, canonical routing, and hidden-file restrictions while the repository site check still passes. The current checkout contains the file. Whether Hostinger has applied it is a deployment check.
- **How to verify the fix** The local site check fails if a Hostinger artifact lacks `.htaccess` or its required rules.
- **Proof test** none. The script validates `.htaccess` only inside an existence check.
- **Suggested fix** Require `.htaccess` in the checked Hostinger artifact and verify effective headers and routing during owner-controlled release validation.

### 26. low: needs confirmation for suppression after backup restore

- **Where** `docs/WAITLIST_SECURITY_GUIDE.md:371`, `supabase/migrations/0003_self_service_erase.sql:22`, `supabase/migrations/0001_waitlist.sql:383`.
- **What an attacker can do** This risk requires an owner restore. If the owner restores a database snapshot taken before an erasure, the older signup may return without its newer suppression, then become eligible for export. The repository keeps its erasure evidence in the same database.
- **How to verify the fix** A restore of an older synthetic snapshot preserves all erasures and suppressions that occurred after it, before sending or exporting is re-enabled.
- **Proof test** none. The repository supplies no backup fixture or restore workflow.
- **Suggested fix** Maintain a restricted, separately recoverable record of suppression changes and require reconciliation before resuming email after a restore.

### 27. info: Form attestations are soft controls

- **Where** `supabase/functions/waitlist/handler.ts:45`, `supabase/functions/waitlist/handler.ts:104`, `supabase/functions/_shared/http.ts:31`, `supabase/functions/_shared/turnstile.ts:29`.
- **What an attacker can do** Supply the claimed fill time, omit the honeypot, or falsely self-attest to age or consent. Origin restricts other browser sites. The honeypot and elapsed time deter basic form bots, while the server still requires an action-specific validated Turnstile result. Waitlist membership additionally requires mailbox confirmation.
- **How to verify the fix** Treat attestation and timing as soft signals in documentation and policy, and verify ownership or eligibility at the step that relies on it.
- **Proof test** none. The existing tests verify literal booleans and the intended soft-filter responses.
- **Suggested fix** Keep Turnstile server checks and bind partner consent to the verified applicant. Use the owner's required age verification standard before any age-restricted partnership activity.

## Attacks tried that FAILED (the defence held)

- Direct list export, signup, erasure, token minting, and queue RPC calls from browser roles returned permission errors in `tests/test_01_privileges.sql` and `tests/test_08_partner_queue.sql`.
- Direct table reads by `service_role` were blocked in the local database. Private tables had RLS enabled and forced, and the reviewed `SECURITY DEFINER` functions pinned an empty search path.
- Unknown fields, wrong content types, foreign origins, missing or non-true required checkboxes, and oversized bodies were rejected in the relevant Deno refusal cases.
- A foreign Turnstile hostname, the wrong action, and a verification outage were refused in the existing Deno tests. Real provider-side token reuse remains unverified.
- GET confirmation, unsubscribe, and erasure were refused. Source review found button-driven browser actions and removal of the visible URL fragments by script.
- Guessed, rotated, expired, and reused confirmation tokens were refused. Twenty parallel confirmations produced one consent event in `tests/race_parallel.sh`.
- A forged management credential and a valid credential for a different signup were refused in `tests/test_03_unsub_suppress.sql`.
- Pending, unsubscribed, and suppressed addresses were excluded from the confirmed export in `tests/test_03_unsub_suppress.sql`. Sequential exact-address suppression also blocked fresh signups and skipped queued mail.
- Fifty simultaneous submissions to one waitlist address produced one send claim. Waitlist plus-address variants shared a send cap and retained distinct identities.
- Thirty simultaneous partner submissions for one exact address produced one application and two send units. Ten parallel drains claimed each of thirty queued partner applications once.
- The existing ten-drain and thirty-resubmission waitlist case completed without deadlock and with one claim per queued person.
- CRLF, quoted or malformed email addresses, MIME encoded words, and the tested bidi and zero-width characters were refused. The CSV helper neutralized the tested leading formula characters.
- Applicant-entered text stayed out of the fixed acknowledgement. The owner HTML escaped injected markup in the Deno mail test.
- Wrong, missing, and unconfigured scheduler credentials produced a 404 and zero database calls.
- An unsigned webhook, a modified signed body, and an old signature were refused. A valid transient bounce fixture produced no suppression. The tested repeat suppression added no second count.
- Ordinary waitlist accept responses were byte-identical across new, existing, suppressed, limited, and bot fixtures. Provider delay did not change the mocked response latency.
- Source review found text-only DOM rendering, a fixed canonical redirect destination, strict CSP and framing headers, and a fixed homepage `mailto:` that opens the visitor's mail client. The offline static checks passed.
- Application errors and alerts in the exercised paths used fixed codes or counts. The source review found no application logging of raw bodies, email addresses, IPs, or tokens.
- Source and CI review found no IP-based logic, auto-confirm on load, single opt-in for the waitlist, analytics script, or CI agent wired to issue text. The partner mailbox finding above is a return of the subscription-bombing issue documented in the guide.

## Could not test locally (needs the live site or real Supabase)

- Effective Hostinger CSP, HTTPS and canonical redirects, clickjacking protection, hidden-file handling, and cache behavior on actual routes.
- Supabase gateway routing, buffering, limits, spend configuration, effective project roles and schema exposure, migration ownership, and real scheduler behavior.
- Turnstile's real token reuse behavior, deployment hostname restrictions, and how mail-link scanners interact with the deployed confirmation page.
- Resend event schemas and scoping, retention of idempotency keys, live rate limits, delivery results after transient failures, and mailbox client rendering.
- Redaction across gateway, scheduler, mail-provider, and access logs, particularly for the one-click query credential.
- Live agreement of consent versions and mail caps, enforcement of version-specific email scope in the owner's launch workflow, and recovery of suppression data after backups.

## Verdict: Safe to stay live: NO

A visitor can take someone else's partner application slot, and the mail worker can send after a deletion, suppression, or pause has taken effect.

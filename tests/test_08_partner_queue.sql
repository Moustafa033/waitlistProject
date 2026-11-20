-- =====================================================================
-- test_08: partner mail queue (0007). Every section performs the attack or the failure.
-- =====================================================================
update private.settings set value = '20'    where key = 'partner_per_day';
update private.settings set value = '500'   where key = 'global_sends_per_hour';
update private.settings set value = '90'    where key = 'global_sends_per_day';
update private.settings set value = '50'    where key = 'drain_batch';
update private.settings set value = 'false' where key = 'sending_paused';
delete from private.counters; delete from private.alerts; delete from private.partner_mail_queue;
delete from private.partner_applications; delete from private.suppressions; delete from private.send_queue;

create or replace function t.apply(p_email text)
returns jsonb language sql as $$
  select public.waitlist_partner_apply(p_email, 'Omar K', '[{"platform":"instagram","username":"omar.lifts"}]',
                                       'Coach with a small but loyal community.', 'partners-v1') $$;
grant execute on function t.apply(text) to service_role;

\echo '--- 0007: only the server can drain or requeue; nobody reads the queue'
set role anon;
select t.fails($$select public.waitlist_drain_partner_queue()$$, '42501', 'anon drains the partner queue');
select t.fails($$select public.waitlist_partner_requeue(gen_random_uuid())$$, '42501', 'anon requeues');
reset role;
set role authenticated;
select t.fails($$select public.waitlist_drain_partner_queue()$$, '42501', 'authenticated drains the partner queue');
reset role;
set role service_role;
select t.fails($$select * from private.partner_mail_queue$$, '42501', 'service_role cannot read the queue table directly');
reset role;
select t.ok(not exists (select 1 from information_schema.columns where table_schema = 'private' and table_name = 'partner_mail_queue'
                        and column_name not in ('application_id', 'queued_at')), 'the queue stores no copy of any personal data');

\echo '--- 0007: a full send cap QUEUES the emails instead of dropping them'
update private.settings set value = '0' where key = 'global_sends_per_hour';   -- no send unit left
set role service_role;
select t.ok((t.apply('q-a@example.com')->>'queued')::boolean, 'cap full -> application saved AND queued');
select t.ok((t.apply('q-b@example.com')->>'queued')::boolean, 'second one queued too');
reset role;
select t.ok((select count(*) from private.partner_mail_queue) = 2, 'two applications waiting');
select t.ok(coalesce((select used from private.counters where bucket = 'send_hour'), 0) = 0, 'no unit stays half-taken');
set role service_role;
select t.ok(jsonb_array_length(public.waitlist_drain_partner_queue()->'sends') = 0, 'cap still full -> drain sends nothing');
reset role;
select t.ok((select count(*) from private.partner_mail_queue) = 2, 'and both stay in the queue');

\echo '--- 0007: when room frees up the drain sends each application exactly once'
update private.settings set value = '500' where key = 'global_sends_per_hour';
set role service_role;
create temp table d1 as select public.waitlist_drain_partner_queue() j;
reset role;
select t.ok(jsonb_array_length((select j from d1)->'sends') = 2, 'next run -> both applications sent');
select t.ok(((select j from d1)->'sends'->0->>'email') = 'q-a@example.com', 'oldest first');
select t.ok(((select j from d1)->'sends'->0->>'kind') = 'confirm' and ((select j from d1)->'sends'->0->>'token') ~ '^[A-Za-z0-9_-]{43}$', 'a pending row is sent its confirmation link, with a fresh token');
select t.ok((select used from private.counters where bucket = 'send_hour') = 2, '1 unit per queued email');
set role service_role;
select t.ok(jsonb_array_length(public.waitlist_drain_partner_queue()->'sends') = 0, 'a second run sends nothing again');
reset role;
select t.ok((select count(*) from private.partner_mail_queue) = 0, 'queue empty');

\echo '--- 0007: provider down -> requeue; only existing applications; never twice in the queue'
create temp table qa as select id from private.partner_applications where email = 'q-a@example.com';
grant select on qa to service_role;
set role service_role;
select t.ok(public.waitlist_partner_requeue((select id from qa), (select e->>'token' from d1, jsonb_array_elements(j->'sends') e where e->>'email' = 'q-a@example.com')), 'requeue an existing application');
select t.ok(public.waitlist_partner_requeue((select id from qa), (select e->>'token' from d1, jsonb_array_elements(j->'sends') e where e->>'email' = 'q-a@example.com')), 'requeue again: still fine');
select t.ok(not public.waitlist_partner_requeue((select id from qa), repeat('Z', 43)), 'a retry that does not name the current link is refused');
select t.ok(not public.waitlist_partner_requeue((select id from qa)), 'a pending application cannot be requeued without its link');
select t.ok(not public.waitlist_partner_requeue(gen_random_uuid()), 'a made-up id is refused');
select t.ok(not public.waitlist_partner_requeue(null), 'null is refused');
reset role;
select t.ok((select count(*) from private.partner_mail_queue) = 1, 'queued once, not twice');
delete from private.partner_mail_queue;

\echo '--- 0007: kill switch -> saved + queued, drained only after resuming'
update private.settings set value = 'true' where key = 'sending_paused';
set role service_role;
select t.ok((t.apply('q-paused@example.com')->>'queued')::boolean, 'paused -> queued');
select t.ok(jsonb_array_length(public.waitlist_drain_partner_queue()->'sends') = 0, 'paused -> the drain sends nothing');
reset role;
update private.settings set value = 'false' where key = 'sending_paused';
set role service_role;
select t.ok(jsonb_array_length(public.waitlist_drain_partner_queue()->'sends') = 1, 'resumed -> sent');
reset role;

\echo '--- 0007: erased or bounced while waiting -> leaves the queue, never emailed'
update private.settings set value = '1' where key = 'global_sends_per_hour';
delete from private.counters where bucket = 'send_hour';
set role service_role;
select t.apply('q-erase@example.com'); select t.apply('q-bounce@example.com');
select public.waitlist_erase('q-erase@example.com');
reset role;
select t.ok(not exists (select 1 from private.partner_mail_queue q join private.partner_applications a on a.id = q.application_id
                        where a.email = 'q-erase@example.com'), 'erasure removes the queue entry with the application');
insert into private.suppressions(email_hash, reason) values (private.email_hash('q-bounce@example.com'), 'hard_bounce');
update private.settings set value = '500' where key = 'global_sends_per_hour';
set role service_role;
select t.ok(jsonb_array_length(public.waitlist_drain_partner_queue()->'sends') = 0, 'the bounced address is not emailed');
reset role;
select t.ok((select count(*) from private.partner_mail_queue) = 0, 'and it left the queue');

\echo '--- 0007: the queue is bounded; a full queue still saves the application'
update private.settings set value = '1' where key = 'partner_queue_max';
update private.settings set value = '0' where key = 'global_sends_per_hour';
set role service_role;
select t.ok((t.apply('q-full-1@example.com')->>'queued')::boolean, 'first fits');
select t.ok(not (t.apply('q-full-2@example.com')->>'queued')::boolean, 'queue full -> not queued');
reset role;
select t.ok(exists (select 1 from private.partner_applications where email = 'q-full-2@example.com'), 'but the application is saved (never lost)');
select t.ok((select hits from private.alerts where kind = 'partner_mail_skipped') >= 1, 'owner alert raised');

\echo '--- 0007: the drain respects drain_batch'
update private.settings set value = '1000' where key = 'partner_queue_max';
update private.settings set value = '500'  where key = 'global_sends_per_hour';
update private.settings set value = '2'    where key = 'drain_batch';
delete from private.partner_mail_queue;
insert into private.partner_mail_queue(application_id) select id from private.partner_applications;
set role service_role;
select t.ok(jsonb_array_length(public.waitlist_drain_partner_queue()->'sends') = 2, 'at most drain_batch per run');
reset role;
update private.settings set value = '50' where key = 'drain_batch';

drop function t.apply(text);
delete from private.counters; delete from private.alerts; delete from private.partner_mail_queue; delete from private.suppressions;
update private.settings set value = '1000' where key = 'partner_queue_max';

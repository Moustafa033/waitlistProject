-- =====================================================================
-- test_11: fixes from the Codex re-check (reviews/codex-recheck.md), all in 0009.
-- =====================================================================
update private.settings set value = '20'    where key = 'partner_per_day';
update private.settings set value = '500'   where key = 'global_sends_per_hour';
update private.settings set value = '90'    where key = 'global_sends_per_day';
update private.settings set value = '30'    where key = 'mailbox_sends_per_day';
update private.settings set value = '0'     where key = 'resend_min_minutes';
update private.settings set value = '3'     where key = 'partner_max_confirm_sends';
update private.settings set value = '1000'  where key = 'partner_queue_max';
update private.settings set value = 'false' where key = 'sending_paused';
delete from private.counters; delete from private.alerts; delete from private.partner_mail_queue;
delete from private.partner_applications; delete from private.suppressions;

create or replace function t.apply(p_email text, p_name text default 'Real Person')
returns jsonb language sql as $$
  select public.waitlist_partner_apply(p_email, p_name, '[{"platform":"instagram","username":"real.person"}]',
                                       'I coach 30 people and post daily workouts.', 'partners-v1') $$;
grant execute on function t.apply(text, text) to service_role;

\echo '--- R1: an earlier link can NEVER approve replacement details (even when the new link is only queued)'
set role service_role;
create temp table r1a as select t.apply('r1@example.com', 'Original Person') j;
reset role;
grant select on r1a to service_role;
update private.settings set value = 'true' where key = 'sending_paused';      -- the replacement link will only be queued
set role service_role;
select t.ok((t.apply('r1@example.com', 'Replacement Person')->>'action') = 'saved', 'replacement while paused -> stored + queued');
reset role;
select t.ok((select confirm_token_hash is null from private.partner_applications where email = 'r1@example.com'),
  'replacing the details killed the old link at once');
set role service_role;
select t.ok(not (public.waitlist_partner_confirm((select j->>'token' from r1a))->>'ok')::boolean,
  'the ORIGINAL link cannot approve the REPLACEMENT details');
reset role;
select t.ok((select status from private.partner_applications where email = 'r1@example.com') = 'pending', 'still pending');
update private.settings set value = 'false' where key = 'sending_paused';

\echo '--- R4: a live send removes the older queue entry (no second link from the queue)'
select t.ok(exists (select 1 from private.partner_mail_queue q join private.partner_applications a on a.id = q.application_id
                    where a.email = 'r1@example.com'), 'r1 is waiting in the queue');
set role service_role;
select t.ok((t.apply('r1@example.com', 'Replacement Person')->>'action') = 'send', 'applying again live -> a fresh link now');
reset role;
select t.ok(not exists (select 1 from private.partner_mail_queue q join private.partner_applications a on a.id = q.application_id
                        where a.email = 'r1@example.com'), 'the old queue entry is gone');

\echo '--- R5: the mailbox allowance is charged on the day the queued email really goes out'
update private.settings set value = '1' where key = 'mailbox_sends_per_day';
update private.settings set value = '0' where key = 'global_sends_per_hour';
delete from private.counters;
set role service_role;
select t.ok((t.apply('r5+p@example.com')->>'action') = 'saved', 'cap full -> queued');
reset role;
select t.ok(not exists (select 1 from private.counters where bucket like 'send_mbx:%' and used > 0),
  'a queued link does not hold the mailbox allowance (given back)');
-- the same inbox gets its one email of the day from the waitlist meanwhile
update private.settings set value = '500' where key = 'global_sends_per_hour';
set role service_role;
select public.waitlist_signup('r5+w@example.com', 'waitlist-v1');
select t.ok(jsonb_array_length(public.waitlist_drain_partner_queue()->'sends') = 0, 'inbox already had its email today -> the queued link waits');
reset role;
select t.ok(exists (select 1 from private.partner_mail_queue q join private.partner_applications a on a.id = q.application_id
                    where a.email = 'r5+p@example.com'), 'still in the queue (sent on a later day), not dropped');
update private.settings set value = '30' where key = 'mailbox_sends_per_day';
delete from private.counters where bucket like 'send_mbx:%';                 -- "the next day"
set role service_role;
select t.ok((select e->>'email' from jsonb_array_elements(public.waitlist_drain_partner_queue()->'sends') e limit 1) = 'r5+p@example.com',
  'next day -> sent');
reset role;

\echo '--- R6: a confirmed application whose owner notice cannot be queued raises queue_full'
set role service_role;
create temp table r6 as select t.apply('r6@example.com') j;
reset role;
grant select on r6 to service_role;
update private.settings set value = '0' where key = 'global_sends_per_hour';
update private.settings set value = '0' where key = 'partner_queue_max';
delete from private.alerts;
set role service_role;
select t.ok((public.waitlist_partner_confirm((select j->>'token' from r6))->>'ok')::boolean, 'confirmed');
reset role;
select t.ok(exists (select 1 from private.alerts where kind = 'queue_full'), 'queue_full alert raised: the owner is told');
select t.ok((select status from private.partner_applications where email = 'r6@example.com') = 'confirmed', 'the application is in the database');
update private.settings set value = '500'  where key = 'global_sends_per_hour';
update private.settings set value = '1000' where key = 'partner_queue_max';

\echo '--- R7: the 48 h deadline holds for queued rows; an unsent link does not count'
update private.settings set value = '0' where key = 'global_sends_per_hour';
set role service_role;
select t.apply('r7-old@example.com');
reset role;
update private.partner_applications set created_at = now() - interval '49 hours' where email = 'r7-old@example.com';
update private.settings set value = '500' where key = 'global_sends_per_hour';
set role service_role;
select t.ok(not exists (select 1 from jsonb_array_elements(public.waitlist_drain_partner_queue()->'sends') e
                        where e->>'email' = 'r7-old@example.com'), 'past the deadline -> no new link');
reset role;
select t.ok(not exists (select 1 from private.partner_applications where email = 'r7-old@example.com'), 'and the application is deleted');
-- cleanup no longer exempts queued rows
update private.settings set value = '0' where key = 'global_sends_per_hour';
set role service_role;
select t.apply('r7-q@example.com');
reset role;
update private.partner_applications set created_at = now() - interval '49 hours' where email = 'r7-q@example.com';
set role service_role;
select public.waitlist_maintenance();
reset role;
select t.ok(not exists (select 1 from private.partner_applications where email = 'r7-q@example.com'), 'maintenance deletes it even though queued');
update private.settings set value = '500' where key = 'global_sends_per_hour';
-- a link that never reached the provider (requeue) gives its attempt back
set role service_role;
create temp table r7r as select t.apply('r7-retry@example.com') j;
reset role;
grant select on r7r to service_role;
set role service_role;
select t.ok(public.waitlist_partner_requeue((select (j->>'id')::uuid from r7r)), 'provider down -> requeued');
reset role;
select t.ok((select confirm_sends = 0 and confirm_token_hash is null and last_confirm_sent_at is null
             from private.partner_applications where email = 'r7-retry@example.com'),
  'the unsent link does not count, and it cannot be used');

\echo '--- #2: the send-time check'
insert into private.suppressions(email_hash, reason) values (private.email_hash('gone2@example.com'), 'erasure');
set role service_role;
select t.ok(public.waitlist_send_allowed('fine@example.com') = 'ok', 'normal address -> ok');
select t.ok(public.waitlist_send_allowed('gone2@example.com') = 'suppressed', 'deleted address -> suppressed');
reset role;
update private.settings set value = 'true' where key = 'sending_paused';
set role service_role;
select t.ok(public.waitlist_send_allowed('fine@example.com') = 'paused', 'kill switch on -> paused');
reset role;
update private.settings set value = 'false' where key = 'sending_paused';
set role anon;
select t.fails($$select public.waitlist_send_allowed('a@example.com')$$, '42501', 'anon cannot use the check (no address probing)');
reset role;

drop function t.apply(text, text);
delete from private.counters; delete from private.alerts; delete from private.partner_mail_queue; delete from private.suppressions;
update private.settings set value = '30' where key = 'resend_min_minutes';
update private.settings set value = '3'  where key = 'mailbox_sends_per_day';

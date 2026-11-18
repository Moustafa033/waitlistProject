-- =====================================================================
-- test_09: fixes from the Codex security audit (0008). Each section performs the attack.
-- =====================================================================
update private.settings set value = '20'    where key = 'partner_per_day';
update private.settings set value = '500'   where key = 'global_sends_per_hour';
update private.settings set value = '90'    where key = 'global_sends_per_day';
update private.settings set value = '3'     where key = 'mailbox_sends_per_day';
update private.settings set value = 'false' where key = 'sending_paused';
delete from private.counters; delete from private.alerts; delete from private.partner_mail_queue;
delete from private.partner_applications; delete from private.suppressions;

create or replace function t.apply(p_email text)
returns jsonb language sql as $$
  select public.waitlist_partner_apply(p_email, 'Omar K', '[{"platform":"instagram","username":"omar.lifts"}]',
                                       'Coach with a small but loyal community.', 'partners-v1') $$;
grant execute on function t.apply(text) to service_role;

\echo '--- audit #3: +tag variants of ONE inbox cannot each get an acknowledgement (inbox bombing)'
set role service_role;
select t.ok(t.apply('victim+1@example.com')->>'action' = 'send', '+1 -> sent (1/3 for that inbox today)');
select t.ok(t.apply('victim+2@example.com')->>'action' = 'send', '+2 -> sent (2/3)');
select t.ok(t.apply('victim+3@example.com')->>'action' = 'send', '+3 -> sent (3/3)');
select t.ok(t.apply('victim+4@example.com')->>'reason' = 'mailbox_cap', '+4 -> refused: that inbox had its emails for today');
select t.ok(t.apply('victim@example.com')->>'reason' = 'mailbox_cap', 'the plain address shares the same inbox cap');
reset role;
select t.ok(not exists (select 1 from private.partner_applications where email in ('victim+4@example.com', 'victim@example.com')),
  'refused tries are not stored (the real person can still apply tomorrow)');
select t.ok((select used from private.counters where bucket = 'partner_day') = 3, 'refused tries do not use the daily application cap');
set role service_role;
select t.ok(t.apply('other@example.com')->>'action' = 'send', 'a different inbox is not affected');
reset role;
-- the cap is shared with waitlist confirmations: both streams count against one inbox
delete from private.counters;
set role service_role;
select public.waitlist_signup('shared+w1@example.com', 'waitlist-v1');
select public.waitlist_signup('shared+w2@example.com', 'waitlist-v1');
select public.waitlist_signup('shared+w3@example.com', 'waitlist-v1');
select t.ok(t.apply('shared+p1@example.com')->>'reason' = 'mailbox_cap', '3 waitlist emails to an inbox today -> no partner email on top');
reset role;

\echo '--- audit #5: a full day answers "busy" for EVERY address (no leak of who applied or was deleted)'
delete from private.counters;
update private.settings set value = '1' where key = 'partner_per_day';
insert into private.suppressions(email_hash, reason) values (private.email_hash('deleted@example.com'), 'erasure');
set role service_role;
select t.ok(t.apply('fills-the-day@example.com')->>'action' = 'send', 'the only slot today is used');
select t.ok(t.apply('brand-new@example.com')->>'reason' = 'busy', 'new address -> busy');
select t.ok(t.apply('other@example.com')->>'reason' = 'busy', 'already applied -> ALSO busy (before 0008: a revealing "thanks")');
select t.ok(t.apply('deleted@example.com')->>'reason' = 'busy', 'deleted address -> ALSO busy');
reset role;
update private.settings set value = '20' where key = 'partner_per_day';

\echo '--- audit #11: erasure still does the right thing with the new lock order'
delete from private.counters;
set role service_role;
select t.ok(t.apply('erase-me@example.com')->>'action' = 'send', 'applied');
select public.waitlist_signup('erase-me@example.com', 'waitlist-v1');
select public.waitlist_erase('erase-me@example.com');
reset role;
select t.ok(not exists (select 1 from private.signups where email = 'erase-me@example.com')
            and not exists (select 1 from private.partner_applications where email = 'erase-me@example.com')
            and exists (select 1 from private.suppressions where email_hash = private.email_hash('erase-me@example.com')),
  'owner erasure: signup and application gone, do-not-email entry written');
set role service_role;
select public.waitlist_signup('self-erase@example.com', 'waitlist-v1');
select t.ok(t.apply('self-erase@example.com')->>'action' = 'send', 'the same person also applied as a partner');
reset role;
create temp table se as select id, public.waitlist_unsub_token(id) tok from private.signups where email = 'self-erase@example.com';
grant select on se to service_role;
set role service_role;
select t.ok((public.waitlist_erase_by_token((select id from se), (select tok from se))->>'ok')::boolean, '"Delete my data" link works');
select t.ok(not (public.waitlist_erase_by_token((select id from se), repeat('A', 43))->>'ok')::boolean, 'a wrong token is still refused');
reset role;
select t.ok(not exists (select 1 from private.signups where email = 'self-erase@example.com')
            and not exists (select 1 from private.partner_applications where email = 'self-erase@example.com'),
  '"Delete my data" now also deletes the partner application of that address');
select t.ok(exists (select 1 from private.suppressions where email_hash = private.email_hash('self-erase@example.com') and reason = 'erasure'),
  'and writes the do-not-email entry');

\echo '--- audit #15: the partner queue cap holds (admission is serialised)'
update private.settings set value = '2' where key = 'partner_queue_max';
delete from private.partner_mail_queue;
create temp table ids as select id from private.partner_applications limit 4;
grant select on ids to service_role;
set role service_role;
select t.ok((select count(*) filter (where public.waitlist_partner_requeue(id)) from ids) = 2, 'only 2 of 4 requeues admitted (cap 2)');
reset role;
select t.ok((select count(*) from private.partner_mail_queue) = 2, 'queue holds exactly the cap');
update private.settings set value = '1000' where key = 'partner_queue_max';

drop function t.apply(text);
delete from private.counters; delete from private.alerts; delete from private.partner_mail_queue; delete from private.suppressions;

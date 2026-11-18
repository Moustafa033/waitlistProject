-- =====================================================================
-- test_10: partner applications need a confirmed email (0009, Codex audit #1).
-- =====================================================================
update private.settings set value = '20'    where key = 'partner_per_day';
update private.settings set value = '500'   where key = 'global_sends_per_hour';
update private.settings set value = '90'    where key = 'global_sends_per_day';
update private.settings set value = '30'    where key = 'mailbox_sends_per_day';
update private.settings set value = '30'    where key = 'resend_min_minutes';
update private.settings set value = '3'     where key = 'partner_max_confirm_sends';
update private.settings set value = 'false' where key = 'sending_paused';
delete from private.counters; delete from private.alerts; delete from private.partner_mail_queue;
delete from private.partner_applications; delete from private.suppressions;

create or replace function t.apply(p_email text, p_name text default 'Real Person')
returns jsonb language sql as $$
  select public.waitlist_partner_apply(p_email, p_name, '[{"platform":"instagram","username":"real.person"}]',
                                       'I coach 30 people and post daily workouts.', 'partners-v1') $$;
grant execute on function t.apply(text, text) to service_role;

\echo '--- 0009: only the server can confirm'
set role anon;
select t.fails($$select public.waitlist_partner_confirm(repeat('A', 43))$$, '42501', 'anon calls partner_confirm directly');
reset role;
set role authenticated;
select t.fails($$select public.waitlist_partner_confirm(repeat('A', 43))$$, '42501', 'authenticated calls partner_confirm directly');
reset role;

\echo '--- 0009: apply -> pending; the owner is NOT told and the slot is NOT used until confirmed'
set role service_role;
create temp table a1 as select t.apply('real@example.com') j;
reset role;
grant select on a1 to service_role;
select t.ok((select j->>'kind' from a1) = 'confirm' and (select j->>'token' from a1) ~ '^[A-Za-z0-9_-]{43}$', 'apply returns a confirmation link token');
select t.ok((select status from private.partner_applications where email = 'real@example.com') = 'pending', 'stored as pending');
select t.ok((select confirm_token_hash from private.partner_applications where email = 'real@example.com')
            = private.token_hash((select j->>'token' from a1)), 'only the HASH of the token is stored');
select t.ok(not exists (select 1 from information_schema.columns where table_schema = 'private'
                        and table_name = 'partner_applications' and column_name = 'confirm_token'), 'no plain token column');

\echo '--- 0009: confirm works once, with the right token only'
set role service_role;
select t.ok(not (public.waitlist_partner_confirm(repeat('A', 43))->>'ok')::boolean, 'a guessed token is refused');
select t.ok(not (public.waitlist_partner_confirm('short')->>'ok')::boolean, 'a malformed token is refused');
select t.ok(not (public.waitlist_partner_confirm(null)->>'ok')::boolean, 'null is refused');
create temp table c1 as select public.waitlist_partner_confirm((select j->>'token' from a1)) j;
reset role;
select t.ok((select (j->>'ok')::boolean and j->>'action' = 'send' from c1), 'the real token confirms');
select t.ok((select j->>'email' from c1) = 'real@example.com' and (select j->>'name' from c1) = 'Real Person',
  'the owner notice gets the details now (and only now)');
select t.ok((select status from private.partner_applications where email = 'real@example.com') = 'confirmed', 'status confirmed');
select t.ok((select confirm_token_hash is null from private.partner_applications where email = 'real@example.com'), 'token cleared');
set role service_role;
select t.ok(not (public.waitlist_partner_confirm((select j->>'token' from a1))->>'ok')::boolean, 'the same link a second time -> refused (single use)');
select t.ok(t.apply('real@example.com')->>'reason' = 'already_applied', 'a confirmed address cannot apply again');
reset role;

\echo '--- 0009 / audit #1: someone using a victim''s address cannot take the victim''s slot'
update private.settings set value = '0' where key = 'resend_min_minutes';
set role service_role;
create temp table atk as select t.apply('victim2@example.com', 'Fake Attacker') j;
reset role;
grant select on atk to service_role;
select t.ok((select status from private.partner_applications where email = 'victim2@example.com') = 'pending', 'the fake application is only pending');
set role service_role;
create temp table vic as select t.apply('victim2@example.com', 'Real Victim') j;
reset role;
grant select on vic to service_role;
select t.ok((select j->>'action' from vic) = 'send', 'the REAL person applies too -> gets their own confirmation link');
select t.ok((select name from private.partner_applications where email = 'victim2@example.com') = 'Real Victim', 'the newest details replace the fake ones');
set role service_role;
select t.ok(not (public.waitlist_partner_confirm((select j->>'token' from atk))->>'ok')::boolean, 'the older link no longer works');
select t.ok((public.waitlist_partner_confirm((select j->>'token' from vic))->>'name') = 'Real Victim', 'the real person confirms their own details');
reset role;

\echo '--- 0009: links are bounded per address; an unconfirmed row expires and frees the address'
set role service_role;
select t.ok(t.apply('spammed@example.com')->>'action' = 'send', 'link 1');
select t.ok(t.apply('spammed@example.com')->>'action' = 'send', 'link 2');
select t.ok(t.apply('spammed@example.com')->>'action' = 'send', 'link 3');
select t.ok(t.apply('spammed@example.com')->>'reason' = 'address_cap', 'link 4 -> refused (max 3 per pending application)');
reset role;
update private.partner_applications set last_confirm_sent_at = now() - interval '49 hours', created_at = now() - interval '49 hours'
 where email = 'spammed@example.com';
set role service_role;
select t.ok((public.waitlist_maintenance()->>'partner_unconfirmed_deleted')::int >= 1, 'maintenance deletes the expired unconfirmed application');
select t.ok(t.apply('spammed@example.com')->>'action' = 'send', 'the address can apply again afterwards');
reset role;
update private.settings set value = '30' where key = 'resend_min_minutes';

\echo '--- 0009: an expired link and a suppressed address are refused'
set role service_role;
create temp table ex as select t.apply('expired@example.com') j;
reset role;
grant select on ex to service_role;
update private.partner_applications set confirm_expires_at = now() - interval '1 minute' where email = 'expired@example.com';
set role service_role;
select t.ok(not (public.waitlist_partner_confirm((select j->>'token' from ex))->>'ok')::boolean, 'expired link refused');
create temp table sp as select t.apply('bounced@example.com') j;
reset role;
grant select on sp to service_role;
insert into private.suppressions(email_hash, reason) values (private.email_hash('bounced@example.com'), 'hard_bounce');
set role service_role;
select t.ok(not (public.waitlist_partner_confirm((select j->>'token' from sp))->>'ok')::boolean, 'confirming a suppressed address is refused');
reset role;
select t.ok((select status from private.partner_applications where email = 'bounced@example.com') = 'pending', 'it stays unconfirmed');

\echo '--- 0009: owner notice queued when the send cap is full at confirm time, then drained'
set role service_role;
create temp table qn as select t.apply('queued-owner@example.com') j;
reset role;
grant select on qn to service_role;
update private.settings set value = '0' where key = 'global_sends_per_hour';
set role service_role;
select t.ok((public.waitlist_partner_confirm((select j->>'token' from qn))->>'action') = 'queued', 'cap full -> confirmed, owner notice queued');
reset role;
select t.ok((select status from private.partner_applications where email = 'queued-owner@example.com') = 'confirmed', 'the application counts already');
update private.settings set value = '500' where key = 'global_sends_per_hour';
set role service_role;
create temp table dq as select public.waitlist_drain_partner_queue() j;
reset role;
select t.ok((select e->>'kind' from dq, jsonb_array_elements(j->'sends') e where e->>'email' = 'queued-owner@example.com') = 'owner',
  'the drain sends the OWNER notice for a confirmed row (not another link)');

drop function t.apply(text, text);
delete from private.counters; delete from private.alerts; delete from private.partner_mail_queue; delete from private.suppressions;
update private.settings set value = '3' where key = 'mailbox_sends_per_day';

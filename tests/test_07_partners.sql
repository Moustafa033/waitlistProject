-- =====================================================================
-- test_07: partner applications (0006). Every section performs the attack.
-- =====================================================================
update private.settings set value = '20'    where key = 'partner_per_day';
update private.settings set value = '500'   where key = 'global_sends_per_hour';
update private.settings set value = '90'    where key = 'global_sends_per_day';
update private.settings set value = 'false' where key = 'sending_paused';
delete from private.counters; delete from private.alerts; delete from private.partner_applications; delete from private.suppressions;

create or replace function t.apply(p_email text, p_name text default 'Sara Ali',
  p_handles jsonb default '[{"platform":"tiktok","username":"@sara.fit"}]',
  p_pitch text default 'Personal trainer, 20k followers, 2 reviews a month.', p_ver text default 'partners-v1')
returns jsonb language sql as $$ select public.waitlist_partner_apply(p_email, p_name, p_handles, p_pitch, p_ver) $$;
grant execute on function t.apply(text, text, jsonb, text, text) to service_role;

\echo '--- 0006: only the server can apply; nobody can read applications'
set role anon;
select t.fails($$select public.waitlist_partner_apply('a@example.com','A','[]','xxxxxxxxxx','partners-v1')$$, '42501', 'anon calls partner_apply directly');
select t.fails($$select * from private.partner_applications$$, '42501', 'anon reads applications');
reset role;
set role authenticated;
select t.fails($$select public.waitlist_partner_apply('a@example.com','A','[]','xxxxxxxxxx','partners-v1')$$, '42501', 'authenticated calls partner_apply directly');
reset role;
set role service_role;
select t.fails($$select * from private.partner_applications$$, '42501', 'even service_role cannot read applications (RPC only)');
select t.fails($$delete from private.partner_applications$$, '42501', 'service_role cannot delete applications directly');
reset role;

\echo '--- 0006: one application per address, EVER'
set role service_role;
select t.ok(t.apply('partner-1@example.com')->>'action' = 'send', 'first application -> saved + 2 emails');
select t.ok(t.apply('partner-1@example.com')->>'reason' = 'already_applied', 'second try, same address -> nothing');
select t.ok(t.apply('  Partner-1@Example.COM ')->>'reason' = 'already_applied', 'case/space tricks are the same address');
select t.ok(t.apply('partner-1@example.com', 'Other Name', '[{"platform":"youtube","username":"other"}]', 'Completely different text here')->>'reason' = 'already_applied',
  'different details, same address -> still refused');
reset role;
select t.ok((select count(*) from private.partner_applications where email = 'partner-1@example.com') = 1, 'exactly one row for that address');
select t.ok((select used from private.counters where bucket = 'send_hour') = 2, 'only the first try took send units (2: applicant + owner)');
select t.ok((select used from private.counters where bucket = 'partner_day') = 1, 'repeats do not use the daily application cap');
-- an application does NOT put anyone on the waitlist
select t.ok(not exists (select 1 from private.signups where email = 'partner-1@example.com'), 'applying never adds the address to the waitlist');

\echo '--- 0006: bad input is refused, never cleaned or stored'
set role service_role;
select t.ok(t.apply('bad-1@example.com', 'Click http://spam.example')->>'reason' = 'invalid_fields', 'link in the name refused');
select t.ok(t.apply('bad-2@example.com', 'www.spam.com')->>'reason' = 'invalid_fields', 'www in the name refused');
select t.ok(t.apply('bad-3@example.com', 'a@b.com')->>'reason' = 'invalid_fields', 'email address as a name refused');
select t.ok(t.apply('bad-4@example.com', '<b>x</b>')->>'reason' = 'invalid_fields', 'markup in the name refused');
select t.ok(t.apply('bad-5@example.com', 'Sara' || chr(8203) || 'Ali')->>'reason' = 'invalid_fields', 'zero-width character in the name refused');
select t.ok(t.apply('bad-6@example.com', 'Sara' || chr(8238) || 'ilA')->>'reason' = 'invalid_fields', 'bidi override in the name refused');
select t.ok(t.apply('bad-7@example.com', repeat('a', 81))->>'reason' = 'invalid_fields', 'name over 80 characters refused');
select t.ok(t.apply('bad-8@example.com', ' Sara ')->>'reason' = 'invalid_fields', 'untrimmed name refused (the function trims first)');
select t.ok(t.apply('ok-ar@example.com', 'سارة علي')->>'action' = 'send', 'a name in Arabic is fine');
select t.ok(t.apply('bad-9@example.com', p_handles => '[]')->>'reason' = 'invalid_fields', 'no social account refused');
select t.ok(t.apply('bad-10@example.com', p_handles => '[{"platform":"tiktok","username":"a"},{"platform":"x","username":"b"},{"platform":"youtube","username":"c"},{"platform":"facebook","username":"d"}]')->>'reason' = 'invalid_fields',
  'more than 3 accounts refused');
select t.ok(t.apply('bad-11@example.com', p_handles => '[{"platform":"myspace","username":"a"}]')->>'reason' = 'invalid_fields', 'unknown platform refused');
select t.ok(t.apply('bad-12@example.com', p_handles => '[{"platform":"tiktok","username":"https://evil.example"}]')->>'reason' = 'invalid_fields', 'a link as username refused');
select t.ok(t.apply('bad-13@example.com', p_handles => '[{"platform":"tiktok","username":"a","extra":"x"}]')->>'reason' = 'invalid_fields', 'extra keys refused');
select t.ok(t.apply('bad-14@example.com', p_handles => '{"platform":"tiktok","username":"a"}')->>'reason' = 'invalid_fields', 'not an array refused');
select t.ok(t.apply('bad-15@example.com', p_pitch => 'too short')->>'reason' = 'invalid_fields', 'pitch under 10 characters refused');
select t.ok(t.apply('bad-16@example.com', p_pitch => repeat('x', 1001))->>'reason' = 'invalid_fields', 'pitch over 1000 characters refused');
select t.ok(t.apply('bad-17@example.com', p_pitch => 'hello there' || chr(8203) || ' friend')->>'reason' = 'invalid_fields', 'hidden character in the pitch refused');
select t.ok(t.apply('bad-18@example.com', p_pitch => 'hello there' || chr(13) || chr(10) || 'friend')->>'reason' = 'invalid_fields', 'carriage return in the pitch refused (the function sends LF only)');
select t.ok(t.apply('ok-nl@example.com', p_pitch => 'line one here' || chr(10) || 'line two')->>'action' = 'send', 'normal line breaks in the pitch are fine');
select t.ok(t.apply('not-an-email')->>'reason' = 'invalid_email', 'invalid email refused');
select t.ok(t.apply('evil@example.com' || chr(10) || 'bcc:x@y.com')->>'reason' = 'invalid_email', 'header injection in the email refused');
select t.ok(t.apply('old@example.com', p_ver => 'partners-v0')->>'reason' = 'stale_consent_version', 'old page version refused');
reset role;
select t.ok(not exists (select 1 from private.partner_applications where email like 'bad-%' or email in ('old@example.com')), 'none of the refused tries was stored');

\echo '--- 0006: deleted / bounced addresses are never stored or emailed'
insert into private.suppressions(email_hash, reason) values (private.email_hash('gone@example.com'), 'erasure');
set role service_role;
select t.ok(t.apply('gone@example.com')->>'reason' = 'suppressed', 'an erased address cannot apply again');
reset role;
select t.ok(not exists (select 1 from private.partner_applications where email = 'gone@example.com'), 'nothing stored for it');

\echo '--- 0006: daily application cap (stops flooding the table)'
update private.settings set value = '5' where key = 'partner_per_day';
delete from private.counters where bucket = 'partner_day';
set role service_role;
select t.ok((select count(*) from generate_series(1, 5) i where t.apply('cap-' || i || '@example.com')->>'action' = 'send') = 5, '5 applications fill the cap');
select t.ok(t.apply('cap-6@example.com')->>'reason' = 'busy', 'the 6th today -> busy');
reset role;
select t.ok(not exists (select 1 from private.partner_applications where email = 'cap-6@example.com'), 'the refused one was not stored');
update private.settings set value = '20' where key = 'partner_per_day';

\echo '--- 0006: full send cap or kill switch -> saved without email, owner alerted'
update private.settings set value = '1' where key = 'global_sends_per_hour';
delete from private.counters where bucket in ('send_hour', 'partner_day'); delete from private.alerts;
set role service_role;
select t.ok(t.apply('cap-mail@example.com')->>'action' = 'saved', 'only 1 send unit left (needs 2) -> saved, no email');
reset role;
select t.ok(coalesce((select used from private.counters where bucket = 'send_hour'), 0) = 0, 'the half-taken unit was given back');
select t.ok(exists (select 1 from private.partner_applications where email = 'cap-mail@example.com'), 'the application is not lost');
select t.ok((select hits from private.alerts where kind = 'partner_mail_skipped') = 1, 'owner alert raised');
update private.settings set value = '500' where key = 'global_sends_per_hour';
update private.settings set value = 'true' where key = 'sending_paused';
set role service_role;
select t.ok(t.apply('paused@example.com')->>'action' = 'saved', 'sending paused -> saved, no email');
reset role;
update private.settings set value = 'false' where key = 'sending_paused';

\echo '--- 0006: erasure and retention'
set role service_role;
select public.waitlist_erase('partner-1@example.com');
reset role;
select t.ok(not exists (select 1 from private.partner_applications where email = 'partner-1@example.com'), 'owner erasure deletes the application');
set role service_role;
select t.ok(t.apply('partner-1@example.com')->>'reason' = 'suppressed', 'and it can never be re-sent after erasure');
reset role;
update private.partner_applications set created_at = now() - interval '366 days' where email = 'ok-nl@example.com';
set role service_role;
select t.ok((public.waitlist_maintenance()->>'partner_deleted')::int = 1, 'maintenance deletes applications older than 365 days');
reset role;
select t.ok(not exists (select 1 from private.partner_applications where email = 'ok-nl@example.com'), 'the old one is gone');
select t.ok(exists (select 1 from private.partner_applications where email = 'ok-ar@example.com'), 'recent ones are kept');

drop function t.apply(text, text, jsonb, text, text);
delete from private.counters; delete from private.alerts; delete from private.suppressions;

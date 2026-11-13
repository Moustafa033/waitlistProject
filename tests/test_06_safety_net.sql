\echo '--- 0005: a full global cap QUEUES real people instead of dropping them'
update private.settings set value = '3'    where key = 'mailbox_sends_per_day';
update private.settings set value = '2'    where key = 'global_sends_per_hour';
update private.settings set value = '90'   where key = 'global_sends_per_day';
update private.settings set value = '30'   where key = 'resend_min_minutes';
update private.settings set value = 'false' where key = 'sending_paused';
delete from private.counters; delete from private.alerts; delete from private.send_queue;
delete from private.suppressions; delete from private.signups;
set role service_role;

select t.ok(public.waitlist_signup('q1@example.com','waitlist-v1')->>'action' = 'send', 'q1 sends (1/2 this hour)');
select t.ok(public.waitlist_signup('q2@example.com','waitlist-v1')->>'action' = 'send', 'q2 sends (2/2 this hour)');
select t.ok((public.waitlist_signup('q3@example.com','waitlist-v1')->>'queued')::boolean, 'q3 hits the hourly cap -> queued, not lost');
select t.ok((public.waitlist_signup('q4@example.com','waitlist-v1')->>'queued')::boolean, 'q4 queued too');
-- signing up again while queued does not create a second queue entry
select t.ok((public.waitlist_signup('q3@example.com','waitlist-v1')->>'queued')::boolean, 'q3 again -> still just queued once');
reset role;
select t.ok((select count(*) from private.send_queue) = 2, 'exactly 2 people in the queue');
select t.ok(not exists (select 1 from private.send_queue q join private.signups s on s.id = q.signup_id where s.confirm_sends > 0),
  'queued people were NOT emailed yet');
select t.ok((select hits from private.alerts where kind = 'global_send_cap') = 3, 'one alert row for this hour, 3 hits');
select t.ok(not exists (select 1 from information_schema.columns where table_schema = 'private' and table_name = 'send_queue' and column_name like '%email%'),
  'the queue stores no copy of the address');

\echo '--- 0005: the drain respects the same caps and sends when room frees up'
set role service_role;
select t.ok(jsonb_array_length(public.waitlist_drain_queue()->'sends') = 0, 'cap still full -> drain sends nobody');
reset role;
delete from private.counters where bucket = 'send_hour';   -- "the next hour"
set role service_role;
select t.ok(jsonb_array_length(public.waitlist_drain_queue()->'sends') = 2, 'next hour -> drain sends both queued people');
select t.ok((public.waitlist_drain_queue()->>'left')::int = 0, 'queue is empty afterwards');
reset role;
select t.ok((select confirm_sends from private.signups where email = 'q3@example.com') = 1, 'q3 got exactly ONE email (no double send)');
select t.ok(exists (select 1 from private.consent_events e join private.signups s on s.id = e.signup_id
                    where s.email = 'q4@example.com' and e.detail->>'source' = 'queue'), 'the queued send is in the consent log');

\echo '--- 0005: the queue is never a way around per-address / per-mailbox limits'
update private.settings set value = '500' where key = 'global_sends_per_hour';
delete from private.counters;
set role service_role;
select public.waitlist_signup('m+1@example.com','waitlist-v1');
select public.waitlist_signup('m+2@example.com','waitlist-v1');
select public.waitlist_signup('m+3@example.com','waitlist-v1');
select t.ok(public.waitlist_signup('m+4@example.com','waitlist-v1')->>'queued' is null, 'mailbox cap -> refused, NOT queued');
select t.ok(public.waitlist_signup('q1@example.com','waitlist-v1')->>'queued' is null, 'too-soon resend -> refused, NOT queued');
reset role;
select t.ok((select count(*) from private.send_queue) = 0, 'nothing was queued by the limited attempts');
-- a queued person who unsubscribes, confirms or is suppressed before the drain is skipped
update private.settings set value = '1' where key = 'global_sends_per_hour';
delete from private.counters;
set role service_role;
select public.waitlist_signup('r1@example.com','waitlist-v1');            -- uses the 1 slot
select public.waitlist_signup('r2@example.com','waitlist-v1');            -- queued
select public.waitlist_signup('r3@example.com','waitlist-v1');            -- queued
select public.waitlist_suppress('r2@example.com','hard_bounce');          -- bounced meanwhile
reset role;
delete from private.counters where bucket = 'send_hour';
set role service_role;
select t.ok((select string_agg(x->>'email', ',') from jsonb_array_elements(public.waitlist_drain_queue()->'sends') x) = 'r3@example.com',
  'drain skips the suppressed person and sends only r3');
reset role;
-- stale entries expire
update private.settings set value = '0' where key = 'global_sends_per_hour';
set role service_role;
select public.waitlist_signup('old@example.com','waitlist-v1');
reset role;
update private.send_queue set queued_at = now() - interval '3 days';
set role service_role;
select t.ok((public.waitlist_drain_queue()->>'left')::int = 0, 'entries older than queue_ttl_hours are dropped');
reset role;
-- the queue is bounded
update private.settings set value = '2' where key = 'queue_max';
set role service_role;
select public.waitlist_signup('b1@example.com','waitlist-v1');
select public.waitlist_signup('b2@example.com','waitlist-v1');
select t.ok(not (public.waitlist_signup('b3@example.com','waitlist-v1')->>'queued')::boolean, 'queue full -> not queued');
reset role;
select t.ok((select count(*) from private.send_queue) = 2 and exists (select 1 from private.alerts where kind = 'queue_full'),
  'queue stays at queue_max and the owner gets a queue_full alert');
update private.settings set value = '2000' where key = 'queue_max';
delete from private.send_queue;

\echo '--- 0005: kill switch stops every email at once; people are still kept'
update private.settings set value = '500' where key = 'global_sends_per_hour';
delete from private.counters;
set role service_role;
select t.ok((public.waitlist_set_paused(true)->>'paused')::boolean, 'owner pauses sending');
select t.ok(public.waitlist_signup('p1@example.com','waitlist-v1')->>'reason' = 'paused', 'paused -> no email');
select t.ok(jsonb_array_length(public.waitlist_drain_queue()->'sends') = 0, 'paused -> drain sends nothing either');
reset role;
select t.ok(exists (select 1 from private.send_queue q join private.signups s on s.id = q.signup_id where s.email = 'p1@example.com'),
  'the paused signup is kept in the queue');
select t.ok(coalesce((select used from private.counters where bucket = 'send_hour'), 0) = 0, 'paused signups consumed no send budget');
set role service_role;
select public.waitlist_set_paused(false);
select t.ok((select x->>'email' from jsonb_array_elements(public.waitlist_drain_queue()->'sends') x) = 'p1@example.com',
  'after resume the queued person gets their email');
reset role;

\echo '--- 0005: a bounce / complaint spike pauses sending by itself'
delete from private.suppressions; delete from private.alerts; delete from private.counters;
insert into private.counters(bucket, period, used) values ('send_hour', date_trunc('hour', now()), 100);
set role service_role;
select public.waitlist_suppress('bad' || g || '@example.com', 'hard_bounce') from generate_series(1, 4) g;
reset role;
select t.ok(not private.is_paused(), '4 bounces out of 100 sends -> below the minimum, still sending');
set role service_role;
select public.waitlist_suppress('bad4@example.com', 'hard_bounce');      -- duplicate webhook
reset role;
select t.ok(not private.is_paused(), 'a repeated webhook for the same address does not count twice');
set role service_role;
select public.waitlist_suppress('bad5@example.com', 'hard_bounce');
reset role;
select t.ok(private.is_paused(), '5 bounces = 5% of 100 sends -> sending paused automatically');
select t.ok((select detail->>'bounces_24h' from private.alerts where kind = 'auto_paused') = '5', 'owner alert says why (counts only)');
-- complaints pause faster
update private.settings set value = 'false' where key = 'sending_paused';
delete from private.suppressions; delete from private.alerts;
insert into private.counters(bucket, period, used) values ('send_hour', date_trunc('hour', now()) - interval '1 hour', 900);
set role service_role;
select public.waitlist_suppress('c1@example.com', 'complaint');
reset role;
select t.ok(not private.is_paused(), '1 complaint -> still sending');
set role service_role;
select public.waitlist_suppress('c2@example.com', 'complaint');
reset role;
select t.ok(private.is_paused(), '2 complaints in 24 h -> paused (even with 1000 sends)');
update private.settings set value = 'false' where key = 'sending_paused';

\echo '--- 0005: alerts are emailed once, and carry no addresses'
set role service_role;
select t.ok(jsonb_array_length(public.waitlist_take_alerts()) >= 1, 'pending alerts are handed to the job');
select t.ok(jsonb_array_length(public.waitlist_take_alerts()) = 0, 'and never handed out twice');
reset role;
select t.ok(not exists (select 1 from private.alerts where detail::text like '%@%'), 'no alert holds an email address');

\echo '--- 0005: none of it is reachable from the browser'
set role anon;
do $$ begin
  begin perform public.waitlist_drain_queue(); raise exception 'LEAK'; exception when insufficient_privilege then null; end;
  begin perform public.waitlist_set_paused(false); raise exception 'LEAK'; exception when insufficient_privilege then null; end;
  begin perform public.waitlist_take_alerts(); raise exception 'LEAK'; exception when insufficient_privilege then null; end;
  begin perform count(*) from private.send_queue; raise exception 'LEAK'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select t.ok(true, 'anon cannot drain, pause/resume, read alerts or see the queue');

-- restore defaults for any later test
update private.settings set value = '500'   where key = 'global_sends_per_hour';
update private.settings set value = 'false' where key = 'sending_paused';
delete from private.counters; delete from private.send_queue; delete from private.alerts; delete from private.suppressions;

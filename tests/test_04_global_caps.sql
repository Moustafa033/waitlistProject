\echo '--- global caps (a bot farm that passes the captcha still cannot burn the sender reputation)'
update private.settings set value = '3' where key = 'global_sends_per_hour';
delete from private.counters where bucket = 'send_hour';
set role service_role;
select t.ok(public.waitlist_signup('g1@example.com', 'waitlist-v1')->>'action' = 'send', 'send 1/3');
select t.ok(public.waitlist_signup('g2@example.com', 'waitlist-v1')->>'action' = 'send', 'send 2/3');
create temp table h as select public.waitlist_signup('g3@example.com', 'waitlist-v1') v;
select t.ok((select v->>'action' from h) = 'send', 'send 3/3');
select t.ok(public.waitlist_signup('g4@example.com', 'waitlist-v1')->>'reason' = 'global_send_cap', '4th in the same hour -> held back');
select public.waitlist_send_failed(((select v->>'hour' from h))::timestamptz);
select t.ok(public.waitlist_signup('g5@example.com', 'waitlist-v1')->>'action' = 'send', 'provider never reached -> the global unit is given back');
reset role;
select t.ok((select confirm_sends from private.signups where email='g4@example.com') = 0, 'held-back address keeps its lifetime budget (it can retry next hour)');
update private.settings set value = '500' where key = 'global_sends_per_hour';

update private.settings set value = '0' where key = 'global_new_per_day';
set role service_role;
select t.ok(public.waitlist_signup('flood@example.com', 'waitlist-v1')->>'reason' = 'global_new_cap', 'daily new-row cap stops table flooding');
reset role;
select t.ok(not exists (select 1 from private.signups where email='flood@example.com'), 'no row created over the cap');
update private.settings set value = '5000' where key = 'global_new_per_day';

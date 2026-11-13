\echo '--- 0004: per-mailbox cap closes the "+tag" bombing hole; identity stays exact'
-- clean slate + generous global caps so only the mailbox cap can bite here
update private.settings set value = '3'   where key = 'mailbox_sends_per_day';
update private.settings set value = '500' where key = 'global_sends_per_hour';
update private.settings set value = '90'  where key = 'global_sends_per_day';
update private.settings set value = '30'  where key = 'resend_min_minutes';
delete from private.counters;
delete from private.signups;
set role service_role;

-- 5 "+tag" variants of ONE inbox -> only 3 confirmation emails (was: 5)
select t.ok(public.waitlist_signup('victim+1@gmail.com','waitlist-v1')->>'action' = 'send', '+1 -> send 1/3');
select t.ok(public.waitlist_signup('victim+2@gmail.com','waitlist-v1')->>'action' = 'send', '+2 -> send 2/3');
select t.ok(public.waitlist_signup('victim+3@gmail.com','waitlist-v1')->>'action' = 'send', '+3 -> send 3/3');
select t.ok(public.waitlist_signup('victim+4@gmail.com','waitlist-v1')->>'reason' = 'mailbox_send_cap', '+4 -> refused (one inbox, cap reached)');
select t.ok(public.waitlist_signup('victim+5@gmail.com','waitlist-v1')->>'reason' = 'mailbox_send_cap', '+5 -> refused');
-- the bare address shares the same mailbox too
select t.ok(public.waitlist_signup('victim@gmail.com','waitlist-v1')->>'reason' = 'mailbox_send_cap', 'bare victim@ shares the inbox -> refused');
-- googlemail.com is the same inbox as gmail.com
select t.ok(public.waitlist_signup('victim+x@googlemail.com','waitlist-v1')->>'reason' = 'mailbox_send_cap', 'googlemail.com folds to gmail.com -> refused');

-- a DIFFERENT base (different letters) is a DIFFERENT person and still sends
select t.ok(public.waitlist_signup('ahmedsayed@gmail.com','waitlist-v1')->>'action' = 'send', 'different-letters address is separate -> send');
-- dots are NOT folded (owner choice): v.ictim@ is its own mailbox key
select t.ok(public.waitlist_signup('v.ictim@gmail.com','waitlist-v1')->>'action' = 'send', 'dot variant is a separate mailbox (dots left alone) -> send');

reset role;
-- identity is untouched: every variant is still its own row on the list
select t.ok((select count(*) from private.signups where email like 'victim+%@gmail.com') = 5, 'all 5 "+tag" variants are still stored as separate people');
-- the mailbox-blocked attempts did NOT consume the shared global daily budget
select t.ok((select used from private.counters where bucket = 'send_day' and period = date_trunc('day', now())) = 5,
  'only the 5 real sends used the global daily budget (3 victim + ahmedsayed + v.ictim); blocked variants did not');
-- the mailbox key is stored hashed, never as plaintext
select t.ok(not exists (select 1 from private.counters where bucket like '%victim%' or bucket like '%gmail%'),
  'no plaintext address in the counter buckets (mailbox key is hashed)');

\echo '--- 0004: encoded-word ("=?") addresses are refused by both layers'
select t.ok(not private.email_ok('=?utf-8?q?victim=40gmail.com?=@attacker.example'), 'SQL email_ok refuses an encoded-word local part');
set role service_role;
select t.ok(public.waitlist_signup('=?utf-8?q?victim=40gmail.com?=@attacker.example','waitlist-v1')->>'reason' = 'invalid_email', 'waitlist_signup refuses an encoded-word address');
reset role;
select t.ok(private.email_ok('normal.person@gmail.com'), 'a normal address still passes');

-- restore defaults for any later file
update private.settings set value = '3' where key = 'mailbox_sends_per_day';
delete from private.counters;

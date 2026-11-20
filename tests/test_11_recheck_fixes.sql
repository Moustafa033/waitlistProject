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

\echo '--- R6 + re-check 2 #2: a confirmed application''s owner notice is queued even when the queue is "full"'
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
select t.ok(exists (select 1 from private.partner_mail_queue q join private.partner_applications a on a.id = q.application_id
                    where a.email = 'r6@example.com'), 'the owner notice is in the queue: never lost');
select t.ok(not exists (select 1 from private.alerts where kind = 'queue_full'), 'so there is nothing to alert about');
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
select t.ok(public.waitlist_partner_requeue((select (j->>'id')::uuid from r7r), (select j->>'token' from r7r)), 'provider down -> requeued');
reset role;
select t.ok((select confirm_sends = 0 and last_confirm_sent_at is null from private.partner_applications where email = 'r7-retry@example.com'),
  'the unsent link does not count');
-- re-check 2 #3: if the provider DID receive that email after all, its link keeps working
set role service_role;
select t.ok((public.waitlist_partner_confirm((select j->>'token' from r7r))->>'ok')::boolean,
  'the current link is NOT killed by a retry');
reset role;

\echo '--- re-check 2 #1 + 3 #1: the send-time check: address, kill switch, current state AND the exact link'
insert into private.suppressions(email_hash, reason) values (private.email_hash('gone2@example.com'), 'erasure');
set role service_role;
create temp table sa as select t.apply('state@example.com') j;
create temp table sw as select public.waitlist_signup('wl-state@example.com', 'waitlist-v1') j;
reset role;
grant select on sa, sw to service_role;
set role service_role;
select t.ok(public.waitlist_send_allowed('state@example.com', 'partner_confirm', (select (j->>'id')::uuid from sa), (select j->>'token' from sa)) = 'ok',
  'pending application + its current link -> ok');
select t.ok(public.waitlist_send_allowed('state@example.com', 'partner_confirm', (select (j->>'id')::uuid from sa), repeat('A', 43)) = 'cancelled',
  'another link for the same application -> cancelled');
select t.ok(public.waitlist_send_allowed('state@example.com', 'partner_confirm', (select (j->>'id')::uuid from sa)) = 'cancelled',
  'no link given -> cancelled (fails closed)');
select t.ok(public.waitlist_send_allowed('state@example.com', 'partner_owner', (select (j->>'id')::uuid from sa)) = 'cancelled', 'not confirmed -> no owner notice');
select t.ok(public.waitlist_send_allowed('other@example.com', 'partner_confirm', (select (j->>'id')::uuid from sa), (select j->>'token' from sa)) = 'cancelled',
  'address does not match the application -> cancelled');
select t.ok(public.waitlist_send_allowed('state@example.com', 'partner_confirm', gen_random_uuid(), (select j->>'token' from sa)) = 'cancelled', 'unknown application -> cancelled');
select t.ok(public.waitlist_send_allowed('wl-state@example.com', 'signup', (select (j->>'signup_id')::uuid from sw), (select j->>'token' from sw)) = 'ok',
  'pending signup + its current link -> ok');
select t.ok(public.waitlist_send_allowed('wl-state@example.com', 'signup', (select (j->>'signup_id')::uuid from sw), repeat('B', 43)) = 'cancelled',
  'wrong link for the signup -> cancelled');
select t.ok(public.waitlist_send_allowed('gone2@example.com', 'signup', gen_random_uuid(), repeat('A', 43)) = 'suppressed', 'deleted address -> suppressed');
select t.ok(public.waitlist_send_allowed('state@example.com', 'something', (select (j->>'id')::uuid from sa), (select j->>'token' from sa)) = 'cancelled', 'unknown kind -> cancelled');
-- the person signs up again: a newer email replaces the first one, which must not be sent any more
create temp table sw2 as select public.waitlist_signup('wl-state@example.com', 'waitlist-v1') j;
reset role;
grant select on sw2 to service_role;
select t.ok((select j->>'token' from sw2) <> (select j->>'token' from sw), 'a new email has a new link');
set role service_role;
select t.ok(public.waitlist_send_allowed('wl-state@example.com', 'signup', (select (j->>'signup_id')::uuid from sw), (select j->>'token' from sw)) = 'cancelled',
  'the OLDER email (replaced link) -> cancelled, even though the signup is still pending');
select t.ok(public.waitlist_send_allowed('wl-state@example.com', 'signup', (select (j->>'signup_id')::uuid from sw), (select j->>'token' from sw2)) = 'ok',
  'the newest email -> ok');
reset role;
update private.signups set confirm_expires_at = now() - interval '1 minute' where email = 'wl-state@example.com';
set role service_role;
select t.ok(public.waitlist_send_allowed('wl-state@example.com', 'signup', (select (j->>'signup_id')::uuid from sw), (select j->>'token' from sw2)) = 'cancelled',
  'an expired link is not sent');
reset role;
update private.signups set confirm_expires_at = now() + interval '1 hour', status = 'unsubscribed', unsubscribed_at = now() where email = 'wl-state@example.com';
set role service_role;
select t.ok(public.waitlist_send_allowed('wl-state@example.com', 'signup', (select (j->>'signup_id')::uuid from sw), (select j->>'token' from sw2)) = 'cancelled',
  'unsubscribed meanwhile -> cancelled');
reset role;
update private.settings set value = 'true' where key = 'sending_paused';
set role service_role;
select t.ok(public.waitlist_send_allowed('state@example.com', 'partner_confirm', (select (j->>'id')::uuid from sa), (select j->>'token' from sa)) = 'paused', 'kill switch on -> paused');
reset role;
update private.settings set value = 'false' where key = 'sending_paused';
set role anon;
select t.fails($$select public.waitlist_send_allowed('a@example.com', 'signup', gen_random_uuid(), repeat('A', 43))$$, '42501', 'anon cannot use the check');
select t.fails($$select public.waitlist_signup_requeue(gen_random_uuid(), repeat('A', 43))$$, '42501', 'anon cannot requeue');
reset role;
set role service_role;
select t.fails($$select private.confirm_token('waitlist', gen_random_uuid(), 0, 1)$$, '42501', 'even the server key cannot make a link directly');
reset role;

\echo '--- re-check 3 #2 + #4: a waitlist email that was not handed over is kept, with its allowance, as the SAME email'
delete from private.send_queue; delete from private.counters;
set role service_role;
create temp table rq as select public.waitlist_signup('wl-rq@example.com', 'waitlist-v1') j;
reset role;
grant select on rq to service_role;
select t.ok((select j->>'token' from rq) <> public.waitlist_unsub_token((select (j->>'signup_id')::uuid from rq)),
  'a confirmation link can never equal the unsubscribe token (own key prefix)');
select t.ok((select used from private.counters where bucket = private.mailbox_bucket('wl-rq@example.com')) = 1, 'the inbox was charged 1 email');
set role service_role;
select t.ok(not public.waitlist_signup_requeue((select (j->>'signup_id')::uuid from rq), repeat('C', 43)), 'requeue with a link that is not the current one -> refused');
select t.ok(public.waitlist_signup_requeue((select (j->>'signup_id')::uuid from rq), (select j->>'token' from rq)), 'provider not reached -> requeued');
reset role;
select t.ok((select confirm_sends = 0 and last_confirm_sent_at is null from private.signups where email = 'wl-rq@example.com'),
  'the attempt does not count, and the wait between emails is lifted');
select t.ok((select used from private.counters where bucket = private.mailbox_bucket('wl-rq@example.com')) = 0, 'the inbox got its unit back');
select t.ok((select confirm_token_hash from private.signups where email = 'wl-rq@example.com') = private.token_hash((select j->>'token' from rq)),
  'the link is NOT cleared: if that email did arrive, it still works');
select t.ok(exists (select 1 from private.send_queue q join private.signups s on s.id = q.signup_id where s.email = 'wl-rq@example.com'), 'it is in the queue');
set role service_role;
create temp table rqd as select public.waitlist_drain_queue() j;
reset role;
select t.ok((select e->>'token' from rqd, jsonb_array_elements(j->'sends') e where e->>'email' = 'wl-rq@example.com') = (select j->>'token' from rq),
  'the retry is the SAME link');
select t.ok((select (e->>'send_no')::int from rqd, jsonb_array_elements(j->'sends') e where e->>'email' = 'wl-rq@example.com') = 1,
  'with the SAME number (same idempotency key: the provider drops a duplicate)');
-- three failed handoffs in a row do not use up the address's 3 emails
set role service_role;
select public.waitlist_signup_requeue((select (j->>'signup_id')::uuid from rq), (select j->>'token' from rq));
select public.waitlist_drain_queue();
select public.waitlist_signup_requeue((select (j->>'signup_id')::uuid from rq), (select j->>'token' from rq));
select public.waitlist_drain_queue();
reset role;
select t.ok((select confirm_sends from private.signups where email = 'wl-rq@example.com') = 1, 'after 3 tries of one email the address has used 1 of its emails');
set role service_role;
select t.ok((public.waitlist_confirm((select j->>'token' from rq))->>'ok')::boolean, 'and the link confirms');
select t.ok(not public.waitlist_signup_requeue((select (j->>'signup_id')::uuid from rq), (select j->>'token' from rq)), 'a confirmed signup is never requeued');
reset role;

\echo '--- re-check 3 #3: a partner retry is the SAME email; replaced details still get a different link'
delete from private.partner_mail_queue;
set role service_role;
create temp table prq as select t.apply('p-rq@example.com', 'First Details') j;
select t.ok(public.waitlist_partner_requeue((select (j->>'id')::uuid from prq), (select j->>'token' from prq)), 'provider not reached -> requeued');
reset role;
grant select on prq to service_role;
select t.ok((select used from private.counters where bucket = private.mailbox_bucket('p-rq@example.com')) = 0, 'the inbox got its unit back');
set role service_role;
create temp table prqd as select public.waitlist_drain_partner_queue() j;
reset role;
select t.ok((select e->>'token' from prqd, jsonb_array_elements(j->'sends') e where e->>'email' = 'p-rq@example.com') = (select j->>'token' from prq),
  'the retry is the SAME link');
select t.ok((select e->>'tag' from prqd, jsonb_array_elements(j->'sends') e where e->>'email' = 'p-rq@example.com') = (select j->>'tag' from prq)
            and (select (e->>'send_no')::int from prqd, jsonb_array_elements(j->'sends') e where e->>'email' = 'p-rq@example.com') = 1,
  'with the SAME idempotency key (number + fingerprint)');
-- R1 must still hold: after a failed handoff the number is given back, and new details arrive
set role service_role;
select public.waitlist_partner_requeue((select (j->>'id')::uuid from prq), (select j->>'token' from prq));
create temp table prq2 as select t.apply('p-rq@example.com', 'Replaced Details') j;
reset role;
grant select on prq2 to service_role;
select t.ok((select (j->>'send_no')::int from prq2) = 2 and (select j->>'token' from prq2) <> (select j->>'token' from prq),
  'NEW details => a new generation and a different link');
set role service_role;
select t.ok(not (public.waitlist_partner_confirm((select j->>'token' from prq))->>'ok')::boolean, 'the first link cannot approve the replaced details');
select t.ok((public.waitlist_partner_confirm((select j->>'token' from prq2))->>'name') = 'Replaced Details', 'the new link approves exactly its own details');
reset role;

\echo '--- re-check 2 #2: an owner notice is admitted even when the queue is full'
create temp table own as select id from private.partner_applications where email = 'p-rq@example.com';
grant select on own to service_role;
update private.settings set value = '0' where key = 'partner_queue_max';
set role service_role;
select t.ok(public.waitlist_partner_requeue((select id from own)), 'queue "full" -> the owner notice of a CONFIRMED application is still admitted');
reset role;
update private.settings set value = '1000' where key = 'partner_queue_max';

\echo '--- re-check 4: a revoked or expired link can NEVER become valid again (generation only goes up)'
delete from private.send_queue; delete from private.counters;
-- the attack: link 1 is out, its send is refunded, the person unsubscribes, then signs up again
set role service_role;
create temp table g1 as select public.waitlist_signup('gen-a@example.com', 'waitlist-v1') j;
select t.ok(public.waitlist_signup_requeue((select (j->>'signup_id')::uuid from g1), (select j->>'token' from g1)), 'link 1: send refunded (provider answer unknown)');
select t.ok((public.waitlist_unsubscribe((select (j->>'signup_id')::uuid from g1),
                                         public.waitlist_unsub_token((select (j->>'signup_id')::uuid from g1)))->>'ok')::boolean, 'the person unsubscribes: link 1 is revoked');
create temp table g2 as select public.waitlist_signup('gen-a@example.com', 'waitlist-v1') j;
reset role;
grant select on g1, g2 to service_role;
select t.ok((select j->>'action' from g2) = 'send' and (select j->>'token' from g2) <> (select j->>'token' from g1),
  'a fresh opt-in on the same record gets a NEW link (before this fix: the revoked one again)');
select t.ok((select (j->>'send_no')::int from g2) = 2, 'and a new generation in its idempotency key');
set role service_role;
select t.ok(not (public.waitlist_confirm((select j->>'token' from g1))->>'ok')::boolean, 'the revoked link cannot confirm the new signup');
reset role;
select t.ok((select status from private.signups where email = 'gen-a@example.com') = 'pending', 'still unconfirmed');
set role service_role;
select t.ok((public.waitlist_confirm((select j->>'token' from g2))->>'ok')::boolean, 'only the link from the new email confirms');
reset role;

-- an expired link whose send was refunded: the retry does not bring it back
set role service_role;
create temp table e1 as select public.waitlist_signup('gen-b@example.com', 'waitlist-v1') j;
select public.waitlist_signup_requeue((select (j->>'signup_id')::uuid from e1), (select j->>'token' from e1));
reset role;
grant select on e1 to service_role;
update private.signups set confirm_expires_at = now() - interval '1 minute' where email = 'gen-b@example.com';
set role service_role;
create temp table e1d as select public.waitlist_drain_queue() j;
reset role;
select t.ok((select e->>'token' from e1d, jsonb_array_elements(j->'sends') e where e->>'email' = 'gen-b@example.com') <> (select j->>'token' from e1),
  'the link expired before the retry went out -> the queue sends a NEW link, not the expired one');
set role service_role;
select t.ok(not (public.waitlist_confirm((select j->>'token' from e1))->>'ok')::boolean, 'the expired link stays invalid');
reset role;

-- a retry of a still-valid email keeps its generation, link AND expiry
set role service_role;
create temp table k1 as select public.waitlist_signup('gen-c@example.com', 'waitlist-v1') j;
reset role;
grant select on k1 to service_role;
create temp table k1e as select confirm_expires_at e, confirm_gen g from private.signups where email = 'gen-c@example.com';
set role service_role;
select public.waitlist_signup_requeue((select (j->>'signup_id')::uuid from k1), (select j->>'token' from k1));
create temp table k1d as select public.waitlist_drain_queue() j;
reset role;
select t.ok((select e->>'token' from k1d, jsonb_array_elements(j->'sends') e where e->>'email' = 'gen-c@example.com') = (select j->>'token' from k1)
            and (select (e->>'send_no')::int from k1d, jsonb_array_elements(j->'sends') e where e->>'email' = 'gen-c@example.com') = 1,
  'retry: same link, same idempotency number');
select t.ok((select confirm_expires_at = (select e from k1e) and confirm_gen = (select g from k1e) and not confirm_retry
             from private.signups where email = 'gen-c@example.com'), 'retry: same expiry (not extended), same generation');

-- the refund is applied once per attempt, and the generation never goes back
set role service_role;
select public.waitlist_signup('gen-d@example.com', 'waitlist-v1');
create temp table d2 as select public.waitlist_signup('gen-d@example.com', 'waitlist-v1') j;
select public.waitlist_signup_requeue((select (j->>'signup_id')::uuid from d2), (select j->>'token' from d2));
select public.waitlist_signup_requeue((select (j->>'signup_id')::uuid from d2), (select j->>'token' from d2));
select public.waitlist_signup_requeue((select (j->>'signup_id')::uuid from d2), (select j->>'token' from d2));
reset role;
select t.ok((select confirm_sends from private.signups where email = 'gen-d@example.com') = 1, '3 requeues of one attempt refund 1 email, not 3');
select t.ok((select used from private.counters where bucket = private.mailbox_bucket('gen-d@example.com')) = 1, 'the inbox unit is returned once');
select t.ok((select confirm_gen from private.signups where email = 'gen-d@example.com') = 2, 'the generation is not given back');

-- the same rule for partner applications
delete from private.partner_mail_queue;
set role service_role;
create temp table pg1 as select t.apply('gen-p@example.com', 'Gen Person') j;
select public.waitlist_partner_requeue((select (j->>'id')::uuid from pg1), (select j->>'token' from pg1));
reset role;
grant select on pg1 to service_role;
update private.partner_applications set confirm_expires_at = now() - interval '1 minute' where email = 'gen-p@example.com';
set role service_role;
create temp table pg1d as select public.waitlist_drain_partner_queue() j;
reset role;
select t.ok((select e->>'token' from pg1d, jsonb_array_elements(j->'sends') e where e->>'email' = 'gen-p@example.com') <> (select j->>'token' from pg1)
            and (select (e->>'send_no')::int from pg1d, jsonb_array_elements(j->'sends') e where e->>'email' = 'gen-p@example.com') = 2,
  'partner: an expired link is replaced by a new generation, never revived');
set role service_role;
select t.ok(not (public.waitlist_partner_confirm((select j->>'token' from pg1))->>'ok')::boolean, 'partner: the expired link stays invalid');
reset role;

drop function t.apply(text, text);
delete from private.counters; delete from private.alerts; delete from private.partner_mail_queue; delete from private.suppressions;
update private.settings set value = '30' where key = 'resend_min_minutes';
update private.settings set value = '3'  where key = 'mailbox_sends_per_day';

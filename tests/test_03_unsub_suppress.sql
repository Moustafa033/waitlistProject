\echo '--- unsubscribe, suppression, erasure, export, retention, consent proof'
set role service_role;
create temp table r(k text primary key, v jsonb);
insert into r values ('u', public.waitlist_signup('sara@example.com', 'waitlist-v1'));
select t.ok((public.waitlist_confirm((select v->>'token' from r where k='u'))->>'ok')::boolean, 'sara confirmed');
create temp table ids as select (v->>'signup_id')::uuid id from r where k='u';
select t.ok((select count(*) from public.waitlist_export_confirmed() where email='sara@example.com') = 1, 'confirmed address is in the launch export');
select t.ok((select count(*) from public.waitlist_export_confirmed() e where e.email in ('loc@example.com','a.hmed@example.com')) = 0, 'pending (never confirmed) addresses are NOT exported');

select t.ok((public.waitlist_unsubscribe((select id from ids), 'x'||repeat('y',42))->>'ok')::boolean = false, 'forged unsubscribe token -> refused');
select t.ok((public.waitlist_unsubscribe(gen_random_uuid(), public.waitlist_unsub_token((select id from ids)))->>'ok')::boolean = false,
  'token of one person cannot unsubscribe another');
select t.ok((public.waitlist_unsubscribe((select id from ids), public.waitlist_unsub_token((select id from ids)))->>'ok')::boolean, 'real one-click unsubscribe -> ok');
select t.ok((public.waitlist_unsubscribe((select id from ids), public.waitlist_unsub_token((select id from ids)))->>'ok')::boolean, 'unsubscribing twice -> still ok (idempotent)');
select t.ok((select count(*) from public.waitlist_export_confirmed() where email='sara@example.com') = 0, 'unsubscribed address left the export');

-- re-subscribe needs a NEW double opt-in, and still counts toward the lifetime cap
reset role;
update private.signups set last_confirm_sent_at = now() - interval '2 hours' where email = 'sara@example.com';
set role service_role;
insert into r values ('u2', public.waitlist_signup('sara@example.com', 'waitlist-v1'));
select t.ok((select v->>'action' from r where k='u2') = 'send', 'unsubscribed person may re-join, but only through a new confirmation');
select t.ok((select count(*) from public.waitlist_export_confirmed() where email='sara@example.com') = 0, 'not exported until she confirms again');

-- hard bounce / complaint
select public.waitlist_suppress('Sara@Example.com', 'complaint');
select t.ok((public.waitlist_confirm((select v->>'token' from r where k='u2'))->>'ok')::boolean = false, 'pending link dies when the address is suppressed');
reset role;
update private.signups set last_confirm_sent_at = now() - interval '2 hours' where email = 'sara@example.com';
set role service_role;
select t.ok(public.waitlist_signup('sara@example.com', 'waitlist-v1')->>'reason' = 'suppressed', 'complained address is never emailed again');
select t.fails($$select public.waitlist_suppress('x@example.com', 'whatever')$$, null, 'unknown suppression reason refused');

-- erasure
insert into r values ('e', public.waitlist_signup('omar@example.com', 'waitlist-v1'));
select public.waitlist_erase('OMAR@example.com');
reset role;
select t.ok(not exists (select 1 from private.signups where email='omar@example.com'), 'erasure deletes the person');
select t.ok(not exists (select 1 from private.suppressions where email_hash like '%omar%') and
            exists (select 1 from private.suppressions where reason='erasure' and length(email_hash) = 64),
  'only a 64-hex keyed hash remains (no plaintext) to keep the do-not-email promise');
select t.ok(not exists (select 1 from private.consent_events where signup_id is not null and signup_id not in (select id from private.signups)),
  'no consent event still points at an erased person');
set role service_role;
select t.ok(public.waitlist_signup('omar@example.com', 'waitlist-v1')->>'reason' = 'suppressed', 'erased person is not emailed again by a replayed signup');
reset role;

-- consent proof is append-only
select t.ok(exists (select 1 from private.consent_events where event='confirmed' and consent_version='waitlist-v1'), 'confirmation event with consent version is recorded');
select t.fails($$update private.consent_events set event='confirmed' where event='requested'$$, null, 'consent events cannot be rewritten (even by the owner role)');
select t.fails($$delete from private.consent_events$$, null, 'consent events cannot be deleted');

-- counter for the landing page is coarse
set role service_role;
select t.ok(public.waitlist_public_count() % 10 = 0, 'public counter is rounded to 10s');
reset role;

-- retention (window counts from the LAST confirmation email; loc got its email at signup)
update private.signups set created_at = now() - interval '31 days', last_confirm_sent_at = now() - interval '31 days'
 where email = 'loc@example.com';

-- returning person: joined 400 days ago, unsubscribed, re-joins today => must survive tonight's cleanup
set role service_role;
insert into r values ('back1', public.waitlist_signup('back@example.com', 'waitlist-v1'));
select public.waitlist_unsubscribe((select (v->>'signup_id')::uuid from r where k='back1'),
                                   public.waitlist_unsub_token((select (v->>'signup_id')::uuid from r where k='back1')));
reset role;
update private.signups set created_at = now() - interval '400 days', unsubscribed_at = now() - interval '200 days',
       last_confirm_sent_at = now() - interval '400 days' where email = 'back@example.com';
set role service_role;
insert into r values ('back2', public.waitlist_signup('back@example.com', 'waitlist-v1'));
select t.ok((select v->>'action' from r where k='back2') = 'send', 'returning person gets a new confirmation email');

select t.ok((public.waitlist_maintenance()->>'pending_deleted')::int >= 1, 'maintenance deletes never-confirmed rows after the retention window');
reset role;
select t.ok(not exists (select 1 from private.signups where email='loc@example.com'), 'old pending row is gone');
select t.ok(exists (select 1 from private.signups where email='back@example.com' and status='pending'),
  'returning person''s fresh pending row survives the cleanup (old created_at is not used)');
set role service_role;
select t.ok((public.waitlist_confirm((select v->>'token' from r where k='back2'))->>'ok')::boolean, 'returning person can still confirm after the cleanup');
reset role;

-- self-service "Delete my data" (0003): only with the person's own signed link
set role service_role;
insert into r values ('del', public.waitlist_signup('erase-me@example.com', 'waitlist-v1'));
create temp table del_id as select (v->>'signup_id')::uuid id from r where k = 'del';
select t.ok((public.waitlist_erase_by_token((select id from del_id), 'x' || repeat('y', 42))->>'ok')::boolean = false,
  'forged delete token -> refused');
select t.ok((public.waitlist_erase_by_token((select id from del_id),
             public.waitlist_unsub_token((select (v->>'signup_id')::uuid from r where k = 'back2')))->>'ok')::boolean = false,
  'another person''s token cannot delete this person');
select t.ok((public.waitlist_erase_by_token(null, 'x')->>'ok')::boolean = false, 'missing id/token -> refused');
reset role;
select t.ok(exists (select 1 from private.signups where email = 'erase-me@example.com'), 'refused attempts deleted nothing');
set role service_role;
select t.ok((public.waitlist_erase_by_token((select id from del_id), public.waitlist_unsub_token((select id from del_id)))->>'ok')::boolean,
  'own signed link -> deleted');
select t.ok((public.waitlist_erase_by_token((select id from del_id), public.waitlist_unsub_token((select id from del_id)))->>'ok')::boolean,
  'same link again -> still ok (idempotent, reveals nothing)');
reset role;
select t.ok(not exists (select 1 from private.signups where email = 'erase-me@example.com'), 'row is gone immediately');
select t.ok(exists (select 1 from private.consent_events where event = 'erased' and detail->>'method' = 'self_service_link'),
  'anonymous erased event logged');
select t.ok(not exists (select 1 from private.consent_events where signup_id = (select id from del_id)),
  'no consent event still points at the deleted person');
set role service_role;
select t.ok(public.waitlist_signup('erase-me@example.com', 'waitlist-v1')->>'reason' = 'suppressed',
  'deleted person is never emailed again (replayed signup is suppressed)');
reset role;

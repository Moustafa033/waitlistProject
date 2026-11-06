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

-- retention
update private.signups set created_at = now() - interval '31 days' where email = 'loc@example.com';
set role service_role;
select t.ok((public.waitlist_maintenance()->>'pending_deleted')::int >= 1, 'maintenance deletes never-confirmed rows after the retention window');
reset role;
select t.ok(not exists (select 1 from private.signups where email='loc@example.com'), 'old pending row is gone');

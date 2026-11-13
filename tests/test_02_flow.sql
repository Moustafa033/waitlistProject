\echo '--- double opt-in flow, identity, enumeration, tokens'
-- 0004: the per-address cap tests below reuse ahmed@ / ahmed+1@ which now share one
-- mailbox. Raise the mailbox cap so these tests exercise the per-ADDRESS cap in isolation;
-- the per-mailbox cap has its own file (test_05_mailbox.sql). Restored at the end.
update private.settings set value = '1000' where key = 'mailbox_sends_per_day';
set role service_role;
create temp table r(k text primary key, v jsonb);
insert into r values ('a', public.waitlist_signup('  Ahmed@Example.com ', 'waitlist-v1', 'en', 'landing'));
select t.ok((select v->>'action' from r where k='a') = 'send', 'new address -> a confirmation is sent');
select t.ok((select v->>'token' ~ '^[A-Za-z0-9_-]{43}$' from r where k='a'), 'token is 43 chars base64url (32 random bytes)');
select t.ok(not (select v ? 'email' from r where k='a'), 'the RPC answer does not echo the email back');
insert into r values ('a2', public.waitlist_signup('ahmed@example.com', 'waitlist-v1'));
select t.ok((select v->>'action' from r where k='a2') = 'none', 'same address (other case/spaces) right away -> NO second email (P-2 identity, anti-bombing gap)');
insert into r values ('b', public.waitlist_signup('ahmed+1@example.com', 'waitlist-v1'));
select t.ok((select v->>'action' from r where k='b') = 'send', 'ahmed+1@ is a DIFFERENT person (no plus folding, P-2)');
insert into r values ('c', public.waitlist_signup('a.hmed@example.com', 'waitlist-v1'));
select t.ok((select v->>'action' from r where k='c') = 'send', 'a.hmed@ is a DIFFERENT person (no dot folding, P-2)');

-- invalid / hostile input never creates a row and never sends
select t.ok(public.waitlist_signup(e'victim@example.com\r\nBcc: all@corp.com', 'waitlist-v1')->>'action' = 'none', 'CRLF header injection in email -> refused');
select t.ok(public.waitlist_signup('a@b', 'waitlist-v1')->>'action' = 'none', 'no TLD -> refused');
select t.ok(public.waitlist_signup('=HYPERLINK("http://x")@example.com', 'waitlist-v1')->>'action' = 'none', 'formula/quotes in email -> refused');
select t.ok(public.waitlist_signup('"a b"@example.com', 'waitlist-v1')->>'action' = 'none', 'quoted local part -> refused (conservative)');
select t.ok(public.waitlist_signup('x..y@example.com', 'waitlist-v1')->>'action' = 'none', 'double dot -> refused');
select t.ok(public.waitlist_signup(repeat('a',65) || '@example.com', 'waitlist-v1')->>'action' = 'none', 'local part > 64 -> refused');
select t.ok(public.waitlist_signup('ok@example.com', 'waitlist-v0')->>'action' = 'none', 'stale consent version -> refused');
select t.ok(public.waitlist_signup('ok@exämple.com', 'waitlist-v1')->>'action' = 'none', 'non-ASCII domain (homograph) -> refused');
select t.ok(public.waitlist_signup('loc@example.com', 'waitlist-v1', 'en"><script>', 'x;drop')->>'action' = 'send', 'junk locale/source are dropped, signup still works');
reset role;
select t.ok((select locale is null and source is null from private.signups where email='loc@example.com'), 'junk locale/source were stored as NULL');
select t.ok((select count(*) from private.signups where email like '%example.com%' and email !~ '^[a-z0-9.+_-]+@example\.com$') = 0, 'no hostile email ever reached the table');
select t.ok((select confirm_token_hash <> convert_to((select v->>'token' from r where k='a'), 'utf8') from private.signups where email='ahmed@example.com'),
  'only the SHA-256 of the token is stored');

-- confirm
set role service_role;
select t.ok((public.waitlist_confirm('A'||repeat('x',42))->>'ok')::boolean = false, 'random token -> not confirmed');
select t.ok((public.waitlist_confirm('short')->>'ok')::boolean = false, 'malformed token -> not confirmed');
select t.ok((public.waitlist_confirm((select v->>'token' from r where k='a'))->>'ok')::boolean, 'real token -> confirmed');
select t.ok((public.waitlist_confirm((select v->>'token' from r where k='a'))->>'ok')::boolean = false, 'same token twice -> refused (single use)');
select t.ok(public.waitlist_signup('ahmed@example.com', 'waitlist-v1')->>'action' = 'none', 'confirmed address signs up again -> nothing sent');

-- rotation + expiry
insert into r values ('b2', '{}');
reset role;
update private.signups set last_confirm_sent_at = now() - interval '2 hours' where email = 'ahmed+1@example.com';
set role service_role;
update r set v = public.waitlist_signup('ahmed+1@example.com', 'waitlist-v1') where k='b2';
select t.ok((select v->>'action' from r where k='b2') = 'send', 'after the gap a second confirmation may be sent');
select t.ok((public.waitlist_confirm((select v->>'token' from r where k='b'))->>'ok')::boolean = false, 'the OLD link stops working after a resend (rotation)');
reset role;
update private.signups set confirm_expires_at = now() - interval '1 second' where email = 'ahmed+1@example.com';
set role service_role;
select t.ok((public.waitlist_confirm((select v->>'token' from r where k='b2'))->>'ok')::boolean = false, 'expired link -> refused');

-- lifetime cap per address (anti subscription-bombing)
reset role;
update private.signups set last_confirm_sent_at = now() - interval '2 hours' where email = 'ahmed+1@example.com';
set role service_role;
select t.ok(public.waitlist_signup('ahmed+1@example.com', 'waitlist-v1')->>'action' = 'send', '3rd confirmation email allowed (lifetime cap 3)');
reset role;
update private.signups set last_confirm_sent_at = now() - interval '2 hours' where email = 'ahmed+1@example.com';
set role service_role;
select t.ok(public.waitlist_signup('ahmed+1@example.com', 'waitlist-v1')->>'reason' = 'address_lifetime_cap', '4th -> refused forever (an attacker cannot flood this inbox through us)');
reset role;
select t.ok((select confirm_sends from private.signups where email='ahmed+1@example.com') = 3, 'exactly 3 confirmation emails were ever issued');
update private.settings set value = '3' where key = 'mailbox_sends_per_day';   -- restore default for later files

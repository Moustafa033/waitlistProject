-- =====================================================================
-- Waitlist — the whole database side. Run it on a SEPARATE Supabase project
-- (not the app project): a bug or a leaked key here can never touch app users.
--
-- Rules this file enforces (see docs/WAITLIST_SECURITY_GUIDE.md):
--  * Nothing is reachable by anon/authenticated. Only service_role (the Edge
--    Function) may call the RPCs. The browser never talks to the database.
--  * Double opt-in. Only `confirmed` rows are ever exported / emailed for launch.
--  * Confirmation tokens: 32 random bytes, stored as SHA-256 only, single use,
--    expire (example 48h). A new email rotates the token (old link dies).
--  * Anti "subscription bombing": per-address send limits (min gap + lifetime
--    cap) and a global hourly send cap. Our site can never be used to flood
--    someone's inbox.
--  * Same public answer for new / pending / confirmed / suppressed emails
--    (no enumeration): the RPC tells the Edge Function only "send" or "none".
--  * One-click unsubscribe (RFC 8058) with an HMAC token; always honored.
--  * Hard bounces, complaints and erasure requests go to a suppression list
--    (keyed hash, no plaintext) and are never emailed again.
--  * Proof of consent: append-only consent_events (what text/version, when,
--    which step). No IP addresses are stored or used (owner policy P-1).
--  * Every number below is an EXAMPLE. The owner decides them (table settings).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to service_role;

-- Supabase grants every NEW object in public to the API roles by default.
-- Undo that for everything this migration (and later ones) create.
alter default privileges in schema public revoke all on tables    from anon, authenticated, public;
alter default privileges in schema public revoke all on functions from anon, authenticated, public;
alter default privileges in schema public revoke all on sequences from anon, authenticated, public;
alter default privileges in schema private revoke all on tables    from anon, authenticated, public;
alter default privileges in schema private revoke all on functions from anon, authenticated, public;

-- ---------------------------------------------------------------- settings
create table private.settings (
  key   text primary key,
  value text not null
);
insert into private.settings(key, value) values
  ('confirm_ttl_hours',        '48'),   -- EXAMPLE: confirmation link lifetime
  ('resend_min_minutes',       '30'),   -- EXAMPLE: min gap between two confirmation emails to one address
  ('max_confirm_sends',        '3'),    -- EXAMPLE: lifetime confirmation emails per address
  ('global_sends_per_hour',    '500'),  -- EXAMPLE: all confirmation emails together, per hour
  ('global_new_per_day',       '5000'), -- EXAMPLE: new pending rows per day (stops table flooding)
  ('pending_retention_days',   '30'),   -- EXAMPLE: never-confirmed rows are deleted after this
  ('unsub_retention_days',     '365'),  -- EXAMPLE: unsubscribed rows are deleted after this
  ('current_consent_version',  'waitlist-v1');

-- secrets live in the database ONLY for HMAC keys (never API keys)
create table private.app_secrets (
  name  text primary key,
  value text not null check (length(value) >= 32)
);

create or replace function private.cfg_int(p_key text) returns integer
language sql stable security definer set search_path = '' as $$
  select value::integer from private.settings where key = p_key
$$;
create or replace function private.cfg_text(p_key text) returns text
language sql stable security definer set search_path = '' as $$
  select value from private.settings where key = p_key
$$;
create or replace function private.secret(p_name text) returns text
language plpgsql stable security definer set search_path = '' as $$
declare v text;
begin
  select value into v from private.app_secrets where name = p_name;
  if v is null then raise exception 'missing secret %', p_name; end if;  -- fail closed
  return v;
end $$;

-- ---------------------------------------------------------------- helpers
-- P-2: the exact email (lower + trim) is the identity. No dot/plus folding.
create or replace function private.normalize_email(p text) returns text
language sql immutable set search_path = '' as $$
  select lower(btrim(p))
$$;

-- Server-side re-check (the Edge Function validates first; this is the last line).
-- Conservative ASCII-only rule: 1..64 local, total <= 254, no control chars,
-- no quotes/spaces/angle brackets/commas/semicolons (header + CSV safety).
create or replace function private.email_ok(p text) returns boolean
language sql immutable set search_path = '' as $$
  select p is not null
     and length(p) between 6 and 254
     and p ~ '^[a-z0-9.!#$%&''*+/=?^_`{|}~-]{1,64}@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$'
     and p !~ '\.\.'
     and left(p, 1) <> '.'
     and split_part(p, '@', 1) !~ '\.$'
     and right(split_part(p, '@', 2), 1) <> '-'
     and split_part(p, '@', 2) ~ '\.[a-z]{2,63}$'
$$;

create or replace function private.email_hash(p_email text) returns text
language sql stable security definer set search_path = '' as $$
  select encode(extensions.hmac(private.normalize_email(p_email), private.secret('email_pepper'), 'sha256'), 'hex')
$$;

create or replace function private.token_hash(p_token text) returns bytea
language sql immutable set search_path = '' as $$
  select extensions.digest(p_token, 'sha256')
$$;

-- base64url without padding, 32 random bytes => 43 chars
create or replace function private.new_token() returns text
language sql volatile set search_path = '' as $$
  select translate(rtrim(encode(extensions.gen_random_bytes(32), 'base64'), '='), '+/', '-_')
$$;

-- ---------------------------------------------------------------- tables
create table private.signups (
  id                   uuid primary key default gen_random_uuid(),
  email                text not null unique check (email = private.normalize_email(email) and private.email_ok(email)),
  status               text not null default 'pending' check (status in ('pending','confirmed','unsubscribed')),
  locale               text check (locale is null or locale ~ '^[a-z]{2}(-[A-Z]{2})?$'),
  source               text check (source is null or source ~ '^[a-z0-9_-]{1,32}$'),
  consent_version      text not null,
  confirm_token_hash   bytea unique,
  confirm_expires_at   timestamptz,
  confirm_sends        integer not null default 0 check (confirm_sends >= 0),
  last_confirm_sent_at timestamptz,
  created_at           timestamptz not null default now(),
  confirmed_at         timestamptz,
  unsubscribed_at      timestamptz,
  updated_at           timestamptz not null default now(),
  check (status <> 'confirmed' or confirmed_at is not null),
  check ((confirm_token_hash is null) = (confirm_expires_at is null))
);
create index signups_status_idx on private.signups(status, created_at);

-- Proof of consent. Append-only (see trigger). The email itself is not copied
-- here; on erasure the link is cut (set null) and the row is anonymized.
create table private.consent_events (
  id              bigint generated always as identity primary key,
  signup_id       uuid references private.signups(id) on delete set null,
  event           text not null check (event in ('requested','confirmed','unsubscribed','resubscribe_requested','erased','suppressed')),
  consent_version text,
  detail          jsonb not null default '{}'::jsonb check (pg_column_size(detail) < 2048),
  at              timestamptz not null default now()
);
create index consent_events_signup_idx on private.consent_events(signup_id);

create or replace function private.consent_events_append_only() returns trigger
language plpgsql set search_path = '' as $$
begin
  -- the only allowed UPDATE is the FK cutting the link on erasure
  if tg_op = 'UPDATE' and new.signup_id is null and old.signup_id is not null
     and new.event = old.event and new.at = old.at and new.consent_version is not distinct from old.consent_version
     and new.detail = old.detail then
    return new;
  end if;
  raise exception 'consent_events is append-only';
end $$;
create trigger consent_events_no_change before update or delete on private.consent_events
  for each row execute function private.consent_events_append_only();

create table private.suppressions (
  email_hash text primary key,
  reason     text not null check (reason in ('hard_bounce','complaint','erasure','manual')),
  at         timestamptz not null default now()
);

create table private.counters (
  bucket text not null,            -- 'send_hour' | 'new_day'
  period timestamptz not null,
  used   integer not null default 0,
  primary key (bucket, period)
);

-- RLS on (and forced) everywhere, no policies => nobody but table owner / bypassrls
do $$ declare r record; begin
  for r in select tablename from pg_tables where schemaname = 'private' loop
    execute format('alter table private.%I enable row level security', r.tablename);
    execute format('alter table private.%I force row level security', r.tablename);
    execute format('revoke all on private.%I from public, anon, authenticated, service_role', r.tablename);
  end loop;
end $$;

-- Atomic counter: +1 only while under the cap. Returns false when full.
-- (Single statement => safe under any concurrency, no read-then-write gap.)
create or replace function private.take(p_bucket text, p_period timestamptz, p_cap integer) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v integer;
begin
  if p_cap <= 0 then return false; end if;
  insert into private.counters as c(bucket, period, used) values (p_bucket, p_period, 1)
  on conflict (bucket, period) do update set used = c.used + 1 where c.used < p_cap
  returning c.used into v;
  return v is not null;
end $$;

-- Gives a unit back (only used when the provider call never happened)
create or replace function private.give_back(p_bucket text, p_period timestamptz) returns void
language sql security definer set search_path = '' as $$
  update private.counters set used = greatest(used - 1, 0) where bucket = p_bucket and period = p_period
$$;

-- ================================================================ RPCs
-- All in public so PostgREST can expose them, but EXECUTE only for service_role.

-- 1) Sign-up. Returns {"action":"send","token":..,"signup_id":..,"send_no":..} or {"action":"none"}.
--    `reason` is for logs/metrics only and MUST NOT reach the browser.
create or replace function public.waitlist_signup(p_email text, p_consent_version text, p_locale text default null, p_source text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_email text := private.normalize_email(p_email);
  v_row   private.signups%rowtype;
  v_token text;
  v_hour  timestamptz := date_trunc('hour', now());
  v_day   timestamptz := date_trunc('day', now());
  v_was_unsub boolean;
begin
  if not private.email_ok(v_email) then
    return jsonb_build_object('action','none','reason','invalid_email');
  end if;
  if p_consent_version is distinct from private.cfg_text('current_consent_version') then
    return jsonb_build_object('action','none','reason','stale_consent_version');
  end if;
  if p_locale is not null and p_locale !~ '^[a-z]{2}(-[A-Z]{2})?$' then p_locale := null; end if;
  if p_source is not null and p_source !~ '^[a-z0-9_-]{1,32}$' then p_source := null; end if;

  if exists (select 1 from private.suppressions where email_hash = private.email_hash(v_email)) then
    return jsonb_build_object('action','none','reason','suppressed');
  end if;

  -- lock the row if it exists; otherwise create it (race-safe via unique + on conflict)
  select * into v_row from private.signups where email = v_email for update;
  if not found then
    if not private.take('new_day', v_day, private.cfg_int('global_new_per_day')) then
      return jsonb_build_object('action','none','reason','global_new_cap');
    end if;
    insert into private.signups(email, locale, source, consent_version)
    values (v_email, p_locale, p_source, p_consent_version)
    on conflict (email) do nothing;
    if not found then
      perform private.give_back('new_day', v_day);   -- someone else inserted it a moment ago
    end if;
    select * into v_row from private.signups where email = v_email for update;
  end if;
  if v_row.status = 'confirmed' then
    return jsonb_build_object('action','none','reason','already_confirmed');
  end if;

  -- per-address limits (anti subscription-bombing). Lifetime counter never resets.
  if v_row.confirm_sends >= private.cfg_int('max_confirm_sends') then
    return jsonb_build_object('action','none','reason','address_lifetime_cap');
  end if;
  if v_row.last_confirm_sent_at is not null
     and v_row.last_confirm_sent_at > now() - make_interval(mins => private.cfg_int('resend_min_minutes')) then
    return jsonb_build_object('action','none','reason','address_too_soon');
  end if;
  if not private.take('send_hour', v_hour, private.cfg_int('global_sends_per_hour')) then
    return jsonb_build_object('action','none','reason','global_send_cap');
  end if;

  v_was_unsub := v_row.status = 'unsubscribed';
  v_token := private.new_token();
  update private.signups set
    status               = case when status = 'unsubscribed' then 'pending' else status end,
    consent_version      = p_consent_version,
    locale               = coalesce(p_locale, locale),
    confirm_token_hash   = private.token_hash(v_token),   -- rotation: the previous link stops working
    confirm_expires_at   = now() + make_interval(hours => private.cfg_int('confirm_ttl_hours')),
    confirm_sends        = confirm_sends + 1,
    last_confirm_sent_at = now(),
    updated_at           = now()
  where id = v_row.id
  returning * into v_row;

  -- proof of consent: logged only when a confirmation is really sent (no table growth from repeats)
  insert into private.consent_events(signup_id, event, consent_version, detail)
  values (v_row.id, case when v_was_unsub then 'resubscribe_requested' else 'requested' end,
          p_consent_version, jsonb_build_object('source', p_source, 'send_no', v_row.confirm_sends));

  return jsonb_build_object('action','send','token', v_token, 'signup_id', v_row.id,
                            'send_no', v_row.confirm_sends, 'hour', v_hour);
end $$;

-- 1b) The email provider was never reached (our own fault): give the global unit back.
--     The per-address counter is NOT refunded (an attacker could otherwise loop it).
create or replace function public.waitlist_send_failed(p_hour timestamptz) returns void
language sql security definer set search_path = '' as $$
  select private.give_back('send_hour', date_trunc('hour', p_hour))
$$;

-- 2) Confirm (called only from the explicit button POST, never on GET)
create or replace function public.waitlist_confirm(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_row private.signups%rowtype;
begin
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' then
    return jsonb_build_object('ok', false);
  end if;
  update private.signups set
    status = 'confirmed', confirmed_at = now(), unsubscribed_at = null,
    confirm_token_hash = null, confirm_expires_at = null, updated_at = now()
  where confirm_token_hash = private.token_hash(p_token)
    and confirm_expires_at > now()
    and status = 'pending'
  returning * into v_row;
  if not found then
    return jsonb_build_object('ok', false);   -- unknown, used, rotated or expired: same answer
  end if;
  if exists (select 1 from private.suppressions where email_hash = private.email_hash(v_row.email)) then
    -- suppressed between signup and click: undo, never confirm a suppressed address
    update private.signups set status = 'unsubscribed', confirmed_at = null, unsubscribed_at = now() where id = v_row.id;
    return jsonb_build_object('ok', false);
  end if;
  insert into private.consent_events(signup_id, event, consent_version, detail)
  values (v_row.id, 'confirmed', v_row.consent_version, jsonb_build_object('method','email_link_button'));
  return jsonb_build_object('ok', true);
end $$;

-- 3) Unsubscribe token: HMAC(signup id). Stateless, never expires, works for every email we send.
create or replace function public.waitlist_unsub_token(p_signup_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select translate(rtrim(encode(extensions.hmac(p_signup_id::text, private.secret('unsub_key'), 'sha256'), 'base64'), '='), '+/', '-_')
$$;

create or replace function public.waitlist_unsubscribe(p_signup_id uuid, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_status text;
begin
  if p_signup_id is null or p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$'
     or p_token <> public.waitlist_unsub_token(p_signup_id) then
    return jsonb_build_object('ok', false);
  end if;
  update private.signups set status = 'unsubscribed', unsubscribed_at = now(),
         confirm_token_hash = null, confirm_expires_at = null, updated_at = now()
  where id = p_signup_id and status <> 'unsubscribed'
  returning status into v_status;
  if found then
    insert into private.consent_events(signup_id, event, detail) values (p_signup_id, 'unsubscribed', '{}'::jsonb);
  end if;
  return jsonb_build_object('ok', true);   -- idempotent: unsubscribing twice is still "ok"
end $$;

-- 4) Provider webhook: hard bounce / spam complaint => never email again
create or replace function public.waitlist_suppress(p_email text, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if p_reason not in ('hard_bounce','complaint','manual') then raise exception 'bad reason'; end if;
  insert into private.suppressions(email_hash, reason) values (private.email_hash(p_email), p_reason)
  on conflict (email_hash) do nothing;
  update private.signups set status = 'unsubscribed', unsubscribed_at = now(),
         confirm_token_hash = null, confirm_expires_at = null, updated_at = now()
  where email = private.normalize_email(p_email) and status <> 'unsubscribed'
  returning id into v_id;
  if v_id is not null then
    insert into private.consent_events(signup_id, event, detail) values (v_id, 'suppressed', jsonb_build_object('reason', p_reason));
  end if;
end $$;

-- 5) Erasure request (GDPR Art. 17): delete the person, keep only a keyed hash
--    so we never email them again (document this in the privacy page).
create or replace function public.waitlist_erase(p_email text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  delete from private.signups where email = private.normalize_email(p_email) returning id into v_id;
  insert into private.suppressions(email_hash, reason) values (private.email_hash(p_email), 'erasure')
  on conflict (email_hash) do update set reason = 'erasure', at = now();
  insert into private.consent_events(event, detail) values ('erased', '{}'::jsonb);
end $$;

-- 6) Launch export: confirmed only, never suppressed. Run by the owner, not by the site.
create or replace function public.waitlist_export_confirmed()
returns table(signup_id uuid, email text, confirmed_at timestamptz, consent_version text, locale text)
language sql stable security definer set search_path = '' as $$
  select s.id, s.email, s.confirmed_at, s.consent_version, s.locale
  from private.signups s
  where s.status = 'confirmed'
    and not exists (select 1 from private.suppressions x where x.email_hash = private.email_hash(s.email))
  order by s.confirmed_at
$$;

-- 7) Public counter for the landing page ("1,234 people joined") — optional.
--    Rounded down to the nearest 10 so it cannot be used to detect one signup.
create or replace function public.waitlist_public_count() returns integer
language sql stable security definer set search_path = '' as $$
  select (count(*) / 10 * 10)::integer from private.signups where status = 'confirmed'
$$;

-- 8) Daily maintenance (pg_cron): data minimization + counter cleanup
create or replace function public.waitlist_maintenance() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a integer; b integer; c integer;
begin
  delete from private.signups
   where status = 'pending' and created_at < now() - make_interval(days => private.cfg_int('pending_retention_days'));
  get diagnostics a = row_count;
  delete from private.signups
   where status = 'unsubscribed' and coalesce(unsubscribed_at, updated_at) < now() - make_interval(days => private.cfg_int('unsub_retention_days'));
  get diagnostics b = row_count;
  delete from private.counters where period < now() - interval '3 days';
  get diagnostics c = row_count;
  return jsonb_build_object('pending_deleted', a, 'unsubscribed_deleted', b, 'counters_deleted', c);
end $$;

-- ---------------------------------------------------------------- privileges
revoke all on all functions in schema private from public, anon, authenticated;
revoke all on all functions in schema public  from public, anon, authenticated;
do $$ declare f text; begin
  foreach f in array array[
    'public.waitlist_signup(text,text,text,text)', 'public.waitlist_send_failed(timestamptz)',
    'public.waitlist_confirm(text)', 'public.waitlist_unsub_token(uuid)',
    'public.waitlist_unsubscribe(uuid,text)', 'public.waitlist_suppress(text,text)',
    'public.waitlist_erase(text)', 'public.waitlist_export_confirmed()',
    'public.waitlist_public_count()', 'public.waitlist_maintenance()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;


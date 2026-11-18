-- =====================================================================
-- 0006 — partner applications ("Work with us": coaches and creators make
-- ads / reviews of our apps on their social media and get paid)
--   * ONE application per email address, ever (owner decision 2026-11-18).
--     A second try is answered like a success but stores and sends nothing.
--   * Daily cap on applications for the whole site (stops table flooding).
--   * Two emails per application: one FIXED text to the applicant (never any
--     visitor text in it, so the form cannot be used to send spam) and one
--     to the owner with the details. Both count toward the same hourly/daily
--     send caps as the waitlist, so the Resend quota is shared fairly.
--   * If a send cap is full or sending is paused, the application is still
--     saved (nothing is lost) and the owner gets an alert.
--   * Same validation in SQL as in the Edge Function (last line of defence).
--   * Deleted automatically after partner_retention_days.
-- Every number is an EXAMPLE; the owner decides them in private.settings.
-- =====================================================================

insert into private.settings(key, value) values
  ('partner_per_day',          '20'),          -- EXAMPLE: new applications per day, whole site
  ('partner_retention_days',   '365'),         -- EXAMPLE: applications are deleted after this
  ('partner_consent_version',  'partners-v1')  -- must equal data-consent-version on site/partners.html
on conflict (key) do nothing;

-- ---------------------------------------------------------------- table
create table private.partner_applications (
  id              uuid primary key default gen_random_uuid(),
  email           text not null unique check (private.email_ok(email)),
  name            text not null check (length(name) between 1 and 80),
  handles         jsonb not null check (jsonb_typeof(handles) = 'array' and pg_column_size(handles) < 1024),
  pitch           text not null check (length(pitch) between 10 and 1000),
  consent_version text not null,
  created_at      timestamptz not null default now()
);
alter table private.partner_applications enable row level security;
alter table private.partner_applications force  row level security;
revoke all on private.partner_applications from public, anon, authenticated, service_role;

-- new alert kind: an application was saved but its emails were skipped (cap full / paused)
alter table private.alerts drop constraint alerts_kind_check;
alter table private.alerts add constraint alerts_kind_check check (kind in (
  'global_send_cap','global_send_day_cap','global_new_cap','queue_full','paused_signups','auto_paused',
  'partner_mail_skipped'));

-- ---------------------------------------------------------------- validation
-- Hidden / control characters are refused, never cleaned (same set as validate.ts).
create or replace function private.has_hidden(p text) returns boolean
language sql immutable set search_path = '' as $$
  select p ~ '[[:cntrl:]]'
      or p ~ '[\u0080-\u009f\u00ad\u061c\u180e\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]'
$$;

-- name: 1..80 characters, any language, but no links, no email addresses, no markup
create or replace function private.partner_name_ok(p text) returns boolean
language sql immutable set search_path = '' as $$
  select p is not null and p = btrim(p) and length(p) between 1 and 80
     and not private.has_hidden(p)
     and p !~ '[<>@/\\:;{}\[\]|`$*=]'
     and p !~* 'www\.|https?'
$$;

-- handles: 1..3 of {"platform": one of the list, "username": letters/digits/._- (optional leading @)}
create or replace function private.partner_handles_ok(p jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select p is not null and jsonb_typeof(p) = 'array'
     and jsonb_array_length(p) between 1 and 3
     and not exists (
       select 1 from jsonb_array_elements(p) h
        where jsonb_typeof(h) <> 'object'
           or (select count(*) from jsonb_object_keys(h)) <> 2
           or h->>'platform' is null or h->>'username' is null
           or h->>'platform' not in ('instagram','tiktok','youtube','x','facebook','snapchat','other')
           or h->>'username' !~ '^@?[A-Za-z0-9._-]{1,50}$')
$$;

-- pitch: 10..1000 characters, line breaks allowed, nothing hidden
create or replace function private.partner_pitch_ok(p text) returns boolean
language sql immutable set search_path = '' as $$
  select p is not null and p = btrim(p) and length(p) between 10 and 1000
     and not private.has_hidden(replace(p, E'\n', ''))
$$;

-- ---------------------------------------------------------------- RPC
-- Returns {"action":"send","id":..,"hour":..}  -> the Edge Function sends both emails
--         {"action":"saved","reason":..}       -> saved, but no email (cap full / paused)
--         {"action":"none","reason":..}        -> nothing stored, nothing sent
-- The function answers the visitor the SAME for send / saved / none, except "busy"
-- (daily application cap) and invalid input, which reveal nothing about anyone.
create or replace function public.waitlist_partner_apply(
  p_email text, p_name text, p_handles jsonb, p_pitch text, p_consent_version text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_email text := private.normalize_email(p_email);
  v_hour  timestamptz := date_trunc('hour', now());
  v_day   timestamptz := date_trunc('day', now());
  v_id    uuid;
  v_taken integer := 0;
begin
  if not private.email_ok(v_email) then return jsonb_build_object('action','none','reason','invalid_email'); end if;
  if p_consent_version is distinct from private.cfg_text('partner_consent_version') then
    return jsonb_build_object('action','none','reason','stale_consent_version');
  end if;
  if not (private.partner_name_ok(p_name) and private.partner_handles_ok(p_handles) and private.partner_pitch_ok(p_pitch)) then
    return jsonb_build_object('action','none','reason','invalid_fields');
  end if;
  -- deleted-my-data, bounced or complained => never store or email again
  if exists (select 1 from private.suppressions where email_hash = private.email_hash(v_email)) then
    return jsonb_build_object('action','none','reason','suppressed');
  end if;
  -- one try per address, ever (checked before the daily unit, so a repeat costs nothing)
  if exists (select 1 from private.partner_applications where email = v_email) then
    return jsonb_build_object('action','none','reason','already_applied');
  end if;
  if not private.take('partner_day', v_day, private.cfg_int('partner_per_day')) then
    return jsonb_build_object('action','none','reason','busy');
  end if;
  insert into private.partner_applications(email, name, handles, pitch, consent_version)
  values (v_email, p_name, p_handles, p_pitch, p_consent_version)
  on conflict (email) do nothing
  returning id into v_id;
  if v_id is null then                       -- lost a race with the same address
    perform private.give_back('partner_day', v_day);
    return jsonb_build_object('action','none','reason','already_applied');
  end if;

  -- two emails (applicant + owner) from the shared hourly and daily send caps
  if private.is_paused() then
    perform private.raise_alert('partner_mail_skipped', v_day);
    return jsonb_build_object('action','saved','reason','paused');
  end if;
  while v_taken < 2 loop
    if not private.take('send_hour', v_hour, private.cfg_int('global_sends_per_hour')) then exit; end if;
    if not private.take('send_day', v_day, private.cfg_int('global_sends_per_day')) then
      perform private.give_back('send_hour', v_hour);
      exit;
    end if;
    v_taken := v_taken + 1;
  end loop;
  if v_taken < 2 then
    for i in 1..v_taken loop
      perform private.give_back('send_hour', v_hour);
      perform private.give_back('send_day', v_day);
    end loop;
    perform private.raise_alert('partner_mail_skipped', v_day);
    return jsonb_build_object('action','saved','reason','send_cap');
  end if;
  return jsonb_build_object('action','send','id',v_id,'hour',v_hour);
end $$;

-- ---------------------------------------------------------------- erasure + retention
-- Re-stated from 0001: owner-run erasure also deletes a partner application.
create or replace function public.waitlist_erase(p_email text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  delete from private.signups where email = private.normalize_email(p_email) returning id into v_id;
  delete from private.partner_applications where email = private.normalize_email(p_email);
  insert into private.suppressions(email_hash, reason) values (private.email_hash(p_email), 'erasure')
  on conflict (email_hash) do update set reason = 'erasure', at = now();
  insert into private.consent_events(event, detail) values ('erased', '{}'::jsonb);
end $$;

-- Re-stated from 0005: also deletes partner applications older than partner_retention_days.
create or replace function public.waitlist_maintenance() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a integer; b integer; c integer; d integer; e integer;
begin
  delete from private.signups
   where status = 'pending'
     and coalesce(last_confirm_sent_at, created_at) < now() - make_interval(days => private.cfg_int('pending_retention_days'));
  get diagnostics a = row_count;
  delete from private.signups
   where status = 'unsubscribed' and coalesce(unsubscribed_at, updated_at) < now() - make_interval(days => private.cfg_int('unsub_retention_days'));
  get diagnostics b = row_count;
  delete from private.counters where period < now() - interval '3 days';
  get diagnostics c = row_count;
  delete from private.alerts where first_at < now() - interval '30 days';
  get diagnostics d = row_count;
  delete from private.partner_applications
   where created_at < now() - make_interval(days => private.cfg_int('partner_retention_days'));
  get diagnostics e = row_count;
  return jsonb_build_object('pending_deleted', a, 'unsubscribed_deleted', b, 'counters_deleted', c,
                            'alerts_deleted', d, 'partner_deleted', e);
end $$;

-- ---------------------------------------------------------------- privileges
revoke all on function private.has_hidden(text)          from public, anon, authenticated;
revoke all on function private.partner_name_ok(text)     from public, anon, authenticated;
revoke all on function private.partner_handles_ok(jsonb) from public, anon, authenticated;
revoke all on function private.partner_pitch_ok(text)    from public, anon, authenticated;
do $$ declare f text; begin
  foreach f in array array[
    'public.waitlist_partner_apply(text,text,jsonb,text,text)',
    'public.waitlist_erase(text)', 'public.waitlist_maintenance()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

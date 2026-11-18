-- =====================================================================
-- 0008 — fixes from the Codex security audit (reviews/codex-security-audit.md, 2026-11-18)
--   #3  Partner acknowledgements now share the per-MAILBOX daily cap with waitlist
--       confirmations, so "+tag" variants of one inbox cannot each get an email
--       (inbox bombing). Exact addresses stay separate identities (W-2).
--   #5  When the daily application cap is full, EVERY address gets the same "busy"
--       answer, so a full cap no longer reveals who already applied or was deleted.
--   #11 Erasure now writes the do-not-email entry BEFORE deleting rows, the same
--       lock order as the bounce/complaint webhook, so the two can no longer deadlock.
--   #15 Partner queue admission is serialised, so parallel requeues respect the cap.
-- =====================================================================

-- ---------------------------------------------------------------- #15 queue cap race
create or replace function private.partner_enqueue(p_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('partner_mail_queue', 0));   -- one admission at a time
  if exists (select 1 from private.partner_mail_queue where application_id = p_id) then return true; end if;
  if (select count(*) from private.partner_mail_queue) >= private.cfg_int('partner_queue_max') then
    return false;
  end if;
  insert into private.partner_mail_queue(application_id) values (p_id) on conflict do nothing;
  return true;
end $$;

-- ---------------------------------------------------------------- #3 + #5 apply
-- Re-stated from 0007. Changes:
--   * "busy" is decided FIRST, before anything about the address is looked at;
--   * the applicant email takes one unit of the per-mailbox daily cap (shared with
--     waitlist confirmations). Mailbox full => nothing stored, nothing sent, and the
--     visitor gets the usual 202 (no feedback that teaches the attacker anything).
create or replace function public.waitlist_partner_apply(
  p_email text, p_name text, p_handles jsonb, p_pitch text, p_consent_version text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_email text := private.normalize_email(p_email);
  v_hour  timestamptz := date_trunc('hour', now());
  v_day   timestamptz := date_trunc('day', now());
  v_mbx   text;
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
  -- #5: a full day is "busy" for everybody, whatever the address
  if coalesce((select used from private.counters where bucket = 'partner_day' and period = v_day), 0)
     >= private.cfg_int('partner_per_day') then
    return jsonb_build_object('action','none','reason','busy');
  end if;
  if exists (select 1 from private.suppressions where email_hash = private.email_hash(v_email)) then
    return jsonb_build_object('action','none','reason','suppressed');
  end if;
  if exists (select 1 from private.partner_applications where email = v_email) then
    return jsonb_build_object('action','none','reason','already_applied');
  end if;
  -- #3: one inbox (all its +tag variants) gets at most mailbox_sends_per_day emails from us per day
  v_mbx := private.mailbox_bucket(v_email);
  if not private.take(v_mbx, v_day, private.cfg_int('mailbox_sends_per_day')) then
    return jsonb_build_object('action','none','reason','mailbox_cap');
  end if;
  if not private.take('partner_day', v_day, private.cfg_int('partner_per_day')) then
    perform private.give_back(v_mbx, v_day);
    return jsonb_build_object('action','none','reason','busy');   -- lost the last slot in a race
  end if;
  insert into private.partner_applications(email, name, handles, pitch, consent_version)
  values (v_email, p_name, p_handles, p_pitch, p_consent_version)
  on conflict (email) do nothing
  returning id into v_id;
  if v_id is null then
    perform private.give_back('partner_day', v_day);
    perform private.give_back(v_mbx, v_day);
    return jsonb_build_object('action','none','reason','already_applied');
  end if;

  if private.is_paused() then
    perform private.raise_alert('partner_mail_skipped', v_day);
    return jsonb_build_object('action','saved','reason','paused','queued', private.partner_enqueue(v_id));
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
    return jsonb_build_object('action','saved','reason','send_cap','queued', private.partner_enqueue(v_id));
  end if;
  return jsonb_build_object('action','send','id',v_id,'hour',v_hour);
end $$;

-- ---------------------------------------------------------------- #11 erasure lock order
-- Same order as waitlist_suppress (0005): suppression row first, then the signup row.
-- Re-stated from 0006 (owner-run erasure).
create or replace function public.waitlist_erase(p_email text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into private.suppressions(email_hash, reason) values (private.email_hash(p_email), 'erasure')
  on conflict (email_hash) do update set reason = 'erasure', at = now();
  delete from private.signups where email = private.normalize_email(p_email);
  delete from private.partner_applications where email = private.normalize_email(p_email);
  insert into private.consent_events(event, detail) values ('erased', '{}'::jsonb);
end $$;

-- Re-stated from 0003 (self-service "Delete my data"). Also removes a partner
-- application of the same address, like the owner-run erasure.
create or replace function public.waitlist_erase_by_token(p_signup_id uuid, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_email text;
begin
  if p_signup_id is null or p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$'
     or p_token <> public.waitlist_unsub_token(p_signup_id) then
    return jsonb_build_object('ok', false);
  end if;
  select email into v_email from private.signups where id = p_signup_id;      -- no row lock yet
  if v_email is not null then
    insert into private.suppressions(email_hash, reason) values (private.email_hash(v_email), 'erasure')
    on conflict (email_hash) do update set reason = 'erasure', at = now();
    delete from private.signups where id = p_signup_id;
    delete from private.partner_applications where email = v_email;
    insert into private.consent_events(event, detail) values ('erased', jsonb_build_object('method', 'self_service_link'));
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- privileges
revoke all on function private.partner_enqueue(uuid) from public, anon, authenticated;
do $$ declare f text; begin
  foreach f in array array[
    'public.waitlist_partner_apply(text,text,jsonb,text,text)',
    'public.waitlist_erase(text)', 'public.waitlist_erase_by_token(uuid,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

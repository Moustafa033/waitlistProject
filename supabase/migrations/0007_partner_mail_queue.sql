-- =====================================================================
-- 0007 — partner mail queue (owner request 2026-11-18)
--   0006 saved an application WITHOUT its two emails when the send cap was full
--   or sending was paused. Now that application is also QUEUED, and the
--   scheduled job (POST /drain, every ~10 min) sends both emails as soon as there
--   is room: the fixed confirmation to the applicant and the details to the owner.
--   * The queue stores no copy of anything: only the application id. Deleting or
--     erasing the application removes its queue entry automatically.
--   * Bounded (partner_queue_max). A full queue still saves the application and
--     raises the owner alert; nothing is ever lost.
--   * Waitlist confirmations keep priority: the job drains their queue first.
--   * The daily APPLICATION cap (partner_per_day) is unchanged: past it,
--     applications are refused ("try again tomorrow"), never queued.
-- Every number is an EXAMPLE; the owner decides them in private.settings.
-- =====================================================================

insert into private.settings(key, value) values
  ('partner_queue_max', '1000')   -- EXAMPLE: most applications waiting for their emails at once
on conflict (key) do nothing;

create table private.partner_mail_queue (
  application_id uuid primary key references private.partner_applications(id) on delete cascade,
  queued_at      timestamptz not null default now()
);
create index partner_mail_queue_order_idx on private.partner_mail_queue(queued_at);
alter table private.partner_mail_queue enable row level security;
alter table private.partner_mail_queue force  row level security;
revoke all on private.partner_mail_queue from public, anon, authenticated, service_role;

-- Puts an application in the queue (bounded). Returns true if it is now queued.
create or replace function private.partner_enqueue(p_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from private.partner_mail_queue where application_id = p_id) then return true; end if;
  if (select count(*) from private.partner_mail_queue) >= private.cfg_int('partner_queue_max') then
    return false;
  end if;
  insert into private.partner_mail_queue(application_id) values (p_id) on conflict do nothing;
  return true;
end $$;

-- ---------------------------------------------------------------- apply
-- Re-stated from 0006. Only change: when the emails cannot go out now, the application
-- is queued ("queued": true) as well as saved, and the owner alert is still raised.
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
  if exists (select 1 from private.suppressions where email_hash = private.email_hash(v_email)) then
    return jsonb_build_object('action','none','reason','suppressed');
  end if;
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
  if v_id is null then
    perform private.give_back('partner_day', v_day);
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

-- ---------------------------------------------------------------- drain
-- Called by the scheduled job AFTER the waitlist queue. Sends at most drain_batch
-- applications per run, each needing 2 units of the shared hourly and daily caps.
-- Rows are taken with SKIP LOCKED and removed in the same transaction, so two job
-- runs at once never send the same application twice. Never waits on a lock held
-- by a live application (same lock rule as waitlist_drain_queue in 0005).
create or replace function public.waitlist_drain_partner_queue() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  q      record;
  a      private.partner_applications%rowtype;
  v_hour timestamptz := date_trunc('hour', now());
  v_day  timestamptz := date_trunc('day', now());
  v_out  jsonb := '[]'::jsonb;
  v_n    integer := 0;
begin
  if not private.is_paused() then
    for q in select application_id from private.partner_mail_queue order by queued_at
             for update skip locked loop
      exit when v_n >= private.cfg_int('drain_batch');
      select * into a from private.partner_applications where id = q.application_id;
      -- erased or bounced since it was queued => leave the queue, send nothing
      if not found or exists (select 1 from private.suppressions where email_hash = private.email_hash(a.email)) then
        delete from private.partner_mail_queue where application_id = q.application_id;
        continue;
      end if;
      if not private.take('send_hour', v_hour, private.cfg_int('global_sends_per_hour')) then exit; end if;
      if not private.take('send_day', v_day, private.cfg_int('global_sends_per_day')) then
        perform private.give_back('send_hour', v_hour); exit;
      end if;
      if not private.take('send_hour', v_hour, private.cfg_int('global_sends_per_hour')) then
        perform private.give_back('send_hour', v_hour); perform private.give_back('send_day', v_day); exit;
      end if;
      if not private.take('send_day', v_day, private.cfg_int('global_sends_per_day')) then
        perform private.give_back('send_hour', v_hour); perform private.give_back('send_hour', v_hour);
        perform private.give_back('send_day', v_day); exit;
      end if;
      delete from private.partner_mail_queue where application_id = a.id;
      v_out := v_out || jsonb_build_object('id', a.id, 'email', a.email, 'name', a.name, 'handles', a.handles,
                                           'pitch', a.pitch, 'hour', v_hour);
      v_n := v_n + 1;
    end loop;
  end if;
  return jsonb_build_object('sends', v_out, 'left', (select count(*) from private.partner_mail_queue),
                            'paused', private.is_paused());
end $$;

-- ---------------------------------------------------------------- requeue
-- The Edge Function calls this when an email could not reach the provider (network down),
-- so the application's emails are retried by the next job run instead of being lost.
-- Re-sending is safe: every email carries a fixed idempotency key (partner-ack/<id>,
-- partner-owner/<id>), so the provider never delivers a duplicate.
create or replace function public.waitlist_partner_requeue(p_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if p_id is null or not exists (select 1 from private.partner_applications where id = p_id) then return false; end if;
  return private.partner_enqueue(p_id);
end $$;

-- ---------------------------------------------------------------- privileges
revoke all on function private.partner_enqueue(uuid) from public, anon, authenticated;
do $$ declare f text; begin
  foreach f in array array[
    'public.waitlist_partner_apply(text,text,jsonb,text,text)', 'public.waitlist_drain_partner_queue()',
    'public.waitlist_partner_requeue(uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

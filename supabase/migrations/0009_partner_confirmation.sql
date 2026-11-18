-- =====================================================================
-- 0009 — partner applications need a confirmed email (Codex audit #1, owner decision 2026-11-18)
--   Before: anyone could apply with someone else's address, use up that address's one
--   application, and the owner received the fake details.
--   Now:
--   * A new application is stored as PENDING and the applicant gets ONE fixed email
--     with a "Confirm application" button (token in the URL fragment, like the waitlist).
--   * Only a confirmed application uses the "one per address" slot, and only then is
--     the owner notified (1 email). No separate "we received" email any more: the
--     confirm page says it.
--   * A pending application never blocks the real person: applying again replaces the
--     details and sends a new link (bounded: resend_min_minutes between links and
--     partner_max_confirm_sends per address), and unconfirmed rows are deleted after
--     partner_confirm_ttl_hours.
--   * The queue (0007) now holds either kind of email; the row's status decides which:
--     pending -> confirmation link (a fresh token is made at send time),
--     confirmed -> owner notice.
-- Every number is an EXAMPLE; the owner decides them in private.settings.
-- =====================================================================

insert into private.settings(key, value) values
  ('partner_confirm_ttl_hours', '48'),  -- EXAMPLE: confirmation link lifetime; unconfirmed rows deleted after this
  ('partner_max_confirm_sends', '3')    -- EXAMPLE: confirmation emails per pending application
on conflict (key) do nothing;

-- Existing rows were sent before confirmation existed: they stay valid as confirmed.
alter table private.partner_applications
  add column status               text not null default 'confirmed' check (status in ('pending','confirmed')),
  add column confirm_token_hash   bytea,
  add column confirm_expires_at   timestamptz,
  add column confirm_sends        integer not null default 0,
  add column last_confirm_sent_at timestamptz,
  add column confirmed_at         timestamptz;
update private.partner_applications set confirmed_at = created_at where confirmed_at is null;
alter table private.partner_applications alter column status set default 'pending';
alter table private.partner_applications add constraint partner_confirmed_has_time
  check (status <> 'confirmed' or confirmed_at is not null);
create unique index partner_applications_token_idx on private.partner_applications(confirm_token_hash)
  where confirm_token_hash is not null;

-- ---------------------------------------------------------------- apply
-- Re-stated from 0008. Returns
--   {"action":"send","kind":"confirm","id","token","send_no","hour"}  -> the function emails the link
--   {"action":"saved","reason","queued"}                             -> stored, link sent later by the queue
--   {"action":"none","reason"}                                       -> nothing stored, nothing sent
create or replace function public.waitlist_partner_apply(
  p_email text, p_name text, p_handles jsonb, p_pitch text, p_consent_version text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_email text := private.normalize_email(p_email);
  v_hour  timestamptz := date_trunc('hour', now());
  v_day   timestamptz := date_trunc('day', now());
  v_mbx   text;
  v_row   private.partner_applications%rowtype;
  v_new   boolean := false;
  v_token text;
begin
  if not private.email_ok(v_email) then return jsonb_build_object('action','none','reason','invalid_email'); end if;
  if p_consent_version is distinct from private.cfg_text('partner_consent_version') then
    return jsonb_build_object('action','none','reason','stale_consent_version');
  end if;
  if not (private.partner_name_ok(p_name) and private.partner_handles_ok(p_handles) and private.partner_pitch_ok(p_pitch)) then
    return jsonb_build_object('action','none','reason','invalid_fields');
  end if;
  -- a full day is "busy" for everybody, whatever the address (audit #5)
  if coalesce((select used from private.counters where bucket = 'partner_day' and period = v_day), 0)
     >= private.cfg_int('partner_per_day') then
    return jsonb_build_object('action','none','reason','busy');
  end if;
  if exists (select 1 from private.suppressions where email_hash = private.email_hash(v_email)) then
    return jsonb_build_object('action','none','reason','suppressed');
  end if;

  select * into v_row from private.partner_applications where email = v_email for update;
  if found then
    if v_row.status = 'confirmed' then
      return jsonb_build_object('action','none','reason','already_applied');
    end if;
    -- pending: the newest details win, but links are rate-limited per address
    if v_row.confirm_sends >= private.cfg_int('partner_max_confirm_sends') then
      return jsonb_build_object('action','none','reason','address_cap');
    end if;
    if v_row.last_confirm_sent_at is not null
       and v_row.last_confirm_sent_at > now() - make_interval(mins => private.cfg_int('resend_min_minutes')) then
      return jsonb_build_object('action','none','reason','too_soon');
    end if;
  end if;

  -- one inbox (all its +tag variants) gets at most mailbox_sends_per_day emails from us per day (audit #3)
  v_mbx := private.mailbox_bucket(v_email);
  if not private.take(v_mbx, v_day, private.cfg_int('mailbox_sends_per_day')) then
    return jsonb_build_object('action','none','reason','mailbox_cap');
  end if;

  if v_row.id is null then
    if not private.take('partner_day', v_day, private.cfg_int('partner_per_day')) then
      perform private.give_back(v_mbx, v_day);
      return jsonb_build_object('action','none','reason','busy');
    end if;
    insert into private.partner_applications(email, name, handles, pitch, consent_version, status)
    values (v_email, p_name, p_handles, p_pitch, p_consent_version, 'pending')
    on conflict (email) do nothing
    returning * into v_row;
    if v_row.id is null then                         -- same address in a parallel request
      perform private.give_back('partner_day', v_day);
      perform private.give_back(v_mbx, v_day);
      return jsonb_build_object('action','none','reason','already_applied');
    end if;
  else
    update private.partner_applications
       set name = p_name, handles = p_handles, pitch = p_pitch, consent_version = p_consent_version
     where id = v_row.id;
  end if;

  -- the confirmation email: 1 unit of the shared hourly and daily caps
  if private.is_paused() then
    perform private.raise_alert('partner_mail_skipped', v_day);
    return jsonb_build_object('action','saved','reason','paused','queued', private.partner_enqueue(v_row.id));
  end if;
  if not private.take('send_hour', v_hour, private.cfg_int('global_sends_per_hour')) then
    perform private.raise_alert('partner_mail_skipped', v_day);
    return jsonb_build_object('action','saved','reason','send_cap','queued', private.partner_enqueue(v_row.id));
  end if;
  if not private.take('send_day', v_day, private.cfg_int('global_sends_per_day')) then
    perform private.give_back('send_hour', v_hour);
    perform private.raise_alert('partner_mail_skipped', v_day);
    return jsonb_build_object('action','saved','reason','send_cap','queued', private.partner_enqueue(v_row.id));
  end if;

  v_token := private.new_token();
  update private.partner_applications set
    confirm_token_hash   = private.token_hash(v_token),
    confirm_expires_at   = now() + make_interval(hours => private.cfg_int('partner_confirm_ttl_hours')),
    confirm_sends        = confirm_sends + 1,
    last_confirm_sent_at = now()
  where id = v_row.id
  returning * into v_row;
  return jsonb_build_object('action','send','kind','confirm','id',v_row.id,'token',v_token,
                            'send_no',v_row.confirm_sends,'hour',v_hour);
end $$;

-- ---------------------------------------------------------------- confirm
-- Called by the function when a person presses "Confirm application" (POST, Turnstile).
-- Single-use: the token is cleared. Returns {"ok":false} for anything invalid, expired,
-- used or suppressed (the same answer for all). On success the owner notice is due:
--   {"ok":true,"action":"send","id","hour","email","name","handles","pitch"}  or
--   {"ok":true,"action":"queued"}  (send cap full / paused: the queue sends it later)
create or replace function public.waitlist_partner_confirm(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a      private.partner_applications%rowtype;
  v_hour timestamptz := date_trunc('hour', now());
  v_day  timestamptz := date_trunc('day', now());
begin
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' then return jsonb_build_object('ok', false); end if;
  select * into a from private.partner_applications
   where confirm_token_hash = private.token_hash(p_token) and status = 'pending'
   for update;
  if not found or a.confirm_expires_at is null or a.confirm_expires_at < now() then
    return jsonb_build_object('ok', false);
  end if;
  if exists (select 1 from private.suppressions where email_hash = private.email_hash(a.email)) then
    return jsonb_build_object('ok', false);
  end if;
  update private.partner_applications
     set status = 'confirmed', confirmed_at = now(), confirm_token_hash = null, confirm_expires_at = null
   where id = a.id;

  if private.is_paused()
     or not private.take('send_hour', v_hour, private.cfg_int('global_sends_per_hour')) then
    perform private.raise_alert('partner_mail_skipped', v_day);
    perform private.partner_enqueue(a.id);
    return jsonb_build_object('ok', true, 'action', 'queued');
  end if;
  if not private.take('send_day', v_day, private.cfg_int('global_sends_per_day')) then
    perform private.give_back('send_hour', v_hour);
    perform private.raise_alert('partner_mail_skipped', v_day);
    perform private.partner_enqueue(a.id);
    return jsonb_build_object('ok', true, 'action', 'queued');
  end if;
  return jsonb_build_object('ok', true, 'action', 'send', 'id', a.id, 'hour', v_hour,
                            'email', a.email, 'name', a.name, 'handles', a.handles, 'pitch', a.pitch);
end $$;

-- ---------------------------------------------------------------- drain
-- Re-stated from 0007. Each row now needs ONE email; its status decides which:
--   pending   -> a confirmation link (a fresh token is made now; within the per-address cap)
--   confirmed -> the owner notice
create or replace function public.waitlist_drain_partner_queue() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  q       record;
  a       private.partner_applications%rowtype;
  v_hour  timestamptz := date_trunc('hour', now());
  v_day   timestamptz := date_trunc('day', now());
  v_out   jsonb := '[]'::jsonb;
  v_n     integer := 0;
  v_token text;
begin
  if not private.is_paused() then
    for q in select application_id from private.partner_mail_queue order by queued_at
             for update skip locked loop
      exit when v_n >= private.cfg_int('drain_batch');
      select * into a from private.partner_applications where id = q.application_id;
      if not found
         or exists (select 1 from private.suppressions where email_hash = private.email_hash(a.email))
         or (a.status = 'pending' and a.confirm_sends >= private.cfg_int('partner_max_confirm_sends')) then
        delete from private.partner_mail_queue where application_id = q.application_id;
        continue;
      end if;
      if not private.take('send_hour', v_hour, private.cfg_int('global_sends_per_hour')) then exit; end if;
      if not private.take('send_day', v_day, private.cfg_int('global_sends_per_day')) then
        perform private.give_back('send_hour', v_hour); exit;
      end if;
      delete from private.partner_mail_queue where application_id = a.id;
      if a.status = 'pending' then
        v_token := private.new_token();
        update private.partner_applications set
          confirm_token_hash   = private.token_hash(v_token),
          confirm_expires_at   = now() + make_interval(hours => private.cfg_int('partner_confirm_ttl_hours')),
          confirm_sends        = confirm_sends + 1,
          last_confirm_sent_at = now()
        where id = a.id
        returning * into a;
        v_out := v_out || jsonb_build_object('kind', 'confirm', 'id', a.id, 'email', a.email, 'token', v_token,
                                             'send_no', a.confirm_sends, 'hour', v_hour);
      else
        v_out := v_out || jsonb_build_object('kind', 'owner', 'id', a.id, 'email', a.email, 'name', a.name,
                                             'handles', a.handles, 'pitch', a.pitch, 'hour', v_hour);
      end if;
      v_n := v_n + 1;
    end loop;
  end if;
  return jsonb_build_object('sends', v_out, 'left', (select count(*) from private.partner_mail_queue),
                            'paused', private.is_paused());
end $$;

-- ---------------------------------------------------------------- retention
-- Re-stated from 0006: also deletes unconfirmed applications once their link has expired.
create or replace function public.waitlist_maintenance() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a integer; b integer; c integer; d integer; e integer; f integer;
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
  delete from private.partner_applications
   where status = 'pending'
     and coalesce(last_confirm_sent_at, created_at) < now() - make_interval(hours => private.cfg_int('partner_confirm_ttl_hours'))
     and not exists (select 1 from private.partner_mail_queue q where q.application_id = partner_applications.id);
  get diagnostics f = row_count;
  return jsonb_build_object('pending_deleted', a, 'unsubscribed_deleted', b, 'counters_deleted', c,
                            'alerts_deleted', d, 'partner_deleted', e, 'partner_unconfirmed_deleted', f);
end $$;

-- ---------------------------------------------------------------- privileges
do $$ declare f text; begin
  foreach f in array array[
    'public.waitlist_partner_apply(text,text,jsonb,text,text)', 'public.waitlist_partner_confirm(text)',
    'public.waitlist_drain_partner_queue()', 'public.waitlist_maintenance()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- =====================================================================
-- 0002 — global DAILY cap on confirmation emails.
--
-- Why: 0001 only caps emails per HOUR (example 500). The email provider's plan has its own
-- DAILY limit (Resend free: 100/day). An attacker who pays a CAPTCHA farm could otherwise push
-- the account over that limit (provider errors, account warnings, sender reputation damage).
-- With this cap the database never asks for more emails per day than the plan allows.
-- EXAMPLE value 90 (owner decides; raise it when the email plan is upgraded):
--   update private.settings set value = '<n>' where key = 'global_sends_per_day';
--
-- Same rules as 0001: single-statement atomic counters, return a reason (never raise),
-- SECURITY DEFINER + search_path = '', EXECUTE for service_role only.
-- =====================================================================

insert into private.settings(key, value) values ('global_sends_per_day', '90')
on conflict (key) do nothing;

-- Same function as 0001 plus the daily cap (taken right after the hourly cap; if the daily
-- cap is full, the hourly unit is given back so the two counters never drift apart).
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

  select * into v_row from private.signups where email = v_email for update;
  if not found then
    if not private.take('new_day', v_day, private.cfg_int('global_new_per_day')) then
      return jsonb_build_object('action','none','reason','global_new_cap');
    end if;
    insert into private.signups(email, locale, source, consent_version)
    values (v_email, p_locale, p_source, p_consent_version)
    on conflict (email) do nothing;
    if not found then
      perform private.give_back('new_day', v_day);
    end if;
    select * into v_row from private.signups where email = v_email for update;
  end if;
  if v_row.status = 'confirmed' then
    return jsonb_build_object('action','none','reason','already_confirmed');
  end if;

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
  if not private.take('send_day', v_day, private.cfg_int('global_sends_per_day')) then
    perform private.give_back('send_hour', v_hour);
    return jsonb_build_object('action','none','reason','global_send_day_cap');
  end if;

  v_was_unsub := v_row.status = 'unsubscribed';
  v_token := private.new_token();
  update private.signups set
    status               = case when status = 'unsubscribed' then 'pending' else status end,
    consent_version      = p_consent_version,
    locale               = coalesce(p_locale, locale),
    confirm_token_hash   = private.token_hash(v_token),
    confirm_expires_at   = now() + make_interval(hours => private.cfg_int('confirm_ttl_hours')),
    confirm_sends        = confirm_sends + 1,
    last_confirm_sent_at = now(),
    updated_at           = now()
  where id = v_row.id
  returning * into v_row;

  insert into private.consent_events(signup_id, event, consent_version, detail)
  values (v_row.id, case when v_was_unsub then 'resubscribe_requested' else 'requested' end,
          p_consent_version, jsonb_build_object('source', p_source, 'send_no', v_row.confirm_sends));

  return jsonb_build_object('action','send','token', v_token, 'signup_id', v_row.id,
                            'send_no', v_row.confirm_sends, 'hour', v_hour);
end $$;

-- The provider was never reached: give BOTH global units back (hour and its day).
create or replace function public.waitlist_send_failed(p_hour timestamptz) returns void
language sql security definer set search_path = '' as $$
  select private.give_back('send_hour', date_trunc('hour', p_hour));
  select private.give_back('send_day',  date_trunc('day',  p_hour));
$$;

-- privileges (create or replace keeps them, re-stated so this file is safe on its own)
revoke all on function public.waitlist_signup(text,text,text,text) from public, anon, authenticated;
revoke all on function public.waitlist_send_failed(timestamptz)    from public, anon, authenticated;
grant execute on function public.waitlist_signup(text,text,text,text) to service_role;
grant execute on function public.waitlist_send_failed(timestamptz)    to service_role;

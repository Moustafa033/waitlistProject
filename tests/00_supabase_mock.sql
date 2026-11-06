-- =====================================================================
-- TEST-ONLY: minimal imitation of a Supabase database so the migration can
-- run on plain Postgres. NEVER run this file on a real project.
-- =====================================================================
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema if not exists extensions;
-- Supabase's real default: everything new in public is granted to the API roles.
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

create schema if not exists t;
create or replace function t.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is distinct from true then raise exception 'FAIL: %', p_msg; end if;
  raise notice 'ok   %', p_msg;
end $$;
create or replace function t.fails(p_sql text, p_state text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if p_state is null or sqlstate = p_state then raise notice 'ok   % (blocked: %)', p_msg, sqlstate; return; end if;
    raise exception 'FAIL: % -> wrong error % %', p_msg, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL: % -> statement succeeded but should have failed', p_msg;
end $$;
grant usage on schema t to anon, authenticated, service_role;
grant execute on all functions in schema t to anon, authenticated, service_role;

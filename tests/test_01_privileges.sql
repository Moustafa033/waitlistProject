\echo '--- privileges: the browser key can reach nothing; the function key only the RPCs'
select t.ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
             where relnamespace = 'private'::regnamespace and relkind = 'r'), 'every private table has RLS enabled AND forced');
select t.ok(not exists (select 1 from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r','v','m')),
  'no table or view in public (nothing for PostgREST to expose)');
select t.ok(not exists (
  select 1 from pg_proc p where p.prosecdef and p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)
    and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')),
  'every SECURITY DEFINER function pins search_path');
select t.ok(not exists (
  select 1 from pg_proc p where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace) and p.prokind = 'f'
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))),
  'anon/authenticated can execute NO function (public or private)');
select t.ok(not has_schema_privilege('anon', 'private', 'usage') and not has_schema_privilege('authenticated', 'private', 'usage'),
  'browser roles have no usage on schema private');
select t.ok(not exists (select 1 from pg_class c where c.relnamespace = 'private'::regnamespace and c.relkind = 'r'
     and (has_table_privilege('service_role', c.oid, 'select') or has_table_privilege('service_role', c.oid, 'insert')
       or has_table_privilege('service_role', c.oid, 'update') or has_table_privilege('service_role', c.oid, 'delete'))),
  'even service_role has no direct table access (RPCs only => every rule always runs)');
-- EXACT list (not a count): any new public function must be added here on purpose, or this fails.
select t.ok((select array_agg(p.proname::text order by p.proname::text collate "C") from pg_proc p
              where p.pronamespace = 'public'::regnamespace and has_function_privilege('service_role', p.oid, 'execute')
                and p.proname like 'waitlist_%')
            = array['waitlist_confirm','waitlist_drain_queue','waitlist_erase','waitlist_erase_by_token','waitlist_export_confirmed',
                    'waitlist_maintenance','waitlist_public_count','waitlist_send_failed','waitlist_set_paused','waitlist_signup',
                    'waitlist_suppress','waitlist_take_alerts','waitlist_unsub_token','waitlist_unsubscribe'],
  'service_role can execute exactly the 14 known waitlist RPCs (no surprise functions)');

set role anon;
select t.fails($$select public.waitlist_signup('a@example.com','waitlist-v1')$$, '42501', 'anon calls waitlist_signup directly');
select t.fails($$select * from public.waitlist_export_confirmed()$$, '42501', 'anon exports the list');
select t.fails($$select * from private.signups$$, '42501', 'anon reads signups');
select t.fails($$select public.waitlist_public_count()$$, '42501', 'anon calls even the harmless counter (Edge Function serves it)');
reset role;
set role authenticated;
select t.fails($$select public.waitlist_erase('a@example.com')$$, '42501', 'authenticated erases someone');
select t.fails($$select public.waitlist_unsub_token(gen_random_uuid())$$, '42501', 'authenticated mints unsubscribe tokens');
select t.fails($$select public.waitlist_erase_by_token(gen_random_uuid(), repeat('A', 43))$$, '42501', 'authenticated calls delete-by-link directly');
reset role;
set role anon;
select t.fails($$select public.waitlist_erase_by_token(gen_random_uuid(), repeat('A', 43))$$, '42501', 'anon calls delete-by-link directly');
reset role;
set role service_role;
select t.fails($$select * from private.signups$$, '42501', 'service_role reads the table directly');
select t.fails($$select * from private.app_secrets$$, '42501', 'service_role reads the HMAC secrets');
reset role;

#!/usr/bin/env bash
# Runs the migration on a fresh database, then every attack test.
set -euo pipefail
PG="psql -h ${PGHOST:-/tmp} -p ${PGPORT:-5433} -U postgres -v ON_ERROR_STOP=1 -q"
DB=waitlist_test
here="$(cd "$(dirname "$0")" && pwd)"
$PG -d postgres -c "drop database if exists $DB" -c "create database $DB"
$PG -d $DB -f "$here/00_supabase_mock.sql"
for f in "$here"/../supabase/migrations/*.sql; do echo "migrate: $(basename "$f")"; $PG -d $DB -f "$f"; done
$PG -d $DB -c "insert into private.app_secrets values ('email_pepper', 'test-pepper-0123456789abcdef0123456789abcdef'), ('unsub_key', 'test-unsub-0123456789abcdef0123456789abcdef')"
fail=0
for t in "$here"/test_*.sql; do
  echo "test:    $(basename "$t")"
  out=$($PG -d $DB -f "$t" 2>&1 >/dev/null) || fail=1
  sed -n -e "s/.*NOTICE:  //p" -e "/ERROR/p" <<<"$out"
done
[ $fail -eq 0 ] || { echo "SQL TESTS FAILED"; exit 1; }
shopt -s nullglob; for t in "$here"/race_*.sh; do echo "race:    $(basename "$t")"; DB=$DB bash "$t"; done
echo "ALL TESTS PASSED"

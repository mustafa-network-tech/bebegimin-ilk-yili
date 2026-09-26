#!/usr/bin/env bash
# Applies every migration to a throw-away PostgreSQL database (with the
# Supabase shim) and runs the RLS / business-rule test suite.
#
# Usage: PGHOST=/tmp PGPORT=5432 PGUSER=postgres ./supabase/tests/run_db_tests.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
DB="${TEST_DB:-bebegimin_test}"

psql -v ON_ERROR_STOP=1 -q -d postgres -c "drop database if exists $DB" -c "create database $DB"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$DIR/00_supabase_shim.sql"
for f in "$DIR"/../migrations/*.sql; do
  echo "→ migration $(basename "$f")"
  psql -v ON_ERROR_STOP=1 -q -o /dev/null -d "$DB" -f "$f" 2>&1 | sed -n 's/.*NOTICE:  \(ok - .*\)/  \1/p; /ERROR/p; /FAIL/p'
  test "${PIPESTATUS[0]}" -eq 0 || { echo "✗ $(basename "$f") failed"; exit 1; }
done
echo "→ seed (demo data)"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$DIR/../seed.sql"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$DIR/01_helpers.sql"
for f in "$DIR"/[1-9]*_test.sql; do
  echo "→ test $(basename "$f")"
  psql -v ON_ERROR_STOP=1 -q -o /dev/null -d "$DB" -f "$f" 2>&1 | sed -n 's/.*NOTICE:  \(ok - .*\)/  \1/p; /ERROR/p; /FAIL/p'
  test "${PIPESTATUS[0]}" -eq 0 || { echo "✗ $(basename "$f") failed"; exit 1; }
done
echo "✓ all database tests passed"

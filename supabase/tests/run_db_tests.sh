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

# Real two-session race: the unique baby_id constraint must let exactly one
# request commit even when both authenticated calls overlap.
echo "→ race extension request"
RACE_DIR="$(mktemp -d)"
RACE_SQL="select tests.login(tests.id('anne')); select public.request_baby_extension(tests.id('ege'), 7);"
set +e
psql -v ON_ERROR_STOP=1 -q -d "$DB" -c "$RACE_SQL" >"$RACE_DIR/one.log" 2>&1 &
RACE_ONE=$!
psql -v ON_ERROR_STOP=1 -q -d "$DB" -c "$RACE_SQL" >"$RACE_DIR/two.log" 2>&1 &
RACE_TWO=$!
wait "$RACE_ONE"; RACE_ONE_STATUS=$?
wait "$RACE_TWO"; RACE_TWO_STATUS=$?
set -e
if { [ "$RACE_ONE_STATUS" -eq 0 ] && [ "$RACE_TWO_STATUS" -ne 0 ]; } ||
   { [ "$RACE_ONE_STATUS" -ne 0 ] && [ "$RACE_TWO_STATUS" -eq 0 ]; }; then
  echo "  ok - exactly one concurrent extension request committed"
else
  echo "✗ extension race expected one success; got $RACE_ONE_STATUS / $RACE_TWO_STATUS"
  sed -n '/ERROR/p' "$RACE_DIR/one.log" "$RACE_DIR/two.log"
  rm -rf -- "$RACE_DIR"
  exit 1
fi
rm -rf -- "$RACE_DIR"

for f in "$DIR"/[1-9]*_test.sql; do
  echo "→ test $(basename "$f")"
  psql -v ON_ERROR_STOP=1 -q -o /dev/null -d "$DB" -f "$f" 2>&1 | sed -n 's/.*NOTICE:  \(ok - .*\)/  \1/p; /ERROR/p; /FAIL/p'
  test "${PIPESTATUS[0]}" -eq 0 || { echo "✗ $(basename "$f") failed"; exit 1; }
done
echo "✓ all database tests passed"

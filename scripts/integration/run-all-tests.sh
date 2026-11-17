#!/usr/bin/env bash
# Run the full integration suite against disposable Docker engines.
# Generates TLS fixtures, brings up MySQL/PostgreSQL/Redis (+TLS variants) and an
# SSH jump host via docker compose, waits for health, runs swift test with the
# LODE_TEST_* environment wired to those engines, then tears everything down.
#
# Usage: scripts/integration/run-all-tests.sh [swift-test-filter]
#   no argument  -> run the whole plugin test suite
#   argument     -> passed to `swift test --filter`
#
# Ports and credentials are throwaway test values. The optional connection-import
# tests need a real local client plist (LODE_TEST_TABLEPLUS_PLIST); they are left
# disabled here unless that variable is already exported in the environment.
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
COMPOSE_FILE="$ROOT/scripts/integration/docker-compose.yml"
CERT="$ROOT/scripts/integration/.fixtures/certs"
FILTER="${1:-}"

MYSQL_PORT="${LODE_TEST_MYSQL_PORT:-33061}"
PG_PORT="${LODE_TEST_PG_PORT:-54321}"
REDIS_PORT="${LODE_TEST_REDIS_PORT:-63791}"
PG_TLS_PORT="${LODE_TEST_PG_TLS_PORT:-54322}"
REDIS_TLS_PORT="${LODE_TEST_REDIS_TLS_PORT:-63792}"
SSH_PORT="${LODE_TEST_SSH_PORT:-2222}"
SSH_TARGET_HOST="${LODE_TEST_SSH_TARGET_HOST:-host.docker.internal}"

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

cleanup() {
  compose down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

bash "$ROOT/scripts/integration/gen-fixtures.sh"

echo "Starting engines..."
compose up -d --build --wait --wait-timeout 240

echo "Running tests..."
set +e
LODE_TEST_MYSQL_PORT="$MYSQL_PORT" \
LODE_TEST_PG_PORT="$PG_PORT" \
LODE_TEST_REDIS_PORT="$REDIS_PORT" \
LODE_TEST_PG_TLS_PORT="$PG_TLS_PORT" \
LODE_TEST_REDIS_TLS_PORT="$REDIS_TLS_PORT" \
LODE_TEST_SSH_PORT="$SSH_PORT" \
LODE_TEST_SSH_TARGET_HOST="$SSH_TARGET_HOST" \
LODE_TEST_TLS_CA="${LODE_TEST_TLS_CA:-$CERT/ca.pem}" \
LODE_TEST_TLS_WRONG_CA="${LODE_TEST_TLS_WRONG_CA:-$CERT/wrong-ca.pem}" \
  swift test --package-path Packages/PluginDatabaseManager ${FILTER:+--filter "$FILTER"}
STATUS=$?
set -e

echo "test_exit=$STATUS"
exit "$STATUS"
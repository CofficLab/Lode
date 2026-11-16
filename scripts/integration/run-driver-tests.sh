#!/usr/bin/env bash
# Run driver integration tests against disposable Docker engines.
# Usage: scripts/integration/run-driver-tests.sh [swift-test-filter]
set -euo pipefail

cd "$(dirname "$0")/../.."

MYSQL_PORT="${LODE_IT_MYSQL_PORT:-33061}"
PG_PORT="${LODE_IT_PG_PORT:-54321}"
REDIS_PORT="${LODE_IT_REDIS_PORT:-63791}"
FILTER="${1:-DriverCancellationIntegrationTests}"

MYSQL_NAME="lode-it-mysql-$$"
PG_NAME="lode-it-pg-$$"
REDIS_NAME="lode-it-redis-$$"

cleanup() {
  docker rm -f "$MYSQL_NAME" "$PG_NAME" "$REDIS_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$MYSQL_NAME" -e MYSQL_ROOT_PASSWORD=test -e MYSQL_DATABASE=testdb \
  -p "$MYSQL_PORT:3306" mysql:8 >/dev/null
docker run -d --name "$PG_NAME" -e POSTGRES_PASSWORD=test -e POSTGRES_DB=testdb \
  -p "$PG_PORT:5432" postgres:16-alpine >/dev/null
docker run -d --name "$REDIS_NAME" -p "$REDIS_PORT:6379" redis:7-alpine >/dev/null

echo "Waiting for engines..."
for _ in $(seq 1 60); do
  if docker exec "$MYSQL_NAME" mysqladmin ping -uroot -ptest --silent >/dev/null 2>&1; then break; fi
  sleep 1
done
for _ in $(seq 1 30); do
  if docker exec "$PG_NAME" pg_isready -U postgres >/dev/null 2>&1; then break; fi
  sleep 1
done
for _ in $(seq 1 30); do
  if [ "$(docker exec "$REDIS_NAME" redis-cli ping 2>/dev/null)" = "PONG" ]; then break; fi
  sleep 1
done

LODE_TEST_MYSQL_PORT="$MYSQL_PORT" \
LODE_TEST_PG_PORT="$PG_PORT" \
LODE_TEST_REDIS_PORT="$REDIS_PORT" \
  swift test --package-path Packages/PluginDatabaseManager --filter "$FILTER"
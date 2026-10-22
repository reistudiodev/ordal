#!/usr/bin/env bash
# Runs the core's tests against real servers in Docker (or Podman).
#
#   scripts/test-integration.sh          # start servers, test, stop servers
#   scripts/test-integration.sh --keep   # leave the servers running afterwards
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

if command -v docker >/dev/null; then
  COMPOSE=(docker compose)
elif command -v podman >/dev/null; then
  COMPOSE=(podman compose)
else
  echo "Docker or Podman is required" >&2
  exit 1
fi

COMPOSE+=(-f docker-compose.test.yml)
"${COMPOSE[@]}" up -d --wait
[ "$KEEP" = 1 ] || trap '"${COMPOSE[@]}" down -v' EXIT

export ORDAL_TEST_POSTGRES_URL=postgres://postgres:ordal@127.0.0.1:55432/postgres
export ORDAL_TEST_MYSQL_URL=mysql://root:ordal@127.0.0.1:53306/ordal
export ORDAL_TEST_MARIADB_URL=mariadb://root:ordal@127.0.0.1:53307/ordal
export ORDAL_TEST_MONGODB_URL=mongodb://127.0.0.1:57017/ordal
export ORDAL_TEST_REDIS_URL=redis://127.0.0.1:56379/15

cargo test -p ordal-core

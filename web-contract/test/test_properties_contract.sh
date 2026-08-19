#!/bin/zsh

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
PORT="${SCOUT_WEB_CONTRACT_PORT:-8787}"
HOST="${SCOUT_WEB_CONTRACT_HOST:-127.0.0.1}"
SERVER_SCRIPT="$ROOT_DIR/mock/property_list_stub.py"
SERVER_LOG="${TMPDIR:-/tmp}/scoutcapture-web-contract.log"

python3 "$SERVER_SCRIPT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

cleanup() {
  if kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

ready=0
for _ in {1..20}; do
  if curl -sSf "http://$HOST:$PORT/health" >/dev/null 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.2
done

if [[ "$ready" -ne 1 ]]; then
  echo "Stub server did not become healthy. See $SERVER_LOG for details." >&2
  exit 1
fi

RESPONSE=$(curl -sSf \
  -H "Authorization: Bearer owner-token" \
  -H "X-Scout-Org-Id: 10000000-0000-0000-0000-000000000001" \
  "http://$HOST:$PORT/v1/properties?limit=10")

echo "$RESPONSE"

echo "$RESPONSE" | grep -q '"name": "Property One"'
echo "$RESPONSE" | grep -q '"org_id": "10000000-0000-0000-0000-000000000001"'
echo "$RESPONSE" | grep -q '"count": 1'

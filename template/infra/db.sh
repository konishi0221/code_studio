#!/usr/bin/env bash
# ============================================================
#  claude-studio : Cloud SQL helper
#  Run psql against an app's database without typing the password.
#  Designed to run in Cloud Shell (cloud-sql-proxy pre-installed).
#
#  Usage:
#    bash template/infra/db.sh <app-name>                         # interactive psql
#    bash template/infra/db.sh <app-name> < schema.sql            # apply file
#    bash template/infra/db.sh <app-name> -c "\dt"                # one command
#    bash template/infra/db.sh <app-name> -c "SELECT * FROM records LIMIT 5"
# ============================================================
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" ]]; then
  echo "Usage: $0 <app-name> [psql args...]" >&2
  echo "Example:" >&2
  echo "  $0 sample" >&2
  echo "  $0 sample -c '\\dt'" >&2
  echo "  $0 sample < template/apps/sample/infra/schema.sql" >&2
  exit 1
fi
shift

REGION="${REGION:-asia-northeast1}"
DB_INSTANCE="${DB_INSTANCE:-claude-studio-db}"
DB_USER="${DB_USER:-$APP}"
DB_NAME="${DB_NAME:-$APP}"
SECRET="${DB_PW_SECRET:-${APP}-db-password}"
PROJECT="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"

PROXY="$(command -v cloud-sql-proxy || true)"
if [[ -z "$PROXY" ]]; then
  echo "cloud-sql-proxy not found." >&2
  echo "Run this from Cloud Shell (it's pre-installed)" >&2
  echo "or install: https://cloud.google.com/sql/docs/postgres/connect-auth-proxy" >&2
  exit 1
fi

PORT="$((5400 + RANDOM % 200))"

"$PROXY" "$PROJECT:$REGION:$DB_INSTANCE" --port "$PORT" >/dev/null 2>&1 &
PROXY_PID=$!
cleanup() { kill "$PROXY_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Wait for proxy to accept connections (up to 5 seconds)
for _ in {1..20}; do
  if (echo >/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then break; fi
  sleep 0.25
done

PGPASSWORD="$(gcloud secrets versions access latest --secret="$SECRET")" \
  psql -h 127.0.0.1 -p "$PORT" -U "$DB_USER" -d "$DB_NAME" "$@"

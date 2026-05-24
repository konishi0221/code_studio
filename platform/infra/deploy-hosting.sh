#!/usr/bin/env bash
# platform/infra/deploy-hosting.sh
#
# Firebase Hosting への **手動** デプロイの唯一の正規ルート。
# 直接 `firebase deploy --only hosting` を打つと、ローカル clone が古い時に
# 過去状態を本番に上書きしてしまうので、必ずこのラッパー経由で。
#
# やってること:
#   1. git fetch & main を origin/main に揃える (強制 pull)
#   2. (オプション) 指定アプリの Cloud Run URL を取得して apps/config.js に注入
#   3. firebase deploy --only hosting
#
# Usage:
#   PROJECT_ID=<project> bash platform/infra/deploy-hosting.sh
#   PROJECT_ID=<project> APP=help bash platform/infra/deploy-hosting.sh

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-asia-northeast1}"
APP="${APP:-}"                        # optional: refresh this app's API_BASE in config.js
BASE_DIR="${BASE_DIR:-platform}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "❌ PROJECT_ID 未設定" >&2
  echo "   解決: PROJECT_ID=<your-project> bash platform/infra/deploy-hosting.sh" >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

echo "▶ git fetch origin main..."
git fetch origin main --quiet

LOCAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$LOCAL_BRANCH" != "main" ]; then
  echo "❌ main ブランチにいません (現在: $LOCAL_BRANCH)"
  echo "   解決: git checkout main"
  exit 1
fi

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)
if [ "$LOCAL" != "$REMOTE" ]; then
  if git merge-base --is-ancestor "$REMOTE" "$LOCAL"; then
    echo "❌ ローカル main に未 push の commit があります"
    echo "   解決: git push origin main"
    exit 1
  fi
  echo "▶ ローカル main が古いので origin/main に追従..."
  git pull --ff-only origin main
fi

if [[ -n "$APP" ]]; then
  SERVICE="${SERVICE:-${APP}-api}"
  echo "▶ Cloud Run URL 取得 (${SERVICE})..."
  RUN_URL=$(gcloud run services describe "$SERVICE" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format='value(status.url)')
  if [ -z "$RUN_URL" ]; then
    echo "❌ Cloud Run の URL が取得できません ($SERVICE)"
    exit 1
  fi
  echo "  API_BASE_${APP^^} = $RUN_URL"
  CFG="${BASE_DIR}/apps/config.js"
  touch "$CFG"
  # Remove any prior line for this app, then append the fresh one.
  grep -v "API_BASE_${APP^^}" "$CFG" > "$CFG.tmp" || true
  mv "$CFG.tmp" "$CFG"
  echo "window.API_BASE_${APP^^}='$RUN_URL';" >> "$CFG"
fi

echo "▶ firebase deploy --only hosting..."
firebase deploy --only hosting \
  --project="$PROJECT_ID" \
  --config="${BASE_DIR}/firebase.json" \
  --non-interactive

echo "✅ Hosting deploy 完了"

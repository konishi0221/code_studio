#!/usr/bin/env bash
# wizard-bootstrap.sh — Cloud Shell ハンドオフ用ラッパー
#
# Wizard の submit で発行された provisioning token を使い、
# - wizard-api から user の入力 (survey / options / GitHub login / email) を取得
# - bootstrap.sh に env で流し込んで非対話実行
# - 各ステップで wizard-api に status を POST → wizard フロントが live で進捗表示
#
# 呼び出し:
#   bash platform/infra/wizard-bootstrap.sh <wizard_api_url> <token>
#
# Cloud Shell では wizard-api がレンダリングする「コピー用コマンド」を貼り付け実行。
set -euo pipefail

API_URL="${1:-${WIZARD_API:-}}"
TOKEN="${2:-${WIZARD_RUN_TOKEN:-}}"

if [[ -z "$API_URL" || -z "$TOKEN" ]]; then
  cat >&2 <<EOF
Usage:
  bash $0 <wizard_api_url> <token>

  または環境変数で:
  WIZARD_API=https://wizard-api-xxx.a.run.app \\
  WIZARD_RUN_TOKEN=xxxxx \\
  bash $0
EOF
  exit 1
fi

# 依存チェック
for cmd in curl jq gcloud; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ $cmd が見つかりません (Cloud Shell なら最初から入ってるはず)" >&2; exit 1; }
done

# status を wizard-api に報告するヘルパー
# 使い方: report_status <status> <step> <message> [<hosting_url>]
report_status() {
  local status="$1" step="$2" message="$3" hosting_url="${4:-}"
  local payload
  payload=$(jq -nc --arg s "$status" --arg st "$step" --arg m "$message" --arg h "$hosting_url" \
    '{status:$s, step:$st, message:$m} + (if $h == "" then {} else {hosting_url:$h} end)')
  curl -fsSL -X POST "$API_URL/api/wizard/by-token/$TOKEN/status" \
    -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 || true
}

trap 'rc=$?; if [[ $rc -ne 0 ]]; then report_status "failed" "exception" "exit code $rc"; fi' EXIT

echo "═══════════════════════════════════════"
echo "  claude-studio 自動セットアップ"
echo "═══════════════════════════════════════"
echo ""

# 1. wizard-api から run データ取得
echo "▶ 1/6 wizard から入力情報を取得"
RUN_JSON=$(curl -fsSL "$API_URL/api/wizard/by-token/$TOKEN")
RUN_ID=$(echo "$RUN_JSON" | jq -r '.run_id')
USER_EMAIL=$(echo "$RUN_JSON" | jq -r '.user_email // empty')
GITHUB_LOGIN=$(echo "$RUN_JSON" | jq -r '.github_login // empty')
HAS_CLOUDSQL=$(echo "$RUN_JSON" | jq -r '.options.cloudsql // false')
HAS_STORAGE=$(echo "$RUN_JSON" | jq -r '.options.cloudstorage // false')
GOAL=$(echo "$RUN_JSON" | jq -r '.survey.goal // empty')
SKILL=$(echo "$RUN_JSON" | jq -r '.survey.skill // empty')
ESTIMATED=$(echo "$RUN_JSON" | jq -r '.estimated_monthly_jpy // 0')

echo "    run_id:        $RUN_ID"
echo "    user:          $USER_EMAIL"
echo "    github:        $GITHUB_LOGIN"
echo "    goal:          $GOAL"
echo "    skill:         $SKILL"
echo "    cloud sql:     $HAS_CLOUDSQL"
echo "    cloud storage: $HAS_STORAGE"
echo "    試算 (月額):    ¥$ESTIMATED"
echo ""

report_status "in_progress" "fetched_params" "wizard 入力を取得しました"

# 2. GCP プロジェクト ID を確認
echo "▶ 2/6 GCP プロジェクトを確認"
if [[ -z "${PROJECT_ID:-}" ]]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
fi
if [[ -z "$PROJECT_ID" ]]; then
  echo "    現在の gcloud project が未設定です。"
  echo "    新しいプロジェクトを作るか、既存のプロジェクト ID を入力してください。"
  echo "    (プロジェクト一覧: gcloud projects list)"
  read -rp "    PROJECT_ID: " PROJECT_ID
  gcloud config set project "$PROJECT_ID" >/dev/null
fi
echo "    PROJECT_ID: $PROJECT_ID"

# 請求アカウントが紐づいてるか軽くチェック (確実な判定はしない、警告のみ)
BILLING_ENABLED=$(gcloud beta billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null || echo "unknown")
if [[ "$BILLING_ENABLED" != "True" && "$BILLING_ENABLED" != "true" ]]; then
  echo ""
  echo "    ⚠️  請求アカウント未連携の可能性: $BILLING_ENABLED"
  echo "    Cloud Console で連携してから続けてください:"
  echo "      https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
  read -rp "    続行しますか? (y/N) " CONFIRM_B
  [[ "$CONFIRM_B" == "y" || "$CONFIRM_B" == "Y" ]] || { report_status "failed" "billing_not_linked" "請求未連携で中止"; exit 1; }
fi

report_status "in_progress" "project_confirmed" "PROJECT_ID=$PROJECT_ID"

# 3. その他必須 env を組み立て
echo "▶ 3/6 設定値を組み立て"
export PROJECT_ID
export OWNER_EMAIL="${OWNER_EMAIL:-$USER_EMAIL}"
export HOSTING_SITE="${HOSTING_SITE:-${PROJECT_ID}-app}"
export GITHUB_OWNER="${GITHUB_OWNER:-$GITHUB_LOGIN}"
export GITHUB_REPO="${GITHUB_REPO:-code_studio}"
export REGION="${REGION:-asia-northeast1}"

if [[ -z "$OWNER_EMAIL" ]]; then
  read -rp "    OWNER_EMAIL: " OWNER_EMAIL
  export OWNER_EMAIL
fi
if [[ -z "$GITHUB_OWNER" ]]; then
  echo "    GitHub 連携がまだのようです。fork は手動でやる前提で進めます。"
  read -rp "    GitHub username (空でも続行可): " GITHUB_OWNER
  export GITHUB_OWNER
fi

# 選択された options に応じて bootstrap.sh の HAS_DB / HAS_BUCKET 制御は
# 各 app.yaml 側の責務 (wizard が template の app.yaml を書き換える Phase 4)。
# 当面: HAS_CLOUDSQL=true ならユーザーに通知だけして bootstrap.sh のデフォに任せる。

echo "    OWNER_EMAIL:   $OWNER_EMAIL"
echo "    HOSTING_SITE:  $HOSTING_SITE"
echo "    GITHUB:        $GITHUB_OWNER/$GITHUB_REPO"
echo "    REGION:        $REGION"
echo ""

# Gemini API キーは bootstrap.sh が prompt するので、ここで先に env に取り込んでおく
if [[ -z "${GEMINI_API_KEY:-}" ]]; then
  echo "    Gemini API キーが必要です (claude-studio の AI ヘルプで使用)。"
  echo "    まだ無ければ: https://aistudio.google.com/app/apikey"
  read -srp "    GEMINI_API_KEY (入力は伏字): " GEMINI_API_KEY; echo
  export GEMINI_API_KEY
fi

report_status "in_progress" "env_ready" "セットアップに必要な env を準備済"

# 4. 確認 → 実行
echo "▶ 4/6 最終確認"
echo "    これから上記設定で GCP リソースを作成 / 更新します。"
read -rp "    続行しますか? (Y/n) " CONFIRM
if [[ "$CONFIRM" == "n" || "$CONFIRM" == "N" ]]; then
  report_status "failed" "user_cancelled" "ユーザーが中止"
  exit 1
fi

# 5. bootstrap.sh 実行
echo ""
echo "▶ 5/6 GCP プロビジョン実行 (3〜10 分)"
report_status "in_progress" "running_bootstrap" "bootstrap.sh 実行開始"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if bash "$SCRIPT_DIR/bootstrap.sh"; then
  report_status "in_progress" "bootstrap_done" "GCP リソース作成完了。Cloud Build トリガが初回ビルドを開始"
else
  report_status "failed" "bootstrap_failed" "bootstrap.sh が失敗しました。出力を確認してください"
  exit 1
fi

# 6. 完了
HOSTING_URL="https://${HOSTING_SITE}.web.app"
echo ""
echo "▶ 6/6 完了"
echo "    🎉 セットアップが完了しました"
echo ""
echo "    あなたの URL: $HOSTING_URL"
echo "    (Cloud Build の初回ビルド完了まであと 5〜10 分かかります)"
echo ""
echo "    進捗確認: https://console.cloud.google.com/cloud-build/builds?project=$PROJECT_ID"

report_status "completed" "all_done" "セットアップ完了" "$HOSTING_URL"

trap - EXIT

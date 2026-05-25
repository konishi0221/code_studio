#!/usr/bin/env bash
# ============================================================
#  claude-studio : Google Cloud one-shot bootstrap
#  Run in Cloud Shell. Idempotent — safe to re-run.
#
#  Provisions shared resources, then per-app resources for
#  every directory under platform/apps/ that contains an app.yaml.
#
#  Usage:
#    PROJECT_ID=<your-project> \
#    OWNER_EMAIL=<your-email>  \
#    GITHUB_OWNER=<your-github-user-or-org> \
#    GITHUB_REPO=<your-repo-name> \
#      bash platform/infra/bootstrap.sh
#
#  Or, equivalently, set them interactively when prompted.
# ============================================================
set -euo pipefail

# ──────────────────────────────────────────
# Configuration (env vars / args)
# ──────────────────────────────────────────
REGION="${REGION:-asia-northeast1}"
REPO_NAME="${REPO_NAME:-claude-studio}"             # Artifact Registry repo (Docker images)
DB_INSTANCE="${DB_INSTANCE:-claude-studio-db}"      # Cloud SQL instance name
# Path from repo root to the deployable directory (the one containing
# apps/, infra/, firebase.json). Defaults to "platform" because this script
# lives at platform/infra/bootstrap.sh.
BASE_DIR="${BASE_DIR:-platform}"
HOSTING_SITE="${HOSTING_SITE:-}"                    # Firebase Hosting site id (globally unique)

step() { printf "\n\033[1;33m▶ %s\033[0m\n" "$*"; }
sub()  { printf "  • %s\n" "$*"; }
err()  { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; }

prompt_if_empty() {
  local var="$1" label="$2"
  if [[ -z "${!var:-}" ]]; then
    read -rp "$label: " val
    printf -v "$var" "%s" "$val"
  fi
}

# Required: project / owner email / GitHub owner+repo
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
prompt_if_empty PROJECT_ID "GCP Project ID"
prompt_if_empty OWNER_EMAIL "Owner email (for Cloud Run invoker + initial ALLOWED_EMAILS)"
prompt_if_empty GITHUB_OWNER "GitHub owner (username or org)"
prompt_if_empty GITHUB_REPO  "GitHub repo name"

# HOSTING_SITE defaults to "${PROJECT_ID}-app" if not given (must be unique).
if [[ -z "$HOSTING_SITE" ]]; then
  HOSTING_SITE="${PROJECT_ID}-app"
  sub "Hosting site id not specified; defaulting to: $HOSTING_SITE"
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"        # = platform/
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"             # = repo root

gcloud config set project "$PROJECT_ID"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

# ────────────────────────────────────────────────────────────
# Shared resources (one-time)
# ────────────────────────────────────────────────────────────

step "Enable APIs"
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com \
  sqladmin.googleapis.com \
  storage.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  generativelanguage.googleapis.com \
  aiplatform.googleapis.com \
  firebase.googleapis.com \
  firebasehosting.googleapis.com \
  identitytoolkit.googleapis.com \
  firestore.googleapis.com

step "Firestore default database (used by wizard-api for run state)"
# Native-mode Firestore in the same region as Cloud Run. Idempotent: if a
# database already exists, the create call errors with ALREADY_EXISTS and
# we ignore it.
if gcloud firestore databases describe --database='(default)' >/dev/null 2>&1; then
  sub "already exists"
else
  gcloud firestore databases create \
    --database='(default)' \
    --location="$REGION" \
    --type=firestore-native \
    --quiet 2>/dev/null || sub "create skipped (likely already exists or unavailable region)"
fi

step "Artifact Registry repo: ${REPO_NAME}"
gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" >/dev/null 2>&1 || \
  gcloud artifacts repositories create "$REPO_NAME" \
    --repository-format=docker --location="$REGION" \
    --description="${REPO_NAME} container images"

step "Shared Gemini API key (Secret Manager: gemini-api-key)"
if ! gcloud secrets describe gemini-api-key >/dev/null 2>&1; then
  echo "  Get one at: https://aistudio.google.com/app/apikey"
  read -srp "  Gemini API key (input hidden): " GEMINI_KEY; echo
  if [[ -z "$GEMINI_KEY" ]]; then
    err "Gemini API key is required."
    exit 1
  fi
  printf "%s" "$GEMINI_KEY" | gcloud secrets create gemini-api-key \
    --replication-policy=automatic --data-file=-
else
  sub "already exists. To rotate: echo -n <key> | gcloud secrets versions add gemini-api-key --data-file=-"
fi

step "GitHub OAuth App (for wizard's automatic fork)"
# wizard-api がユーザーの GitHub アカウントを連携して、テンプレ repo を
# 自動 fork するために必要。GitHub OAuth App は github.com/settings/developers
# で登録 (アプリ名は何でも OK、Homepage = https://<HOSTING_SITE>.web.app):
#   - Authorization callback URL: https://<wizard-api Cloud Run URL>/api/github/callback
#     (Cloud Run URL は wizard-api を最初にデプロイした後でわかる。
#      仮で https://example.com にしておいて、後で更新でも OK)
# Client ID はトリガの substitution _GITHUB_CLIENT_ID で wizard-api に注入。
# Client Secret は Secret Manager (github-oauth-client-secret) に保管。
# 未設定でも wizard は動く (GitHub OAuth ボタンが「未設定」表示で fallback の手入力)。
#
# 環境変数で渡せば対話 prompt をスキップ:
#   GITHUB_CLIENT_ID=Iv1.xxx GITHUB_CLIENT_SECRET=xxx bash bootstrap.sh
GITHUB_CLIENT_ID="${GITHUB_CLIENT_ID:-}"
if [[ -z "$GITHUB_CLIENT_ID" ]]; then
  echo "  Register an OAuth App at: https://github.com/settings/developers"
  echo "  (blank to skip — you can re-run this script later to set them)"
  read -rp "  GitHub OAuth Client ID (blank to skip): " GITHUB_CLIENT_ID
fi
if ! gcloud secrets describe github-oauth-client-secret >/dev/null 2>&1; then
  if [[ -n "${GITHUB_CLIENT_SECRET:-}" ]]; then
    GH_SECRET="$GITHUB_CLIENT_SECRET"
  elif [[ -n "$GITHUB_CLIENT_ID" ]]; then
    read -srp "  GitHub OAuth Client Secret (input hidden): " GH_SECRET; echo
  else
    GH_SECRET=""
  fi
  if [[ -n "$GH_SECRET" ]]; then
    printf "%s" "$GH_SECRET" | gcloud secrets create github-oauth-client-secret \
      --replication-policy=automatic --data-file=-
    sub "  client_secret stored"
  else
    # 空 placeholder: 後で値を入れるまで wizard-api 側で githubOAuthAvailable()=false。
    printf "" | gcloud secrets create github-oauth-client-secret \
      --replication-policy=automatic --data-file=-
    sub "  placeholder created (no GitHub OAuth). Set later with:"
    sub "    echo -n <secret> | gcloud secrets versions add github-oauth-client-secret --data-file=-"
  fi
else
  if [[ -n "${GITHUB_CLIENT_SECRET:-}" ]]; then
    printf "%s" "$GITHUB_CLIENT_SECRET" | gcloud secrets versions add github-oauth-client-secret --data-file=-
    sub "  client_secret rotated"
  else
    sub "  client_secret already exists. To rotate: echo -n <secret> | gcloud secrets versions add github-oauth-client-secret --data-file=-"
  fi
fi
[[ -n "$GITHUB_CLIENT_ID" ]] && sub "  client_id=${GITHUB_CLIENT_ID} (passed to wizard trigger as _GITHUB_CLIENT_ID)"

# Only create the shared Cloud SQL instance if at least one app declares
# HAS_DB=true. Cloud SQL db-f1-micro costs ~$9/month even idle, so skipping
# it when no app needs DB matters for solo/learning setups.
NEEDS_DB=false
for APP_YAML in "$ROOT_DIR"/apps/*/app.yaml; do
  [[ -f "$APP_YAML" ]] || continue
  # Match HAS_DB: "true" or HAS_DB: true (with or without quotes).
  if grep -Eq '^[[:space:]]*HAS_DB:[[:space:]]*"?true"?[[:space:]]*(#.*)?$' "$APP_YAML"; then
    NEEDS_DB=true
    break
  fi
done

if [[ "$NEEDS_DB" == "true" ]]; then
  step "Shared Cloud SQL instance: ${DB_INSTANCE}"
  if ! gcloud sql instances describe "$DB_INSTANCE" >/dev/null 2>&1; then
    ROOT_PW="$(openssl rand -base64 24)"
    gcloud sql instances create "$DB_INSTANCE" \
      --database-version=POSTGRES_15 \
      --tier=db-f1-micro \
      --region="$REGION" \
      --storage-size=10GB \
      --storage-auto-increase \
      --no-backup \
      --root-password="$ROOT_PW"
    sub "Postgres superuser password (save this!): ${ROOT_PW}"
  fi
else
  step "Cloud SQL: skipped (no app declares HAS_DB=true)"
  sub "Add HAS_DB: \"true\" to an app.yaml and re-run to provision."
fi

step "Grant Cloud Build SA the roles it needs"
# Newer GCP projects (post-2024-04-29) default to the Compute SA for Cloud Build.
# Older projects use the dedicated Cloud Build SA. Grant to both so it works either way.
CB_SA_LEGACY="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
CB_SA_COMPUTE="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
for SA in "$CB_SA_LEGACY" "$CB_SA_COMPUTE"; do
  for ROLE in \
    roles/run.admin \
    roles/iam.serviceAccountUser \
    roles/artifactregistry.writer \
    roles/secretmanager.secretAccessor \
    roles/cloudsql.client \
    roles/storage.objectViewer \
    roles/logging.logWriter \
    roles/firebasehosting.admin \
    roles/firebase.admin
  do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${SA}" --role="$ROLE" \
      --condition=None --quiet >/dev/null 2>&1 || true
  done
done

step "Ensure Firebase Hosting service identity exists"
# By default it's created lazily on first use, so the IAM binding below
# can fail with "does not exist" on a fresh project.
gcloud beta services identity create --service=firebasehosting.googleapis.com >/dev/null 2>&1 || true

# ────────────────────────────────────────────────────────────
# Per-app loop: read platform/apps/*/app.yaml, provision resources,
# create Cloud Build trigger.
# ────────────────────────────────────────────────────────────

for APP_DIR in "$ROOT_DIR"/apps/*/; do
  APP="$(basename "$APP_DIR")"
  APP_YAML="${APP_DIR}app.yaml"

  if [[ ! -f "$APP_YAML" ]]; then
    sub "skip ${APP} (no app.yaml)"
    continue
  fi

  # Parse app.yaml — simple key:value, ignore comments.
  eval "$(grep -E '^[a-zA-Z_][a-zA-Z0-9_]*:' "$APP_YAML" | sed -E 's/^([a-zA-Z_][a-zA-Z0-9_]*):[[:space:]]*"?([^"#]*)"?[[:space:]]*(#.*)?$/APP_\1="\2"/' )"

  SERVICE="${APP_SERVICE:-${APP}-api}"
  SA_NAME="${APP_SA:-${APP}-run}"
  SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  DB_NAME="${APP_DB_NAME:-${APP}}"
  DB_USER="${APP_DB_USER:-${APP}}"
  DB_PW_SECRET="${APP_DB_PW_SECRET:-${APP}-db-password}"
  BUCKET="${APP_BUCKET:-${PROJECT_ID}-${APP}-receipts}"
  HAS_DB="${APP_HAS_DB:-true}"
  HAS_BUCKET="${APP_HAS_BUCKET:-true}"
  CLOUDBUILD_REL="${APP_CLOUDBUILD:-${BASE_DIR}/apps/${APP}/cloudbuild.yaml}"
  # Additional files (under platform/) that should trigger a rebuild,
  # space-separated. The base trigger pattern always includes apps/${APP}/**.
  EXTRA_TRIGGER_FILES="${APP_EXTRA_TRIGGER_FILES:-}"

  step "App: ${APP}  (service=${SERVICE})"

  sub "service account ${SA_EMAIL}"
  gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1 || \
    gcloud iam service-accounts create "$SA_NAME" --display-name="${APP} Cloud Run runtime"

  if [[ "$HAS_DB" == "true" ]]; then
    sub "database ${DB_NAME}"
    gcloud sql databases describe "$DB_NAME" --instance="$DB_INSTANCE" >/dev/null 2>&1 || \
      gcloud sql databases create "$DB_NAME" --instance="$DB_INSTANCE"

    if ! gcloud secrets describe "$DB_PW_SECRET" >/dev/null 2>&1; then
      DB_PW="$(openssl rand -base64 24)"
      gcloud sql users create "$DB_USER" --instance="$DB_INSTANCE" --password="$DB_PW" 2>/dev/null || \
        gcloud sql users set-password "$DB_USER" --instance="$DB_INSTANCE" --password="$DB_PW"
      printf "%s" "$DB_PW" | gcloud secrets create "$DB_PW_SECRET" \
        --replication-policy=automatic --data-file=-
    fi

    if [[ -f "${APP_DIR}infra/schema.sql" ]]; then
      sub "apply schema (best-effort; run manually if this fails)"
      DB_PW_VAL="$(gcloud secrets versions access latest --secret="$DB_PW_SECRET")"
      PGPASSWORD="$DB_PW_VAL" gcloud sql connect "$DB_INSTANCE" --user="$DB_USER" --database="$DB_NAME" --quiet \
        < "${APP_DIR}infra/schema.sql" 2>/dev/null || \
        sub "↑ skipped — apply manually with: bash ${BASE_DIR}/infra/db.sh ${APP} < ${APP_DIR}infra/schema.sql"
    fi
  fi

  if [[ "$HAS_BUCKET" == "true" ]]; then
    sub "bucket gs://${BUCKET}"
    gcloud storage buckets describe "gs://${BUCKET}" >/dev/null 2>&1 || \
      gcloud storage buckets create "gs://${BUCKET}" --location="$REGION" --uniform-bucket-level-access
  fi

  sub "runtime SA permissions"
  for ROLE in \
    roles/secretmanager.secretAccessor \
    roles/cloudsql.client \
    roles/storage.objectAdmin \
    roles/logging.logWriter
  do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" \
      --condition=None --quiet >/dev/null
  done

  # Allow the SA to sign GCS URLs (getSignedUrl v4 uses the IAM SignBlob API
  # when running on Cloud Run without a private key).
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role=roles/iam.serviceAccountTokenCreator \
    --quiet >/dev/null 2>&1 || true

  # App-specific extra roles (declared in app.yaml as EXTRA_ROLES)
  if [[ -n "${APP_EXTRA_ROLES:-}" ]]; then
    sub "extra roles: ${APP_EXTRA_ROLES}"
    for ROLE in $APP_EXTRA_ROLES; do
      gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" \
        --condition=None --quiet >/dev/null || true
    done
  fi

  # 1st-gen GitHub App triggers live in the global region.
  # Trigger fires on push to main, only when files matching included-files change.
  # Deployment-specific values (owner email, hosting site id, allowed emails)
  # are passed via the trigger's --substitutions so that cloudbuild.yaml stays
  # generic and free of per-deployment leakage.
  sub "Cloud Build trigger ${SERVICE}-deploy (global, main only)"

  # Compose included-files: base apps/${APP}/** plus any extras (resolved to platform/-prefixed paths).
  INCLUDED_FILES="${BASE_DIR}/apps/${APP}/**"
  for extra in $EXTRA_TRIGGER_FILES; do
    INCLUDED_FILES="${INCLUDED_FILES},${BASE_DIR}/${extra}"
  done

  # Trigger substitutions. Use `^||^` separator so values containing commas
  # (e.g. multi-email ALLOWED_EMAILS) are not mis-split.
  SUBS="^||^_INVOKER=user:${OWNER_EMAIL}||_HOSTING_SITE=${HOSTING_SITE}||_ALLOWED_EMAILS=${OWNER_EMAIL}"
  # wizard-api だけ追加で GitHub OAuth Client ID を渡す (empty なら wizard 側で
  # OAuth ボタンが未設定表示になり、手入力 fallback に切り替わる)。
  if [[ "$APP" == "wizard" ]]; then
    SUBS="${SUBS}||_GITHUB_CLIENT_ID=${GITHUB_CLIENT_ID:-}"
  fi

  if gcloud builds triggers describe "${SERVICE}-deploy" >/dev/null 2>&1; then
    sub "  trigger exists — updating substitutions"
    gcloud builds triggers update "${SERVICE}-deploy" \
      --substitutions="$SUBS" --quiet 2>/dev/null || \
      sub "  ⚠ substitutions update failed (gcloud version too old?). Delete trigger & re-run to recreate."
  else
    gcloud builds triggers create github \
      --name="${SERVICE}-deploy" \
      --repo-owner="$GITHUB_OWNER" \
      --repo-name="$GITHUB_REPO" \
      --branch-pattern='^main$' \
      --build-config="$CLOUDBUILD_REL" \
      --included-files="$INCLUDED_FILES" \
      --substitutions="$SUBS" 2>/dev/null || {
      sub "  ⚠ skipped — connect the GitHub repo to Cloud Build first:"
      sub "    https://console.cloud.google.com/cloud-build/triggers/connect?project=${PROJECT_ID}"
      sub "    then re-run this script."
    }
  fi
done

step "Done."
cat <<EOF

  Next steps:

  1. If the Cloud Build trigger creation was skipped, connect the GitHub repo:
       https://console.cloud.google.com/cloud-build/triggers/connect?project=${PROJECT_ID}
     then re-run this script to create the triggers.

  2. Add Firebase Auth's authorized domain (Firebase Console → Authentication →
     Settings → Authorized domains):
       https://${HOSTING_SITE}.web.app

  3. Add OAuth redirect URI (Cloud Console → APIs & Services → Credentials →
     Web client → Authorized redirect URIs):
       https://${HOSTING_SITE}.web.app/__/auth/handler

  4. (Optional, for wizard automatic GitHub fork) Register a GitHub OAuth App:
     https://github.com/settings/developers → New OAuth App
       - Homepage URL: https://${HOSTING_SITE}.web.app
       - Authorization callback URL: (wait until wizard-api is deployed,
         then set to https://<wizard-api Cloud Run URL>/api/github/callback)
     Re-run this script with GITHUB_CLIENT_ID + GITHUB_CLIENT_SECRET env vars
     (or interactive prompt) to wire it up.

  5. First manual deploy of any app:
       gcloud builds submit --config=${BASE_DIR}/apps/<app>/cloudbuild.yaml --region=${REGION} .

  6. Service URLs:
       gcloud run services list --region=${REGION}

  Hosting URL (after first deploy): https://${HOSTING_SITE}.web.app
EOF

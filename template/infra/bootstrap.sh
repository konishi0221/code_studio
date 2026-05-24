#!/usr/bin/env bash
# ============================================================
#  claude-studio : Google Cloud one-shot bootstrap
#  Run in Cloud Shell. Idempotent — safe to re-run.
#
#  Provisions shared resources, then per-app resources for
#  every directory under template/apps/ that contains an app.yaml.
#
#  Usage:
#    PROJECT_ID=<your-project> \
#    OWNER_EMAIL=<your-email>  \
#    GITHUB_OWNER=<your-github-user-or-org> \
#    GITHUB_REPO=<your-repo-name> \
#      bash template/infra/bootstrap.sh
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
# Path from repo root to the template directory. Override if you flattened
# the template (e.g. moved its contents to repo root).
TEMPLATE_REL="${TEMPLATE_REL:-template}"
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

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"        # = template/
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
  identitytoolkit.googleapis.com

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
# Per-app loop: read template/apps/*/app.yaml, provision resources,
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
  CLOUDBUILD_REL="${APP_CLOUDBUILD:-${TEMPLATE_REL}/apps/${APP}/cloudbuild.yaml}"
  # Additional files (under template/) that should trigger a rebuild,
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
        sub "↑ skipped — apply manually with: bash ${TEMPLATE_REL}/infra/db.sh ${APP} < ${APP_DIR}infra/schema.sql"
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

  # ────────────────────────────────────────────────────────
  # Patch cloudbuild.yaml substitutions with concrete values.
  # We do this in-place so the substitutions are git-visible (helpful when
  # reviewing diffs after re-running bootstrap). It's idempotent — if the
  # values already match, sed is a no-op.
  # ────────────────────────────────────────────────────────
  CLOUDBUILD_FILE="${REPO_ROOT}/${CLOUDBUILD_REL}"
  if [[ -f "$CLOUDBUILD_FILE" ]]; then
    sub "patch substitutions in ${CLOUDBUILD_REL}"
    sed -i.bak \
      -e "s|user:OWNER_EMAIL_PLACEHOLDER|user:${OWNER_EMAIL}|g" \
      -e "s|_HOSTING_SITE: HOSTING_SITE_PLACEHOLDER|_HOSTING_SITE: ${HOSTING_SITE}|g" \
      -e "s|_ALLOWED_EMAILS: \"\"|_ALLOWED_EMAILS: \"${OWNER_EMAIL}\"|g" \
      "$CLOUDBUILD_FILE"
    rm -f "${CLOUDBUILD_FILE}.bak"
  fi

  # 1st-gen GitHub App triggers live in the global region.
  # Trigger fires on push to main, only when files matching included-files change.
  sub "Cloud Build trigger ${SERVICE}-deploy (global, main only)"

  # Compose included-files: base apps/${APP}/** plus any extras (resolved to template/-prefixed paths).
  INCLUDED_FILES="${TEMPLATE_REL}/apps/${APP}/**"
  for extra in $EXTRA_TRIGGER_FILES; do
    INCLUDED_FILES="${INCLUDED_FILES},${TEMPLATE_REL}/${extra}"
  done

  if gcloud builds triggers describe "${SERVICE}-deploy" >/dev/null 2>&1; then
    sub "  trigger already exists (delete & re-run to recreate)"
  else
    gcloud builds triggers create github \
      --name="${SERVICE}-deploy" \
      --repo-owner="$GITHUB_OWNER" \
      --repo-name="$GITHUB_REPO" \
      --branch-pattern='^main$' \
      --build-config="$CLOUDBUILD_REL" \
      --included-files="$INCLUDED_FILES" 2>/dev/null || {
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

  4. First manual deploy of any app:
       gcloud builds submit --config=${TEMPLATE_REL}/apps/<app>/cloudbuild.yaml --region=${REGION} .

  5. Service URLs:
       gcloud run services list --region=${REGION}

  Hosting URL (after first deploy): https://${HOSTING_SITE}.web.app
EOF

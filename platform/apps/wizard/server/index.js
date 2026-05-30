// Wizard backend (Cloud Run service: wizard-api)
//
// Receives setup submissions from /wizard/ frontend, persists to Firestore
// for tracking. Future phases will:
//   - exchange Google OAuth token for cloud-platform scoped credentials
//   - kick off Cloud Tasks chain that provisions the user's GCP project
//
// For now (α): we record the submission and return status=manual_required,
// signalling the owner that a human bootstrap is needed for this user.
// The frontend polls /runs/:id and shows progress as it advances.

import express from "express";
import admin from "firebase-admin";
import { Firestore } from "@google-cloud/firestore";
import crypto from "node:crypto";

const {
  FIREBASE_PROJECT_ID,
  ALLOWED_EMAILS = "",
  DEV,
  PORT = 8080,
  GITHUB_CLIENT_ID = "",
  GITHUB_CLIENT_SECRET = "",
  HOSTING_BASE = "",   // 例: https://code-studio-497311-app.web.app
  WIZARD_API_BASE = "", // 例: https://wizard-api-xxxx.run.app (callback URL の組み立て用)
} = process.env;

admin.initializeApp({ projectId: FIREBASE_PROJECT_ID || undefined });
const allowList = ALLOWED_EMAILS.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);

// Firestore (default) database. Created idempotently by infra/bootstrap.sh.
// Service account must have roles/datastore.user on the project.
const db = new Firestore({ projectId: FIREBASE_PROJECT_ID || undefined });
const RUNS = db.collection("wizard_runs");

// ──────────────────────────────────────────
const app = express();
// Cloud Run はリクエストを HTTPS で受けて、コンテナには X-Forwarded-Proto: https を
// 付けた HTTP として流す。trust proxy を有効にしないと req.protocol が "http" のまま
// になり、GitHub OAuth に渡す redirect_uri が http://... になって登録済みの
// https://... と不一致 → "redirect_uri is not associated" で詰む。
app.set("trust proxy", true);
app.use(express.json({ limit: "256kb" }));

app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "content-type,authorization");
  if (req.method === "OPTIONS") return res.sendStatus(204);
  next();
});

app.get("/health", (req, res) => {
  res.json({ ok: true, service: "wizard-api" });
});

// Firebase ID トークン検証。
// パブリック (auth 不要) なルートはここでスキップ:
//   - /api/wizard/config       : フロントが OAuth 利用可否を判定する用
//   - /api/github/callback     : GitHub から戻ってくる redirect (Bearer 無い)
//   - /api/wizard/by-token/... : Cloud Shell 側スクリプトが token を身分証として使う
// req.path は app.use("/api", ...) のマウント先からの相対パスなので /api 抜き。
const PUBLIC_API_PATHS = new Set(["/wizard/config", "/github/callback"]);
const PUBLIC_PATH_PREFIXES = ["/wizard/by-token/"];

app.use("/api", async (req, res, next) => {
  if (PUBLIC_API_PATHS.has(req.path)) return next();
  if (PUBLIC_PATH_PREFIXES.some(p => req.path.startsWith(p))) return next();
  if (DEV) { req.user = { uid: "dev", email: "dev@local" }; return next(); }
  try {
    const m = /^Bearer (.+)$/.exec(req.headers.authorization || "");
    if (!m) return res.status(401).json({ error: "ログインが必要です" });
    const decoded = await admin.auth().verifyIdToken(m[1]);
    if (allowList.length && !allowList.includes((decoded.email || "").toLowerCase())) {
      return res.status(403).json({ error: `権限がありません (${decoded.email || "?"})` });
    }
    req.user = decoded;
    next();
  } catch (e) {
    res.status(401).json({ error: "認証失敗: " + (e.code || e.message) });
  }
});

// 入力フィールドの許容値。フロントエンド (apps/wizard/index.html) のボタンと一致させる。
const ALLOWED = {
  skill: ["beginner", "some", "intermediate", "advanced"],
  goal: ["keihi", "invoice", "crm", "meeting", "custom", "hobby"],
  industry: ["freelance", "construction", "retail", "shigyo", "it", "other"],
  team: ["solo", "2-5", "6-20", "21+"],
};

// 課金が発生する optional サービス。これらの bool が将来の自動プロビジョン
// (bootstrap.sh / Cloud Tasks chain) で HAS_DB / HAS_BUCKET / min-instances 等
// に反映される。新規追加時はフロントの COST_PLANS も合わせて更新。
const OPTION_KEYS = ["cloudsql", "cloudstorage", "cloudrun_warm"];

function pick(obj, key, allowed) {
  const v = String(obj?.[key] || "").trim();
  return allowed.includes(v) ? v : null;
}

// ──────────────────────────────────────────
// 構造化ログ: Firestore `wizard_runs/{id}/events` に粒度細かく書く。
// 用途:
//   - フロントエンド (signin, click, fetch エラー等) からも POST で送られてくる
//   - バックエンド (validation, firestore 書き込み, 将来の各 chain step) もここに書く
//   - フロントは GET で取り出して「詳細ログ」パネルに表示
//   - 仕様変更 (Google OAuth 変わった等) で詰まった時、どのブロックで死んだか即わかる
// ──────────────────────────────────────────
const LEVELS = ["debug", "info", "warn", "error"];

async function logEvent(runId, ev) {
  try {
    const safe = {
      actor: ev.actor || "backend",
      level: LEVELS.includes(ev.level) ? ev.level : "info",
      code: String(ev.code || "").slice(0, 80),
      message: String(ev.message || "").slice(0, 1000),
      data: ev.data ?? null,
      user_email: ev.user_email || "",
      at: admin.firestore.Timestamp.now(),
    };
    await RUNS.doc(runId).collection("events").add(safe);
    // Cloud Logging にも構造化で残す (cloudshell / Logs Explorer から run_id で絞り込める)
    console.log(JSON.stringify({
      severity: safe.level.toUpperCase(),
      run_id: runId,
      actor: safe.actor,
      code: safe.code,
      message: safe.message,
      user_email: safe.user_email,
    }));
  } catch (e) {
    console.error(`[wizard] logEvent failed run=${runId}: ${e.message}`);
  }
}

// 共通: run へのアクセス権チェック (本人 or オーナー)
async function getRunWithAccess(runId, user) {
  const snap = await RUNS.doc(runId).get();
  if (!snap.exists) return { error: { status: 404, message: "run not found" } };
  const d = snap.data();
  const isOwner = allowList.length && allowList.includes((user.email || "").toLowerCase());
  if (d.user_uid !== user.uid && !isOwner) {
    return { error: { status: 403, message: "他人の run にはアクセスできません" } };
  }
  return { snap, data: d, isOwner };
}

// POST /api/wizard/submit — 新しい run を作成
app.post("/api/wizard/submit", async (req, res) => {
  const b = req.body || {};
  const survey = {
    skill: pick(b, "skill", ALLOWED.skill),
    goal: pick(b, "goal", ALLOWED.goal),
    industry: pick(b, "industry", ALLOWED.industry),
    team: pick(b, "team", ALLOWED.team),
  };
  const missing = Object.entries(survey).filter(([, v]) => !v).map(([k]) => k);
  if (missing.length) {
    return res.status(400).json({ error: `必須項目が未入力 or 不正: ${missing.join(", ")}` });
  }
  const ghUser = String(b.github_username || "").trim().slice(0, 80);

  // optional 課金サービスの選択 (whitelist フィルタ)
  const options = {};
  for (const k of OPTION_KEYS) options[k] = !!(b.options && b.options[k]);
  const estimatedMonthlyJpy = Number.isFinite(b.estimated_monthly_jpy)
    ? Math.max(0, Math.min(1_000_000, Math.round(b.estimated_monthly_jpy)))
    : null;

  const now = admin.firestore.Timestamp.now();
  const doc = {
    user_uid: req.user.uid,
    user_email: req.user.email || "",
    survey,
    options,
    estimated_monthly_jpy: estimatedMonthlyJpy,
    github_username: ghUser,
    // ステータス: ユーザーが Cloud Shell でハンドオフ実行するまで待機。
    //   awaiting_cloud_shell → in_progress → completed (or failed)
    status: "awaiting_cloud_shell",
    steps: [
      { name: "received", status: "done", at: now },
      { name: "awaiting_cloud_shell", status: "pending", at: now,
        message: "ユーザーが Cloud Shell で wizard-bootstrap.sh を実行するのを待っています。" },
    ],
    created_at: now,
    updated_at: now,
  };

  try {
    const ref = await RUNS.add(doc);
    const optsOn = Object.entries(options).filter(([, v]) => v).map(([k]) => k);
    await logEvent(ref.id, {
      actor: "backend", level: "info", code: "submit.received",
      message: `goal=${survey.goal} skill=${survey.skill} team=${survey.team} gh=${ghUser || "-"} options=[${optsOn.join(",") || "none"}] cost=¥${estimatedMonthlyJpy ?? "?"}/月`,
      user_email: req.user.email,
      data: { options, estimated_monthly_jpy: estimatedMonthlyJpy },
    });
    await logEvent(ref.id, {
      actor: "backend", level: "warn", code: "status.manual_required",
      message: "自動プロビジョン未実装のため manual_required で停止。オーナーに連絡が届きます。",
    });
    console.log(`[wizard] submit run=${ref.id} user=${req.user.email} goal=${survey.goal} skill=${survey.skill}`);
    res.json({ run_id: ref.id, status: doc.status });
  } catch (e) {
    console.error(`[wizard] submit FAILED user=${req.user.email}: ${e.message}`);
    res.status(500).json({ error: "submit failed: " + e.message });
  }
});

// GET /api/wizard/runs/:id — ステータス取得 (本人 or オーナーのみ)
app.get("/api/wizard/runs/:id", async (req, res) => {
  const { snap, data: d, error } = await getRunWithAccess(req.params.id, req.user);
  if (error) return res.status(error.status).json({ error: error.message });
  res.json({
    id: snap.id,
    status: d.status,
    steps: d.steps,
    survey: d.survey,
    options: d.options || {},
    estimated_monthly_jpy: d.estimated_monthly_jpy ?? null,
    github_username: d.github_username,
    user_email: d.user_email,
    hosting_url: d.hosting_url || null,
    created_at: d.created_at?.toDate?.()?.toISOString?.() || null,
    updated_at: d.updated_at?.toDate?.()?.toISOString?.() || null,
  });
});

// POST /api/wizard/runs/:id/events — フロントエンド (or 将来のバッチ) からの構造化ログ
app.post("/api/wizard/runs/:id/events", async (req, res) => {
  const { error } = await getRunWithAccess(req.params.id, req.user);
  if (error) return res.status(error.status).json({ error: error.message });
  const b = req.body || {};
  await logEvent(req.params.id, {
    actor: b.actor === "backend" ? "frontend" : "frontend", // frontend からの POST は actor 固定
    level: b.level,
    code: b.code,
    message: b.message,
    data: b.data,
    user_email: req.user.email || "",
  });
  res.json({ ok: true });
});

// GET /api/wizard/runs/:id/events — フロントの「詳細ログ」パネル用
app.get("/api/wizard/runs/:id/events", async (req, res) => {
  const { error } = await getRunWithAccess(req.params.id, req.user);
  if (error) return res.status(error.status).json({ error: error.message });
  const q = await RUNS.doc(req.params.id).collection("events")
    .orderBy("at", "asc").limit(300).get();
  res.json({
    events: q.docs.map(doc => {
      const d = doc.data();
      return {
        id: doc.id,
        actor: d.actor,
        level: d.level,
        code: d.code,
        message: d.message,
        data: d.data,
        at: d.at?.toDate?.()?.toISOString?.() || null,
      };
    }),
  });
});

// GET /api/wizard/runs — 自分の最近の run 一覧
app.get("/api/wizard/runs", async (req, res) => {
  const q = await RUNS.where("user_uid", "==", req.user.uid)
    .orderBy("created_at", "desc").limit(10).get();
  res.json({
    runs: q.docs.map(d => ({
      id: d.id,
      status: d.data().status,
      goal: d.data().survey?.goal,
      created_at: d.data().created_at?.toDate?.()?.toISOString?.() || null,
    })),
  });
});

// ──────────────────────────────────────────
// GitHub OAuth (Phase 1 自動セットアップ)
//
// フロー:
//   1. フロント: ボタン押す → POST /api/github/start (with Firebase ID token)
//   2. backend: state を Firestore に保存 → GitHub authorize URL を返す
//   3. フロント: そこへ window.location.href で遷移
//   4. ユーザーが GitHub で承認 → GitHub が GET /api/github/callback?code&state にリダイレクト
//   5. backend: state 検証 → code を access_token に交換 → ユーザー情報取得 →
//      wizard_users/{uid}.github に保存 → HOSTING_BASE/wizard/?gh=connected にリダイレクト
//   6. フロント: クエリパラメータ読んで「連携済み」表示
//
// 設定 (オーナーが github.com/settings/developers で OAuth App 登録):
//   - Authorization callback URL: <WIZARD_API_BASE>/api/github/callback
//   - GITHUB_CLIENT_ID: env (cloudbuild.yaml で --set-env-vars 経由)
//   - GITHUB_CLIENT_SECRET: Secret Manager (--set-secrets 経由)
// ──────────────────────────────────────────
const OAUTH_STATES = db.collection("wizard_oauth_states");
const WIZARD_USERS = db.collection("wizard_users");

function githubOAuthAvailable() {
  return !!(GITHUB_CLIENT_ID && GITHUB_CLIENT_SECRET);
}

// GET /api/wizard/config — フロントが「GitHub OAuth が使えるか」を判定する用 (no-auth)
app.get("/api/wizard/config", (req, res) => {
  res.json({
    github_oauth_available: githubOAuthAvailable(),
    hosting_base: HOSTING_BASE || null,
  });
});

// POST /api/github/start — Firebase 認証必須。GitHub authorize URL を返す
app.post("/api/github/start", async (req, res) => {
  if (!githubOAuthAvailable()) {
    return res.status(503).json({ error: "GitHub OAuth 未設定 (GITHUB_CLIENT_ID/SECRET 必要)" });
  }
  const stateRand = crypto.randomBytes(24).toString("hex");
  await OAUTH_STATES.doc(stateRand).set({
    uid: req.user.uid,
    email: req.user.email || "",
    created_at: admin.firestore.Timestamp.now(),
  });
  const callbackUrl = `${WIZARD_API_BASE || `${req.protocol}://${req.get("host")}`}/api/github/callback`;
  const url = "https://github.com/login/oauth/authorize?" + new URLSearchParams({
    client_id: GITHUB_CLIENT_ID,
    scope: "read:user public_repo",
    state: stateRand,
    redirect_uri: callbackUrl,
    allow_signup: "true",
  }).toString();
  console.log(JSON.stringify({ severity: "INFO", code: "github.oauth_start", uid: req.user.uid, callback: callbackUrl }));
  res.json({ auth_url: url });
});

// GET /api/github/callback — GitHub からの帰り (Firebase 認証なしで直で叩かれる)
app.get("/api/github/callback", async (req, res) => {
  const { code, state, error: ghError, error_description } = req.query;
  const back = (params) => {
    const base = HOSTING_BASE || "/";
    const qs = new URLSearchParams(params).toString();
    return res.redirect(`${base}/wizard/?${qs}`);
  };
  if (ghError) {
    console.warn(`[github.callback] user denied or error: ${ghError} ${error_description}`);
    return back({ gh_error: String(ghError).slice(0, 80) });
  }
  if (!code || !state) {
    return back({ gh_error: "missing_code_or_state" });
  }
  const stateSnap = await OAUTH_STATES.doc(String(state)).get();
  if (!stateSnap.exists) {
    return back({ gh_error: "invalid_state" });
  }
  const stateData = stateSnap.data();
  await stateSnap.ref.delete().catch(() => {});
  // 30 分以内に使われなかったらタイムアウト扱い (Firestore TTL 設定でもよいが、念のため明示)
  const ageMs = Date.now() - (stateData.created_at?.toMillis?.() || 0);
  if (ageMs > 30 * 60 * 1000) return back({ gh_error: "state_expired" });

  const callbackUrl = `${WIZARD_API_BASE || `${req.protocol}://${req.get("host")}`}/api/github/callback`;
  try {
    // 1. code → access_token
    const tokenRes = await fetch("https://github.com/login/oauth/access_token", {
      method: "POST",
      headers: { Accept: "application/json", "content-type": "application/json" },
      body: JSON.stringify({
        client_id: GITHUB_CLIENT_ID,
        client_secret: GITHUB_CLIENT_SECRET,
        code,
        redirect_uri: callbackUrl,
      }),
    });
    const tokenJson = await tokenRes.json();
    if (!tokenJson.access_token) {
      console.error(`[github.callback] token exchange failed: ${JSON.stringify(tokenJson)}`);
      return back({ gh_error: "token_exchange_failed" });
    }

    // 2. user info
    const userRes = await fetch("https://api.github.com/user", {
      headers: {
        Authorization: `token ${tokenJson.access_token}`,
        Accept: "application/vnd.github+json",
        "User-Agent": "claude-studio-wizard",
      },
    });
    if (!userRes.ok) {
      const t = await userRes.text();
      console.error(`[github.callback] user fetch failed: ${userRes.status} ${t.slice(0,200)}`);
      return back({ gh_error: "user_fetch_failed" });
    }
    const ghUser = await userRes.json();

    // 3. 保存: wizard_users/{uid}.github
    // access_token は将来 fork 等で使うので保存 (TODO: encrypt at rest)
    await WIZARD_USERS.doc(stateData.uid).set({
      github: {
        login: ghUser.login,
        id: ghUser.id,
        avatar_url: ghUser.avatar_url || "",
        access_token: tokenJson.access_token,
        scope: tokenJson.scope || "",
        connected_at: admin.firestore.Timestamp.now(),
      },
    }, { merge: true });

    console.log(JSON.stringify({
      severity: "INFO", code: "github.oauth_connected",
      uid: stateData.uid, login: ghUser.login, scope: tokenJson.scope,
    }));
    return back({ gh: "connected", login: ghUser.login });
  } catch (e) {
    console.error(`[github.callback] exception: ${e.message}`);
    return back({ gh_error: "exception", gh_detail: String(e.message).slice(0, 80) });
  }
});

// GET /api/github/me — 現在の Firebase user が GitHub 連携してるか確認 (auth 必須)
app.get("/api/github/me", async (req, res) => {
  const doc = await WIZARD_USERS.doc(req.user.uid).get();
  if (!doc.exists || !doc.data().github?.login) {
    return res.json({ connected: false });
  }
  const g = doc.data().github;
  res.json({
    connected: true,
    login: g.login,
    avatar_url: g.avatar_url || "",
    scope: g.scope || "",
    connected_at: g.connected_at?.toDate?.()?.toISOString?.() || null,
  });
});

// POST /api/github/disconnect — 連携解除 (auth 必須)
app.post("/api/github/disconnect", async (req, res) => {
  await WIZARD_USERS.doc(req.user.uid).set({
    github: admin.firestore.FieldValue.delete(),
  }, { merge: true });
  console.log(JSON.stringify({ severity: "INFO", code: "github.disconnected", uid: req.user.uid }));
  res.json({ ok: true });
});

// ──────────────────────────────────────────
// Provisioning token + Cloud Shell ハンドオフ (Phase 2 自動セットアップ)
//
// 流れ:
//   1. ユーザーが wizard で submit
//   2. フロント: POST /api/wizard/runs/:id/provision-link で token 生成
//   3. backend: token を Firestore に保存 (24h TTL) + Cloud Shell URL を返す
//   4. ユーザーが Cloud Shell を開いて、表示されたコマンドを貼り付け実行:
//        bash platform/infra/wizard-bootstrap.sh <api_url> <token>
//   5. wizard-bootstrap.sh が:
//        - GET /api/wizard/by-token/:token で run 情報取得
//        - bootstrap.sh を env 渡して非対話で実行
//        - 各ステップで POST /api/wizard/by-token/:token/status を呼ぶ
//   6. フロントは引き続き /api/wizard/runs/:id を polling → live 進捗
// ──────────────────────────────────────────
const TOKENS = db.collection("wizard_provisioning_tokens");
const TOKEN_TTL_MS = 24 * 60 * 60 * 1000; // 24h

// token endpoints (`/api/wizard/by-token/...`) は auth middleware の
// PUBLIC_PATH_PREFIXES で skip 済み。

function genToken() {
  return crypto.randomBytes(24).toString("base64url");
}

// repo URL を runtime に渡せるよう env から拾う (将来テンプレ repo 分離時のため)
const TEMPLATE_REPO_URL = process.env.TEMPLATE_REPO_URL || "https://github.com/konishi0221/code_studio";

// POST /api/wizard/runs/:id/provision-link — Firebase auth 必須
// 既存トークンが期限内ならそれを返す (冪等)、なければ新規発行
app.post("/api/wizard/runs/:id/provision-link", async (req, res) => {
  const { snap, data: d, error } = await getRunWithAccess(req.params.id, req.user);
  if (error) return res.status(error.status).json({ error: error.message });

  // 既存有効トークンを探す
  let token = null;
  const existing = await TOKENS.where("run_id", "==", snap.id).limit(1).get();
  if (!existing.empty) {
    const t = existing.docs[0];
    const age = Date.now() - (t.data().created_at?.toMillis?.() || 0);
    if (age < TOKEN_TTL_MS) token = t.id;
    else await t.ref.delete().catch(() => {});
  }
  if (!token) {
    token = genToken();
    await TOKENS.doc(token).set({
      run_id: snap.id,
      user_uid: d.user_uid,
      created_at: admin.firestore.Timestamp.now(),
      expires_at: admin.firestore.Timestamp.fromMillis(Date.now() + TOKEN_TTL_MS),
    });
  }

  const apiBase = WIZARD_API_BASE || `${req.protocol}://${req.get("host")}`;
  const command = `bash platform/infra/wizard-bootstrap.sh ${apiBase} ${token}`;
  // Cloud Shell deep link — repo を clone、platform/ を作業ディレクトリ、
  // platform/infra/cloudshell-welcome.md を表示。
  const cloudShellUrl = "https://shell.cloud.google.com/cloudshell/editor?" + new URLSearchParams({
    cloudshell_git_repo: TEMPLATE_REPO_URL,
    cloudshell_workspace: "platform",
    cloudshell_print: "platform/infra/cloudshell-welcome.md",
    cloudshell_open_in_editor: "platform/infra/wizard-bootstrap.sh",
  }).toString();

  await logEvent(snap.id, {
    actor: "backend", level: "info", code: "provision.link_generated",
    message: `Cloud Shell handoff link issued`,
    data: { token_prefix: token.slice(0, 6) + "...", expires_in_hours: 24 },
  });

  res.json({
    token,
    command,
    cloud_shell_url: cloudShellUrl,
    api_base: apiBase,
    expires_at: new Date(Date.now() + TOKEN_TTL_MS).toISOString(),
  });
});

// Helper: token から run を解決 + access チェック
async function resolveToken(token) {
  if (!token || typeof token !== "string" || token.length < 16) return null;
  const t = await TOKENS.doc(token).get();
  if (!t.exists) return null;
  const td = t.data();
  const expMs = td.expires_at?.toMillis?.() || 0;
  if (Date.now() > expMs) {
    await t.ref.delete().catch(() => {});
    return null;
  }
  const runSnap = await RUNS.doc(td.run_id).get();
  if (!runSnap.exists) return null;
  return { tokenDoc: t, tokenData: td, runSnap, runData: runSnap.data() };
}

// GET /api/wizard/by-token/:token — Cloud Shell の wizard-bootstrap.sh から呼ぶ
// run の主要パラメータを返す (bootstrap.sh が環境変数に流し込めるよう)
app.get("/api/wizard/by-token/:token", async (req, res) => {
  const r = await resolveToken(req.params.token);
  if (!r) return res.status(404).json({ error: "token not found / expired" });
  // GitHub OAuth で取った login も拾う (wizard_users.{uid}.github.login)
  let githubLogin = "";
  try {
    const u = await WIZARD_USERS.doc(r.tokenData.user_uid).get();
    githubLogin = u.exists ? (u.data().github?.login || "") : "";
  } catch {}
  res.json({
    run_id: r.runSnap.id,
    user_email: r.runData.user_email || "",
    github_login: githubLogin || r.runData.github_username || "",
    survey: r.runData.survey || {},
    options: r.runData.options || {},
    estimated_monthly_jpy: r.runData.estimated_monthly_jpy ?? null,
    status: r.runData.status,
  });
});

// POST /api/wizard/by-token/:token/status — wizard-bootstrap.sh が各ステップで叩く
// body: { status, step, message, level?, hosting_url? }
app.post("/api/wizard/by-token/:token/status", async (req, res) => {
  const r = await resolveToken(req.params.token);
  if (!r) return res.status(404).json({ error: "token not found / expired" });
  const b = req.body || {};
  const VALID_STATUS = ["in_progress", "completed", "failed"];
  const newStatus = VALID_STATUS.includes(b.status) ? b.status : null;
  const step = String(b.step || "").slice(0, 80);
  const message = String(b.message || "").slice(0, 500);
  const hostingUrl = b.hosting_url ? String(b.hosting_url).slice(0, 200) : null;

  const now = admin.firestore.Timestamp.now();
  const update = { updated_at: now };
  if (newStatus) update.status = newStatus;
  if (hostingUrl) update.hosting_url = hostingUrl;
  if (step) {
    update.steps = admin.firestore.FieldValue.arrayUnion({
      name: step,
      status: newStatus === "failed" ? "failed" : (newStatus === "completed" ? "done" : "running"),
      at: now,
      message,
    });
  }
  await RUNS.doc(r.runSnap.id).update(update);
  await logEvent(r.runSnap.id, {
    actor: "bootstrap", // wizard-bootstrap.sh からの報告
    level: b.level || (newStatus === "failed" ? "error" : "info"),
    code: `bootstrap.${step || "status"}`,
    message: message || newStatus || "(empty)",
    data: hostingUrl ? { hosting_url: hostingUrl } : null,
  });
  console.log(JSON.stringify({
    severity: newStatus === "failed" ? "ERROR" : "INFO",
    code: "bootstrap.status_update",
    run_id: r.runSnap.id, status: newStatus, step, message,
  }));
  res.json({ ok: true });
});

app.listen(PORT, () => {
  console.log(`[wizard] listening on ${PORT} (project=${FIREBASE_PROJECT_ID || "?"}, allowlist=${allowList.length || "none"})`);
});

// Wizard backend (Cloud Run service: wizard-api)
//
// Receives setup submissions from /wizard/ frontend, persists to Firestore
// for tracking. Future phases will:
//   - exchange Google OAuth token for cloud-platform scoped credentials
//   - exchange GitHub OAuth code for a personal access token
//   - kick off Cloud Tasks chain that provisions the user's GCP project
//
// For now (α): we record the submission and return status=manual_required,
// signalling the owner that a human bootstrap is needed for this user.
// The frontend polls /runs/:id and shows progress as it advances.

import express from "express";
import admin from "firebase-admin";
import { Firestore } from "@google-cloud/firestore";

const {
  FIREBASE_PROJECT_ID,
  ALLOWED_EMAILS = "",
  DEV,
  PORT = 8080,
} = process.env;

admin.initializeApp({ projectId: FIREBASE_PROJECT_ID || undefined });
const allowList = ALLOWED_EMAILS.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);

// Firestore (default) database. Created idempotently by infra/bootstrap.sh.
// Service account must have roles/datastore.user on the project.
const db = new Firestore({ projectId: FIREBASE_PROJECT_ID || undefined });
const RUNS = db.collection("wizard_runs");

// ──────────────────────────────────────────
const app = express();
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

// Firebase ID トークン検証
app.use("/api", async (req, res, next) => {
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

  const now = admin.firestore.Timestamp.now();
  const doc = {
    user_uid: req.user.uid,
    user_email: req.user.email || "",
    survey,
    github_username: ghUser,
    // 現状ステータス: 自動プロビジョン未実装なので manual_required で止まる。
    // 将来のステップ追加例:
    //   received → connecting_github → creating_gcp_project → enabling_apis →
    //   provisioning_resources → forking_repo → first_deploy → completed
    status: "manual_required",
    steps: [
      { name: "received", status: "done", at: now },
      { name: "manual_required", status: "pending", at: now,
        message: "GCP プロビジョン自動化は実装中。オーナーに連絡が届いて手動セットアップが入ります。" },
    ],
    created_at: now,
    updated_at: now,
  };

  try {
    const ref = await RUNS.add(doc);
    await logEvent(ref.id, {
      actor: "backend", level: "info", code: "submit.received",
      message: `goal=${survey.goal} skill=${survey.skill} team=${survey.team} gh=${ghUser || "-"}`,
      user_email: req.user.email,
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
    github_username: d.github_username,
    user_email: d.user_email,
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

app.listen(PORT, () => {
  console.log(`[wizard] listening on ${PORT} (project=${FIREBASE_PROJECT_ID || "?"}, allowlist=${allowList.length || "none"})`);
});

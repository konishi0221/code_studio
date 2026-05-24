import express from "express";
import { GoogleGenerativeAI } from "@google/generative-ai";
import admin from "firebase-admin";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const {
  GEMINI_API_KEY,
  GEMINI_MODEL = "gemini-2.5-flash",
  FIREBASE_PROJECT_ID,
  ALLOWED_EMAILS = "",
  DEV,
  PORT = 8080,
} = process.env;

admin.initializeApp({ projectId: FIREBASE_PROJECT_ID || undefined });
const allowList = ALLOWED_EMAILS.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);

// ──────────────────────────────────────────
// このシステムの知識をビルド時にバンドルした docs/ から読み込む。
// cloudbuild.yaml が platform/CLAUDE.md / README.md / DEPLOY.md を
// この docs/ にコピーしてから kaniko build する。
// ──────────────────────────────────────────
async function loadDocs() {
  const docsDir = path.join(__dirname, "docs");
  const out = [];
  try {
    const files = await fs.readdir(docsDir);
    for (const f of files.sort()) {
      if (!f.endsWith(".md")) continue;
      const content = await fs.readFile(path.join(docsDir, f), "utf8");
      out.push({ name: f, content });
    }
  } catch (e) {
    console.warn(`[help] docs/ load failed: ${e.message}`);
  }
  return out;
}

let SYSTEM_INSTRUCTION = "";
const SYS_BASE = `あなたはこの GCP ベースのミニアプリ開発スタック (claude-studio) を熟知した日本語アシスタントです。
ユーザーはこのスタックを使って Claude Code と一緒にミニアプリを開発する個人や小規模チームです。
以下のドキュメントの内容をすべて把握した上で、ユーザーの質問に**簡潔に・例え話を交えて・日本語で**答えてください。

回答方針:
- 技術用語は必ず例え話に翻訳する（Cloud Run = お店の厨房、Cloud SQL = 帳簿、git push = 事務所に提出 など）
- コードを書くときは HTML/CSS/JS の例を中心に。コマンド系を案内するときは「これは小西/オーナーに頼んでください」と促す
- 推測で答えない。ドキュメントに書かれていないことは「ドキュメントには明示されていません」と正直に言う
- 励ましたり「次は〇〇しましょう」のような誘導はしない。質問にだけ答える
- 長文を避ける。最初は 2-4 文で答えて、ユーザーが追加質問してきたら掘り下げる

==================== 知識ベース ====================
`;

async function buildSystemInstruction() {
  const docs = await loadDocs();
  if (docs.length === 0) {
    SYSTEM_INSTRUCTION = SYS_BASE + "\n(ドキュメントが見つかりませんでした)";
    return;
  }
  const sections = docs.map(d => `### ${d.name}\n\n${d.content}`).join("\n\n---\n\n");
  SYSTEM_INSTRUCTION = SYS_BASE + sections;
  console.log(`[help] loaded ${docs.length} docs into system instruction (${SYSTEM_INSTRUCTION.length} chars)`);
}

await buildSystemInstruction();

// ──────────────────────────────────────────
const app = express();
app.use(express.json({ limit: "2mb" }));

app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "content-type,authorization");
  if (req.method === "OPTIONS") return res.sendStatus(204);
  next();
});

app.get("/health", (req, res) => {
  res.json({ ok: true, docs: SYSTEM_INSTRUCTION.length, model: GEMINI_MODEL });
});

// Firebase ID トークン検証
app.use("/api", async (req, res, next) => {
  if (DEV) { req.user = { email: "dev@local" }; return next(); }
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

const genAI = GEMINI_API_KEY ? new GoogleGenerativeAI(GEMINI_API_KEY) : null;

app.post("/api/chat", async (req, res) => {
  if (!genAI) return res.status(500).json({ error: "GEMINI_API_KEY が未設定" });
  const history = Array.isArray(req.body?.history) ? req.body.history : [];
  if (history.length === 0) return res.status(400).json({ error: "history が空" });

  // 履歴フォーマット変換: [{role,text}] → Gemini contents [{role,parts:[{text}]}]
  // role は "user" / "model" のみ。
  const contents = history.map(m => ({
    role: m.role === "user" ? "user" : "model",
    parts: [{ text: String(m.text || "") }],
  }));

  try {
    const model = genAI.getGenerativeModel({
      model: GEMINI_MODEL,
      systemInstruction: SYSTEM_INSTRUCTION,
    });
    const result = await model.generateContent({ contents });
    const reply = result.response?.text() || "";
    console.log(`[help] chat user=${req.user.email} in=${history[history.length-1].text.slice(0,40)} out=${reply.slice(0,40)}`);
    res.json({ reply });
  } catch (e) {
    console.error(`[help] gemini error: ${e.message}`);
    res.status(500).json({ error: "Gemini 呼び出し失敗: " + e.message });
  }
});

app.listen(PORT, () => {
  console.log(`[help] listening on ${PORT} (model=${GEMINI_MODEL}, docs=${SYSTEM_INSTRUCTION.length} chars)`);
});

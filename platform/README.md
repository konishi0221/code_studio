# claude-studio platform

claude-studio の **運営側 Web 本体**。
エンドユーザーが自分の GCP にミニアプリ基盤を立ち上げるための **LP + Setup Wizard** を提供する。

**🌐 本番 URL**: https://code-studio-497311-app.web.app

`main` に push すれば Cloud Build トリガで自動デプロイ → 上記 URL で公開。

> ⚠ **重要な役割分担**
> - **このリポ (`platform/`)** = 運営側。LP・wizard・(開発中の) ヘルプチャットだけ載ってる。
> - **エンドユーザー向けミニアプリ群** = **別リポジトリ** (テンプレ repo、未着手) に置く。wizard が clone してユーザーの GCP にデプロイする。
> - 今このリポの `apps/help/` 等は最終的に別リポへ移動予定。**それまでの開発デバッグ用**として `apps/debug/` 配下からアクセスできる。

---

## 📁 ルーティング (Hosting)

| URL | ディレクトリ | 役割 | 認証 |
|---|---|---|---|
| `/` | `apps/index.html` | **LP** (プロダクト説明 + CTA) | 不要 |
| `/wizard/` | `apps/wizard/index.html` | **Setup Wizard** (Google ログイン + GitHub + アンケート + 確認) | wizard 内で Google サインイン |
| `/debug/` | `apps/debug/index.html` | **内部ランチャー** (旧 `apps/index.html`)。help 等の開発用 | Firebase Auth (Google) |
| `/help/` | `apps/help/index.html` | AI ヘルプチャット (このシステムを知ってる Gemini)。debug 配下扱い | Firebase Auth |

未認証で `/help/` に直接アクセス → `/debug/?next=/help/` に飛んでサインイン → 戻る。

---

## 🤖 Claude Code への依頼の定型句

新しい機能や修正を Claude Code に依頼するときは、最初に以下を伝える：

> **`README.md` と `DEPLOY.md` と `CLAUDE.md` を読んでから、〇〇をやって**

これで Claude Code がプロジェクト構成・デプロイ方法・コード規約を全部把握してから書いてくれる。

---

## 🚨 コードを書く前に必ず pull する

**最重要・例外なし**。コードを編集する前に、ローカルが remote の最新と一致しているか確認する。

```bash
git fetch origin main
git rev-list --left-right --count main...origin/main   # "0	0" を確認
git pull --ff-only origin main
```

詳細ルールは `CLAUDE.md` §0 参照。

---

## 📁 ディレクトリ構成

```
platform/
├── apps/                        ← Hosting 公開ルート
│   ├── index.html               ← LP (エンドユーザー向け)
│   ├── config.js                ← Cloud Run URL (ビルド時に自動注入)
│   ├── wizard/                  ← Setup Wizard → /wizard/
│   │   ├── index.html
│   │   └── README.md
│   ├── debug/                   ← 内部ランチャー → /debug/
│   │   ├── index.html
│   │   └── README.md
│   └── help/                    ← AI ヘルプチャット → /help/ (デバッグ用、別リポへ移動予定)
│       ├── index.html
│       ├── README.md
│       ├── server/              ← Cloud Run コード
│       ├── app.yaml             ← bootstrap.sh が読むメタデータ
│       └── cloudbuild.yaml      ← Cloud Build 定義
├── infra/
│   ├── bootstrap.sh             ← GCP リソース一括プロビジョン
│   ├── db.sh                    ← psql ラッパー
│   └── deploy-hosting.sh        ← 手動 Hosting deploy ラッパー
├── firebase.json
├── CLAUDE.md
├── DEPLOY.md
└── README.md                    ← これ
```

---

## 🧰 使ってる GCP サービス

| サービス | 用途 (例え話) |
|---|---|
| **Firebase Auth** | 入口の受付係 (誰が来たか確認) |
| **Firebase Hosting** | お店の看板・店内 (静的ファイル配信) |
| **Cloud Run** | お店の厨房 (サーバ側プログラム実行) |
| **Cloud SQL (Postgres)** | 帳簿棚 (行と列で整理されたデータ) — 現状未使用 |
| **Cloud Storage** | 倉庫 (ファイル・画像保存) — 現状未使用 |
| **Gemini API** | 文章を読んだり画像を見たりする AI (help が利用) |
| **Secret Manager** | 金庫 (API キー等の保管) |
| **Cloud Build** | 工場 (コードからデプロイ) |
| **Artifact Registry** | 倉庫 (ビルド済みコンテナ) |

---

## 🚀 デプロイ

> 構造の全詳細は **[DEPLOY.md](DEPLOY.md)** に集約。

### 仕組み

```
コード修正 → main に push → Cloud Build トリガ発火 → (Docker build → Cloud Run) → Hosting 反映
                                                                              ↓
                                          ユーザーは https://code-studio-497311-app.web.app を開くだけ
```

main への push が Cloud Build をキックして本番デプロイされる。**`firebase deploy` を直接叩くのは禁止** (古い clone から打つと本番を巻き戻すため)。手動 deploy は `bash infra/deploy-hosting.sh` 経由。

### トリガの発火条件

Cloud Build トリガは 2 本:

| トリガ | 発火条件 | やること |
|---|---|---|
| `help-api-deploy` | `apps/help/**` / `CLAUDE.md` / `README.md` / `DEPLOY.md` / `apps/index.html` / `apps/config.js` / `apps/debug/**` のいずれか変更 | help-api (Cloud Run) ビルド + Hosting (apps/ 全体) デプロイ |
| `wizard-api-deploy` | `apps/wizard/**` 変更 | wizard-api (Cloud Run) ビルド + Hosting (apps/ 全体) デプロイ |

両方とも Hosting を deploy するので、最後勝ち (Firebase Hosting deploy は冪等)。
発火条件は各アプリの `app.yaml` の `EXTRA_TRIGGER_FILES` + `apps/<APP>/**` の組み合わせ。変更したらオーナー側で `bash platform/infra/bootstrap.sh` 再実行 or Cloud Console でトリガ更新が必要。

---

## 📦 現在のアプリ (このリポ内)

| ディレクトリ | サービス | 役割 | 状態 |
|---|---|---|---|
| `apps/` (`/`) | — | LP | ✅ |
| `apps/wizard/` (`/wizard/`) | `wizard-api` (Cloud Run) | Setup Wizard (5 ステップ: Google → GitHub OAuth → アンケート → オプション/月額試算 → 確認) | α (UI + 受付 API + 詳細ログ + コスト試算 + GitHub OAuth 実装済、GCP 自動プロビジョン未実装) |
| `apps/debug/` (`/debug/`) | — | 内部ランチャー | ✅ |
| `apps/help/` (`/help/`) | `help-api` (Cloud Run) | AI ヘルプチャット (Gemini) | ✅ (デバッグ用、最終的に別リポへ) |

### 🔍 障害切り分け用ログ

Wizard は全イベント (auth, click, fetch, error, step transition) を構造化記録:
- **フロント側**: `wizard_runs/{id}/events` に POST + local 蓄積 → 画面下「詳細ログ」パネルで常時閲覧
- **バックエンド側**: 同じ events subcollection + `console.log(JSON)` で Cloud Logging へ
- **詰まったとき**: パネルの「ログをコピー」ボタンで env / UA / run_id 付きでクリップボードにコピー → AI ヘルプに貼って原因切り分け
- **オーナー用**: パネルから直接 Cloud Logs と Firestore のドキュメントへ飛べる
- Google / GitHub の OAuth 仕様等が変わって動かなくなったとき、log code (`auth.signin_failed` / `submit.failed` / `poll.error` 等) で死んだブロックが即わかる

---

## 🔗 詳細ドキュメント

- [CLAUDE.md](CLAUDE.md) — Claude Code 用ルール
- [DEPLOY.md](DEPLOY.md) — デプロイ構造の完全ドキュメント
- [apps/wizard/README.md](apps/wizard/README.md) — Wizard 設計と残課題
- [apps/debug/README.md](apps/debug/README.md) — 内部ランチャーの位置づけ
- [apps/help/README.md](apps/help/README.md) — AI ヘルプの使い方
- [../docs/saas-draft-v1.md](../docs/saas-draft-v1.md) — SaaS 全体設計 (一次資料)

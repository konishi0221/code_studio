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

現状 Cloud Build トリガは `help-api-deploy` 1 本で、help/cloudbuild.yaml を走らせる。
このビルドは Cloud Run (help-api) と **Hosting (apps/ 全体)** の両方をデプロイするので、LP / wizard / debug の更新もこのトリガで配信される。

発火条件 = `apps/help/**`, `CLAUDE.md`, `README.md`, `DEPLOY.md`, `apps/index.html`, `apps/config.js`, `apps/wizard/**`, `apps/debug/**` のいずれか変更時。
(`apps/help/app.yaml` の `EXTRA_TRIGGER_FILES` で管理。変更したらオーナー側で `bash platform/infra/bootstrap.sh` 再実行 or Cloud Console でトリガ更新が必要)

---

## 📦 現在のアプリ (このリポ内)

| ディレクトリ | 役割 | 状態 |
|---|---|---|
| `apps/` (`/`) | LP | ✅ |
| `apps/wizard/` (`/wizard/`) | Setup Wizard | α (UI 動く、バックエンド未実装) |
| `apps/debug/` (`/debug/`) | 内部ランチャー | ✅ |
| `apps/help/` (`/help/`) | AI ヘルプチャット (Gemini) | ✅ (デバッグ用、最終的に別リポへ) |

---

## 🔗 詳細ドキュメント

- [CLAUDE.md](CLAUDE.md) — Claude Code 用ルール
- [DEPLOY.md](DEPLOY.md) — デプロイ構造の完全ドキュメント
- [apps/wizard/README.md](apps/wizard/README.md) — Wizard 設計と残課題
- [apps/debug/README.md](apps/debug/README.md) — 内部ランチャーの位置づけ
- [apps/help/README.md](apps/help/README.md) — AI ヘルプの使い方
- [../docs/saas-draft-v1.md](../docs/saas-draft-v1.md) — SaaS 全体設計 (一次資料)

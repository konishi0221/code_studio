# claude-studio

> Claude Code で個人・小規模チーム向けのミニアプリを次々作るための GCP ベース Web プラットフォーム。
> プラットフォーム本体 + 将来のユーザー向けテンプレート + 設計ドキュメント の親リポ。

## 構成

```
claude-studio/
├── README.md          ← これ（運営側用）
├── docs/              ← 設計ドキュメント
│   ├── saas-draft-v1.md
│   └── migration-to-saas.md
├── platform/          ← ⭐ プラットフォーム本体（このリポを main push したら自動デプロイされる Web 本体）
│   ├── apps/
│   │   ├── index.html       ← ランチャー
│   │   ├── config.js
│   │   ├── help/            ← AI ヘルプチャット（このシステムを知ってる Gemini）
│   │   ├── quiz/            ← 教育クイズ（未着手）
│   │   └── wizard/          ← Setup Wizard（scaffold のみ、ロジック未実装）
│   ├── infra/
│   │   ├── bootstrap.sh     ← GCP リソース一括プロビジョン
│   │   ├── db.sh            ← psql ラッパー
│   │   └── deploy-hosting.sh ← 手動 Hosting deploy ラッパー
│   ├── firebase.json
│   ├── CLAUDE.md
│   ├── DEPLOY.md
│   └── README.md
└── template/          ← 各ユーザーの GCP に wizard が生成する配布テンプレ（未着手）
```

### 2 つのレイヤを区別する

| レイヤ | 何 | デプロイ先 |
|---|---|---|
| **`platform/`** | claude-studio 運営本体。ランディングページ・wizard UI・AI ヘルプ等を載せる Web 本体 | 運営側 GCP プロジェクト |
| **`template/`** (未着手) | wizard が各ユーザーの GCP に展開する初期テンプレ。最終的にはユーザーが Claude Code で日々編集する場 | 各ユーザーの GCP プロジェクト |

## 開発の進め方

設計とロードマップは `docs/saas-draft-v1.md` 参照。移植・サニタイズ手順は `docs/migration-to-saas.md` 参照。
プラットフォーム本体の運用ルール（Claude Code の振る舞い、push 手順）は `platform/CLAUDE.md` 参照。

### 新規セッション開始時のお決まり

```bash
git fetch origin main
git rev-list --left-right --count main...origin/main   # "0	0" 確認
git pull --ff-only origin main                          # behind なら追従
```

詳細は `platform/CLAUDE.md` §0 と同じルール。

## プラットフォーム本体のデプロイ（運営側）

このリポ自体を運営側 GCP プロジェクトにデプロイすると、claude-studio のプラットフォーム Web 本体が立ち上がる。

```bash
PROJECT_ID=<your-project> \
OWNER_EMAIL=<your-email> \
GITHUB_OWNER=<github-user> \
GITHUB_REPO=code_studio \
HOSTING_SITE=<unique-site-id> \
  bash platform/infra/bootstrap.sh
```

詳細は `platform/DEPLOY.md` 参照。bootstrap 後は main に push する度に Cloud Build トリガが自動デプロイする。

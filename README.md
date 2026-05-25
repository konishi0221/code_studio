# claude-studio

> Claude Code で個人・小規模チーム向けのミニアプリを次々作るための GCP ベース Web プラットフォーム。
> プラットフォーム本体 + 将来のユーザー向けテンプレート + 設計ドキュメント の親リポ。

**🌐 本番 URL**: https://code-studio-497311-app.web.app

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

初回セットアップ手順は **[docs/setup.md](docs/setup.md)** にスマホで読める形でまとまっている (Cloud Shell コマンド・Firebase Console 操作・所要時間付き)。

要約：
1. Cloud Shell で `bash platform/infra/bootstrap.sh` (env vars 指定)
2. GitHub ↔ Cloud Build をブラウザで 1 タップ接続
3. bootstrap 再実行 (トリガ作成)
4. Firebase Auth / OAuth redirect URI を手動追加
5. main に push → 自動デプロイ → `https://<HOSTING_SITE>.web.app` で稼働

詳細は [docs/setup.md](docs/setup.md) と [platform/DEPLOY.md](platform/DEPLOY.md) 参照。

# claude-studio スターターテンプレート

これは claude-studio の wizard が立ち上げた **あなた専用のミニアプリ基盤** のソースコードです。

> ⚠️ 過渡期: 現状このディレクトリは `code_studio` リポの subdir として配置されてます。将来は独立リポ (例: `claude-studio-template`) に extract される予定。wizard-bootstrap.sh はこの `template/` を user の repo の root としてセットアップする想定で動きます。

## 構造

```
template/                       ← user の repo root として extract される
├── README.md                   ← これ
├── CLAUDE.md                   ← user 側 Claude Code 用ルール
├── DEPLOY.md                   ← user 側デプロイ仕様
├── firebase.json
├── apps/                       ← Hosting 公開ルート
│   ├── index.html              ← ユーザーのトップページ (ミニアプリ一覧)
│   ├── config.js               ← Cloud Run URL がビルド時に注入される
│   ├── help/                   ← AI ヘルプ (Gemini) — 常時 include
│   ├── memo/                   ← localStorage メモ帳 — 常時 include (DB不要)
│   └── keihi/                  ← 経費管理スカフォールド — wizard で cloudsql=on の時のみ
└── infra/
    ├── bootstrap.sh            ← GCP リソース一括プロビジョン (BASE_DIR=template デフォルト)
    ├── db.sh                   ← psql ラッパー
    └── deploy-hosting.sh
```

## アプリの条件付き同梱 (wizard との連動)

各アプリの `app.yaml` に `REQUIRES_OPTIONS: <option_key>` を書くと、wizard で
そのオプションを ON にしたユーザーにだけ同梱される (= wizard-bootstrap.sh が
ON じゃないユーザーのリポからそのディレクトリを削除して push する)。

| アプリ | 同梱条件 | 理由 |
|---|---|---|
| `help/` | 常時 | Cloud Run のみ (Gemini API) |
| `memo/` | 常時 | 静的のみ (DB / バックエンド不要) |
| `keihi/` | `cloudsql=true` | Cloud SQL の `keihi` DB が必要 |

新しいアプリを追加する時:
- DB が要らない → `app.yaml` から `REQUIRES_OPTIONS` を省く (常時 include)
- DB / Storage が要る → `REQUIRES_OPTIONS: cloudsql` 等を入れる

## 新しいミニアプリの追加

1. `apps/<id>/index.html` と `apps/<id>/README.md` を作る
2. ルートの `apps/index.html` の `APPS` 配列に 1 行追加
3. main に push → 自動デプロイ

Cloud Run バックエンドが要るなら `apps/<id>/server/` + `apps/<id>/cloudbuild.yaml` + `apps/<id>/app.yaml` も。

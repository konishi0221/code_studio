# claude-studio

> Claude Code で個人・小規模チーム向けのミニアプリを次々作るための GCP テンプレート。
> 配布用テンプレ + 将来の Setup Wizard を含む親リポ。

このリポは「運営側」のソースリポジトリ。利用者に渡すのは `template/` 配下のみ。

## 構成

```
claude-studio/
├── README.md          ← これ（運営側用）
├── docs/              ← 設計ドキュメント
│   ├── saas-draft-v1.md
│   └── migration-to-saas.md
├── template/          ← 配布する中身（ユーザーが GitHub Template として複製）
│   ├── apps/
│   │   ├── index.html       ← ランチャー
│   │   ├── config.js
│   │   └── help/            ← ⭐ AI ヘルプチャット（このシステムを知ってる Gemini）
│   ├── infra/
│   ├── firebase.json
│   ├── CLAUDE.md
│   ├── DEPLOY.md
│   └── README.md
└── wizard/            ← Setup Wizard（未着手、Phase 1 で実装）
```

## 開発の進め方

最新のステータスとロードマップは `docs/saas-draft-v1.md` 参照。移植・サニタイズ手順は `docs/migration-to-saas.md` 参照。

新規セッション開始時のお決まり：

```bash
git fetch origin main
git rev-list --left-right --count main...origin/main   # "0	0" 確認
```

詳細は `template/CLAUDE.md` の §0 と同じルール。

## 配布フロー（最終形）

利用者は以下 4 ステップで自分のミニアプリ基盤を立ち上げる：

1. このリポを **GitHub Template** で自分の private リポに複製
2. 自分の GCP プロジェクトを作成
3. `template/infra/bootstrap.sh` を 1 コマンド実行
4. Claude Code で開発開始

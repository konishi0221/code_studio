# AIヘルプ (`/help/`)

このスタック (claude-studio) について何でも答える Gemini チャット。
ランチャーから 🟦 AIヘルプ をタップ → Google ログイン済みの状態で利用可能。

## 何ができる

- 「Cloud Run って何？」「git push したら何が起きる？」のような技術質問
- 「新しいミニアプリの追加手順は？」のような運用質問
- このリポの `CLAUDE.md` / `README.md` / `DEPLOY.md` の内容を Gemini が把握済みなので、**このシステム固有の答え**が返ってくる

## どこを直すと挙動が変わる

| ファイル | 役割 |
|---|---|
| `index.html` | UI (チャット画面、サジェスト、会話履歴の localStorage 保存) |
| `server/index.js` | バックエンド (Firebase Auth 検証 → Gemini API 呼び出し) |
| `server/index.js` の `SYS_BASE` 定数 | 回答方針 (口調・例え話の指示) |
| `cloudbuild.yaml` の `bundle-docs` ステップ | Gemini に食わせるドキュメントの選び方 |

## 仕組み

```
[ブラウザ] ──(Bearer token + history)──▶ [Cloud Run help-api]
                                              │
                                              ├ Firebase Auth ID トークン検証
                                              │
                                              ├ system instruction =
                                              │    SYS_BASE + bundle-docs で
                                              │    バンドルした CLAUDE.md など
                                              │
                                              └ Gemini API (generateContent)
                                                  ↓
[ブラウザ] ◀──── reply ──────────────────────────┘
```

- 会話履歴はブラウザの `localStorage` に保存 (`STORAGE_KEY = "helpThread"`)
- 直近 20 ターンだけサーバに送る (トークン節約)
- ドキュメントはビルド時に Docker image にバンドル (`cloudbuild.yaml` の `bundle-docs` ステップ)
  → ドキュメント更新時は再デプロイで反映

## ファイル構成

```
help/
├── README.md           ← これ
├── index.html          ← UI
├── app.yaml            ← bootstrap.sh が読む
├── cloudbuild.yaml     ← デプロイ仕様
└── server/
    ├── index.js        ← Express + Gemini
    ├── package.json
    ├── Dockerfile
    ├── .dockerignore
    └── docs/           ← ビルド時に platform/*.md がコピーされる (git では空)
```

## 設定値

`cloudbuild.yaml` の冒頭 `substitutions` を bootstrap.sh が書き換える前提:

| Key | 例 | 説明 |
|---|---|---|
| `_INVOKER` | `user:foo@example.com` | Cloud Run 呼び出し許可ユーザー (組織ポリシー対策) |
| `_ALLOWED_EMAILS` | `foo@example.com,bar@example.com` | API を叩けるメール (空なら任意の認証ユーザー) |
| `_HOSTING_SITE` | `myproject-app` | Firebase Hosting site id (globally unique) |

## 残課題

- [ ] ストリーミング応答 (今は generateContent で一括返答、長い回答だと待ち時間が目立つ)
- [ ] 会話履歴をサーバ側に永続化 (現状 localStorage、デバイス間で同期できない)
- [ ] system prompt のドキュメント選択を `app.yaml` で設定可能に
- [ ] コスト記録 (Gemini 利用量を後で確認できるよう DB に記録)

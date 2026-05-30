# CLAUDE.md (user 側 Claude Code 用ルール)

> Claude Code が自動で読み込む内部メモ。
> README.md とは別の役割: README は人間向けのプロジェクト説明、ここは Claude の振る舞い指定。

このリポジトリは wizard が立ち上げた **あなた専用のミニアプリ基盤** です。
Claude Code に「README 読んで、〇〇を作って」と頼むだけで、Cloud Run + Cloud SQL + Hosting + Auth を使ったアプリを足していけます。

---

## 0. セッション開始時の標準動作 (応答前に 1 回)

新規セッション開始時、Claude は以下を確認してから応答を始める:

1. **`git fetch origin main && git pull --ff-only origin main`** (古い状態で commit/push する事故を防ぐ)
2. CLAUDE.md / README.md / DEPLOY.md を最後まで読む
3. `git log -15 --oneline` で直近の作業を把握
4. `apps/` を眺めて、作りかけのミニアプリが無いか確認

---

## 1. デプロイ = main に push

このリポは `main` への push で Cloud Build が走り、自動デプロイされる。
**`firebase deploy` を直接叩くのは禁止** (古い clone から打つと本番を巻き戻すため)。
手動 deploy は `bash infra/deploy-hosting.sh` 経由のみ。

---

## 2. アプリ追加のレシピ

### 静的のみのアプリ (DB/API なし)

`apps/<id>/index.html` + `apps/<id>/README.md` を作って、`apps/index.html` の `APPS` 配列に 1 行追加。

### Cloud Run バックエンド付きアプリ

`apps/<id>/` 配下に:
- `index.html` (フロントエンド)
- `server/` (Node + Express コード)
- `cloudbuild.yaml` (Docker build → Cloud Run deploy)
- `app.yaml` (bootstrap.sh が読むメタデータ、`HAS_DB` / `HAS_BUCKET` フラグ)
- 必要なら `infra/schema.sql`

詳細は `apps/help/` を参考に (= 既存の動くサンプル)。

---

## 3. 触っちゃダメなもの

- `infra/` 配下 (= bootstrap.sh / db.sh / deploy-hosting.sh)
- `firebase.json` のルート設定 (Hosting site id は build 時に注入される)
- 他人のアプリディレクトリ (チームで使う場合)

---

## 4. AI コストの感覚

- Gemini Flash: 質問 1 回 ¥1〜3 程度。月 100 回でも ¥数百
- Cloud Build: 1 deploy ¥1〜5、無料枠 120 分/日
- Cloud Run: scale-to-zero ならアイドル ¥0、リクエストごと課金 (月 200 万まで無料枠)

使った分課金の上で無料枠が広いので、個人利用なら **基本構成だけなら月 ¥80〜200 ほど** で運用できる。

---

## 5. 詰まったとき

- `apps/help/` の AI ヘルプチャットに聞く (このシステムを知ってる Gemini)
- ビルドが失敗したら Cloud Build Console のログ
- 認証で詰まったら、ブラウザの sessionStorage / cookie をクリアして再試行

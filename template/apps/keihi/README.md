# 経費管理 (`/keihi/`)

> ⚠️ スカフォールドのみ。中身は Claude Code と一緒に作っていく。

領収書を撮って Cloud SQL に保管するミニアプリの**骨**。

## 含まれるもの (wizard で `cloudsql=true` を選んだ場合のみ)

- `index.html` — 仮の表示ページ (まだ機能なし)
- `app.yaml` — bootstrap.sh 用メタデータ (`HAS_DB=true`, `HAS_BUCKET=true`, `REQUIRES_OPTIONS: cloudsql`)
- `cloudbuild.yaml` — Cloud Build 設定 (Cloud Run の `keihi-api` をビルド)
- `server/` — Cloud Run コード (placeholder)
- `infra/schema.sql` — DB スキーマ (placeholder)

## Claude Code に頼んで作る例

> `apps/keihi/README.md` 読んで、領収書を写真撮って OCR で日付・金額・店名を抽出 → Cloud SQL に保存 → 一覧画面で月別合計を出す機能を作って

## 削除したい場合

wizard で `cloudsql` を選ばなかった場合、そもそもこのディレクトリは user のリポにコピーされない。後から消したい場合は `apps/keihi/` 配下を削除 + ルート `apps/index.html` の `APPS` 配列から該当行を削除。

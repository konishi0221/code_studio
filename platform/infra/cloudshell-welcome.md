# claude-studio 自動セットアップ

Wizard で集めた情報を使って、あなたの GCP プロジェクトに claude-studio
一式を自動で立ち上げます。所要時間 5〜10 分。

## 実行

Wizard 画面に表示されているコマンドをコピーして、ここに貼り付けて Enter
してください。

例:

```
bash platform/infra/wizard-bootstrap.sh \
  https://wizard-api-xxxxx.a.run.app \
  YOUR_TOKEN_HERE
```

## 途中で聞かれること

- **PROJECT_ID**: あなたの GCP プロジェクト ID (gcloud に既に設定されてれば自動)
- **GEMINI_API_KEY**: <https://aistudio.google.com/app/apikey> で取得
- **請求アカウント連携**: まだなら案内に従って Cloud Console で連携

## 完了後

`https://<PROJECT_ID>-app.web.app` で立ち上がります (初回ビルドにあと数分)。
進捗は Wizard 画面で live 表示されます。

## トラブル

- 何か聞かれて分からない → 一度 Ctrl-C で止めて、Wizard 画面の「ログをコピー」
  ボタンから AI ヘルプに状況を貼って質問
- もう一度やり直したい → 同じコマンドをもう一度実行 (途中まで成功した分は
  bootstrap.sh が冪等にスキップ)

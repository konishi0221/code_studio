# claude-studio platform 実機デプロイ手順 (初回 1 回だけ)

このリポを自分の GCP プロジェクトにデプロイして、`https://<HOSTING_SITE>.web.app` で動かすまでの手順。スマホからでも進められるが、Cloud Shell を 1 回だけ叩く必要あり。

所要 15〜20 分 (うち手動操作は 5 分程度)。

---

## 前提

- [ ] GCP プロジェクトを 1 つ作成済み (請求アカウント紐付け済み)
- [ ] このリポ (`konishi0221/code_studio`) の main に最新がある
- [ ] Gemini API キーを持っている (https://aistudio.google.com/app/apikey から無料取得可)
- [ ] Cloud Shell が使える Google アカウント (= GCP プロジェクトのオーナー)

---

## ステップ 1: Cloud Shell で bootstrap 実行

[GCP コンソール](https://console.cloud.google.com/) 右上の `>_` アイコン (Cloud Shell) を開く。

```bash
# 1) リポを clone
git clone https://github.com/konishi0221/code_studio.git
cd code_studio

# 2) 必要な値を env vars にセット (適宜置換)
export PROJECT_ID=code-studio
export OWNER_EMAIL=<your-email>
export GITHUB_OWNER=konishi0221
export GITHUB_REPO=code_studio
# HOSTING_SITE は省略可。省略時は ${PROJECT_ID}-app になる (例: code-studio-app)
# export HOSTING_SITE=code-studio-app

# 3) bootstrap 実行
bash platform/infra/bootstrap.sh
```

途中で **Gemini API キーの入力**を求められる (一度だけ、Secret Manager に保存される)。

最後に「Cloud Build トリガが作成できなかった」というメッセージが出るのが**正常** (ステップ 2 で接続する)。

---

## ステップ 2: GitHub ↔ Cloud Build 接続 (ブラウザで 1 タップ)

bootstrap 出力に出てきた URL を開く:

```
https://console.cloud.google.com/cloud-build/triggers/connect?project=code-studio
```

1. 「リポジトリを接続」をタップ
2. **GitHub (Cloud Build GitHub App)** を選択 → 「続行」
3. GitHub のページに遷移したら **Authorize Google Cloud Build** をタップ
4. `konishi0221/code_studio` を選択 → Install
5. GCP コンソールに戻ってきたら「接続」完了

---

## ステップ 3: bootstrap 再実行 (今度はトリガが作られる)

Cloud Shell に戻って、もう一度：

```bash
bash platform/infra/bootstrap.sh
```

`Cloud Build trigger help-api-deploy (global, main only)` のステップで `created` と出れば成功。

---

## ステップ 4: Firebase Auth を有効化

[Firebase Console](https://console.firebase.google.com/project/code-studio/authentication/providers) を開く。

1. プロジェクトを Firebase 有効化していなければ「プロジェクトを追加」→ 既存 GCP プロジェクト (code-studio) を選ぶ
2. **Authentication** → **Sign-in method** → **Google** プロバイダを「有効」に
3. **Authentication** → **Settings** → **Authorized domains** に `code-studio-app.web.app` (= HOSTING_SITE) を追加

---

## ステップ 5: OAuth redirect URI を追加

[Cloud Console > Credentials](https://console.cloud.google.com/apis/credentials?project=code-studio) を開く。

1. 「OAuth 2.0 クライアント ID」セクションの **Web client (Firebase Auth が自動作成)** を開く
2. 「承認済みのリダイレクト URI」に追加：
   ```
   https://code-studio-app.web.app/__/auth/handler
   ```
3. 保存

---

## ステップ 6: 初回デプロイを発火

Cloud Shell でこのリポにいる状態のまま：

```bash
git commit --allow-empty -m "Trigger initial deploy"
git push origin main
```

または GitHub Web UI で main に何か commit して push でも OK。

[Cloud Build 履歴](https://console.cloud.google.com/cloud-build/builds?project=code-studio) を開いてビルド進行を見る。3〜5 分で完了するはず。

---

## ステップ 7: 動作確認

`https://code-studio-app.web.app` をスマホで開く。

- Google ログイン画面 → 自分のアカウントでログイン
- ランチャーが出る (Setup Wizard / AIヘルプ)
- **AIヘルプ** をタップ → Gemini と日本語チャット
  - 「Cloud Run って何？」と聞いてみる
- **Setup Wizard** をタップ → scaffold UI (実装中の画面が出る)

---

## 詰まったら

### Cloud Build が失敗する
- [ビルドログ](https://console.cloud.google.com/cloud-build/builds?project=code-studio) でエラー確認
- よくある原因: Cloud SQL がまだ作成中、IAM 反映待ち (再実行で大抵直る)

### ログインできない
- OAuth redirect URI 設定が反映されていない可能性 (反映に数分)
- Firebase Auth の Google プロバイダが「無効」のまま

### AIヘルプが「ログインが必要です」を返す
- `ALLOWED_EMAILS` に自分のメールが入っていない可能性
- Cloud Run の `help-api` の環境変数を確認: GCP コンソール → Cloud Run → help-api → 「変数とシークレット」

### `/help/` を開いても 404
- Hosting デプロイが完了してない可能性
- ビルドログで `deploy-hosting` ステップが緑になっているか確認

---

## 次回以降の運用

- `main` に push する度に Cloud Build トリガが自動で再デプロイ
- ドキュメント (CLAUDE.md / README.md / DEPLOY.md) を更新すると、help-api が再ビルドされ Gemini の知識ベースも自動更新される (help/app.yaml の `EXTRA_TRIGGER_FILES` 設定)
- Cloud Build トリガを止めたいときは GCP コンソール → Cloud Build → トリガから無効化

---

## コスト目安 (この構成)

| サービス | 月額 |
|---|---|
| Cloud Run (help-api、min=0) | 数十円〜数百円 (アイドル時ゼロ) |
| Cloud Storage / Artifact Registry | 数十円 |
| Firebase Hosting / Auth | 無料枠内 |
| Gemini API | 従量課金 (チャット 100 回で数円〜数十円) |
| Cloud Build | 月 120 分まで無料 |

**合計: 月 100〜500 円程度**。help しか使わない構成なので Cloud SQL は作っていない (HAS_DB=true のアプリが増えたら $9/月 追加)。

# デプロイ構造 完全ガイド

> このドキュメントは「どういう構造でデプロイされるか」を全部書いたもの。
> プロジェクト方針: **スマホ運用前提・ユーザーにコマンドを叩かせない**。
> 結論を先に → 自動デプロイの仕組みは **すでにコード化済み**。
> 足りないのは **GitHub ↔ Cloud Build の初回接続 (コンソールで 1 タップ、ターミナル不要) だけ**。

---

## 0. 一言まとめ

```
Claude が作業ブランチで作業 → main に push → トリガ発火 → 自動ビルド & デプロイ → ユーザーは URL を開くだけ
```

トリガはアプリごとに 1 つ。`apps/<app>/cloudbuild.yaml` を Cloud Build が読んで実行する。
ブランチは **`main` のみ** (`^main$`)。Claude は作業ブランチ `claude/development-session-*` で作業し、完了したら main に fast-forward して push する。

---

## 1. 全体アーキテクチャ

```
┌─────────────┐     ①push      ┌──────────────┐
│   GitHub    │ ─────────────▶ │ Cloud Build  │  ②cloudbuild.yaml を実行
│  (your repo)│   トリガ発火    │              │
└─────────────┘                └──────┬───────┘
                                      │
                          ┌───────────┼─────────────────┐
                          ▼           ▼                 ▼
                   ③Docker build  ④Cloud Run     ⑤Firebase Hosting
                   → Artifact Reg.   deploy         deploy
                                       │                 │
                                       └──── ⑥ブラウザ ──┘
                                       Firebase ID トークン付きで API を叩く
```

### 共有スタック (全アプリ共通・bootstrap.sh で 1 回作成)

| レイヤ | リソース |
|---|---|
| プロジェクト | あなたの GCP プロジェクト |
| Hosting | Firebase Hosting |
| Auth | Firebase Auth (Google プロバイダ) |
| API 実行基盤 | Cloud Run (`asia-northeast1`) |
| AI | Gemini API (Secret: `gemini-api-key`) |
| DB | Cloud SQL Postgres 15 (アプリ毎に DB を分けて使う) |
| Storage | Cloud Storage (アプリ毎にバケット) |
| イメージ置き場 | Artifact Registry |
| CI/CD | Cloud Build トリガ (GitHub 連携) |

---

## 2. アプリ別デプロイ構造

### 2-1. help (AI ヘルプチャット)

| 項目 | 値 |
|---|---|
| Cloud Run サービス | `help-api` (`allUsers` で public 化、認証は Express の `verifyIdToken`) |
| Hosting で公開 | `/help/` |
| ビルド定義 | `apps/help/cloudbuild.yaml` |
| ランタイム SA | `help-run@<project>.iam.gserviceaccount.com` |
| DB | なし |
| Storage | なし |
| Secrets | `gemini-api-key` |

#### `apps/help/cloudbuild.yaml` のステップ

1. **bundle-docs** — `template/{CLAUDE,README,DEPLOY}.md` を `apps/help/server/docs/` にコピー (Gemini の system prompt のソース)
2. **build** — Kaniko で `apps/help/server` を Docker build & push
3. **deploy** — Cloud Run `help-api` にデプロイ (`--no-allow-unauthenticated` で IAM 必須、`allUsers` invoker は prep-config で付与)
4. **prep-config** — `allUsers` invoker 付与・Cloud Run URL を `apps/config.js` に注入
5. **ensure-hosting-site** — Hosting サイトを冪等に作成
6. **deploy-hosting** — `firebase deploy --only hosting`

#### 認証フロー

```
スマホ → Firebase Hosting              (UI/静的・<hosting>.web.app)
            │
            │ Google ログイン (Firebase Auth)
            │   ↓ ID トークン取得 (localStorage に保存)
            │
            ▼ fetch (Cross-Origin)
         Cloud Run help-api             (https://help-api-...run.app)
            ├ IAM = allUsers invoker  ← public (org policy で SA 不可のため)
            └ Express ミドルウェア
                ├ Authorization: Bearer <token> を verifyIdToken で検証
                ├ ALLOWED_EMAILS にあれば通す (空なら全認証ユーザー許可)
                └ 検証失敗 → 401
```

Cloud Run の public 化は組織ポリシーで Hosting SA を弾く環境の代替策。
**Express の `verifyIdToken` が本当の認証ゲート**で、Cloud Run の IAM は単に「到達できる経路」を提供するだけ。

---

## 3. 自動デプロイ (Cloud Build トリガ) の仕組み

### トリガ作成 (bootstrap.sh が自動でやる)

bootstrap.sh は各 `apps/*/app.yaml` を見て、対応するトリガを冪等に作成する。

```
gcloud builds triggers create github \
  --name="<app>-api-deploy" \
  --repo-owner="<GITHUB_OWNER>" --repo-name="<REPO_NAME>" \
  --branch-pattern='^main$' \
  --build-config="apps/<app>/cloudbuild.yaml" \
  --included-files="apps/<app>/**"
```

第 1 世代 GitHub App トリガは `global` リージョンに作られる (`asia-northeast1` 等のリージョン指定だと `INVALID_ARGUMENT` で失敗するので注意)。

### 足りない唯一のもの: GitHub ↔ Cloud Build の初回接続

`gcloud builds triggers create github` は、対象 GitHub リポジトリが Cloud Build に**接続済み**である必要がある。未接続だと bootstrap.sh はスキップして接続用 URL を表示する。

接続は **OAuth 認可**なので、ターミナルではなく**ブラウザで 1 回タップ**するだけ：

> **手順 (1 回だけ)**
> 1. `https://console.cloud.google.com/cloud-build/triggers/connect?project=<PROJECT_ID>` を開く
> 2. 「リポジトリを接続」→ GitHub (Cloud Build GitHub App) を選択
> 3. 自分の GitHub リポを選んで承認
> 4. 完了。bootstrap.sh を再実行するとトリガが自動作成される

### 運用フロー (確定版)

```
1. ユーザーが要望を伝える
2. Claude が claude/development-session-* で作業 → commit → そのブランチに push
3. Claude が main を作業ブランチ HEAD に fast-forward → main に push
                          ↓ 自動
4. 該当アプリの Cloud Build トリガ発火 (main への push)
                          ↓ 自動
5. apps/<app>/cloudbuild.yaml 実行 (Docker → Cloud Run → Hosting)
                          ↓
6. ユーザー: https://<HOSTING_SITE>.web.app を開くだけ
```

- main は作業ブランチの祖先なので **fast-forward 可能＝履歴破壊なし・安全**
- ユーザーが GitHub / main / ターミナルを触る場面は**ゼロ**
- Claude は「main に push したらリリースされる」と認識して作業すること

---

## 4. 手動デプロイ (緊急時のみ)

通常は `main` に push すれば Cloud Build が自動 deploy する。手動は緊急時のみ。

### ⚠️ 重要: `firebase deploy` の直接呼び出しは禁止

直接 `firebase deploy --only hosting` を打つと、**ローカル clone が古い時に過去状態を本番に上書きしてしまう**。Cloud Build はその後正しい状態を deploy しても、人間が再び古い clone から打てば再発する。

### ✅ 手動 deploy する場合の正規ルート

```bash
bash infra/deploy-hosting.sh
```

このラッパーが内部で:
1. `git fetch origin main` で remote を更新
2. ローカル main を `git pull --ff-only origin main` で最新化 (未 push 不可・stale 不可)
3. `gcloud run services describe` で Cloud Run URL 取得 → `apps/config.js` を生成
4. `firebase deploy --only hosting --config=firebase.json`

main 以外のブランチや未 push commit があると最初の段階で exit 1 で止まる。古い clone からの暴発を構造的に防ぐ。

---

## 5. 過去にハマったポイント (再発防止メモ)

### 5-1. 組織ポリシー `iam.allowedPolicyMemberDomains`

Google Workspace の組織配下にあるプロジェクトでは、デフォルトで `constraints/iam.allowedPolicyMemberDomains` が「自社ドメインのメンバーのみ IAM 追加可」という制約を継承する。

これにより以下が**全部**ブロックされる：
- `allUsers` を invoker に追加 → `FAILED_PRECONDITION: not a permitted customer`
- `allAuthenticatedUsers` も同様
- **Firebase Hosting の Service Agent** `service-<PROJECT_NUMBER>@gcp-sa-firebasehosting.iam.gserviceaccount.com` も `gcp-sa-firebasehosting` ドメインなのでブロック → **自動 provision されない**

特に Hosting SA が provision されないと Hosting → Cloud Run rewrite が完全に死ぬ。

**対策**: プロジェクトレベルでポリシーを `allowAll: true` に上書き (`bootstrap.sh` が実行)：

```bash
cat > /tmp/policy.yaml <<'EOF'
name: projects/<PROJECT_ID>/policies/iam.allowedPolicyMemberDomains
spec:
  rules:
    - allowAll: true
EOF
gcloud org-policies set-policy /tmp/policy.yaml
sleep 180   # 反映に最大 7 分かかる
```

これは `roles/orgpolicy.policyAdmin` が必要。組織管理者ロール持ちのアカウントで実行する必要あり。**個人 Google アカウントで作ったプロジェクト (組織なし) なら不要**。

### 5-2. Hosting rewrite を捨てて Cloud Run 直叩きに

§5-1 の通り Hosting SA が IAM 登録できないため、伝統的な `Hosting /api/** → Cloud Run` の rewrite は使えない。

そこで：
- `firebase.json` から `rewrites` を削除
- Cloud Run を `allUsers` invoker で public 化
- `cloudbuild.yaml` の `prep-config` で `gcloud run services describe` から URL 取得 → `apps/config.js` に `window.API_BASE_<APP>='<url>';` を注入
- ブラウザは絶対 URL で Cloud Run を直接 fetch (CORS allow `*`)
- 認証は Express の `verifyIdToken` ミドルウェアが行う (実質ノーリスク)

### 5-3. iOS Safari ITP で別オリジン authDomain のストレージが消える

**症状**: iPhone でログイン → ミニアプリ画面に遷移 → 再ログイン要求

**原因**: Firebase Auth デフォルトの `authDomain = <project>.firebaseapp.com` を iOS Safari ITP が「クロスサイトストレージ」と判定して数日で消す。

**対策**: 各ミニアプリの index.html で `cfg.authDomain = location.hostname` を上書き。認証フロー全部を Hosting のドメイン内に閉じる。

**前提**: Cloud Console の OAuth クライアントの「承認済みリダイレクト URI」に `https://<HOSTING_SITE>.web.app/__/auth/handler` を**手動で**追加が必要。無いと Google ログイン画面で `redirect_uri_mismatch` で蹴られる。

---

## 6. よくある誤解

| 誤解 | 実際 |
|---|---|
| 「Cloud Run にデプロイしてないの？」 | Cloud Run と Hosting の両方に 1 回でデプロイ |
| 「Hosting の URL を開けば API も同一オリジン」 | 違う。`/api/**` rewrite は使ってない。ブラウザは Cloud Run の絶対 URL を叩く (CORS) |
| 「Cloud Run の URL を開けばいい」 | 直叩きで開いてもブラウザに Firebase ID Token が無いので 401。Hosting の URL を開く |
| 「毎回コマンドが必要」 | 接続後は **push だけ**で自動。コマンド不要 |
| 「`/api/*` が 403 returned by Google」 | Cloud Run の `allUsers` invoker が消えた可能性。§5-1 参照 |

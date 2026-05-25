# Setup Wizard (`/wizard/`)

エンドユーザーが自分の GCP プロジェクトに claude-studio 一式を立ち上げるための Setup Wizard。

> 現状 **α 実装**。
> - **UI**: 全ステップ動く (welcome → Google サインイン → GitHub 名入力 → アンケート → 確認 → 進捗表示)
> - **バックエンド (Cloud Run `wizard-api`)**: 実装済。submit を受け取って Firestore (`wizard_runs/{id}`) に永続化、状態取得 (poll) も可能
> - **自動プロビジョン本体**: 未実装。現状は status=`manual_required` で止まる (オーナーが手動で `infra/bootstrap.sh` 実行する流れ)
> - **次フェーズ**: GitHub OAuth 正式連携 → Cloud Tasks chain で GCP プロビジョン

## ユーザー側の作業を最小化する設計方針

ユーザーがやることは以下だけ:
1. **Google ログイン** (Firebase Auth)
2. **GitHub 連携** (OAuth で「GitHub で続行」ボタン 1 回。`read:user` + `public_repo` 権限のみ要求、未設定 / fallback 時のみ手入力)
3. **4 つの設問にクリック回答** (スキル / 作りたいもの / 業界 / チームサイズ)
4. **オプション選択 + 月額試算** (Cloud SQL / Storage / Cloud Run 常時 hot 等の有料サービスを toggle で選択、選択に応じて月額が live で更新)
5. **確認 → 開始ボタン**

これ以外は全部 wizard が裏でやる予定:
- GCP プロジェクト作成 / 請求紐付け
- API 一括有効化
- Cloud SQL / Storage / Service Account / Secret Manager
- GitHub Template から fork
- Cloud Build トリガ作成 + 初回デプロイ
- Firebase Auth プロバイダ有効化 + 認可ドメイン追加
- OAuth redirect URI 追加 (現状唯一の手動 GCP コンソール作業)

## GitHub OAuth (Step 2)

ユーザーが GitHub アカウントを wizard に連携する。テンプレ repo を fork したり、後で Cloud Build と接続したりするのに使う access_token を取る。

### フロー

1. フロント: 「GitHub で続行」ボタン → `POST /api/github/start` (Firebase ID トークン付き)
2. backend: state を Firestore `wizard_oauth_states/{state}` に保存、GitHub authorize URL を返す
3. フロント: `location.href` で遷移
4. GitHub で承認 → GitHub が `GET <wizard-api>/api/github/callback?code&state` にリダイレクト
5. backend: state 検証 → code → access_token 交換 → user info 取得 → `wizard_users/{uid}.github` に保存
6. backend: `HOSTING_BASE/wizard/?gh=connected&login=<username>` にリダイレクト
7. フロント: クエリ読んで連携済み表示

### オーナーの 1 回作業

1. **GitHub OAuth App 登録**: https://github.com/settings/developers → New OAuth App
   - **Application name**: 何でも (例: claude-studio wizard)
   - **Homepage URL**: `https://code-studio-497311-app.web.app`
   - **Authorization callback URL**: `https://<wizard-api Cloud Run URL>/api/github/callback`
     (wizard-api を 1 度デプロイした後で URL が判明する。初回は仮値 `https://example.com` で登録 → デプロイ後に更新でも OK)

2. **bootstrap.sh に渡す**:
   ```bash
   GITHUB_CLIENT_ID=Iv1.xxxxx \
   GITHUB_CLIENT_SECRET=xxxxx \
   bash platform/infra/bootstrap.sh
   ```
   (環境変数を渡せば対話 prompt スキップ、すでに secret がある場合は値を更新)

3. **wizard-api を再デプロイ**: 何でもいいので wizard/ 配下に commit → main push、または Cloud Build Console で `wizard-api-deploy` トリガを手動実行
   → 新しい `_GITHUB_CLIENT_ID` substitution と最新の secret が Cloud Run に注入される

### OAuth 未設定 / 設定中の挙動

- `GITHUB_CLIENT_ID` が空 or Secret Manager の値が空 → `/api/wizard/config` が `github_oauth_available: false` を返す
- フロント: 「GitHub で続行」ボタンの代わりに**ユーザー名手入力 fallback** を表示
- これで OAuth 設定前でも wizard は動く

## Cloud Shell ハンドオフ (Step 5 完了後)

submit するとフロントが backend に `POST /api/wizard/runs/{id}/provision-link`
を叩いて以下を取る:
- `token` (24h 有効、一度発行されたら同じ run の間は冪等)
- `command` (= `bash platform/infra/wizard-bootstrap.sh <api> <token>`)
- `cloud_shell_url` (deep link: 当リポを clone + `wizard-bootstrap.sh` を editor で open + `cloudshell-welcome.md` を terminal に print)

done 画面で:
1. コピー用コードボックスにコマンド (ワンタップで `📋`)
2. 「Cloud Shell を開く」ボタン (大きい primary CTA)
3. 進捗カード (polling で live 更新)

### `wizard-bootstrap.sh` の動き

Cloud Shell で実行されると:
1. `curl ... /api/wizard/by-token/{token}` で survey / options / GitHub login / user_email を取得
2. `gcloud config get-value project` で PROJECT_ID を拾う、無ければ prompt
3. 請求アカウント連携の有無を軽く検査 (`gcloud beta billing projects describe`)
4. `OWNER_EMAIL` / `HOSTING_SITE` / `GITHUB_OWNER` / `GITHUB_REPO` を env に組み立て
5. `GEMINI_API_KEY` を prompt (env で渡せばスキップ) — 各ユーザーが自前キー
6. 確認 → `bash bootstrap.sh` 実行 (非対話モード、すべて env で流し込み)
7. 各 step で `POST .../by-token/{token}/status` を叩いて wizard-api 経由で Firestore 更新 → フロントの polling に反映
8. 完了時に `status=completed` + `hosting_url` を渡す → done 画面の URL ブロックが点灯

### 認証モデル

- `POST .../provision-link` は Firebase auth 必須 (本人 or owner のみ)
- `GET .../by-token/:token` と `POST .../by-token/:token/status` は **token がそのまま身分証**。Firebase auth は不要 (Cloud Shell のスクリプトに Firebase 鍵を渡せないため)
- token は `crypto.randomBytes(24)` の base64url、24 時間 TTL、Firestore に保管
- token を持ってる人 = その run を見られる + status 更新できる、それだけ

## オプション + 月額試算 (Step 4)

「いきなり Cloud SQL 立ててお金かかる」が起きないよう、有料サービスは toggle 式で選択。選択に応じて月額が live 計算される。

| サービス | 月額目安 (asia-northeast1) | 必要なケース |
|---|---|---|
| Secret Manager / Artifact Registry / Hosting / Cloud Run (scale-to-zero) | ~¥80 (固定) | 常に必要 |
| Cloud SQL (Postgres db-f1-micro) | +¥1,700 | 経費・請求書・顧客リスト等の構造化データ保存 |
| Cloud Storage バケット | +¥0〜500 | 画像・PDF・領収書スキャン保管 |
| Cloud Run 常時 hot (min-instances=1) | +¥7,000 / サービス | コールドスタート無しにしたい場合 (個人用途では基本不要) |
| Gemini / Cloud Build / Hosting 通信 | 使った分 | 無料枠が広く、通常は無料内 |

価格データはフロント側 `COST_PLANS` に集約。新規サービス追加時はここ + バックエンドの `OPTION_KEYS` を更新。

「**Step 3 の回答に合わせた推奨セット**」ボタンで、`goal` から自動 toggle (例: 経費なら Cloud SQL + Storage を on)。ユーザーは上書きできる。

選択は submit と一緒に Firestore に保存 (`wizard_runs/{id}.options`)。将来の自動プロビジョン (Cloud Tasks chain) がこの flag を読んで `bootstrap.sh` の `HAS_DB` / `HAS_BUCKET` や Cloud Run の `min-instances` に反映する。

## 設問が重要な理由

Step 3 のアンケートは単なるセットアップ情報ではなく、**ユーザー側 GCP に書き込む `CLAUDE.md` と AI ヘルプの応答**に反映される。
- 初心者にはより噛み砕いた説明
- 経費アプリ志向ならその雛形を初期 deploy
- 業界に合わせた用語・例え話

## 設計詳細 (saas-draft-v1.md §3-2 / §4-2)

### フロントエンド (このディレクトリ)
- `/wizard/` の Web UI で 4 ステップのウォークスルー (実装済み)
- 状態は `localStorage` に永続化、リロード / タブ複数で復元可
- Firebase Auth Google サインイン
- 入力フォーム + 4 つの選択肢グループ
- 完了 → バックエンドへの POST (未実装) → 進捗表示 (未実装)

### バックエンド (`platform/apps/wizard/server/` 実装済 α)
- Express on Cloud Run (`wizard-api`)
- 認証: Firebase ID トークン検証 (任意の Google ユーザー、`ALLOWED_EMAILS` で絞れる)
- エンドポイント:
  - `POST /api/wizard/submit` — submit を Firestore `wizard_runs/{id}` に保存、`run_id` を返す
  - `GET /api/wizard/runs/:id` — 本人 or オーナーが状態取得
  - `GET /api/wizard/runs` — 自分の最近の run 一覧
  - `POST /api/wizard/runs/:id/events` — フロントから構造化ログを書き込む
  - `GET /api/wizard/runs/:id/events` — events 一覧 (詳細ログパネル用)
- 将来 Cloud Tasks chain で各 step を進める (現状は status=`manual_required` で止まる)
- Firestore SA は `wizard-run`、`roles/datastore.user` を `EXTRA_ROLES` で付与

### 構造化ログ (どのブロックで詰まったか即わかるよう全イベント記録)

- フロント / バックエンド両方が `wizard_runs/{id}/events` サブコレクションに書く
- 各 event: `{ at, actor, level (debug/info/warn/error), code, message, data }`
- フロントは追加で local array にもため、画面下の **「詳細ログ」パネル**で常時参照可
- パネルから:
  - **ログをコピー** — 共有 / 貼り付け用 (env / UA / run_id ヘッダ付き、トラブル相談で AI ヘルプに丸ごと貼れる)
  - **Cloud Logs** — backend (Cloud Run) の構造化ログを `jsonPayload.run_id="..."` で絞り込んだ Logs Explorer を開く
  - **Firestore** — その run のドキュメントを直接開く (オーナー用)
- バックエンドは `console.log(JSON.stringify({severity, run_id, code, ...}))` 形式で出力 → Cloud Logging 側で自動構造化される
- Google/GitHub 等の外部 API が仕様変更で動かなくなったとき、`code` (例: `auth.signin_failed`, `submit.failed`, `poll.error`) でどのブロックの何が死んだか一発切り分け

## バックエンドでやる予定の処理 (Cloud Tasks chain 単位)

1. **create-project** — GCP プロジェクト作成 + 請求アカウントとリンク
2. **enable-apis** — Cloud Run / Cloud SQL / Cloud Build / Hosting / Auth / Secret Manager / Gemini を一括有効化
3. **override-org-policy** — `iam.allowedPolicyMemberDomains` を `allowAll` に上書き (Workspace 配下のみ。個人 GCP なら skip)
4. **provision-shared** — Artifact Registry / Cloud SQL / 共有 Secret 作成
5. **fork-template** — GitHub Template から user のリポに fork
6. **create-trigger** — Cloud Build ↔ GitHub の OAuth 認可 (人間ステップ、ブラウザに誘導) + トリガ作成
7. **inject-claude-md** — アンケート結果を反映した `CLAUDE.md` を user のリポに書き込み
8. **initial-push** — main に空 commit push → 初回ビルド発火
9. **wait-deploy** — ビルド完了を polling、Hosting URL を確定
10. **finalize** — OAuth redirect URI + Firebase Auth authorized domain を user に手動追加してもらうステップ案内

## 技術的ボトルネック

| # | ボトルネック | 対処方針 |
|---|---|---|
| B1 | OAuth スコープ (`cloud-platform` の Google App 検証) | 検証審査を通す or 必要最小スコープに分割 |
| B2 | GitHub OAuth App 登録 | platform 側に GitHub OAuth App を登録 |
| B3 | 組織ポリシー (`iam.allowedPolicyMemberDomains`) | ユーザー種別判定 + `orgpolicy.policyAdmin` 要否を分岐 |
| B4 | Cloud Build ↔ GitHub 接続 (人間ステップ) | UI で「このボタン押して」と日本語誘導 |
| B6 | Firebase Auth プロバイダ有効化 | Identity Toolkit API + Firebase Management API で API 化 |

詳細は `docs/saas-draft-v1.md` §9 参照。

## ファイル構成 (現状)

```
wizard/
├── README.md           ← これ
├── index.html          ← UI + サインイン + フォーム + 実 API 呼び出し + 状態 polling
├── app.yaml            ← bootstrap.sh が読むメタデータ (EXTRA_ROLES: roles/datastore.user)
├── cloudbuild.yaml     ← Cloud Build 設定 (wizard-api build + deploy + hosting deploy)
└── server/             ← Cloud Run コード
    ├── package.json    ← express + firebase-admin + @google-cloud/firestore
    ├── Dockerfile
    ├── .dockerignore
    └── index.js        ← /api/wizard/submit, /api/wizard/runs[/:id]
```

## オーナーが 1 回やる必要のあるセットアップ

このサービスが動くには bootstrap.sh の再実行が必要 (初回 wizard 導入時):

```bash
bash platform/infra/bootstrap.sh   # firestore API 有効化 + Firestore DB 作成
                                    # wizard-run SA 作成 + roles/datastore.user 付与
                                    # wizard-api Cloud Build トリガ作成
```

bootstrap.sh は既存リソースに対しては冪等。新規追加分 (Firestore, wizard SA, wizard trigger) だけ作る。

## 残課題

- [x] バックエンド Cloud Run worker 実装 (`apps/wizard/server/`)
- [x] Firestore で submit 永続化
- [x] フロントエンドが実 API を叩いて状態 polling
- [x] 構造化ログ + 詳細ログパネル + Cloud Logs/Firestore 直リンク
- [x] GitHub OAuth 正式連携 (Step 2、未設定なら手入力 fallback)
- [x] Cloud Shell ハンドオフ (provision-link + wizard-bootstrap.sh) ← Phase 2
- [x] bootstrap.sh 完了コールバック → live 進捗表示 ← Phase 3
- [ ] Google OAuth `cloud-platform` スコープ取得 (Google App 検証通す)
- [ ] Cloud Tasks chain で各ステップを非同期実行 (途中失敗からの再開)
- [ ] 各ステップの実装 (create-project, enable-apis, provision-shared, fork-template, ...)
- [ ] 進捗バー UI (現状はステップ一覧表示のみ)
- [ ] アンケート結果を user 側 `CLAUDE.md` テンプレに焼き込む
- [ ] オーナー用 admin UI で待機中の run を一覧 / 手動 trigger

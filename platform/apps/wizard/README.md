# Setup Wizard (`/wizard/`)

エンドユーザーが自分の GCP プロジェクトに claude-studio 一式を立ち上げるための Setup Wizard。

> 現状 **α 実装**。UI フロー (Google サインイン・GitHub ユーザー名入力・スキル/業種アンケート・確認画面) は動く。
> バックエンド自動プロビジョン (GCP API 有効化・Cloud SQL・Cloud Build トリガ作成等) は未実装で、最後のステップで「実装中」表示。

## ユーザー側の作業を最小化する設計方針

ユーザーがやることは以下だけ:
1. **Google ログイン** (Firebase Auth)
2. **GitHub 連携** (現状はユーザー名手入力、後で正式 OAuth に置換)
3. **4 つの設問にクリック回答** (スキル / 作りたいもの / 業界 / チームサイズ)
4. **確認 → 開始ボタン**

これ以外は全部 wizard が裏でやる予定:
- GCP プロジェクト作成 / 請求紐付け
- API 一括有効化
- Cloud SQL / Storage / Service Account / Secret Manager
- GitHub Template から fork
- Cloud Build トリガ作成 + 初回デプロイ
- Firebase Auth プロバイダ有効化 + 認可ドメイン追加
- OAuth redirect URI 追加 (現状唯一の手動 GCP コンソール作業)

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

### バックエンド (未実装、`platform/apps/wizard/server/` 想定)
- Cloud Run worker が gcloud SDK or Cloud Client Libraries で操作
- Cloud Tasks chain で長時間処理をステップ分割 (回線切れ耐性)
- 各ステップの状態を Firestore に書く

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
└── index.html          ← UI + サインイン + フォーム + localStorage (バックエンド呼び出しは stub)
```

## 残課題

- [ ] GitHub OAuth 正式連携 (今はユーザー名手入力)
- [ ] バックエンド Cloud Run worker 実装 (`apps/wizard/server/`)
- [ ] Cloud Tasks chain で各ステップを非同期実行
- [ ] Firestore で進捗状態管理
- [ ] 進捗バー UI (バックエンド連動)
- [ ] エラーハンドリング (途中で失敗したら再開可能に)
- [ ] アンケート結果を `CLAUDE.md` テンプレに焼き込む
- [ ] OAuth redirect URI 追加の手動ステップを Identity Platform API で自動化

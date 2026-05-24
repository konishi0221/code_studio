# Setup Wizard (`/wizard/`)

各ユーザーが自分の GCP プロジェクトに claude-studio 一式を 5 分で立ち上げるための Setup Wizard。

> ⚠️ **現状 scaffold のみ**。UI の見た目だけ作ってあって、実際の OAuth・GCP プロビジョニング・GitHub 連携のロジックは未実装。
> 今は `platform/infra/bootstrap.sh` を Cloud Shell で手動実行する方法しかありません。

## 設計 (saas-draft-v1.md §3-2 / §4-2 参照)

### フロントエンド (このディレクトリ)

- `/wizard/` の Web UI で 5 ステップのウォークスルー
- OAuth フロー (Google Identity Platform、`cloud-platform` + `cloud-billing` スコープ + GitHub `repo`)
- 入力フォーム (プロジェクト名・リージョン・初期アプリ選択)
- 進捗バー (バックエンドの状態を Firestore でポーリング)
- 完了画面 (URL + 「Claude Code を開いて」案内)

### バックエンド (未実装、`platform/apps/wizard/server/` 想定)

- Cloud Run worker が gcloud SDK or Cloud Client Libraries で操作
- Cloud Tasks chain で長時間処理をステップ分割 (回線切れ耐性)
- 各ステップの状態を Firestore (or Cloud SQL) に書く

## やる予定の処理 (Cloud Tasks chain 単位)

1. **create-project** — GCP プロジェクト作成 + 請求アカウントとリンク
2. **enable-apis** — Cloud Run / Cloud SQL / Cloud Build / Hosting / Auth / Secret Manager / Gemini を一括有効化
3. **override-org-policy** — `iam.allowedPolicyMemberDomains` を `allowAll` に上書き (Workspace 配下のみ。個人 GCP なら skip)
4. **provision-shared** — Artifact Registry / Cloud SQL / 共有 Secret 作成
5. **fork-template** — GitHub Template から user のリポに fork
6. **prompt-github-connect** — Cloud Build ↔ GitHub の OAuth 認可 (人間ステップ、ブラウザに誘導)
7. **create-trigger** — Cloud Build トリガ作成
8. **initial-push** — main に空 commit push → 初回ビルド発火
9. **wait-deploy** — ビルド完了を polling、Hosting URL を確定
10. **finalize** — OAuth redirect URI + Firebase Auth authorized domain を user に手動追加してもらうステップ案内

## 技術的ボトルネック

| # | ボトルネック | 対処方針 |
|---|---|---|
| B1 | OAuth スコープ (`cloud-platform` の Google App 検証) | 検証審査を通す or 必要最小スコープに分割 |
| B4 | Cloud Build ↔ GitHub 接続 (人間ステップ) | UI で「このボタン押して」と日本語誘導 |
| B6 | Firebase Auth プロバイダ有効化 | Identity Toolkit API + Firebase Management API で API 化 |
| B3 | 組織ポリシー (`iam.allowedPolicyMemberDomains`) | ユーザー種別判定 + `orgpolicy.policyAdmin` 要否を分岐 |

詳細は `docs/saas-draft-v1.md` §9 参照。

## ファイル構成 (現状)

```
wizard/
├── README.md           ← これ
└── index.html          ← scaffold UI (機能なし)
```

## 残課題

- [ ] OAuth フロー実装 (Google Identity Platform)
- [ ] バックエンド Cloud Run worker 実装
- [ ] Cloud Tasks chain で各ステップを非同期実行
- [ ] Firestore で進捗状態管理
- [ ] フォーム入力 (プロジェクト名・リージョン)
- [ ] 進捗バー UI
- [ ] エラーハンドリング (途中で失敗したら再開可能に)
- [ ] GitHub 連携の人間ステップを最小化する UX

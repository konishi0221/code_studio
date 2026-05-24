# claude-studio platform

Claude Code で個人・小規模チーム向けのミニアプリを次々作るための GCP プラットフォーム本体。
`apps/<アプリID>/` を 1 ディレクトリ追加するだけで新しいアプリが立ち上がる。

`main` に push すれば Cloud Build トリガで自動デプロイ → `https://<HOSTING_SITE>.web.app` で公開。

> このディレクトリ (`platform/`) は claude-studio の運営側 Web 本体。
> 将来 wizard が各ユーザーの GCP に展開する「ユーザー向けテンプレ」は `template/` (リポ root の兄弟ディレクトリ、未着手)。
> 両者は同じ launcher / Cloud Run / Cloud SQL 構成を共有する設計だが、デプロイ先 GCP プロジェクトが別。

---

## 🛠 このプロジェクトについて

あなたの業務・趣味に役立つミニアプリをスマホで使えるようにする個人サンドボックス。`apps/help/` の AI ヘルプチャットを最初の起点として、必要なアプリを自分で増やしていきます。

インフラ・GCP 設定・デプロイ周りは、最初に `infra/bootstrap.sh` を実行したオーナー (あなた) が管理。

---

## 🤖 Claude Code への依頼の定型句

新しいミニアプリや修正を Claude Code に依頼するときは、最初に以下を伝える：

> **`README.md` と `DEPLOY.md` と `CLAUDE.md` を読んでから、〇〇を作って**

これで Claude Code がプロジェクト構成・デプロイ方法・コード規約を全部把握してから書いてくれる。

---

## 🚨 コードを書く前に必ず pull する

**最重要・例外なし**。コードを編集する前に、ローカルが remote の最新と一致しているか確認する。

```bash
git fetch origin main
git rev-list --left-right --count main...origin/main   # "0	0" を確認
git pull --ff-only origin main
```

詳細ルールは `CLAUDE.md` §0 参照。

---

## 📁 ミニアプリ構造 (ランチャー方式)

```
apps/                          ← Hosting 公開ルート
├── index.html                 ← ランチャー (アプリ選択 + 共通 Google ログイン) → /
├── config.js                  ← Cloud Run URL (ビルド時に自動注入)
├── help/                      ← AI ヘルプチャット → /help/
│   ├── index.html
│   ├── README.md
│   ├── server/                ← Cloud Run コード
│   ├── infra/                 ← schema.sql 等 (Hosting 配信から除外)
│   └── cloudbuild.yaml
└── <新アプリID>/
    ├── index.html
    └── README.md
```

### 新しいミニアプリの追加手順

1. `apps/<id>/index.html` と `apps/<id>/README.md` を作る (**1 アプリ＝1 ディレクトリ**)
2. ランチャー `apps/index.html` の `APPS` 配列に 1 行追加
3. main に push → 自動デプロイ → `https://<HOSTING_SITE>.web.app/<id>/` で公開

### ルール

- **共通ログイン**: ランチャーで Google ログイン → `localStorage` 永続化で全ミニアプリ共有
- **静的のみのアプリ**: `apps/<id>/index.html` 1 ファイルだけで完結
- **バックエンドが要るアプリ**: 専用 Cloud Run サービスを持てる (例: `help-api`)。サーバコードは `apps/<id>/server/` 配下に

---

## 💻 ミニアプリ実装レシピ

### A. 認証も API も要らないアプリ

`apps/<id>/index.html` を 1 ファイル書くだけ。

```html
<!DOCTYPE html>
<html lang="ja">
<head><meta charset="UTF-8"><title>マイアプリ</title></head>
<body>
  <h1>こんにちは</h1>
  <button onclick="alert('クリックされた')">ボタン</button>
</body>
</html>
```

最後にランチャー (`apps/index.html`) の `APPS` 配列に 1 行追加：

```js
{ id: "myapp", name: "マイアプリ", icon: "🎯", desc: "説明", path: "/myapp/" },
```

### B. ログインしてるユーザーのメールを取りたい

ランチャーで Firebase Auth が共通ログイン済み (localStorage 共有)。各ミニアプリでは取得し直し：

```html
<script type="module">
import { initializeApp } from "https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js";

const cfg = await fetch("/__/firebase/init.json").then(r => r.json());
cfg.authDomain = location.hostname;   // iOS Safari ITP 対策 (必須)
const auth = getAuth(initializeApp(cfg));

onAuthStateChanged(auth, (user) => {
  if (!user) { location.href = "/"; return; }
  document.body.textContent = "こんにちは " + user.email;
});
</script>
```

### C. バックエンド (Cloud Run) を認証付きで叩きたい

`<script src="/config.js"></script>` で `window.API_BASE_<APP_UPPERCASE>` が読まれる (Cloud Build が注入)。
Firebase ID トークンを Bearer ヘッダにつけて fetch。

```html
<script src="/config.js"></script>
<script type="module">
import { initializeApp } from "https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js";

const cfg = await fetch("/__/firebase/init.json").then(r => r.json());
cfg.authDomain = location.hostname;
const auth = getAuth(initializeApp(cfg));

onAuthStateChanged(auth, async (user) => {
  if (!user) { location.href = "/"; return; }
  const token = await user.getIdToken();
  const res = await fetch(window.API_BASE_MYAPP + "/api/something", {
    headers: { Authorization: "Bearer " + token }
  });
  console.log(await res.json());
});
</script>
```

---

## 🧰 使える GCP サービス (bootstrap 完了後)

| サービス | 用途 (例え話) | 状態 |
|---|---|---|
| **Firebase Auth** | 入口の受付係 (誰が来たか確認) | ✅ |
| **Firebase Hosting** | お店の看板・店内 (静的ファイル配信) | ✅ |
| **Cloud Run** | お店の厨房 (サーバ側プログラム実行) | ✅ |
| **Cloud SQL (Postgres)** | 帳簿棚 (行と列で整理されたデータ) | ✅ |
| **Cloud Storage** | 倉庫 (ファイル・画像保存) | ✅ |
| **Gemini API** | 文章を読んだり画像を見たりする AI | ✅ |
| **Secret Manager** | 金庫 (API キー等の保管) | ✅ |
| **Cloud Build** | 工場 (コードからデプロイ) | ✅ |
| **Artifact Registry** | 倉庫 (ビルド済みコンテナ) | ✅ |

---

## 🚀 デプロイ

> 構造の全詳細は **[DEPLOY.md](DEPLOY.md)** に集約。

### 仕組み

```
コード修正 → main に push → Cloud Build トリガ発火 → Docker build → Cloud Run 反映 → Hosting 反映
                                                                ↓
                                            ユーザーは https://<HOSTING_SITE>.web.app を開くだけ
```

main への push が Cloud Build をキックして本番デプロイされる。**`firebase deploy` を直接叩くのは禁止** (古い clone から打つと本番を巻き戻すため)。手動 deploy は `bash infra/deploy-hosting.sh` 経由。

---

## 📦 現在のアプリ

| ディレクトリ | サービス名 | 内容 | 状態 |
|---|---|---|---|
| `apps/help/` | `help-api` | AI ヘルプチャット (このシステムを知ってる Gemini) | 稼働中 ✅ |

---

## 🔗 詳細ドキュメント

- [CLAUDE.md](CLAUDE.md) — Claude Code 用ルール (`git fetch` 義務・push 手順・触っちゃダメリスト等)
- [DEPLOY.md](DEPLOY.md) — デプロイ構造の完全ドキュメント
- [apps/help/README.md](apps/help/README.md) — AI ヘルプの使い方

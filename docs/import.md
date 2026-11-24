# キットに載っていない店を取り込む

レンタルサーバーや VPS に EC-CUBE を直接入れて動いている店を、このキットへ移すための手順。
**同じ版のままキットへ移してから、`bin/upgrade.sh` で上げる**（一度に「移しながら上げる」をしない。
失敗したときに、引っ越しと版の違いのどちらが原因か分からなくなる）。

4 段ともコマンドがある。**本番の切り替えの前に、手元か検証の環境で 1〜3 をリハーサルする。**

| 段 | やること | コマンド |
|---|---|---|
| 1. 診断 | 元の店を読むだけで、何が要るかを報告書にする | `bin/import.sh fetch` / `diagnose` |
| 2. 取り込み | 同じ版のまま、まっさらなキット（手元か検証の環境）へ流し込む | `bin/import.sh fetch --full` / `load` |
| 3. 上げる | 検証の環境で `bin/upgrade.sh ~4.3 --php=8.3` | `bin/upgrade.sh` |
| 4. 切り替え | 本番のキットで、元の店をメンテナンスにし、データだけを取り直して入れる。DNS は人が向け替える | `bin/import.sh cutover` |

## 1. 診断

```bash
# SSH で入れるなら（元の店には読むだけ。商品画像と vendor は取らない）
bin/import.sh fetch shop@old.example.jp:/var/www/eccube
bin/import.sh diagnose var/import/old.example.jp

# SSH が無いなら、店から zip（EC-CUBE のフォルダ丸ごと）と DB のダンプを受け取って
bin/import.sh diagnose ~/受け取り/eccube --dump=~/受け取り/eccube.sql.gz
```

報告書は `var/import/<名前>/report/report.md`。見るもの:

| 項目 | どう調べるか |
|---|---|
| 本体を直接書き換えた箇所 | 同じ版のまっさらな EC-CUBE（GitHub のタグ）と比べる。差分は `core.patch` |
| `app/template` の写し | 元の版の本体・上げた先の本体・店の写しの 3 つを比べ、「消してよい」「そのまま運ぶ」「取り込みが要る」に分ける |
| プラグインと `app/Customize` | PHPStan（レベル 1）を元の版と上げた先の両方で流し、**上げた先でだけ出る誤り**を数える。加えて Symfony 6 で消えた書き方を名前で探す |
| テーマ | 使っているテーマと、コードを URL に直接書いている箇所。取り込みでは `bin/theme.sh` で `original` にする |
| ライブラリ | 本体の `composer.json` に足されたもの（`composer.extra.json` の下書き）。上げた先の本体と制約が合わないものも挙げる |
| DB | 種類と版、MySQL 8 専用の照合順序、トリガー、ダンプが最後まであるか |
| サーバー（fetch のとき） | OS・PHP・メモリ・空きディスク・Docker と root の有無（同じサーバーで移せるか）・cron |

**判定**は「標準（固定料金で受けられる見込み）」か「要見積り」。要見積りには理由が付く。
画面の動き・決済・メールは診断では分からないので、取り込んだあとの検証の環境で確かめる。

**取ってきたものには会員の個人情報が入る**（DB のダンプ）。`var/import/` は git に入らず、権限は自分だけに
絞ってある。終わったら消す（コマンドは消さない）。DB のパスワードは向こうで環境変数としてクライアントに渡し、
コマンドの引数には出さない。

## 2. 取り込み

**まっさらなキット**へ、同じ系列の版のまま流し込む。自分の店のコードが入ったキットに重ねない（どちらのものか分からなくなる）。

```bash
git clone https://github.com/kurozumi/eccube-kit.git myshop && cd myshop
bin/init.sh --no-start --image=ghcr.io/kurozumi/eccube-kit/ec-cube:4.2   # 元の店と同じ系列
docker compose up -d
bin/import.sh fetch shop@old.example.jp:/var/www/eccube --full           # 商品画像も取る
bin/import.sh load var/import/old.example.jp
```

`load` は元の店を**バックアップの形**（`backups/<日時>-import-<名前>/`）に詰め直し、`bin/restore.sh` で入れる。
戻す前の控え・メンテナンス表示・プラグインの組み立て直しは restore.sh のものがそのまま効く。

| もの | 行き先 |
|---|---|
| DB | キットの DB（MySQL のダンプは MariaDB が読めるように直す: MySQL 8 の照合順序・GTID・`USE`） |
| 商品画像・`app/PluginData` | 本体の画像のボリューム・本体のボリューム |
| `app/template`（本体と同じ写しは除く）・`html/user_data`・`app/Plugin` | 作業ツリー（`customize.css` はキットのもの＝テーマの `@import` の後ろに店の中身を足す） |
| 使っているテーマ | `bin/theme.sh install` で `original` へ（`.env` の `ECCUBE_TEMPLATE_CODE=original`） |
| `app/Customize`（店が書いたもの）・足されたライブラリ | 作業ツリーと `composer.extra.json`。キットに同じ名前のファイルがあれば止まる（`services.yaml` は店のものを使う） |
| `ECCUBE_AUTH_MAGIC`・管理画面の URL | `.env`（AUTH_MAGIC が違うと誰もログインできない） |

**運ばないもの:**

- **メールの送り先（`MAILER_DSN`）。** 検証の環境から本物のお客さんへメールが出ないように。手元なら Mailpit に届く。
  本番へ出すときに `.env` に書く。
- **本体を直接書き換えた箇所。** 診断の `core.patch` を見て `app/Customize` へ書き直す。
- 店が `app/DoctrineMigrations` に足した migration。名前空間と DB の記録を合わせる必要があるので、あれば止まる（手で移す）。

**決済は、検証で注文する前に、管理画面でテスト用の設定に切り替える。** 決済プラグインの設定は DB に入っていて、
本物の鍵のまま運ばれる。そのまま注文すると本当に請求する。

取り込んだら、画面・管理画面のログイン（元の店のパスワード）を確かめ、`git commit` してから
`bin/upgrade.sh ~4.3.0 --php=8.3` で上げる。上げた先で読めないプラグインがあれば、upgrade.sh が何も変えずに止まる。

## 3. 上げる（リハーサル）

取り込んだ環境で `bin/upgrade.sh ~4.3.0 --php=8.3`。止まったら、診断の報告書に従って直す:

- 買ったプラグインは**作者の 4.3 対応版**に入れ替える（`app/Plugin/<コード>` を差し替える）。無ければ作者に問い合わせる。
  **作者の許可かライセンスの裏付けなしに、買ったプラグインを直さない。**
- `app/Customize` の Symfony 6 で消えた書き方を直す。テンプレートの「取り込みが要る」を合わせる。
- 直したら `git commit`。上げ終わったら `bin/plugin.sh sync`（プラグインの版を DB に合わせる）。

**本番では、このリポジトリ（リハーサルで直したコード）をそのまま使う。** 本番のサーバーにこのリポジトリを置き、
`bin/init.sh --image=…:4.3` で 4.3 として立てて、`.env` に本物の `MAILER_DSN` を書いておく
（`docs/deploy.md`、紹介サイトの「本番サーバーを用意する」）。買ったプラグイン（git に入らない）は、
リハーサルの環境の `bin/backup.sh` の `admin-files.tar.gz` から `app/Plugin` を本番へ写す。

## 4. 切り替え

本番のキット（リハーサルで直したコードで、上げた先の版で動いているもの）で打つ:

```bash
bin/import.sh cutover shop@old.example.jp:/var/www/eccube --old-url=https://shop.example.jp/
```

1. 元の店から先に取っておく（まだ営業中。差分を小さくして、止める時間を短くする）
2. **元の店をメンテナンス表示にする**（`.maintenance`、または元の店の `ECCUBE_MAINTENANCE_FILE_PATH`）。
   `--old-url` を渡せば 503 になったかを確かめ、なっていなければ止める
3. 変わった分のファイルと DB を取り直す
4. このキットを控え（`backups/<日時>-before-cutover`）、アプリを止めて、**データだけ**を入れる: DB・画像・
   `app/PluginData`・ページ（`app/template/user_data`。DB の行と対）。コードはこのリポジトリのもの
5. `bin/upgrade.sh` をいまの版のまま流す（4.2 の DB をスキーマの更新と migration で 4.3 に合わせる。削除・名前の変更が
   混じれば止まり、失敗すれば自動で戻る）。`bin/plugin.sh sync`、`bin/healthcheck.sh`
6. 終わったら、DNS（Cloudflare）を新しいサーバーのトンネルへ向け替える。決済会社に新しい IP と通知の URL を登録し、
   元のサーバーの cron を止める（表示が出る）

**2 から 5 のどこかで失敗したら、元の店のメンテナンス表示を外して営業に戻す**（自分で置いたものだけ。店が先に入れていた
表示は残す）。このキットは途中の状態で残る（公開前）ので、表示に出る `bin/restore.sh backups/…-before-cutover` で戻す。
DNS を向け替えたあとに戻すと、新しいサーバーで受けた注文が元の店に無い。戻すなら向け替える前に決める。

元の店の管理画面で直せるファイル（ブロック・メール・CSS）は運ばない。リハーサルのあとに元の店で直されていて、
このリポジトリのものと違えば、終わったときに挙げる。

### 分かっていること

- PHPStan はレベル 1。クラスの宣言が合わない（4.3 で `AbstractPluginManager` の引数の型が変わった、など）は
  拾うが、メソッドが消えたことは拾わない。それを補うのが名前での検索で、こちらは決まった型しか見ない。
  **「誤り 0」は「動く」ではない**。
- オーナーズストアで買ったものか自作かは、ファイルからは分からない。報告書は店に聞く項目にする。

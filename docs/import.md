# キットに載っていない店を取り込む

レンタルサーバーや VPS に EC-CUBE を直接入れて動いている店を、このキットへ移すための手順。
**同じ版のままキットへ移してから、`bin/upgrade.sh` で上げる**（一度に「移しながら上げる」をしない。
失敗したときに、引っ越しと版の違いのどちらが原因か分からなくなる）。

4 段ともコマンドがある。**本番の切り替えの前に、手元か検証の環境で 1〜3 をリハーサルする。**

| 段 | やること | コマンド |
|---|---|---|
| 1. 診断 | 元の店を読むだけで、何が要るかを報告書にする | `bin/import.sh fetch`（SSH）か `unpack`（FTP）/ `diagnose` |
| 2. 取り込み | 同じ版のまま、まっさらなキット（手元か検証の環境）へ流し込む | `bin/import.sh fetch --full`（SSH）か `unpack`（FTP）/ `load` |
| 3. 上げる | 検証の環境で `bin/upgrade.sh ~4.3 --php=8.3` | `bin/upgrade.sh` |
| 4. 切り替え | 本番のキットで、元の店をメンテナンスにし、データだけを取り直して入れる。DNS は人が向け替える | `bin/import.sh cutover`（SSH）か `cutover --from=`（FTP） |

元の店に SSH で入れるか（`fetch`）、入れないか（`unpack`。下の「SSH が使えないレンタルサーバー」）で、取り方だけが違う。
取ったものは同じ形（`var/import/<名前>/` の `files/`・`dump.sql.gz`・`meta.env`）になり、`diagnose` と `load` はどちらも同じ。

## 1. 診断

```bash
# SSH で入れるなら（元の店には読むだけ。商品画像と vendor は取らない）
bin/import.sh fetch shop@old.example.jp:/var/www/eccube
bin/import.sh diagnose var/import/old.example.jp

# SSH が無いなら、FTP で落としたフォルダ（か zip）と、phpMyAdmin などで取った DB のダンプを整えてから
bin/import.sh unpack ~/受け取り/public_html --dump=~/受け取り/eccube.sql --name=myshop
bin/import.sh diagnose var/import/myshop
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
| 店が `app/DoctrineMigrations` に足した migration | 作業ツリーの `app/DoctrineMigrations`。名前空間を `CustomizeMigrations` にし、DB の記録（`doctrine_migration_versions`）の名前も同じに書き換える（下） |

**運ばないもの:**

- **メールの送り先（`MAILER_DSN`）。** 検証の環境から本物のお客さんへメールが出ないように。手元なら Mailpit に届く。
  本番へ出すときに `.env` に書く。
- **本体を直接書き換えた箇所。** 診断の `core.patch` を見て `app/Customize` へ書き直す。

**店の migration は名前空間を変えて運ぶ。** 元の店は本体の migration と同じ `app/DoctrineMigrations`（名前空間
`DoctrineMigrations`）に置いているが、キットでは独自 migration を `CustomizeMigrations` で持つ（本体のものを覆い隠さない
ため。`docs/customize.md`「migration を作る」）。DB は当たった migration を「名前空間\クラス名」で覚えているので、
ファイルだけ移すと**当たっているものを別の migration とみなしてもう一度流す**（列の追加なら「もうある」で落ちる）。
`load` はファイルの名前空間とダンプの記録の両方を書き換える。元の店でまだ当たっていないものは、次の起動か
`upgrade.sh` で流れる。止まるのは、PHP でないファイル・名前空間やクラス名の形が違うもの・ほかの migration を名前で
使うもの・キットに同じ名前で中身の違うものがあるとき（手で移す）。`cutover` も、取り直した DB の記録を同じように
書き換える。リハーサルのあとで元の店に足された migration は、終わったときに挙げる。

**決済は、検証で注文する前に、管理画面でテスト用の設定に切り替える。** 決済プラグインの設定は DB に入っていて、
本物の鍵のまま運ばれる。そのまま注文すると本当に請求する。

取り込んだら、画面・管理画面のログイン（元の店のパスワード）を確かめ、`git commit` してから
`bin/upgrade.sh ~4.3.0 --php=8.3` で上げる。上げた先で読めないプラグインがあれば、upgrade.sh が何も変えずに止まる。

### SSH が使えないレンタルサーバー

ロリポップ・さくらのレンタルサーバ・エックスサーバーなどの共用サーバーで、SSH が無い・使い方が分からない店は、
FTP とサーバーの管理画面で取って、`bin/import.sh unpack` で整える。

1. **ファイル**: FTP ソフトで、EC-CUBE のフォルダ（`src/` と `.env` がある場所。`public_html` の下のことが多い）を
   丸ごと落とす。`vendor` も落ちてくるが、`unpack` が捨てる。**点で始まるファイル（`.env`）を隠す FTP ソフトがある**
   （FileZilla は「サーバー → 隠しファイルを強制表示」）。`.env` が無いと `unpack` は止まる（全パスワードの鍵
   `ECCUBE_AUTH_MAGIC` と DB の接続先が入っている）。サーバーの管理画面のファイルマネージャーで zip に固めて落としても
   よい（zip / tar.gz をそのまま渡せる）
2. **DB**: サーバーの管理画面のバックアップ機能（mysqldump の形で出るものが多い）か、phpMyAdmin の「エクスポート」
   （既定のまま、形式は SQL）。`.sql`・`.sql.gz`・それを 1 つ入れた `.zip` のどれでもよい

```bash
bin/import.sh unpack ~/受け取り/public_html --dump=~/受け取り/eccube.sql --name=myshop
```

`unpack` がやること:

- フォルダ（か書庫）から EC-CUBE の場所を探し（`src/Eccube/Common/Constant.php`）、`vendor`・`var`・キャッシュを
  除いて写す。書庫は使い捨てのコンテナの中で開き、外へ書き出そうとする名前（`../`）やリンクがあれば入れない
- **phpMyAdmin のダンプは、使い捨ての DB（MySQL 8 か MariaDB 10.11。ダンプの見出しの版で選ぶ）に一度入れて、
  mysqldump で取り直す。** phpMyAdmin の書き出しには「最後まで書いた」の印が無く、`CREATE TABLE` の前に `DROP` も
  無いので、そのままでは `bin/restore.sh` が受け付けない。入れて取り直すことで、入りきるか・EC-CUBE の表が
  そろっているか（一部の表だけを選んで書き出していないか）も確かめる。元の DB の版は `meta.env` に残し、報告書に出す
- **途中で切れたダンプは止める。** レンタルサーバーの phpMyAdmin は大きい DB で時間切れになり、途中までのファイルを
  正常に渡してくる。最後に `COMMIT` も文字コードの戻しも無ければ止める（そのときはサーバーのバックアップ機能か、
  gzip 圧縮で書き出し直す）

取り込み（`load`）には商品画像（`html/upload`）が要る。FTP で丸ごと落としていれば入っている。
サーバーの様子（PHP・メモリ・cron）は分からないので、報告書は cron を店に聞く項目にする（管理画面の「cron 設定」）。

## 3. 上げる（リハーサル）

取り込んだ環境で `bin/upgrade.sh ~4.3.0 --php=8.3`。止まったら、診断の報告書に従って直す:

- 買ったプラグインは**作者の 4.3 対応版**に入れ替える（`app/Plugin/<コード>` を差し替える）。無ければ作者に問い合わせる。
  **作者の許可かライセンスの裏付けなしに、買ったプラグインを直さない。**
- `app/Customize` の Symfony 6 で消えた書き方を直す。テンプレートの「取り込みが要る」を合わせる。
- 直したら `git commit`。上げ終わったら `bin/plugin.sh sync`（プラグインの版を DB に合わせる）。

**本番では、このリポジトリ（リハーサルで直したコード）をそのまま使う。** 本番のサーバーにこのリポジトリを置き、
`bin/init.sh --image=…:4.3` で 4.3 として立てて、`.env` に本物の `MAILER_DSN` を書いておく
（`docs/deploy.md`、紹介サイトの「本番サーバーを用意する」）。

**プラグインは git に入らない**（`app/Plugin/*` は追跡しない。買ったものは作者のもの）ので、clone しただけの本番には無い。
リハーサルの環境で固めて、本番で広げる:

```bash
bin/import.sh plugins pack                                    # リハーサルの環境で。var/import/plugins-<日時>.tar.gz
scp var/import/plugins-*.tar.gz <本番>:<キット>/var/import/
bin/import.sh plugins add var/import/plugins-<日時>.tar.gz     # 本番のキットで
```

- `pack` は `app/Plugin` のプラグインを全部、`.git` を除いて固める（remote は中の `plugins.txt` に控える）。
  リハーサルで差し替えた作者の対応版・直したものが、そのまま運ばれる
- `add` は書庫を使い捨てのコンテナで開き、外へ書き出そうとする名前（`../`）・シンボリックリンク・
  `<コード>/composer.json` の形でないものがあれば入れない。本番に**中身の違う同じコードのもの**があれば、何も入れずに止まる
  （同じ中身なら飛ばす）。**ファイルを置くだけ**で、DB には触らない（切り替えが元の店の DB を入れ、`bin/plugin.sh sync` が版を合わせる）
- `backup.sh` の `admin-files.tar.gz` を本番で広げない。`app/template`・`html/user_data` も入っていて、本番のものを上書きする

## 4. 切り替え

本番のキット（リハーサルで直したコードで、上げた先の版で動いているもの）で打つ:

```bash
bin/import.sh cutover shop@old.example.jp:/var/www/eccube --old-url=https://shop.example.jp/
```

1. 元の店から先に取っておく（まだ営業中。差分を小さくして、止める時間を短くする）。**元の店の DB で有効なプラグインが
   このキットの `app/Plugin` に無ければ、ここで止まる**（DB は「有効」と言うのにファイルが無いと画面が落ちる。上の
   `plugins pack` / `add` で運ぶ）。版が違うものは確認の表示に出し、5 の `plugin.sh sync` が更新する
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

**リハーサルで外した・別のものに替えたプラグイン**は、元の店の DB ではまだ有効なので、1 で止まる。元の店の管理画面で
無効にしてから打つ（無効のまま残るものは運ばない。画面には響かない）。逆に**リハーサルで足したプラグイン**は元の店の
DB に無いので、切り替えのあとで `bin/plugin.sh install <コード>` で入れる（確認の表示と、終わったときの表示に出る）。
DNS を向け替えたあとに戻すと、新しいサーバーで受けた注文が元の店に無い。戻すなら向け替える前に決める。

**SSH が使えない店**は、元の店を止めるのと取り直すのを人がやり、整えたものを渡す:

1. 元の店の管理画面で「コンテンツ管理 → メンテナンス管理」を有効にする。**ここからお客さんは注文できない。**
   有効にした人のブラウザは素通りするので、止まったかは別の端末（スマホの回線など）で見る
2. **そのあとで**、FTP でファイルを落とし直し（FTP ソフトの「同期」なら変わった分だけ）、DB を書き出し直して、
   同じ名前で `unpack` する（前の報告書は残る）
3. 本番のキットで:

```bash
bin/import.sh cutover --from=var/import/myshop --old-url=https://shop.example.jp/
```

`--old-url` は必須で、元の店が 503 でなければ**何も変えずに止まる**。これを使って、**元の店を止める前に一度打っておく**と、
プラグインがそろっているか・版が変わるものまで確かめてから、503 でないところで止まる（リハーサルのときに整えたもので打てばよい）。取ったのがメンテナンスにする前か後かは
コマンドからは分からないので、確認の表示で念を押す（前に取ったものだと、そのあとの注文と会員登録が消える）。
整えてから 2 時間を超えていれば注意を出す。そこから先（控え → データだけ入れる → `upgrade.sh` → `plugin.sh sync`
→ 疎通）は SSH のときと同じ。**失敗したときにメンテナンス表示を外すのは人**（コマンドは元の店に触れない）。

**合わせる先は、いま動いている版の系列。** 配布イメージの環境では `.env` の `ECCUBE_VERSION` が使われず、動いている版と
ずれていることがあるので、そこからは取らない（試験で、4.2 で動いているキットを切り替えのついでに 4.3 へ上げようとした）。
手元で build する環境は `ECCUBE_VERSION` を使い、系列が動いている版と違えば、元の店を止める前に止まる。

元の店の管理画面で直せるファイル（ブロック・メール・CSS）は運ばない。リハーサルのあとに元の店で直されていて、
このリポジトリのものと違えば、終わったときに挙げる。

### 分かっていること

- 確かめたのは手元の試験（4.2.3-p2・MySQL 8 の店、phpMyAdmin 5.2 の日本語の画面で書き出したもの）まで。本物の
  レンタルサーバーの管理画面のバックアップ機能の形（会社ごとに違う）は、1 店目で確かめる。mysqldump・phpMyAdmin
  以外の形（Adminer など）は、いまは受け付けない

- PHPStan はレベル 1。クラスの宣言が合わない（4.3 で `AbstractPluginManager` の引数の型が変わった、など）は
  拾うが、メソッドが消えたことは拾わない。それを補うのが名前での検索で、こちらは決まった型しか見ない。
  **「誤り 0」は「動く」ではない**。
- オーナーズストアで買ったものか自作かは、ファイルからは分からない。報告書は店に聞く項目にする。

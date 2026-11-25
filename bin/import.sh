#!/usr/bin/env bash
# キットに載っていない EC-CUBE の店を、キットへ取り込む前に調べる。**元の店には何も書かない。**
#
#   bin/import.sh fetch <ユーザー>@<ホスト>:<EC-CUBE のフォルダ> [--name=<名前>]
#       元のサーバーから、診断に要るファイルと DB のダンプを SSH で取ってくる（読むだけ）。
#       置き場は var/import/<名前>/。商品画像（html/upload）と vendor は取らない（数と大きさだけ数える）。
#   bin/import.sh unpack <フォルダ | zip | tar.gz> --dump=<.sql | .sql.gz | .zip> [--name=<名前>]
#       SSH が使えないレンタルサーバー向け。FTP で落としたフォルダ（または管理画面で固めた zip）と、サーバーの管理画面
#       （phpMyAdmin・Adminer・バックアップ機能）で取った DB のダンプを、fetch で取ったのと同じ形（var/import/<名前>/）に整える。
#       phpMyAdmin・Adminer のダンプは、使い捨ての DB に一度入れて mysqldump で取り直す（入りきるか・表がそろっているかを確かめる）。
#       以降の diagnose / load はそのまま使える。
#   bin/import.sh diagnose <店のフォルダ> [--dump=<ダンプ>] [--to=4.3]
#       取ってきたもの（または店から受け取った zip を展開したフォルダ）を調べ、報告書を作る。
#       fetch で取ったフォルダなら、ダンプは自動で使う。
#
#   bin/import.sh fetch <ユーザー>@<ホスト>:<フォルダ> --full
#       取り込み用。商品画像も取る（2 回目からは変わった分だけ）。
#   bin/import.sh load <fetch --full で取ったフォルダ | 店のフォルダ> [--dump=<ダンプ>]
#       **まっさらなキット**（clone → bin/init.sh --image=…:<元の店の系列> → docker compose up -d）へ、同じ版のまま
#       流し込む。元の店をバックアップの形（backups/<日時>-import-<名前>/）に詰め直し、bin/restore.sh で入れる。
#       ECCUBE_AUTH_MAGIC・管理画面の URL・テーマは引き継ぎ、メールの送り先は引き継がない（検証から本物のお客さんへ
#       メールが出ないように）。本体を直接書き換えた箇所は運ばない（diagnose の core.patch を見て app/Customize へ）。
#   bin/import.sh plugins pack
#       リハーサルの環境で。git に入らない app/Plugin のプラグインを .git 抜きで固める（var/import/plugins-<日時>.tar.gz）。
#   bin/import.sh plugins add <書庫>
#       本番のキットで。上の書庫を確かめて app/Plugin に置く（置くだけ。DB は cutover が元の店のものを入れる）。
#   bin/import.sh cutover <ユーザー>@<ホスト>:<フォルダ> [--old-url=https://元の店/]
#       本番の切り替え。**リハーサル（load → 直す → upgrade）を済ませ、そのリポジトリで動いている本番のキット**で打つ。
#       元の店をメンテナンス表示にし、変わった分と DB を取り直し、データだけ（DB・画像・PluginData・ページ）を入れて
#       bin/upgrade.sh でこのキットの版に合わせる。コードはこのリポジトリのものを使う。
#       元の店の DB で有効なプラグインが app/Plugin に無ければ、元の店を止める前に止まる（plugins pack / add で運ぶ）。
#       **途中で失敗したら、元の店のメンテナンス表示を外して営業に戻す。** DNS の向け替えは人がやる。
#   bin/import.sh cutover --from=var/import/<名前> --old-url=https://元の店/
#       SSH が使えない店の切り替え。人が元の店の管理画面でメンテナンス表示にし、ファイルと DB を取り直して unpack した
#       あとで打つ。元の店が本当にメンテナンス画面（503）かを確かめてから流し込む。失敗したら、表示を外すのは人。
#
# 診断で見るもの（報告書は var/import/<名前>/report/report.md）:
#   - 本体を直接書き換えた箇所（同じ版のまっさらな EC-CUBE と比べる。差分は core.patch）
#   - app/template の写しのうち、上げた先の本体が変えたもの（3 つを比べる）
#   - プラグインと app/Customize が上げた先で読めるか（PHPStan を両方の版で流し、上げた先でだけ出る誤りを数える）
#   - 使っているテーマ、足されたライブラリ（composer.extra.json の下書き）、店が足した migration（load が名前空間と DB の記録を合わせて運ぶ）
#   - DB の種類と版、MySQL 8 専用の照合順序、トリガー、ダンプが最後まであるか
#   - 判定（標準の手順で進められるか）と、店に確かめることの一覧
#
# 取ってきたものには会員の個人情報（DB のダンプ）が入る。var/import/ は git に入らない。
# 終わったら消すこと（bin/import.sh は消さない）。
set -euo pipefail
case "${1:-}" in -h|--help|"") awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
cd "$(dirname "$0")/.."

# shellcheck source=lib/guard.sh
. "$(dirname "$0")/lib/guard.sh"
# shellcheck source=lib/image.sh
. "$(dirname "$0")/lib/image.sh"
# shellcheck source=lib/compose.sh
. "$(dirname "$0")/lib/compose.sh"

log() { echo "[import] $*"; }
die() { echo "[import] エラー: $*" >&2; exit 1; }

IMAGE_BASE="${IMPORT_IMAGE_BASE:-ghcr.io/kurozumi/eccube-kit/ec-cube}"
PHPSTAN_VER=1.12.12
PHPSTAN_SHA=80cf561a258720de8935b232d2cb0110ccbb1e4d0a8593c795a402e0b3357325
cache=var/import/cache

if command -v sha256sum >/dev/null 2>&1; then sha_cmd="sha256sum"; else sha_cmd="shasum -a 256"; fi

need_image() { # need_image <参照>  … 手元に無ければ取る
    docker image inspect "$1" >/dev/null 2>&1 && return 0
    log "イメージを取得します: $1"
    docker pull -q "$1" >/dev/null || return 1
}

# 同じ版のまっさらな EC-CUBE（GitHub のタグ）を手元に置く。出力: そのパス
get_pristine() { # get_pristine <版>
    local ver="$1" dir="${cache}/ec-cube-${1}" tmp
    mkdir -p "$cache"
    if [ ! -d "$dir" ]; then
        log "まっさらな EC-CUBE ${ver} を取ってきます..." >&2
        tmp="$(mktemp -d)"
        curl -fsSL "https://codeload.github.com/EC-CUBE/ec-cube/tar.gz/refs/tags/${ver}" | tar -xzf - -C "$tmp" \
            || { rm -rf "$tmp"; die "EC-CUBE ${ver} のソースを取れませんでした（GitHub にその版のタグがあるか確かめてください）"; }
        mv "$tmp"/ec-cube-* "$dir"; rm -rf "$tmp"
    fi
    (cd "$dir" && pwd)
}

# 渡されたフォルダを読む。fetch で取ったフォルダ（files/ と dump.sql.gz・meta.env）でも、店から受け取ったフォルダでもよい。
# 決めるもの: src_base（EC-CUBE のフォルダ）・src_dump・src_meta・src_ver・src_series
resolve_src() { # resolve_src <フォルダ> <--dump の値>
    local src="$1"
    [ -d "$src" ] || die "フォルダがありません: $src"
    src_base="$src"; src_dump="$2"; src_meta=""
    if [ -d "$src/files" ] && [ -f "$src/files/src/Eccube/Common/Constant.php" ]; then
        src_base="$src/files"
        [ -n "$src_dump" ] || { [ -f "$src/dump.sql.gz" ] && src_dump="$src/dump.sql.gz"; }
        [ -f "$src/meta.env" ] && src_meta="$src/meta.env"
    fi
    [ -f "$src_base/src/Eccube/Common/Constant.php" ] || die "EC-CUBE 4 のフォルダではありません（src/Eccube/Common/Constant.php が無い）: $src_base"
    src_base="$(cd "$src_base" && pwd)"
    [ -z "$src_dump" ] || [ -f "$src_dump" ] || die "ダンプがありません: $src_dump"
    [ -z "$src_dump" ] || src_dump="$(cd "$(dirname "$src_dump")" && pwd)/$(basename "$src_dump")"
    src_ver="$(sed -nE "s/.*const VERSION = '([^']+)'.*/\1/p" "$src_base/src/Eccube/Common/Constant.php" | head -1)"
    [ -n "$src_ver" ] || die "EC-CUBE の版を読めませんでした"
    src_series="$(printf '%s' "$src_ver" | cut -d. -f1-2)"
}

# ---------------------------------------------------------------- fetch
cmd_fetch() {
    local src="" name="" full=0
    for a in "$@"; do
        case "$a" in
            --name=*) name="${a#--name=}" ;;
            --full) full=1 ;;
            -*) die "知らない指定です: $a" ;;
            *) src="$a" ;;
        esac
    done
    case "$src" in *@*:/*|*:/*) ;; *) die "使い方: bin/import.sh fetch <ユーザー>@<ホスト>:<EC-CUBE のフォルダ（絶対パス）>" ;; esac
    local host="${src%%:*}" path="${src#*:}"
    path="${path%/}"
    [ -n "$name" ] || name="$(printf '%s' "${host#*@}" | tr -c 'A-Za-z0-9._-' '_')"
    command -v rsync >/dev/null 2>&1 || die "rsync がありません（macOS は最初から入っています。Ubuntu は sudo apt install rsync）"
    local dest="var/import/${name}"
    mkdir -p "${dest}/files"
    chmod 700 var/import "$dest" 2>/dev/null || true

    log "${host} の ${path} を確かめます..."
    # shellcheck disable=SC2029  # path はこちらで展開してから渡す
    ssh -n -o BatchMode=yes "$host" "test -f '${path}/src/Eccube/Common/Constant.php'" \
        || die "${host}:${path} に EC-CUBE 4 が見つかりません（SSH の鍵で入れるか、フォルダが正しいか確かめてください）"
    ssh -n -o BatchMode=yes "$host" "command -v rsync >/dev/null" || die "${host} に rsync がありません。FTP で落として bin/import.sh unpack で整えてください"

    # --full は取り込み（load）用。商品画像も取る。2 回目からは変わった分だけ
    local ex_upload=(--exclude='/html/upload/')
    if [ "$full" = 1 ]; then
        ex_upload=(--exclude='/html/upload/temp_image/')
        log "ファイルを取ってきます（商品画像を含む。vendor・キャッシュは除く）..."
    else
        log "ファイルを取ってきます（商品画像・vendor・キャッシュは除く）..."
    fi
    rsync -az --delete \
        --exclude='/vendor/' --exclude='/var/' --exclude='/node_modules/' "${ex_upload[@]}" \
        --exclude='/app/proxy/' --exclude='.git/' \
        "${host}:${path}/" "${dest}/files/"
    # 向こうのフォルダの権限がそのまま来る（1777 のこともある）。.env の鍵が入っているので絞る
    chmod 700 "${dest}/files"

    log "サーバーの様子を控えます（PHP の版・画像の数・cron）..."
    # shellcheck disable=SC2029
    ssh -n -o BatchMode=yes "$host" "cd '${path}' && {
        echo \"php=\$(php -r 'echo PHP_VERSION;' 2>/dev/null)\"
        echo \"upload_files=\$(find html/upload -type f 2>/dev/null | wc -l | tr -d ' ')\"
        echo \"upload_kb=\$(du -sk html/upload 2>/dev/null | cut -f1)\"
        echo \"os=\$(. /etc/os-release 2>/dev/null && echo \"\$PRETTY_NAME\")\"
        echo \"mem_mb=\$(awk '/MemTotal/ {print int(\$2/1024)}' /proc/meminfo 2>/dev/null)\"
        echo \"disk_free_kb=\$(df -Pk . 2>/dev/null | awk 'NR==2 {print \$4}')\"
        echo \"docker=\$(command -v docker >/dev/null && echo yes || echo no)\"
        echo \"root=\$(sudo -n true 2>/dev/null && echo yes || echo no)\"
        crontab -l 2>/dev/null | grep -v '^#' | grep -E 'console|eccube|php' | sed 's/^/cron=/' || true
    }" > "${dest}/meta.env" || log "注意: サーバーの様子を一部読めませんでした"
    chmod 600 "${dest}/meta.env"

    log "DB をダンプします（元の DB には読むだけ）..."
    # 接続先は店の .env の DATABASE_URL。パスワードはコマンドの引数に出さない（ps で見えるため）。
    # 向こうで解いて、環境変数でクライアントへ渡す
    local url
    url="$(sed -n 's/^DATABASE_URL=//p' "${dest}/files/.env" 2>/dev/null | tail -1 | tr -d "\"'\r")"
    [ -n "$url" ] || die ".env に DATABASE_URL がありません。DB のダンプは店から受け取って --dump= で渡してください"
    # shellcheck disable=SC2029
    if ssh -n -o BatchMode=yes "$host" "URL='${url}' php -r '
        \$u = parse_url(getenv(\"URL\"));
        \$q = []; parse_str(\$u[\"query\"] ?? \"\", \$q);
        \$db = ltrim(\$u[\"path\"] ?? \"\", \"/\");
        \$user = urldecode(\$u[\"user\"] ?? \"\"); \$pass = urldecode(\$u[\"pass\"] ?? \"\");
        \$host = \$u[\"host\"] ?? \"localhost\"; \$port = \$u[\"port\"] ?? \"\";
        if (str_starts_with(\$u[\"scheme\"], \"mysql\")) {
            putenv(\"MYSQL_PWD=\$pass\");
            \$cmd = sprintf(\"mysqldump --single-transaction --quick --no-tablespaces --routines --triggers -h %s %s -u %s %s\", escapeshellarg(\$host), \$port ? \"-P \".escapeshellarg(\$port) : \"\", escapeshellarg(\$user), escapeshellarg(\$db));
        } elseif (str_starts_with(\$u[\"scheme\"], \"pgsql\") || str_starts_with(\$u[\"scheme\"], \"postgres\")) {
            putenv(\"PGPASSWORD=\$pass\");
            \$cmd = sprintf(\"pg_dump --no-owner -h %s %s -U %s %s\", escapeshellarg(\$host), \$port ? \"-p \".escapeshellarg(\$port) : \"\", escapeshellarg(\$user), escapeshellarg(\$db));
        } else { fwrite(STDERR, \"DB の種類が分かりません\n\"); exit(2); }
        passthru(\$cmd . \" | gzip -c\", \$rc); exit(\$rc);
    '" > "${dest}/dump.sql.gz.part"; then
        mv "${dest}/dump.sql.gz.part" "${dest}/dump.sql.gz"
        chmod 600 "${dest}/dump.sql.gz"
        log "DB のダンプ: ${dest}/dump.sql.gz（$(du -h "${dest}/dump.sql.gz" | cut -f1)）"
    else
        rm -f "${dest}/dump.sql.gz.part"
        log "注意: DB をダンプできませんでした（向こうに mysqldump / pg_dump が無い、など）。サーバーの管理画面（phpMyAdmin・Adminer など）で取り、bin/import.sh unpack ${dest}/files --dump=<ファイル> で整えてください"
    fi
    echo
    log "取ってきました: ${dest}"
    log "次: bin/import.sh diagnose ${dest}"
}

# ---------------------------------------------------------------- unpack
# 店から受け取ったフォルダ・書庫を、fetch と同じ形（files/・dump.sql.gz・meta.env）に整える。
# 書庫は他人が作ったものなので、使い捨てのコンテナの中で開き、外へ書き出そうとする名前・リンクがあれば入れない
unpack_files() { # unpack_files <フォルダ | 書庫> <置き場>
    local in="$1" to="$2" abs kind mount
    if [ -d "$in" ]; then
        kind=dir; abs="$(cd "$in" && pwd)"; mount="${abs}:/in/dir:ro"
    else
        [ -f "$in" ] || die "ありません: $in"
        abs="$(cd "$(dirname "$in")" && pwd)/$(basename "$in")"; mount="${abs}:/in/pkg:ro"
        case "$in" in
            *.zip) kind=zip ;;
            *.tar.gz|*.tgz) kind=tgz ;;
            *.tar) kind=tar ;;
            *) die "フォルダか、zip / tar.gz / tar を渡してください: $in" ;;
        esac
    fi
    mkdir -p "$to"
    local err; err="$(mktemp)"
    if ! docker run --rm --network none -v "$mount" alpine:3 sh -c '
        set -e
        if [ "$1" = dir ]; then cd /in/dir; else
            mkdir -p /w && cd /w
            # busybox の unzip / tar は ../ や先頭の / を黙って削って続ける（標準エラーに 1 行出すだけ）
            case "$1" in
                zip) names="$(unzip -l /in/pkg 2>&1 || true)" ;;
                tgz) names="$(tar -tzf /in/pkg 2>&1 || true)" ;;
                tar) names="$(tar -tf /in/pkg 2>&1 || true)" ;;
            esac
            if printf "%s\n" "$names" | grep -qE "removing leading|(^/|(^|/)\.\.(/|$))"; then echo BADNAME >&2; exit 5; fi
            case "$1" in
                zip) unzip -q /in/pkg ;;
                tgz) tar -xzf /in/pkg ;;
                tar) tar -xf /in/pkg ;;
            esac
        fi
        roots="$(find . -maxdepth 7 -path "*/src/Eccube/Common/Constant.php" ! -path "*/__MACOSX/*" ! -path "*/vendor/*" | sed "s#/src/Eccube/Common/Constant.php\$##")"
        [ -n "$roots" ] || { echo NOROOT >&2; exit 3; }
        [ "$(printf "%s\n" "$roots" | wc -l)" = 1 ] || { echo "MULTI $(printf "%s\n" "$roots" | tr "\n" " ")" >&2; exit 3; }
        cd "$roots"
        set -f   # 下の ._* をファイル名として展開させない
        ex="--exclude=./vendor --exclude=./var --exclude=./node_modules --exclude=./app/proxy --exclude=./html/upload/temp_image --exclude=.git --exclude=__MACOSX --exclude=._* --exclude=.DS_Store"
        # shellcheck disable=SC2086
        if [ -n "$(find . \( -path ./vendor -o -path ./var -o -path ./node_modules \) -prune -o -type l -print | head -1)" ]; then
            echo "SYMLINK $(find . \( -path ./vendor -o -path ./var -o -path ./node_modules \) -prune -o -type l -print | head -3 | tr "\n" " ")" >&2; exit 4
        fi
        [ -f .env ] || echo NOENV >&2
        tar -cf - $ex .
    ' sh "$kind" 2>"$err" | tar -xf - -C "$to"; then
        local e; e="$(cat "$err")"; rm -f "$err"
        case "$e" in
            *BADNAME*) die "書庫に、外へ書き出そうとする名前（../ や / で始まるもの）が入っています。入れません" ;;
            *NOROOT*)  die "EC-CUBE 4 が見つかりません（src/Eccube/Common/Constant.php が無い）: $in" ;;
            *MULTI*)   die "EC-CUBE が 2 つ以上入っています。1 つだけにしてください: ${e#*MULTI }" ;;
            *SYMLINK*) die "シンボリックリンクが入っています。入れません（リンク先を実物にして固め直してください）: ${e#*SYMLINK }" ;;
            *)         die "展開できませんでした: ${e:-（理由不明）}" ;;
        esac
    fi
    if grep -q NOENV "$err"; then
        rm -f "$err"
        die "EC-CUBE のフォルダに .env がありません。FTP ソフトは、点で始まるファイルを隠すことがあります（FileZilla は「サーバー → 隠しファイルを強制表示」）。
         .env には全パスワードの鍵（ECCUBE_AUTH_MAGIC）と DB の接続先があり、無いと取り込めません"
    fi
    rm -f "$err"
}

# DB のダンプを、mysqldump / pg_dump の形（完了の行つき）にして <出力>.gz へ。決めるもの: dump_from・dump_server
unpack_dump() { # unpack_dump <ダンプ> <DB の種類 mysql|postgresql> <出力 .sql.gz>
    local in="$1" engine="$2" out="$3" abs
    [ -f "$in" ] || die "ダンプがありません: $in"
    abs="$(cd "$(dirname "$in")" && pwd)/$(basename "$in")"
    dump_cat() {
        case "$abs" in
            *.zip) docker run --rm --network none -v "${abs}:/in/d.zip:ro" alpine:3 sh -c '
                    n="$(unzip -l /in/d.zip 2>/dev/null | sed -nE "s/^ *[0-9]+ +[0-9-]+ +[0-9:]+ +//p" | grep -vE "/$|__MACOSX" | grep -E "\.sql(\.gz)?$")" || true
                    [ "$(printf "%s\n" "$n" | grep -c .)" = 1 ] || { echo "zip の中に .sql（.sql.gz）がちょうど 1 つ要ります" >&2; exit 3; }
                    case "$n" in *.gz) unzip -p /in/d.zip "$n" | gunzip -c ;; *) unzip -p /in/d.zip "$n" ;; esac' ;;
            *.gz) gunzip -c "$abs" ;;
            *) cat "$abs" ;;
        esac
    }
    local head tail
    head="$(dump_cat 2>/dev/null | head -c 8192 | head -40)" || true
    tail="$(dump_cat | tail -c 2048)" || die "ダンプを読めませんでした: $in"
    dump_server="$(printf '%s\n' "$head" | sed -nE 's/^-- .*(Server version|サーバのバージョン|サーバーのバージョン|Dumped from database version)[:：]?[[:space:]]*(.+)$/\2/p' | head -1 | tr -d '\r')"
    # Adminer は 1 行目に「-- Adminer <版> <DB の種類> <サーバーの版> dump」。MariaDB でも種類は MySQL と書き、版の側に MariaDB が入る
    [ -n "$dump_server" ] || dump_server="$(printf '%s\n' "$head" | sed -nE '1s/^-- Adminer [^ ]+ (.+) dump[[:space:]]*$/\1/p' | tr -d '\r')"
    local reload_what=""

    case "$head" in
        *"-- PostgreSQL database dump"*)
            [ "$engine" = postgresql ] || die "ダンプは PostgreSQL ですが、店の .env の DATABASE_URL は MySQL / MariaDB です"
            printf '%s' "$tail" | grep -q -- '-- PostgreSQL database dump complete' || die "ダンプが途中で切れています（完了の行がありません）。取り直してください"
            dump_from=pg_dump; dump_cat | gzip -c > "$out"; return 0 ;;
        *"-- MySQL dump"*|*"-- MariaDB dump"*)
            [ "$engine" = mysql ] || die "ダンプは MySQL / MariaDB ですが、店の .env の DATABASE_URL は PostgreSQL です"
            printf '%s' "$tail" | grep -q -- '-- Dump completed' || die "ダンプが途中で切れています（完了の行がありません）。取り直してください"
            dump_from=mysqldump; dump_cat | gzip -c > "$out"; return 0 ;;
        *"-- phpMyAdmin SQL Dump"*)
            [ "$engine" = mysql ] || die "phpMyAdmin のダンプですが、店の .env の DATABASE_URL は PostgreSQL です"
            # phpMyAdmin には完了の行が無い。既定の書き出しは最後に COMMIT と文字コードの戻しを書くので、それで見る
            # （レンタルサーバーの phpMyAdmin は大きい DB で時間切れになり、途中で切れたファイルを正常に渡してくる）
            printf '%s' "$tail" | grep -qE 'SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION|^COMMIT;[[:space:]]*$' \
                || die "phpMyAdmin のダンプが途中で切れているようです（最後に COMMIT も文字コードの戻しもありません）。
         大きい DB は phpMyAdmin が時間切れで途中までしか書かないことがあります。サーバーの管理画面の「MySQL バックアップ」
         などの機能で取り直すか、gzip 圧縮で書き出してください"
            dump_from=phpmyadmin; reload_what=phpMyAdmin ;;
        "-- Adminer "*)
            case "$(printf '%s\n' "$head" | head -1)" in
                *" PostgreSQL "*)
                    # Adminer の PostgreSQL の書き出しは pg_dump と違い、シーケンスや型を全部は書かない。取り直せる形にならないので受けない
                    die "Adminer で書き出した PostgreSQL のダンプは受け付けていません。pg_dump で取ってください（サーバーの管理画面の
         バックアップ機能、または pg_dump が打てる場所から）" ;;
            esac
            [ "$engine" = mysql ] || die "Adminer の MySQL のダンプですが、店の .env の DATABASE_URL は PostgreSQL です"
            # Adminer は書き終えたときだけ、最後に「-- <日時> UTC」の 1 行を書く。時間切れで止まったファイルには無い
            printf '%s' "$tail" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -1 | grep -qE '^-- [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' \
                || die "Adminer のダンプが途中で切れているようです（最後に書き出した日時の行がありません）。
         大きい DB は Adminer が時間切れで途中までしか書かないことがあります。サーバーの管理画面の「MySQL バックアップ」
         などの機能で取り直してください"
            dump_from=adminer; reload_what=Adminer ;;
        *)
            die "ダンプの形が分かりません（mysqldump・pg_dump・phpMyAdmin・Adminer のどれかで書き出してください）。先頭:
$(printf '%s\n' "$head" | head -3 | sed 's/^/         /')" ;;
    esac

    # phpMyAdmin・Adminer のダンプは使い捨ての DB に入れて、mysqldump で取り直す。入りきるか、表がそろっているかもここで分かる
    local img client dumper
    case "$dump_server" in
        *[Mm]aria[Dd][Bb]*) img=mariadb:10.11; client=mariadb; dumper=mariadb-dump ;;
        *) img=mysql:8.0; client=mysql; dumper=mysqldump ;;
    esac
    need_image "$img" || die "DB のイメージを取れませんでした: $img"
    local pw c
    pw="$(openssl rand -hex 16)"
    c="eccube-import-dump-$$"
    dump_container="$c"   # cmd_unpack の EXIT が消す（die でも残さない）
    log "${reload_what} のダンプを、使い捨ての DB（${img}）に入れて確かめます..."
    docker run -d --name "$c" --network none -e MYSQL_ROOT_PASSWORD="$pw" -e MARIADB_ROOT_PASSWORD="$pw" \
        -e MYSQL_DATABASE=shop -e MARIADB_DATABASE=shop "$img" --max-allowed-packet=1G >/dev/null \
        || die "使い捨ての DB を起動できませんでした"
    # 初回は一時のサーバー（port: 0）が先に立って落ちる。本物（port: 3306）が立つまで待つ
    # pipefail の下で docker logs | grep -q にしない（grep が先に終わると SIGPIPE で「無い」になる）
    local i=0 lg
    while :; do
        lg="$(docker logs "$c" 2>&1 || true)"
        case "$lg" in *"port: 3306 "*) break ;; esac   # 33060（X プロトコル）を拾わないよう、後ろの空白まで見る
        i=$((i + 1)); [ "$i" -lt 180 ] || die "使い捨ての DB が起動しません（docker logs ${c}）"; sleep 1
    done
    local lerr; lerr="$(mktemp)"
    if ! dump_cat | sed -e '/^USE /d' -e '/^CREATE DATABASE /d' -e '/^DROP DATABASE /d' \
        | docker exec -i -e MYSQL_PWD="$pw" "$c" "$client" -uroot --default-character-set=utf8mb4 --max-allowed-packet=1G shop 2>"$lerr"; then
        local e; e="$(head -5 "$lerr")"; rm -f "$lerr"
        die "ダンプを DB に入れられませんでした（${img}）:
$(printf '%s\n' "$e" | sed 's/^/         /')"
    fi
    rm -f "$lerr"
    local have
    have="$(docker exec -e MYSQL_PWD="$pw" "$c" "$client" -uroot -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='shop' AND table_name IN ('dtb_base_info','dtb_customer','dtb_order','dtb_product','dtb_plugin','dtb_member')")"
    [ "$have" = 6 ] || die "ダンプに EC-CUBE の表がそろっていません（${have}/6）。${reload_what} で一部の表だけを選んで書き出していませんか"
    docker exec -e MYSQL_PWD="$pw" "$c" "$dumper" -uroot --default-character-set=utf8mb4 --single-transaction --quick \
        --no-tablespaces --routines --triggers shop | gzip -c > "$out" || die "取り直せませんでした"
    gunzip -c "$out" | tail -c 1024 | grep -q -- '-- Dump completed' || die "取り直したダンプに完了の行がありません"
}

cmd_unpack() {
    local src="" dump="" name=""
    for a in "$@"; do
        case "$a" in
            --dump=*) dump="${a#--dump=}" ;;
            --name=*) name="${a#--name=}" ;;
            -*) die "知らない指定です: $a" ;;
            *) src="$a" ;;
        esac
    done
    [ -n "$src" ] && [ -n "$dump" ] || die "使い方: bin/import.sh unpack <フォルダ | zip | tar.gz> --dump=<.sql | .sql.gz | .zip> [--name=<名前>]"
    if [ -z "$name" ]; then
        name="$(basename "${src%/}")"; name="${name%.zip}"; name="${name%.tar.gz}"; name="${name%.tgz}"; name="${name%.tar}"
        name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
    fi
    local dest="var/import/${name}"
    mkdir -p var/import; chmod 700 var/import 2>/dev/null || true
    local stage="${dest}.new"
    rm -rf "$stage"; mkdir -p "$stage/files"; chmod 700 "$stage" "$stage/files"
    dump_container=""
    trap 'rm -rf "'"$stage"'"; [ -z "$dump_container" ] || docker rm -f "$dump_container" >/dev/null 2>&1 || true' EXIT

    log "ファイルを整えます（vendor・キャッシュは除く）..."
    unpack_files "$src" "$stage/files"
    chmod 700 "$stage/files"
    resolve_src "$stage" ""
    local engine
    case "$(sed -n 's/^DATABASE_URL=//p' "$src_base/.env" | tail -1 | tr -d "\"' \r")" in
        mysql*) engine=mysql ;; pgsql*|postgres*) engine=postgresql ;;
        "") die ".env に DATABASE_URL がありません" ;;
        *) die "DB の種類が分かりません（DATABASE_URL）。キットは MySQL / MariaDB と PostgreSQL だけです" ;;
    esac
    [ -n "$(sed -n 's/^ECCUBE_AUTH_MAGIC=//p' "$src_base/.env" | tail -1 | tr -d "\"' \r")" ] \
        || log "注意: .env に ECCUBE_AUTH_MAGIC がありません。取り込んでも誰もログインできません（店に確かめてください）"

    log "DB のダンプを確かめます..."
    dump_from=""; dump_server=""
    unpack_dump "$dump" "$engine" "$stage/dump.sql.gz"
    chmod 600 "$stage/dump.sql.gz"

    local n kb
    n="$(find "$stage/files/html/upload" -type f 2>/dev/null | wc -l | tr -d ' ')"
    kb="$(du -sk "$stage/files/html/upload" 2>/dev/null | cut -f1)"
    {
        echo "source=archive"
        echo "unpacked=$(date +%s)"
        echo "dump_from=${dump_from}"
        [ -z "$dump_server" ] || echo "db_server=${dump_server}"
        echo "upload_files=${n:-0}"
        echo "upload_kb=${kb:-0}"
    } > "$stage/meta.env"
    chmod 600 "$stage/meta.env"

    # 入れ替え（前の診断の報告書は残す）
    if [ -d "$dest" ]; then
        rm -rf "$dest/files" "$dest/dump.sql.gz" "$dest/meta.env"
        mv "$stage/files" "$stage/dump.sql.gz" "$stage/meta.env" "$dest/"
        rm -rf "$stage"
    else
        mv "$stage" "$dest"
    fi
    trap - EXIT
    [ -z "$dump_container" ] || docker rm -f "$dump_container" >/dev/null 2>&1 || true
    echo
    log "整えました: ${dest}（EC-CUBE ${src_ver}・DB は ${dump_from}${dump_server:+（${dump_server}）}・商品画像など ${n:-0} ファイル）"
    [ "${n:-0}" != 0 ] || log "注意: 商品画像（html/upload）がありません。取り込み（load）の前に、html/upload も落としてください"
    log "次: bin/import.sh diagnose ${dest}"
}

# ---------------------------------------------------------------- diagnose
cmd_diagnose() {
    local src="" dump="" to=4.3
    for a in "$@"; do
        case "$a" in
            --dump=*) dump="${a#--dump=}" ;;
            --to=*) to="${a#--to=}" ;;
            -*) die "知らない指定です: $a" ;;
            *) src="$a" ;;
        esac
    done
    [ -n "$src" ] || die "使い方: bin/import.sh diagnose <店のフォルダ> [--dump=<ダンプ>] [--to=4.3]"
    resolve_src "$src" "$dump"
    local base="$src_base" dump="$src_dump" meta="$src_meta" ver="$src_ver" series="$src_series"
    case "$to" in [0-9].[0-9]) ;; *) die "--to は系列で指定してください（例: --to=4.3）" ;; esac
    log "EC-CUBE ${ver} → ${to} として調べます"

    # 診断の置き場。fetch のフォルダなら、その中に作る
    local out
    if [ "$base" != "$(cd "$src" && pwd)" ]; then out="$(cd "$src" && pwd)/report"; else out="$PWD/var/import/$(basename "$base")-$(date +%Y%m%d-%H%M%S)/report"; fi
    mkdir -p "$out" "$cache"
    chmod 700 var/import 2>/dev/null || true
    rm -f "$out"/phpstan-*.txt "$out"/core.patch "$out"/composer.extra.json

    local pristine; pristine="$(get_pristine "$ver")"

    # PHPStan（版と sha256 を固定）
    local phar="${cache}/phpstan-${PHPSTAN_VER}.phar"
    if [ ! -f "$phar" ]; then
        log "PHPStan ${PHPSTAN_VER} を取ってきます..."
        curl -fsSL -o "${phar}.part" "https://github.com/phpstan/phpstan/releases/download/${PHPSTAN_VER}/phpstan.phar" || die "PHPStan を取れませんでした"
        [ "$($sha_cmd "${phar}.part" | cut -d' ' -f1)" = "$PHPSTAN_SHA" ] || { rm -f "${phar}.part"; die "PHPStan の sha256 が合いません。取り直してください"; }
        mv "${phar}.part" "$phar"
    fi
    printf 'parameters:\n    level: 1\n    reportUnmatchedIgnoredErrors: false\n    treatPhpDocTypesAsCertain: false\n' > "${cache}/phpstan.neon"
    local tools; tools="$(cd "$cache" && pwd)"

    local to_img="${IMAGE_BASE}:${to}" from_img="${IMAGE_BASE}:${series}"
    need_image "$to_img" || die "上げた先のイメージを取れませんでした: $to_img"
    local have_from=1
    need_image "$from_img" 2>/dev/null || { have_from=0; log "注意: EC-CUBE ${series} のイメージが無いので、元の版での比べ（PHPStan）は省きます。上げた先の誤りは、元からあったものも数えます"; }

    # PHPStan を元の版と上げた先の両方で。読むのは店が書いた PHP（app/Customize・app/Plugin）だけ
    local paths="app/Customize"
    [ -n "$(ls -A "$base/app/Plugin" 2>/dev/null)" ] && paths="$paths app/Plugin"
    run_stan() { # run_stan <イメージ> <出力>
        # 4.4 の本体は PHPStan 2 向けの拡張を持ち、1.x の phar は「incompatible extensions」で何も読まずに終わる
        # （誤り 0 件に見える）。拡張の置き場を空で覆う（bin/lib/compat.sh と同じ）
        docker run --rm --user "$(id -u):$(id -g)" \
            --tmpfs /var/www/html/vendor/phpstan/extension-installer \
            -v "$base/app/Customize:/var/www/html/app/Customize:ro" \
            -v "$base/app/Plugin:/var/www/html/app/Plugin:ro" \
            -v "$tools:/tools:ro" -e HOME=/tmp \
            --entrypoint sh "$1" -c "cd /var/www/html && php -d memory_limit=2G /tools/phpstan-${PHPSTAN_VER}.phar analyse -c /tools/phpstan.neon \
                --no-progress --error-format=raw --autoload-file=vendor/autoload.php ${paths} 2>/dev/null" > "$2" || true
    }
    log "上げた先（${to}）で、プラグインと app/Customize を読みます（PHPStan）..."
    run_stan "$to_img" "$out/phpstan-to.txt"
    if [ "$have_from" = 1 ]; then
        log "元の版（${series}）でも読みます（元からある誤りを除くため）..."
        run_stan "$from_img" "$out/phpstan-from.txt"
    fi

    # 報告書
    local dumpmount=()
    if [ -n "$dump" ]; then
        local dabs; dabs="$(cd "$(dirname "$dump")" && pwd)/$(basename "$dump")"
        case "$dump" in *.gz) dumpmount=(-v "${dabs}:/dump/dump.sql.gz:ro") ;; *) dumpmount=(-v "${dabs}:/dump/dump.sql:ro") ;; esac
    fi
    local metamount=()
    [ -n "$meta" ] && metamount=(-v "$(cd "$(dirname "$meta")" && pwd)/meta.env:/meta.env:ro")
    log "報告書を作ります..."
    local summary
    summary="$(docker run --rm --user "$(id -u):$(id -g)" \
        -v "$base:/old:ro" -v "$pristine:/from:ro" -v "$out:/out" \
        -v "$PWD/bin/lib/import-diagnose.php:/kit/diagnose.php:ro" -v "$PWD/bin/lib/import-dump.php:/kit/import-dump.php:ro" \
        ${dumpmount[@]+"${dumpmount[@]}"} ${metamount[@]+"${metamount[@]}"} \
        --entrypoint php "$to_img" -d memory_limit=1G /kit/diagnose.php "$to")" || die "報告書を作れませんでした"

    echo
    printf '%s\n' "$summary" | sed -n 's/^VERDICT=/判定: /p'
    printf '%s\n' "$summary" | sed -n 's/^REASON=/  ・/p'
    echo
    log "報告書: ${out}/report.md"
    [ -f "$out/core.patch" ] && log "本体の書き換えの差分: ${out}/core.patch"
    [ -f "$out/composer.extra.json" ] && log "composer.extra.json の下書き: ${out}/composer.extra.json"
    log "DB のダンプには会員の個人情報が入っています。終わったら var/import/ を消してください"
}


# ---------------------------------------------------------------- load
# .env の 1 行を書き換える（無ければ足す）。sed -i は macOS と Linux で書き方が違うので使わない
set_env() { # set_env <キー> <値>
    local tmp; tmp="$(mktemp)"
    awk -v k="$1" -v v="$2" 'BEGIN { done = 0 } $0 ~ "^" k "=" { if (!done) print k "=" v; done = 1; next } { print } END { if (!done) print k "=" v }' .env > "$tmp"
    cat "$tmp" > .env; rm -f "$tmp"
}

cmd_load() {
    local src="" dump=""
    for a in "$@"; do
        case "$a" in
            --dump=*) dump="${a#--dump=}" ;;
            -*) die "知らない指定です: $a" ;;
            *) src="$a" ;;
        esac
    done
    [ -n "$src" ] || die "使い方: bin/import.sh load <fetch --full で取ったフォルダ | 店のフォルダ> [--dump=<ダンプ>]"
    resolve_src "$src" "$dump"
    [ -n "$src_dump" ] || die "DB のダンプがありません（fetch --full で取るか、--dump= で渡してください）"
    local name; name="$(basename "$(cd "$src" && pwd)")"

    # ── このキットが、取り込める状態か ──
    [ -f .env ] || die "先に bin/init.sh で、このキットを用意してください（--image=ghcr.io/kurozumi/eccube-kit/ec-cube:${src_series}）"
    local proj cid kit_ver
    proj="$(guard_project_name)"
    cid="$(docker compose ps -q ec-cube 2>/dev/null | head -1 || true)"
    [ -n "$cid" ] || die "キットが動いていません。docker compose up -d してから、もう一度"
    kit_ver="$(image_eccube_of_container "$cid")"
    [ "$(printf '%s' "$kit_ver" | cut -d. -f1-2)" = "$src_series" ] \
        || die "キットの EC-CUBE（${kit_ver:-?}）と元の店（${src_ver}）の系列が違います。同じ系列で取り込んでから bin/upgrade.sh で上げます:
         bin/init.sh --image=${IMAGE_BASE}:${src_series} で用意し直してください"
    local shop_db kit_db
    case "$(sed -n 's/^DATABASE_URL=//p' "$src_base/.env" 2>/dev/null | tail -1 | tr -d "\"' \r")" in
        mysql*) shop_db=mysql ;; pgsql*|postgres*) shop_db=postgresql ;; *) shop_db="?" ;;
    esac
    kit_db="$(env_get DB_ENGINE)"; kit_db="${kit_db:-mysql}"
    [ "$shop_db" = "$kit_db" ] || die "元の店の DB（${shop_db}）とキットの DB_ENGINE（${kit_db}）が違います。ダンプは種類をまたいで戻りません（.env の DB_ENGINE を合わせて bin/init.sh）"
    # **まっさらなキットにだけ入れる。** 自分の店のコードが入ったキットに重ねると、どちらのものか分からなくなる
    local dirty
    dirty="$(git status --porcelain -- app/Customize app/template html/user_data html/template/original 2>/dev/null || true)"
    [ -z "$dirty" ] || die "このキットには、まだコミットしていない変更があります。まっさらなキット（clone して bin/init.sh したもの）に取り込んでください:
$(printf '%s\n' "$dirty" | head -5 | sed 's/^/         /')"
    [ -z "$(find app/Plugin -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)" ] || die "app/Plugin にもうプラグインがあります。まっさらなキットに取り込んでください"
    [ ! -f html/template/original/.base ] || die "html/template/original にもうテーマが入っています。まっさらなキットに取り込んでください"
    # 商品画像（fetch --full で取る。受け取ったフォルダなら html/upload ごと）
    if [ -z "$(find "$src_base/html/upload/save_image" -type f 2>/dev/null | head -1)" ] && [ -n "$src_meta" ] \
        && [ "$(sed -n 's/^upload_files=//p' "$src_meta")" != 0 ]; then
        die "商品画像を取っていません。bin/import.sh fetch --full でもう一度取ってください"
    fi

    local theme; theme="$(sed -n 's/^ECCUBE_TEMPLATE_CODE=//p' "$src_base/.env" 2>/dev/null | tail -1 | tr -d "\"' \r")"
    case "${theme:-default}" in default) theme="" ;; esac
    [ -z "$theme" ] || [ -d "$src_base/html/template/$theme" ] || [ -d "$src_base/app/template/$theme" ] \
        || die "元の店はテーマ ${theme} を使っていますが、そのファイルがありません"

    local pristine; pristine="$(get_pristine "$src_ver")"
    local img; img="$(docker inspect -f '{{.Config.Image}}' "$cid")"
    local out="backups/$(date +%Y%m%d-%H%M%S)-import-${name}"
    mkdir -p "$out"; chmod 700 "$out"
    out="$(cd "$out" && pwd)"
    local dmount
    case "$src_dump" in *.gz) dmount="${src_dump}:/dump/dump.sql.gz:ro" ;; *) dmount="${src_dump}:/dump/dump.sql:ro" ;; esac
    pack() { # pack <check|pack>
        docker run --rm --user "$(id -u):$(id -g)" \
            -v "$src_base:/old:ro" -v "$pristine:/from:ro" -v "$PWD:/kit" -v "$out:/out" -v "$dmount" \
            -v "$PWD/bin/lib/import-pack.php:/kit-pack.php:ro" \
            --entrypoint php "$img" -d memory_limit=1G /kit-pack.php "$1" "$theme"
    }
    local stops
    stops="$(pack check | sed -n 's/^STOP=//p')" || die "取り込めるかの確認に失敗しました"
    if [ -n "$stops" ]; then
        rm -rf "$out"
        die "取り込めません。何も変えていません:
$(printf '%s\n' "$stops" | sed 's/^/         ・/')"
    fi

    echo
    log "元の店（EC-CUBE ${src_ver}・${name}）を、このキット（${proj}）へ取り込みます。"
    log "  このキットの DB・画像は、元の店の中身で置き換わります（いまのものは backups/ に控えます）"
    log "  .env の ECCUBE_AUTH_MAGIC を元の店の値にします（違うと誰もログインできない）"
    [ -z "$theme" ] || log "  テーマ ${theme} を original として入れます"
    log "  **メールの送り先（MAILER_DSN）は引き継ぎません。** 検証の環境から本物のお客さんへメールが出ないように"
    log "  **決済は、検証で注文する前に、管理画面で必ずテスト用の設定に切り替えてください**（本物の鍵のままだと本当に請求します）"
    if [ "${CONFIRM_IMPORT:-}" != "$proj" ]; then
        local ans; read -r -p "続行しますか? [y/N] " ans || ans=""
        [ "$ans" = y ] || { rm -rf "$out"; log "中止しました。何も変えていません。"; exit 1; }
    fi

    log "元の店を、バックアップの形に詰め直します..."
    local notes
    notes="$(pack pack)" || die "詰め直せませんでした（${out}）。app/Customize に書きかけがあれば git checkout -- app/Customize で戻せます"

    log ".env を元の店に合わせます..."
    local magic route
    magic="$(sed -n 's/^ECCUBE_AUTH_MAGIC=//p' "$out/host.env")"
    [ -n "$magic" ] || die "元の店の .env に ECCUBE_AUTH_MAGIC がありません。これが無いと誰もログインできないので止めます"
    set_env ECCUBE_AUTH_MAGIC "$magic"
    route="$(sed -n 's/^ECCUBE_ADMIN_ROUTE=//p' "$src_base/.env" 2>/dev/null | tail -1 | tr -d "\"' \r")"
    [ -z "$route" ] || set_env ECCUBE_ADMIN_ROUTE "$route"
    [ -z "$theme" ] || set_env ECCUBE_TEMPLATE_CODE original
    docker compose up -d >/dev/null 2>&1 || die "キットを起動し直せませんでした（docker compose up -d）"
    local i=0
    until [ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q ec-cube | head -1)" 2>/dev/null)" = healthy ]; do
        i=$((i + 1)); [ "$i" -lt 600 ] || die "キットが起動しません（docker compose logs ec-cube）"; sleep 1
    done

    if [ -n "$theme" ]; then
        log "テーマ ${theme} を original として入れます..."
        local tout
        tout="$(bin/theme.sh install "$out/theme-${theme}.tar.gz" 2>&1)" || { printf '%s\n' "$tout" >&2; die "テーマを入れられませんでした"; }
        printf '%s\n' "$tout" | grep -E '入れました|注意|^    ' || true
    fi

    log "DB・画像・管理画面のファイル・プラグインを流し込みます（bin/restore.sh）..."
    CONFIRM_RESTORE="$proj" bin/restore.sh "$out" || die "流し込みに失敗しました。restore.sh の表示に従ってください（取り込む前の状態は backups/ にあります）"

    echo
    log "取り込みました（EC-CUBE ${src_ver}）。"
    printf '%s\n' "$notes" | sed -n 's/^NOTE=/[import]   ・/p'
    log "  本体を直接書き換えた箇所は運んでいません（bin/import.sh diagnose の core.patch）"
    log "次にやること:"
    log "  1) 画面を確かめる。管理画面は /${route:-admin}（パスワードは元の店のもの）。メールは Mailpit に届く"
    log "  2) 決済をテスト用の設定にしてから、注文を通す"
    log "  3) git add -A && git commit（app/Customize・テーマ・composer.extra.json）"
    log "  4) 上げる: bin/upgrade.sh ~4.3.0 --php=8.3"
    log "元の店の DB と画像は ${out} にもあります（個人情報。終わったら消す）"
}

# ---------------------------------------------------------------- plugins
# 買ったプラグインは git に入らない（app/Plugin/* は .gitignore）。リハーサルで作者の対応版に入れ替えたものを、
# 本番のキットへそのまま運ぶ。backup.sh の admin-files.tar.gz は app/template・html/user_data も含むので、
# それを本番で広げると本番のファイルを上書きする。プラグインだけを固め、入れる側で中身を確かめる。
cmd_plugins() {
    local sub="${1:-}"; [ $# -eq 0 ] || shift
    case "$sub" in
        pack) plugins_pack "$@" ;;
        add) plugins_add "$@" ;;
        *) die "使い方: bin/import.sh plugins pack（リハーサルの環境で）| bin/import.sh plugins add <書庫>（本番のキットで）" ;;
    esac
}

plugin_version() { # plugin_version <app/Plugin/<コード>>
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/composer.json" 2>/dev/null | head -1
}

plugins_pack() {
    [ $# -eq 0 ] || die "plugins pack は引数を取りません（app/Plugin のプラグインを全部固めます）"
    local codes=() d c
    for d in app/Plugin/*/; do
        [ -f "${d}composer.json" ] || continue
        c="$(basename "$d")"
        case "$c" in *[!A-Za-z0-9_]*) continue ;; esac
        codes+=("$c")
    done
    [ "${#codes[@]}" -gt 0 ] || die "app/Plugin にプラグインがありません"
    local links; links="$(cd app/Plugin && find "${codes[@]}" -name .git -prune -o -type l -print | head -3)"
    [ -z "$links" ] || die "シンボリックリンクがあります。入れる側で止まるので、実物にしてから:
$(printf '%s\n' "$links" | sed 's#^#         app/Plugin/#')"
    local tmp; tmp="$(mktemp -d)"
    for c in "${codes[@]}"; do
        printf '%s\t%s\t%s\n' "$c" "$(plugin_version "app/Plugin/$c")" "$(git -C "app/Plugin/$c" remote get-url origin 2>/dev/null || echo -)"
    done > "$tmp/plugins.txt"
    mkdir -p var/import
    local out; out="var/import/plugins-$(date +%Y%m%d-%H%M%S).tar.gz"
    # .git は運ばない（重いうえ、本番で git の操作はしない。remote は plugins.txt に控える）
    ( umask 077; COPYFILE_DISABLE=1 tar -czf "$out" --exclude='.git' --exclude='._*' --exclude='.DS_Store' \
        -C "$tmp" plugins.txt -C "$PWD/app/Plugin" "${codes[@]}" ) || { rm -rf "$tmp"; die "固められませんでした"; }
    rm -rf "$tmp"
    log "app/Plugin のプラグイン ${#codes[@]} 本を固めました: ${out}（$(du -h "$out" | cut -f1 | tr -d ' ')）"
    for c in "${codes[@]}"; do
        local v; v="$(plugin_version "app/Plugin/$c")"
        if [ -n "$(git -C "app/Plugin/$c" status --porcelain 2>/dev/null)" ]; then
            log "  ${c} ${v:-?}（コミットしていない変更があります。それも入っています）"
        else
            log "  ${c} ${v:-?}"
        fi
    done
    log "本番のサーバーへ写して、本番のキットで:"
    log "  scp ${out} <本番>:<キット>/var/import/"
    log "  bin/import.sh plugins add var/import/$(basename "$out")"
    log "買ったプラグインは、作者のライセンスの範囲で運んでください（同じ店の本番へ移すのは、ふつう範囲の内です）"
}

plugins_add() {
    local in="${1:-}"
    [ $# -eq 1 ] && [ -f "$in" ] || die "使い方: bin/import.sh plugins add <bin/import.sh plugins pack で作った書庫>"
    case "$in" in *.tar.gz|*.tgz) ;; *) die "plugins pack で作った .tar.gz を渡してください: $in" ;; esac
    local abs; abs="$(cd "$(dirname "$in")" && pwd)/$(basename "$in")"
    mkdir -p app/Plugin
    local stage; stage="app/Plugin/.import-$$"
    local err; err="$(mktemp)"
    trap 'rm -rf "'"$stage"'" "'"$err"'"' EXIT
    mkdir "$stage"
    # 書庫は使い捨てのコンテナで開く。busybox の tar は ../ や先頭の / を黙って削って続ける（標準エラーに 1 行出すだけ）
    if ! docker run --rm --network none --user "$(id -u):$(id -g)" -v "${abs}:/in/pkg:ro" alpine:3 sh -c '
        set -e
        names="$(tar -tzf /in/pkg 2>&1 || true)"
        if printf "%s\n" "$names" | grep -qE "removing leading|(^/|(^|/)\.\.(/|$))"; then echo BADNAME >&2; exit 5; fi
        printf "%s\n" "$names" | grep -qx "plugins.txt" || { echo NOMANIFEST >&2; exit 3; }
        mkdir -p /tmp/w && cd /tmp/w && tar -xzf /in/pkg
        # macOS の tar が足す AppleDouble（._*）と .DS_Store は捨てる
        find . \( -name "._*" -o -name .DS_Store \) -exec rm -rf {} +
        l="$(find . -type l | head -3 | tr "\n" " ")"
        [ -z "$l" ] || { echo "SYMLINK $l" >&2; exit 4; }
        for d in $(ls -A); do
            [ "$d" = plugins.txt ] && continue
            case "$d" in *[!A-Za-z0-9_]*) echo "BADCODE $d" >&2; exit 6 ;; esac
            [ -f "$d/composer.json" ] || { echo "BADCODE $d" >&2; exit 6; }
        done
        tar -cf - .
    ' 2>"$err" | tar -xf - -C "$stage"; then
        local e; e="$(cat "$err")"
        case "$e" in
            *BADNAME*)    die "書庫に、外へ書き出そうとする名前（../ や / で始まるもの）が入っています。入れません" ;;
            *NOMANIFEST*) die "bin/import.sh plugins pack で作った書庫ではありません（plugins.txt が無い）" ;;
            *SYMLINK*)    die "シンボリックリンクが入っています。入れません: ${e#*SYMLINK }" ;;
            *BADCODE*)    die "プラグインではないものが入っています（app/Plugin/<コード>/composer.json の形でない）: ${e#*BADCODE }" ;;
            *)            die "展開できませんでした: ${e:-（理由不明）}" ;;
        esac
    fi
    # 先に全部見てから入れる。違う中身のものが 1 つでもあれば、何も入れない
    local d c add=() same=() differ=()
    for d in "$stage"/*/; do
        c="$(basename "$d")"
        if [ ! -e "app/Plugin/$c" ]; then add+=("$c")
        elif diff -rq -x .git "app/Plugin/$c" "$stage/$c" >/dev/null 2>&1; then same+=("$c")
        else differ+=("$c"); fi
    done
    if [ "${#differ[@]}" -gt 0 ]; then
        die "このキットにもう入っていて、中身が違うプラグインがあります。何も入れていません:
$(printf '         app/Plugin/%s\n' "${differ[@]}")
         書庫のほうを入れるなら、そのフォルダを外へ移してから、もう一度（中身を確かめる: diff -r app/Plugin/<コード> <書庫を広げたもの>）"
    fi
    [ "${#add[@]}" -gt 0 ] || { log "書庫のプラグインは全部、同じ中身でもう入っています（${#same[@]} 本）。何も変えていません"; return 0; }
    for c in "${add[@]}"; do
        mv "$stage/$c" "app/Plugin/$c" || die "app/Plugin/$c に入れられませんでした（入れ終わったもの: ${add[*]}）"
    done
    log "プラグイン ${#add[@]} 本を app/Plugin に入れました:"
    for c in "${add[@]}"; do log "  ${c} $(plugin_version "app/Plugin/$c")"; done
    [ "${#same[@]}" -eq 0 ] || log "同じ中身でもう入っていたもの: ${same[*]}"
    log "ファイルを置いただけです（DB にはまだ入れていません）。切り替え（bin/import.sh cutover）が元の店の DB を入れ、"
    log "bin/plugin.sh sync が版を合わせます。cutover は、元の店で有効なプラグインがここにそろっているかを、元の店を止める前に確かめます"
}

# 元の店の DB（ダンプ）の dtb_plugin と、このキットの app/Plugin を突き合わせる。
# 結果: plug_missing_on（有効なのに無い）/ plug_missing_off（無効で無い）/ plug_update（コード 古い版 新しい版）/ plug_extra（DB に無い）
plugins_check() { # plugins_check <ダンプ> <イメージ>
    local dump="$1" img="$2" dmount res
    case "$dump" in *.gz) dmount="${dump}:/dump/dump.sql.gz:ro" ;; *) dmount="${dump}:/dump/dump.sql:ro" ;; esac
    mkdir -p app/Plugin
    res="$(docker run --rm --network none --user "$(id -u):$(id -g)" -v "$dmount" -v "$PWD/app/Plugin:/plugin:ro" \
        -v "$PWD/bin/lib/import-dump.php:/kit-dump.php:ro" --entrypoint php "$img" -d memory_limit=512M /kit-dump.php)" \
        || die "元の店の DB のダンプから、プラグインの一覧を読めませんでした。何も変えていません"
    plug_missing_on="$(printf '%s\n' "$res" | awk -F'\t' '$1 ~ /^MISSING=/ && $2 == 1 { sub(/^MISSING=/, "", $1); print $1 }')"
    plug_missing_off="$(printf '%s\n' "$res" | awk -F'\t' '$1 ~ /^MISSING=/ && $2 == 0 { sub(/^MISSING=/, "", $1); print $1 }')"
    plug_update="$(printf '%s\n' "$res" | awk -F'\t' '$1 ~ /^UPDATE=/ { sub(/^UPDATE=/, "", $1); print $1 " " $2 " → " $3 }')"
    plug_extra="$(printf '%s\n' "$res" | sed -n 's/^EXTRA=//p')"
}

plugins_missing_die() { # plugins_missing_die <ssh-before | ssh-after | manual>
    local how
    case "$1" in
        ssh-before) how="無効にしてから、もう一度。**何も変えていません**（元の店はまだ営業中）" ;;
        ssh-after)  how="無効にしてから、もう一度（先に取ってから止めるまでの間に、元の店で足されたものです）" ;;
        *)          how="無効にし、ファイルと DB を取り直して unpack し直してから、もう一度。**何も変えていません**
         （元の店のメンテナンス表示はそのまま。営業に戻すなら、元の店の管理画面で外す）" ;;
    esac
    die "元の店で有効なプラグインのうち、このキットの app/Plugin に無いものがあります:
$(printf '%s\n' "$plug_missing_on" | sed 's/^/         ・/')
         このまま入れると、元の店の DB は「有効」と言うのにファイルが無く、画面が落ちます。
         - リハーサルの環境で bin/import.sh plugins pack → できた書庫を本番へ写し、bin/import.sh plugins add <書庫>
         - リハーサルで外した（別のプラグインに替えた）ものなら、元の店の管理画面（オーナーズストア → プラグイン一覧）で
           ${how}"
}

# ---------------------------------------------------------------- cutover
# 元の店のメンテナンス表示。EC-CUBE 4 の index.php は、.maintenance（または ECCUBE_MAINTENANCE_FILE_PATH）があれば
# 「モード:トークン」のトークンを cookie に持つ人以外へメンテナンス画面を出す。**自分で置いたものだけを外す**
# （店が手で入れていたものは残す）。
old_maint_path() { # old_maint_path <取ったフォルダの files> <元の店のフォルダ>
    local p; p="$(sed -n 's/^ECCUBE_MAINTENANCE_FILE_PATH=//p' "$1/.env" 2>/dev/null | tail -1 | tr -d "\"' \r")"
    printf '%s' "${p:-$2/.maintenance}"
}

cmd_cutover() {
    local src="" name="" old_url="" from=""
    for a in "$@"; do
        case "$a" in
            --name=*) name="${a#--name=}" ;;
            --from=*) from="${a#--from=}" ;;
            --old-url=*) old_url="${a#--old-url=}" ;;
            -*) die "知らない指定です: $a" ;;
            *) src="$a" ;;
        esac
    done
    # 2 つのやり方: SSH で入れる店はこちらで元の店を止めて取り直す。入れない店（--from）は人が止めて取り直し、unpack したものを渡す
    local manual=0 host="" path="" dest
    if [ -n "$from" ]; then
        manual=1
        [ -z "$src" ] || die "--from と <ユーザー>@<ホスト>:<フォルダ> は一緒に使えません"
        [ -n "$old_url" ] || die "--from のときは --old-url=https://元の店/ が要ります（元の店が本当に止まっているかを、それで確かめます）"
        dest="${from%/}"
        [ -f "$dest/meta.env" ] && [ -f "$dest/dump.sql.gz" ] || die "${dest} は bin/import.sh unpack で整えたフォルダではありません"
        name="$(basename "$dest")"
    else
        case "$src" in *:/*) ;; *) die "使い方: bin/import.sh cutover <ユーザー>@<ホスト>:<元の店のフォルダ> [--old-url=https://元の店/] [--name=<名前>]
         SSH が使えない店: bin/import.sh cutover --from=var/import/<名前> --old-url=https://元の店/" ;; esac
        host="${src%%:*}"; path="${src#*:}"; path="${path%/}"
        [ -n "$name" ] || name="$(printf '%s' "${host#*@}" | tr -c 'A-Za-z0-9._-' '_')"
        dest="var/import/${name}"
    fi

    # ── このキット（本番）が、切り替えられる状態か ──
    [ -f .env ] || die ".env がありません。本番のサーバーで、リハーサルを済ませたリポジトリから bin/init.sh してください"
    local proj cid kit_ver
    proj="$(guard_project_name)"
    cid="$(docker compose ps -q ec-cube 2>/dev/null | head -1 || true)"
    [ -n "$cid" ] || die "キットが動いていません。docker compose up -d（本番なら bin/publish.sh）してから、もう一度"
    kit_ver="$(image_eccube_of_container "$cid")"
    local prod=""
    guard_is_prod_stack && prod=--prod
    local mailer; mailer="$(env_get MAILER_DSN)"
    if [ -n "$prod" ]; then
        case "$mailer" in ""|null://*|*mailpit*) die "本番なのに .env の MAILER_DSN が無い（または Mailpit）です。切り替えた瞬間から注文メールが届かなくなるので、先に書いてください" ;; esac
    fi

    if [ "$manual" = 0 ]; then
        log "切り替えの前に、元の店から取ってきます（元の店はまだ営業中。差分を小さくしておくため）..."
        cmd_fetch "${host}:${path}" --name="$name" --full >/dev/null
    fi
    resolve_src "$dest" ""
    [ -n "$src_dump" ] || die "DB のダンプがありません（${dest}）"
    if [ "$manual" = 0 ]; then
        [ -f "$src_base/index.php" ] && grep -q 'maintenanceFile' "$src_base/index.php" \
            || die "元の店（EC-CUBE ${src_ver}）の index.php が、ファイルでのメンテナンス表示に対応していません"
    else
        [ -n "$(find "$src_base/html/upload/save_image" -type f 2>/dev/null | head -1)" ] \
            || die "商品画像（html/upload）がありません。FTP で html/upload も落として、unpack し直してください"
    fi
    [ "$(printf '%s\n%s\n' "$src_series" "$(printf '%s' "$kit_ver" | cut -d. -f1-2)" | sort -V | head -1)" = "$src_series" ] \
        || die "キットの EC-CUBE（${kit_ver}）が元の店（${src_ver}）より古いです"
    # 合わせる先は**いま動いている版の系列**。配布イメージの環境では .env の ECCUBE_VERSION は使われず、動いている版と
    # ずれていることがある（4.2 で動いているのに ~4.3.0 と書かれていて、切り替えのついでに 4.3 へ上げようとした。試験で踏んだ）
    local kit_series constraint
    kit_series="$(printf '%s' "$kit_ver" | cut -d. -f1-2)"
    if [ -n "$(env_get ECCUBE_IMAGE)" ]; then
        constraint="~${kit_series}.0"
    else
        constraint="$(env_get ECCUBE_VERSION)"; constraint="${constraint:-$kit_ver}"
        [ "$(image_series "$constraint")" = "$kit_series" ] \
            || die ".env の ECCUBE_VERSION（${constraint}）が、動いている EC-CUBE（${kit_ver}）と系列が違います。切り替えで版は変えません。.env を直してから"
    fi
    local magic_old magic_now
    magic_old="$(sed -n 's/^ECCUBE_AUTH_MAGIC=//p' "$src_base/.env" | tail -1 | tr -d "\"' \r")"
    magic_now="$(env_get ECCUBE_AUTH_MAGIC)"
    [ -n "$magic_old" ] || die "元の店の .env に ECCUBE_AUTH_MAGIC がありません"
    local theme; theme="$(sed -n 's/^ECCUBE_TEMPLATE_CODE=//p' "$src_base/.env" 2>/dev/null | tail -1 | tr -d "\"' \r")"
    case "${theme:-default}" in default) theme="" ;; esac
    local mfile=""
    [ "$manual" = 1 ] || mfile="$(old_maint_path "$src_base" "$path")"
    # 買ったプラグインは git に無いので、このリポジトリを clone しただけの本番には無い（plugins pack / add で運ぶ）。
    # 元の店を止める前に、元の店で有効なものがそろっているかを見る
    local img; img="$(docker inspect -f '{{.Config.Image}}' "$cid")"
    local plug_missing_on plug_missing_off plug_update plug_extra
    plugins_check "$src_dump" "$img"
    if [ -n "$plug_missing_on" ]; then [ "$manual" = 1 ] && plugins_missing_die manual; plugins_missing_die ssh-before; fi

    echo
    if [ "$manual" = 1 ]; then
        local at; at="$(sed -n 's/^unpacked=//p' "$dest/meta.env" | head -1)"
        local age=$(( $(date +%s) - ${at:-0} ))
        log "切り替えます: 元の店（${old_url}・EC-CUBE ${src_ver}。${dest} に整えたもの）→ このキット（${proj}・EC-CUBE ${kit_ver}）"
        log "  **元の店は、あなたが管理画面でメンテナンス表示にしてあり、ファイルと DB はそのあとで取ったもの**として進めます"
        log "  （その前に取ったものだと、そのあとに入った注文・会員登録が消えます）"
        [ "$age" -lt 7200 ] || log "  注意: ${dest} を整えたのは $((age / 3600)) 時間前です。メンテナンス表示にしたあとで取り直したものか、確かめてください"
    else
        log "切り替えます: 元の店 ${host}:${path}（EC-CUBE ${src_ver}）→ このキット（${proj}・EC-CUBE ${kit_ver}）"
        log "  1. 元の店をメンテナンス表示にする（${mfile}）。**ここからお客さんは注文できません**"
        log "  2. 元の店から、変わった分のファイルと DB を取り直す"
        log "  3. このキットの DB・画像を、元の店のもので置き換え、bin/upgrade.sh で EC-CUBE ${kit_ver} に合わせる"
        log "  4. 開くか確かめる。**ここまでのどこかで失敗したら、元の店のメンテナンス表示を外して営業に戻す**"
    fi
    if [ "$manual" = 1 ]; then
        log "  1. 元の店（${old_url}）がメンテナンス画面（503）かを確かめる。なっていなければ何もせずに止まる"
        log "  2. このキットの DB・画像を、整えたもので置き換え、bin/upgrade.sh で EC-CUBE ${kit_ver} に合わせる"
        log "  3. 開くか確かめる。失敗したら止まる（元の店のメンテナンス表示は、あなたが管理画面で外す）"
    fi
    log "  コード（app/Customize・テーマ・プラグイン）は、このリポジトリのもの（リハーサルで直したもの）を使います"
    if [ -n "$plug_update" ]; then
        log "  プラグインの版を上げます（bin/plugin.sh sync）:"
        printf '%s\n' "$plug_update" | sed 's/^/[import]     /'
    fi
    [ -z "$plug_missing_off" ] || log "  元の店で無効のプラグインのうち、ここに無いもの（運びません。無効なので画面には響きません）: $(printf '%s' "$plug_missing_off" | tr '\n' ' ')"
    [ -z "$plug_extra" ] || log "  ここにあって元の店に無いプラグイン（切り替えのあとで入れる）: $(printf '%s' "$plug_extra" | tr '\n' ' ')"
    [ "$magic_old" = "$magic_now" ] || log "  .env の ECCUBE_AUTH_MAGIC を元の店の値にします"
    local ans
    read -r -p "始めるなら、プロジェクト名（${proj}）を打ってください: " ans || ans=""
    [ "$ans" = "$proj" ] || die "中止しました。何も変えていません"

    # ── 1. 元の店をメンテナンス表示に。ここから先の失敗は、元の店を開け直す ──
    # tr < /dev/urandom | head にしない（pipefail が tr の SIGPIPE を失敗と数え、何も言わずに終わる。試験で踏んだ）
    local token; token="$(openssl rand -hex 12)"
    local mine=0 reopened=0 old_down=0
    reopen_old() {
        if [ "$manual" = 1 ]; then
            [ "$old_down" = 1 ] || return 0   # 止まっているのを確かめる前の失敗。元の店には何も起きていない
            echo "[import] **元の店は止まったままです。営業に戻すなら、元の店の管理画面でメンテナンス表示を外してください。**" >&2
            return 0
        fi
        [ "$mine" = 1 ] && [ "$reopened" = 0 ] || return 0
        # shellcheck disable=SC2029
        if ssh -n -o BatchMode=yes "$host" "[ \"\$(cat '${mfile}' 2>/dev/null)\" = 'import:${token}' ] && rm -f '${mfile}'"; then
            reopened=1
            echo "[import] **元の店のメンテナンス表示を外しました。元の店で営業に戻っています。**" >&2
        else
            echo "[import] **元の店のメンテナンス表示を外せませんでした。** 手で消してください: ssh ${host} rm '${mfile}'" >&2
        fi
    }
    local kit_backup=""
    trap 'rc=$?; if [ "$rc" != 0 ]; then echo "[import] 切り替えに失敗しました。" >&2; reopen_old
        if [ -n "$kit_backup" ]; then echo "[import] このキットは途中の状態です（公開前）。切り替える前に戻すなら: bin/restore.sh ${kit_backup}" >&2; fi; fi' EXIT
    trap 'exit 130' INT TERM
    if [ "$manual" = 0 ]; then
        local had
        # shellcheck disable=SC2029
        had="$(ssh -n -o BatchMode=yes "$host" "if [ -e '${mfile}' ]; then echo had; else printf '%s' 'import:${token}' > '${mfile}' && echo put; fi")" \
            || die "元の店をメンテナンス表示にできませんでした（${mfile} に書けない？）。何も変えていません"
        case "$had" in
            put) mine=1; log "元の店をメンテナンス表示にしました" ;;
            had) log "元の店はもうメンテナンス表示です（店が入れたもの。終わっても外しません）" ;;
            *) die "元の店をメンテナンス表示にできませんでした" ;;
        esac
    fi
    if [ -n "$old_url" ]; then
        local code; code="$(curl -s -o /dev/null -w '%{http_code}' "$old_url" || true)"
        if [ "$code" != 503 ]; then
            [ "$manual" = 1 ] && die "元の店（${old_url}）がメンテナンス画面になっていません（${code}）。何も変えていません。
         元の店の管理画面（コンテンツ管理 → メンテナンス管理）で有効にし、**そのあとで**ファイルと DB を取り直して
         bin/import.sh unpack し直してから、もう一度打ってください（自分のブラウザは素通りするので、503 は別の端末で確かめる）"
            die "元の店（${old_url}）がメンテナンス画面になっていません（${code}）。注文が入り続けるので止めます"
        fi
        old_down=1
        log "元の店がメンテナンス画面（503）になったのを確かめました"
    fi

    # ── 2. 取り直す（変わった分だけ）。--from は人が取り直して unpack 済み ──
    if [ "$manual" = 0 ]; then
        log "元の店から、変わった分のファイルと DB を取り直します..."
        cmd_fetch "${host}:${path}" --name="$name" --full >/dev/null
        resolve_src "$dest" ""
        [ -n "$src_dump" ] || die "DB をダンプできませんでした"
        # 先に取ってから止めるまでの間に、元の店でプラグインが足されていないか
        plugins_check "$src_dump" "$img"
        [ -z "$plug_missing_on" ] || plugins_missing_die ssh-after
    fi

    # ── 3. データだけ流し込み、上げる ──
    local pristine; pristine="$(get_pristine "$src_ver")"
    local out="backups/$(date +%Y%m%d-%H%M%S)-cutover-${name}"
    mkdir -p "$out"; chmod 700 "$out"; out="$(cd "$out" && pwd)"
    local dmount
    case "$src_dump" in *.gz) dmount="${src_dump}:/dump/dump.sql.gz:ro" ;; *) dmount="${src_dump}:/dump/dump.sql:ro" ;; esac
    local packed differ mig_missing
    packed="$(docker run --rm --user "$(id -u):$(id -g)" \
        -v "$src_base:/old:ro" -v "$pristine:/from:ro" -v "$PWD:/kit:ro" -v "$out:/out" -v "$dmount" \
        -v "$PWD/bin/lib/import-pack.php:/kit-pack.php:ro" \
        --entrypoint php "$img" -d memory_limit=1G /kit-pack.php pack-data "$theme")" \
        || die "元の店のデータを詰め直せませんでした"
    differ="$(printf '%s\n' "$packed" | sed -n 's/^DIFFER=//p')"
    mig_missing="$(printf '%s\n' "$packed" | sed -n 's/^MIGRATION_MISSING=//p')"

    log "このキットのいまの状態を控えます（backups/<日時>-before-cutover）..."
    local blog; blog="$(BACKUP_LABEL=cutover bin/backup.sh 2>&1)" || { printf '%s\n' "$blog" >&2; die "このキットを控えられませんでした。このキットは何も変えていません"; }
    kit_backup="$(printf '%s\n' "$blog" | sed -n 's/^\[backup\] 完了: //p' | tail -1)"

    [ "$magic_old" = "$magic_now" ] || set_env ECCUBE_AUTH_MAGIC "$magic_old"
    # shellcheck disable=SC2046
    local dc=(docker compose $(compose_files $prod))
    log "アプリを止めて、DB を元の店のものにします..."
    "${dc[@]}" stop ec-cube worker >/dev/null 2>&1 || "${dc[@]}" stop ec-cube >/dev/null
    bin/restore.sh --rollback --db-only "$out" >/dev/null || die "DB を流し込めませんでした（控え: backups/*-before-cutover）"
    log "画像とプラグインが置いたファイルを入れます..."
    docker run --rm -i -v "${proj}_eccube_upload:/upload" alpine:3 sh -c 'tar -C / -xzf - && chown -R 33:33 /upload' < "$out/upload.tar.gz" \
        || die "画像を入れられませんでした"
    if [ -f "$out/plugindata.tar.gz" ]; then
        docker run --rm -i -v "${proj}_eccube_app:/app" alpine:3 sh -c 'mkdir -p /app/app && rm -rf /app/app/PluginData && tar -C /app/app -xzf - && chown -R 33:33 /app/app/PluginData' < "$out/plugindata.tar.gz" \
            || die "プラグインが置いたファイルを入れられませんでした"
    fi
    tar -xzf "$out/admin-files.tar.gz" || die "ページ（app/template/user_data）を入れられませんでした"

    log "EC-CUBE ${kit_ver} に合わせます（bin/upgrade.sh。スキーマの更新・migration。失敗したら自動で戻ります）..."
    # 確認（取ったイメージで続けるか）には y で答える。`yes |` にすると pipefail が yes の SIGPIPE を失敗と数える
    bin/upgrade.sh "$constraint" $prod < <(yes y) > "$out/upgrade.log" 2>&1 \
        || { tail -20 "$out/upgrade.log" >&2; die "上げられませんでした（${out}/upgrade.log）"; }
    log "プラグインの版を DB に合わせます（bin/plugin.sh sync）..."
    bin/plugin.sh sync > "$out/plugin-sync.log" 2>&1 || { tail -20 "$out/plugin-sync.log" >&2; die "プラグインを合わせられませんでした（${out}/plugin-sync.log）"; }
    bin/healthcheck.sh > "$out/healthcheck.log" 2>&1 || { cat "$out/healthcheck.log" >&2; die "開くかの確認に失敗しました"; }

    trap - EXIT INT TERM
    echo
    log "**切り替えの準備ができました。** 元の店はメンテナンス表示のままです（このキットの側で注文を受けます）。"
    if [ -n "$differ" ]; then
        log "元の店の管理画面で直されていて、このリポジトリのものと違うファイルがあります（運んでいません。必要なら手で移す）:"
        printf '%s\n' "$differ" | sed 's/^/    /'
    fi
    if [ -n "$mig_missing" ]; then
        log "元の店にあって、このリポジトリに無い migration があります（リハーサルのあとで元の店に足されたもの）。"
        log "DB には当たっていますが、ファイルがありません。元の店の同じファイルの名前空間を CustomizeMigrations にして、app/DoctrineMigrations に置いてください:"
        printf '%s\n' "$mig_missing" | sed 's/^/    /'
    fi
    log "次にやること:"
    log "  1) このキットの画面を、本番の URL を向ける前に確かめる（管理画面に元の店のパスワードで入れる・商品・カート）"
    log "  2) DNS（Cloudflare）を、このサーバーのトンネルへ向け替える"
    log "  3) 決済会社に、通知の URL と新しいサーバーの IP を登録する（診断の「店に確かめること」）"
    local crons; crons="$(sed -n 's/^cron=//p' "$dest/meta.env" 2>/dev/null)"
    [ -z "$crons" ] || { log "  4) 元のサーバーの cron を止める:"; printf '%s\n' "$crons" | sed 's/^/       /'; }
    if [ "$manual" = 1 ]; then
        log "  4) 元のサーバーの cron（レンタルサーバーの管理画面の「cron 設定」）を止める"
        log "  やめて元の店に戻すなら（このキットで注文を受ける前だけ）: 元の店の管理画面でメンテナンス表示を外す"
    else
        log "  やめて元の店に戻すなら（このキットで注文を受ける前だけ）: ssh ${host} rm '${mfile}'"
    fi
    if [ -n "$plug_extra" ]; then
        log "  リハーサルで足したプラグイン（元の店の DB に無いので、まだ入っていない）を入れる:"
        printf '%s\n' "$plug_extra" | sed 's#^#[import]     bin/plugin.sh install #'
    fi
    log "  git status で、ページ（app/template/user_data）の変更をコミットしてください"
}

case "$1" in
    cutover) shift; cmd_cutover "$@" ;;
    load) shift; cmd_load "$@" ;;
    fetch) shift; cmd_fetch "$@" ;;
    unpack) shift; cmd_unpack "$@" ;;
    diagnose) shift; cmd_diagnose "$@" ;;
    plugins) shift; cmd_plugins "$@" ;;
    *) die "知らないコマンドです: $1（fetch / unpack / diagnose / load / plugins / cutover）" ;;
esac

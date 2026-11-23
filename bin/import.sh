#!/usr/bin/env bash
# キットに載っていない EC-CUBE の店を、キットへ取り込む前に調べる。**元の店には何も書かない。**
#
#   bin/import.sh fetch <ユーザー>@<ホスト>:<EC-CUBE のフォルダ> [--name=<名前>]
#       元のサーバーから、診断に要るファイルと DB のダンプを SSH で取ってくる（読むだけ）。
#       置き場は var/import/<名前>/。商品画像（html/upload）と vendor は取らない（数と大きさだけ数える）。
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
#
# 診断で見るもの（報告書は var/import/<名前>/report/report.md）:
#   - 本体を直接書き換えた箇所（同じ版のまっさらな EC-CUBE と比べる。差分は core.patch）
#   - app/template の写しのうち、上げた先の本体が変えたもの（3 つを比べる）
#   - プラグインと app/Customize が上げた先で読めるか（PHPStan を両方の版で流し、上げた先でだけ出る誤りを数える）
#   - 使っているテーマ、足されたライブラリ（composer.extra.json の下書き）、店が足した migration
#   - DB の種類と版、MySQL 8 専用の照合順序、トリガー、ダンプが最後まであるか
#   - 判定（固定料金で受けられるか）と、店に確かめることの一覧
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
    ssh -o BatchMode=yes "$host" "test -f '${path}/src/Eccube/Common/Constant.php'" \
        || die "${host}:${path} に EC-CUBE 4 が見つかりません（SSH の鍵で入れるか、フォルダが正しいか確かめてください）"
    ssh -o BatchMode=yes "$host" "command -v rsync >/dev/null" || die "${host} に rsync がありません。店から zip で受け取って diagnose に渡してください"

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
    ssh -o BatchMode=yes "$host" "cd '${path}' && {
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
    if ssh -o BatchMode=yes "$host" "URL='${url}' php -r '
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
        log "注意: DB をダンプできませんでした（向こうに mysqldump / pg_dump が無い、など）。店から受け取って --dump= で渡してください"
    fi
    echo
    log "取ってきました: ${dest}"
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
        docker run --rm --user "$(id -u):$(id -g)" \
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
        -v "$PWD/bin/lib/import-diagnose.php:/kit/diagnose.php:ro" \
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
        local ans; read -r -p "続行しますか? [y/N] " ans
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

case "$1" in
    load) shift; cmd_load "$@" ;;
    fetch) shift; cmd_fetch "$@" ;;
    diagnose) shift; cmd_diagnose "$@" ;;
    *) die "知らないコマンドです: $1（fetch / diagnose / load）" ;;
esac

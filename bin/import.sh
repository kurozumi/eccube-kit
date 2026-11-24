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

# ---------------------------------------------------------------- fetch
cmd_fetch() {
    local src="" name=""
    for a in "$@"; do
        case "$a" in
            --name=*) name="${a#--name=}" ;;
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

    log "ファイルを取ってきます（商品画像・vendor・キャッシュは除く）..."
    rsync -az --delete \
        --exclude='/vendor/' --exclude='/var/' --exclude='/node_modules/' --exclude='/html/upload/' \
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
    [ -d "$src" ] || die "フォルダがありません: $src"
    local base="$src" meta=""
    # fetch で取ったフォルダ（files/ と dump.sql.gz）
    if [ -d "$src/files" ] && [ -f "$src/files/src/Eccube/Common/Constant.php" ]; then
        base="$src/files"
        [ -n "$dump" ] || { [ -f "$src/dump.sql.gz" ] && dump="$src/dump.sql.gz"; }
        [ -f "$src/meta.env" ] && meta="$src/meta.env"
    fi
    [ -f "$base/src/Eccube/Common/Constant.php" ] || die "EC-CUBE 4 のフォルダではありません（src/Eccube/Common/Constant.php が無い）: $base"
    base="$(cd "$base" && pwd)"
    [ -z "$dump" ] || [ -f "$dump" ] || die "ダンプがありません: $dump"

    local ver series
    ver="$(sed -nE "s/.*const VERSION = '([^']+)'.*/\1/p" "$base/src/Eccube/Common/Constant.php" | head -1)"
    [ -n "$ver" ] || die "EC-CUBE の版を読めませんでした"
    series="$(printf '%s' "$ver" | cut -d. -f1-2)"
    case "$to" in [0-9].[0-9]) ;; *) die "--to は系列で指定してください（例: --to=4.3）" ;; esac
    log "EC-CUBE ${ver} → ${to} として調べます"

    # 診断の置き場。fetch のフォルダなら、その中に作る
    local out
    if [ "$base" != "$(cd "$src" && pwd)" ]; then out="$(cd "$src" && pwd)/report"; else out="$PWD/var/import/$(basename "$base")-$(date +%Y%m%d-%H%M%S)/report"; fi
    mkdir -p "$out" "$cache"
    chmod 700 var/import 2>/dev/null || true
    rm -f "$out"/phpstan-*.txt "$out"/core.patch "$out"/composer.extra.json

    # 同じ版のまっさらな EC-CUBE（GitHub のタグ）
    local pristine="${cache}/ec-cube-${ver}"
    if [ ! -d "$pristine" ]; then
        log "まっさらな EC-CUBE ${ver} を取ってきます..."
        local tmp; tmp="$(mktemp -d)"
        curl -fsSL "https://codeload.github.com/EC-CUBE/ec-cube/tar.gz/refs/tags/${ver}" | tar -xzf - -C "$tmp" \
            || { rm -rf "$tmp"; die "EC-CUBE ${ver} のソースを取れませんでした（GitHub にその版のタグがあるか確かめてください）"; }
        mv "$tmp"/ec-cube-* "$pristine"; rm -rf "$tmp"
    fi
    pristine="$(cd "$pristine" && pwd)"

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

case "$1" in
    fetch) shift; cmd_fetch "$@" ;;
    diagnose) shift; cmd_diagnose "$@" ;;
    *) die "知らないコマンドです: $1（fetch / diagnose）" ;;
esac

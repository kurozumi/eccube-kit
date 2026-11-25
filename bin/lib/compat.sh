# shellcheck shell=bash
# 系列をまたいで EC-CUBE を上げる前の点検（bin/upgrade.sh が読む）。店にも DB にも触らない。
#
#   compat_check <いまのイメージ> <上げた先のイメージ> <出力ディレクトリ>
#     - PHPStan: app/Customize と app/Plugin を、いまの版と上げた先の版の両方で読み、**上げた先でだけ出る誤り**を
#       <出力>/phpstan-new.txt に出す（元からある誤りは数えない）。プラグインが新しい版の本体のクラスやメソッドを
#       前提にしていないと、ここに出る。読み込みで落ちる（Fatal error）より手前の、動かすと落ちるものも拾う
#     - テンプレート: app/template で上書きしているファイルのうち、**本体側が 2 つの版のあいだで変わったもの**を
#       <出力>/templates-changed.txt に出す。上書きは古いまま勝ち続けるので、本体の直しや新しい項目が出なくなる
#   終わりの値: 0 = 点検できた（結果はファイル。中身が空なら問題なし）、1 = 点検できなかった
#
# PHPStan の版と sha256 は bin/import.sh（diagnose）と揃える。
COMPAT_PHPSTAN_VER=1.12.12
COMPAT_PHPSTAN_SHA=80cf561a258720de8935b232d2cb0110ccbb1e4d0a8593c795a402e0b3357325

_compat_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# PHPStan を用意して、置き場の絶対パスを出す。取れなければ 1
compat_phpstan_tools() {
    local dir=var/cache/phpstan phar
    mkdir -p "$dir" || return 1
    phar="${dir}/phpstan-${COMPAT_PHPSTAN_VER}.phar"
    if [ ! -f "$phar" ]; then
        curl -fsSL -o "${phar}.part" "https://github.com/phpstan/phpstan/releases/download/${COMPAT_PHPSTAN_VER}/phpstan.phar" || { rm -f "${phar}.part"; return 1; }
        [ "$(_compat_sha "${phar}.part" | cut -d' ' -f1)" = "$COMPAT_PHPSTAN_SHA" ] || { rm -f "${phar}.part"; return 1; }
        mv "${phar}.part" "$phar"
    fi
    printf 'parameters:\n    level: 1\n    reportUnmatchedIgnoredErrors: false\n    treatPhpDocTypesAsCertain: false\n' > "${dir}/phpstan.neon"
    (cd "$dir" && pwd)
}

# compat_stan <イメージ> <道具の置き場> <出力>。読むのは店が書いた PHP だけ
compat_stan() {
    local paths="app/Customize"
    [ -n "$(find app/Plugin -mindepth 1 -maxdepth 1 ! -name '.*' 2>/dev/null | head -1)" ] && paths="$paths app/Plugin"
    # 読めないとき（イメージが壊れている・PHP が起きない・PHPStan が断った）は、空の結果を「誤り無し」と取り違えないよう 1。
    # **4.4 の本体は PHPStan 2 向けの拡張（vendor/phpstan/extension-installer）を持っていて、1.x の phar は
    # 「incompatible extensions」と言って何も読まずに 1 を返す。** 1 は「誤りがあった」と同じ値なので、素通りしていた。
    # その置き場を空のフォルダで覆って拡張なしで読ませ、それでも断られたら点検できなかったことにする
    docker run --rm --user "$(id -u):$(id -g)" \
        --tmpfs /var/www/html/vendor/phpstan/extension-installer \
        -v "$PWD/app/Customize:/var/www/html/app/Customize:ro" \
        -v "$PWD/app/Plugin:/var/www/html/app/Plugin:ro" \
        -v "$2:/tools:ro" -e HOME=/tmp \
        --entrypoint sh "$1" -c "cd /var/www/html && php -d memory_limit=2G /tools/phpstan-${COMPAT_PHPSTAN_VER}.phar analyse -c /tools/phpstan.neon \
            --no-progress --error-format=raw --autoload-file=vendor/autoload.php ${paths} >/tmp/o 2>/tmp/e; rc=\$?; cat /tmp/o; \
            grep -q 'incompatible extensions' /tmp/o /tmp/e && rc=9; echo __COMPAT_RC__\$rc" > "$3" 2>/dev/null || true
    # PHPStan は誤りが無ければ 0、あれば 1。それ以外は PHPStan 自身が落ちた・断った（読めていない）
    grep -qE '^__COMPAT_RC__[01]$' "$3" || return 1
    sed -i.bak '/^__COMPAT_RC__/d' "$3" && rm -f "$3.bak"
}

# 本体のテンプレートの指紋（default と admin）。<イメージ> <出力>
compat_core_templates() {
    docker run --rm --entrypoint sh "$1" -c \
        'cd /var/www/html/src/Eccube/Resource/template && find default admin -type f -name "*.twig" -exec sha256sum {} +' \
        2>/dev/null | awk '{ print $2 "\t" $1 }' | sort > "$2"
    [ -s "$2" ]
}

compat_check() {
    local from="$1" to="$2" out="$3" tools
    mkdir -p "$out" || return 1
    rm -f "$out"/phpstan-*.txt "$out"/templates-*.txt
    tools="$(compat_phpstan_tools)" || { echo "PHPStan を用意できませんでした（ネットワーク・sha256）" > "$out/error.txt"; return 1; }
    compat_stan "$to" "$tools" "$out/phpstan-to.txt"   || { echo "上げた先のイメージで PHPStan を流せませんでした" > "$out/error.txt"; return 1; }
    compat_stan "$from" "$tools" "$out/phpstan-from.txt" || { echo "いまのイメージで PHPStan を流せませんでした" > "$out/error.txt"; return 1; }
    # 上げた先でだけ出る誤り。行の頭のコンテナ内のパスを落として比べる。app/ の下だけ（本体の誤りは数えない）
    sed 's#^/var/www/html/##' "$out/phpstan-from.txt" | sort -u > "$out/phpstan-from.norm"
    sed 's#^/var/www/html/##' "$out/phpstan-to.txt" | grep '^app/[^:]*:[0-9]*:' | sort -u |
        comm -23 - "$out/phpstan-from.norm" > "$out/phpstan-new.txt" || true
    rm -f "$out/phpstan-from.norm"

    # テンプレート: app/template/admin/X は本体の admin/X、ほかのテーマのフォルダ（default・original など）の X は
    # 本体の default/X を上書きする。user_data（ページ管理のページ）は本体に対になるものが無いので見ない
    compat_core_templates "$from" "$out/templates-from.tsv" || { echo "いまのイメージのテンプレートを読めませんでした" > "$out/error.txt"; return 1; }
    compat_core_templates "$to" "$out/templates-to.tsv"     || { echo "上げた先のイメージのテンプレートを読めませんでした" > "$out/error.txt"; return 1; }
    : > "$out/templates-changed.txt"
    local f rel core a b
    while IFS= read -r f; do
        rel="${f#app/template/}"
        case "$rel" in
            user_data/*) continue ;;
            admin/*) core="$rel" ;;
            */*) core="default/${rel#*/}" ;;
            *) continue ;;
        esac
        a="$(awk -F'\t' -v k="$core" '$1 == k { print $2 }' "$out/templates-from.tsv")"
        b="$(awk -F'\t' -v k="$core" '$1 == k { print $2 }' "$out/templates-to.tsv")"
        [ -n "$a" ] || continue                       # 本体に対になるものが無い（店が足したファイル）
        if [ -z "$b" ]; then
            printf '%s\t上げた先の本体には無い（%s）\n' "$f" "$core" >> "$out/templates-changed.txt"
        elif [ "$a" != "$b" ]; then
            printf '%s\t本体が変わった（%s）\n' "$f" "$core" >> "$out/templates-changed.txt"
        fi
    done < <(find app/template -type f -name '*.twig' 2>/dev/null | sort)
    rm -f "$out/templates-from.tsv" "$out/templates-to.tsv"
    return 0
}

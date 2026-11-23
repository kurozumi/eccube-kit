#!/usr/bin/env bash
# オリジナルテーマ（html/template/original）の静的物を本体から写し、本体を上げたときに
# 上流の変更を見えるようにする。
#
#   bin/theme.sh init          本体テーマの assets を html/template/original/assets へ写す
#   bin/theme.sh diff          自分の変更 / 上流の変更 / 衝突 を挙げる
#   bin/theme.sh status        写した時点の版と、いまの本体の版
#
#   bin/theme.sh install <書庫>        買ったテーマ（オーナーズストアの zip / tar.gz）を original として入れる
#   bin/theme.sh diff <新しい書庫>     入れたテーマの新しい版（4.3 対応版など）と、自分の変更を突き合わせる
#   bin/theme.sh install <書庫> --force  新しい版に入れ替える（いまのものは var/theme-backup/ に控える）
#   bin/theme.sh adopt <コード>        管理画面から入れたテーマを original へ移す（upgrade で消えないように）
#
# 買ったテーマ・管理画面から入れたテーマ:
#   管理画面（テンプレート管理 → アップロード）は、静的物を本体のボリュームの
#   html/template/<コード> に書く。**bin/upgrade.sh はこのボリュームを作り直すので、上げた瞬間に
#   テーマの CSS と画像が消える**（ページは 200 のまま崩れて出る）。bin/backup.sh も取らない。
#   キットが残すのは original だけなので、テーマは original として入れる。書庫の中身は本体と同じ
#   読み方（app/ → app/template/original、html/ → html/template/original）。
#   original は読み取り専用で mount しているので、管理画面からのアップロードはできない。
#
# なぜ要るか:
#   twig は app/template/<code>/ に**直すファイルだけ**置けばよい（無ければ本体の
#   default にフォールバックする）。だが静的物は違う。asset() の base_path が
#   /html/template/<code> の 1 本だけで、フォールバックが無い。1 ファイル欠けると
#   その URL は 404 になる。**だから assets は丸ごと写すしかない。**
#
#   写した瞬間は同じでも、本体を上げると**古いほうが勝ち続ける**。例外は出ず、
#   直ったはずの崩れが戻る・新しい画像が出ない、という形でだけ現れる。
#   そこで写した時点の版と各ファイルの sha256 を .base に記録しておき、`diff` で
#   「自分が変えたもの」「上流が変えたもの」「両方（衝突）」を分けて出す。
#   bin/self-update.sh が環境ファイルでやっているのと同じ構造。
#
# 前提:
#   - テーマコードは original 固定。compose.yaml が html/template/original を bind
#     mount している（default にすると本体のテーマを空ディレクトリで覆い隠すため、
#     可変にしていない）
#   - .env に ECCUBE_TEMPLATE_CODE=original を書いて docker compose up -d する
set -euo pipefail
# -h / --help は先頭のコメント（この説明）をそのまま出す。AI や初めての人が最初に打つのはこれ
case "${1:-}" in -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
cd "$(dirname "$0")/.."
# shellcheck source=lib/guard.sh
. "$(dirname "$0")/lib/guard.sh"
# shellcheck source=lib/theme.sh
. "$(dirname "$0")/lib/theme.sh"

code=original
dir="html/template/${code}"
appdir="app/template/${code}"
base="${dir}/.base"

log() { echo "[theme] $*"; }
die() { echo "[theme] エラー: $*" >&2; exit 1; }

# 本体はボリュームの中にしか無い。ec-cube のイメージで `docker compose run` すると
# イメージが無いときにフルビルドが始まるので、alpine でボリュームを読む
# （bin/backup.sh と同じ理由）。
proj="$(guard_project_name)"
[ -n "$proj" ] || die "compose のプロジェクト名を取得できません"
vol() { docker run --rm -v "${proj}_eccube_app:/app:ro" alpine:3 "$@"; }

core_version() {
    vol sed -nE "s/.*const VERSION = '([^']+)'.*/\1/p" /app/src/Eccube/Common/Constant.php 2>/dev/null | head -1
}

# 本体テーマの assets を一時ディレクトリへ取り出す（出力: そのパス）
fetch_core_assets() {
    local tmp
    tmp="$(mktemp -d)"
    vol tar -C /app/html/template/default -cf - assets | tar -xf - -C "$tmp"
    [ -d "$tmp/assets" ] || die "本体テーマの assets を取り出せませんでした（ボリュームが無い？ docker compose up -d）"
    printf '%s' "$tmp"
}

# sha256 は環境で名前が違う（Linux: sha256sum / macOS: shasum -a 256）。
# **シェル関数にしないこと。** xargs はシェル関数を呼べず、`xargs: sha: not found`
# が 2>/dev/null に隠れて pipefail で黙って死ぬ（実際にそうなった。.base に
# version 行しか残らず、init が「完了」を出さずに終わった）。
if command -v sha256sum >/dev/null 2>&1; then sha_cmd="sha256sum"; else sha_cmd="shasum -a 256"; fi

# <ルート>/assets 以下の「<sha>  <相対パス>」一覧（相対パスは assets/ から）
manifest() { # manifest <ルート>
    # shellcheck disable=SC2086  # sha_cmd は単語分割させる
    ( cd "$1" && find assets -type f -print0 | LC_ALL=C sort -z | xargs -0 $sha_cmd ) \
        | sed -E 's/^([0-9a-f]+) [ *]?/\1  /'
}

# 2 つの manifest で違う相対パス（片方にしか無いものも含む）
changed() { # changed <manifestA> <manifestB>
    LC_ALL=C comm -3 <(LC_ALL=C sort "$1") <(LC_ALL=C sort "$2") \
        | sed -E 's/^\t//; s/^[0-9a-f]+  //' | LC_ALL=C sort -u
}

# 入れたテーマ（書庫・adopt）の「<sha>  html/<相対パス>」「<sha>  app/<相対パス>」一覧
pkg_manifest() { # pkg_manifest <html のルート> <app のルート>
    local side root
    for side in html app; do
        if [ "$side" = html ]; then root="$1"; else root="$2"; fi
        [ -d "$root" ] || continue
        # shellcheck disable=SC2086  # sha_cmd は単語分割させる
        ( cd "$root" && find . -type f ! -name .base ! -name .gitkeep -print0 | LC_ALL=C sort -z | xargs -0 -r $sha_cmd ) \
            | sed -E "s#^([0-9a-f]+) [ *]?\./#\1  ${side}/#"
    done
}

base_mode() { # core（本体から写した）/ package（書庫・adopt）/ 空（まだ無い）
    [ -f "$base" ] || return 0
    case "$(head -1 "$base")" in package=*) echo package ;; *) echo core ;; esac
}

# 書庫を一時ディレクトリへ展開する（出力: そのパス。中に app/ と html/）。
# **展開は使い捨てのコンテナの中だけでやり、普通のファイルとディレクトリだけを tar で受け取る。**
# 書庫は他人が作ったものなので、`../` や絶対パスで外へ書こうとする名前、外を指すシンボリックリンクが
# 入っていてもホストに届かないようにする（リンクは見つけたら止める）。macOS が足すゴミ（__MACOSX・._*・
# .DS_Store）は捨てる。1 つのフォルダに包んである書庫は、その中を見る。
extract_pkg() { # extract_pkg <書庫>
    local f="$1" abs kind tmp
    [ -f "$f" ] || die "書庫がありません: $f"
    abs="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
    case "$f" in
        *.zip) kind=zip ;;
        *.tar.gz|*.tgz) kind=tgz ;;
        *.tar) kind=tar ;;
        *) die "zip / tar.gz / tar のどれかを渡してください: $f" ;;
    esac
    tmp="$(mktemp -d)"
    if ! docker run --rm -v "${abs}:/in/pkg:ro" alpine:3 sh -c '
        set -e
        mkdir -p /w/x && cd /w/x
        # busybox の unzip / tar は ../ や先頭の / を黙って削って続ける（標準エラーに 1 行出すだけ）。
        # 削られた名前は書庫を作った人の意図と違う場所に落ちるので、見つけたら入れない
        case "$1" in
            zip) names="$(unzip -l /in/pkg 2>&1 || true)" ;;
            tgz) names="$(tar -tzf /in/pkg 2>&1 || true)" ;;
            tar) names="$(tar -tf /in/pkg 2>&1 || true)" ;;
        esac
        if printf "%s\n" "$names" | grep -qE "removing leading|(^/|(^|/)\.\.(/|$))"; then
            echo "BADNAME $(printf "%s\n" "$names" | grep -E "removing leading" | head -1)" >&2; exit 5
        fi
        case "$1" in
            zip) unzip -q /in/pkg ;;
            tgz) tar -xzf /in/pkg ;;
            tar) tar -xf /in/pkg ;;
        esac
        rm -rf __MACOSX; find . -name "._*" -exec rm -f {} + ; find . -name .DS_Store -exec rm -f {} +
        if [ ! -d app ] && [ ! -d html ]; then
            n=$(find . -mindepth 1 -maxdepth 1 | wc -l)
            one=$(find . -mindepth 1 -maxdepth 1 -type d | head -1)
            if [ "$n" = 1 ] && [ -n "$one" ] && { [ -d "$one/app" ] || [ -d "$one/html" ]; }; then cd "$one"; fi
        fi
        if [ ! -d app ] && [ ! -d html ]; then echo "NOFORMAT" >&2; exit 3; fi
        if [ -n "$(find . -type l | head -1)" ]; then echo "SYMLINK $(find . -type l | head -3 | tr "\n" " ")" >&2; exit 4; fi
        if [ -n "$(find . ! -type f ! -type d | head -1)" ]; then echo "SPECIAL" >&2; exit 4; fi
        mkdir -p app html
        tar -cf - app html
    ' sh "$kind" 2>"${tmp}.err" | tar -xf - -C "$tmp"; then
        local err; err="$(cat "${tmp}.err" 2>/dev/null)"; rm -rf "$tmp" "${tmp}.err"
        case "$err" in
            *NOFORMAT*) die "テーマの書庫の形ではありません（中に app/ か html/ が要ります。EC-CUBE の管理画面が読む形と同じ）" ;;
            *BADNAME*)  die "書庫に、外へ書き出そうとする名前（../ や / で始まるもの）が入っています。入れません: ${err#*BADNAME }" ;;
            *SYMLINK*)  die "書庫にシンボリックリンクが入っています。入れません: ${err#*SYMLINK }" ;;
            *SPECIAL*)  die "書庫に普通のファイルとフォルダ以外のものが入っています。入れません" ;;
            *)          die "書庫を展開できませんでした: ${err:-（理由不明）}" ;;
        esac
    fi
    rm -f "${tmp}.err"
    [ -d "$tmp/app" ] && [ -d "$tmp/html" ] || { rm -rf "$tmp"; die "書庫を展開できませんでした"; }
    printf '%s' "$tmp"
}

# いまの original（twig と静的物の両方）を控える。控えられなければ何も変えずに止まる
keep_current() { # keep_current <名前の一部> [一緒に控えるパス...]
    local keep items=() label="$1" extra
    shift
    for extra in "$@"; do [ -e "$extra" ] && items+=("$extra"); done
    [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null | grep -v '^\.gitkeep$' || true)" ] && items+=("$dir")
    [ -d "$appdir" ] && [ -n "$(ls -A "$appdir" 2>/dev/null | grep -v '^\.gitkeep$' || true)" ] && items+=("$appdir")
    [ "${#items[@]}" -gt 0 ] || return 0
    mkdir -p var/theme-backup
    keep="$(mktemp -d "var/theme-backup/$(date +%Y%m%d-%H%M%S)-${label}-XXXXXX")" \
        || die "控えの置き場を作れませんでした。何も変えていません。"
    COPYFILE_DISABLE=1 tar -czf "${keep}/original.tar.gz" "${items[@]}" \
        || die "いまのテーマを控えられませんでした。何も変えていません。"
    log "いまのテーマ（${items[*]}）を ${keep}/original.tar.gz に控えました"
    log "  戻すなら: rm -rf ${dir} ${appdir} && tar -xzf ${keep}/original.tar.gz"
}

# 用意した app/ と html/ で original を置き換え、.base を書く
put_theme() { # put_theme <app/ と html/ を持つディレクトリ> <.base の見出し>
    local src="$1" label="$2" gk_html=0 gk_app=0
    [ -f "${dir}/.gitkeep" ] && gk_html=1
    [ -f "${appdir}/.gitkeep" ] && gk_app=1
    # **フォルダごと消さない。中身だけ消す。** html/template/original は compose が bind mount しているので、
    # 消して作り直すと、動いているコンテナは消えた古いフォルダを見続け、静的物が全部 404 になる（取り込みの試験で踏んだ）
    mkdir -p "$dir" "$appdir"
    find "$dir" "$appdir" -mindepth 1 -delete
    cp -a "${src}/html/." "$dir/"
    cp -a "${src}/app/." "$appdir/"
    [ "$gk_html" = 1 ] && : > "${dir}/.gitkeep"
    [ "$gk_app" = 1 ] && : > "${appdir}/.gitkeep"
    {
        echo "package=${label}"
        pkg_manifest "$dir" "$appdir"
    } > "$base"
    log "入れました: 静的物 $(find "$dir" -type f ! -name .base ! -name .gitkeep | wc -l | tr -d ' ') ファイル、twig $(find "$appdir" -type f ! -name .gitkeep | wc -l | tr -d ' ') ファイル"
    [ -f "${dir}/assets/css/style.css" ] || log "注意: ${dir}/assets/css/style.css がありません。テーマが本体の静的物を前提にしているなら、画面の CSS が 404 になります"
}

# テーマの中に、元のコードを名指しした URL（/html/template/<コード>/...）が残っていないか
# テーマの中に、コードを名指しした URL（/html/template/<コード>/...）が残っていないか。
# 元は別のコードで作られたテーマなので、original・default・admin 以外を指していれば 404 になる
warn_hardcoded() {
    local hits
    hits="$(grep -rlE 'html/template/[A-Za-z0-9_-]+' "$dir" "$appdir" 2>/dev/null | while read -r f; do
            grep -ohE 'html/template/[A-Za-z0-9_-]+' "$f" | grep -vqE '^html/template/(original|default|admin)$' && printf '%s\n' "$f"
        done | head -10 || true)"
    [ -n "$hits" ] || return 0
    log "注意: テーマのコードを直接書いた URL（/html/template/<コード>/...）があります。original に直さないと、その画像や CSS は 404 です:"
    printf '%s\n' "$hits" | sed 's/^/    /'
}

next_steps() {
    echo
    log "次にやること:"
    log "  1) .env に ECCUBE_TEMPLATE_CODE=${code} を書く（もう書いてあれば不要）"
    log "  2) docker compose up -d && bin/plugin.sh reload   （twig のキャッシュを作り直す）"
    log "  3) 画面を開いて崩れていないか見てから、git add ${dir} ${appdir} && git commit"
}

cmd="${1:-help}"
case "$cmd" in
  init)
    if [ "$(base_mode)" = package ] && [ "${2:-}" = "--force" ]; then
        die "original には買ったテーマ（$(head -1 "$base" | cut -d= -f2-)）が入っています。init は本体のテーマで置き換えるので止めます。
       本当に本体のテーマへ戻すなら、${dir} を消してから bin/theme.sh init"
    fi
    if [ -f "$base" ] && [ "${2:-}" != "--force" ]; then
        die "すでに写してあります（$(head -1 "$base")）。写し直すなら bin/theme.sh init --force
       （自分で直した分は置き換わります。いまの写しは var/theme-backup/ に控えます。先に bin/theme.sh diff で確かめてください）"
    fi
    ver="$(core_version)"
    [ -n "$ver" ] || die "本体のバージョンを読めませんでした（ボリュームが無い？ docker compose up -d）"
    log "本体（EC-CUBE ${ver}）のテーマ assets を ${dir}/assets へ写します..."
    src="$(fetch_core_assets)"
    # **写し直す前に、いまの写しを控える。** 自分で直した CSS・画像も丸ごと置き換わるので、
    # git にコミットしていなければ、ここが唯一の残り先になる。
    if [ -d "${dir}/assets" ]; then
        # 同じ秒に 2 回打っても別のフォルダにする（同じ名前だと、2 回目が 1 回目の控えを置き換え後の中身で潰す）
        mkdir -p var/theme-backup
        keep="$(mktemp -d "var/theme-backup/$(date +%Y%m%d-%H%M%S)-${code}-XXXXXX")" \
            || { rm -rf "$src"; die "控えの置き場を作れませんでした。何も変えていません。"; }
        items=(assets); [ -f "$base" ] && items+=(.base)
        COPYFILE_DISABLE=1 tar -czf "${keep}/assets.tar.gz" -C "$dir" "${items[@]}" \
            || { rm -rf "$src"; die "いまの写しを控えられませんでした。何も変えていません。"; }
        # 戻すときは、置き換えたあとの assets をよけてから展開する（上に重ねると、控えに無いファイルが残る）
        log "いまの写しを ${keep}/assets.tar.gz に控えました"
        log "  戻すなら: mv ${dir}/assets ${keep}/assets.replaced && tar -xzf ${keep}/assets.tar.gz -C ${dir}"
    fi
    rm -rf "${dir}/assets"
    mkdir -p "$dir"
    cp -a "$src/assets" "${dir}/assets"
    rm -rf "$src"
    {
        echo "version=${ver}"
        manifest "$dir"
    } > "$base"
    n="$(( $(wc -l < "$base") - 1 ))"
    log "完了。${n} ファイル。写した版を ${base} に記録しました。"
    echo
    log "次にやること:"
    log "  1) .env に ECCUBE_TEMPLATE_CODE=${code} を書く"
    log "  2) docker compose up -d   （nginx にも mount が要るので作り直される）"
    log "  3) git add ${dir} && git commit   （6MB ほど。静的物なので追跡する）"
    log "  twig を直すときは app/template/${code}/ に**直すファイルだけ**置く。丸ごと写さない。"
    ;;

  install)
    pkg="${2:-}"
    [ -n "$pkg" ] || die "使い方: bin/theme.sh install <書庫（zip / tar.gz）> [--force]"
    if [ -f "$base" ] && [ "${3:-}" != "--force" ]; then
        die "original にはもう入っています（$(head -1 "$base")）。入れ替えるなら bin/theme.sh install ${pkg} --force
       （自分で直した分も置き換わります。先に bin/theme.sh diff ${pkg} で確かめてください。いまのものは var/theme-backup/ に控えます）"
    fi
    if [ ! -f "$base" ] && [ -n "$(find "$appdir" -type f ! -name .gitkeep 2>/dev/null | head -1)" ] && [ "${3:-}" != "--force" ]; then
        die "${appdir} に、あなたが置いた twig があります。テーマで置き換えるので、確かめてから --force を付けてください（控えは取ります）"
    fi
    src="$(extract_pkg "$pkg")"
    trap 'rm -rf "$src"' EXIT
    keep_current install
    sum="$($sha_cmd "$pkg" | cut -c1-12)"
    put_theme "$src" "$(basename "$pkg") sha256:${sum}"
    warn_hardcoded
    next_steps
    ;;

  adopt)
    from="${2:-}"
    [ -n "$from" ] || die "使い方: bin/theme.sh adopt <テーマコード>   （ボリュームにしか無いもの: $(theme_unsaved_dirs "${proj}_eccube_app" | tr '\n' ' ')）"
    [ "$from" != "$code" ] && [ "$from" != default ] && [ "$from" != admin ] || die "${from} は移せません"
    case "$from" in */*|.*) die "テーマコードが正しくありません: ${from}" ;; esac
    if [ -f "$base" ] && [ "${3:-}" != "--force" ]; then
        die "original にはもう入っています（$(head -1 "$base")）。置き換えるなら --force（いまのものは var/theme-backup/ に控えます）"
    fi
    vol_name="${proj}_eccube_app"
    has_html=0
    docker run --rm -v "${vol_name}:/app:ro" alpine:3 test -d "/app/html/template/${from}" 2>/dev/null && has_html=1
    [ "$has_html" = 1 ] || [ -d "app/template/${from}" ] \
        || die "テーマ ${from} が見つかりません（ボリュームの html/template/${from} にも app/template/${from} にも無い）"
    src="$(mktemp -d)"
    trap 'rm -rf "$src"' EXIT
    mkdir -p "$src/html" "$src/app"
    if [ "$has_html" = 1 ]; then
        docker run --rm -v "${vol_name}:/app:ro" alpine:3 tar -C "/app/html/template/${from}" -cf - . | tar -xf - -C "$src/html" \
            || die "ボリュームから静的物を取り出せませんでした。何も変えていません。"
    else
        log "注意: ボリュームに html/template/${from} がありません（twig だけ移します）"
    fi
    [ -d "app/template/${from}" ] && cp -a "app/template/${from}/." "$src/app/"
    keep_current adopt "app/template/${from}"
    put_theme "$src" "adopted:${from}"
    # 元の twig は、original に移したので消す（同じものが 2 つあると、どちらを直せばよいか分からなくなる）
    if [ -d "app/template/${from}" ]; then
        rm -rf "app/template/${from}"
        log "app/template/${from} は ${appdir} へ移したので消しました（上の控えに入っています）"
    fi
    warn_hardcoded
    next_steps
    log "  ボリュームの html/template/${from} は、次の bin/upgrade.sh で消えます（もう使いません）"
    ;;

  diff)
    [ -f "$base" ] || die "まだ写していません。bin/theme.sh init"
    if [ "$(base_mode)" = package ]; then
        b="$(mktemp)"; o="$(mktemp)"
        tail -n +2 "$base" > "$b"
        pkg_manifest "$dir" "$appdir" > "$o"
        mine="$(changed "$b" "$o")"
        log "入れたテーマ: $(head -1 "$base" | cut -d= -f2-)"
        if [ -z "${2:-}" ]; then
            rm -f "$b" "$o"
            if [ -z "$mine" ]; then log "入れたときのままです"; exit 0; fi
            log "あなたが変えたファイル（$(printf '%s\n' "$mine" | wc -l | tr -d ' ') 件）:"
            printf '%s\n' "$mine" | sed 's/^/    /'
            log "テーマの新しい版と比べるなら: bin/theme.sh diff <新しい書庫>"
            exit 0
        fi
        new="$(extract_pkg "$2")"
        n="$(mktemp)"
        pkg_manifest "$new/html" "$new/app" > "$n"
        theirs="$(changed "$b" "$n")"
        both="$(LC_ALL=C comm -12 <(printf '%s\n' "$mine" | sed '/^$/d') <(printf '%s\n' "$theirs" | sed '/^$/d'))"
        rm -f "$b" "$o" "$n"
        log "新しい書庫: $(basename "$2")"
        echo
        if [ -n "$mine" ]; then
            log "あなたが変えたファイル（$(printf '%s\n' "$mine" | wc -l | tr -d ' ') 件）。入れ替えると消えます:"
            printf '%s\n' "$mine" | sed 's/^/    /'
        else
            log "あなたが変えたファイルはありません。そのまま入れ替えられます: bin/theme.sh install $2 --force"
        fi
        if [ -n "$theirs" ]; then
            echo
            log "新しい版で変わったファイル（$(printf '%s\n' "$theirs" | wc -l | tr -d ' ') 件）"
            printf '%s\n' "$theirs" | sed 's/^/    /'
        fi
        if [ -n "$both" ]; then
            echo
            log "**両方が変えたファイル（衝突）**。入れ替えたあと、あなたの変更を手で入れ直す必要があります:"
            printf '%s\n' "$both" | sed 's/^/    /'
        fi
        echo
        log "新しい版は ${new} に展開してあります（html/ と app/。比べ終わったら rm -rf）"
        log "  比べる: diff ${new}/html/<相対パス> ${dir}/<相対パス>   （app/ は ${appdir}）"
        exit 0
    fi
    if [ "$(grep -E '^ECCUBE_TEMPLATE_CODE=' .env 2>/dev/null | cut -d= -f2-)" != "$code" ]; then
        log "注意: 写しはありますが、.env の ECCUBE_TEMPLATE_CODE が ${code} ではないので使われていません"
    fi
    base_ver="$(head -1 "$base" | cut -d= -f2-)"
    cur_ver="$(core_version)"
    log "写した版: EC-CUBE ${base_ver}   いまの本体: EC-CUBE ${cur_ver:-?}"

    src="$(fetch_core_assets)"
    trap 'rm -rf "$src"' EXIT
    b="$(mktemp)"; o="$(mktemp)"; u="$(mktemp)"
    tail -n +2 "$base" > "$b"
    manifest "$dir" > "$o"
    manifest "$src" > "$u"

    mine="$(changed "$b" "$o")"
    theirs="$(changed "$b" "$u")"
    both="$(LC_ALL=C comm -12 <(printf '%s\n' "$mine" | sed '/^$/d') <(printf '%s\n' "$theirs" | sed '/^$/d'))"
    rm -f "$b" "$o" "$u"

    echo
    if [ -z "$mine" ] && [ -z "$theirs" ]; then
        log "差分なし。写したときのままで、本体も変わっていません。"
        exit 0
    fi
    if [ -n "$mine" ]; then
        log "あなたが変えたファイル（$(printf '%s\n' "$mine" | wc -l | tr -d ' ') 件）:"
        printf '%s\n' "$mine" | sed 's/^/    /'
    fi
    if [ -n "$theirs" ]; then
        echo
        log "本体側で変わったファイル（$(printf '%s\n' "$theirs" | wc -l | tr -d ' ') 件）。**いまはあなたの写しが勝っている**:"
        printf '%s\n' "$theirs" | sed 's/^/    /'
        log "  本体のものを取り込むなら（1 ファイルずつ、内容を見てから）:"
        log "    cp ${src}/<相対パス> ${dir}/<相対パス>"
    fi
    if [ -n "$both" ]; then
        echo
        log "**両方が変えたファイル（衝突）**。手で合わせる必要があります:"
        printf '%s\n' "$both" | sed 's/^/    /'
        log "  比べる: diff ${src}/<相対パス> ${dir}/<相対パス>"
    fi
    if [ -n "$theirs" ]; then
        echo
        log "取り込みが終わったら、写した版を更新する: bin/theme.sh init --force"
        log "（あなたの変更を先に退避すること。init --force は assets を本体で置き換える）"
        # 一時ディレクトリを見せたので、この実行では消さずに残す
        trap - EXIT
        log "本体の assets は ${src} に残してあります（不要なら rm -rf）。"
    fi
    ;;

  status)
    if [ "$(base_mode)" = package ]; then
        log "入れたテーマ: $(head -1 "$base" | cut -d= -f2-)  ファイル数: $(( $(wc -l < "$base") - 1 ))"
    elif [ -f "$base" ]; then
        log "写した版: $(head -1 "$base")  ファイル数: $(( $(wc -l < "$base") - 1 ))"
    else
        log "まだ写していません（bin/theme.sh init）"
    fi
    log "いまの本体: EC-CUBE $(core_version || echo '?')"
    log ".env の ECCUBE_TEMPLATE_CODE: $(grep -E '^ECCUBE_TEMPLATE_CODE=' .env 2>/dev/null | cut -d= -f2- || echo '未設定（default）')"
    foreign="$(theme_unsaved_dirs "${proj}_eccube_app")"
    if [ -n "$foreign" ]; then
        log "注意: 本体のボリュームにしか無いテーマがあります（bin/upgrade.sh で消えます。backup にも入りません）:"
        printf '%s\n' "$foreign" | sed 's/^/    /'
        log "  残すなら: bin/theme.sh adopt <コード>"
    fi
    ;;

  *)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac

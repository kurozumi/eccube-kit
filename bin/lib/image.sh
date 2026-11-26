#!/usr/bin/env bash
# 配布イメージ（レジストリから pull）とローカル build を切り替えるための共通処理。
#
# **この環境は 2 通りの使われ方をする。**
#   1) 自分で build する（改造する人・開発）    … ECCUBE_IMAGE 未設定
#   2) 配布イメージを pull する（使うだけの人） … ECCUBE_IMAGE=ghcr.io/<owner>/<repo>/ec-cube:4.3-v1.0.0
#
# 起動系のスクリプトは `image_provision` を呼ぶだけでよく、どちらなのかを
# 自分で判断しなくてよい。
#
# **`up -d --build` を直接書かないこと。** 配布イメージを使っている利用者の
# 環境でそれを打つと、pull したイメージをローカル build で上書きしてしまう。
# 利用者の手元には EC-CUBE を取得できる composer 環境があるとは限らず、
# **成功しても中身が配布物と別物になる**（本体の取得タイミングが違うため）。
#
#   source "$(dirname "$0")/lib/image.sh"
#   image_provision "${dc[@]}" || ...

# 設定値を解決する。シェルの環境変数を優先し、無ければ .env を見る。
# （compose 自身は .env を読むが、スクリプト側は読まないため）
# ボリュームへ戻したファイルの持ち主（uid:gid）。.env の PUID / PGID（entrypoint が www-data をそれに合わせる）、
# 無ければ php:*-fpm の www-data（33）。数字でないものは使わない（chown に渡すので）
app_owner() { # app_owner → "1000:1000" / "33:33"
    local u g
    u="$(env_get PUID)"; g="$(env_get PGID)"
    case "$u" in ''|*[!0-9]*) u=33 ;; esac
    case "$g" in ''|*[!0-9]*) g="$u" ;; esac
    printf '%s:%s' "$u" "$g"
}

env_get() { # env_get KEY
    local key="$1" val
    # 間接展開で見る。**printenv は export されていない変数を見落とす**ので、
    # スクリプトの中で設定した値が拾えず、.env の古い値が勝ってしまう。
    val="${!key-}"
    if [ -n "$val" ]; then
        printf '%s' "$val"
        return 0
    fi
    [ -f .env ] || return 0
    # **`|| true` と `return 0` を外さないこと。** 呼び出し側は set -euo pipefail
    # なので、キーが無いときの grep の失敗が pipefail でパイプライン全体の失敗に
    # なり、`x="$(env_get FOO)"` の 1 行でスクリプトが黙って死ぬ。
    grep -E "^${key}=" .env 2>/dev/null | head -1 | cut -d= -f2- | sed 's/[[:space:]]*$//' || true
    return 0
}

# compose が使うイメージ参照。compose.yaml の既定値と必ず揃えること。
image_ref() {
    local ref
    ref="$(env_get ECCUBE_IMAGE)"
    printf '%s' "${ref:-eccube-ec-cube}"
}

# ECCUBE_IMAGE がレジストリを指しているか（＝pull できるか）。
#
# docker と同じ判定にする: 最初の要素にドットかコロンがあるか localhost なら
# レジストリホスト、それ以外は Docker Hub 上の名前とみなされる。ローカル build の
# 既定値 `eccube-ec-cube:local` はスラッシュを含まないのでここで false になる。
image_uses_registry() {
    local ref first
    ref="$(image_ref)"
    case "$ref" in
        */*) first="${ref%%/*}" ;;
        *)   return 1 ;;
    esac
    case "$first" in
        *.*|*:*|localhost) return 0 ;;
    esac
    # Docker Hub（`owner/name`）も pull できる
    return 0
}

# 起動前にイメージを用意する。レジストリ参照なら pull、そうでなければ build。
#   image_provision <docker compose の呼び出し…>
# 失敗時は非 0 を返すだけで終了はしない（呼び出し側に .env を戻す処理があるため）。
image_provision() { # image_provision docker compose [-f ...]
    if image_uses_registry; then
        echo "[image] 配布イメージを取得します: $(image_ref)"
        "$@" pull ec-cube
    else
        echo "[image] イメージをビルドします（EC-CUBE の取得で数分かかります）..."
        "$@" build
    fi
}

# composer の制約から EC-CUBE の系列を取り出す。
#   ~4.3.0 → 4.3 / ^4.4.1 → 4.4 / 4.2.* → 4.2
image_series() { # image_series <制約>
    printf '%s' "$1" | sed -E 's/^[^0-9]*//; s/^([0-9]+\.[0-9]+).*/\1/'
}

# 系列ごとの phpredis。**両立しないので系列で決まる**（docker/php/Dockerfile 参照）。
#   4.2 / 4.3（Symfony Cache 6.4） … 6.0.x（6.1+ は hSet のシグネチャ変更で衝突）
#   4.4（Symfony Cache 7.4）       … 6.1 以上（symfony/cache が ext-redis <6.1 を conflict）
# **.github/build-matrix.json（焼く組の一覧）と揃えること。** kit-e2e がずれを落とす。
image_phpredis_for_series() { # image_phpredis_for_series <系列>
    case "$1" in
        4.4) printf '6.3.0' ;;
        *)   printf '6.0.2' ;;
    esac
}

# 系列ごとの**既定の** PHP（`-php` 無しの短いタグが指すもの）。4.4 は土台が Symfony 7.4
# なので 8.2 以上が要る。他の PHP は配布タグの `-php8.x` で選ぶ（image_php_versions_for_series）。
# **.github/build-matrix.json（焼く組の一覧）と揃えること。** kit-e2e がずれを落とす。
#
# **8.2 は 2026-12-31 でセキュリティサポートが切れる。** 4.3 は対応の上限の 8.3（2027-12-31 まで）を
# 既定にした。4.2 は上流の対応が 8.1 までで、8.2 より上を配っていないので 8.2 のまま
# （4.2 を使い続けるなら、サポートの切れた PHP で動かすことになる）。
image_php_for_series() { # image_php_for_series <系列>
    case "$1" in
        4.2) printf '8.2' ;;
        *)   printf '8.3' ;;
    esac
}

# 系列ごとに配っている PHP（空白区切り）。上流の対応一覧に従う（4.2 の 8.2 は一覧の外だが
# composer の制約には入り、v1.0.0 から配っている）。知らない系列は空を返す。
# **.github/build-matrix.json（焼く組の一覧）と揃えること。** kit-e2e がずれを落とす。
image_php_versions_for_series() { # image_php_versions_for_series <系列>
    case "$1" in
        4.2) printf '8.1 8.2' ;;
        4.3) printf '8.1 8.2 8.3' ;;
        4.4) printf '8.2 8.3 8.4 8.5' ;;
        *)   printf '' ;;
    esac
}

# その系列で使える PHP か。**知らない系列は通す**（判定できないことで作業を止めない。
# 新しい系列の対応は composer と上流の README が正しい）。
image_php_supported() { # image_php_supported <系列> <PHP>
    local list
    list="$(image_php_versions_for_series "$1")"
    [ -z "$list" ] && return 0
    case " $list " in *" $2 "*) return 0 ;; esac
    return 1
}

# 上げた先（切り替えた先）で使う PHP を決める。
#   <指定> があれば、それがその系列で使えるかだけ見る（使えなければ説明して 1）
#   無ければ <いまの PHP> のまま。**ただし新しい系列で使えないなら、その系列の既定に寄せる**
#   （4.2 の 8.1 から 4.4 へ上げると、4.4 は 8.2 以上なので 8.1 では build も pull もできない）
# 決まった PHP を標準出力へ。説明は標準エラーへ。
image_resolve_php() { # image_resolve_php <系列> <指定（空可）> <いまの PHP（空可）>
    local series="$1" want="$2" cur="$3"
    if [ -n "$want" ]; then
        if image_php_supported "$series" "$want"; then
            printf '%s' "$want"
            return 0
        fi
        echo "エラー: EC-CUBE ${series} 系は PHP ${want} に対応していません（使えるのは: $(image_php_versions_for_series "$series")）。" >&2
        return 1
    fi
    if [ -n "$cur" ] && image_php_supported "$series" "$cur"; then
        printf '%s' "$cur"
        return 0
    fi
    if [ -n "$cur" ]; then
        echo "注意: いまの PHP ${cur} は EC-CUBE ${series} 系で使えないので、$(image_php_for_series "$series") にします（--php=<版> で選べます）。" >&2
    fi
    image_php_for_series "$series"
}

# 動いているコンテナの PHP（8.3 のような major.minor）を、**イメージの**環境変数から読む。
# 公式の php イメージは ENV PHP_VERSION=8.3.36 を持つ。コンテナ側の環境変数は見ない
# （compose の env_file が .env の PHP_VERSION=8.2 を流し込むと、実物と違う値が読めてしまう）。
# 読めなければ空（失敗で止めない。呼び出し側はタグや .env へ落とす）。
image_php_of_container() { # image_php_of_container <コンテナ ID>
    local img
    img="$(docker inspect --format '{{.Image}}' "$1" 2>/dev/null)" || return 0
    image_php_of_image "$img"
}

# イメージ（ID か参照）の PHP（8.3 のような major.minor）。読めなければ空。
image_php_of_image() { # image_php_of_image <イメージ>
    docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null |
        sed -n 's/^PHP_VERSION=\([0-9]*\.[0-9]*\).*/\1/p' | head -1 || true
}

# ── 引いたイメージで PHP のマイナー版が変わるなら止める（勝手に上げない）──
# 短いタグ（ec-cube:4.3）は系列の既定の PHP を指す。既定を動かすと（4.3 は 8.2 → 8.3）、翌朝の焼き直しを
# deploy / publish が引いた時点で、**店の PHP のマイナー版が黙って変わる**。新しい PHP で動かないプラグインが
# あれば、それで店が落ちる。PHP を変えるのは upgrade.sh --php= だけにする（動くかを確かめ、だめなら戻す）。
#   image_php_drift_guard <引く前のイメージ ID（空可）> <接頭辞> [動いているコンテナ ID]
#   0 … 変わらない・前が無い・読めない（止めない。判定できないことで作業を止めない）
#   1 … 変わる。**手元のタグを引く前のイメージに戻してから**説明を出す（戻さないと、次の up -d で黙って切り替わる）
# パッチ版（8.3.36 → 8.3.37）は見ない。それは届けたいもの。
image_php_drift_guard() {
    local before="$1" p="$2" cid="${3:-}" ref after old new pinned series ver
    [ -n "$before" ] || return 0
    ref="$(image_ref)"
    after="$(docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null || true)"
    [ -n "$after" ] && [ "$after" != "$before" ] || return 0
    old="$(image_php_of_image "$before")"
    new="$(image_php_of_image "$after")"
    [ -n "$old" ] && [ -n "$new" ] && [ "$old" != "$new" ] || return 0
    docker tag "$before" "$ref" 2>/dev/null || echo "${p}注意: 手元のタグを元のイメージに戻せませんでした（${ref}）。" >&2
    pinned="$(image_retag_php "$ref" "$old")"
    series="$(printf '%s' "${ref##*:}" | sed -nE 's/^([0-9]+\.[0-9]+).*/\1/p')"
    ver=""; [ -z "$cid" ] || ver="$(image_eccube_of_container "$cid")"
    {
        echo "${p}止めました: 新しいイメージは PHP ${new} です（いまは PHP ${old}）。PHP のマイナー版は勝手に上げません。"
        echo "${p}  何も変えていません。お店は PHP ${old} のまま動いています（手元のタグも元に戻しました）。"
        echo "${p}  ${ref} は系列の既定の PHP を指すタグで、既定が ${new} に変わりました。どちらかを選んでください:"
        if [ -n "$series" ] && image_php_supported "$series" "$old"; then
            echo "${p}  - PHP ${old} のままにする: .env の ECCUBE_IMAGE を ${pinned} にして、もう一度（パッチは届き続けます）"
        else
            echo "${p}  - PHP ${old} は ${series:-この} 系列ではもう焼いていません（パッチが届かない）。上げてください"
        fi
        echo "${p}  - PHP ${new} に上げる: bin/upgrade.sh ${ver:-<いまの EC-CUBE の版>} --php=${new}（本番は --prod も）"
        echo "${p}    上げる前にプラグインが読めるかを確かめ、上げたあと開かなければ自動で戻します。先に検証の環境で試すのが安全です"
    } >&2
    return 1
}

# 動いているコンテナの EC-CUBE のバージョン（4.3.1 など）。読めなければ空。
# **版の形をしていなければ捨てる。** php の CLI は警告や致命的エラーを標準出力に出すので、autoload が
# 読めないと「PHP Warning: require(...)」が版として返ってくる。
image_eccube_of_container() { # image_eccube_of_container <コンテナ ID>
    local v
    v="$(docker exec -u www-data "$1" php -r 'require "vendor/autoload.php"; echo Eccube\Common\Constant::VERSION;' 2>/dev/null || true)"
    case "$v" in
        [0-9]*.[0-9]*) case "$v" in *[!0-9A-Za-z.+-]*) ;; *) printf '%s' "$v" ;; esac ;;
    esac
}

# PHP のセキュリティサポートが終わる日（https://www.php.net/supported-versions.php ）。
# **配る PHP を足したら、ここにも足す。** 知らない版は空（警告しない）。
# security-scan.yml は endoflife.date を見ているが、店の手元から毎回問い合わせるのは避けた（オフラインでも出したい）。
image_php_eol() { # image_php_eol <PHP>
    case "$1" in
        8.1) printf '2025-12-31' ;;
        8.2) printf '2026-12-31' ;;
        8.3) printf '2027-12-31' ;;
        8.4) printf '2028-12-31' ;;
        8.5) printf '2029-12-31' ;;
        *)   printf '' ;;
    esac
}

# 知らせ始める日（期限の年の 10 月 1 日）。期限を知らない版は空。
# 日付の計算はしない（BSD と GNU の date が違う）。YYYY-MM-DD は文字列の比較で前後が分かる。
image_php_eol_warn_from() { # image_php_eol_warn_from <PHP>
    local eol
    eol="$(image_php_eol "$1")"
    [ -n "$eol" ] && printf '%s-10-01' "${eol%%-*}"
    return 0
}

# PHP の版を比べる（8.10 > 8.9。文字列で比べると逆になる）。a が b より新しければ 0。
image_php_newer() { # image_php_newer <a> <b>
    local a1="${1%%.*}" a2="${1#*.}" b1="${2%%.*}" b2="${2#*.}"
    [ "$a1" -gt "$b1" ] 2>/dev/null && return 0
    [ "$a1" -eq "$b1" ] 2>/dev/null && [ "$a2" -gt "$b2" ] 2>/dev/null && return 0
    return 1
}

# 勧めてよい PHP か: いまより新しく、それ自体はまだ知らせる時期に入っていない
_image_php_recommendable() { # _image_php_recommendable <候補> <いまの PHP> <今日>
    local f
    f="$(image_php_eol_warn_from "$1")"
    [ -n "$f" ] && [[ "$3" < "$f" ]] && image_php_newer "$1" "$2"
}

# PHP のサポートが切れている・期限の年の 10 月以降なら、知らせる文を標準出力へ（それ以外は空）。
# 案内する先:
#   同じ系列に、**それ自体はまだ知らせる時期に入っていない**新しい PHP がある → 系列の既定（無理なら、その中で
#     いちばん新しいもの）へ --php で。期限間近の版へ移しても、すぐまた同じ注意が出るので勧めない（4.2 の 8.1 → 8.2）
#   無い（4.2 の 8.2、4.3 の 8.3 の終わり） → 系列を上げる
# 版はいま動いているものを書く。**配布イメージでは本体の版も変わりうる**（追跡タグ 4.3-php8.2 → 4.3-php8.3 は系列の
# 最新のパッチ、固定タグ 4.3-php8.2-v1.0.12 → 4.3-php8.3-v1.0.12 はそのリリースの時点の版）。
image_php_eol_notice() { # image_php_eol_notice <PHP> <EC-CUBE のバージョン（空可）> [今日 YYYY-MM-DD]
    local php="$1" ver="$2" today="${3:-$(date +%F)}" series eol from v best="" def ok
    eol="$(image_php_eol "$php")"
    [ -n "$eol" ] || return 0
    from="$(image_php_eol_warn_from "$php")"
    [[ "$today" < "$from" ]] && return 0
    series="$(image_series "$ver")"
    if [[ "$today" > "$eol" ]]; then
        echo "PHP ${php} のセキュリティサポートは ${eol} で終わりました。PHP 自体の脆弱性はもう直りません。"
    else
        echo "PHP ${php} のセキュリティサポートは ${eol} で終わります。"
    fi
    for v in $(image_php_versions_for_series "$series"); do
        if _image_php_recommendable "$v" "$php" "$today" && { [ -z "$best" ] || image_php_newer "$v" "$best"; }; then best="$v"; fi
    done
    def="$(image_php_for_series "$series")"
    if [ -n "$best" ] && _image_php_recommendable "$def" "$php" "$today"; then best="$def"; fi
    if [ -n "$best" ]; then
        echo "EC-CUBE ${series} 系のまま PHP ${best} に上げられます: bin/upgrade.sh ${ver} --php=${best}（本番は --prod も付ける。配布イメージでは本体の版も変わりうるので、upgrade.sh が出す版を確かめる）"
    elif [ -n "$series" ]; then
        echo "EC-CUBE ${series} 系には、これより長くサポートされる PHP がありません。EC-CUBE を新しい系列へ上げてください。"
    fi
    echo "手順: docs/upgrade.md「PHP のサポートが切れるとき」"
}

# deploy の最後と doctor が使う。動いている ec-cube の PHP を見て、知らせることがあれば <接頭辞> を付けて出す。
# **EC-CUBE の版は、知らせる時期のときだけ読む**（コンテナの中で php を起動するので、毎日の deploy で無駄に打たない）。
# 何も出さなかったら 1（doctor が warn を立てるのに使う）。失敗では止めない。
image_php_eol_report() { # image_php_eol_report <コンテナ ID> <接頭辞>
    local cid="$1" prefix="$2" php from notice
    [ -n "$cid" ] || return 1
    php="$(image_php_of_container "$cid")"
    from="$(image_php_eol_warn_from "$php")"
    [ -n "$from" ] || return 1
    [[ "$(date +%F)" < "$from" ]] && return 1
    notice="$(image_php_eol_notice "$php" "$(image_eccube_of_container "$cid")")"
    [ -n "$notice" ] || return 1
    printf '%s\n' "$notice" | sed "s/^/${prefix}/"
}

# 配布イメージの参照の PHP を差し替える。タグは「<系列>[-php<版>][-<固定の印>]」の形で、
# ワークフローは -php 付きと無しの両方に固定の印（-vX.Y.Z / 日付 / sha）を打っている。
#   :4.3-php8.1        + 8.3 → :4.3-php8.3
#   :4.3               + 8.3 → :4.3（追跡タグで、8.3 が 4.3 の既定。短いまま）
#   :4.3               + 8.2 → :4.3-php8.2
#   :4.3-v1.0.12       + 8.3 → :4.3-php8.3-v1.0.12
#   :4.3-v1.0.12       + 8.2 → :4.3-php8.2-v1.0.12
# **固定タグでは -php を必ず明示する。** -php 無しの固定タグが指す PHP は「焼いた時点の既定」で、
# 既定は動く（4.3 は v1.0.12 まで 8.2、以後 8.3）。いまの既定と同じだからと短いまま残すと、
# 4.3-v1.0.12（中身は 8.2）を 8.3 のつもりで使い続けることになる。
# 系列で始まらないタグは触らない（image_retag_series と同じ理由）。
image_retag_php() { # image_retag_php <参照> <PHP>
    local ref="$1" php="$2" name tag series rest
    case "$ref" in
        *:*) ;;
        *) printf '%s' "$ref"; return 0 ;;
    esac
    name="${ref%:*}"
    tag="${ref##*:}"
    case "$tag" in
        [0-9]*.[0-9]*) ;;
        *) printf '%s' "$ref"; return 0 ;;
    esac
    series="$(printf '%s' "$tag" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
    rest="${tag#"$series"}"
    case "$rest" in
        -php[0-9]*)
            rest="$(printf '%s' "$rest" | sed -E "s/^-php[0-9]+\.[0-9]+/-php${php}/")" ;;
        "")
            [ "$php" = "$(image_php_for_series "$series")" ] || rest="-php${php}" ;;
        *)
            rest="-php${php}${rest}" ;;
    esac
    printf '%s:%s%s' "$name" "$series" "$rest"
}

# 配布イメージの参照から PHP を読む。分からなければ空。
#   :4.3-php8.1 → 8.1 / :4.3 → 系列の既定 / :4.3-v1.0.12 → 空（焼いた時点の既定は読めない）
# **当てにするのは、動いているイメージが無いときだけ。** 実物は image_php_of_container で読む。
image_ref_php() { # image_ref_php <参照>
    local tag series
    case "$1" in *:*) ;; *) return 0 ;; esac
    tag="${1##*:}"
    case "$tag" in [0-9]*.[0-9]*) ;; *) return 0 ;; esac
    series="$(printf '%s' "$tag" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
    case "$tag" in
        *-php[0-9]*) printf '%s' "$tag" | sed -E 's/.*-php([0-9]+\.[0-9]+).*/\1/' ;;
        "$series")   image_php_for_series "$series" ;;
        *)           return 0 ;;
    esac
}

# ── バージョン制約が本当に解決できるかを、build を始める前に確かめる ──
#
# **安定版の無い系列の `~4.4.0` は解決できない。** 4.4 は Packagist に alpha しか無い
# （4.4.0-alpha / 4.4.0-alpha-1。2026-09-25）。create-project は stability を指定しないので
# 安定版しか探さず、build に入ってから composer が
# 「Could not find package ec-cube/ec-cube with version ~4.4.0」で落ちるまで数分かかり、
# .env は書き換わったままになる。ここで 1 秒で止めて、打ち直す形を出す。
#
# **alpha / beta / RC は安定版として数えない。** 以前は「系列で始まる版があるか」だけを見ていたので、
# alpha が出た時点で ~4.4.0 を通してしまい、まさに上の落ち方をしていた。-p1 のような
# パッチ版（4.3.1-p1）は安定版。
#
# 制約の完全な解釈は composer の仕事なのでやらない。見るのは「その系列に何があるか」だけ:
#   版そのもの・@stability 付き      → 通す（4.4.0-alpha-1、~4.4.0@alpha など。composer に任せる）
#   系列に安定版がある              → 通す（~4.3.0 など）
#   系列に安定版が無く、プレリリースか dev がある → 打てる形を並べて止める
#   系列そのものが無い              → ある系列を並べて止める
#
# **問い合わせに 1 つでも失敗したら黙って通す。** 安定版と dev で JSON が別々にあり、片方だけ
# 落ちると「dev が無い」と誤って判定して、正しい指定を止めてしまう（実際に踏んだ）。
# 判定できないことで作業を止めない。
image_check_version() { # image_check_version <制約> [再実行の例] → 解決できなさそうなら説明して 1
    local want="$1" hint="${2:-}" series url stable_json dev_json stable pre dev all_vers
    series="$(image_series "$want")"
    case "$series" in [0-9]*.[0-9]*) ;; *) return 0 ;; esac   # 系列を取り出せない形は composer に任せる
    url="https://repo.packagist.org/p2/ec-cube/ec-cube"
    stable_json="$(curl -fsSL --max-time 10 "${url}.json" 2>/dev/null)" || return 0
    dev_json="$(curl -fsSL --max-time 10 "${url}~dev.json" 2>/dev/null)" || return 0
    vers_of() { printf '%s' "$1" | grep -o '"version":"[^"]*"' | cut -d'"' -f4; }
    stable="$(vers_of "$stable_json" | grep -cE "^${series}\.[0-9]+(\.[0-9]+)?(-p[0-9]+)?$" || true)"
    pre="$(vers_of "$stable_json" | grep -iE "^${series}\.[0-9]+.*-(alpha|beta|rc)" | head -1 || true)"
    dev="$(vers_of "$dev_json" | grep -c "^${series}\.x-dev$" || true)"
    [ -n "$(vers_of "$stable_json" | head -1)" ] || return 0   # 中身が読めない → 通す

    case "$want" in
        *@*) return 0 ;;   # stability を明示している。composer に任せる
    esac
    # 版そのもの（4.4.0-alpha-1 など）。あれば通す
    # 一覧は変数に取ってから見る（pipefail の下で grep -q が先に終わると、前の cut が SIGPIPE で落ちて「無い」になる）
    all_vers="$(vers_of "$stable_json")"
    if printf '%s\n' "$all_vers" | grep -qxF "$want"; then
        return 0
    fi

    case "$want" in
        *x-dev|dev-*)   # すでに dev 指定。その dev があるかだけ見る
            [ "$dev" != 0 ] && return 0
            {
                echo "エラー: ${want} は上流にありません。"
                printf '       入れられる dev: %s\n' "$(vers_of "$dev_json" | grep -E 'x-dev$' | head -4 | tr '\n' ' ')"
            } >&2
            return 1 ;;
    esac
    [ "$stable" != 0 ] && return 0
    if [ "$dev" != 0 ] || [ -n "$pre" ]; then
        {
            echo "エラー: EC-CUBE ${series} は **まだ正式版がありません**（Packagist に安定版が 1 つも無い）。"
            echo "       ${want} は解決できないので、build を始めずに止めました（.env は変えていません）。"
            echo
            if [ -n "$pre" ]; then
                echo "       プレリリースを入れるなら、版をそのまま書きます（最新: ${pre}）:"
                echo
                echo "         ${hint:-<コマンド>} ${pre}"
                echo
            fi
            if [ "$dev" != 0 ]; then
                echo "       上流の ${series} ブランチの最新を入れるなら:"
                echo
                echo "         ${hint:-<コマンド>} ${series}.x-dev"
                echo
            fi
            echo "       **x-dev は動く的なので、build するたび中身が変わります**（同じ指定でも別のコミットになる）。"
            echo "       本番なら配布イメージのタグを固定するほうが安全です（docs/install.md のタグ表）。"
        } >&2
        return 1
    fi
    {
        echo "エラー: EC-CUBE ${series} は上流にありません（${want} は解決できません）。"
        printf '       入れられる系列: %s\n' "$(vers_of "$stable_json" | sed -n 's/^\([0-9]*\.[0-9]*\)\..*/\1/p' | sort -u -V | tr '\n' ' ')"
    } >&2
    return 1
}

# 参照のタグに入っている系列だけを差し替える。
#   ghcr.io/o/r/ec-cube:4.3-v1.0.0 + 4.4 → ghcr.io/o/r/ec-cube:4.4-v1.0.0
#   ghcr.io/o/r/ec-cube:4.3        + 4.4 → ghcr.io/o/r/ec-cube:4.4
#   ghcr.io/o/r/ec-cube:4.3-php8.1 + 4.4 → ghcr.io/o/r/ec-cube:4.4-php8.1（**無いタグになりうる。**
#     新しい系列にその PHP が無ければ pull で止まるので、.env の -php を新しい系列にあるものへ）
# 系列で始まらないタグ（latest など）は**触らない**。何を指しているか分からない
# ものを機械的に書き換えると、別系列のイメージを黙って掴ませることになる。
image_retag_series() { # image_retag_series <参照> <系列>
    local ref="$1" series="$2" name tag
    case "$ref" in
        *:*) ;;
        *) printf '%s' "$ref"; return 0 ;;
    esac
    name="${ref%:*}"
    tag="${ref##*:}"
    case "$tag" in
        [0-9]*.[0-9]*) printf '%s:%s' "$name" "$(printf '%s' "$tag" | sed -E "s/^[0-9]+\.[0-9]+/${series}/")" ;;
        *) printf '%s' "$ref" ;;
    esac
}

# イメージに焼かれている EC-CUBE のバージョンを読む（取得できなければ空）。
#
# 配布イメージを使うとき、**.env の ECCUBE_VERSION は「何を build するか」でしか
# なく、実際に動くのはイメージに焼かれたバージョン**になる。両者は簡単にずれるので、
# 上げたあとに実物を確かめられるようにしておく。
image_baked_version() { # image_baked_version <参照>
    docker run --rm --entrypoint sh "$1" -c \
        'php -r "require \"vendor/autoload.php\"; echo Eccube\\Common\\Constant::VERSION;"' 2>/dev/null || true
}

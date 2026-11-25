#!/usr/bin/env bash
# セキュリティの点検と、不審な兆候が見えたときの緊急停止（docs/security.md）。
#
#   bin/security.sh check [--days=N]   不審なものを挙げる（読むだけ。既定は直近 7 日）
#   bin/security.sh close [--hard]     お店を閉じて、調査用の控えを var/incident/ に取る
#   bin/security.sh open               調査が終わったら開け直す（プロジェクト名を打って確かめる）
#
# check が見るもの（EC-CUBE セキュリティ対策ガイドラインの「ログ監視」「不審なデータの確認」）:
#   - 管理者: 2 段階認証が OFF の人、最近作られた人
#   - 管理画面のログイン: 失敗の多さ、業務時間の外のログイン（.env の SECURITY_HOURS。既定 8-21）
#   - 会員・注文: 名前・住所・メッセージなどにタグや URL が入ったもの
#   - ページ管理の <head> に足したスクリプト、最近入ったプラグイン
#   - git に入っていない変更（管理画面や侵入者が書き換えたファイル）と、その中のスクリプトらしいもの
#   - nginx のログ: レート制限に当たった数、ログインの連打、管理画面の URL の探索
# 終わりの値: 0 = 要確認なし、2 = 要確認あり、1 = 見られなかったものがある。cron で回すなら
#   0 7 * * * cd /path/to/myshop && bin/security.sh check > var/security-check.log 2>&1 || <通知するコマンド>
#
# close は「迷わず閉じる」ためのもの:
#   1. お客さんにメンテナンス表示を出す（管理画面は開いたまま。本体の作り）
#   2. --hard なら nginx も止める（管理者のアカウントが乗っ取られた疑いがあるとき。サイトごと見えなくなる）
#   3. ログ・git の状態・check の結果を var/incident/<日時>/ に控える。コンテナは消さない（ログが消える）
# close のあいだは bin/deploy.sh と bin/publish.sh が止まる（止めた nginx を起こさないため）。
set -euo pipefail
case "${1:-}" in -h|--help|"") awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
cd "$(dirname "$0")/.."
# shellcheck source=lib/guard.sh
. bin/lib/guard.sh

MAINT=/var/www/html/.maintenance
env_val() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"' \r" || true; }
dc() { docker compose "$@"; }
ec_running() { [ -n "$(dc ps -q --status running ec-cube 2>/dev/null || true)" ]; }
# .git はフォルダとは限らない（worktree や submodule ではファイル）
in_git() { command -v git >/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1; }
maint_content() { dc exec -T ec-cube sh -c "cat $MAINT 2>/dev/null" 2>/dev/null | tr -d '\r' || true; }

cmd="$1"; shift
days=7; hard=0
for a in "$@"; do
    case "$a" in
        --days=*) days="${a#--days=}" ;;
        --hard) hard=1 ;;
        *) echo "知らない引数: $a（bin/security.sh --help）" >&2; exit 1 ;;
    esac
done
case "$days" in ''|*[!0-9]*) echo "--days は数で（例 --days=30）" >&2; exit 1 ;; esac

# ---------------------------------------------------------------- check
# 全部を出し終えてから「要確認」を数える。見られなかったものがあれば $tmp/unknown を置く
check() {
    local tmp rc need
    tmp="$(mktemp -d)"
    check_body "$tmp" > "$tmp/all" 2>&1 || true
    cat "$tmp/all"
    need="$(grep -c '\[要確認\]' "$tmp/all" || true)"
    echo
    if [ -f "$tmp/unknown" ]; then
        echo "結果: 見られなかったものがあります（[不明]）。要確認 ${need:-0} 件"; rc=1
    elif [ "${need:-0}" -gt 0 ]; then
        echo "結果: 要確認 ${need} 件。身に覚えが無いものは docs/security.md「不審な兆候が見えたら」へ"; rc=2
    else
        echo "結果: 要確認なし"; rc=0
    fi
    rm -rf "$tmp"
    return "$rc"
}

check_body() {
    local tmp="$1" route hours
    route="$(env_val ECCUBE_ADMIN_ROUTE)"; route="${route:-admin}"
    hours="$(env_val SECURITY_HOURS)"; hours="${hours:-8-21}"
    echo "# セキュリティの点検（直近 ${days} 日。$(date '+%Y-%m-%d %H:%M')）"

    # DB（ec-cube のコンテナの中で、PDO で読むだけ）
    if ec_running; then
        dc exec -T -e SEC_DAYS="$days" -e SEC_HOURS="$hours" ec-cube php < bin/lib/security-check.php > "$tmp/db" 2>"$tmp/db.err" \
            || : > "$tmp/unknown"
        cat "$tmp/db"
        [ -s "$tmp/db" ] || { echo "## DB"; echo "  [不明] 点検を流せませんでした: $(head -3 "$tmp/db.err" | tr '\n' ' ')"; : > "$tmp/unknown"; }
    else
        echo "## DB"; echo "  [不明] ec-cube が動いていないので、DB を見られませんでした"; : > "$tmp/unknown"
    fi

    # git に入っていない変更
    echo "## git に入っていない変更（管理画面や侵入者が書き換えたファイル）"
    if in_git; then
        git status --porcelain --untracked-files=all -- app html/user_data > "$tmp/git" 2>/dev/null || true
        if [ ! -s "$tmp/git" ]; then
            echo "  [ok] 無し"
        else
            local n=0 st f
            while IFS= read -r line; do
                st="${line:0:2}"; f="${line:3}"; f="${f#\"}"; f="${f%\"}"
                n=$((n + 1)); [ "$n" -le 20 ] || continue
                local note=""
                # 中身にスクリプトらしいもの（カード情報を抜く改ざんの典型）があれば添える
                if [ -f "$f" ] && grep -qiE 'eval\(|atob\(|String\.fromCharCode|document\.write\(|<script[^>]*src=["'"'"']?https?://' "$f" 2>/dev/null; then
                    note=" … 外のスクリプトや難読化らしいものを含む"
                fi
                echo "  [要確認] ${st} ${f}${note}"
            done < "$tmp/git"
            [ "$n" -le 20 ] || echo "  [要確認] ほかに $((n - 20)) 件（git status で全部見る）"
            echo "  （画面から自分で直したものなら git に入れる: docs/handbook.md。身に覚えが無ければ docs/security.md「不審な兆候が見えたら」）"
        fi
    else
        echo "  [不明] git のリポジトリではないので、変更を見られません"; : > "$tmp/unknown"
    fi

    # nginx のログ（compose のログ。json-file は 10MB × 5 世代までなので、古いものは無いことがある）
    echo "## nginx のログ（直近 ${days} 日。残っている分だけ）"
    if dc logs --no-color --no-log-prefix --since "$((days * 24))h" nginx > "$tmp/ng" 2>/dev/null && [ -s "$tmp/ng" ]; then
        # combined 形式: $1 が IP（real_ip 済み）、$6 が "メソッド、$7 がパス、$9 が状態
        awk -v route="$route" -f bin/lib/security-nginx.awk "$tmp/ng"
    else
        echo "  [不明] nginx のログを読めませんでした（動いていない、または残っていない）"; : > "$tmp/unknown"
    fi
    echo "  （決済のエラーの多発はプラグインごとに出る場所が違うので、ここでは見ていません。決済サービスの管理画面で見る）"

}

# ---------------------------------------------------------------- close
close() {
    local ts dir prev
    ts="$(date +%Y%m%d-%H%M%S)"; dir="var/incident/${ts}"
    mkdir -p "$dir"
    if ec_running; then
        prev="$(maint_content)"
        [ -z "$prev" ] || printf '%s\n' "$prev" > "$dir/maintenance.before"
        # ':' を入れない。':' の後ろは表示を素通りする合い言葉として読まれる（本体の index.php）
        dc exec -T ec-cube sh -c "printf incident > $MAINT && chown www-data:www-data $MAINT 2>/dev/null || true"
        echo "[security] メンテナンス表示を出しました（お客さんには「メンテナンス中」。管理画面は開いたまま）"
    elif [ "$hard" = 0 ]; then
        echo "[security] ec-cube が動いていないので、メンテナンス表示を出せません。入口ごと止めるなら --hard" >&2
        exit 1
    fi
    if [ "$hard" = 1 ]; then
        dc stop nginx
        echo "[security] nginx を止めました（サイトは外から見えません。管理画面も）"
    fi

    echo "[security] 調査用の控えを ${dir}/ に取ります..."
    dc ps -a > "$dir/ps.txt" 2>&1 || true
    dc logs --no-color --timestamps > "$dir/compose.log" 2>&1 || true
    if ec_running; then dc cp ec-cube:/var/www/html/var/log "$dir/eccube-log" >/dev/null 2>&1 || true; fi
    if in_git; then
        { git log -5 --oneline; echo; git status --porcelain --untracked-files=all; echo; git diff --stat; } > "$dir/git.txt" 2>&1 || true
        git diff > "$dir/git.diff" 2>/dev/null || true
    fi
    check > "$dir/check.txt" 2>&1 || true
    chmod -R go-rwx "$dir" 2>/dev/null || true
    echo "[security] 控えました（個人情報を含みます。渡すのは調査をお願いする人だけに）:"
    ls -1 "$dir" | sed 's/^/             /'
    cat <<EOF

次にやること（docs/security.md「不審な兆候が見えたら」）:
  1. 専門家（保守をお願いしている人）に連絡して、${dir}/ を渡す
  2. docker compose down はしない（コンテナの中のログが消える）。bin/deploy.sh・bin/publish.sh も止まります
  3. DB とファイルも控えるなら: bin/backup.sh
  4. 調べ終わって、足場の除去と認証情報の再発行が済んだら: bin/security.sh open
EOF
}

# ---------------------------------------------------------------- open
open_shop() {
    local proj cur nginx_up ans
    proj="$(guard_project_name)"
    cur=""; ec_running && cur="$(maint_content)"
    nginx_up="$(dc ps -q --status running nginx 2>/dev/null || true)"
    if [ "${cur#incident}" = "$cur" ] && [ -n "$nginx_up" ]; then
        echo "[security] bin/security.sh close で閉じた状態ではありません（何もしません）"
        exit 0
    fi
    cat <<EOF
[security] お店を開け直します。ガイドラインの再開の条件:
  根本原因の特定 / 攻撃者の足場の除去 / 認証情報の再発行 / ログによる再侵入の見張り / 監視の強化
EOF
    if [ "${CONFIRM_OPEN:-}" != "$proj" ]; then
        [ -t 0 ] || { echo "[security] 確かめられません。非対話なら CONFIRM_OPEN=${proj}" >&2; exit 1; }
        printf '済んでいれば、プロジェクト名（%s）を入力: ' "$proj"
        read -r ans
        [ "$ans" = "$proj" ] || { echo "[security] 中止しました（何も変えていません）"; exit 1; }
    fi
    if [ -z "$nginx_up" ]; then dc start nginx; echo "[security] nginx を起こしました"; fi
    if [ "${cur#incident}" != "$cur" ]; then
        dc exec -T ec-cube rm -f "$MAINT"
        echo "[security] メンテナンス表示を外しました"
    fi
    echo "[security] 開きました。しばらくは毎日 bin/security.sh check を見てください"
}

case "$cmd" in
    check) check ;;
    close) close ;;
    open) open_shop ;;
    *) echo "知らないコマンド: $cmd（bin/security.sh --help）" >&2; exit 1 ;;
esac

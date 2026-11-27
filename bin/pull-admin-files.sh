#!/usr/bin/env bash
# サーバーの管理画面で書かれたファイルを、手元の作業ツリーへ取り込む。
#
#   bin/pull-admin-files.sh shop:/srv/myshop
#
# 管理画面（CSS/JS 管理・メール設定の本文・ページ管理・ブロック管理）はサーバーの
# ディスクに書く。**そのファイルはサーバーにしか無い。** サーバーの bin/backup.sh には
# 入るが、git には誰かが入れない限り入らない。ここで手元に取り込み、commit → push で
# あなたのリポジトリに残す。以後は deploy で消えない。
#
# 取り込むのは app/template と html/user_data だけ（管理画面が書く場所）。
# **app/Plugin は取らない。** 手元のプラグインはそれぞれ git 管理で、上書きすると壊す。
set -euo pipefail
# -h / --help は先頭のコメント（この説明）をそのまま出す。AI や初めての人が最初に打つのはこれ
case "${1:-}" in -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
cd "$(dirname "$0")/.."

# shellcheck source=bin/lib/deploy-guard.sh
. bin/lib/deploy-guard.sh

log() { echo "[pull-admin] $*"; }
die() { echo "[pull-admin] エラー: $*" >&2; exit 1; }

remote="${1:-}"
[ -n "$remote" ] || die "使い方: bin/pull-admin-files.sh host:/path   例: shop:/srv/myshop"
host="${remote%%:*}"; path="${remote#*:}"
[ "$host" != "$remote" ] && [ -n "$path" ] || die "host:/path の形で指定してください"

# 手元で**変更した追跡ファイル**があれば止める。取り込みで上書きして失う。
# 未追跡（??）は止めない。管理画面で作ったページを手元にも置いている、という普通の
# 状態で毎回止まってしまう（実際にそうなった）。上書きされうる旨だけ出す。
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    st="$(git status --porcelain -- app/template html/user_data 2>/dev/null || true)"
    modified="$(printf '%s\n' "$st" | grep -E '^( M|M |MM|AM| D|D )' || true)"
    untracked="$(printf '%s\n' "$st" | grep -E '^\?\?' || true)"
    if [ -n "$modified" ]; then
        printf '%s\n' "$modified" | sed 's/^/    /' >&2
        die "手元の app/template / html/user_data に未コミットの変更があります。先に commit するか stash してください。"
    fi
    if [ -n "$untracked" ]; then
        log "注意: 手元に未追跡のファイルがあります。サーバーに同じパスがあれば上書きされます:"
        printf '%s\n' "$untracked" | sed 's/^/    /'
    fi
fi

log "${host} の ${path} から app/template と html/user_data を取り込みます..."
# 向こうに出した版（deploy.sh / bootstrap-server.sh の記録）。取り込んだあと、**向こうが出した版のままのファイルは
# 手元へ戻す。** 手元で直してまだ出していないファイルは、向こうでは古い版のまま。それを取り込むと手元の直しが
# 消え、言われたとおり commit すると取り消しになる（deploy.sh が止まったときの案内どおりに打つと、そうなっていた）
sent="$(ssh "$host" "cat '${path}/var/deploy.log' 2>/dev/null" 2>/dev/null | deploy_sent_shas || true)"
bases="$(printf '%s\n' "$sent" | sed '/^$/d')"
# 記録にある版が手元に無い（浅い clone・まだ fetch していない）と、取り込んだあとに見分けられず、手元の直しを
# 黙って上書きしたままになる。**取り込む前に止める。**
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    for b in $bases; do
        git cat-file -e "${b}^{commit}" 2>/dev/null \
            || die "向こうに出した版 ${b} が手元にありません。git fetch origin（浅い clone なら git fetch --unshallow）のあとで打ち直してください"
    done
fi
# tar で 1 本にして流す。ファイル単位の scp は遅く、途中で切れたときに半端が残る。
ssh "$host" "cd '${path}' && tar -czf - app/template html/user_data" | tar -xzf -

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    kept=""
    # 名前は NUL 区切りで読む（git は日本語などの名前を引用符付きで出し、そのままでは見つからない）
    while IFS= read -r -d '' f; do
        [ -n "$f" ] || continue
        now="$(git hash-object -- "$f" 2>/dev/null || true)"
        for b in $bases; do
            if [ -n "$now" ] && [ "$(git rev-parse -q --verify "${b}:${f}" 2>/dev/null || true)" = "$now" ]; then
                git checkout -q HEAD -- "$f"
                kept="${kept}${f}
"
                break
            fi
        done
    done < <(git diff --name-only -z -- app/template html/user_data 2>/dev/null || true)
    if [ -n "$kept" ]; then
        log "手元のほうが新しいので取り込まなかったもの（向こうはまだ前に出した版のまま。次の deploy で届きます）:"
        printf '%s' "$kept" | sed 's/^/    /'
    fi
    if [ -z "$bases" ] && [ -n "$(git diff --name-only -- app/template html/user_data 2>/dev/null || true)" ]; then
        log "注意: 向こうに出した版の記録が無いので、手元で直してまだ出していないものも、向こうの古い版で上書きしています。"
        log "  git diff で確かめ、手元の直しを残すファイルは git checkout HEAD -- <ファイル> で戻してください。"
    fi
    changed="$(git status --porcelain -- app/template html/user_data 2>/dev/null || true)"
    if [ -z "$changed" ]; then
        log "手元と同じでした。取り込むものはありません。"
        exit 0
    fi
    log "取り込みました。手元に無かった・違っていたもの:"
    printf '%s\n' "$changed" | sed 's/^/    /'
    echo
    log "内容を確かめて、あなたのリポジトリに残してください:"
    log "    git add app/template html/user_data"
    log "    git commit -m \"管理画面で直した分を取り込む\" && git push"
else
    log "取り込みました（git 管理外なので差分は出せません）。"
fi

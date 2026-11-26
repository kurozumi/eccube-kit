#!/usr/bin/env bash
# 本番へ出すものを絞るための共通処理。bin/deploy.sh が使う。
#
# 守りたいこと:
#   - エンジニアが、手元のブランチや未コミットの変更を、そのまま本番へ送れない
#     （本番へ出せるのは origin/<DEPLOY_BRANCH> の先頭と**完全に同じ**ものだけ）
#   - 担当者が「何が出るか」を見ずに本番へ出せない（要約を見せ、プロジェクト名を打たせる）
#   - 誰が・いつ・何を出したかがサーバーに残る（var/deploy.log）
#
# GitHub 側のブランチ保護（bin/setup.sh protect）は、非公開リポジトリだと有料プランが要る。
# ここは**プランに関係なく効く**側の壁。両方あるのが鉄壁で、片方でも意味がある。
#
#   . "$(dirname "$0")/lib/deploy-guard.sh"
#   deploy_guard_local main        手元が origin/main の先頭と同じか（違反を列挙して 1）
#   deploy_preview <from> <to>     出るコミットと、注意の要るファイルを要約
#   deploy_confirm <プロジェクト名>  本番の確認。CONFIRM_DEPLOY=<名前> で非対話
#   deploy_record <sha> <mode> <by> <状態>   var/deploy.log に 1 行
#   deploy_last_sha                最後に成功した sha

# 本番へ出せるブランチ。.env の DEPLOY_BRANCH、無ければ main
deploy_branch() {
    local v
    v="$(grep -E '^DEPLOY_BRANCH=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
    printf '%s' "${v:-main}"
}

# 手元の状態が「レビュー済みのブランチの先頭と完全に同じ」か。
# 違反は一行ずつ stderr に出す。**1 つでもあれば 1。**
deploy_guard_local() { # deploy_guard_local <branch>
    local branch="$1" cur head remote ok=1
    cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
    if [ "$cur" != "$branch" ]; then
        echo "  ✗ いまのブランチは ${cur:-?} です。本番へ出せるのは ${branch} だけです。" >&2; ok=0
    fi
    if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        echo "  ✗ コミットしていない変更があります。本番には、リポジトリにあるものしか送れません。" >&2; ok=0
    fi
    if git fetch --quiet origin "$branch" 2>/dev/null; then
        head="$(git rev-parse HEAD 2>/dev/null || echo '')"
        remote="$(git rev-parse "origin/${branch}" 2>/dev/null || echo '')"
        if [ -n "$remote" ] && [ "$head" != "$remote" ]; then
            if git merge-base --is-ancestor "$remote" "$head" 2>/dev/null; then
                echo "  ✗ origin/${branch} に無いコミットが $(git rev-list --count "${remote}..${head}") 件あります（push もレビューもされていません）。" >&2
            elif git merge-base --is-ancestor "$head" "$remote" 2>/dev/null; then
                echo "  ✗ origin/${branch} より $(git rev-list --count "${head}..${remote}") 件古いです。git pull してから。" >&2
            else
                echo "  ✗ origin/${branch} と分岐しています。" >&2
            fi
            ok=0
        fi
    else
        echo "  ✗ origin/${branch} を取得できません（ネットワーク、または origin にそのブランチが無い）。" >&2; ok=0
    fi
    [ "$ok" = 1 ]
}

# 出るコミットと、注意の要るファイルを要約する。git のある場所で呼ぶ。
deploy_preview() { # deploy_preview <from-sha|""> <to-sha>
    local from="$1" to="$2" files n
    if [ -z "$to" ]; then echo "  出すもの: ?（sha が分かりません）"; return 0; fi
    if [ -z "$from" ] || ! git cat-file -e "${from}^{commit}" 2>/dev/null; then
        echo "  出すもの: ${to:0:7}（前回の記録が無いので差分は出せません）"
        return 0
    fi
    if [ "$from" = "$to" ]; then
        echo "  コード: ${to:0:7}（変更なし。設定とキャッシュの反映だけ）"
        return 0
    fi
    echo "  コード: ${from:0:7} → ${to:0:7}（$(git rev-list --count "${from}..${to}") コミット）"
    git --no-pager log --format='    %h %s' "${from}..${to}" | head -20
    files="$(git diff --name-only "$from" "$to")"
    n="$(printf '%s\n' "$files" | grep -c . || true)"
    echo "  変わるファイル: ${n} 件"
    printf '%s\n' "$files" | grep -q '^app/DoctrineMigrations/' && \
        echo "  ⚠ migration が含まれます。DB の構造が変わります。戻すには backups/ が要ります"
    printf '%s\n' "$files" | grep -qE '^(compose.*\.yaml|docker/|\.env\.example)' && \
        echo "  ⚠ compose / docker / .env.example が変わります。コンテナが作り直されます"
    printf '%s\n' "$files" | grep -q '^app/Plugin/' && \
        echo "  ⚠ プラグインが変わります。有効化・無効化が要るなら bin/plugin.sh"
    printf '%s\n' "$files" | grep -q '^bin/' && \
        echo "  ⚠ bin/ が変わります。この deploy 自体の手順が変わっているかもしれません"
    return 0
}

# 本番への確認。y ではなくプロジェクト名を打たせる（指が覚えて通してしまわないように）。
# 非対話（cron / CI）は CONFIRM_DEPLOY=<プロジェクト名>。
deploy_confirm() { # deploy_confirm <プロジェクト名>
    local proj="$1" ans
    if [ "${CONFIRM_DEPLOY:-}" = "$proj" ]; then
        echo "[deploy] CONFIRM_DEPLOY を確認しました。続行します。"
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "[deploy] 本番です。対話できないので、続けるなら CONFIRM_DEPLOY=${proj} を付けて実行してください。" >&2
        return 1
    fi
    echo
    echo "  本番に出します。続けるなら、プロジェクト名 ${proj} を入力してください（それ以外で中止）:"
    read -r -p "  > " ans
    if [ "$ans" != "$proj" ]; then
        echo "[deploy] 中止しました。何も変えていません。"
        return 1
    fi
    return 0
}

# 誰が・いつ・何を。var/deploy.log（サーバーのホスト側。git 管理外）
deploy_record() { # deploy_record <sha> <mode> <by> <状態: start|done|failed[ ...]>
    mkdir -p var
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:-?}" "${2:-?}" "${3:-?}" "${4:-?}" >> var/deploy.log
}

# 最後に成功した sha（無ければ空）
deploy_last_sha() {
    awk -F'\t' '$5 ~ /^done/ { s = $2 } END { if (s != "" && s != "?") print s }' var/deploy.log 2>/dev/null || true
}

# この人（記録用）。git の email があればそれ、無ければ OS のユーザー
deploy_whoami() {
    local u
    u="$(git config user.email 2>/dev/null || true)"
    printf '%s@%s' "${u:-${SUDO_USER:-${USER:-?}}}" "$(hostname -s 2>/dev/null || hostname)"
}

# 手元から送る（push モード）とき、**サーバーの管理画面が直したファイルを上書きしないか**を見る。
#   deploy_admin_conflicts <host> <path> [<出したことのある sha> ...]
#   標準出力: 上書きしてしまうファイル（1 行 1 つ）。終わりの値: 0 = 見られた、1 = 見られなかった
#
# 管理画面（ページ管理・ブロック管理・メール設定の本文・CSS / JS 管理）は app/template と html/user_data に書く。
# サーバーに git は無いので、サーバーで直したかどうかは「これまでに出した版」と比べて決める。
#   - サーバー ≠ いま送るもの              … 送ると上書きされる
#   - かつ サーバーがどの出した版とも違う  … サーバーで変わった ＝ 管理画面で直した
#     （出した版に無いファイル・出した版が分からないときは、上の 1 つだけで決める。安全側）
# 出した版は 1 つではない。最後に成功した版に加えて、そのあとに始めた deploy の版も入れる（deploy_sent_shas）。
# 失敗した deploy もファイルは入れ替えていることがあり（途中で止まれば新旧が混ざる）、それを管理画面の直しと
# 取り違えると、直した版も戻す版も出せなくなる。
# 比べる「いま送るもの」は手元の追跡しているファイルの**いまの中身**（送るのと同じ。DEPLOY_UNREVIEWED では
# コミットしていない変更も送る）。サーバーにしか無いファイルは送っても触らないので見ない（--existing）。
deploy_admin_conflicts() {
    local host="$1" path="$2" tmp d dirs="" rc=0 i=0 n base bdirs f hit has
    shift 2
    tmp="$(mktemp -d)" || return 1
    for d in app/template html/user_data; do
        [ -n "$(git ls-files -- "$d" 2>/dev/null | head -1)" ] && dirs="$dirs $d"
    done
    [ -n "$dirs" ] || { rm -rf "$tmp"; return 0; }
    mkdir -p "$tmp/head"
    # shellcheck disable=SC2086  # dirs は空白区切りの固定の名前
    git ls-files -z -- $dirs | rsync -a --from0 --files-from=- ./ "$tmp/head/" 2>"$tmp/err" \
        || { sed 's/^/    /' "$tmp/err" >&2; rm -rf "$tmp"; return 1; }
    # 出した版を 1 つずつ取り出す。取り出せない版は比べ先にしない（比べ先が減るだけで、安全側）
    for base in "$@"; do
        git cat-file -e "${base}^{commit}" 2>/dev/null || continue
        # shellcheck disable=SC2086
        git ls-tree -r --name-only "$base" -- $dirs > "$tmp/list.$i" 2>/dev/null || continue
        bdirs=""
        for d in $dirs; do grep -q "^${d}/" "$tmp/list.$i" && bdirs="$bdirs $d"; done
        [ -n "$bdirs" ] || continue
        mkdir -p "$tmp/base.$i"
        # shellcheck disable=SC2086
        if git archive -o "$tmp/base.$i.tar" "$base" -- $bdirs 2>/dev/null && tar -xf "$tmp/base.$i.tar" -C "$tmp/base.$i" 2>/dev/null; then
            i=$((i + 1))
        else
            rm -rf "$tmp/base.$i" "$tmp/list.$i"
        fi
    done
    n="$i"
    for d in $dirs; do
        # 無いのは初回（まだ何も無い）。ssh が届かなかったのとは分ける
        has="$(ssh "$host" "if [ -d '${path}/${d}' ]; then echo yes; else echo no; fi" 2>>"$tmp/err")" || { rc=1; break; }
        case "$has" in
            no) continue ;;
            yes) ;;
            *) echo "${host}:${path}/${d} があるか分かりませんでした" >> "$tmp/err"; rc=1; break ;;
        esac
        # サーバー ≠ いま送るもの
        rsync -rnc --existing --out-format='%n' "${host}:${path}/${d}/" "$tmp/head/${d}/" > "$tmp/a" 2>>"$tmp/err" || { rc=1; break; }
        # サーバー ≠ 出した版（版ごと）
        i=0
        while [ "$i" -lt "$n" ]; do
            mkdir -p "$tmp/base.$i/${d}"
            rsync -rnc --existing --out-format='%n' "${host}:${path}/${d}/" "$tmp/base.$i/${d}/" > "$tmp/b.$i" 2>>"$tmp/err" || { rc=1; break 2; }
            i=$((i + 1))
        done
        while IFS= read -r f; do
            case "$f" in */|'') continue ;; esac
            # どれか 1 つの出した版と同じなら、出したもの
            hit=0; i=0
            while [ "$i" -lt "$n" ]; do
                if grep -qxF "${d}/${f}" "$tmp/list.$i" && ! grep -qxF "$f" "$tmp/b.$i"; then hit=1; break; fi
                i=$((i + 1))
            done
            [ "$hit" = 1 ] || printf '%s/%s\n' "$d" "$f"
        done < "$tmp/a"
    done
    [ "$rc" = 0 ] || sed 's/^/    /' "$tmp/err" >&2
    rm -rf "$tmp"
    return "$rc"
}

# 比べ先になる「出した版」: 最後に成功した版と、そのあとに始めた（失敗・途中の）deploy の版。
# 標準入力に var/deploy.log。1 行目が最後に成功した版（無ければ空行）、2 行目からがそのあとの版
deploy_sent_shas() {
    awk -F'\t' '
        $2 == "" || $2 == "?" { next }
        $5 ~ /^done/ { last = $2; n = 0; delete seen; next }   # "done UNREVIEWED" も成功
        !($2 in seen) && $2 != last { seen[$2] = 1; after[n++] = $2 }
        END { print last; for (i = 0; i < n; i++) print after[i] }'
}

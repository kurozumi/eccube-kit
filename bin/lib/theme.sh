#!/usr/bin/env bash
# 本体のボリュームの中にしか無いテーマを見つける。
#
# **キットが残すテーマの静的物は html/template/original だけ。** 管理画面（テンプレート管理 →
# アップロード）で入れたテーマは、静的物が本体のボリューム（eccube_app）の
# html/template/<コード> に書かれる。bin/upgrade.sh はこのボリュームを作り直すので、
# **上げた瞬間にテーマの CSS と画像が消え、ページは 200 のまま崩れて出る**（例外も出ない）。
# bin/backup.sh も取らない。bin/theme.sh adopt <コード> で original へ移すと残る。
#
#   source "$(dirname "$0")/lib/theme.sh"
#   theme_foreign_dirs <ボリューム名>   … ボリュームにしか無いテーマのコード（1 行 1 つ）
#   theme_unsaved_dirs <ボリューム名>   … そのうち、まだ original へ移していないもの（消えると失うもの）
#   theme_code_in_use <ボリューム名>    … 使っているテーマのコード（ホストの .env → コンテナ内 .env → default）

# 本体が最初から持っているもの（4.2〜4.4 で同じ）と、キットが bind mount するもの
_theme_known=" admin default install original "

theme_foreign_dirs() { # theme_foreign_dirs <ボリューム名>
    local vol="$1" d
    docker volume inspect "$vol" >/dev/null 2>&1 || return 0
    for d in $(docker run --rm -v "${vol}:/app:ro" alpine:3 sh -c \
        'for d in /app/html/template/*/; do [ -d "$d" ] && basename "$d"; done' 2>/dev/null); do
        case "$_theme_known" in *" ${d} "*) ;; *) printf '%s\n' "$d" ;; esac
    done
}

theme_unsaved_dirs() { # theme_unsaved_dirs <ボリューム名>
    local adopted
    adopted="$(sed -n '1s/^package=adopted://p' html/template/original/.base 2>/dev/null)"
    theme_foreign_dirs "$1" | { if [ -n "$adopted" ]; then grep -vxF "$adopted" || true; else cat; fi; }
}

theme_code_in_use() { # theme_code_in_use <ボリューム名>
    local vol="$1" c
    # ホストの .env は環境変数で渡るので、コンテナ内 .env（管理画面が書く）より強い
    c="$(sed -n 's/^ECCUBE_TEMPLATE_CODE=//p' .env 2>/dev/null | tail -1 | tr -d "\"' \t\r")"
    if [ -z "$c" ] && docker volume inspect "$vol" >/dev/null 2>&1; then
        c="$(docker run --rm -v "${vol}:/app:ro" alpine:3 \
            sed -n 's/^ECCUBE_TEMPLATE_CODE=//p' /app/.env 2>/dev/null | tail -1 | tr -d "\"' \t\r")"
    fi
    printf '%s' "${c:-default}"
}

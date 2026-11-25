#!/usr/bin/env bash
# キットを最初から最後まで通して試す（kit-e2e.yml が系列 × DB の組で流す）。
#
#   .github/scripts/kit-e2e.sh <系列 4.2|4.3|4.4> <mysql|postgresql>
#
# 流れ: init → ページが開く → security.sh check → backup → DB を変えて restore（戻ったか）→
#       同じ系列で upgrade（作り直し・migration・ページの確認・切り戻しの仕組みを通る）→ ページが開く → doctor
#
# **使い捨ての場所でだけ動かす。** .env を作り直すので、.env がすでにある場所では動かない（店の .env を消さないため）。
# 手元で試すなら git worktree を作って、その中で打つ。CI（GITHUB_ACTIONS=true）はまっさらな checkout なので気にしない。
set -euo pipefail
series="${1:?系列（4.2 / 4.3 / 4.4）}"
engine="${2:?mysql か postgresql}"
cd "$(dirname "$0")/../.."
image="ghcr.io/${E2E_IMAGE_REPO:-kurozumi/eccube-kit}/ec-cube:${series}"
proj="kite2e$(printf '%s' "$series" | tr -d .)${engine:0:2}"

step() { echo; echo "::group::$*" 2>/dev/null || true; echo "===== $*"; }
endstep() { echo "::endgroup::" 2>/dev/null || true; }
fail() { echo "::error::$*"; echo "[e2e] 失敗: $*" >&2; exit 1; }

if [ -e .env ] && [ "${GITHUB_ACTIONS:-}" != true ]; then
    fail ".env があります。店の .env を消さないよう、使い捨ての worktree の中で打ってください"
fi

# ---------------------------------------------------------------- 準備
step "準備（${series} / ${engine}）"
python3 - "$engine" "$proj" <<'PY'
import re, sys
engine, proj = sys.argv[1], sys.argv[2]
s = open('.env.example', encoding='utf-8').read()
s = re.sub(r'(?m)^DB_ENGINE=.*$', f'DB_ENGINE={engine}', s)
s = re.sub(r'(?m)^COMPOSE_PROFILES=.*$', 'COMPOSE_PROFILES=', s)   # 公開層（tunnel / caddy）は立てない
s += f'\nCOMPOSE_PROJECT_NAME={proj}\n'
open('.env', 'w', encoding='utf-8').write(s)
PY
endstep

# shellcheck source=../../bin/lib/compose.sh
. bin/lib/compose.sh

# ページ: トップと商品一覧は 200、ほかは 500 番台と無応答でないこと（upgrade.sh の確かめ方と同じ）
pages() {
    local base admin code p bad=""
    base="$(compose_nginx_url)"
    admin="$(grep -E '^ECCUBE_ADMIN_ROUTE=' .env | tail -1 | cut -d= -f2-)"
    for p in / /products/list; do
        code="$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-Proto: https' "${base}${p}" || echo 000)"
        echo "  ${p} ${code}"
        [ "$code" = 200 ] || bad="${bad} ${p}(${code})"
    done
    for p in /cart /entry /contact /mypage/login /help/about "/${admin:-admin}/login"; do
        code="$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-Proto: https' "${base}${p}" || echo 000)"
        echo "  ${p} ${code}"
        case "$code" in 000|5*) bad="${bad} ${p}(${code})" ;; esac
    done
    [ -z "$bad" ] || fail "開かないページ:${bad}"
}

# DB に SQL を 1 行流して、結果を出す
sql() {
    if [ "$engine" = postgresql ]; then
        docker compose exec -T db sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "$0"' "$1"
    else
        docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -h 127.0.0.1 -u "$MYSQL_USER" -D "$MYSQL_DATABASE" -N -e "$0"' "$1"
    fi
}

# ---------------------------------------------------------------- init
step "init（${image}）"
bin/init.sh --image="$image"
endstep

step "ページ（init のあと）"
pages
endstep

step "security.sh check"
rc=0; bin/security.sh check || rc=$?
# 0 = 要確認なし、2 = 要確認あり（まっさらな店は管理者の 2 段階認証が OFF なので 2 になる）。1 = 見られなかった
[ "$rc" = 0 ] || [ "$rc" = 2 ] || fail "security.sh check が見られないものを出した（${rc}）"
endstep

# ---------------------------------------------------------------- backup → restore
step "backup"
bin/backup.sh
# 毎日の世代と同じ名前（日時だけ）。init や restore の「変える前の控え」（-before-）は除く
dir=""
for d in backups/2*; do case "$d" in *-before-*) ;; *) [ -d "$d" ] && dir="$d" ;; esac; done
[ -n "$dir" ] && [ -f "$dir/db.sql.gz" ] || fail "バックアップができていない（${dir:-無し}）"
echo "  ${dir}"
endstep

step "restore（DB を変えてから戻す）"
before="$(sql "SELECT shop_name FROM dtb_base_info WHERE id = 1" | tr -d '\r')"
sql "UPDATE dtb_base_info SET shop_name = 'E2E_CHANGED' WHERE id = 1" >/dev/null
[ "$(sql "SELECT shop_name FROM dtb_base_info WHERE id = 1" | tr -d '\r')" = E2E_CHANGED ] || fail "DB を変えられなかった"
CONFIRM_RESTORE="$proj" bin/restore.sh "$dir"
after="$(sql "SELECT shop_name FROM dtb_base_info WHERE id = 1" | tr -d '\r')"
echo "  shop_name: ${before} → E2E_CHANGED → ${after}"
[ "$after" = "$before" ] || fail "restore で DB が戻っていない（${after}）"
pages
endstep

# ---------------------------------------------------------------- upgrade（同じ系列）
case "$series" in
    4.4) to="4.4.x-dev" ;;    # 4.4 はまだ正式版が無い（~4.4.0 は解決できない）
    *)   to="~${series}.0" ;;
esac
step "upgrade ${to}（同じ系列。本体の作り直し・migration・ページの確認）"
# yes は upgrade.sh が終わると SIGPIPE で落ちる。pipefail がそれを失敗にしないよう、yes の側の失敗は握る
{ yes y || true; } | bin/upgrade.sh "$to"
endstep

step "ページ（upgrade のあと）"
pages
endstep

step "plugin.sh doctor"
bin/plugin.sh doctor
endstep

echo
echo "[e2e] 通りました（${series} / ${engine}）"

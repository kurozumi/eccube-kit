#!/usr/bin/env bash
# 借りたばかりのサーバーを、公開の一歩手前まで整える。**サーバーに git も GitHub の鍵も要らない。**
#   使い方: bin/bootstrap-server.sh <user>@<host> [/srv/myshop]
#
# やること（手元から ssh で）:
#   1. Docker が無ければ入れる（Ubuntu / Debian。get.docker.com の手順。sudo が使えること）
#   2. この店のファイル（git が追跡しているもの）を rsync で送る
#   3. 向こうで bin/init.sh --no-start（.env を作り、パスワード類を生成。起動はしない）
#      手元の .env に ECCUBE_IMAGE があれば向こうにも書く（サーバーで build しないで済む）
#   4. 次にやること（メール設定・Tunnel・公開）を表示する
#
# 以後の反映は bin/deploy.sh --remote=<user>@<host>:/srv/myshop（サーバーに .git が無いので手元から送る）。
set -euo pipefail
case "${1:-}" in -h|--help|"") awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
cd "$(dirname "$0")/.."
host="$1"; path="${2:-/srv/myshop}"
log() { printf '[bootstrap] %s\n' "$*"; }
die() { printf '[bootstrap] エラー: %s\n' "$*" >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "この場所が git のリポジトリではありません（送るのは git が追跡しているファイルです）"
command -v rsync >/dev/null 2>&1 || die "rsync が必要です"
log "${host} に入れるか確かめます..."
ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" true 2>/dev/null || ssh -o ConnectTimeout=10 "$host" true || die "${host} に入れません。VPS の管理画面で SSH 鍵を登録したか、user@host が合っているか確認してください"
log "Docker を確かめます..."
ssh "$host" 'bash -s' <<'REMOTE'
set -e
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "  Docker あり: $(docker --version | cut -d, -f1) / compose $(docker compose version --short)"
else
    echo "  Docker が無いので入れます（数分）..."
    if [ "$(id -u)" = 0 ]; then SUDO=""; else SUDO="sudo"; fi
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && $SUDO sh /tmp/get-docker.sh >/dev/null && rm -f /tmp/get-docker.sh
    if [ "$(id -u)" != 0 ]; then $SUDO usermod -aG docker "$USER"; echo "  $USER を docker グループに入れました（次の ssh から効きます）"; fi
    echo "  入れました: $(docker --version | cut -d, -f1)"
fi
REMOTE
log "${host}:${path} へ店のファイルを送ります..."
ssh "$host" "mkdir -p '${path}'" 2>/dev/null || ssh "$host" "sudo mkdir -p '${path}' && sudo chown \"\$(id -u):\$(id -g)\" '${path}'" || die "${path} を作れません"
# **向こうにもうファイルがあれば、上書きする前に控える**（var/bootstrap-backup/<日時>/。送り先の中の相対パス）。
# 動いている店へ打ち直したとき、管理画面が向こうで書いたファイル（customize.css など）を黙って消さない。
# 控えの置き場は向こうで mktemp -d で作る（同じ秒に 2 回打っても、前の控えを潰さない）
bdir="$(ssh "$host" "cd '${path}' && mkdir -p var/bootstrap-backup && mktemp -d \"var/bootstrap-backup/\$(date +%Y%m%d-%H%M%S)-XXXXXX\"")" \
    || die "向こうに控えの置き場を作れません（${path}/var/bootstrap-backup）"
git ls-files -z | rsync -az --from0 --files-from=- --backup --backup-dir="$bdir" ./ "${host}:${path}/" || die "送れませんでした"
# **送った版を向こうの記録（var/deploy.log）に残す。** deploy.sh はこれを「出した版」として、管理画面で直したファイルを
# 見分ける。記録が無いと、最初の deploy で手元で直しただけのファイルまで「管理画面で直した」と挙げて止まり、案内どおり
# 取り込むと手元の直しが消えていた（検証の環境で踏んだ）。コミットしていない変更も送ったときは記録しない（送った中身が
# どの版とも違うので、比べ先にできない。最初の deploy は手元と違うものを全部挙げる）
if [ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    # shellcheck source=bin/lib/deploy-guard.sh
    . bin/lib/deploy-guard.sh
    rec="$(printf '%s\t%s\t%s\t%s\t%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git rev-parse HEAD)" push "$(deploy_whoami)" "done bootstrap")"
    ssh "$host" "cd '${path}' && mkdir -p var && printf '%s\n' '${rec}' >> var/deploy.log" \
        || log "注意: 送った版を向こうの記録に残せませんでした。最初の deploy は、手元と違うファイルを全部挙げて止まります"
else
    log "注意: コミットしていない変更も送ったので、送った版を記録しません。最初の deploy は、手元と違うファイルを全部挙げて止まります"
fi
if [ -n "$(ssh "$host" "cd '${path}' && find '${bdir}' -type f | head -1" 2>/dev/null)" ]; then
    log "向こうで上書きしたファイルは ${path}/${bdir}/ に控えました"
else
    ssh "$host" "cd '${path}' && rmdir '${bdir}'" 2>/dev/null || true
fi
img="$(grep -E '^ECCUBE_IMAGE=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
log "向こうで .env を作ります（パスワード類を生成。起動はしません）..."
ssh "$host" "cd '${path}' && bin/init.sh --no-start" | sed 's/^/  /'
if [ -n "$img" ]; then
    ssh "$host" "cd '${path}' && (grep -qE '^#?ECCUBE_IMAGE=' .env && sed -i \"s|^#\\{0,1\\}ECCUBE_IMAGE=.*|ECCUBE_IMAGE=${img}|\" .env || echo 'ECCUBE_IMAGE=${img}' >> .env)"
    log "ECCUBE_IMAGE=${img} を向こうの .env に書きました（配布イメージを pull するだけで済みます）"
else
    log "注意: 手元の .env に ECCUBE_IMAGE が無いので、向こうは build します（10 分以上）。docs/install.md のタグ表を見て向こうの .env に書くと速い"
fi
cat <<EOS

[bootstrap] できました。次にやること（順番に。全部この手元から打てます）:

  1. メール送信の設定（質問に答えて 1 通試す）
       bin/setup.sh mail --remote=${host}:${path}
  2. ドメインと HTTPS（Cloudflare Tunnel。トークンを貼ると、繋がるか試してから書く）
       bin/setup.sh tunnel --remote=${host}:${path}
  3. 公開する
       bin/publish.sh --remote=${host}:${path}
  4. バックアップの送り先と毎日の自動実行
       bin/setup.sh backup --remote=${host}:${path}
  以後、直したら:
       bin/deploy.sh --remote=${host}:${path}
EOS

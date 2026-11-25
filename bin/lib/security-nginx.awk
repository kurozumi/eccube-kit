# bin/security.sh check が nginx のアクセスログ（combined 形式）を数える。-v route=<管理画面の URL>
#   $1 が IP（nginx の real_ip で、お客さんの IP に置き換え済み）、$6 が "メソッド、$7 がパス、$9 が状態。
#   ・429（ログインとパスワード再発行のレート制限に当たった）… 要確認
#   ・ログインの送信（POST）が 30 回を超えた IP … 要確認
#   ・管理画面や設定ファイルを探す 403 / 404 … 参考（インターネットに出ていれば毎日来る）
$6 !~ /^"[A-Z]+$/ { next }
{ ip = $1; m = substr($6, 2); p = $7; s = $9; sub(/\?.*/, "", p) }
s == "429" { r429[ip]++; n429++ }
m == "POST" && (p ~ /^\/(mypage|shopping)\/login$/ || p == "/" route "/login") { login[ip]++ }
(s == "404" || s == "403") && p ~ /^\/(wp-|wordpress|xmlrpc\.php|phpmyadmin|pma|\.env|\.git|administrator|vendor\/phpunit|install\.php|admin(\/|$))/ \
    && !(route == "admin" && p ~ /^\/admin(\/|$)/) { probe[ip]++; nprobe++ }
function top(a,   k, out, i, best, bk, seen) {
    out = ""
    for (i = 0; i < 3; i++) { best = 0; bk = ""
        for (k in a) if (!(k in seen) && a[k] > best) { best = a[k]; bk = k }
        if (bk == "") break
        seen[bk] = 1; out = out (out == "" ? "" : "、") bk " ×" best }
    return out
}
END {
    if (n429 > 0) printf "  [要確認] レート制限（1 分に 10 回ほど）に当たった要求 %d 件。多い IP: %s\n", n429, top(r429)
    else print "  [ok] レート制限に当たった要求は無し"
    heavy = 0; for (k in login) if (login[k] >= 30) { hv[k] = login[k]; heavy++ }
    if (heavy > 0) printf "  [要確認] ログインの送信が 30 回を超えた IP %d 個: %s\n", heavy, top(hv)
    if (nprobe > 0) printf "  [参考] 管理画面や設定ファイルを探す要求 %d 件（よくある機械的な探索）。多い IP: %s\n", nprobe, top(probe)
}

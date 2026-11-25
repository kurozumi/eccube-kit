<?php
/*
 * bin/security.sh check が ec-cube コンテナの中で流す、DB の点検（読むだけ）。
 * EC-CUBE セキュリティ対策ガイドラインの「不審なデータの確認」と、管理画面のログイン（dtb_login_history）を見る。
 * カーネルは起こさない（キャッシュが壊れていても、侵入を疑う場面で動く必要がある）。DATABASE_URL から PDO で直接読む。
 *
 * 入力（環境変数）:
 *   SEC_DAYS   … 何日さかのぼるか（既定 7）
 *   SEC_HOURS  … 業務時間（例 8-21 = 8 時から 21 時の前まで）。外のログインを挙げる
 *   SEC_TZ     … 時刻を読むタイムゾーン（既定 Asia/Tokyo）
 * 出力: 行ごとに「## 見出し」「  [要確認] …」「  [参考] …」「  [ok] …」。DB に繋がらなければ
 *   「  [不明] …」を出して 3 で終わる。
 */
error_reporting(E_ALL & ~E_DEPRECATED);
$days  = max(1, (int) (getenv('SEC_DAYS') ?: 7));
$hours = getenv('SEC_HOURS') ?: '8-21';
$tz    = new DateTimeZone(getenv('SEC_TZ') ?: 'Asia/Tokyo');
$utc   = new DateTimeZone('UTC');
[$h0, $h1] = array_map('intval', explode('-', $hours) + [1 => 21]);

function out(string $kind, string $msg): void { echo "  [$kind] $msg\n"; }
function head1(string $t): void { echo "## $t\n"; }

// ---- 接続 ----
$url = getenv('DATABASE_URL') ?: '';
// コンテナ内の .env にしか無いこともある（install 直後）
if ($url === '' && is_file('/var/www/html/.env')) {
    foreach (file('/var/www/html/.env') as $l) {
        if (preg_match('/^DATABASE_URL=(.*)$/', trim($l), $m)) { $url = trim($m[1], "\"'"); }
    }
}
$p = parse_url($url);
if (!$p || empty($p['scheme'])) { head1('DB'); out('不明', 'DATABASE_URL を読めませんでした'); exit(3); }
$scheme = $p['scheme'];
$pg = in_array($scheme, ['postgres', 'postgresql', 'pgsql', 'pdo-pgsql'], true);
$db = ltrim($p['path'] ?? '', '/');
$host = $p['host'] ?? 'db';
$port = $p['port'] ?? ($pg ? 5432 : 3306);
$user = urldecode($p['user'] ?? '');
$pass = urldecode($p['pass'] ?? '');
try {
    $dsn = $pg ? "pgsql:host=$host;port=$port;dbname=$db" : "mysql:host=$host;port=$port;dbname=$db;charset=utf8mb4";
    $pdo = new PDO($dsn, $user, $pass, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
    // EC-CUBE は日時を UTC で持つ。PostgreSQL の timestamptz を UTC で受け取る
    if ($pg) { $pdo->exec("SET TIME ZONE 'UTC'"); }
} catch (Throwable $e) {
    head1('DB'); out('不明', 'DB に繋がりませんでした: ' . $e->getMessage()); exit(3);
}

$since = (new DateTime("-{$days} days", $utc))->format('Y-m-d H:i:s');
$local = fn ($v) => $v === null ? '-' : (new DateTime((string) $v, $utc))->setTimezone($tz)->format('Y-m-d H:i');
$hasTable = function (string $t) use ($pdo, $pg): bool {
    $q = $pg
        ? "SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = ?"
        : "SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?";
    $s = $pdo->prepare($q); $s->execute([$t]);
    return (bool) $s->fetchColumn();
};
$rows = function (string $sql, array $args = []) use ($pdo): array { $s = $pdo->prepare($sql); $s->execute($args); return $s->fetchAll(); };
$cut = fn ($s, $n = 40) => mb_strimwidth(preg_replace('/\s+/u', ' ', (string) $s), 0, $n, '…');

// 文字の欄に、画面に埋め込むと動くものや、外への URL が入っていないか（攻撃の足場・試し打ちの痕）
$suspicious = '/<\s*\/?\s*(script|iframe|img|svg|object|embed|link|meta)\b|javascript:|\bon[a-z]+\s*=|\{\{|\{%|https?:\/\//i';
// 見るのはお客さんが入力する欄だけ。プラグインが足した列（決済画面の URL など）や管理者のメモは見ない
$scan = function (array $r, array $only) use ($suspicious): array {
    $hit = [];
    foreach ($only as $k) {
        $v = $r[$k] ?? null;
        if (!is_string($v) || $v === '') { continue; }
        if (preg_match($suspicious, $v)) { $hit[] = $k; }
    }
    return $hit;
};

// ---- 管理者 ----
head1("管理者（dtb_member）");
if (!$hasTable('dtb_member')) { out('不明', 'dtb_member がありません（未インストール？）'); exit(3); }
$cols = array_column($rows($pg
    ? "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'dtb_member'"
    : "SELECT column_name FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'dtb_member'"), 'column_name');
$cols = array_map('strtolower', $cols);
$has2fa = in_array('two_factor_auth_enabled', $cols, true);
$members = $rows('SELECT * FROM dtb_member ORDER BY id');
foreach ($members as $m) {
    $m = array_change_key_case($m);
    $active = (int) ($m['work_id'] ?? 1) === 1;
    $flags = [];
    if ($active && $has2fa && !(bool) $m['two_factor_auth_enabled']) { $flags[] = '2 段階認証が OFF'; }
    $new = isset($m['create_date']) && $m['create_date'] >= $since;
    if ($new) { $flags[] = "{$days} 日以内に作られた"; }
    $desc = sprintf('%s（%s）作成 %s・最終ログイン %s%s', $m['login_id'], $m['name'], $local($m['create_date'] ?? null),
        $local($m['login_date'] ?? null), $active ? '' : '・非稼働');
    if ($flags && $active) { out('要確認', $desc . ' … ' . implode('、', $flags)); }
    else { out('ok', $desc); }
}

// ---- 管理画面のログイン ----
head1("管理画面のログイン（直近 {$days} 日）");
if (!$hasTable('dtb_login_history')) {
    out('参考', 'ログイン履歴の表がありません（EC-CUBE 4.1 以前）');
} else {
    $fail = $rows('SELECT user_name, client_ip, create_date FROM dtb_login_history WHERE login_history_status_id = 0 AND create_date >= ?', [$since]);
    $ok   = $rows('SELECT user_name, client_ip, create_date FROM dtb_login_history WHERE login_history_status_id = 1 AND create_date >= ? ORDER BY create_date', [$since]);
    $n = count($fail);
    if ($n === 0) { out('ok', '失敗 0 件'); }
    else {
        $byIp = array_count_values(array_map(fn ($r) => (string) $r['client_ip'], $fail)); arsort($byIp);
        $byUser = array_count_values(array_map(fn ($r) => (string) $r['user_name'], $fail)); arsort($byUser);
        $top = fn ($a) => implode('、', array_map(fn ($k, $v) => "$k ×$v", array_keys(array_slice($a, 0, 3, true)), array_slice($a, 0, 3, true)));
        out($n >= 10 ? '要確認' : '参考', "失敗 {$n} 件。多い IP: " . $top($byIp) . '。多い ID: ' . $top($byUser));
    }
    $off = 0;
    foreach ($ok as $r) {
        $t = (new DateTime((string) $r['create_date'], $utc))->setTimezone($tz);
        $h = (int) $t->format('G');
        if ($h < $h0 || $h >= $h1) {
            if (++$off <= 10) { out('要確認', sprintf('業務時間（%s 時）の外のログイン: %s %s（%s）', $hours, $t->format('Y-m-d H:i'), $r['user_name'], $r['client_ip'])); }
        }
    }
    if ($off > 10) { out('要確認', '業務時間の外のログインがほかに ' . ($off - 10) . ' 件'); }
    // それまでの 90 日に一度も成功していない IP からの成功
    $seen = array_flip(array_column($rows('SELECT DISTINCT client_ip FROM dtb_login_history WHERE login_history_status_id = 1 AND create_date < ? AND create_date >= ?',
        [$since, (new DateTime('-' . ($days + 90) . ' days', $utc))->format('Y-m-d H:i:s')]), 'client_ip'));
    $newIp = [];
    foreach ($ok as $r) { if (!isset($seen[$r['client_ip']])) { $newIp[(string) $r['client_ip']] = $r['user_name']; } }
    if ($newIp && $seen) {
        foreach (array_slice($newIp, 0, 5, true) as $ip => $u) { out('参考', "これまで使われていない IP からのログイン: {$ip}（{$u}）"); }
    }
    if (count($ok) > 0 && $off === 0) { out('ok', '成功 ' . count($ok) . ' 件（どれも業務時間内）'); }
}

// ---- 会員・注文 ----
$person = ['name01', 'name02', 'kana01', 'kana02', 'company_name', 'addr01', 'addr02', 'email', 'phone_number', 'postal_code'];
foreach ([['dtb_customer', '会員', $person], ['dtb_order', '注文', array_merge($person, ['message'])]] as [$t, $label, $only]) {
    head1("{$label}（直近 {$days} 日に作られたもの）");
    $list = $rows("SELECT * FROM {$t} WHERE create_date >= ? ORDER BY id DESC LIMIT 20000", [$since]);
    $hits = 0;
    foreach ($list as $r) {
        $r = array_change_key_case($r);
        $cols = $scan($r, $only);
        if ($cols && ++$hits <= 10) {
            $who = $t === 'dtb_customer' ? ($r['email'] ?? '') : ('注文 ' . ($r['order_no'] ?? $r['id']));
            out('要確認', sprintf('id=%s %s … %s に「%s」', $r['id'], $who, implode('・', $cols), $cut($r[$cols[0]])));
        }
    }
    if ($hits > 10) { out('要確認', "ほかに " . ($hits - 10) . " 件"); }
    if ($hits === 0) { out('ok', count($list) . ' 件。タグや URL の入ったものは無し'); }
}

// ---- ページ（<head> に足せるタグ） ----
head1('ページ管理の <head> に足したタグ（dtb_page.meta_tags）');
if (in_array('meta_tags', array_map('strtolower', array_column($rows($pg
    ? "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'dtb_page'"
    : "SELECT column_name FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'dtb_page'"), 'column_name')), true)) {
    $pages = $rows("SELECT id, page_name, url, meta_tags, update_date FROM dtb_page WHERE meta_tags LIKE '%<script%' OR meta_tags LIKE '%<iframe%' OR meta_tags LIKE '%http%'");
    if (!$pages) { out('ok', 'スクリプト・外部の URL を入れたページは無し'); }
    foreach ($pages as $pg1) {
        preg_match_all('#(?:src|href)\s*=\s*["\']?(https?://[^/"\'\s>]+)#i', (string) $pg1['meta_tags'], $mm);
        $where = $mm[1] ? implode('、', array_unique($mm[1])) : '（URL 無し）';
        $recent = $pg1['update_date'] >= $since;
        out($recent ? '要確認' : '参考', sprintf('%s（%s）更新 %s: %s', $pg1['page_name'], $pg1['url'], $local($pg1['update_date']), $where));
    }
}

// ---- プラグイン ----
head1('プラグイン（dtb_plugin）');
$plugins = $rows('SELECT code, name, version, enabled, create_date, update_date FROM dtb_plugin ORDER BY code');
if (!$plugins) { out('ok', '入っていない'); }
$recent = array_values(array_filter($plugins, fn ($pl) => $pl['create_date'] >= $since));
foreach (array_slice($recent, 0, 5) as $pl) {
    out('要確認', sprintf('%s %s（%s）%s・入れた日 %s … %d 日以内に入った', $pl['code'], $pl['version'], $cut($pl['name'], 30),
        $pl['enabled'] ? '有効' : '無効', $local($pl['create_date']), $days));
}
if (count($recent) > 5) { out('要確認', sprintf('ほかに %d 本が %d 日以内に入った（一覧は bin/plugin.sh list）', count($recent) - 5, $days)); }
$on  = count(array_filter($plugins, fn ($pl) => $pl['enabled']));
$off = count($plugins) - $on;
if ($plugins) { out('ok', "有効 {$on} 本"); }
if ($off > 0) { out('参考', "無効 {$off} 本。使わないなら bin/plugin.sh remove で外す（ガイドライン「使っていないプラグインを停止・削除する」）"); }
exit(0);

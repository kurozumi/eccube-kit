<?php
/*
 * bin/import.sh diagnose が、上げた先の EC-CUBE のイメージの中で動かす診断。
 * キットに載っていない店のファイルを読むだけで、何も書き換えない。
 *
 *   /old   … 店のファイル（読み取り専用）
 *   /from  … 店と同じ版のまっさらな EC-CUBE（GitHub のタグ）
 *   /var/www/html … 上げた先の EC-CUBE（このイメージの本体）
 *   /dump  … DB のダンプ（任意。.sql / .sql.gz）
 *   /out   … 報告書の置き場
 *
 * 店ごとの値（パスワード・鍵）は報告書に書かない。キーの名前と、伏せた値だけを出す。
 */

const OLD = '/old';
const FROM = '/from';
const TO = '/var/www/html';
const OUT = '/out';

$to_ver = $argv[1] ?? '?';

function rel_files(string $root, string $sub = ''): array
{
    $base = rtrim($root, '/') . ($sub === '' ? '' : '/' . $sub);
    if (!is_dir($base)) {
        return is_file($base) ? [$sub] : [];
    }
    $out = [];
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($base, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $f) {
        if ($f->isFile()) {
            $out[] = ltrim(substr($f->getPathname(), strlen(rtrim($root, '/'))), '/');
        }
    }
    sort($out);
    return $out;
}

function same(string $a, string $b): bool
{
    return is_file($a) && is_file($b) && filesize($a) === filesize($b) && hash_file('sha256', $a) === hash_file('sha256', $b);
}

function diff_lines(string $a, string $b): array
{
    $cmd = sprintf('diff -u %s %s', escapeshellarg($a), escapeshellarg($b));
    $out = shell_exec($cmd) ?? '';
    $plus = $minus = 0;
    foreach (explode("\n", $out) as $l) {
        if (str_starts_with($l, '+++') || str_starts_with($l, '---')) continue;
        if (str_starts_with($l, '+')) $plus++;
        if (str_starts_with($l, '-')) $minus++;
    }
    return [$plus, $minus, $out];
}

function parse_env(string $file): array
{
    $env = [];
    if (!is_file($file)) return $env;
    foreach (file($file, FILE_IGNORE_NEW_LINES) as $l) {
        if (!preg_match('/^\s*(?:export\s+)?([A-Z0-9_]+)\s*=\s*(.*)$/', $l, $m)) continue;
        $v = trim($m[2]);
        if (preg_match('/^(["\'])(.*)\1$/', $v, $q)) $v = $q[2];
        $env[$m[1]] = $v;
    }
    return $env;
}

function mask_url(string $url): string
{
    return preg_replace('#//([^:/@]+):[^@]*@#', '//$1:***@', $url);
}

function dir_size(string $dir): array
{
    $n = 0; $bytes = 0;
    if (!is_dir($dir)) return [0, 0];
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $f) { if ($f->isFile() && $f->getFilename() !== '.gitkeep') { $n++; $bytes += $f->getSize(); } }
    return [$n, $bytes];
}

function human(int $b): string
{
    foreach (['B', 'KB', 'MB', 'GB'] as $u) { if ($b < 1024 || $u === 'GB') return round($b, 1) . $u; $b /= 1024; }
    return $b . 'B';
}

function md(string $s): string { return str_replace('|', '\\|', $s); }

// ---------------------------------------------------------------- 基本
$from_ver = '?';
if (preg_match("/const VERSION = '([^']+)'/", @file_get_contents(OLD . '/src/Eccube/Common/Constant.php') ?: '', $m)) $from_ver = $m[1];
$env = parse_env(OLD . '/.env');
$theme = $env['ECCUBE_TEMPLATE_CODE'] ?? 'default';
$admin_route = $env['ECCUBE_ADMIN_ROUTE'] ?? 'admin';
$db_url = $env['DATABASE_URL'] ?? '';
$db_scheme = strtolower(parse_url($db_url, PHP_URL_SCHEME) ?: '?');
$db_kind = match (true) {
    str_starts_with($db_scheme, 'mysql') => 'mysql',
    str_starts_with($db_scheme, 'pgsql'), str_starts_with($db_scheme, 'postgres') => 'postgresql',
    str_starts_with($db_scheme, 'sqlite') => 'sqlite',
    default => '?',
};

$reasons = [];   // 固定料金にできない理由
$works = [];     // 取り込みで必ずやる作業（料金に入る）
$asks = [];      // 店に確かめること

// ---------------------------------------------------------------- DB のダンプ
$dump = null;
foreach (['/dump/dump.sql.gz', '/dump/dump.sql'] as $p) if (is_file($p)) $dump = $p;
$dump_info = ['server' => null, 'complete' => false, 'c0900' => 0, 'definer' => 0, 'routines' => 0, 'bytes' => 0, 'mariadb' => false];
$plugin_rows = [];
if ($dump) {
    $dump_info['bytes'] = filesize($dump);
    $h = str_ends_with($dump, '.gz') ? gzopen($dump, 'r') : fopen($dump, 'r');
    $cols = null; $in_copy = false;
    while (($l = (str_ends_with($dump, '.gz') ? gzgets($h) : fgets($h))) !== false) {
        if ($dump_info['server'] === null && preg_match('/^-- (?:Server version|Dumped from database version)\s+(.+)$/', rtrim($l), $m)) {
            $dump_info['server'] = trim($m[1]);
            if (stripos($m[1], 'mariadb') !== false) $dump_info['mariadb'] = true;
        }
        if (str_starts_with($l, '-- Dump completed') || str_starts_with($l, '-- PostgreSQL database dump complete')) $dump_info['complete'] = true;
        $dump_info['c0900'] += substr_count($l, '_0900_');
        if (str_contains($l, 'DEFINER=')) $dump_info['definer']++;
        if (preg_match('/^CREATE\s+(?:DEFINER\S*\s+)?(?:TRIGGER|PROCEDURE|FUNCTION|EVENT)\b/i', $l) || preg_match('/\b(?:TRIGGER|PROCEDURE|FUNCTION)\b.*\bBEGIN\b/i', $l)) $dump_info['routines']++;
        // dtb_plugin の列（MySQL: CREATE TABLE、PostgreSQL: COPY の見出し）
        if (preg_match('/^CREATE TABLE [`"]?(?:public\.)?dtb_plugin[`"]? \(/', $l)) { $cols = []; continue; }
        if (is_array($cols) && !$in_copy && preg_match('/^\s+[`"]?(\w+)[`"]?\s+\w/', $l, $m) && !preg_match('/^\s+(PRIMARY|UNIQUE|KEY|CONSTRAINT|INDEX)\b/', $l)) { $cols[] = $m[1]; continue; }
        if (preg_match('/^INSERT INTO [`"]?dtb_plugin[`"]? (?:\(([^)]*)\) )?VALUES (.*);\s*$/s', $l, $m)) {
            $c = $m[1] ? array_map(fn($x) => trim($x, " `\""), explode(',', $m[1])) : $cols;
            foreach (sql_tuples($m[2]) as $t) $plugin_rows[] = array_combine(array_slice($c, 0, count($t)), $t);
        }
        if (preg_match('/^COPY (?:public\.)?dtb_plugin \(([^)]*)\) FROM stdin;/', $l, $m)) { $cols = array_map('trim', explode(',', $m[1])); $in_copy = true; continue; }
        if ($in_copy) {
            if (rtrim($l) === '\.') { $in_copy = false; continue; }
            $t = array_map(fn($x) => $x === '\N' ? null : $x, explode("\t", rtrim($l, "\n")));
            $plugin_rows[] = array_combine(array_slice($cols, 0, count($t)), $t);
        }
    }
}

function sql_tuples(string $s): array
{
    $rows = []; $row = []; $cur = ''; $inq = false; $depth = 0; $len = strlen($s);
    for ($i = 0; $i < $len; $i++) {
        $ch = $s[$i];
        if ($inq) {
            if ($ch === '\\') { $cur .= $s[++$i] ?? ''; continue; }
            if ($ch === "'") { if (($s[$i + 1] ?? '') === "'") { $cur .= "'"; $i++; continue; } $inq = false; continue; }
            $cur .= $ch; continue;
        }
        if ($ch === "'") { $inq = true; continue; }
        if ($ch === '(') { $depth++; if ($depth === 1) { $row = []; $cur = ''; continue; } }
        if ($ch === ')') { $depth--; if ($depth === 0) { $row[] = $cur === 'NULL' ? null : $cur; $rows[] = $row; $cur = ''; continue; } }
        if ($ch === ',' && $depth === 1) { $row[] = $cur === 'NULL' ? null : $cur; $cur = ''; continue; }
        if ($depth >= 1) $cur .= $ch;
    }
    return $rows;
}

// ---------------------------------------------------------------- 本体の書き換え
$core_roots = ['src', 'html/template/default', 'html/template/admin', 'html/template/install', 'index.php', 'app/config/eccube', 'bin/console'];
$core = ['modified' => [], 'added' => [], 'deleted' => []];
$patch = '';
foreach ($core_roots as $r) {
    foreach (rel_files(OLD, $r) as $f) {
        $o = OLD . '/' . $f; $p = FROM . '/' . $f;
        if (!is_file($p)) { $core['added'][] = $f; continue; }
        if (!same($o, $p)) {
            [$plus, $minus, $d] = diff_lines($p, $o);
            $core['modified'][] = [$f, $plus, $minus];
            $patch .= $d;
        }
    }
    if ($r === 'src') {
        foreach (rel_files(FROM, $r) as $f) if (!is_file(OLD . '/' . $f)) $core['deleted'][] = $f;
    }
}
// app/config/eccube/packages に店が足した設定は、キットでは app/config/eccube/packages へ運べる（本体の書き換えではない）
$extra_config = array_values(array_filter($core['added'], fn($f) => str_starts_with($f, 'app/config/eccube/packages/')));
$core['added'] = array_values(array_filter($core['added'], fn($f) => !str_starts_with($f, 'app/config/eccube/packages/')));
if ($patch !== '') file_put_contents(OUT . '/core.patch', $patch);
$core_n = count($core['modified']) + count($core['added']) + count($core['deleted']);
if ($core_n > 0) $reasons[] = "本体を直接書き換えた箇所が {$core_n} ファイルあります。`app/Customize` への書き直しが要ります（core.patch）";

// 店が足した migration（本体の app/DoctrineMigrations に混ぜてあるもの）
$own_migrations = [];
foreach (rel_files(OLD, 'app/DoctrineMigrations') as $f) if (!is_file(FROM . '/' . $f)) $own_migrations[] = $f;
if ($own_migrations) $works[] = '店が足した migration ' . count($own_migrations) . ' 件を `app/DoctrineMigrations`（キットでは独自 migration の置き場）へ運ぶ';

// ---------------------------------------------------------------- ライブラリ
$cj_old = json_decode(@file_get_contents(OLD . '/composer.json') ?: '{}', true) ?: [];
$cj_from = json_decode(@file_get_contents(FROM . '/composer.json') ?: '{}', true) ?: [];
$libs = [];
foreach (($cj_old['require'] ?? []) as $k => $v) {
    if (!array_key_exists($k, $cj_from['require'] ?? [])) $libs[$k] = $v;
}
// 上げた先の本体がもう入れている版と、店の制約が合わないもの（symfony/* の ^5.4 など）は、そのままでは composer が解けない
require_once TO . '/vendor/autoload.php';
$lock = [];
foreach ((json_decode(@file_get_contents(TO . '/composer.lock') ?: '{}', true)['packages'] ?? []) as $pk) $lock[$pk['name']] = $pk['version'];
$lib_clash = [];
foreach ($libs as $k => $v) {
    if (isset($lock[$k]) && class_exists(\Composer\Semver\Semver::class)) {
        try { if (!\Composer\Semver\Semver::satisfies($lock[$k], $v)) $lib_clash[$k] = $lock[$k]; } catch (\Throwable $e) {}
    }
}
if ($lib_clash) $reasons[] = '足されたライブラリのうち ' . count($lib_clash) . ' 件は、上げた先の本体が入れている版と制約が合いません（' . implode('、', array_map(fn($k) => "{$k}: {$libs[$k]} ↔ {$lib_clash[$k]}", array_keys($lib_clash))) . '）。使っているコードごと直します';
if ($libs) {
    file_put_contents(OUT . '/composer.extra.json', json_encode(['require' => $libs], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
    $works[] = '足されたライブラリ ' . count($libs) . ' 件を `app/Customize/composer.extra.json` に書く（composer.extra.json）';
}

// ---------------------------------------------------------------- テンプレートの写し
$tpl_rows = [];
$tpl_conflicts = 0;
foreach (glob(OLD . '/app/template/*', GLOB_ONLYDIR) as $d) {
    $code = basename($d);
    if (in_array($code, ['plugin', 'user_data', 'smartphone'], true)) continue;
    $core_dir = $code === 'admin' ? 'admin' : 'default';
    foreach (rel_files($d) as $f) {
        if (basename($f) === '.gitkeep') continue;
        $mine = "$d/$f";
        $from = FROM . "/src/Eccube/Resource/template/$core_dir/$f";
        $to = TO . "/src/Eccube/Resource/template/$core_dir/$f";
        if (!is_file($from)) { $st = '店が足したファイル（そのまま運ぶ）'; }
        elseif (!is_file($to)) { $st = '上げた先の本体に無い（中身を確かめる）'; $tpl_conflicts++; }
        else {
            $mine_same = same($mine, $from);
            $core_same = same($from, $to);
            if ($mine_same && $core_same) $st = '本体と同じ写し（消してよい）';
            elseif ($mine_same) $st = '本体と同じ写しで、本体が変わった（消せば新しい本体が使われる）';
            elseif ($core_same) $st = '店が直した。本体は変わっていない（そのまま運ぶ）';
            else { $st = '**店も本体も変えた（取り込みが要る）**'; $tpl_conflicts++; }
        }
        $tpl_rows[] = ["app/template/$code/$f", $st];
    }
}
if ($tpl_conflicts) $reasons[] = "テンプレートの写しのうち {$tpl_conflicts} ファイルは、店も本体も変えています。手で合わせます";
$tpl_stale = count(array_filter($tpl_rows, fn($r) => str_starts_with($r[1], '本体と同じ写し')));
if ($tpl_stale) $works[] = "本体と同じテンプレートの写し {$tpl_stale} 件を消す（残すと、本体を上げても古いほうが勝ち続ける）";

// ---------------------------------------------------------------- テーマ
$themes = [];
foreach (glob(OLD . '/html/template/*', GLOB_ONLYDIR) as $d) {
    $code = basename($d);
    if (in_array($code, ['default', 'admin', 'install'], true)) continue;
    [$n, $bytes] = dir_size($d);
    $hard = [];
    foreach (['html/template/' . $code, 'app/template/' . $code] as $root) {
        foreach (rel_files(OLD, $root) as $f) {
            if (preg_match('/\.(css|js|twig|html|scss)$/', $f) && preg_match('#html/template/' . preg_quote($code, '#') . '\b#', file_get_contents(OLD . '/' . $f))) $hard[] = $f;
        }
    }
    $themes[] = ['code' => $code, 'files' => $n, 'bytes' => $bytes, 'in_use' => $code === $theme, 'style' => is_file("$d/assets/css/style.css"), 'hard' => $hard, 'twig' => count(rel_files(OLD . "/app/template/$code"))];
}
foreach ($themes as $t) {
    if ($t['in_use']) {
        $works[] = "使っているテーマ {$t['code']} を `original` として取り込む（`bin/theme.sh`）";
        if ($t['hard']) $works[] = "テーマの中でコード {$t['code']} を URL に直接書いている " . count($t['hard']) . ' ファイルを直す';
        $asks[] = "テーマ {$t['code']} を作った会社が EC-CUBE {$to_ver} 対応版を出しているか（出ていれば入れ替え、無ければ今のものを画面で確かめる）";
    }
}

// ---------------------------------------------------------------- プラグイン
$plugins = [];
foreach (glob(OLD . '/app/Plugin/*', GLOB_ONLYDIR) as $d) {
    $cj = json_decode(@file_get_contents("$d/composer.json") ?: '{}', true) ?: [];
    $code = $cj['extra']['code'] ?? basename($d);
    $plugins[$code] = ['dir' => basename($d), 'name' => $cj['description'] ?? $code, 'version' => $cj['version'] ?? '?', 'db' => null, 'enabled' => null, 'git' => is_dir("$d/.git")];
}
foreach ($plugin_rows as $r) {
    $code = $r['code'] ?? null;
    if ($code === null) continue;
    $plugins[$code] ??= ['dir' => null, 'name' => $r['name'] ?? $code, 'version' => '?', 'db' => null, 'enabled' => null, 'git' => false];
    $plugins[$code]['db'] = $r['version'] ?? '?';
    $plugins[$code]['enabled'] = in_array((string) ($r['enabled'] ?? ''), ['1', 't', 'true'], true);
}
ksort($plugins);

// PHPStan（bin/import.sh が、元の版と上げた先の版の両方で流した結果）。上げた先にだけ出るものが、上げると壊れるもの
$stan = ['from' => @file(OUT . '/phpstan-from.txt', FILE_IGNORE_NEW_LINES) ?: [], 'to' => @file(OUT . '/phpstan-to.txt', FILE_IGNORE_NEW_LINES) ?: []];
$norm = fn($l) => preg_replace('#^/var/www/html/#', '', $l);
$from_set = array_flip(array_map($norm, $stan['from']));
$new_errors = [];
foreach ($stan['to'] as $l) {
    $l = $norm($l);
    if (!preg_match('#^(app/[^:]+):\d+:#', $l) || isset($from_set[$l])) continue;
    $new_errors[] = $l;
}
file_put_contents(OUT . '/phpstan-new.txt', implode("\n", $new_errors) . ($new_errors ? "\n" : ''));
$errors_by = [];
foreach ($new_errors as $l) {
    $who = preg_match('#^app/Plugin/([^/]+)/#', $l, $m) ? $m[1] : 'Customize';
    $errors_by[$who] = ($errors_by[$who] ?? 0) + 1;
}

// Symfony 6 で消えた書き方（PHPStan の水準では拾わないもの）
$removed = [
    '/->(getMasterRequest|isMasterRequest)\s*\(|MASTER_REQUEST/' => 'getMasterRequest / isMasterRequest（Symfony 6 で削除。Main に変わった）',
    '/Symfony\\\\Component\\\\Security\\\\Core\\\\Encoder\\\\/' => 'Security\\Core\\Encoder（Symfony 6 で削除。PasswordHasher に変わった）',
    '/->getUsername\s*\(/' => 'getUsername()（Symfony 6 で UserInterface から外れた。getUserIdentifier）',
    '/Symfony\\\\Component\\\\HttpKernel\\\\Event\\\\(GetResponseEvent|FilterResponseEvent|FilterControllerEvent|GetResponseForExceptionEvent)/' => '古いイベントクラス（Symfony 5 で削除）',
    '/Doctrine\\\\Common\\\\Persistence\\\\/' => 'Doctrine\\Common\\Persistence（削除済み）',
    '/\bSwift_[A-Z]/' => 'SwiftMailer（4.2 で Symfony Mailer に変わった）',
];
$legacy = [];
foreach (array_merge(['app/Customize'], array_map(fn($d) => 'app/Plugin/' . basename($d), glob(OLD . '/app/Plugin/*', GLOB_ONLYDIR))) as $root) {
    foreach (rel_files(OLD, $root) as $f) {
        if (!str_ends_with($f, '.php')) continue;
        $src = file_get_contents(OLD . '/' . $f);
        foreach ($removed as $re => $label) if (preg_match($re, $src)) $legacy[] = [$f, $label];
    }
}
$legacy_by = [];
foreach ($legacy as [$f]) { $who = preg_match('#^app/Plugin/([^/]+)/#', $f, $m) ? $m[1] : 'Customize'; $legacy_by[$who] = ($legacy_by[$who] ?? 0) + 1; }

$broken_plugins = [];
foreach ($plugins as $code => $p) {
    $dir = $p['dir'] ?? $code;
    if (($errors_by[$dir] ?? 0) + ($legacy_by[$dir] ?? 0) > 0) $broken_plugins[] = $code;
}
if ($broken_plugins) {
    $reasons[] = '上げた先で動かない見込みのプラグインが ' . count($broken_plugins) . ' 本あります（' . implode('、', $broken_plugins) . '）。対応版に入れ替えるか、直します';
    $asks[] = implode('、', $broken_plugins) . ' はどこから来たものか（オーナーズストアで買ったものなら EC-CUBE ' . $to_ver . ' 対応版が出ているか、店や制作会社が作ったものなら直す）';
}
if (($errors_by['Customize'] ?? 0) + ($legacy_by['Customize'] ?? 0) > 0) $reasons[] = '`app/Customize` に、上げた先で動かない見込みの書き方が ' . (($errors_by['Customize'] ?? 0) + ($legacy_by['Customize'] ?? 0)) . ' 件あります';
$disabled = array_keys(array_filter($plugins, fn($p) => $p['enabled'] === false && $p['dir'] !== null));
if ($disabled) $works[] = '無効のまま入っているプラグイン ' . count($disabled) . ' 本（' . implode('、', $disabled) . '）を、使うか外すか決める（無効のままだと上げるときに列が消える場合がある）';
$orphan = array_keys(array_filter($plugins, fn($p) => $p['dir'] === null));
if ($orphan) $asks[] = 'DB には載っているのにファイルが無いプラグイン（' . implode('、', $orphan) . '）が何か';

// ---------------------------------------------------------------- サーバーの様子（fetch が控えたもの）
$meta = [];
$crons = [];
if (is_file('/meta.env')) {
    foreach (file('/meta.env', FILE_IGNORE_NEW_LINES) as $l) {
        if (!str_contains($l, '=')) continue;
        [$k, $v] = explode('=', $l, 2);
        if ($k === 'cron') $crons[] = $v; else $meta[$k] = $v;
    }
}
if ($crons) $asks[] = '元のサーバーの cron（' . count($crons) . ' 件。下の「サーバー」）を、切り替えたら止める。キットでも要るものは移す';

// ---------------------------------------------------------------- そのほか運ぶもの
[$up_n, $up_bytes] = dir_size(OLD . '/html/upload');
if ($up_n === 0 && isset($meta['upload_files'])) { $up_n = (int) $meta['upload_files']; $up_bytes = (int) ($meta['upload_kb'] ?? 0) * 1024; }
[$ud_n, $ud_bytes] = dir_size(OLD . '/html/user_data');
[$pd_n, $pd_bytes] = dir_size(OLD . '/app/PluginData');
if ($pd_n > 0) $works[] = "`app/PluginData`（プラグインが置いたファイル {$pd_n} 件）を運ぶ。**キットはまだここを保存しないので、取り込みの前に対応が要る**";
$htaccess_changed = is_file(OLD . '/.htaccess') && is_file(FROM . '/.htaccess') && !same(OLD . '/.htaccess', FROM . '/.htaccess');
if ($htaccess_changed) $works[] = '`.htaccess` に足された転送・設定を、キットの nginx（または Cloudflare）へ移す';

// DB
if ($db_kind === 'mysql' && !$dump_info['mariadb']) $works[] = 'DB を MySQL から MariaDB（キットの既定）へ移す';
if ($dump_info['c0900'] > 0) $works[] = "ダンプに MySQL 8 専用の照合順序（`_0900_`）が {$dump_info['c0900']} か所あります。MariaDB へ入れる前に書き換える";
if ($dump_info['routines'] > 0 || $dump_info['definer'] > 0) $asks[] = 'DB のトリガー・ストアドプロシージャ（' . max($dump_info['routines'], $dump_info['definer']) . ' 件）を誰が何のために作ったか';
if ($dump && !$dump_info['complete']) $reasons[] = 'DB のダンプが途中で切れています（完了の行がありません）。取り直してください';
if ($db_kind === 'sqlite') $reasons[] = 'DB が SQLite です。キットは MariaDB / PostgreSQL なので、データの移し替えが要ります';

// 店に必ず確かめること（ファイルからは分からない）
$asks[] = '決済会社の管理画面で、結果通知の URL と、通信を許す IP アドレスを登録しているか（サーバーが変わると届かなくなる）';
$asks[] = 'メールをどこから送っているか（サーバーが変わると SPF / DKIM の設定が要る）';
if (!is_file('/meta.env')) $asks[] = 'サーバーで定期的に動かしている処理（cron）があるか。切り替えたら古いサーバーで止める';
$asks[] = '店の URL がドメインの直下か、`/shop/` のような下の階層か';
if (($env['MAILER_DSN'] ?? '') === '' || str_starts_with($env['MAILER_DSN'] ?? '', 'null:')) $asks[] = 'メールの送り先（MAILER_DSN）が .env に無い。どう送っているか';

// ---------------------------------------------------------------- 報告書
$verdict = $reasons ? '要見積り' : '標準（固定料金で受けられる見込み）';
$L = [];
$L[] = "# 取り込みの事前診断";
$L[] = '';
$L[] = '診断した日: ' . date('Y-m-d') . '　/　EC-CUBE ' . $from_ver . ' → ' . $to_ver;
$L[] = '';
$L[] = "## 判定: {$verdict}";
$L[] = '';
if ($reasons) { $L[] = '固定料金にできない理由:'; $L[] = ''; foreach ($reasons as $r) $L[] = "- $r"; $L[] = ''; }
$L[] = '取り込みでやる作業:';
$L[] = '';
foreach ($works ?: ['特別な作業はありません'] as $w) $L[] = "- $w";
$L[] = '';
$L[] = '店に確かめること:';
$L[] = '';
foreach ($asks as $a) $L[] = "- [ ] $a";
$L[] = '';
$L[] = '## 店の概要';
$L[] = '';
$L[] = '| 項目 | 値 |';
$L[] = '|---|---|';
$L[] = "| EC-CUBE | {$from_ver} |";
$L[] = '| DB | ' . md($db_kind) . ($dump_info['server'] ? '（' . md($dump_info['server']) . '）' : '') . ' `' . md(mask_url($db_url)) . '` |';
$L[] = '| DB のダンプ | ' . ($dump ? human($dump_info['bytes']) . ($dump_info['complete'] ? '・完了の行あり' : '・**完了の行なし**') : '受け取っていない') . ' |';
$L[] = "| 使っているテーマ | {$theme} |";
$L[] = "| 管理画面の URL | /{$admin_route} |";
$L[] = "| 商品画像など（html/upload） | {$up_n} ファイル・" . human($up_bytes) . ' |';
$L[] = "| 独自の CSS / JS（html/user_data） | {$ud_n} ファイル・" . human($ud_bytes) . ' |';
$L[] = "| プラグインが置いたファイル（app/PluginData） | {$pd_n} ファイル・" . human($pd_bytes) . ' |';
$L[] = '| ECCUBE_AUTH_MAGIC | ' . (isset($env['ECCUBE_AUTH_MAGIC']) && $env['ECCUBE_AUTH_MAGIC'] !== '' ? 'あり（引き継ぐ。無いと誰もログインできない）' : '**無い**') . ' |';
$L[] = '';
if ($meta) {
    $same_ok = ($meta['docker'] ?? '') === 'yes' || ($meta['root'] ?? '') === 'yes';
    $mem = (int) ($meta['mem_mb'] ?? 0);
    $L[] = '';
    $L[] = '## サーバー';
    $L[] = '';
    $L[] = '| 項目 | 値 |';
    $L[] = '|---|---|';
    $L[] = '| OS | ' . md($meta['os'] ?? '?') . ' |';
    $L[] = '| PHP | ' . md($meta['php'] ?? '?') . ' |';
    $L[] = '| メモリ | ' . ($mem ? $mem . 'MB' : '?') . ' |';
    $L[] = '| 空きディスク | ' . (isset($meta['disk_free_kb']) ? human((int) $meta['disk_free_kb'] * 1024) : '?') . ' |';
    $L[] = '| Docker / root | ' . md(($meta['docker'] ?? '?') . ' / ' . ($meta['root'] ?? '?')) . ' |';
    $L[] = '| 同じサーバーで移せるか | ' . ($same_ok && $mem >= 4000 ? 'できる見込み（OS の版は上で確かめる）' : '別のサーバーを勧める（' . (!$same_ok ? 'Docker も root も無い' : 'メモリが 4GB 未満') . '）') . ' |';
    foreach ($crons as $c) $L[] = '| cron | `' . md($c) . '` |';
}
$L[] = '';
$L[] = '.env にあるキー（値は書きません）: ' . implode(', ', array_map(fn($k) => "`$k`", array_keys($env)));
$L[] = '';
$L[] = '## 本体の書き換え';
$L[] = '';
if ($core_n === 0) { $L[] = '本体は書き換えられていません。'; }
else {
    $L[] = "同じ版のまっさらな EC-CUBE（{$from_ver}）と比べました。差分は `core.patch` にあります。";
    $L[] = '';
    $L[] = '| ファイル | 状態 | 行 |';
    $L[] = '|---|---|---|';
    foreach ($core['modified'] as [$f, $p, $m]) $L[] = '| `' . md($f) . "` | 書き換え | +{$p} / -{$m} |";
    foreach ($core['added'] as $f) $L[] = '| `' . md($f) . '` | 足したファイル | |';
    foreach ($core['deleted'] as $f) $L[] = '| `' . md($f) . '` | 消したファイル | |';
}
if ($extra_config) { $L[] = ''; $L[] = '店が足した本体の設定（キットでは `app/config/eccube/packages/` へ運べる）: ' . implode(', ', array_map(fn($f) => '`' . $f . '`', $extra_config)); }
if ($own_migrations) { $L[] = ''; $L[] = '店が足した migration: ' . implode(', ', array_map(fn($f) => '`' . $f . '`', $own_migrations)); }
$L[] = '';
$L[] = '## 足されたライブラリ';
$L[] = '';
if (!$libs) $L[] = '本体の composer.json に足されたものはありません。';
else foreach ($libs as $k => $v) $L[] = "- `{$k}`: `{$v}`" . (isset($lib_clash[$k]) ? "（**上げた先の本体は {$lib_clash[$k]} を入れている。合わない**）" : (isset($lock[$k]) ? '（上げた先の本体にもう入っている）' : ''));
$L[] = '';
$L[] = '## テンプレートの写し（app/template）';
$L[] = '';
if (!$tpl_rows) $L[] = '本体のテンプレートを上書きしているファイルはありません。';
else {
    $L[] = "元の版（{$from_ver}）と上げた先（{$to_ver}）の本体、店の写しの 3 つを比べました。";
    $L[] = '';
    $L[] = '| ファイル | 状態 |';
    $L[] = '|---|---|';
    foreach ($tpl_rows as [$f, $s]) $L[] = '| `' . md($f) . "` | {$s} |";
}
$L[] = '';
$L[] = '## テーマ（html/template）';
$L[] = '';
if (!$themes) $L[] = '本体のテーマ（default）だけです。';
else {
    $L[] = '| コード | 使用中 | 静的物 | twig | 自分のコードを URL に直書き |';
    $L[] = '|---|---|---|---|---|';
    foreach ($themes as $t) $L[] = "| {$t['code']} | " . ($t['in_use'] ? '**使用中**' : '—') . " | {$t['files']} ファイル・" . human($t['bytes']) . ($t['style'] ? '' : '（style.css 無し）') . " | {$t['twig']} | " . ($t['hard'] ? implode('<br>', array_map(fn($f) => '`' . md($f) . '`', $t['hard'])) : 'なし') . ' |';
}
$L[] = '';
$L[] = '## プラグイン';
$L[] = '';
if (!$plugins) $L[] = 'プラグインはありません。';
else {
    $L[] = "上げた先（{$to_ver}）の本体に対して PHPStan で読み、元の版では出ずに上げた先でだけ出る誤りを数えました（`phpstan-new.txt`）。";
    $L[] = '';
    $L[] = '| コード | 版（ファイル / DB） | 状態 | 上げた先で出る誤り | Symfony 6 で消えた書き方 |';
    $L[] = '|---|---|---|---|---|';
    foreach ($plugins as $code => $p) {
        $dir = $p['dir'] ?? $code;
        $state = $p['dir'] === null ? '**ファイルが無い**' : ($p['enabled'] === null ? '未インストール？（DB に無い）' : ($p['enabled'] ? '有効' : '無効'));
        $L[] = '| ' . md($code) . ' | ' . md($p['version']) . ' / ' . md((string) ($p['db'] ?? '—')) . " | {$state} | " . ($errors_by[$dir] ?? 0) . ' | ' . ($legacy_by[$dir] ?? 0) . ' |';
    }
}
$L[] = '';
$L[] = '## app/Customize';
$L[] = '';
$cust = array_filter(rel_files(OLD, 'app/Customize'), fn($f) => str_ends_with($f, '.php'));
$cust_from = array_flip(rel_files(FROM, 'app/Customize'));
$cust_own = array_values(array_filter($cust, fn($f) => !isset($cust_from[$f]) || !same(OLD . "/$f", FROM . "/$f")));
$loc = 0; foreach ($cust_own as $f) $loc += count(file(OLD . "/$f"));
$L[] = '店が書いた PHP: ' . count($cust_own) . " ファイル・{$loc} 行。上げた先で出る誤り: " . ($errors_by['Customize'] ?? 0) . ' 件、Symfony 6 で消えた書き方: ' . ($legacy_by['Customize'] ?? 0) . ' 件';
$L[] = '';
$L[] = '## 上げた先で動かない見込みの箇所';
$L[] = '';
if (!$legacy && !$new_errors) $L[] = '見つかりませんでした。';
if ($legacy) {
    $L[] = 'Symfony 6 で消えた書き方（PHPStan の水準では拾わないものを、名前で探したもの）:';
    $L[] = '';
    foreach ($legacy as [$f, $label]) $L[] = '- `' . md($f) . "`: {$label}";
}
if ($new_errors) {
    $L[] = '';
    $L[] = '上げた先でだけ出る誤り（先頭 20 件。全部は `phpstan-new.txt`）:';
    $L[] = '';
    foreach (array_slice($new_errors, 0, 20) as $e) $L[] = '- `' . md(mb_strimwidth($e, 0, 300, '…')) . '`';
}
$L[] = '';
$L[] = '---';
$L[] = '';
$L[] = 'この診断はファイルと DB のダンプを読んだだけです。画面の動き・決済・メールは、取り込んだあとの検証の環境で確かめます。';
file_put_contents(OUT . '/report.md', implode("\n", $L) . "\n");

// bin/import.sh が端末に出す要約
echo "VERDICT={$verdict}\n";
foreach ($reasons as $r) echo "REASON={$r}\n";
foreach ($works as $w) echo "WORK={$w}\n";

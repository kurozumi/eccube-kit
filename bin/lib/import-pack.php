<?php
/*
 * bin/import.sh load が、キットの EC-CUBE のイメージの中で動かす詰め直し。
 * 元の店のファイルとダンプを、bin/restore.sh が読むバックアップの形（backups/<日時>-import-<名前>/）にし、
 * git で追うもの（app/Customize・composer.extra.json）はキットの作業ツリーへ書く。元の店には書かない。
 *
 *   /old   … 元の店（読み取り専用）
 *   /from  … 元の店と同じ版のまっさらな EC-CUBE
 *   /kit   … キットの作業ツリー（app/Customize と composer.extra.json だけ書く）
 *   /out   … バックアップの形の置き場
 *   /dump  … DB のダンプ（.sql / .sql.gz）
 *
 * 引数: <check|pack> <使っているテーマのコード（default なら空）>
 *   check … 書く前に、止めるべき食い違いだけを見る（何も書かない）。出力: STOP=<理由>
 *   pack  … 書く。出力: NOTE=<伝えること>
 */

const OLD = '/old';
const FROM = '/from';
const KIT = '/kit';
const OUT = '/out';

$mode = $argv[1] ?? 'check';
$theme = $argv[2] ?? '';

function rel_files(string $root, string $sub = ''): array
{
    $base = rtrim($root, '/') . ($sub === '' ? '' : '/' . $sub);
    if (!is_dir($base)) return is_file($base) ? [$sub] : [];
    $out = [];
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($base, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $f) if ($f->isFile()) $out[] = ltrim(substr($f->getPathname(), strlen(rtrim($root, '/'))), '/');
    sort($out);
    return $out;
}
function same(string $a, string $b): bool
{
    return is_file($a) && is_file($b) && filesize($a) === filesize($b) && hash_file('sha256', $a) === hash_file('sha256', $b);
}
function put(string $dst, string $src): void
{
    @mkdir(dirname($dst), 0775, true);
    copy($src, $dst) || throw new RuntimeException("写せませんでした: $src → $dst");
}
function sh(string $cmd): void
{
    passthru($cmd, $rc);
    if ($rc !== 0) throw new RuntimeException("失敗しました: $cmd");
}

// 店が書いた app/Customize のファイル（まっさらな EC-CUBE と違うもの）
$customize = [];
foreach (rel_files(OLD, 'app/Customize') as $f) {
    if (basename($f) === '.gitkeep' || basename($f) === 'readme') continue;
    if (same(OLD . "/$f", FROM . "/$f")) continue;
    $customize[] = $f;
}
// 店が足した migration
$migrations = array_values(array_filter(rel_files(OLD, 'app/DoctrineMigrations'), fn($f) => !is_file(FROM . "/$f")));

// ---------------------------------------------------------------- check
$stops = [];
foreach ($customize as $f) {
    if ($f === 'app/Customize/Resource/config/services.yaml') continue; // 店のものを使う（下で伝える）
    if (is_file(KIT . "/$f") && !same(OLD . "/$f", KIT . "/$f")) $stops[] = "キットにも同じ名前のファイルがあります: {$f}（手で合わせてから、もう一度）";
}
if ($migrations) $stops[] = '店が足した migration があります（' . implode(', ', $migrations) . '）。名前空間と DB の記録を合わせる必要があるので、いまは手で移します（docs/import.md）';
if ($mode === 'check') {
    foreach ($stops as $s) echo "STOP={$s}\n";
    exit(0);
}
if ($stops) { foreach ($stops as $s) fwrite(STDERR, "$s\n"); exit(1); }

$notes = [];

// ---------------------------------------------------------------- app/Customize（git で追うので作業ツリーへ）
foreach ($customize as $f) put(KIT . "/$f", OLD . "/$f");
if (in_array('app/Customize/Resource/config/services.yaml', $customize, true)) {
    $notes[] = '店の app/Customize/Resource/config/services.yaml を使いました。キットのメール疎通コマンドを使うなら、services: の下に「Customize\\Command\\MailTestCommand: ~」を足してください';
}
if ($customize) $notes[] = 'app/Customize に店のファイルを ' . count($customize) . ' 件入れました（git で追ってください）';

// 足されたライブラリを composer.extra.json へ
$cj_old = json_decode(@file_get_contents(OLD . '/composer.json') ?: '{}', true) ?: [];
$cj_from = json_decode(@file_get_contents(FROM . '/composer.json') ?: '{}', true) ?: [];
$libs = array_diff_key($cj_old['require'] ?? [], $cj_from['require'] ?? []);
if ($libs) {
    $p = KIT . '/app/Customize/composer.extra.json';
    $j = json_decode(@file_get_contents($p) ?: '{}', true) ?: [];
    $j['require'] = array_merge((array) ($j['require'] ?? []), $libs);
    if ($j['require'] === []) $j['require'] = new stdClass();
    file_put_contents($p, json_encode($j, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n");
    $notes[] = '足されたライブラリ ' . count($libs) . ' 件を app/Customize/composer.extra.json に書きました（起動時に入ります）';
}

// ---------------------------------------------------------------- admin-files.tar.gz（app/template・html/user_data・app/Plugin）
$stage = '/tmp/stage';
sh('rm -rf ' . $stage . ' && mkdir -p ' . $stage);
$skipped = 0;
foreach (rel_files(OLD, 'app/template') as $f) {
    if (basename($f) === '.gitkeep') continue;
    // 使っているテーマの twig は theme.sh で original へ入れる
    if ($theme !== '' && str_starts_with($f, "app/template/{$theme}/")) continue;
    // 本体と同じ写しは運ばない（運ぶと、本体を上げても古いほうが勝ち続ける）
    if (preg_match('#^app/template/(default|admin)/(.+)$#', $f, $m)) {
        $core = FROM . '/src/Eccube/Resource/template/' . $m[1] . '/' . $m[2];
        if (same(OLD . "/$f", $core)) { $skipped++; continue; }
    }
    put("$stage/$f", OLD . "/$f");
}
if ($skipped) $notes[] = "本体と同じテンプレートの写し {$skipped} 件は運びませんでした";

// html/user_data。customize.css はキットのもの（1 行目でテーマを読み込む @import）の後ろに店の中身を足す
foreach (rel_files(OLD, 'html/user_data') as $f) {
    if (basename($f) === '.gitkeep') continue;
    if ($f === 'html/user_data/assets/css/customize.css') {
        $shop = file_get_contents(OLD . "/$f");
        $kit = file_get_contents(KIT . "/$f");
        if (same(OLD . "/$f", FROM . "/$f") || trim($shop) === '') continue;
        // 店の @import は先頭にしか効かないので、キットの @import（テーマを読む行）のすぐ後ろへ移す
        preg_match_all('/^\s*@import[^;]*;\s*$/m', $shop, $im);
        $body = trim(preg_replace('/^\s*@import[^;]*;\s*$/m', '', $shop));
        if ($im[0] && preg_match('/@import[^;]*customize-theme\.css[^;]*;/', $kit, $km, PREG_OFFSET_CAPTURE)) {
            $at = $km[0][1] + strlen($km[0][0]);
            $kit = substr($kit, 0, $at) . "\n" . implode("\n", array_map('trim', $im[0])) . substr($kit, $at);
        }
        $merged = rtrim($kit) . "\n\n/* ---- 元の店の customize.css ---- */\n" . $body . "\n";
        @mkdir(dirname("$stage/$f"), 0775, true);
        file_put_contents("$stage/$f", $merged);
        $notes[] = 'customize.css は、キットのもの（テーマの @import）の後ろに店の中身を足しました';
        continue;
    }
    if ($f === 'html/user_data/assets/js/customize.js' && same(OLD . "/$f", FROM . "/$f")) continue;
    put("$stage/$f", OLD . "/$f");
}
// プラグイン（.git は運ばない。backup.sh と同じ）
foreach (rel_files(OLD, 'app/Plugin') as $f) {
    if (basename($f) === '.gitkeep' || str_contains($f, '/.git/')) continue;
    put("$stage/$f", OLD . "/$f");
}
sh("mkdir -p $stage/app/template $stage/html/user_data $stage/app/Plugin && tar -C $stage -czf " . OUT . '/admin-files.tar.gz app/template html/user_data app/Plugin');
$plugins_txt = '';
foreach (glob(OLD . '/app/Plugin/*', GLOB_ONLYDIR) as $d) $plugins_txt .= basename($d) . "\t-\n";
file_put_contents(OUT . '/plugins.txt', $plugins_txt);

// ---------------------------------------------------------------- テーマ（theme.sh install が読む形: app/ と html/）
if ($theme !== '') {
    $t = '/tmp/theme';
    sh("rm -rf $t && mkdir -p $t/app $t/html");
    if (is_dir(OLD . "/app/template/$theme")) sh('cp -a ' . escapeshellarg(OLD . "/app/template/$theme") . "/. $t/app/");
    if (is_dir(OLD . "/html/template/$theme")) sh('cp -a ' . escapeshellarg(OLD . "/html/template/$theme") . "/. $t/html/");
    sh("tar -C $t -czf " . OUT . "/theme-{$theme}.tar.gz app html");
}

// ---------------------------------------------------------------- 画像と PluginData（ボリュームへ戻すもの）
sh('mkdir -p /tmp/u && ln -sfn ' . escapeshellarg(OLD . '/html/upload') . ' /tmp/u/upload && tar -C /tmp/u -czhf ' . OUT . '/upload.tar.gz upload');
if (rel_files(OLD, 'app/PluginData') && array_filter(rel_files(OLD, 'app/PluginData'), fn($f) => basename($f) !== '.gitkeep')) {
    sh('tar -C ' . escapeshellarg(OLD . '/app') . ' -czf ' . OUT . '/plugindata.tar.gz PluginData');
}

// ---------------------------------------------------------------- DB
$dump = is_file('/dump/dump.sql.gz') ? '/dump/dump.sql.gz' : '/dump/dump.sql';
$in = str_ends_with($dump, '.gz') ? gzopen($dump, 'r') : fopen($dump, 'r');
$outz = gzopen(OUT . '/db.sql.gz', 'w6');
$mysql = null; $changed = 0;
while (($l = (str_ends_with($dump, '.gz') ? gzgets($in) : fgets($in))) !== false) {
    if ($mysql === null && preg_match('/^-- (MySQL|MariaDB) dump/', $l)) $mysql = true;
    if ($mysql === null && str_starts_with($l, '-- PostgreSQL database dump')) $mysql = false;
    if ($mysql) {
        // 別の DB へ入れ替えない（キットの DB 名へ流す）。MySQL 8 だけの書き方を MariaDB が読める形に
        if (preg_match('/^(USE |CREATE DATABASE )/', $l)) { $changed++; continue; }
        if (preg_match('/^SET @@(GLOBAL\.GTID_PURGED|SESSION\.SQL_LOG_BIN)|^SET @MYSQL_DUMP_TEMP_LOG_BIN/', $l)) { $changed++; continue; }
        $n = str_replace(['utf8mb4_0900_ai_ci', 'utf8mb4_0900_as_cs', 'utf8mb4_0900_bin'], ['utf8mb4_general_ci', 'utf8mb4_bin', 'utf8mb4_bin'], $l, $c);
        $n = preg_replace('#/\*!80016 DEFAULT ENCRYPTION=\'N\' \*/#', '', $n, -1, $c2);
        $changed += $c + $c2;
        $l = $n;
    }
    gzwrite($outz, $l);
}
gzclose($outz);
if ($changed) $notes[] = "DB のダンプの {$changed} か所を MariaDB 向けに書き換えました（MySQL 8 の照合順序・GTID・USE など）";

// host.env（restore.sh が ECCUBE_AUTH_MAGIC を突き合わせる）
$env = [];
foreach (@file(OLD . '/.env', FILE_IGNORE_NEW_LINES) ?: [] as $l) if (preg_match('/^\s*([A-Z0-9_]+)\s*=\s*(.*)$/', $l, $m)) $env[$m[1]] = trim($m[2], " \"'");
file_put_contents(OUT . '/host.env', 'ECCUBE_AUTH_MAGIC=' . ($env['ECCUBE_AUTH_MAGIC'] ?? '') . "\n");
chmod(OUT . '/host.env', 0600);

foreach ($notes as $n) echo "NOTE={$n}\n";

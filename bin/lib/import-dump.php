<?php
/*
 * 元の店の DB のダンプ（mysqldump / pg_dump）から dtb_plugin の行を読む。import-diagnose.php が require し、
 * bin/import.sh cutover はこれを直接動かして、元の店のプラグインがこのキットにそろっているかを見る。
 *
 * 直接動かすとき（キットの EC-CUBE のイメージの中で）:
 *   /dump/dump.sql(.gz)  … ダンプ
 *   /plugin              … このキットの app/Plugin（読み取り専用）
 *   出力（1 行ずつ。タブ区切り）:
 *     MISSING=<コード>\t<1 有効|0 無効>      元の店の DB にあって、このキットの app/Plugin に無い
 *     UPDATE=<コード>\t<DB の版>\t<ファイルの版>  版が違う（bin/plugin.sh sync が更新する）
 *     EXTRA=<コード>                          このキットにあって、元の店の DB に無い（切り替えのあとで入れる）
 */

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

/** ダンプを 1 行ずつ渡すと、dtb_plugin の行を集める（MySQL: CREATE TABLE の列と INSERT、PostgreSQL: COPY） */
final class DumpPluginRows
{
    public array $rows = [];
    private ?array $cols = null;
    private bool $inCopy = false;
    private bool $inCreate = false;
    private ?string $insert = null;

    public function feed(string $l): void
    {
        if (preg_match('/^CREATE TABLE [`"]?(?:public\.)?dtb_plugin[`"]? \(/', $l)) { $this->cols = []; $this->inCreate = true; return; }
        if ($this->inCreate && str_starts_with($l, ')')) { $this->inCreate = false; return; }
        if ($this->inCopy) {
            if (rtrim($l) === '\.') { $this->inCopy = false; $this->cols = null; return; }
            $t = array_map(fn($x) => $x === '\N' ? null : $x, explode("\t", rtrim($l, "\n")));
            $this->rows[] = array_combine(array_slice($this->cols, 0, count($t)), $t);
            return;
        }
        if ($this->inCreate && preg_match('/^\s+[`"]?(\w+)[`"]?\s+\w/', $l, $m) && !preg_match('/^\s+(PRIMARY|UNIQUE|KEY|CONSTRAINT|INDEX)\b/', $l)) { $this->cols[] = $m[1]; return; }
        // mariadb-dump（キットの fetch が使う）は `INSERT INTO ... VALUES` で改行し、行を 1 行ずつ並べて `;` で終える。
        // mysqldump は 1 行に詰める。どちらも `;` で終わる行までをまとめて読む
        if ($this->insert !== null || preg_match('/^INSERT INTO [`"]?dtb_plugin[`"]? /', $l)) {
            $this->insert = ($this->insert ?? '') . $l;
            if (!preg_match('/;\s*$/', $l)) return;
            $stmt = $this->insert; $this->insert = null;
            if (preg_match('/^INSERT INTO [`"]?dtb_plugin[`"]? (?:\(([^)]*)\) )?VALUES\s*(.*);\s*$/s', $stmt, $m)) {
                $c = $m[1] ? array_map(fn($x) => trim($x, " `\""), explode(',', $m[1])) : ($this->cols ?? []);
                foreach (sql_tuples($m[2]) as $t) $this->rows[] = array_combine(array_slice($c, 0, count($t)), $t);
            }
            return;
        }
        if (preg_match('/^COPY (?:public\.)?dtb_plugin \(([^)]*)\) FROM stdin;/', $l, $m)) { $this->cols = array_map('trim', explode(',', $m[1])); $this->inCopy = true; }
    }

    public static function enabled(array $r): bool
    {
        return in_array((string) ($r['enabled'] ?? ''), ['1', 't', 'true'], true);
    }
}

if (PHP_SAPI === 'cli' && realpath($argv[0] ?? '') === __FILE__) {
    $dump = null;
    foreach (['/dump/dump.sql.gz', '/dump/dump.sql'] as $p) if (is_file($p)) $dump = $p;
    if ($dump === null) { fwrite(STDERR, "ダンプがありません\n"); exit(1); }
    $gz = str_ends_with($dump, '.gz');
    $h = $gz ? gzopen($dump, 'r') : fopen($dump, 'r');
    $pr = new DumpPluginRows();
    $seen = false;
    while (($l = $gz ? gzgets($h) : fgets($h)) !== false) {
        if (!$seen && preg_match('/dtb_plugin/', $l)) $seen = true;
        $pr->feed($l);
    }
    // 表そのものが無いダンプは、そろっているかを判断できない（空の店と見分けがつかない）
    if (!$seen) { fwrite(STDERR, "ダンプに dtb_plugin がありません\n"); exit(1); }
    $db = [];
    foreach ($pr->rows as $r) if (($r['code'] ?? '') !== '') $db[$r['code']] = $r;
    ksort($db);
    foreach ($db as $code => $r) {
        $dir = "/plugin/$code";
        if (!is_dir($dir)) { echo "MISSING={$code}\t" . (DumpPluginRows::enabled($r) ? 1 : 0) . "\n"; continue; }
        $cj = json_decode(@file_get_contents("$dir/composer.json") ?: '{}', true) ?: [];
        $ver = (string) ($cj['version'] ?? '?');
        if ($ver !== (string) ($r['version'] ?? '')) echo "UPDATE={$code}\t" . ($r['version'] ?? '?') . "\t{$ver}\n";
    }
    foreach (glob('/plugin/*', GLOB_ONLYDIR) ?: [] as $d) {
        if (!isset($db[basename($d)]) && is_file("$d/composer.json")) echo 'EXTRA=' . basename($d) . "\n";
    }
}

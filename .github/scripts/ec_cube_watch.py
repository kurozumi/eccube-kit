#!/usr/bin/env python3
"""EC-CUBE 公式のセキュリティ情報を見張る（ec-cube-watch.yml）。

見るもの（どれも機械で読めるもの）:
  - 脆弱性リスト https://www.ec-cube.net/info/weakness/ … 1 行ごとの weakness.php?id=<番号>
  - GitHub の EC-CUBE/ec-cube のセキュリティ勧告（GHSA）
  - 開発者向けのセキュリティガイドライン（EC-CUBE/doc4.ec-cube.net の _pages/security-guideline/）の最後の commit

サイト運営者向けの「セキュリティ対策ガイドライン」（/security/guideline/）はブラウザの確認がかかっていて
機械では読めない（すり抜けない）。そちらは月 1 回の Issue で人に知らせる（ワークフロー側）。

使い方: ec_cube_watch.py <前回の状態.json（無ければ空のファイル）> <出力先ディレクトリ>
  出力: report.md（新しく出たもの）/ all.md（いまの一覧）/ state.json（次回の比較用）
  標準出力の最後に changed=true|false、errors=true|false、first=true|false（GITHUB_OUTPUT 用）

**読めなかった元は「消えた」と取り違えない。** 前回の状態をそのまま引き継ぎ、errors=true にする。
"""
import html
import json
import os
import re
import sys
import urllib.request

UA = "eccube-kit-watch (+https://github.com/kurozumi/eccube-kit)"
WEAKNESS_URL = "https://www.ec-cube.net/info/weakness/"
GH_API = "https://api.github.com"


def get(url, accept=None):
    headers = {"User-Agent": UA}
    if accept:
        headers["Accept"] = accept
    token = os.environ.get("GH_TOKEN")
    if token and url.startswith(GH_API):
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def weakness():
    page = get(WEAKNESS_URL)
    items = {}
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", page, re.S):
        m = re.search(r'href="\./weakness\.php\?id=(\d+)"[^>]*>(.*?)</a>', row, re.S)
        if not m:
            continue
        cells = [re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", c))).strip()
                 for c in re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)]
        wid, title = m.group(1), re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", m.group(2)))).strip()
        date, versions, severity = (cells + ["", "", ""])[:3]
        items[f"weakness:{wid}"] = {
            "title": title,
            "detail": f"{date}・対象 {versions}・深刻度 {severity}",
            "url": f"https://www.ec-cube.net/info/weakness/weakness.php?id={wid}",
        }
    if not items:
        # 形が変わった・確認のページが返った。0 件を「全部消えた」と読まない
        raise RuntimeError("脆弱性の行を 1 つも読めませんでした（ページの形が変わったか、ブラウザの確認が返った）")
    return items


def advisories():
    data = json.loads(get(f"{GH_API}/repos/EC-CUBE/ec-cube/security-advisories?per_page=100",
                          "application/vnd.github+json"))
    return {
        f"ghsa:{a['ghsa_id']}": {
            "title": a.get("summary") or a["ghsa_id"],
            "detail": f"{(a.get('published_at') or '')[:10]}・深刻度 {a.get('severity') or '?'}"
                      + (f"・{a['cve_id']}" if a.get("cve_id") else ""),
            "url": a.get("html_url") or f"https://github.com/EC-CUBE/ec-cube/security/advisories/{a['ghsa_id']}",
        }
        for a in data
    }


def doc4():
    data = json.loads(get(f"{GH_API}/repos/EC-CUBE/doc4.ec-cube.net/commits?path=_pages/security-guideline&per_page=1",
                          "application/vnd.github+json"))
    if not data:
        raise RuntimeError("_pages/security-guideline の commit がありません（置き場所が変わった？）")
    c = data[0]
    return {
        f"doc4:{c['sha'][:12]}": {
            "title": "開発者向けセキュリティガイドラインが更新された: " + c["commit"]["message"].splitlines()[0],
            "detail": c["commit"]["committer"]["date"][:10],
            "url": c["html_url"],
        }
    }


SOURCES = [
    ("weakness", "脆弱性リスト（ec-cube.net）", weakness),
    ("ghsa", "GitHub のセキュリティ勧告（EC-CUBE/ec-cube）", advisories),
    ("doc4", "開発者向けセキュリティガイドライン（doc4.ec-cube.net）", doc4),
]


def line(key, it):
    return f"- [{it['title']}]({it['url']})（{it['detail']}）"


def main():
    prev_path, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    prev = {}
    if os.path.getsize(prev_path) > 0:
        prev = json.load(open(prev_path, encoding="utf-8"))
    first = not prev
    state, new, errors = {}, [], []
    for prefix, label, fn in SOURCES:
        try:
            got = fn()
        except Exception as e:  # noqa: BLE001  読めなかった元は前回を引き継ぐ
            errors.append(f"- {label}: {e}")
            got = {k: v for k, v in prev.items() if k.startswith(prefix + ":")}
        state.update(got)
        for k, it in got.items():
            if k not in prev:
                new.append((label, k, it))

    with open(os.path.join(out, "state.json"), "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, sort_keys=True)

    with open(os.path.join(out, "all.md"), "w", encoding="utf-8") as f:
        for prefix, label, _ in SOURCES:
            f.write(f"### {label}\n\n")
            for k in sorted((k for k in state if k.startswith(prefix + ":")), key=lambda k: (len(k), k), reverse=True)[:10]:
                f.write(line(k, state[k]) + "\n")
            f.write("\n")

    with open(os.path.join(out, "report.md"), "w", encoding="utf-8") as f:
        if new and not first:
            f.write("EC-CUBE の公式のセキュリティ情報に、前回から増えたものがあります。\n\n")
            for label in dict.fromkeys(lbl for lbl, _, _ in new):
                f.write(f"### {label}\n\n")
                for lbl, k, it in new:
                    if lbl == label:
                        f.write(line(k, it) + "\n")
                f.write("\n")
            f.write("## やること\n\n"
                    "1. 中身を読み、配っている系列（4.2・4.3・4.4）と店に関係するかを決める\n"
                    "2. 本体の修正なら、修正版が出たら `bin/upgrade.sh` の案内をリリースノートに書く。"
                    "修正ファイルの配布だけなら、キットで当てられるかを調べる\n"
                    "3. 運用の手順が変わるなら `docs/security.md` を直す\n\n"
                    "手元の Claude Code にこの Issue を渡してよい。\n\n")
        if errors:
            f.write("## 読めなかったもの\n\n" + "\n".join(errors) + "\n\n"
                    "前回の状態を引き継いでいます（消えたとは扱っていません）。続くようなら見る先を直す。\n")

    print(f"changed={'true' if new and not first else 'false'}")
    print(f"errors={'true' if errors else 'false'}")
    print(f"first={'true' if first else 'false'}")


if __name__ == "__main__":
    main()

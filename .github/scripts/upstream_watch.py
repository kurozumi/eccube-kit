#!/usr/bin/env python3
"""上流（EC-CUBE・PHP）の新しい版を見張る（upstream-watch.yml）。

キットが配っているもの（.github/build-matrix.json）と、上流にあるものを毎日比べる。

  1. パッチ版（4.3.1 → 4.3.2）    … 配っている系列に新しい安定版が出た。
                                     イメージは焼いた時点の版のままなので、その系列を当日焼き直す（action: build）。
                                     店に届けるのは店の人の `bin/upgrade.sh`（勝手には上げない）。
  2. 正式版の初登場（4.4.0）      … matrix が `4.4.x-dev` のまま、上流に 4.4 の安定版が出た。
                                     matrix を `~4.4.0` に変える PR を作る（action: stable_pr）。
  3. プレリリース（4.4.0-RC1 など） … 知らせるだけ。
  4. 新しい系列（4.5）            … 上流のブランチか Packagist に、matrix に無い新しい系列が出た。
                                     移植は人（プラグイン全数・PHP・phpredis）。手順を Issue に並べる。
  5. 系列が許す PHP が変わった    … 上流の各系列のブランチの composer.json の require.php。
  6. 新しい PHP（8.6）            … endoflife.date に、キットのどの系列も配っていない新しい PHP が出た。
  7. 上流が対応する PHP           … 上流の各系列の README の対応一覧か CI（unit-test.yml の matrix）に、キットがその系列で
                                     配っているいちばん新しい PHP より新しい版が載った。composer.json の制約（5）は
                                     広い（4.4 は `^8.2`）ので、上流が実際に足した日はここでしか分からない。
  8. phpredis の正式版            … PECL に、キットが使っているより新しい phpredis の正式版（stable）が出た。
                                     新しい PHP は phpredis が組めないと焼けない（6.3.0 は PHP 8.6 で組めない）。

使い方: upstream_watch.py <.github/build-matrix.json> <前回の状態.json（無ければ空）> <出力先>
  出力: report.md / state.json / actions.json（{"build": [系列…], "stable_pr": [{"series", "latest"}…]}）
  標準出力の最後に changed= / errors= / first=（GITHUB_OUTPUT 用）

**読めなかった元は「消えた」「変わった」と取り違えない。** 前回の状態を引き継ぎ、errors=true にする。
**初回は、履歴で決まるもの（1 と 3）を知らせない**（いまある全部を「新しい」と言わない）。
2・4・5・6・7・8 は「いまの状態」で決まるので、初回でも知らせる（知らせたものは state に入り、二度は言わない）。
"""
import json
import os
import re
import sys
import urllib.request

UA = "eccube-kit-upstream-watch (+https://github.com/kurozumi/eccube-kit)"
GH_API = "https://api.github.com"
PACKAGIST = "https://repo.packagist.org/p2/ec-cube/ec-cube.json"
EOL_PHP = "https://endoflife.date/api/php.json"
RAW = "https://raw.githubusercontent.com/EC-CUBE/ec-cube"
PECL_REDIS = "https://pecl.php.net/rest/r/redis/allreleases.xml"


def get(url):
    headers = {"User-Agent": UA}
    token = os.environ.get("GH_TOKEN")
    if token and url.startswith(GH_API):
        headers["Authorization"] = f"Bearer {token}"
        headers["Accept"] = "application/vnd.github+json"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def vt(s):
    """'4.10' → (4, 10)。比べるため"""
    return tuple(int(x) for x in re.findall(r"\d+", s))


def kit_matrix(path):
    """build-matrix.json を読む。{系列: {"eccube": 制約, "php": [版…]}}"""
    rows = json.load(open(path, encoding="utf-8"))
    if not rows:
        raise RuntimeError("build-matrix.json を読めませんでした（形が変わった？）")
    kit = {}
    for r in rows:
        k = kit.setdefault(r["series"], {"eccube": r["eccube"], "php": [], "phpredis": []})
        k["php"].append(r["php"])
        if r.get("phpredis") and r["phpredis"] not in k["phpredis"]:
            k["phpredis"].append(r["phpredis"])
    return kit


def readme_php(text):
    """上流の README の対応一覧（`* PHP 8.2.x / 8.3.x`）から PHP の版を取る。見つからなければ例外（書き方が変わった）"""
    m = re.search(r"^\*\s*PHP\s+(.+)$", text, re.M)
    if not m:
        raise RuntimeError("「* PHP …」の行が見つからない（書き方が変わった？）")
    vs = sorted(set(re.findall(r"\d+\.\d+", m.group(1))), key=vt)
    if not vs:
        raise RuntimeError(f"PHP の版が読めない: {m.group(0)!r}")
    return vs


def ci_php(text):
    """上流の unit-test.yml の matrix（`php: [ '8.2', '8.3' ]`）から PHP の版を取る。見つからなければ例外"""
    m = re.search(r"^\s+php:\s*\[([^\]]*)\]", text, re.M)
    if not m:
        raise RuntimeError("matrix の「php: [ … ]」が見つからない（書き方が変わった？）")
    vs = sorted(set(re.findall(r"\d+\.\d+", m.group(1))), key=vt)
    if not vs:
        raise RuntimeError(f"PHP の版が読めない: {m.group(0).strip()!r}")
    return vs


def is_stable(series, v):
    return re.fullmatch(rf"{re.escape(series)}\.\d+(\.\d+)?(-p\d+)?", v) is not None


def is_pre(series, v):
    return v.startswith(series + ".") and re.search(r"-(alpha|beta|rc)", v, re.I) is not None


def main():
    matrix_path, prev_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(out, exist_ok=True)
    prev = json.load(open(prev_path, encoding="utf-8")) if os.path.getsize(prev_path) > 0 else {}
    first = not prev
    kit = kit_matrix(matrix_path)
    kit_max = max(kit, key=vt)
    kit_php = sorted({p for k in kit.values() for p in k["php"]}, key=vt)

    state, errors = {}, []
    events = []          # (種類, 本文)
    actions = {"build": [], "stable_pr": []}

    def carry(prefix):
        state.update({k: v for k, v in prev.items() if k.startswith(prefix)})

    # ---- Packagist（1・2・3・4）
    versions = None
    try:
        data = json.loads(get(PACKAGIST))
        versions = [p["version"] for p in data["packages"]["ec-cube/ec-cube"] if p.get("version")]
        if not versions:
            raise RuntimeError("版が 1 つも無い")
    except Exception as e:  # noqa: BLE001
        errors.append(f"- Packagist（ec-cube/ec-cube）: {e}")
        carry("ver:")
        carry("stable:")
    if versions is not None:
        for s, k in kit.items():
            dev = k["eccube"].endswith("x-dev")
            stables = [v for v in versions if is_stable(s, v)]
            for v in versions:
                if not v.startswith(s + "."):
                    continue
                key = f"ver:{v}"
                state[key] = 1
                if key in prev or first:
                    continue
                if is_stable(s, v) and not dev:
                    events.append(("patch", f"EC-CUBE **{v}** が出ました（{s} 系）。{s} のイメージを今日焼き直します。"))
                    if s not in actions["build"]:
                        actions["build"].append(s)
                elif is_pre(s, v):
                    events.append(("pre", f"EC-CUBE **{v}**（プレリリース）が出ました。知らせるだけです（配る版は変えません）。"))
            if dev and stables:
                key = f"stable:{s}"
                state[key] = 1
                if key not in prev:
                    latest = max(stables, key=vt)
                    events.append(("stable", f"EC-CUBE **{s} の正式版（{latest}）** が出ました。いまの matrix は `{k['eccube']}`"
                                             f"（開発ブランチ）のままです。`~{s}.0` に変える PR を作ります。"))
                    actions["stable_pr"].append({"series": s, "latest": latest})
        for v in versions:
            m = re.match(r"(\d+\.\d+)\.", v)
            if m and vt(m.group(1)) > vt(kit_max):
                key = f"series:{m.group(1)}"
                if key not in state:
                    state[key] = 1
                    if key not in prev:
                        events.append(("series", f"EC-CUBE **{m.group(1)} 系**が Packagist に出ました（{v}）。キットはまだ配っていません。"))

    # ---- 上流のブランチ（4）と各系列の composer.json（5）
    try:
        branches = json.loads(get(f"{GH_API}/repos/EC-CUBE/ec-cube/branches?per_page=100"))
        names = [b["name"] for b in branches]
        if not names:
            raise RuntimeError("ブランチが 1 つも無い")
        for b in names:
            if re.fullmatch(r"\d+\.\d+", b) and vt(b) > vt(kit_max):
                key = f"series:{b}"
                if key not in state:
                    state[key] = 1
                    if key not in prev:
                        events.append(("series", f"EC-CUBE の上流に **{b} ブランチ**ができました。キットはまだ配っていません。"))
    except Exception as e:  # noqa: BLE001
        errors.append(f"- 上流のブランチ（EC-CUBE/ec-cube）: {e}")
    carry("series:")   # 一度知らせた系列は、読めない日にも覚えておく

    for s in sorted(kit, key=vt):
        try:
            req = json.loads(get(f"{RAW}/{s}/composer.json"))["require"]["php"]
        except Exception as e:  # noqa: BLE001
            errors.append(f"- {s} ブランチの composer.json: {e}")
            carry(f"phpreq:{s}")
            continue
        key = f"phpreq:{s}"
        state[key] = req
        if key in prev and prev[key] != req:
            events.append(("phpreq", f"EC-CUBE {s} が許す PHP が変わりました: `{prev[key]}` → `{req}`"
                                     f"（キットが配っている PHP: {' / '.join(kit[s]['php'])}）。"))

    # ---- 上流が対応する PHP（7）。キットがその系列で配っているいちばん新しい PHP より新しいものだけ
    #      （4.2 の README は 7.4〜8.1 だが、キットは 8.1 / 8.2 を配る。古いほうは知らせない）
    for s in sorted(kit, key=vt):
        top = max(kit[s]["php"], key=vt)
        found = {}
        for label, url, parse in (("README の対応一覧", f"{RAW}/{s}/README.md", readme_php),
                                  ("CI（unit-test.yml）", f"{RAW}/{s}/.github/workflows/unit-test.yml", ci_php)):
            try:
                for v in parse(get(url)):
                    if vt(v) > vt(top):
                        found.setdefault(v, []).append(label)
            except Exception as e:  # noqa: BLE001
                errors.append(f"- {s} ブランチの{label}: {e}")
                carry(f"upphp:{s}:")
        for v, where in sorted(found.items(), key=lambda x: vt(x[0])):
            key = f"upphp:{s}:{v}"
            state[key] = 1
            if key not in prev:
                events.append(("upphp", f"EC-CUBE {s} の上流が **PHP {v}** を{'・'.join(where)}に載せました"
                                        f"（キットが {s} で配っている PHP: {' / '.join(kit[s]['php'])}）。"))

    # ---- phpredis の正式版（8）
    kit_redis = sorted({r for k in kit.values() for r in k["phpredis"]}, key=vt)
    try:
        rels = re.findall(r"<r>\s*<v>([^<]+)</v>\s*<s>([^<]+)</s>", get(PECL_REDIS))
        if not rels:
            raise RuntimeError("版が 1 つも無い（形が変わった？）")
        for v, stability in rels:
            if stability.strip() == "stable" and re.fullmatch(r"\d+\.\d+\.\d+", v) and kit_redis and vt(v) > vt(kit_redis[-1]):
                key = f"phpredis:{v}"
                state[key] = 1
                if key not in prev:
                    uses = ", ".join(f"{s}: {' / '.join(k['phpredis'])}" for s, k in sorted(kit.items(), key=lambda x: vt(x[0])))
                    events.append(("phpredis", f"**phpredis {v}**（正式版）が出ました。キットが使っている版は {uses} です。"))
    except Exception as e:  # noqa: BLE001
        errors.append(f"- PECL（redis）: {e}")
        carry("phpredis:")

    # ---- 新しい PHP（6）
    try:
        cycles = [c["cycle"] for c in json.loads(get(EOL_PHP)) if re.fullmatch(r"\d+\.\d+", str(c.get("cycle", "")))]
        if not cycles:
            raise RuntimeError("版が 1 つも無い")
        for c in cycles:
            if vt(c) > vt(kit_php[-1]):
                key = f"php:{c}"
                state[key] = 1
                if key not in prev:
                    events.append(("php", f"**PHP {c}** が出ました。キットが配っている PHP は {kit_php[-1]} までです。"))
    except Exception as e:  # noqa: BLE001
        errors.append(f"- endoflife.date（PHP）: {e}")
        carry("php:")

    # ---- 書き出し
    json.dump(state, open(os.path.join(out, "state.json"), "w", encoding="utf-8"), ensure_ascii=False, sort_keys=True)
    json.dump(actions, open(os.path.join(out, "actions.json"), "w", encoding="utf-8"))

    todo = {
        "patch": "- 焼き直しのあと、kit-e2e が新しいイメージで 6 組を通して試します（落ちたら Issue が開きます）。\n"
                 "- 店に届けるのは店の人です（`bin/upgrade.sh ~<版> --prod`）。**キットは店の EC-CUBE を勝手に上げません。**\n"
                 "- 上流のリリースノートを読み、セキュリティの修正ならリリースノートか README で利用者に知らせる。",
        "pre": "- 何もしなくてよい。正式版が出たら、ここから PR が作られます。",
        "stable": "- 作られた PR の kit-e2e が通るのを確かめる。\n"
                  "- PR の本文の「人が直すもの」（文書・サイトの表・`.env.example`・`upgrade.sh` の使い方の例）を直す。\n"
                  "- マージしたら、次のリリースで「本番に使ってよい」と案内する。",
        "series": "新しい系列を配るのは人の仕事です（`docs/upgrade.md`「マイナー」、`CLAUDE.md`）。\n"
                  "1. 上流の README で、その系列が対応する PHP を見る\n"
                  "2. `.github/build-matrix.json` に足す（正式版が無いうちは `<系列>.x-dev`）。phpredis の版も決める\n"
                  "3. `bin/lib/image.sh` の `image_php_for_series` / `image_php_versions_for_series` / `image_phpredis_for_series` を揃える\n"
                  "4. `kit-e2e.yml` の matrix に足す（`image.sh` と一覧のずれは kit-e2e が落とす）\n"
                  "5. 配っているプラグインを全部移植する（目印による差し込み・本体の処理への割り込み・本体の副作用への対処の 3 つは黙って壊れる）\n"
                  "6. 文書・サイトの対応表を直す",
        "phpreq": "- 新しく許された PHP は、`.github/build-matrix.json` と `image_php_versions_for_series` に足すか決める。\n"
                  "- 外された PHP は、その系列で配るのを止めるか決める（止めるなら、使っている店への案内が先）。",
        "upphp": "- その系列で配るかを決める。配るなら、その PHP で phpredis が組めるか（下の「phpredis の正式版」）と、公式の\n"
                 "  `php:<版>-fpm-bookworm` で Dockerfile が通るかを手元で焼いて確かめる（PHP 8.6 の公式イメージは pecl が無く、fpm が ZTS）。\n"
                 "- 足すのは `.github/build-matrix.json`・`image_php_versions_for_series`・`image_php_eol`（保守期限）。"
                 "**既定（`default: true`）は動かさない。**",
        "phpredis": "- その系列で配っている PHP の全部で組めるかを確かめ、上げるなら `.github/build-matrix.json` の `phpredis` と"
                    " `image_phpredis_for_series` を揃える。\n"
                    "- 新しい PHP を phpredis 待ちで配れずにいたなら、それを足す PR と一緒にしてよい。",
        "php": "- 系列ごとに、上流の composer.json がその版を許しているか・上流の CI で試されているかを見る。\n"
               "  上流が README か CI に載せたら、ここからまた知らせます（「上流が対応する PHP」）。\n"
               "- 配るなら `.github/build-matrix.json`・`image_php_versions_for_series`・`image_php_eol`（保守期限）を足す。"
               "**既定（`default: true`）は動かさない**（短いタグの店の PHP が変わる。いまは deploy が止めるが、知らせが要る）。",
    }
    titles = {"patch": "パッチ版", "pre": "プレリリース", "stable": "正式版", "series": "新しい系列",
              "phpreq": "系列が許す PHP", "php": "新しい PHP", "upphp": "上流が対応する PHP",
              "phpredis": "phpredis の正式版"}
    with open(os.path.join(out, "report.md"), "w", encoding="utf-8") as f:
        if events:
            f.write("上流（EC-CUBE・PHP）に、キットが追いつくべきものが出ました。\n\n")
            for kind in titles:
                lines = [t for k, t in events if k == kind]
                if lines:
                    f.write(f"### {titles[kind]}\n\n" + "\n".join(f"- {t}" for t in lines) + "\n\n" + todo[kind] + "\n\n")
            f.write("手元の Claude Code にこの Issue を渡してよい。\n\n")
        if errors:
            f.write("## 読めなかったもの\n\n" + "\n".join(errors) + "\n\n前回の状態を引き継いでいます。続くようなら見る先を直す。\n")
        f.write(f"\n<details><summary>キットが配っているもの</summary>\n\n"
                + "\n".join(f"- {s}: `{k['eccube']}`・PHP {' / '.join(k['php'])}" for s, k in sorted(kit.items(), key=lambda x: vt(x[0])))
                + "\n</details>\n")

    print(f"changed={'true' if events else 'false'}")
    print(f"errors={'true' if errors else 'false'}")
    print(f"first={'true' if first else 'false'}")


if __name__ == "__main__":
    main()

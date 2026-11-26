#!/usr/bin/env bash
# 系列の正式版が出たとき、matrix の制約を `<系列>.x-dev` → `~<系列>.0` に変える PR を作る（upstream-watch.yml）。
#
#   .github/scripts/upstream_stable_pr.sh <系列> <最新の正式版>
#
# 機械で変えるのは .github/build-matrix.json だけ（build-image と kit-e2e.sh がここを読む。ワークフローのファイルは
# GITHUB_TOKEN では push できないので、一覧をワークフローの外に置いてある）。
# 文書・サイトの表・`.env.example`・`upgrade.sh` の使い方の例は、言い回しが要るので PR の本文に並べて人に任せる。
# **マージは人。** GITHUB_TOKEN で作った PR には pull_request のワークフローが走らないので、kit-e2e と
# config-check は workflow_dispatch でそのブランチに流す（ワークフロー側）。
#
# 終わりの値: 0 = PR を作った（または同じ PR がもうある）、1 = 作れなかった（ブランチを push できたかは標準出力）
set -euo pipefail
series="${1:?系列}"
latest="${2:?最新の正式版}"
branch="auto/eccube-${series}-stable"
file=.github/build-matrix.json

existing="$(gh pr list --head "$branch" --state open --json number -q '.[0].number')"
if [ -n "$existing" ]; then
    echo "pr=exists"; exit 0
fi

grep -q "\"series\":\"${series}\",\"eccube\":\"${series}.x-dev\"" "$file" || { echo "matrix の ${series} は x-dev ではありません"; exit 1; }
git switch -c "$branch"
sed -i "s/\"series\":\"${series}\",\"eccube\":\"${series}\.x-dev\"/\"series\":\"${series}\",\"eccube\":\"~${series}.0\"/" "$file"
git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -qam "build-matrix: EC-CUBE ${series} の正式版（${latest}）が出たので、matrix を ~${series}.0 にする"
git push -f origin "$branch"
echo "branch=${branch}"

cat > pr-body.md <<EOF
EC-CUBE **${series} の正式版（${latest}）** が Packagist に出たので、配るイメージを開発ブランチ（\`${series}.x-dev\`）から正式版（\`~${series}.0\`）に変えます。upstream-watch が作った PR です。

## 機械で変えたもの

- \`.github/build-matrix.json\` の ${series} の行（kit-e2e もここから上げる先を読む）

## 人が直すもの（この PR に足してからマージ）

- [ ] \`build-image.yml\` の「4.4 は 4.4.x-dev」のコメント
- [ ] \`.env.example\` の系列の説明
- [ ] \`bin/upgrade.sh\` / \`bin/switch-version.sh\` の使い方の例
- [ ] \`docs/distribute.md\` / \`docs/install.md\` / \`docs/upgrade.md\` の「正式版がまだ無い」の記述
- [ ] \`site/index.html\` の対応表（「試すだけ」→ 本番に使える）
- [ ] \`CLAUDE.md\` の該当箇所
- [ ] 上流のリリースノートで、対応する PHP が README と変わっていないか

## 確かめること

- [ ] kit-e2e（${series} の 2 組）が通る。この PR には自動では走らないので、upstream-watch がこのブランチへ手動の実行を投げています（Actions → kit-e2e）
- [ ] マージのあと、次のリリースで「${series} を本番に使ってよい」と案内する。店を上げるのは店の人（\`bin/upgrade.sh ~${series}.0 --prod\`。系列をまたぐ店は \`--rehearsed\` と点検が要る）

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
if gh pr create --head "$branch" --title "EC-CUBE ${series} の正式版（${latest}）を配る" --body-file pr-body.md; then
    echo "pr=created"
else
    # 「Allow GitHub Actions to create and approve pull requests」が切ってあると作れない。ブランチは残す
    echo "pr=failed"
    exit 1
fi

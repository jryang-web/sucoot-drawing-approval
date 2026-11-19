#!/usr/bin/env bash
# 建置前端並發布到 gh-pages 分支（GitHub Pages：Settings → Pages → Deploy from a branch → gh-pages / root）
# 只會包含 dist/ 的靜態檔案；前端只有 publishable key（可公開），不含任何密鑰。
set -euo pipefail
cd "$(dirname "$0")/.."
npm run build -- --mode pages
touch dist/.nojekyll
SRC_SHA=$(git rev-parse --short HEAD)
TMP=$(mktemp -d)
cp -r dist/. "$TMP"/
cd "$TMP"
git init -q -b gh-pages
git add -A
git -c user.name="$(git -C "$OLDPWD" config user.name)" -c user.email="$(git -C "$OLDPWD" config user.email)" \
  commit -q -m "deploy: build from ${SRC_SHA}"
git push -f "$(git -C "$OLDPWD" remote get-url origin)" gh-pages:gh-pages
rm -rf "$TMP"
echo "Deployed ${SRC_SHA} to gh-pages"

#!/usr/bin/env bash
# 发版：把 Version.swift、git tag、formula 的 url/sha256 三处对齐。
#
#   ./scripts/release.sh 0.1.0          # 干跑：只检查并打印将要发生的事
#   ./scripts/release.sh 0.1.0 --go     # 真做：打 tag → push → 抓 tarball 算 sha256 → 改公式
#
# 为什么要有这个脚本：GitHub 生成的 tarball 哈希只有 tag 推上去之后才拿得到，
# 而那个哈希要写进 formula —— 手抄这一步很容易错，错了 brew 只会告诉你 "SHA256 mismatch"。
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
GO=0
if [ "${2:-}" = "--go" ]; then GO=1; fi

if [ -z "$VERSION" ]; then
    echo "用法：./scripts/release.sh <版本号> [--go]" >&2
    echo "例如：./scripts/release.sh 0.1.0" >&2
    exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✗ 版本号要形如 1.2.3：$VERSION" >&2
    exit 1
fi

TAG="v$VERSION"
REPO_SLUG="BreakFree003/apple-translate-api"
FORMULA="Formula/apple-translate-api.rb"
TARBALL_URL="https://github.com/${REPO_SLUG}/archive/refs/tags/${TAG}.tar.gz"

echo "▶ 检查"
SRC_VERSION="$(grep -oE 'static let string = "[^"]+"' Sources/AppleTranslateServer/Version.swift | head -1 | sed 's/.*"\(.*\)"/\1/')"
echo "  Version.swift = ${SRC_VERSION:-（读不到）}，目标 = $VERSION"
if [ "$SRC_VERSION" != "$VERSION" ]; then
    echo "  ✗ 先把 Sources/AppleTranslateServer/Version.swift 改成 $VERSION" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "  ✗ 工作树不干净 —— tag 只会包含已提交的内容，先提交" >&2
    git status --short >&2
    exit 1
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "  ✗ tag $TAG 已存在" >&2
    exit 1
fi

REMOTE="$(git remote get-url origin 2>/dev/null || true)"
echo "  origin = ${REMOTE:-（还没配）}"

echo "▶ 构建 + 单测"
swift build -c release
swift test 2>&1 | grep -E 'Test run with' || true

echo
if [ "$GO" -ne 1 ]; then
    cat <<EOF
▶ 干跑结束，检查都过了。真做请加 --go：

    ./scripts/release.sh $VERSION --go

它会依次做：
    git tag -a $TAG -m "apple-translate-api $VERSION"
    git push origin HEAD && git push origin $TAG
    curl -L $TARBALL_URL | shasum -a 256
    python3 把 url/sha256 写进 $FORMULA

之后还有三步要你自己做（脚本不替你做，因为要动别的仓库）：
    git add $FORMULA && git commit -m "formula: $TAG" && git push
    cp $FORMULA <homebrew-apple-translate-api 仓库>/Formula/
    brew update && brew install apple-translate-api && brew services start apple-translate-api
EOF
    exit 0
fi

if [ -z "$REMOTE" ]; then
    echo "✗ origin 没配。先把仓库推上 GitHub：gh repo create $REPO_SLUG --public --source=. --push" >&2
    exit 1
fi

echo "▶ 打 tag"
git tag -a "$TAG" -m "apple-translate-api $VERSION"

echo "▶ push"
git push origin HEAD
git push origin "$TAG"

echo "▶ 等 GitHub 生成 tarball 并算 sha256"
SHA=""
for attempt in $(seq 1 20); do
    SHA="$(curl -fsSL "$TARBALL_URL" 2>/dev/null | shasum -a 256 | awk '{print $1}')" || SHA=""
    if [ -n "$SHA" ]; then break; fi
    echo "  第 $attempt 次还拿不到（GitHub 在生成），等 3 秒"
    sleep 3
done
if [ -z "$SHA" ]; then
    echo "✗ 拿不到 tarball。手动算：curl -L $TARBALL_URL | shasum -a 256" >&2
    exit 1
fi
echo "  sha256 = $SHA"

echo "▶ 写进公式（只改顶层 url / sha256 两行，注释里的示例不动）"
python3 - "$FORMULA" "$TARBALL_URL" "$SHA" <<'PY'
import re, sys

path, url, sha = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
text = re.sub(r'^  url ".*"$', f'  url "{url}"', text, count=1, flags=re.M)
text = re.sub(r'^  sha256 ".*"$', f'  sha256 "{sha}"', text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
PY
grep -nE '^  (url|sha256)' "$FORMULA"

echo
echo "✅ 剩下三步："
echo "   1. git add $FORMULA && git commit -m 'formula: $TAG' && git push"
echo "   2. 把 $FORMULA 复制到 homebrew-apple-translate-api 仓库的 Formula/ 下并推上去"
echo "   3. brew update && brew install apple-translate-api && brew services start apple-translate-api"

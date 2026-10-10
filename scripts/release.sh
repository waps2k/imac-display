#!/bin/bash
# 빌드 → zip → 태그 → GitHub 릴리즈(바이너리 첨부)까지 한 번에 한다.
#   ./scripts/release.sh 0.2.2                 # 릴리즈 노트는 커밋 목록으로 자동 생성
#   ./scripts/release.sh 0.2.2 "변경 내용…"     # 릴리즈 노트 직접 지정
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?버전을 지정하세요 (예: 0.2.2)}"
NOTES="${2:-}"
TAG="v$VERSION"

if [ -n "$(git status --porcelain)" ]; then
    echo "커밋되지 않은 변경이 있습니다. 먼저 커밋하세요." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "$TAG 태그가 이미 있습니다." >&2
    exit 1
fi

VERSION="$VERSION" ./scripts/build-apps.sh

OUT="dist/release"
rm -rf "$OUT"
mkdir -p "$OUT"
for app in Sender Receiver; do
    ditto -c -k --keepParent "dist/iMacDisplay $app.app" "$OUT/iMacDisplay-$app-$VERSION.zip"
done
(cd "$OUT" && shasum -a 256 *.zip > SHA256SUMS.txt)

git push origin HEAD
git tag "$TAG"
git push origin "$TAG"

if [ -n "$NOTES" ]; then
    gh release create "$TAG" "$OUT"/* --title "$TAG" --notes "$NOTES"
else
    gh release create "$TAG" "$OUT"/* --title "$TAG" --generate-notes
fi

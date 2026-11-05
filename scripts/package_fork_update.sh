#!/bin/bash
set -euo pipefail

: "${SPARKLE_PRIVATE_KEY:?Set SPARKLE_PRIVATE_KEY to the fork update signing key}"
: "${GITHUB_REPOSITORY:?Run this script in GitHub Actions}"
: "${GITHUB_REF_NAME:?Missing release tag}"
if [[ "$GITHUB_REPOSITORY" != "duskedge/ai-usage-menubar" || ! "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-duskedge\.[0-9]+$ ]]; then
    echo 'Refusing to publish outside the fork or without a versioned fork tag.' >&2
    exit 1
fi

app='DerivedData-CI/Build/Products/Release/AI Usage.app'
tools='DerivedData-CI/SourcePackages/artifacts/sparkle/Sparkle/bin'
expected_version="${GITHUB_REF_NAME#v}"
expected_version="${expected_version%-duskedge.*}"
actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ "$actual_version" != "$expected_version" ]]; then
    echo "Tag version $expected_version differs from app version $actual_version" >&2
    exit 1
fi
mkdir -p dist/update
cp dist/AI-Usage-macos-arm64.zip dist/update/
cat > dist/release-notes.md <<'NOTES'
本版本支持 Antigravity 本地 Gemini 五小时、周额度及 Argon 周额度，并启用此 fork 的签名自动更新。

下载 AI-Usage-macos-arm64.zip，退出旧应用后解压并替换 /Applications/AI Usage.app。
首次切换到 fork 更新源需要手动安装；之后应用每小时自动检查已发布的签名更新。

适用于 Apple Silicon、macOS 26 及以上。安装包为 ad-hoc 签名，未经 Apple 公证。
NOTES
cp dist/release-notes.md dist/update/AI-Usage-macos-arm64.md
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/$GITHUB_REF_NAME/" \
    --link "https://github.com/$GITHUB_REPOSITORY" \
    --embed-release-notes \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    dist/update
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/sign_update" \
    --ed-key-file - --verify dist/update/appcast.xml

#!/usr/bin/env bash
# Prepare a release: set the version of all apps, commit and tag.
#   scripts/release.sh 1.4.0
# Normally run by the Release workflow (Actions › Release › Run workflow).
#
# Sets the version in desktop/build.gradle.kts, android/app/build.gradle.kts (and raises the Android
# versionCode by one) and ios/project.yml, so all apps carry the same version.
set -euo pipefail
version="${1:?usage: scripts/release.sh X.Y.Z}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z"; exit 1; }
cd "$(dirname "$0")/.."
git diff --quiet || { echo "working tree not clean"; exit 1; }

sed -i -E "s/^val appVersion = \"[^\"]+\"/val appVersion = \"$version\"/" desktop/build.gradle.kts
sed -i -E "s/^val appVersionName = \"[^\"]+\"/val appVersionName = \"$version\"/" android/app/build.gradle.kts
code=$(sed -n -E 's/^val appVersionCode = ([0-9]+).*/\1/p' android/app/build.gradle.kts)
sed -i -E "s/^val appVersionCode = [0-9]+/val appVersionCode = $((code + 1))/" android/app/build.gradle.kts
sed -i -E "s/^( *MARKETING_VERSION: *)\"[^\"]+\"/\1\"$version\"/" ios/project.yml

grep -q "^val appVersion = \"$version\"" desktop/build.gradle.kts || { echo "could not set the desktop version"; exit 1; }
grep -q "^val appVersionName = \"$version\"" android/app/build.gradle.kts || { echo "could not set the Android version"; exit 1; }
grep -q "MARKETING_VERSION: \"$version\"" ios/project.yml || { echo "could not set the iOS version"; exit 1; }

git commit -am "Release $version"
git tag -a "v$version" -m "Parla $version"
echo "Tagged v$version. Push with: git push origin main v$version"

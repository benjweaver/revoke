#!/usr/bin/env bash
# Releases the version in project.yml in one step: builds a notarised, universal
# Revoke.app (see build.sh), publishes it as a GitHub release with its CHANGELOG.md
# section as the notes, and points the Homebrew tap at it.
#   Scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

repo=benjweaver/revoke
tap=benjweaver/homebrew-revoke
identity="Developer ID Application: Ben Weaver (AR25V66TVY)"

# The release is tagged at the commit it's built from, so that commit has to be
# committed and pushed.
if [ -n "$(git status --porcelain)" ]; then
  echo "error: commit or stash your changes before releasing" >&2
  exit 1
fi
git fetch -q origin main
commit=$(git rev-parse HEAD)
if [ "$commit" != "$(git rev-parse origin/main)" ]; then
  echo "error: HEAD isn't origin/main; push main (or check it out) before releasing" >&2
  exit 1
fi

version=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
tag="v$version"
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  echo "error: $tag is already released; bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml" >&2
  exit 1
fi
notes=$(awk -v version="$version" '
  index($0, "## [" version "]") == 1 { on = 1; next }
  /^## \[/ || /^\[/ { on = 0 }
  on
' CHANGELOG.md)
if ! grep -q '[^[:space:]]' <<<"$notes"; then
  echo "error: CHANGELOG.md has no section for $version" >&2
  exit 1
fi
# Signing and notarising come after a long build, so check both can work before it.
if ! security find-identity -v -p codesigning | grep -qF "\"$identity\""; then
  echo "error: \"$identity\" isn't in the keychain" >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile notary >/dev/null; then
  echo "error: the notarytool profile \"notary\" doesn't work; see Release in the README" >&2
  exit 1
fi

sh Scripts/build.sh
app=build/export/Revoke.app
filter="$app/Contents/Library/SystemExtensions/dev.benjweaver.Revoke.Filter.systemextension/Contents/MacOS/dev.benjweaver.Revoke.Filter"
for binary in "$app/Contents/MacOS/Revoke" "$filter"; do
  for arch in arm64 x86_64; do
    lipo "$binary" -verify_arch "$arch" ||
      { echo "error: $(basename "$binary") is missing $arch" >&2; exit 1; }
  done
done
out=build/release
rm -rf "$out"; mkdir -p "$out"
zip="$out/Revoke-$version.zip"
ditto -c -k --keepParent "$app" "$zip"

gh release create "$tag" "$zip" --repo "$repo" --target "$commit" --title "Revoke $version" \
  --notes "$notes

Universal (Apple silicon and Intel), macOS 15 or later. Signed with a Developer ID and notarized by Apple."

# Point the tap at the new release. The push starts the tap's install test.
tapdir=$(mktemp -d)
trap 'rm -rf "$tapdir"' EXIT
gh repo clone "$tap" "$tapdir" -- -q
bash "$tapdir/scripts/update-cask.sh" "$tag"
if git -C "$tapdir" diff --quiet; then
  echo "The tap already points at $tag."
else
  git -C "$tapdir" commit -qam "revoke $version"
  git -C "$tapdir" push -q
  echo "Pointed $tap at $tag; its install test is running."
fi

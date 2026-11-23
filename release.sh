#!/bin/zsh
# Builds a signed, notarized Quarry DMG for download from GitHub Releases.
#
# Usage: ./release.sh             build dist/Quarry-<version>.dmg, notarized and stapled
#        ./release.sh --publish   also create GitHub release v<version> with the DMG attached
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application).
#   2. Notary credentials in your keychain (app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials quarry-notary \
#          --apple-id <your Apple ID> --team-id <TEAMID> --password <app-specific password>
#   3. For --publish: gh auth login, and a GitHub remote for this repo.
#
# The version comes from CFBundleShortVersionString in Info.plist.in.
set -euo pipefail
here=${0:A:h}
name="Quarry"
profile="${NOTARY_PROFILE:-quarry-notary}"

version=$(plutil -extract CFBundleShortVersionString raw "$here/Info.plist.in" 2>/dev/null || true)
[[ -n "$version" ]] || { echo "no CFBundleShortVersionString in Info.plist.in"; exit 1; }

identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)
fi
[[ -n "$identity" ]] || { echo "no Developer ID Application certificate found (see setup at the top of release.sh)"; exit 1; }

if [[ " $* " == *" --publish "* ]]; then
  command -v gh >/dev/null || { echo "--publish needs the gh CLI"; exit 1; }
  git -C "$here" remote get-url origin >/dev/null 2>&1 || { echo "--publish needs a GitHub remote named origin"; exit 1; }
  if gh release view "v$version" >/dev/null 2>&1; then
    echo "release v$version already exists; bump CFBundleShortVersionString in Info.plist.in"; exit 1
  fi
fi

echo "== building $name $version"
"$here/build.sh"
built="$HOME/Applications/$name.app"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/dmg"
ditto "$built" "$stage/dmg/$name.app"
ln -s /Applications "$stage/dmg/Applications"

echo "== signing with $identity"
codesign --force --options runtime --timestamp --sign "$identity" "$stage/dmg/$name.app"
codesign --verify --strict --deep "$stage/dmg/$name.app"

mkdir -p "$here/dist"
dmg="$here/dist/$name-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "$name $version" -srcfolder "$stage/dmg" -fs HFS+ -format UDZO -ov "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"

echo "== notarizing (usually a few minutes)"
out=$(xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait 2>&1) || true
echo "$out" | grep -E "id:|status:" | head -4
if ! echo "$out" | grep -q "status: Accepted"; then
  id=$(echo "$out" | grep -m1 -o 'id: [0-9a-f-]*' | cut -d' ' -f2)
  echo "notarization failed"
  [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$profile"
  exit 1
fi
xcrun stapler staple -q "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg" 2>&1
echo "== built $dmg"

if [[ " $* " == *" --publish "* ]]; then
  gh release create "v$version" "$dmg" --title "$name $version" --generate-notes
fi

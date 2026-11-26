#!/usr/bin/env bash
# Prepare an AltStore source package for the WNSS iPhone app.
# This script is iOS-only. It never touches the Android build, APK, update
# popup, build-release.sh, or RELEASE_PARITY.md.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./publish-altstore-release.sh [options]

Default behaviour:
  1. Bump CURRENT_PROJECT_VERSION in the KMP Xcode project
  2. Rebuild the signed iPhone IPA
  3. Copy the IPA and app icon into this altstore package
  4. Update altstore.json and index.html
  5. Calculate size and SHA-256
  6. Create releases/<version>-<build>/ with an immutable copy and metadata

Options:
  --change-id ID          Label printed in the run summary
  --base-url URL          Public HTTPS folder where this package will be hosted
  --notes TEXT            Release notes written to altstore.json and index.html
  --marketing-version V   Optional app version change, e.g. 1.0.71
  --build-number N        Set an exact build number instead of incrementing
  --no-bump               Keep the current Xcode build number
  --no-rebuild            Copy the existing IPA without rebuilding
  --dry-run               Show the plan without changing any files
  -h, --help              Show this help

Environment overrides:
  WNSS_KMP_ROOT           Default: ~/Downloads/wnss-kmp
  WNSS_ALTSTORE_BASE_URL  Default: GitHub Pages URL for wnss-download/altstore
  WNSS_DEVELOPMENT_TEAM   Default: A2M62835WH
  WNSS_BUNDLE_ID          Default: ug.go.health.wnss.kmp.ios
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 2
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_DIR="$SCRIPT_DIR"

KMP_ROOT="${WNSS_KMP_ROOT:-$HOME/Downloads/wnss-kmp}"
PROJECT="$KMP_ROOT/iosApp/iosApp.xcodeproj/project.pbxproj"
THEME="$KMP_ROOT/shared/src/commonMain/kotlin/ug/go/health/wnss/WnssTheme.kt"
IOS_BUILD_SCRIPT="$KMP_ROOT/scripts/build-ios-ipa.sh"
IPA_SOURCE="$KMP_ROOT/build/ios/export/WNSS iOS.ipa"
ICON_SOURCE="$KMP_ROOT/iosApp/iosApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

ALTSTORE_JSON="$PACKAGE_DIR/altstore.json"
INDEX_HTML="$PACKAGE_DIR/index.html"
PUBLISHED_IPA="$PACKAGE_DIR/WNSS.ipa"
PUBLISHED_ICON="$PACKAGE_DIR/icon.png"
RELEASES_DIR="$PACKAGE_DIR/releases"

BASE_URL="${WNSS_ALTSTORE_BASE_URL:-https://tibenkanageorge.github.io/wnss-download/altstore}"
BASE_URL="${BASE_URL%/}"
TEAM="${WNSS_DEVELOPMENT_TEAM:-A2M62835WH}"
BUNDLE="${WNSS_BUNDLE_ID:-ug.go.health.wnss.kmp.ios}"

CHANGE_ID=""
NOTES_TEXT=""
MARKETING_VERSION_ARG=""
BUILD_NUMBER_ARG=""
BUMP=1
REBUILD=1
DRY_RUN=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --change-id)
            [ "$#" -ge 2 ] || die "--change-id needs a value"
            CHANGE_ID="$2"
            shift 2
            ;;
        --base-url)
            [ "$#" -ge 2 ] || die "--base-url needs a value"
            BASE_URL="$2"
            shift 2
            ;;
        --notes)
            [ "$#" -ge 2 ] || die "--notes needs a value"
            NOTES_TEXT="$2"
            shift 2
            ;;
        --marketing-version)
            [ "$#" -ge 2 ] || die "--marketing-version needs a value"
            MARKETING_VERSION_ARG="$2"
            shift 2
            ;;
        --build-number)
            [ "$#" -ge 2 ] || die "--build-number needs a value"
            BUILD_NUMBER_ARG="$2"
            shift 2
            ;;
        --no-bump)
            BUMP=0
            shift
            ;;
        --no-rebuild)
            REBUILD=0
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

BASE_URL="${BASE_URL%/}"
STAMP=$(date +%Y%m%d-%H%M%S)
STARTED=$(date '+%Y-%m-%d %H:%M:%S %z')
[ -n "$CHANGE_ID" ] || CHANGE_ID="altstore-$STAMP"
LOG_DIR="$PACKAGE_DIR/logs/$STAMP"

read_pbx_value() {
    [ -f "$PROJECT" ] || die "Xcode project not found: $PROJECT"
    grep -m1 -E "$1[[:space:]]*=" "$PROJECT" \
        | sed -E "s/.*$1[[:space:]]*=[[:space:]]*([^;]+);.*/\1/" \
        | tr -d '[:space:]'
}

update_pbx_value() {
    python3 - "$PROJECT" "$1" "$2" "$3" <<'PY'
import re
import sys

path, key, old, new = sys.argv[1:5]
with open(path, "r", encoding="utf-8") as handle:
    text = handle.read()
pattern = re.compile(r'(' + re.escape(key) + r'\s*=\s*)' + re.escape(old) + r'(\s*;)')
text, count = pattern.subn(r'\g<1>' + new + r'\g<2>', text)
if count == 0:
    raise SystemExit(f"No {key} value {old!r} found in {path}")
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
print(f"Updated {count} {key} entries: {old} -> {new}")
PY
}

update_in_app_version() {
    [ -f "$THEME" ] || die "KMP theme file not found: $THEME"
    python3 - "$THEME" "$1" <<'PY'
import re
import sys

path, version = sys.argv[1:3]
with open(path, "r", encoding="utf-8") as handle:
    text = handle.read()
pattern = re.compile(r'(const\s+val\s+Version\s*=\s*"WNSS v)[^"]+(")')
text, count = pattern.subn(r'\g<1>' + version + r'\g<2>', text)
if count != 1:
    raise SystemExit(f"Expected one WNSS version label in {path}, found {count}")
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
print(f"Updated in-app label: WNSS v{version}")
PY
}

ipa_plist_value() {
    local ipa="$1"
    local key="$2"
    local info_path
    info_path=$(unzip -Z1 "$ipa" | grep -m1 -E '^Payload/[^/]+\.app/Info\.plist$') || {
        echo "Info.plist not found in $ipa" >&2
        return 1
    }
    unzip -p "$ipa" "$info_path" \
        | python3 -c 'import plistlib, sys; print(plistlib.loads(sys.stdin.buffer.read()).get(sys.argv[1], ""))' "$key"
}

CURRENT_VERSION=$(read_pbx_value MARKETING_VERSION)
CURRENT_BUILD=$(read_pbx_value CURRENT_PROJECT_VERSION)

case "$CURRENT_VERSION" in
    *[!0-9.]*|"") die "Unexpected MARKETING_VERSION: $CURRENT_VERSION" ;;
esac
case "$CURRENT_BUILD" in
    *[!0-9]*|"") die "Unexpected CURRENT_PROJECT_VERSION: $CURRENT_BUILD" ;;
esac

TARGET_VERSION="$CURRENT_VERSION"
if [ -n "$MARKETING_VERSION_ARG" ]; then
    case "$MARKETING_VERSION_ARG" in
        *[!0-9.]*|"") die "Invalid marketing version: $MARKETING_VERSION_ARG" ;;
    esac
    TARGET_VERSION="$MARKETING_VERSION_ARG"
fi

TARGET_BUILD="$CURRENT_BUILD"
if [ -n "$BUILD_NUMBER_ARG" ]; then
    case "$BUILD_NUMBER_ARG" in
        *[!0-9]*|"") die "Invalid build number: $BUILD_NUMBER_ARG" ;;
    esac
    TARGET_BUILD="$BUILD_NUMBER_ARG"
elif [ "$BUMP" -eq 1 ]; then
    TARGET_BUILD=$((CURRENT_BUILD + 1))
fi

[ -n "$NOTES_TEXT" ] || NOTES_TEXT="WNSS iOS ${TARGET_VERSION} build ${TARGET_BUILD}."
RELEASE_FOLDER_REL="releases/${TARGET_VERSION}-${TARGET_BUILD}"
RELEASE_DIR="$PACKAGE_DIR/$RELEASE_FOLDER_REL"
SOURCE_URL="$BASE_URL/altstore.json"
DOWNLOAD_URL="$BASE_URL/WNSS.ipa"
RELEASE_DOWNLOAD_URL="$BASE_URL/$RELEASE_FOLDER_REL/WNSS.ipa"
ICON_URL="$BASE_URL/icon.png"

echo "WNSS AltStore release preparation"
echo "Change ID:       $CHANGE_ID"
echo "Current:         $CURRENT_VERSION ($CURRENT_BUILD)"
echo "Target:          $TARGET_VERSION ($TARGET_BUILD)"
echo "Base URL:        $BASE_URL"
echo "Package:         $PACKAGE_DIR"
echo "Started:         $STARTED"
echo

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN - no files will be changed"
    if [ "$TARGET_BUILD" = "$CURRENT_BUILD" ]; then
        echo "Would keep build at $TARGET_BUILD"
    else
        echo "Would set build to $TARGET_BUILD"
    fi
    if [ "$REBUILD" -eq 1 ]; then
        echo "Would rebuild IPA via $IOS_BUILD_SCRIPT"
    else
        echo "Would copy existing IPA from $IPA_SOURCE"
    fi
    echo "Would write $RELEASE_DIR/WNSS.ipa"
    echo "Would update $ALTSTORE_JSON"
    echo "Would update $INDEX_HTML"
    echo "Download URL:    $DOWNLOAD_URL"
    echo "Source URL:      $SOURCE_URL"
    exit 0
fi

mkdir -p "$LOG_DIR" "$RELEASES_DIR"

if [ "$TARGET_BUILD" != "$CURRENT_BUILD" ]; then
    update_pbx_value CURRENT_PROJECT_VERSION "$CURRENT_BUILD" "$TARGET_BUILD" | tee "$LOG_DIR/build-number.log"
fi

if [ "$TARGET_VERSION" != "$CURRENT_VERSION" ]; then
    update_pbx_value MARKETING_VERSION "$CURRENT_VERSION" "$TARGET_VERSION" | tee -a "$LOG_DIR/build-number.log"
    update_in_app_version "$TARGET_VERSION" | tee -a "$LOG_DIR/build-number.log"
fi

if [ "$REBUILD" -eq 1 ]; then
    [ -x "$IOS_BUILD_SCRIPT" ] || die "iOS build script not found or not executable: $IOS_BUILD_SCRIPT"
    echo "Rebuilding signed IPA..." | tee "$LOG_DIR/ios-ipa.log"
    WNSS_DEVELOPMENT_TEAM="$TEAM" WNSS_BUNDLE_ID="$BUNDLE" "$IOS_BUILD_SCRIPT" 2>&1 | tee -a "$LOG_DIR/ios-ipa.log"
else
    [ -f "$IPA_SOURCE" ] || die "Existing IPA not found: $IPA_SOURCE"
    echo "Using existing IPA: $IPA_SOURCE"
fi

[ -f "$IPA_SOURCE" ] || die "IPA was not produced: $IPA_SOURCE"
[ -f "$ICON_SOURCE" ] || die "App icon not found: $ICON_SOURCE"

mkdir -p "$RELEASE_DIR"
cp "$IPA_SOURCE" "$PUBLISHED_IPA"
cp "$IPA_SOURCE" "$RELEASE_DIR/WNSS.ipa"
cp "$ICON_SOURCE" "$PUBLISHED_ICON"
cp "$ICON_SOURCE" "$RELEASE_DIR/icon.png"

SIZE=$(stat -f%z "$PUBLISHED_IPA")
SHA=$(shasum -a 256 "$PUBLISHED_IPA" | awk '{print $1}')
MIN_OS=$(ipa_plist_value "$PUBLISHED_IPA" MinimumOSVersion)
BUNDLE_IN_IPA=$(ipa_plist_value "$PUBLISHED_IPA" CFBundleIdentifier)
VERSION_IN_IPA=$(ipa_plist_value "$PUBLISHED_IPA" CFBundleShortVersionString)
BUILD_IN_IPA=$(ipa_plist_value "$PUBLISHED_IPA" CFBundleVersion)

[ "$BUNDLE_IN_IPA" = "$BUNDLE" ] || die "IPA bundle ID mismatch: $BUNDLE_IN_IPA (expected $BUNDLE)"
[ "$VERSION_IN_IPA" = "$TARGET_VERSION" ] || die "IPA version mismatch: $VERSION_IN_IPA (expected $TARGET_VERSION)"
[ "$BUILD_IN_IPA" = "$TARGET_BUILD" ] || die "IPA build mismatch: $BUILD_IN_IPA (expected $TARGET_BUILD)"

DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

python3 - "$ALTSTORE_JSON" "$BUNDLE" "$TARGET_VERSION" "$TARGET_BUILD" "$DATE" "$NOTES_TEXT" \
    "$DOWNLOAD_URL" "$ICON_URL" "$SIZE" "$SHA" "$MIN_OS" "$RELEASE_FOLDER_REL" "$BASE_URL" "$SOURCE_URL" <<'PY'
import json
import os
import sys

(
    path, bundle, version, build, date, notes, download_url, icon_url,
    size, sha, min_os, release_folder, base_url, source_url,
) = sys.argv[1:15]

try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

data["name"] = "WNSS"
data["identifier"] = "ug.go.health.wnss.altstore"
data["subtitle"] = "Weekly Nutrition Surveillance System"
data["description"] = "Uganda Ministry of Health WNSS iPhone builds."
data["website"] = base_url
data.setdefault("apps", [])

apps = data["apps"]
app = next((item for item in apps if item.get("bundleIdentifier") == bundle), None)
if app is None:
    app = {}
    apps.append(app)

app.update({
    "name": "WNSS",
    "bundleIdentifier": bundle,
    "developerName": "Uganda Ministry of Health",
    "subtitle": "Weekly Nutrition Surveillance System",
    "description": "Weekly nutrition surveillance reporting for Ugandan health facilities.",
    "iconURL": icon_url,
    "tintColor": "0B1B3A",
    "category": "Medical",
    "version": version,
    "buildVersion": build,
    "versionDate": date,
    "versionDescription": notes,
    "localizedDescription": notes,
    "downloadURL": download_url,
    "size": int(size),
})

versions = app.setdefault("versions", [])
version_entry = next(
    (item for item in versions
     if item.get("version") == version and str(item.get("buildVersion", "")) == build),
    None,
)
if version_entry is None:
    version_entry = {}
    versions.append(version_entry)

version_entry.update({
    "version": version,
    "buildVersion": build,
    "date": date,
    "localizedDescription": notes,
    "downloadURL": download_url,
    "size": int(size),
    "sha256": sha.lower(),
    "minOSVersion": min_os,
})

versions.sort(
    key=lambda item: (item.get("date", ""), str(item.get("buildVersion", ""))),
    reverse=True,
)

user_info = data.setdefault("userInfo", {})
user_info["wnssCurrentReleaseFolder"] = release_folder
user_info["wnssSourceURL"] = source_url

with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, ensure_ascii=False)
    handle.write("\n")

print(f"Updated {path}")
PY

python3 - "$RELEASE_DIR/metadata.json" "$TARGET_VERSION" "$TARGET_BUILD" "$DATE" "$SIZE" "$SHA" "$MIN_OS" \
    "$DOWNLOAD_URL" "$RELEASE_DOWNLOAD_URL" "$SOURCE_URL" "$ICON_URL" <<'PY'
import json
import sys

(
    path, version, build, date, size, sha, min_os, download_url,
    release_download_url, source_url, icon_url,
) = sys.argv[1:12]

data = {
    "version": version,
    "build": build,
    "date": date,
    "size": int(size),
    "sha256": sha.lower(),
    "minOSVersion": min_os,
    "downloadURL": download_url,
    "releaseDownloadURL": release_download_url,
    "sourceURL": source_url,
    "iconURL": icon_url,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
print(f"Wrote {path}")
PY

python3 - "$PACKAGE_DIR/qrcode.png" "$BASE_URL/" <<'PY'
import sys

import qrcode

path, url = sys.argv[1:3]
qr = qrcode.QRCode(
    version=None,
    error_correction=qrcode.constants.ERROR_CORRECT_H,
    box_size=12,
    border=4,
)
qr.add_data(url)
qr.make(fit=True)
image = qr.make_image(fill_color="#0B1B3A", back_color="white")
image.save(path, optimize=True)
print(f"Updated {path} -> {url}")
PY

python3 - "$INDEX_HTML" "$SOURCE_URL" "$DOWNLOAD_URL" "$TARGET_VERSION" "$TARGET_BUILD" "$SIZE" "$SHA" "$ICON_URL" "$RELEASE_FOLDER_REL" <<'PY'
import html
import sys
from urllib.parse import quote

(
    path, source_url, download_url, version, build, size, sha, icon_url, release_folder,
) = sys.argv[1:10]

source_link = source_url + "?v=" + build
add_url = "altstore://source?url=" + quote(source_link, safe="")
e = html.escape

page = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>WNSS for AltStore</title>
  <style>
    :root {{ color-scheme: light; }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: 32px 18px;
      background: #f4f3ee;
      color: #0b1b3a;
      font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }}
    main {{
      width: min(100%, 620px);
      background: #fff;
      border-radius: 24px;
      padding: 30px;
      box-shadow: 0 12px 32px rgba(11,27,58,.14);
    }}
    .hero {{ display: flex; gap: 20px; align-items: center; }}
    .hero img {{ width: 88px; height: 88px; border-radius: 20px; }}
    h1 {{ margin: 0 0 6px; font-size: 28px; line-height: 1.15; }}
    p {{ margin: 6px 0; color: #5b6678; }}
    .version {{
      display: inline-block;
      margin: 18px 0 22px;
      padding: 7px 12px;
      border-radius: 999px;
      background: #e9eefd;
      color: #2456e8;
      font-weight: 700;
    }}
    .actions {{ display: flex; flex-wrap: wrap; gap: 12px; }}
    a.button {{
      display: inline-block;
      padding: 13px 18px;
      border-radius: 14px;
      background: #2456e8;
      color: #fff;
      text-decoration: none;
      font-weight: 700;
    }}
    a.button.secondary {{ background: #e8e6df; color: #0b1b3a; }}
    dl {{ display: grid; grid-template-columns: auto 1fr; gap: 6px 16px; margin: 22px 0 0; }}
    dt {{ color: #5b6678; }}
    dd {{ margin: 0; overflow-wrap: anywhere; }}
  </style>
</head>
<body>
  <main>
    <div class="hero">
      <img src="{e(icon_url)}" alt="WNSS app icon">
      <div>
        <h1>WNSS for iPhone</h1>
        <p>Add this source to AltStore, then install or refresh WNSS.</p>
      </div>
    </div>

    <div class="version">WNSS v{e(version)} · build {e(build)}</div>

    <div class="actions">
      <a class="button" href="{e(add_url)}">Add to AltStore</a>
      <a class="button secondary" href="{e(source_link)}">Open altstore.json</a>
      <a class="button secondary" href="{e(download_url)}">Download IPA</a>
    </div>

    <dl>
      <dt>Source URL</dt><dd>{e(source_url)}</dd>
      <dt>Release folder</dt><dd>{e(release_folder)}</dd>
      <dt>IPA size</dt><dd>{int(size):,} bytes</dd>
    </dl>
  </main>
</body>
</html>
"""
with open(path, "w", encoding="utf-8") as handle:
    handle.write(page)
print(f"Updated {path}")
PY

echo
echo "AltStore package ready: $PACKAGE_DIR"
echo "Version:   $TARGET_VERSION ($TARGET_BUILD)"
echo "Size:      $SIZE bytes"
echo "SHA-256:   $SHA"
echo "Source:    $SOURCE_URL"
echo "IPA:       $DOWNLOAD_URL"
echo "Release:   $RELEASE_DIR"
echo "Logs:      $LOG_DIR"
echo
echo "Publish note: host this folder over HTTPS, then commit/push it to the chosen host."
echo "Android release flow and update popup were not touched."

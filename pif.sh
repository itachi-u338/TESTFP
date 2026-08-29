#!/bin/bash
set -Eeuo pipefail

# Print the exact command that fails
trap 'echo "ERROR: command failed at line $LINENO: $BASH_COMMAND"; exit 1' ERR

echo "============================================================"
echo " Android 17 QPR2 Beta OTA Metadata"
echo "============================================================"

ENDPOINT="https://developer.android.com/about/versions/17/qpr2/download-ota"
HTML_FILE="PIXEL_OTA_HTML"

echo
echo "[1/7] Downloading Google OTA page..."
echo "URL: $ENDPOINT"

curl -L --fail --silent --show-error \
  -o "$HTML_FILE" \
  "$ENDPOINT"

if [ ! -s "$HTML_FILE" ]; then
    echo "ERROR: OTA page is empty or was not downloaded."
    exit 1
fi

echo "OK: OTA page downloaded ($(wc -c < "$HTML_FILE") bytes)"

# ------------------------------------------------------------
# Show whether tokay_beta is actually present
# ------------------------------------------------------------

echo
echo "[2/7] Looking for Pixel 9 / tokay_beta..."

if grep -qi "tokay" "$HTML_FILE"; then
    echo "OK: tokay found in page"
else
    echo "WARNING: tokay was not found in raw HTML."
    echo "The Google page may be rendering OTA data dynamically."
fi

# ------------------------------------------------------------
# Extract OTA ZIP filenames
# ------------------------------------------------------------

echo
echo "[3/7] Searching for OTA ZIP filenames..."

OTA_FILE="$(
    grep -oE '[A-Za-z0-9._-]+_beta-ota-[A-Za-z0-9._-]+\.zip' "$HTML_FILE" |
    sort -u |
    head -n1 || true
)"

if [ -n "$OTA_FILE" ]; then
    echo "Found OTA file: $OTA_FILE"
else
    echo "No OTA filename found in raw HTML."
fi

# ------------------------------------------------------------
# If raw HTML doesn't contain OTA data, show useful diagnostics
# ------------------------------------------------------------

if [ -z "$OTA_FILE" ]; then

    echo
    echo "------------------------------------------------------------"
    echo "OTA links found in HTML:"
    echo "------------------------------------------------------------"

    grep -oE 'https?://[^" ]+\.zip' "$HTML_FILE" |
        sort -u |
        head -50 || true

    echo
    echo "------------------------------------------------------------"
    echo "References containing 'tokay':"
    echo "------------------------------------------------------------"

    grep -i -C2 "tokay" "$HTML_FILE" |
        head -100 || true

    echo
    echo "ERROR: Google OTA data is not present in the raw HTML."
    echo
    echo "The script must not continue using an empty OTA URL."
    exit 1
fi

# ------------------------------------------------------------
# Construct OTA URL
# ------------------------------------------------------------

OTA_URL="https://dl.google.com/dl/android/aosp/$OTA_FILE"

echo
echo "[4/7] OTA selected:"
echo "$OTA_URL"

# ------------------------------------------------------------
# Download OTA
# ------------------------------------------------------------

echo
echo "[5/7] Downloading OTA ZIP..."

rm -f PIXEL_OTA.zip PIXEL_OTA_METADATA

curl -L --fail --show-error \
    -o PIXEL_OTA.zip \
    "$OTA_URL"

if [ ! -s PIXEL_OTA.zip ]; then
    echo "ERROR: OTA ZIP download failed."
    exit 1
fi

echo "OTA size: $(du -h PIXEL_OTA.zip | cut -f1)"

# ------------------------------------------------------------
# Validate ZIP
# ------------------------------------------------------------

echo
echo "[6/7] Validating OTA ZIP..."

if ! unzip -tq PIXEL_OTA.zip >/dev/null; then
    echo "ERROR: Downloaded file is not a valid ZIP."
    file PIXEL_OTA.zip
    exit 1
fi

echo "OK: OTA ZIP is valid."

# ------------------------------------------------------------
# Extract official OTA metadata
# ------------------------------------------------------------

echo
echo "Extracting META-INF/com/android/metadata..."

if ! unzip -l PIXEL_OTA.zip |
    grep -q 'META-INF/com/android/metadata'; then

    echo "ERROR: META-INF/com/android/metadata does not exist."
    echo
    echo "Metadata files present:"
    unzip -l PIXEL_OTA.zip |
        grep -E 'META-INF|metadata' |
        head -50

    exit 1
fi

unzip -p \
    PIXEL_OTA.zip \
    META-INF/com/android/metadata \
    > PIXEL_OTA_METADATA

if [ ! -s PIXEL_OTA_METADATA ]; then
    echo "ERROR: Metadata extraction produced an empty file."
    exit 1
fi

echo
echo "============================================================"
echo " OTA METADATA"
echo "============================================================"

cat PIXEL_OTA_METADATA

echo
echo "============================================================"

# ------------------------------------------------------------
# Read standard OTA metadata
# ------------------------------------------------------------

POST_BUILD="$(
    grep -m1 '^post-build=' PIXEL_OTA_METADATA |
    cut -d= -f2- |
    tr -d '\r'
)"

POST_SDK="$(
    grep -m1 '^post-sdk-level=' PIXEL_OTA_METADATA |
    cut -d= -f2- |
    tr -d '\r'
)"

SECURITY_PATCH="$(
    grep -m1 '^security-patch-level=' PIXEL_OTA_METADATA |
    cut -d= -f2- |
    tr -d '\r'
)"

echo
echo "post-build:          ${POST_BUILD:-NOT FOUND}"
echo "post-sdk-level:      ${POST_SDK:-NOT FOUND}"
echo "security-patch:      ${SECURITY_PATCH:-NOT FOUND}"

# ------------------------------------------------------------
# Validate
# ------------------------------------------------------------

if [ -z "$POST_BUILD" ]; then
    echo
    echo "ERROR: post-build was not found."
    exit 1
fi

if [ -z "$SECURITY_PATCH" ]; then
    echo
    echo "ERROR: security-patch-level was not found."
    exit 1
fi

echo
echo "============================================================"
echo " SUCCESS"
echo "============================================================"
echo "OTA:             $OTA_FILE"
echo "Build metadata:  $POST_BUILD"
echo "SDK level:       ${POST_SDK:-unknown}"
echo "Security patch:  $SECURITY_PATCH"
echo "============================================================"

# Cleanup
rm -f PIXEL_OTA.zip PIXEL_OTA_METADATA PIXEL_OTA_HTML

echo
echo "Completed successfully."

# Remove temporary HTML files if they exist
find . -maxdepth 1 -name "*_HTML" -exec rm {} \;
find . -maxdepth 1 -name "*_METADATA" -exec rm {} \;

# Add fields to chiteroman.json
cp pif.json chiteroman.json

# Migrate data using the migrate_osmosis.sh script and output to osmosis.json
./migrate_osmosis.sh -a pif.json device_osmosis.json
sed -i 's|//.*||g; /^[[:space:]]*$/d' device_osmosis.json
jq '(.spoofBuild, .spoofVendingFinger, .spoofProps) = "1" | (.spoofProvider, .spoofSignature, .spoofVendingSdk) = "0"' device_osmosis.json > tmp.json && mv tmp.json device_osmosis.json


./migrate_osmosis.sh -a pif.json osmosis.json
sed -i 's|//.*||g; /^[[:space:]]*$/d' osmosis.json
jq '(.spoofBuild, .spoofProvider, .spoofVendingFinger, .spoofProps) = "1" | (.spoofSignature, .spoofVendingSdk) = "0"' osmosis.json > tmp.json && mv tmp.json osmosis.json

# Delete the previously created pif.json as it's no longer needed
rm pif.json

# Remove any backup files with the .bak extension if they exist
find . -maxdepth 1 -name "*.bak" -exec rm {} \;

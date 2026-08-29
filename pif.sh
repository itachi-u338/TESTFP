#!/bin/bash
set -euo pipefail

echo "Fetching Android 17 QPR2 Beta OTA metadata directly..."

ENDPOINT="https://developer.android.com/about/versions/17/qpr2/download-ota"
HTML_FILE="PIXEL_OTA_HTML"

echo "Targeting Endpoint: $ENDPOINT"

# ------------------------------------------------------------
# Download Google OTA page
# ------------------------------------------------------------
wget -q \
  --no-check-certificate \
  -O "$HTML_FILE" \
  "$ENDPOINT"

if [ ! -s "$HTML_FILE" ]; then
  echo "Error: Unable to download OTA page!"
  exit 1
fi

# ------------------------------------------------------------
# Release date
# ------------------------------------------------------------
BETA_REL_DATE="$(
  grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$HTML_FILE" |
  head -n1 || true
)"

if [ -z "$BETA_REL_DATE" ]; then
  BETA_REL_DATE="$(date '+%Y-%m-%d')"
fi

# Estimate expiry = 6 weeks after release
BETA_EXP_DATE="$(
  date -d "$BETA_REL_DATE + 42 days" '+%Y-%m-%d' 2>/dev/null ||
  echo "Unknown"
)"

echo "Beta Released: $BETA_REL_DATE"
echo "Estimated Expiry: $BETA_EXP_DATE"

# ------------------------------------------------------------
# Extract OTA ZIP URLs
#
# Google currently publishes OTA files under:
# https://dl.google.com/dl/android/aosp/<OTA_FILE>.zip
# ------------------------------------------------------------
OTA_LIST="$(
  grep -oE 'https://dl\.google\.com/dl/android/aosp/[A-Za-z0-9._-]+\.zip' "$HTML_FILE" |
  sort -u
)"

# Fallback for relative OTA links
if [ -z "$OTA_LIST" ]; then
  OTA_LIST="$(
    grep -oE 'href="[^"]*ota/[A-Za-z0-9._-]+\.zip"' "$HTML_FILE" |
    sed -E 's/^href="([^"]*)".*/\1/' |
    sed 's#^#https://developer.android.com#' |
    sort -u
  )"
fi

if [ -z "$OTA_LIST" ]; then
  echo "Error: No Pixel Beta OTA ZIP links found!"
  exit 1
fi

echo
echo "Found OTA files:"
echo "$OTA_LIST"
echo

# ------------------------------------------------------------
# Target device override:
#
# ./script.sh -m tokay
# ------------------------------------------------------------
TARGET_DEVICE=""

if [ "${1:-}" = "-m" ] && [ -n "${2:-}" ]; then
  TARGET_DEVICE="$2"
fi

OTA=""
PRODUCT=""
DEVICE=""
MODEL=""

# ------------------------------------------------------------
# Select requested device
# ------------------------------------------------------------
if [ -n "$TARGET_DEVICE" ]; then

  DEVICE="$TARGET_DEVICE"
  PRODUCT="${TARGET_DEVICE}_beta"

  OTA="$(
    echo "$OTA_LIST" |
    grep -iE "/${TARGET_DEVICE}_beta-.*\.zip$" |
    head -n1 || true
  )"

  if [ -z "$OTA" ]; then
    echo "Error: No OTA found for device: $TARGET_DEVICE"
    echo
    echo "Available devices:"
    echo "$OTA_LIST" |
      sed -E 's#.*/([^/]+)_beta-.*#\1#' |
      sort -u
    exit 1
  fi

# ------------------------------------------------------------
# If running on an Android device, use getprop
# ------------------------------------------------------------
elif command -v getprop >/dev/null 2>&1 &&
     [ -n "$(getprop ro.product.device 2>/dev/null || true)" ]; then

  DEVICE="$(getprop ro.product.device)"
  MODEL="$(getprop ro.product.model)"

  PRODUCT="${DEVICE}_beta"

  OTA="$(
    echo "$OTA_LIST" |
    grep -iE "/${DEVICE}_beta-.*\.zip$" |
    head -n1 || true
  )

# ------------------------------------------------------------
# Otherwise select random Pixel device
# ------------------------------------------------------------
else

  echo "Selecting random Pixel device from Android 17 QPR2 list..."

  mapfile -t OTA_ARRAY < <(echo "$OTA_LIST")

  OTA_COUNT="${#OTA_ARRAY[@]}"

  if [ "$OTA_COUNT" -eq 0 ]; then
    echo "Error: OTA list is empty!"
    exit 1
  fi

  RANDOM_INDEX=$((RANDOM % OTA_COUNT))

  OTA="${OTA_ARRAY[$RANDOM_INDEX]}"

  OTA_FILE="$(basename "$OTA")"

  # Example:
  # tokay_beta-ota-cp41.260814.003.b1-1d691c88.zip
  PRODUCT="${OTA_FILE%%-ota-*}"

  DEVICE="${PRODUCT%_beta}"

fi

# ------------------------------------------------------------
# Model name
# ------------------------------------------------------------
case "$DEVICE" in
  tokay)
    MODEL="Pixel 9"
    ;;
  caiman)
    MODEL="Pixel 9 Pro"
    ;;
  komodo)
    MODEL="Pixel 9 Pro XL"
    ;;
  comet)
    MODEL="Pixel 9 Pro Fold"
    ;;
  mustang)
    MODEL="Pixel 10"
    ;;
  blazer)
    MODEL="Pixel 10 Pro"
    ;;
  Frankel)
    MODEL="Pixel 10 Pro XL"
    ;;
  *)
    MODEL="${MODEL:-Pixel Device}"
    ;;
esac

echo
echo "Selected Device: $MODEL ($PRODUCT)"
echo "OTA URL: $OTA"
echo

# ------------------------------------------------------------
# Download complete OTA ZIP
#
# IMPORTANT:
# Do NOT use Range: bytes=0-32768 here.
#
# META-INF/com/android/metadata is inside the ZIP and cannot
# reliably be read by simply grepping the first 32 KB.
# ------------------------------------------------------------
OTA_ZIP="PIXEL_OTA.zip"
OTA_METADATA="PIXEL_OTA_METADATA"

echo "Downloading OTA ZIP..."
echo "This may take some time..."

rm -f "$OTA_ZIP" "$OTA_METADATA"

wget \
  --no-check-certificate \
  --show-progress \
  -O "$OTA_ZIP" \
  "$OTA"

if [ ! -s "$OTA_ZIP" ]; then
  echo "Error: OTA download failed!"
  exit 1
fi

echo "OTA downloaded successfully."

# ------------------------------------------------------------
# Verify ZIP
# ------------------------------------------------------------
echo "Checking OTA ZIP..."

if ! unzip -tq "$OTA_ZIP" >/dev/null 2>&1; then
  echo "Error: Downloaded OTA is not a valid ZIP file!"
  exit 1
fi

# ------------------------------------------------------------
# Extract Android OTA metadata
# ------------------------------------------------------------
echo "Extracting OTA metadata..."

unzip -p \
  "$OTA_ZIP" \
  META-INF/com/android/metadata \
  > "$OTA_METADATA"

if [ ! -s "$OTA_METADATA" ]; then
  echo "Error: META-INF/com/android/metadata not found!"
  exit 1
fi

echo
echo "OTA metadata:"
echo "------------------------------------------------------------"
cat "$OTA_METADATA"
echo "------------------------------------------------------------"
echo

# ------------------------------------------------------------
# Extract fingerprint
# ------------------------------------------------------------
FINGERPRINT="$(
  grep -m1 '^post-build=' "$OTA_METADATA" |
  cut -d= -f2- |
  tr -d '\r'
)"

# ------------------------------------------------------------
# Extract security patch
# ------------------------------------------------------------
SECURITY_PATCH="$(
  grep -m1 '^security-patch-level=' "$OTA_METADATA" |
  cut -d= -f2- |
  tr -d '\r'
)"

# ------------------------------------------------------------
# Validate metadata
# ------------------------------------------------------------
if [ -z "$FINGERPRINT" ]; then
  echo "Error: Failed to extract post-build fingerprint!"
  exit 1
fi

if [ -z "$SECURITY_PATCH" ]; then
  echo "Error: Failed to extract security patch level!"
  exit 1
fi

echo "Extracted Fingerprint: $FINGERPRINT"
echo "Extracted Security Patch: $SECURITY_PATCH"

# ------------------------------------------------------------
# Generate pif.json
# ------------------------------------------------------------
cat > pif.json <<EOF
{
  "MANUFACTURER": "Google",
  "MODEL": "$MODEL",
  "FINGERPRINT": "$FINGERPRINT",
  "PRODUCT": "$PRODUCT",
  "DEVICE": "$DEVICE",
  "SECURITY_PATCH": "$SECURITY_PATCH",
  "DEVICE_INITIAL_SDK_INT": "32"
}
EOF

echo
echo "Generated pif.json:"
echo "------------------------------------------------------------"
cat pif.json
echo "------------------------------------------------------------"

# ------------------------------------------------------------
# Cleanup large OTA file
# ------------------------------------------------------------
rm -f "$OTA_ZIP" "$OTA_METADATA"

echo
echo "Done."

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

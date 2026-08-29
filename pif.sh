#!/bin/bash
set -Eeuo pipefail

trap 'echo "ERROR: command failed at line $LINENO: $BASH_COMMAND"; exit 1' ERR

echo "============================================================"
echo " Android 17 QPR2 Beta OTA Metadata"
echo "============================================================"

ENDPOINT="https://developer.android.com/about/versions/17/qpr2/download-ota"
HTML_FILE="PIXEL_OTA_HTML"

# ------------------------------------------------------------
# Target device
#
# Usage:
#   ./script.sh
#       -> random Pixel device
#
#   ./script.sh -m tokay
#       -> Pixel 9
# ------------------------------------------------------------

TARGET_DEVICE=""

if [ "${1:-}" = "-m" ] && [ -n "${2:-}" ]; then
    TARGET_DEVICE="$2"
fi

# ------------------------------------------------------------
# Download Google OTA page
# ------------------------------------------------------------

echo
echo "[1/6] Downloading Google OTA page..."

curl -L --fail --silent --show-error \
    -o "$HTML_FILE" \
    "$ENDPOINT"

if [ ! -s "$HTML_FILE" ]; then
    echo "ERROR: OTA page is empty."
    exit 1
fi

echo "OK: Downloaded $(wc -c < "$HTML_FILE") bytes"

# ------------------------------------------------------------
# Extract release information
# ------------------------------------------------------------

echo
echo "[2/6] Reading release information..."

RELEASE_DATE="$(
    grep -oE 'Release date.{0,500}' "$HTML_FILE" |
    grep -oE '[A-Z][a-z]+ [0-9]{1,2}, [0-9]{4}' |
    head -n1 || true
)"

if [ -z "$RELEASE_DATE" ]; then
    RELEASE_DATE="August 28, 2026"
fi

echo "Release date: $RELEASE_DATE"

SECURITY_PATCH_PAGE="$(
    grep -oE 'Security patch level.{0,300}' "$HTML_FILE" |
    grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' |
    head -n1 || true
)"

echo "Security patch from page: ${SECURITY_PATCH_PAGE:-unknown}"

# ------------------------------------------------------------
# Extract ACTUAL OTA links from Google's HTML
#
# Google currently uses URLs similar to:
#
# https://dl.google.com/developers/android/cinnamonbun/images/ota/
# tokay_beta-ota-cp41.260814.003.b1-1d691c88.zip
#
# DO NOT construct the URL manually.
# ------------------------------------------------------------

echo
echo "[3/6] Extracting OTA download links..."

# Extract href values which contain _beta-ota
mapfile -t OTA_URLS < <(
    grep -oE 'https://dl\.google\.com/[^"]+_beta-ota-[^"]+\.zip' "$HTML_FILE" |
    sed 's/&amp;/\&/g' |
    sort -u
)

# If Google's HTML contains relative/encoded links, try another method.
if [ "${#OTA_URLS[@]}" -eq 0 ]; then

    mapfile -t OTA_URLS < <(
        grep -oE 'href="[^"]+_beta-ota-[^"]+\.zip"' "$HTML_FILE" |
        sed -E 's/^href="([^"]+)".*/\1/' |
        sed 's/&amp;/\&/g' |
        sort -u
    )
fi

if [ "${#OTA_URLS[@]}" -eq 0 ]; then
    echo "ERROR: Could not find OTA download links."
    exit 1
fi

echo "Found ${#OTA_URLS[@]} OTA links."

# ------------------------------------------------------------
# Select device
# ------------------------------------------------------------

if [ -n "$TARGET_DEVICE" ]; then

    DEVICE="$TARGET_DEVICE"
    PRODUCT="${TARGET_DEVICE}_beta"

    echo
    echo "Requested device: $DEVICE"

    OTA=""

    for URL in "${OTA_URLS[@]}"; do

        FILE="$(basename "$URL")"

        if [[ "$FILE" == "${PRODUCT}-ota-"* ]]; then
            OTA="$URL"
            break
        fi

    done

    if [ -z "$OTA" ]; then
        echo
        echo "ERROR: No OTA found for $PRODUCT"
        echo
        echo "Available OTA devices:"

        for URL in "${OTA_URLS[@]}"; do
            basename "$URL" |
                sed -E 's/^([^_]+)_beta-ota-.*/\1/'
        done | sort -u

        exit 1
    fi

else

    # --------------------------------------------------------
    # Random device
    # --------------------------------------------------------

    echo
    echo "Selecting random Pixel device..."

    OTA_COUNT="${#OTA_URLS[@]}"

    RANDOM_INDEX=$((RANDOM % OTA_COUNT))

    OTA="${OTA_URLS[$RANDOM_INDEX]}"

    FILE="$(basename "$OTA")"

    PRODUCT="${FILE%%-ota-*}"
    DEVICE="${PRODUCT%_beta}"

fi

# ------------------------------------------------------------
# Determine model
# ------------------------------------------------------------

case "$DEVICE" in
    bluejay)
        MODEL="Pixel 6a"
        ;;
    panther)
        MODEL="Pixel 7"
        ;;
    cheetah)
        MODEL="Pixel 7 Pro"
        ;;
    lynx)
        MODEL="Pixel 7a"
        ;;
    felix)
        MODEL="Pixel Fold"
        ;;
    tangorpro)
        MODEL="Pixel Tablet"
        ;;
    shiba)
        MODEL="Pixel 8"
        ;;
    husky)
        MODEL="Pixel 8 Pro"
        ;;
    akita)
        MODEL="Pixel 8a"
        ;;
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
    tegu)
        MODEL="Pixel 9a"
        ;;
    frankel)
        MODEL="Pixel 10"
        ;;
    blazer)
        MODEL="Pixel 10 Pro"
        ;;
    mustang)
        MODEL="Pixel 10 Pro XL"
        ;;
    rango)
        MODEL="Pixel 10 Pro Fold"
        ;;
    stallion)
        MODEL="Pixel 10a"
        ;;
    *)
        MODEL="Pixel Device"
        ;;
esac

echo
echo "============================================================"
echo " SELECTED DEVICE"
echo "============================================================"
echo "Model:       $MODEL"
echo "Device:      $DEVICE"
echo "Product:     $PRODUCT"
echo "OTA:         $(basename "$OTA")"
echo "Download:    $OTA"
echo "============================================================"

# ------------------------------------------------------------
# Download OTA ZIP
# ------------------------------------------------------------

echo
echo "[4/6] Downloading OTA ZIP..."

rm -f PIXEL_OTA.zip
rm -f PIXEL_OTA_METADATA

curl -L \
    --fail \
    --show-error \
    --retry 3 \
    --retry-delay 2 \
    -o PIXEL_OTA.zip \
    "$OTA"

if [ ! -s PIXEL_OTA.zip ]; then
    echo "ERROR: OTA ZIP is empty."
    exit 1
fi

echo "OTA downloaded."
echo "Size: $(du -h PIXEL_OTA.zip | cut -f1)"

# ------------------------------------------------------------
# Validate ZIP
# ------------------------------------------------------------

echo
echo "[5/6] Reading OTA metadata..."

if ! unzip -tq PIXEL_OTA.zip >/dev/null 2>&1; then
    echo "ERROR: Downloaded OTA is not a valid ZIP."
    exit 1
fi

if ! unzip -l PIXEL_OTA.zip |
    grep -q 'META-INF/com/android/metadata'; then

    echo "ERROR: META-INF/com/android/metadata not found."

    echo
    echo "Available metadata files:"
    unzip -l PIXEL_OTA.zip |
        grep -i 'metadata\|META-INF' |
        head -50 || true

    exit 1
fi

unzip -p \
    PIXEL_OTA.zip \
    META-INF/com/android/metadata \
    > PIXEL_OTA_METADATA

if [ ! -s PIXEL_OTA_METADATA ]; then
    echo "ERROR: Metadata extraction failed."
    exit 1
fi

echo
echo "------------------------------------------------------------"
echo "OTA METADATA"
echo "------------------------------------------------------------"

cat PIXEL_OTA_METADATA

echo "------------------------------------------------------------"

# ------------------------------------------------------------
# Extract standard Android OTA fields
# ------------------------------------------------------------

POST_BUILD="$(
    grep -m1 '^post-build=' PIXEL_OTA_METADATA |
    cut -d= -f2- |
    tr -d '\r'
)"

SECURITY_PATCH="$(
    grep -m1 '^security-patch-level=' PIXEL_OTA_METADATA |
    cut -d= -f2- |
    tr -d '\r'
)"

POST_SDK="$(
    grep -m1 '^post-sdk-level=' PIXEL_OTA_METADATA |
    cut -d= -f2- |
    tr -d '\r'
)"

# ------------------------------------------------------------
# Display extracted information
# ------------------------------------------------------------

echo
echo "============================================================"
echo " EXTRACTED OTA INFORMATION"
echo "============================================================"
echo "Model:          $MODEL"
echo "Device:         $DEVICE"
echo "Product:        $PRODUCT"
echo "Build:          ${POST_BUILD:-unknown}"
echo "SDK level:      ${POST_SDK:-unknown}"
echo "Security patch: ${SECURITY_PATCH:-unknown}"
echo "============================================================"

if [ -z "$POST_BUILD" ]; then
    echo "ERROR: post-build not found in OTA metadata."
    exit 1
fi

if [ -z "$SECURITY_PATCH" ]; then
    echo "ERROR: security-patch-level not found in OTA metadata."
    exit 1
fi

# ------------------------------------------------------------
# Generate JSON
# ------------------------------------------------------------

echo
echo "[6/6] Generating JSON..."

cat > pif.json <<EOF
{
  "MANUFACTURER": "Google",
  "MODEL": "$MODEL",
  "FINGERPRINT": "$POST_BUILD",
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
# Cleanup
# ------------------------------------------------------------

rm -f PIXEL_OTA.zip
rm -f PIXEL_OTA_METADATA
rm -f PIXEL_OTA_HTML

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

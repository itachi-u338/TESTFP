#!/usr/bin/env bash
set -euo pipefail

OTA_PAGE="https://developer.android.com/about/versions/17/qpr2/download-ota"

HTML_FILE="qpr2_ota.html"
META_FILE="ota_metadata"

echo "=============================================="
echo " Android 17 QPR2 OTA metadata"
echo "=============================================="
echo "Source:"
echo "$OTA_PAGE"
echo

# ------------------------------------------------------------
# Requirements
# ------------------------------------------------------------

for cmd in curl python3 grep sed awk sort unzip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command '$cmd' is not installed."
        exit 1
    fi
done

# ------------------------------------------------------------
# Download Google's OTA page
# ------------------------------------------------------------

echo "Fetching Google OTA page..."

curl -fsSL \
    --retry 3 \
    --retry-delay 2 \
    "$OTA_PAGE" \
    -o "$HTML_FILE"

if [ ! -s "$HTML_FILE" ]; then
    echo "Error: Google OTA page is empty."
    exit 1
fi

# ------------------------------------------------------------
# Release information
# ------------------------------------------------------------

RELEASE_DATE="$(
    grep -m1 -A2 'Release date' "$HTML_FILE" |
    grep -oE '[A-Z][a-z]+ [0-9]{1,2}, [0-9]{4}' |
    head -n1 || true
)"

SECURITY_PATCH_PAGE="$(
    grep -m1 -A10 'Security patch level' "$HTML_FILE" |
    grep -oE '202[0-9]-[0-9]{2}-[0-9]{2}' |
    head -n1 || true
)"

echo "Release date: ${RELEASE_DATE:-Unknown}"
echo "Page security patch: ${SECURITY_PATCH_PAGE:-Unknown}"
echo

# ------------------------------------------------------------
# Extract COMPLETE OTA ZIP URLs
# ------------------------------------------------------------

echo "Extracting OTA URLs..."

mapfile -t OTA_FILES < <(
    grep -oE 'https://dl\.google\.com/[^"]+_beta-ota-[^"]+\.zip' "$HTML_FILE" |
    sort -u
)

if [ "${#OTA_FILES[@]}" -eq 0 ]; then
    echo "Error: No QPR2 OTA files were found."
    exit 1
fi

echo "Found ${#OTA_FILES[@]} OTA files."
echo

# ------------------------------------------------------------
# Random device selection
# ------------------------------------------------------------

if [ "${1:-}" = "-m" ] && [ -n "${2:-}" ]; then

    TARGET_DEVICE="$2"

    echo "Requested device: $TARGET_DEVICE"

    TARGET_PRODUCT="${TARGET_DEVICE}_beta"

    OTA=""

    for candidate in "${OTA_FILES[@]}"; do
        filename="$(basename "$candidate")"

        if [[ "$filename" == "${TARGET_PRODUCT}-ota-"* ]]; then
            OTA="$candidate"
            break
        fi
    done

    if [ -z "$OTA" ]; then
        echo "Error: No QPR2 OTA found for $TARGET_DEVICE"
        exit 1
    fi

else

    echo "Selecting random Pixel device from Android 17 QPR2 list..."

    RANDOM_INDEX=$((RANDOM % ${#OTA_FILES[@]}))

    OTA="${OTA_FILES[$RANDOM_INDEX]}"

fi

# ------------------------------------------------------------
# Parse selected OTA filename
# ------------------------------------------------------------

OTA_FILENAME="$(basename "$OTA")"

PRODUCT="${OTA_FILENAME%%-ota-*}"

DEVICE="${PRODUCT%_beta}"

OTA_URL="$OTA"

echo "Selected OTA:"
echo "$OTA_FILENAME"
echo

echo "Device:"
echo "$DEVICE"
echo

echo "Product:"
echo "$PRODUCT"
echo

echo "OTA URL:"
echo "$OTA_URL"
echo

# ------------------------------------------------------------
# Device model mapping
# ------------------------------------------------------------

case "$DEVICE" in
    bluejay)
        MODEL="Pixel 6a"
        ;;
    oriole)
        MODEL="Pixel 6"
        ;;
    raven)
        MODEL="Pixel 6 Pro"
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
    blazr)
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
        MODEL="$DEVICE"
        ;;
esac

echo "Model:"
echo "$MODEL"
echo

# ------------------------------------------------------------
# Check OTA server
# ------------------------------------------------------------

echo "Checking OTA server..."

HTTP_STATUS="$(
    curl -L \
        -s \
        -o /dev/null \
        -w '%{http_code}' \
        --retry 3 \
        "$OTA_URL" || true
)"

echo "OTA HTTP status: $HTTP_STATUS"

if [ "$HTTP_STATUS" != "200" ]; then
    echo
    echo "Error: Google OTA returned HTTP $HTTP_STATUS"
    echo "URL: $OTA_URL"
    echo
    echo "This usually means the OTA URL on Google's page is no longer"
    echo "available or Google changed the download endpoint."
    exit 1
fi

# ------------------------------------------------------------
# Get OTA file size
# ------------------------------------------------------------

echo
echo "Getting OTA file size..."

ZIP_SIZE="$(
    curl -fsSLI \
        --retry 3 \
        "$OTA_URL" |
    awk 'BEGIN { IGNORECASE=1 }
         /^content-length:/ {
             gsub("\r", "", $2)
             print $2
             exit
         }'
)"

if [ -z "$ZIP_SIZE" ]; then
    echo "Error: Could not determine OTA ZIP size."
    exit 1
fi

echo "OTA size: $ZIP_SIZE bytes"

# ------------------------------------------------------------
# Extract ZIP metadata WITHOUT downloading whole OTA
# ------------------------------------------------------------

echo
echo "Locating OTA metadata using HTTP Range requests..."

python3 - "$OTA_URL" "$ZIP_SIZE" "$META_FILE" <<'PY'
import sys
import struct
import subprocess

url = sys.argv[1]
size = int(sys.argv[2])
output = sys.argv[3]

def curl_range(start, end):
    command = [
        "curl",
        "-fsSL",
        "--retry", "3",
        "--retry-delay", "1",
        "-r",
        f"{start}-{end}",
        url
    ]

    return subprocess.check_output(command)

# ------------------------------------------------------------
# Fetch final part of ZIP
# ------------------------------------------------------------

TAIL_SIZE = min(131072, size)

tail_start = size - TAIL_SIZE
tail_end = size - 1

print(
    f"Downloading final ZIP section: "
    f"{tail_start}-{tail_end}"
)

tail = curl_range(tail_start, tail_end)

# EOCD signature
EOCD = b"PK\x05\x06"

position = tail.rfind(EOCD)

if position < 0:
    raise SystemExit(
        "Error: ZIP end-of-central-directory record not found."
    )

if position + 22 > len(tail):
    raise SystemExit(
        "Error: ZIP EOCD record is incomplete."
    )

eocd = tail[position:position + 22]

(
    signature,
    disk_number,
    central_directory_disk,
    disk_entries,
    total_entries,
    central_directory_size,
    central_directory_offset,
    comment_length
) = struct.unpack(
    "<4sHHHHIIH",
    eocd
)

if signature != EOCD:
    raise SystemExit(
        "Error: Invalid ZIP EOCD signature."
    )

print(f"ZIP entries: {total_entries}")
print(
    f"Central directory offset: "
    f"{central_directory_offset}"
)
print(
    f"Central directory size: "
    f"{central_directory_size}"
)

# ------------------------------------------------------------
# Fetch central directory
# ------------------------------------------------------------

cd_start = central_directory_offset
cd_end = cd_start + central_directory_size - 1

print(
    f"Downloading central directory: "
    f"{cd_start}-{cd_end}"
)

central_directory = curl_range(
    cd_start,
    cd_end
)

TARGET = b"META-INF/com/android/metadata"

position = 0
metadata_entry = None

for _ in range(total_entries):

    if position + 46 > len(central_directory):
        break

    if central_directory[position:position + 4] != b"PK\x01\x02":
        break

    header = central_directory[position:position + 46]

    fields = struct.unpack(
        "<4s6H3I5H2I",
        header
    )

    compression_method = fields[4]
    compressed_size = fields[8]
    uncompressed_size = fields[9]
    filename_length = fields[10]
    extra_length = fields[11]
    comment_length = fields[12]
    local_header_offset = fields[16]

    filename_start = position + 46
    filename_end = filename_start + filename_length

    filename = central_directory[
        filename_start:filename_end
    ]

    if filename == TARGET:

        metadata_entry = {
            "compression": compression_method,
            "compressed_size": compressed_size,
            "uncompressed_size": uncompressed_size,
            "local_offset": local_header_offset,
            "filename_length": filename_length,
            "extra_length": extra_length
        }

        break

    position = (
        filename_end
        + extra_length
        + comment_length
    )

if metadata_entry is None:
    raise SystemExit(
        "Error: META-INF/com/android/metadata "
        "was not found."
    )

print("Found OTA metadata entry.")

compression = metadata_entry["compression"]
compressed_size = metadata_entry["compressed_size"]
local_offset = metadata_entry["local_offset"]

# ------------------------------------------------------------
# Fetch local ZIP header
# ------------------------------------------------------------

local_header = curl_range(
    local_offset,
    local_offset + 29
)

if local_header[:4] != b"PK\x03\x04":
    raise SystemExit(
        "Error: Invalid ZIP local header."
    )

local_fields = struct.unpack(
    "<4s5H3I2H",
    local_header[:30]
)

local_filename_length = local_fields[9]
local_extra_length = local_fields[10]

data_offset = (
    local_offset
    + 30
    + local_filename_length
    + local_extra_length
)

print(f"Metadata data offset: {data_offset}")
print(f"Metadata compressed size: {compressed_size}")

# ------------------------------------------------------------
# Fetch ONLY the metadata entry
# ------------------------------------------------------------

metadata_data = curl_range(
    data_offset,
    data_offset + compressed_size - 1
)

if len(metadata_data) != compressed_size:
    raise SystemExit(
        f"Error: Expected {compressed_size} bytes, "
        f"received {len(metadata_data)}."
    )

# ------------------------------------------------------------
# Decompress if required
# ------------------------------------------------------------

if compression == 0:

    decoded = metadata_data

elif compression == 8:

    import zlib

    decoded = zlib.decompress(
        metadata_data,
        -15
    )

else:

    raise SystemExit(
        f"Error: Unsupported ZIP compression method "
        f"{compression}"
    )

with open(output, "wb") as file:
    file.write(decoded)

print(
    f"Metadata extracted successfully: "
    f"{len(decoded)} bytes"
)
PY

# ------------------------------------------------------------
# Verify metadata
# ------------------------------------------------------------

if [ ! -s "$META_FILE" ]; then
    echo "Error: OTA metadata is empty."
    exit 1
fi

echo
echo "=============================================="
echo " OTA METADATA"
echo "=============================================="

cat "$META_FILE"

echo
echo "=============================================="

# ------------------------------------------------------------
# Extract metadata values
# ------------------------------------------------------------

POST_BUILD="$(
    sed -n 's/^post-build=//p' "$META_FILE" |
    head -n1 |
    tr -d '\r'
)"

SECURITY_PATCH="$(
    sed -n 's/^security-patch-level=//p' "$META_FILE" |
    head -n1 |
    tr -d '\r'
)"

POST_SDK_LEVEL="$(
    sed -n 's/^post-sdk-level=//p' "$META_FILE" |
    head -n1 |
    tr -d '\r'
)"

echo
echo "=============================================="
echo " RESULT"
echo "=============================================="

echo "Model:            $MODEL"
echo "Device:           $DEVICE"
echo "Product:          $PRODUCT"
echo "OTA:              $OTA_FILENAME"
echo "Fingerprint:      ${POST_BUILD:-Not present}"
echo "Security patch:   ${SECURITY_PATCH:-${SECURITY_PATCH_PAGE:-Unknown}}"
echo "Post SDK level:   ${POST_SDK_LEVEL:-Unknown}"

# ------------------------------------------------------------
# GitHub Actions outputs
# ------------------------------------------------------------

if [ -n "${GITHUB_OUTPUT:-}" ]; then

    {
        echo "device=$DEVICE"
        echo "model=$MODEL"
        echo "product=$PRODUCT"
        echo "ota_filename=$OTA_FILENAME"
        echo "ota_url=$OTA_URL"
        echo "fingerprint=$POST_BUILD"
        echo "security_patch=${SECURITY_PATCH:-${SECURITY_PATCH_PAGE:-}}"
        echo "post_sdk_level=$POST_SDK_LEVEL"
    } >> "$GITHUB_OUTPUT"

fi

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

rm -f "$HTML_FILE"
rm -f "$META_FILE"

echo
echo "=============================================="
echo " SUCCESS"
echo "=============================================="
echo "The complete OTA ZIP was NOT downloaded."

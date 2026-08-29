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

for cmd in curl python3 grep sed awk sort; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command '$cmd' is not installed."
        exit 1
    fi
done

# ------------------------------------------------------------
# Download Google's small HTML page
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
    grep -m1 -A1 'Release date' "$HTML_FILE" |
    grep -oE '[A-Z][a-z]+ [0-9]{1,2}, [0-9]{4}' |
    head -n1 || true
)"

BUILD_LIST="$(
    grep -A5 'Release date' "$HTML_FILE" |
    grep -oE 'CP[0-9A-Z.]+'
    | sort -u
    | tr '\n' ' '
)"

SECURITY_PATCH="$(
    grep -m1 -A8 'Security patch level' "$HTML_FILE" |
    grep -oE '202[0-9]-[0-9]{2}-[0-9]{2}' |
    head -n1 || true
)"

echo "Release date: ${RELEASE_DATE:-Unknown}"
echo "Builds: ${BUILD_LIST:-Unknown}"
echo "Security patch: ${SECURITY_PATCH:-Unknown}"
echo

# ------------------------------------------------------------
# Extract OTA ZIP filenames from Google's page
# ------------------------------------------------------------

echo "Extracting OTA entries..."

mapfile -t OTA_FILES < <(
    grep -oE '[a-z0-9]+_beta-ota-cp[0-9a-z.]+-[0-9a-f]+\.zip' "$HTML_FILE" |
    sort -u
)

if [ "${#OTA_FILES[@]}" -eq 0 ]; then
    echo "Error: No QPR2 OTA files were found."
    exit 1
fi

echo "Found ${#OTA_FILES[@]} OTA entries."
echo

# ------------------------------------------------------------
# Random device
# ------------------------------------------------------------

RANDOM_INDEX=$((RANDOM % ${#OTA_FILES[@]}))

OTA_FILENAME="${OTA_FILES[$RANDOM_INDEX]}"

PRODUCT="${OTA_FILENAME%%-ota-*}"
DEVICE="${PRODUCT%_beta}"

OTA_URL="https://dl.google.com/developers/android/cinnamonbun/images/ota/${OTA_FILENAME}"

echo "Selected OTA:"
echo "$OTA_FILENAME"
echo

echo "Device:"
echo "$DEVICE"
echo

echo "OTA URL:"
echo "$OTA_URL"
echo

# ------------------------------------------------------------
# Device name mapping
# ------------------------------------------------------------

case "$DEVICE" in
    bluejay)   MODEL="Pixel 6a" ;;
    panther)   MODEL="Pixel 7" ;;
    cheetah)   MODEL="Pixel 7 Pro" ;;
    lynx)      MODEL="Pixel 7a" ;;
    felix)     MODEL="Pixel Fold" ;;
    tangorpro) MODEL="Pixel Tablet" ;;
    shiba)     MODEL="Pixel 8" ;;
    husky)     MODEL="Pixel 8 Pro" ;;
    akita)     MODEL="Pixel 8a" ;;
    tokay)     MODEL="Pixel 9" ;;
    caiman)    MODEL="Pixel 9 Pro" ;;
    komodo)    MODEL="Pixel 9 Pro XL" ;;
    comet)     MODEL="Pixel 9 Pro Fold" ;;
    tegu)      MODEL="Pixel 9a" ;;
    frankel)   MODEL="Pixel 10" ;;
    blazer)    MODEL="Pixel 10 Pro" ;;
    mustang)   MODEL="Pixel 10 Pro XL" ;;
    rango)     MODEL="Pixel 10 Pro Fold" ;;
    stallion)  MODEL="Pixel 10a" ;;
    *)
        MODEL="$DEVICE"
        ;;
esac

echo "Model:"
echo "$MODEL"
echo

# ------------------------------------------------------------
# Obtain remote ZIP size
# ------------------------------------------------------------

echo "Checking remote OTA..."

ZIP_SIZE="$(
    curl -fsSLI \
        --retry 3 \
        "$OTA_URL" |
    awk 'BEGIN{IGNORECASE=1}
         /^content-length:/ {
             gsub("\r","",$2);
             print $2;
             exit
         }'
)"

if [ -z "$ZIP_SIZE" ]; then
    echo "Error: Could not determine OTA ZIP size."
    exit 1
fi

echo "Remote ZIP size: $ZIP_SIZE bytes"

# ------------------------------------------------------------
# Extract META-INF/com/android/metadata using HTTP Range
#
# This DOES NOT download the entire OTA.
#
# ZIP layout:
#
#   [local file entries]
#   [central directory]
#   [EOCD]
#
# We first fetch the final portion of the ZIP, locate the EOCD,
# obtain the central directory location, then fetch only that
# directory and the metadata entry.
# ------------------------------------------------------------

echo
echo "Locating ZIP central directory..."

python3 - "$OTA_URL" "$ZIP_SIZE" "$META_FILE" <<'PY'
import sys
import struct
import subprocess
import tempfile
import os

url = sys.argv[1]
size = int(sys.argv[2])
output = sys.argv[3]

# Last 128 KiB is enough for the normal ZIP EOCD.
TAIL = min(131072, size)

start = size - TAIL
end = size - 1

def curl_range(a, b):
    cmd = [
        "curl",
        "-fsSL",
        "--retry", "3",
        "--retry-delay", "1",
        "-r", f"{a}-{b}",
        url
    ]
    return subprocess.check_output(cmd)

tail = curl_range(start, end)

# EOCD signature = PK\x05\x06
sig = b"PK\x05\x06"

pos = tail.rfind(sig)

if pos < 0:
    raise SystemExit("Error: ZIP end-of-central-directory record not found.")

if pos + 22 > len(tail):
    raise SystemExit("Error: Incomplete ZIP EOCD record.")

eocd = tail[pos:pos + 22]

(
    signature,
    disk,
    cd_disk,
    disk_entries,
    total_entries,
    cd_size,
    cd_offset,
    comment_length
) = struct.unpack("<4sHHHHIIH", eocd)

if signature != sig:
    raise SystemExit("Error: Invalid ZIP EOCD signature.")

print(f"ZIP entries: {total_entries}")
print(f"Central directory size: {cd_size}")
print(f"Central directory offset: {cd_offset}")

# ----------------------------------------------------------
# Fetch central directory
# ----------------------------------------------------------

cd = curl_range(cd_offset, cd_offset + cd_size - 1)

target = b"META-INF/com/android/metadata"

found = None
p = 0

for _ in range(total_entries):
    if p + 46 > len(cd):
        break

    if cd[p:p+4] != b"PK\x01\x02":
        break

    header = cd[p:p+46]

    fields = struct.unpack("<4s6H3I5H2I", header)

    compression = fields[4]
    compressed_size = fields[8]
    uncompressed_size = fields[9]
    filename_length = fields[10]
    extra_length = fields[11]
    comment_length = fields[12]
    local_offset = fields[16]

    name_start = p + 46
    name_end = name_start + filename_length

    name = cd[name_start:name_end]

    if name == target:
        found = (
            compression,
            compressed_size,
            uncompressed_size,
            filename_length,
            extra_length,
            local_offset
        )
        break

    p = name_end + extra_length + comment_length

if found is None:
    raise SystemExit(
        "Error: META-INF/com/android/metadata "
        "was not found in the ZIP central directory."
    )

(
    compression,
    compressed_size,
    uncompressed_size,
    filename_length,
    extra_length,
    local_offset
) = found

print(f"Metadata compression method: {compression}")
print(f"Metadata compressed size: {compressed_size}")
print(f"Metadata uncompressed size: {uncompressed_size}")
print(f"Metadata local offset: {local_offset}")

# ----------------------------------------------------------
# Fetch local file header
# ----------------------------------------------------------

local_header = curl_range(local_offset, local_offset + 29)

if local_header[:4] != b"PK\x03\x04":
    raise SystemExit("Error: Invalid ZIP local-file header.")

lh = struct.unpack("<4s5H3I2H", local_header[:30])

local_filename_length = lh[9]
local_extra_length = lh[10]

data_offset = (
    local_offset
    + 30
    + local_filename_length
    + local_extra_length
)

print(f"Metadata data offset: {data_offset}")

# ----------------------------------------------------------
# Fetch ONLY metadata bytes
# ----------------------------------------------------------

data = curl_range(
    data_offset,
    data_offset + compressed_size - 1
)

if len(data) != compressed_size:
    raise SystemExit(
        f"Error: expected {compressed_size} metadata bytes, "
        f"received {len(data)}."
    )

# Metadata is normally stored without compression.
if compression == 0:
    decoded = data

elif compression == 8:
    import zlib
    decoded = zlib.decompress(data, -15)

else:
    raise SystemExit(
        f"Error: unsupported ZIP compression method {compression}"
    )

with open(output, "wb") as f:
    f.write(decoded)

print(f"Metadata extracted: {len(decoded)} bytes")
PY

# ------------------------------------------------------------
# Display metadata
# ------------------------------------------------------------

if [ ! -s "$META_FILE" ]; then
    echo "Error: metadata extraction produced an empty file."
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
# Extract useful fields
# ------------------------------------------------------------

POST_BUILD="$(
    sed -n 's/^post-build=//p' "$META_FILE" |
    head -n1 |
    tr -d '\r'
)"

SECURITY_PATCH_METADATA="$(
    sed -n 's/^security-patch-level=//p' "$META_FILE" |
    head -n1 |
    tr -d '\r'
)"

POST_SDK="$(
    sed -n 's/^post-sdk-level=//p' "$META_FILE" |
    head -n1 |
    tr -d '\r'
)"

echo
echo "Device:              $MODEL"
echo "Codename:            $DEVICE"
echo "OTA filename:        $OTA_FILENAME"
echo "Build fingerprint:   ${POST_BUILD:-Not present}"
echo "Security patch:      ${SECURITY_PATCH_METADATA:-$SECURITY_PATCH}"
echo "Post SDK level:      ${POST_SDK:-Unknown}"

# ------------------------------------------------------------
# Optional GitHub Actions outputs
# ------------------------------------------------------------

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "device=$DEVICE"
        echo "model=$MODEL"
        echo "ota_filename=$OTA_FILENAME"
        echo "ota_url=$OTA_URL"
        echo "fingerprint=$POST_BUILD"
        echo "security_patch=${SECURITY_PATCH_METADATA:-$SECURITY_PATCH}"
        echo "post_sdk_level=$POST_SDK"
    } >> "$GITHUB_OUTPUT"
fi

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

rm -f "$HTML_FILE" "$META_FILE"

echo
echo "Success."
echo "The complete OTA ZIP was NOT downloaded."

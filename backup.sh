#! /bin/sh

# Safer defaults for busybox/ash
set -e
set -o pipefail 2>/dev/null || true

>&2 echo "-----"

# ---- Validate S3 env ----
if [ "${S3_ACCESS_KEY_ID}" = "**None**" ] || [ -z "${S3_ACCESS_KEY_ID:-}" ]; then
  echo "You need to set the S3_ACCESS_KEY_ID environment variable."
  exit 1
fi

if [ "${S3_SECRET_ACCESS_KEY}" = "**None**" ] || [ -z "${S3_SECRET_ACCESS_KEY:-}" ]; then
  echo "You need to set the S3_SECRET_ACCESS_KEY environment variable."
  exit 1
fi

if [ "${S3_BUCKET}" = "**None**" ] || [ -z "${S3_BUCKET:-}" ]; then
  echo "You need to set the S3_BUCKET environment variable."
  exit 1
fi

# ---- Validate SQLite source ----
if [ -z "${SQLITE_DB_PATH:-}" ]; then
  echo "You need to set SQLITE_DB_PATH to the SQLite database file (e.g., /mnt/src/config/jellyfin.db)."
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is not installed in this image. Install it or use an image that includes sqlite3."
  exit 1
fi

# ---- AWS/MiniO config ----
if [ "${S3_ENDPOINT}" = "**None**" ] || [ -z "${S3_ENDPOINT:-}" ]; then
  AWS_ARGS=""
else
  AWS_ARGS="--endpoint-url ${S3_ENDPOINT}"
fi

export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${S3_REGION:-}"

# Compression command (default gzip)
if [ -z "${COMPRESSION_CMD:-}" ]; then
  COMPRESSION_CMD="gzip -c"
fi

TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
DB_BASENAME="$(basename "$SQLITE_DB_PATH")"
DB_NAME="${DB_BASENAME%.*}"

# Files
TMP_FILE="/tmp/${DB_NAME}_${TS}.sqlite"
SRC_FILE="/tmp/${DB_NAME}_${TS}.sqlite"
DEST_FILE="${DB_NAME}_${TS}.sqlite"

# Create consistent SQLite backup using the built-in .backup command
echo "Creating SQLite backup of ${SQLITE_DB_PATH}..."
sqlite3 "$SQLITE_DB_PATH" ".backup '${TMP_FILE}'"

# Optionally compress
if [ -n "${COMPRESSION_CMD:-}" ]; then
  SRC_FILE="${SRC_FILE}.gz"
  DEST_FILE="${DEST_FILE}.gz"
  echo "Compressing backup (${COMPRESSION_CMD})..."
  # shellcheck disable=SC2086
  $COMPRESSION_CMD < "$TMP_FILE" > "$SRC_FILE"
  rm -f "$TMP_FILE"
else
  # No compression requested
  :
fi

# Optional encryption
if [ "${ENCRYPTION_PASSWORD}" != "**None**" ] && [ -n "${ENCRYPTION_PASSWORD:-}" ]; then
  >&2 echo "Encrypting ${SRC_FILE}"
  openssl enc -aes-256-cbc -in "$SRC_FILE" -out "${SRC_FILE}.enc" -k "$ENCRYPTION_PASSWORD"
  if [ $? -ne 0 ]; then
    >&2 echo "Error encrypting ${SRC_FILE}"
    exit 1
  fi
  rm -f "$SRC_FILE"
  SRC_FILE="${SRC_FILE}.enc"
  DEST_FILE="${DEST_FILE}.enc"
fi

S3_PREFIX="${S3_PREFIX:-}"

echo "Uploading backup to s3://${S3_BUCKET}/${S3_PREFIX}/${DEST_FILE}"
cat "$SRC_FILE" | aws $AWS_ARGS s3 cp - "s3://${S3_BUCKET}/${S3_PREFIX}/${DEST_FILE}" || exit 2
rm -f "$SRC_FILE"

# Optional retention
if [ "${DELETE_OLDER_THAN}" != "**None**" ] && [ -n "${DELETE_OLDER_THAN:-}" ]; then
  >&2 echo "Checking for files older than ${DELETE_OLDER_THAN}"
  aws $AWS_ARGS s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" | grep " PRE " -v | while read -r line; do
    fileName=$(echo "$line" | awk '{print $4}')
    created=$(echo "$line" | awk '{print $1" "$2}')
    created=$(date -d "$created" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M" "$created" +%s)
    older_than=$(date -d "$DELETE_OLDER_THAN" +%s 2>/dev/null || true)
    if [ -n "$fileName" ] && [ -n "$created" ] && [ -n "$older_than" ] && [ "$created" -lt "$older_than" ]; then
      >&2 echo "DELETING ${fileName}"
      aws $AWS_ARGS s3 rm "s3://${S3_BUCKET}/${S3_PREFIX}/${fileName}" || true
    else
      >&2 echo "${fileName} not older than ${DELETE_OLDER_THAN}"
    fi
  done
fi

echo "SQLite backup finished"
>&2 echo "-----"

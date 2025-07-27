#! /bin/sh

# Safer defaults for busybox/ash
set -e
(set -o pipefail) 2>/dev/null || true

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

# ---- Build list of SQLite sources from one env var ----
# Provide either one path or multiple paths separated by ';' or newlines.
if [ -z "${SQLITE_DB_PATH:-}" ]; then
  echo "Set SQLITE_DB_PATH with one or more absolute paths (semicolon or newline separated)."
  exit 1
fi

# Normalize newlines to semicolons and collapse duplicate delimiters
_LIST_RAW="$(printf '%s' "${SQLITE_DB_PATH}" | tr '\n' ';' | sed 's/;;*/;/g; s/^;//; s/;$//')"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is not installed in this image. Install it or use an image that includes sqlite3."
  exit 1
fi

# ---- AWS/MinIO config ----
if [ "${S3_ENDPOINT}" = "**None**" ] || [ -z "${S3_ENDPOINT:-}" ]; then
  AWS_ARGS=""
else
  AWS_ARGS="--endpoint-url ${S3_ENDPOINT}"
fi

export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${S3_REGION:-}"

# Compression command (default gzip to stdout)
if [ -z "${COMPRESSION_CMD:-}" ]; then
  COMPRESSION_CMD="gzip -c"
fi

S3_PREFIX="${S3_PREFIX:-}"

# Single run timestamp folder (use hyphens for colon to avoid awkward keys)
RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
if [ -n "${S3_PREFIX}" ]; then
  RUN_PREFIX="${S3_PREFIX%/}/${RUN_TS}/"
else
  RUN_PREFIX="${RUN_TS}/"
fi

backup_one() {
  _SRC_PATH="$1"

  # Trim whitespace
  _SRC_PATH="$(echo "$_SRC_PATH" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$_SRC_PATH" ] && return 0  # skip blanks

  if [ ! -f "$_SRC_PATH" ]; then
    >&2 echo "Skipping: not a file -> $_SRC_PATH"
    return 1
  fi

  DB_BASENAME="$(basename "$_SRC_PATH")"     # keep the original filename for S3 object name
  TMP_FILE="/tmp/${DB_BASENAME}.bak"         # temporary raw backup
  SRC_FILE="$TMP_FILE"                        # may change if compressed/encrypted
  DEST_FILE="$DB_BASENAME"                    # object key base name (preserve original)

  echo "Creating SQLite backup of ${_SRC_PATH}..."
  sqlite3 "$_SRC_PATH" ".backup '${TMP_FILE}'" || return 1

  # Optional compression
  if [ -n "${COMPRESSION_CMD:-}" ]; then
    SRC_FILE="${TMP_FILE}.gz"
    DEST_FILE="${DEST_FILE}.gz"
    echo "Compressing backup (${COMPRESSION_CMD})..."
    # shellcheck disable=SC2086
    $COMPRESSION_CMD < "$TMP_FILE" > "$SRC_FILE" || { rm -f "$TMP_FILE"; return 1; }
    rm -f "$TMP_FILE"
  fi

  # Optional encryption
  if [ "${ENCRYPTION_PASSWORD}" != "**None**" ] && [ -n "${ENCRYPTION_PASSWORD:-}" ]; then
    >&2 echo "Encrypting ${SRC_FILE}"
    if ! openssl enc -aes-256-cbc -in "$SRC_FILE" -out "${SRC_FILE}.enc" -k "$ENCRYPTION_PASSWORD"; then
      >&2 echo "Error encrypting ${SRC_FILE}"
      rm -f "$SRC_FILE"
      return 1
    fi
    rm -f "$SRC_FILE"
    SRC_FILE="${SRC_FILE}.enc"
    DEST_FILE="${DEST_FILE}.enc"
  fi

  OBJ_KEY="${RUN_PREFIX}${DEST_FILE}"
  echo "Uploading backup to s3://${S3_BUCKET}/${OBJ_KEY}"
  if ! cat "$SRC_FILE" | aws $AWS_ARGS s3 cp - "s3://${S3_BUCKET}/${OBJ_KEY}"; then
    rm -f "$SRC_FILE"
    return 1
  fi

  rm -f "$SRC_FILE"
  echo "Backup finished for ${_SRC_PATH}"
  return 0
}

# Iterate over semicolon-separated list (paths may contain spaces)
failures=0
oldIFS="$IFS"
IFS=';'
for _ITEM in $_LIST_RAW; do
  IFS="$oldIFS"
  if ! backup_one "$_ITEM"; then
    failures=$((failures + 1))
    >&2 echo "!! Failure backing up: $_ITEM (continuing...)"
  fi
  IFS=';'
done
IFS="$oldIFS"

# Optional retention (run once for the bucket/prefix root)
if [ "${DELETE_OLDER_THAN}" != "**None**" ] && [ -n "${DELETE_OLDER_THAN:-}" ]; then
  >&2 echo "Checking for files older than ${DELETE_OLDER_THAN}"
  aws $AWS_ARGS s3 ls "s3://${S3_BUCKET}/${S3_PREFIX%/}/" | grep " PRE " -v | while read -r line; do
    fileName=$(echo "$line" | awk '{print $4}')
    created=$(echo "$line" | awk '{print $1" "$2}')
    created=$(date -d "$created" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M" "$created" +%s)
    older_than=$(date -d "$DELETE_OLDER_THAN" +%s 2>/dev/null || true)
    if [ -n "$fileName" ] && [ -n "$created" ] && [ -n "$older_than" ] && [ "$created" -lt "$older_than" ]; then
      >&2 echo "DELETING ${fileName}"
      aws $AWS_ARGS s3 rm "s3://${S3_BUCKET}/${S3_PREFIX%/}/${fileName}" || true
    else
      >&2 echo "${fileName} not older than ${DELETE_OLDER_THAN}"
    fi
  done
fi

if [ "$failures" -gt 0 ]; then
  >&2 echo "Completed with $failures failure(s)."
  exit 1
fi

echo "SQLite backups finished"
>&2 echo "-----"

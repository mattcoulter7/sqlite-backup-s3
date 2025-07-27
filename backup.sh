#! /bin/sh
# Multi-file + directory mode SQLite -> S3 backup (preserves structure under timestamped folder)

set -e
(set -o pipefail) 2>/dev/null || true

log()  { echo "$@"; }
elog() { >&2 echo "$@"; }

elog "-----"

# --- Validate S3 env ---
[ -n "${S3_ACCESS_KEY_ID:-}" ] && [ "${S3_ACCESS_KEY_ID}" != "**None**" ] || { echo "Need S3_ACCESS_KEY_ID"; exit 1; }
[ -n "${S3_SECRET_ACCESS_KEY:-}" ] && [ "${S3_SECRET_ACCESS_KEY}" != "**None**" ] || { echo "Need S3_SECRET_ACCESS_KEY"; exit 1; }
[ -n "${S3_BUCKET:-}" ] && [ "${S3_BUCKET}" != "**None**" ] || { echo "Need S3_BUCKET"; exit 1; }

# At least one source
if [ -z "${SQLITE_DB_PATHS:-}" ] && [ -z "${SQLITE_DB_ROOT_DIR:-}" ]; then
  echo "Set SQLITE_DB_PATHS (semicolon/newline separated) or SQLITE_DB_ROOT_DIR (to scan)."
  exit 1
fi

command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 not installed in image"; exit 1; }

# --- AWS/MinIO config ---
if [ -z "${S3_ENDPOINT:-}" ] || [ "${S3_ENDPOINT}" = "**None**" ]; then
  AWS_ARGS=""
else
  AWS_ARGS="--endpoint-url ${S3_ENDPOINT}"
fi
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${S3_REGION:-}"

# Default compression (to stdout)
[ -n "${COMPRESSION_CMD:-}" ] || COMPRESSION_CMD="gzip -c"
S3_PREFIX="${S3_PREFIX:-}"

# Timestamped folder once per run (use '-' instead of ':' in time)
RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
[ -n "${S3_PREFIX}" ] && RUN_PREFIX="${S3_PREFIX%/}/${RUN_TS}" || RUN_PREFIX="${RUN_TS}"

# --- Helpers ---
is_truthy() {
  v="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [ "$v" = "yes" ] || [ "$v" = "true" ] || [ "$v" = "1" ]
}

# Magic header check; avoids creating DBs accidentally
has_sqlite_header() {
  # First 16 bytes should be: "SQLite format 3\000"
  head -c 16 "$1" 2>/dev/null | grep -q "^SQLite format 3"
}

is_sqlite_file() {
  # Prefer read-only PRAGMA; if not supported or fails, fall back to header check
  if sqlite3 -readonly "$1" "PRAGMA schema_version;" >/dev/null 2>&1; then
    return 0
  fi
  has_sqlite_header "$1"
}

# Optional extension filter
EXTS_RAW="${SQLITE_EXTS:-}"   # unset/empty => no filtering
if [ -n "$EXTS_RAW" ]; then
  EXTS="$(echo "$EXTS_RAW" | tr '[:upper:]' '[:lower:]' | tr ',' ';' | sed 's/;*$//; s/^;*//; s/;;*/;/g; s/ //g')"
else
  EXTS=""
fi

is_ext_ok() {
  f="$1"
  [ -z "$EXTS" ] && return 0
  lower="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"
  OLDIFS="$IFS"; IFS=';'
  for e in $EXTS; do
    IFS="$OLDIFS"
    case "$lower" in
      *."$e") return 0 ;;
    esac
    IFS=';'
  done
  IFS="$OLDIFS"
  return 1
}

# --- Build candidate list ---
CANDIDATES_RAW=""

# Explicit files
if [ -n "${SQLITE_DB_PATHS:-}" ]; then
  _LIST="$(printf '%s' "${SQLITE_DB_PATHS}" | tr '\n' ';' | sed 's/;;*/;/g; s/^;//; s/;$//')"
  CANDIDATES_RAW="$(echo "$_LIST" | tr ';' '\n')"
fi

# Directory scan
add_from_dir() {
  ROOT="$1"; RECURSE="$2"
  [ -d "$ROOT" ] || { elog "Directory not found: $ROOT"; return 0; }
  ROOT_NORM="${ROOT%/}"
  if is_truthy "$RECURSE"; then
    find "$ROOT_NORM" -type f 2>/dev/null
  else
    for f in "$ROOT_NORM"/*; do [ -f "$f" ] && echo "$f"; done
  fi
}

if [ -n "${SQLITE_DB_ROOT_DIR:-}" ]; then
  RECURSE_FLAG="${INCLUDE_SUB_DIR:-${INCLUDE_SUBDIRS:-no}}"
  SCAN_LIST="$(add_from_dir "${SQLITE_DB_ROOT_DIR}" "${RECURSE_FLAG}")"
  if [ -n "$SCAN_LIST" ]; then
    if [ -n "$CANDIDATES_RAW" ]; then
      CANDIDATES_RAW="${CANDIDATES_RAW}
${SCAN_LIST}"
    else
      CANDIDATES_RAW="${SCAN_LIST}"
    fi
  fi
fi

# De-duplicate; split on newlines only
CANDIDATES_SORTED="$(printf '%s\n' "$CANDIDATES_RAW" | sed '/^$/d' | awk '!x[$0]++')"

failures=0

backup_one() {
  SRC_PATH="$1"
  [ -n "$SRC_PATH" ] || return 0
  if [ ! -f "$SRC_PATH" ]; then
    elog "Skipping: not a file -> $SRC_PATH"
    return 1
  fi

  # Optional extension filter
  if ! is_ext_ok "$SRC_PATH"; then
    elog "Skipping (ext filter): $SRC_PATH"
    return 0
  fi

  # Validate actual SQLite (no accidental creation)
  if ! is_sqlite_file "$SRC_PATH"; then
    elog "Skipping (not SQLite): $SRC_PATH"
    return 1
  fi

  DB_BASENAME="$(basename "$SRC_PATH")"
  TMP_FILE="/tmp/${DB_BASENAME}.bak"
  OUT_FILE="$TMP_FILE"
  DEST_KEY_BASE="$DB_BASENAME"

  # Preserve structure relative to root dir if provided
  if [ -n "${SQLITE_DB_ROOT_DIR:-}" ]; then
    ROOT_NORM="${SQLITE_DB_ROOT_DIR%/}"
    case "$SRC_PATH" in
      "$ROOT_NORM"/*) REL="${SRC_PATH#${ROOT_NORM}/}"; DEST_KEY_BASE="$REL" ;;
    esac
  fi

  log "Creating SQLite backup of ${SRC_PATH}..."
  if ! sqlite3 "$SRC_PATH" ".backup '${TMP_FILE}'"; then
    rm -f "$TMP_FILE"
    return 1
  fi

  # Optional compression
  if [ -n "${COMPRESSION_CMD:-}" ]; then
    OUT_FILE="${TMP_FILE}.gz"
    log "Compressing backup (${COMPRESSION_CMD})..."
    # shellcheck disable=SC2086
    if ! $COMPRESSION_CMD < "$TMP_FILE" > "$OUT_FILE"; then
      rm -f "$TMP_FILE"
      return 1
    fi
    rm -f "$TMP_FILE"
    DEST_KEY_BASE="${DEST_KEY_BASE}.gz"
  fi

  # Optional encryption
  if [ "${ENCRYPTION_PASSWORD:-**None**}" != "**None**" ] && [ -n "${ENCRYPTION_PASSWORD:-}" ]; then
    elog "Encrypting ${OUT_FILE}"
    if ! openssl enc -aes-256-cbc -in "$OUT_FILE" -out "${OUT_FILE}.enc" -k "$ENCRYPTION_PASSWORD"; then
      elog "Error encrypting ${OUT_FILE}"
      rm -f "$OUT_FILE"
      return 1
    fi
    rm -f "$OUT_FILE"
    OUT_FILE="${OUT_FILE}.enc"
    DEST_KEY_BASE="${DEST_KEY_BASE}.enc"
  fi

  # Ensure bucket exists (best-effort)
  if ! aws $AWS_ARGS s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
    if [ -n "${S3_REGION:-}" ] && [ "${S3_REGION}" != "us-east-1" ]; then
      aws $AWS_ARGS s3api create-bucket --bucket "$S3_BUCKET" --create-bucket-configuration LocationConstraint="$S3_REGION" >/dev/null 2>&1 || true
    else
      aws $AWS_ARGS s3api create-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1 || true
    fi
  fi

  OBJ_KEY="${RUN_PREFIX%/}/${DEST_KEY_BASE}"
  log "Uploading backup to s3://${S3_BUCKET}/${OBJ_KEY}"
  if ! cat "$OUT_FILE" | aws $AWS_ARGS s3 cp - "s3://${S3_BUCKET}/${OBJ_KEY}"; then
    rm -f "$OUT_FILE"
    return 1
  fi
  rm -f "$OUT_FILE"
  log "Backup finished for ${SRC_PATH}"
  return 0
}

# Iterate without subshell so $failures is preserved
while IFS= read -r item; do
  if ! backup_one "$item"; then
    failures=$((failures + 1))
    elog "!! Failure backing up: $item (continuing...)"
  fi
done <<EOF
$CANDIDATES_SORTED
EOF

# Optional retention
if [ "${DELETE_OLDER_THAN:-**None**}" != "**None**" ] && [ -n "${DELETE_OLDER_THAN:-}" ]; then
  elog "Checking for files older than ${DELETE_OLDER_THAN}"
  aws $AWS_ARGS s3 ls "s3://${S3_BUCKET}/${S3_PREFIX%/}/" --recursive | while read -r line; do
    fileName=$(echo "$line" | awk '{print $4}')
    created=$(echo "$line" | awk '{print $1" "$2}')
    created=$(date -d "$created" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M" "$created" +%s)
    older_than=$(date -d "$DELETE_OLDER_THAN" +%s 2>/dev/null || true)
    if [ -n "$fileName" ] && [ -n "$created" ] && [ -n "$older_than" ] && [ "$created" -lt "$older_than" ]; then
      elog "DELETING ${fileName}"
      aws $AWS_ARGS s3 rm "s3://${S3_BUCKET}/${fileName}" || true
    else
      elog "${fileName} not older than ${DELETE_OLDER_THAN}"
    fi
  done
fi

if [ "${failures:-0}" -gt 0 ]; then
  elog "Completed with ${failures} failure(s)."
  exit 1
fi

log "SQLite backups finished"
elog "-----"

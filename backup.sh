#! /bin/sh
# SQLite -> S3 backup: explicit files and/or directory scan, preserves structure under timestamped folder
# DRY_RUN: set to yes/true/1 to only plan & validate (no backup, no upload, no retention)

set -e
(set -o pipefail) 2>/dev/null || true

log()  { echo "$@"; }
elog() { >&2 echo "$@"; }

elog "-----"

# --- DRY-RUN toggle (explicit only) ---
if printf '%s' "${DRY_RUN:-}" | tr '[:upper:]' '[:lower:]' | grep -Eq '^(yes|true|1)$'; then
  DRY=1
else
  DRY=0
fi

# --- Validate S3 env (only when NOT dry-run) ---
if [ "$DRY" -eq 0 ]; then
  [ -n "${S3_ACCESS_KEY_ID:-}" ]   || { echo "Need S3_ACCESS_KEY_ID"; exit 1; }
  [ -n "${S3_SECRET_ACCESS_KEY:-}" ] || { echo "Need S3_SECRET_ACCESS_KEY"; exit 1; }
  [ -n "${S3_BUCKET:-}" ]          || { echo "Need S3_BUCKET"; exit 1; }
fi

# At least one source
if [ -z "${SQLITE_DB_PATHS:-}" ] && [ -z "${SQLITE_DB_ROOT_DIR:-}" ]; then
  echo "Set SQLITE_DB_PATHS (semicolon/newline separated) or SQLITE_DB_ROOT_DIR (to scan)."
  exit 1
fi

command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 not installed in image"; exit 1; }

# --- AWS/MinIO config ---
if [ -n "${S3_ENDPOINT:-}" ]; then AWS_ARGS="--endpoint-url ${S3_ENDPOINT}"; else AWS_ARGS=""; fi
export AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-}"
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
has_sqlite_header() { head -c 16 "$1" 2>/dev/null | grep -q "^SQLite format 3"; }
# Require BOTH: header AND read-only PRAGMA to succeed
is_sqlite_file() { has_sqlite_header "$1" && sqlite3 -readonly "$1" "PRAGMA schema_version;" >/dev/null 2>&1; }

# Optional extension filter (unset/empty => no filter)
EXTS_RAW="${SQLITE_EXTS:-}"
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
    case "$lower" in *."$e") return 0 ;; esac
    IFS=';'
  done
  IFS="$OLDIFS"
  return 1
}

# Preserve structure helper (relative path under root dir if provided)
rel_key_for() {
  _p="$1"
  if [ -n "${SQLITE_DB_ROOT_DIR:-}" ]; then
    ROOT_NORM="${SQLITE_DB_ROOT_DIR%/}"
    case "$_p" in "$ROOT_NORM"/*) printf '%s' "${_p#${ROOT_NORM}/}"; return 0 ;; esac
  fi
  basename "$_p"
}

# --- Gather candidate files ---
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

# De-duplicate; keep order; split on newlines only
CANDIDATES_SORTED="$(printf '%s\n' "$CANDIDATES_RAW" | sed '/^$/d' | awk '!x[$0]++')"

# --- Plan output ---
echo "Run folder: s3://${S3_BUCKET}/${RUN_PREFIX%/}/"
echo "Sources:"
printf '%s\n' "$CANDIDATES_SORTED" | sed 's/^/  - /'
[ -z "$CANDIDATES_SORTED" ] && { echo "No files found to back up."; exit 0; }
[ "$DRY" -eq 1 ] && echo "DRY-RUN: validation only; no dump/compress/encrypt/upload/retention."

# --- Summary accumulators ---
count_ok=0;      list_ok=""
count_ext=0;     list_ext=""
count_nosql=0;   list_nosql=""
count_missing=0; list_missing=""
count_fail=0;    list_fail=""

backup_one() {
  SRC_PATH="$1"
  [ -n "$SRC_PATH" ] || return 0

  if [ ! -f "$SRC_PATH" ]; then
    echo "SKIP (missing): $SRC_PATH"
    count_missing=$((count_missing+1)); list_missing="${list_missing}${SRC_PATH}\n"
    return 1
  fi

  if ! is_ext_ok "$SRC_PATH"; then
    echo "SKIP (ext filter): $SRC_PATH"
    count_ext=$((count_ext+1)); list_ext="${list_ext}$(rel_key_for "$SRC_PATH")\n"
    return 0
  fi

  if ! is_sqlite_file "$SRC_PATH"; then
    echo "SKIP (not SQLite): $SRC_PATH"
    count_nosql=$((count_nosql+1)); list_nosql="${list_nosql}$(rel_key_for "$SRC_PATH")\n"
    return 1
  fi

  DEST_KEY_BASE="$(rel_key_for "$SRC_PATH")"

  if [ "$DRY" -eq 1 ]; then
    # Predict resulting object name
    _k="$DEST_KEY_BASE"
    [ -n "${COMPRESSION_CMD:-}" ] && _k="${_k}.gz"
    [ -n "${ENCRYPTION_PASSWORD:-}" ] && _k="${_k}.enc"
    echo "→ DRY-RUN: would BACKUP: $SRC_PATH"
    echo "           would Upload -> s3://${S3_BUCKET}/${RUN_PREFIX%/}/${_k}"
    count_ok=$((count_ok+1)); list_ok="${list_ok}${_k}\n"
    return 0
  fi

  # --- Real backup path below ---
  DB_BASENAME="$(basename "$SRC_PATH")"
  TMP_FILE="/tmp/${DB_BASENAME}.bak"
  OUT_FILE="$TMP_FILE"

  echo "→ BACKUP: $SRC_PATH"
  if ! sqlite3 "$SRC_PATH" ".backup '${TMP_FILE}'"; then
    echo "FAIL (sqlite backup): $SRC_PATH"
    count_fail=$((count_fail+1)); list_fail="${list_fail}${DEST_KEY_BASE}\n"
    rm -f "$TMP_FILE"; return 1
  fi

  if [ -n "${COMPRESSION_CMD:-}" ]; then
    OUT_FILE="${TMP_FILE}.gz"
    # shellcheck disable=SC2086
    if ! $COMPRESSION_CMD < "$TMP_FILE" > "$OUT_FILE"; then
      echo "FAIL (compress): $SRC_PATH"
      count_fail=$((count_fail+1)); list_fail="${list_fail}${DEST_KEY_BASE}\n"
      rm -f "$TMP_FILE"; return 1
    fi
    rm -f "$TMP_FILE"
    DEST_KEY_BASE="${DEST_KEY_BASE}.gz"
  fi

  if [ -n "${ENCRYPTION_PASSWORD:-}" ]; then
    if ! openssl enc -aes-256-cbc -in "$OUT_FILE" -out "${OUT_FILE}.enc" -k "$ENCRYPTION_PASSWORD"; then
      echo "FAIL (encrypt): $SRC_PATH"
      count_fail=$((count_fail+1)); list_fail="${list_fail}${DEST_KEY_BASE}\n"
      rm -f "$OUT_FILE"; return 1
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
  echo "   Upload -> s3://${S3_BUCKET}/${OBJ_KEY}"
  if ! cat "$OUT_FILE" | aws $AWS_ARGS s3 cp - "s3://${S3_BUCKET}/${OBJ_KEY}"; then
    echo "FAIL (upload): $SRC_PATH"
    count_fail=$((count_fail+1)); list_fail="${list_fail}${DEST_KEY_BASE}\n"
    rm -f "$OUT_FILE"; return 1
  fi

  rm -f "$OUT_FILE"
  echo "   OK"
  count_ok=$((count_ok+1)); list_ok="${list_ok}${DEST_KEY_BASE}\n"
  return 0
}

# --- Iterate without subshell so counters persist ---
while IFS= read -r item; do
  [ -n "$item" ] || continue
  backup_one "$item" || true
done <<EOF
$CANDIDATES_SORTED
EOF

# --- Optional retention (skip in dry-run) ---
if [ "$DRY" -eq 1 ]; then
  if [ -n "${DELETE_OLDER_THAN:-}" ]; then
    echo "DRY-RUN: would check/delete objects older than ${DELETE_OLDER_THAN} under s3://${S3_BUCKET}/${S3_PREFIX%/}/"
  fi
else
  if [ -n "${DELETE_OLDER_THAN:-}" ]; then
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
fi

# --- Summary ---
[ "$DRY" -eq 1 ] && echo "----- DRY-RUN SUMMARY -----" || echo "----- SUMMARY -----"
echo "Backed up : $count_ok";      [ "$count_ok"      -gt 0 ] && printf "%b" "$list_ok"
echo "Skipped (ext filter): $count_ext"; [ "$count_ext" -gt 0 ] && printf "%b" "$list_ext"
echo "Skipped (not SQLite): $count_nosql"; [ "$count_nosql" -gt 0 ] && printf "%b" "$list_nosql"
echo "Missing   : $count_missing"; [ "$count_missing" -gt 0 ] && printf "%b" "$list_missing"
echo "Failed    : $count_fail";    [ "$count_fail"    -gt 0 ] && printf "%b" "$list_fail"
echo "-------------------"

# --- Exit with correct status ---
if [ "$count_fail" -gt 0 ]; then
  exit 1
fi
exit 0

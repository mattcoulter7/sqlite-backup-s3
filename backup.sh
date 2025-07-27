#! /bin/sh
# SQLite -> S3 backup: explicit files and/or directory scan, preserves structure
# Supports:
# - DRY_RUN: yes|true|1 (plan only)
# - INCLUDE_NON_SQL_ASSETS: yes|true|1 (include non-SQL files under root as "assets")
# - BUNDLE_ARCHIVE: yes|true|1 (default yes) -> upload single archive per run
# - ARCHIVE_FORMAT: tar.gz (default) | zip
# - ARCHIVE_EXT: override suffix (e.g., "gz" to get {ts}.gz while still tar+gz inside)

set -e
(set -o pipefail) 2>/dev/null || true

log()  { echo "$@"; }
elog() { >&2 echo "$@"; }

elog "-----"

to_bool() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | grep -Eq '^(yes|true|1)$'
}

# --- Toggles ---
if to_bool "${DRY_RUN:-}"; then DRY=1; else DRY=0; fi
if to_bool "${INCLUDE_NON_SQL_ASSETS:-}"; then INCLUDE_ASSETS=1; else INCLUDE_ASSETS=0; fi
# Default BUNDLE_ARCHIVE to yes
if [ -z "${BUNDLE_ARCHIVE:-}" ] || to_bool "${BUNDLE_ARCHIVE:-yes}"; then BUNDLE=1; else BUNDLE=0; fi
ARCHIVE_FORMAT="${ARCHIVE_FORMAT:-tar.gz}"   # tar.gz | zip
ARCHIVE_EXT="${ARCHIVE_EXT:-}"               # optional override of suffix

# --- Validate S3 env (only when NOT dry-run) ---
if [ "$DRY" -eq 0 ]; then
  [ -n "${S3_ACCESS_KEY_ID:-}" ]     || { echo "Need S3_ACCESS_KEY_ID"; exit 1; }
  [ -n "${S3_SECRET_ACCESS_KEY:-}" ] || { echo "Need S3_SECRET_ACCESS_KEY"; exit 1; }
  [ -n "${S3_BUCKET:-}" ]            || { echo "Need S3_BUCKET"; exit 1; }
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

# Default compression for per-file mode (ignored in archive mode)
[ -n "${COMPRESSION_CMD:-}" ] || COMPRESSION_CMD="gzip -c"
S3_PREFIX="${S3_PREFIX:-}"

# Timestamped folder once per run (use '-' instead of ':' in time)
RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
[ -n "${S3_PREFIX}" ] && RUN_PREFIX="${S3_PREFIX%/}/${RUN_TS}" || RUN_PREFIX="${RUN_TS}"

# Determine archive suffix
case "$ARCHIVE_FORMAT" in
  zip)    DEF_EXT="zip" ;;
  tar.gz) DEF_EXT="tar.gz" ;;
  *)      echo "Unsupported ARCHIVE_FORMAT: $ARCHIVE_FORMAT (use tar.gz or zip)"; exit 1 ;;
esac
[ -n "$ARCHIVE_EXT" ] && FINAL_EXT="$ARCHIVE_EXT" || FINAL_EXT="$DEF_EXT"
ARCHIVE_KEY_BASENAME="${RUN_TS}.${FINAL_EXT}"   # e.g., 2025-07-27T05-06-00Z.tar.gz
ARCHIVE_S3_KEY=""
STAGE_ROOT=""

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

# Is path under the configured root dir?
is_under_root() {
  [ -n "${SQLITE_DB_ROOT_DIR:-}" ] || return 1
  ROOT_NORM="${SQLITE_DB_ROOT_DIR%/}"
  case "$1" in "$ROOT_NORM"/*) return 0 ;; *) return 1 ;; esac
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

# Ensure bucket exists (best-effort)
ensure_bucket() {
  [ "$DRY" -eq 1 ] && return 0
  if ! aws $AWS_ARGS s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
    if [ -n "${S3_REGION:-}" ] && [ "${S3_REGION}" != "us-east-1" ]; then
      aws $AWS_ARGS s3api create-bucket --bucket "$S3_BUCKET" --create-bucket-configuration LocationConstraint="$S3_REGION" >/dev/null 2>&1 || true
    else
      aws $AWS_ARGS s3api create-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1 || true
    fi
  fi
}

# Upload helper (for per-file or archive)
upload_bytes_to_s3() {
  LOCAL_FILE="$1"
  DEST_KEY="$2"
  ensure_bucket
  if [ "$DRY" -eq 1 ]; then
    echo "   DRY-RUN Upload -> s3://${S3_BUCKET}/${DEST_KEY}"
    return 0
  fi
  echo "   Upload -> s3://${S3_BUCKET}/${DEST_KEY}"
  cat "$LOCAL_FILE" | aws $AWS_ARGS s3 cp - "s3://${S3_BUCKET}/${DEST_KEY}"
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
[ "$BUNDLE" -eq 1 ] && MODE_STR="ARCHIVE (one upload)" || MODE_STR="PER-FILE uploads"
echo "Mode: $MODE_STR"
echo "Run folder: s3://${S3_BUCKET}/${RUN_PREFIX%/}/"
[ "$BUNDLE" -eq 1 ] && echo "Archive format: $ARCHIVE_FORMAT  (suffix: .${FINAL_EXT})"
echo "Sources:"
printf '%s\n' "$CANDIDATES_SORTED" | sed 's/^/  - /'
[ -z "$CANDIDATES_SORTED" ] && { echo "No files found to back up."; exit 0; }
[ "$DRY" -eq 1 ] && echo "DRY-RUN: validation only; no dump/compress/encrypt/upload/retention."
[ "$INCLUDE_ASSETS" -eq 1 ] && echo "ASSETS: non-SQLite/filtered files under root will be included."

# --- Summary accumulators ---
count_ok=0;      list_ok=""
count_ext=0;     list_ext=""
count_nosql=0;   list_nosql=""
count_missing=0; list_missing=""
count_fail=0;    list_fail=""
count_asset=0;   list_asset=""

# If bundling, create staging dir
if [ "$BUNDLE" -eq 1 ]; then
  STAGE_ROOT="$(mktemp -d /tmp/sqlite-stage.XXXXXX)"
  [ -n "$STAGE_ROOT" ] || { echo "Failed to create staging directory"; exit 1; }
  # We will upload to: s3://$S3_BUCKET/${S3_PREFIX%/}/${ARCHIVE_KEY_BASENAME}
  [ -n "${S3_PREFIX}" ] && ARCHIVE_S3_KEY="${S3_PREFIX%/}/${ARCHIVE_KEY_BASENAME}" || ARCHIVE_S3_KEY="${ARCHIVE_KEY_BASENAME}"
fi

# Stage helpers (for archive mode)
stage_put() {
  SRC="$1"            # local source file (dump or asset)
  DEST_REL="$2"       # relative path inside archive (preserve structure)
  DEST_DIR="${STAGE_ROOT%/}/$(dirname "$DEST_REL")"
  mkdir -p "$DEST_DIR"
  cp -f "$SRC" "${STAGE_ROOT%/}/$DEST_REL"
}

dump_sqlite_to_path() {
  SRC_DB="$1"
  DEST_REL="$2"
  TMP_FILE="/tmp/.$(basename "$DEST_REL").bak"
  if ! sqlite3 "$SRC_DB" ".backup '${TMP_FILE}'"; then
    return 1
  fi
  stage_put "$TMP_FILE" "$DEST_REL"
  rm -f "$TMP_FILE"
}

# Asset staging (no per-file compression/encryption in archive mode)
stage_asset() {
  SRC_PATH="$1"
  DEST_REL="$2"
  stage_put "$SRC_PATH" "$DEST_REL"
}

# Per-file upload pipeline (when not bundling) -------------
upload_db_per_file() {
  SRC_DB="$1"
  DEST_BASE="$2"   # relative key base in S3 prefix

  [ "$DRY" -eq 1 ] && {
    k="$DEST_BASE"
    [ -n "${COMPRESSION_CMD:-}" ] && k="${k}.gz"
    [ -n "${ENCRYPTION_PASSWORD:-}" ] && k="${k}.enc"
    echo "→ DRY-RUN: would BACKUP: $SRC_DB"
    echo "           would Upload -> s3://${S3_BUCKET}/${RUN_PREFIX%/}/${k}"
    count_ok=$((count_ok+1)); list_ok="${list_ok}${k}\n"
    return 0
  }

  TMP_FILE="/tmp/$(basename "$DEST_BASE").bak"
  OUT_FILE="$TMP_FILE"
  if ! sqlite3 "$SRC_DB" ".backup '${TMP_FILE}'"; then
    echo "FAIL (sqlite backup): $SRC_DB"
    count_fail=$((count_fail+1)); list_fail="${list_fail}${DEST_BASE}\n"
    rm -f "$TMP_FILE"; return 1
  fi

  if [ -n "${COMPRESSION_CMD:-}" ]; then
    OUT_FILE="${TMP_FILE}.gz"
    # shellcheck disable=SC2086
    if ! $COMPRESSION_CMD < "$TMP_FILE" > "$OUT_FILE"; then
      echo "FAIL (compress): $SRC_DB"
      count_fail=$((count_fail+1)); list_fail="${list_fail}${DEST_BASE}\n"
      rm -f "$TMP_FILE"; return 1
    fi
    rm -f "$TMP_FILE"
    DEST_BASE="${DEST_BASE}.gz"
  fi

  if [ -n "${ENCRYPTION_PASSWORD:-}" ]; then
    if ! openssl enc -aes-256-cbc -in "$OUT_FILE" -out "${OUT_FILE}.enc" -k "$ENCRYPTION_PASSWORD"; then
      echo "FAIL (encrypt): $SRC_DB"
      count_fail=$((count_fail+1)); list_fail="${list_fail}${DEST_BASE}\n"
      rm -f "$OUT_FILE"; return 1
    fi
    rm -f "$OUT_FILE"
    OUT_FILE="${OUT_FILE}.enc"
    DEST_BASE="${DEST_BASE}.enc"
  fi

  OBJ_KEY="${RUN_PREFIX%/}/${DEST_BASE}"
  if upload_bytes_to_s3 "$OUT_FILE" "$OBJ_KEY"; then
    rm -f "$OUT_FILE"
    echo "   OK"
    count_ok=$((count_ok+1)); list_ok="${list_ok}${DEST_BASE}\n"
    return 0
  else
    echo "FAIL (upload): $SRC_DB"
    count_fail=$((count_fail+1)); list_fail="${list_fail}${DEST_BASE}\n"
    rm -f "$OUT_FILE"; return 1
  fi
}

upload_asset_per_file() {
  SRC_PATH="$1"
  DEST_BASE="$2"

  [ "$DRY" -eq 1 ] && {
    k="$DEST_BASE"
    [ -n "${COMPRESSION_CMD:-}" ] && k="${k}.gz"
    [ -n "${ENCRYPTION_PASSWORD:-}" ] && k="${k}.enc"
    echo "ASSET: $SRC_PATH"
    echo "   DRY-RUN -> s3://${S3_BUCKET}/${RUN_PREFIX%/}/${k}"
    count_asset=$((count_asset+1)); list_asset="${list_asset}${k}\n"
    return 0
  }

  TMP_FILE="/tmp/asset.$(basename "$DEST_BASE")"
  OUT_FILE="$TMP_FILE"
  if [ -n "${COMPRESSION_CMD:-}" ]; then
    OUT_FILE="${TMP_FILE}.gz"
    # shellcheck disable=SC2086
    if ! $COMPRESSION_CMD < "$SRC_PATH" > "$OUT_FILE"; then
      echo "FAIL (asset compress): $SRC_PATH"
      count_fail=$((count_fail+1)); list_fail="${list_fail}${DEST_BASE}\n"
      rm -f "$TMP_FILE" "$OUT_FILE" 2>/dev/null || true
      return 1
    fi
    DEST_BASE="${DEST_BASE}.gz"
  else
    cp -f "$SRC_PATH" "$OUT_FILE"
  fi

  if [ -n "${ENCRYPTION_PASSWORD:-}" ]; then
    if ! openssl enc -aes-256-cbc -in "$OUT_FILE" -out "${OUT_FILE}.enc" -k "$ENCRYPTION_PASSWORD"; then
      echo "FAIL (asset encrypt): $SRC_PATH"
      count_fail=$((count_fail+1)); list_fail="${list_fail}${DEST_BASE}\n"
      rm -f "$OUT_FILE" 2>/dev/null || true
      return 1
    fi
    rm -f "$OUT_FILE"
    OUT_FILE="${OUT_FILE}.enc"
    DEST_BASE="${DEST_BASE}.enc"
  fi

  OBJ_KEY="${RUN_PREFIX%/}/${DEST_BASE}"
  if upload_bytes_to_s3 "$OUT_FILE" "$OBJ_KEY"; then
    rm -f "$OUT_FILE" "$TMP_FILE" 2>/dev/null || true
    echo "   ASSET OK"
    count_asset=$((count_asset+1)); list_asset="${list_asset}${DEST_BASE}\n"
    return 0
  else
    echo "FAIL (asset upload): $SRC_PATH"
    count_fail=$((count_fail+1)); list_fail="${list_fail}${DEST_BASE}\n"
    rm -f "$OUT_FILE" "$TMP_FILE" 2>/dev/null || true
    return 1
  fi
}

# --- Main loop over candidates ---
while IFS= read -r SRC_PATH; do
  [ -n "$SRC_PATH" ] || continue

  if [ ! -f "$SRC_PATH" ]; then
    echo "SKIP (missing): $SRC_PATH"
    count_missing=$((count_missing+1)); list_missing="${list_missing}${SRC_PATH}\n"
    continue
  fi

  DEST_REL="$(rel_key_for "$SRC_PATH")"

  # Extension filter
  if ! is_ext_ok "$SRC_PATH"; then
    if [ "$INCLUDE_ASSETS" -eq 1 ] && is_under_root "$SRC_PATH"; then
      echo "ASSET (ext filter): $SRC_PATH"
      if [ "$BUNDLE" -eq 1 ]; then
        if [ "$DRY" -eq 1 ]; then
          echo "   DRY-RUN -> archive add: $DEST_REL"
          count_asset=$((count_asset+1)); list_asset="${list_asset}${DEST_REL}\n"
        else
          stage_asset "$SRC_PATH" "$DEST_REL" || true
          count_asset=$((count_asset+1)); list_asset="${list_asset}${DEST_REL}\n"
        fi
      else
        upload_asset_per_file "$SRC_PATH" "$DEST_REL" || true
      fi
      continue
    fi
    echo "SKIP (ext filter): $SRC_PATH"
    count_ext=$((count_ext+1)); list_ext="${list_ext}${DEST_REL}\n"
    continue
  fi

  # SQLite validation
  if ! is_sqlite_file "$SRC_PATH"; then
    if [ "$INCLUDE_ASSETS" -eq 1 ] && is_under_root "$SRC_PATH"; then
      echo "ASSET (not SQLite): $SRC_PATH"
      if [ "$BUNDLE" -eq 1 ]; then
        if [ "$DRY" -eq 1 ]; then
          echo "   DRY-RUN -> archive add: $DEST_REL"
          count_asset=$((count_asset+1)); list_asset="${list_asset}${DEST_REL}\n"
        else
          stage_asset "$SRC_PATH" "$DEST_REL" || true
          count_asset=$((count_asset+1)); list_asset="${list_asset}${DEST_REL}\n"
        fi
      else
        upload_asset_per_file "$SRC_PATH" "$DEST_REL" || true
      fi
      continue
    fi
    echo "SKIP (not SQLite): $SRC_PATH"
    count_nosql=$((count_nosql+1)); list_nosql="${list_nosql}${DEST_REL}\n"
    continue
  fi

  # --- Valid SQLite DB ---
  if [ "$BUNDLE" -eq 1 ]; then
    if [ "$DRY" -eq 1 ]; then
      echo "→ DRY-RUN: would dump $SRC_PATH -> archive add: $DEST_REL"
      count_ok=$((count_ok+1)); list_ok="${list_ok}${DEST_REL}\n"
    else
      echo "→ DUMP: $SRC_PATH"
      if dump_sqlite_to_path "$SRC_PATH" "$DEST_REL"; then
        count_ok=$((count_ok+1)); list_ok="${list_ok}${DEST_REL}\n"
      else
        echo "FAIL (sqlite backup): $SRC_PATH"
        count_fail=$((count_fail+1)); list_fail="${list_fail}${DEST_REL}\n"
      fi
    fi
  else
    upload_db_per_file "$SRC_PATH" "$DEST_REL" || true
  fi
done <<EOF
$CANDIDATES_SORTED
EOF

# --- If bundling, create archive and upload once ---
if [ "$BUNDLE" -eq 1 ]; then
  if [ "$DRY" -eq 1 ]; then
    echo "DRY-RUN: would create archive from staging and upload once."
    [ -n "${S3_PREFIX}" ] && ARCHIVE_S3_KEY="${S3_PREFIX%/}/${ARCHIVE_KEY_BASENAME}" || ARCHIVE_S3_KEY="${ARCHIVE_KEY_BASENAME}"
    echo "DRY-RUN: would upload -> s3://${S3_BUCKET}/${ARCHIVE_S3_KEY}"
  else
    # If nothing staged, still create an empty archive to reflect run (optional behavior)
    ARCHIVE_FILE="/tmp/sqlite-archive.${FINAL_EXT}"
    case "$ARCHIVE_FORMAT" in
      tar.gz)
        # Create tar.gz
        ( cd "$STAGE_ROOT" && tar -czf "$ARCHIVE_FILE" . ) || { echo "FAIL (archive tar.gz)"; count_fail=$((count_fail+1)); }
        ;;
      zip)
        command -v zip >/dev/null 2>&1 || { echo "zip not installed; set ARCHIVE_FORMAT=tar.gz or add zip to image"; exit 1; }
        ( cd "$STAGE_ROOT" && zip -r -q "$ARCHIVE_FILE" . ) || { echo "FAIL (archive zip)"; count_fail=$((count_fail+1)); }
        ;;
    esac

    # Optional encryption (once for the archive)
    if [ -n "${ENCRYPTION_PASSWORD:-}" ] && [ -f "$ARCHIVE_FILE" ]; then
      if ! openssl enc -aes-256-cbc -in "$ARCHIVE_FILE" -out "${ARCHIVE_FILE}.enc" -k "$ENCRYPTION_PASSWORD"; then
        echo "FAIL (archive encrypt)"
        count_fail=$((count_fail+1))
      else
        rm -f "$ARCHIVE_FILE"
        ARCHIVE_FILE="${ARCHIVE_FILE}.enc"
        ARCHIVE_KEY_BASENAME="${ARCHIVE_KEY_BASENAME}.enc"
      fi
    fi

    [ -n "${S3_PREFIX}" ] && ARCHIVE_S3_KEY="${S3_PREFIX%/}/${ARCHIVE_KEY_BASENAME}" || ARCHIVE_S3_KEY="${ARCHIVE_KEY_BASENAME}"

    if [ -f "$ARCHIVE_FILE" ]; then
      if upload_bytes_to_s3 "$ARCHIVE_FILE" "$ARCHIVE_S3_KEY"; then
        echo "   ARCHIVE OK -> s3://${S3_BUCKET}/${ARCHIVE_S3_KEY}"
      else
        echo "FAIL (archive upload)"
        count_fail=$((count_fail+1))
      fi
      rm -f "$ARCHIVE_FILE"
    fi
  fi

  # Clean staging
  [ -n "$STAGE_ROOT" ] && rm -rf "$STAGE_ROOT" || true
fi

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
if [ "$DRY" -eq 1 ]; then echo "----- DRY-RUN SUMMARY -----"; else echo "----- SUMMARY -----"; fi
echo "Backed up (SQLite) : $count_ok";      [ "$count_ok"      -gt 0 ] && printf "%b" "$list_ok"
echo "Included assets    : $count_asset";   [ "$count_asset"   -gt 0 ] && printf "%b" "$list_asset"
echo "Skipped (ext)      : $count_ext";     [ "$count_ext"     -gt 0 ] && printf "%b" "$list_ext"
echo "Skipped (not SQL)  : $count_nosql";   [ "$count_nosql"   -gt 0 ] && printf "%b" "$list_nosql"
echo "Missing            : $count_missing"; [ "$count_missing" -gt 0 ] && printf "%b" "$list_missing"
echo "Failed             : $count_fail";    [ "$count_fail"    -gt 0 ] && printf "%b" "$list_fail"
if [ "$BUNDLE" -eq 1 ]; then
  echo "Archive object     : ${ARCHIVE_S3_KEY:-<dry-run>}"
fi
echo "-------------------"

# --- Exit with correct status ---
[ "$count_fail" -gt 0 ] && exit 1 || exit 0

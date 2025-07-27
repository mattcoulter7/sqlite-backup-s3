# sqlite-backup-s3

Backup SQLite database files to S3‑compatible storage (supports periodic backups, compression, optional encryption, retention, multi‑file and directory‑based backups, and clear per‑run logging).

> ⚠️ This service **only handles periodic backups** — restore must be done manually.
> 🏷️ **Credits**: Adapted from the excellent [`itbm/postgresql-backup-s3`](https://github.com/itbm/postgresql-backup-s3) repository.

---

## Features

* **Safe, online SQLite backups** using `sqlite3 ".backup"` (consistent even while the app is running).
* **Multiple inputs**:

  * `SQLITE_DB_PATHS` for one or many explicit files (semicolon or newline separated).
  * `SQLITE_DB_ROOT_DIR` to scan a directory (optionally recurse with `INCLUDE_SUB_DIR=yes|true|1`).
  * You may combine both; duplicates are de‑duplicated.
* **Optional extension filter** via `SQLITE_EXTS` (e.g. `sqlite,sqlite3,db`).
  If **unset/empty**, **no filtering by extension** is applied.
* **Strong validation**: A file is backed up **only if** it has the `SQLite format 3` header **and** `sqlite3 -readonly "PRAGMA schema_version;"` succeeds.
* **Timestamped run folder**: Each run uploads into `s3://<bucket>/<prefix>/<YYYY-MM-DDTHH-MM-SSZ>/...`.
* **Directory structure preserved** under `SQLITE_DB_ROOT_DIR` (subpaths are kept in S3).
* **Compression** (default `gzip -c`) and optional **AES‑256‑CBC encryption**.
* **Retention** with `DELETE_OLDER_THAN` (e.g. `"30 days ago"`).
* **Clear logs & summary** per run (listed sources, backed up files, skips, failures).
* **S3 bucket auto‑create** (best‑effort) if missing, useful with MinIO.

---

## Basic Usage

### Backup (single file)

```sh
docker run \
  -e S3_ACCESS_KEY_ID=key \
  -e S3_SECRET_ACCESS_KEY=secret \
  -e S3_BUCKET=my-bucket \
  -e S3_PREFIX=backup \
  -e SQLITE_DB_PATHS=/data/my_database.sqlite \
  -v /your/db/folder:/data:ro \
  your-image:tag
```

This runs:

```sh
sqlite3 /data/my_database.sqlite ".backup '/tmp/backup.sqlite'"
```

The backup is compressed (default `gzip -c`), optionally encrypted, and uploaded to S3.

### Backup (multiple explicit files)

```sh
docker run \
  -e S3_ACCESS_KEY_ID=minio \
  -e S3_SECRET_ACCESS_KEY=miniosecret \
  -e S3_BUCKET=app-backups \
  -e S3_PREFIX=sqlite \
  -e SQLITE_DB_PATHS="/data/db1.sqlite;/data/db2.sqlite3" \
  -e S3_ENDPOINT=http://minio:9000 \
  -v /host/data:/data:ro \
  your-image:tag
```

### Backup (directory scan, recursive)

```sh
docker run \
  -e S3_ACCESS_KEY_ID=minio \
  -e S3_SECRET_ACCESS_KEY=miniosecret \
  -e S3_BUCKET=app-backups \
  -e S3_PREFIX=jellyfin \
  -e SQLITE_DB_ROOT_DIR=/data \
  -e INCLUDE_SUB_DIR=yes \
  # -e SQLITE_EXTS="sqlite,sqlite3,db"   # optional; if unset, no extension filter
  -e S3_ENDPOINT=http://minio:9000 \
  -v /host/jellyfin:/data:ro \
  your-image:tag
```

> **Note:** If you set `SQLITE_EXTS`, it acts as an **allow‑list**. If you leave it **unset/empty**, **no extension filtering** is performed. Either way, non‑SQLite files are **skipped** thanks to the header + `PRAGMA` validation.

---

## Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sqlite-backup
  namespace: backup
spec:
  selector:
    matchLabels:
      app: sqlite-backup
  template:
    metadata:
      labels:
        app: sqlite-backup
    spec:
      containers:
      - name: sqlite-backup
        image: mattcoulter7/sqlite-backup-s3:1.0.0
        imagePullPolicy: IfNotPresent
        env:
        # Run cron inside container at Melbourne time so @daily is local midnight
        - name: TZ
          value: "Australia/Melbourne"

        # --- Choose ONE or BOTH input modes ---

        # (A) Explicit files (newline or semicolon separated)
        - name: SQLITE_DB_PATHS
          value: |
            /mnt/data/jellyfin.db
            /mnt/data/library.db

        # (B) Directory scan (preserves structure)
        # - name: SQLITE_DB_ROOT_DIR
        #   value: /mnt/data
        # - name: INCLUDE_SUB_DIR
        #   value: "yes"                       # yes|true|1 to recurse
        # - name: SQLITE_EXTS
        #   value: "sqlite,sqlite3,db"         # optional; unset => no ext filtering

        # --- S3 / MinIO destination ---
        - name: S3_ACCESS_KEY_ID
          value: "minio"
        - name: S3_SECRET_ACCESS_KEY
          value: "miniosecret"
        - name: S3_BUCKET
          value: "app-backups"
        - name: S3_ENDPOINT
          value: "http://minio.default.svc.cluster.local:9000"
        - name: S3_PREFIX
          value: "jellyfin"
        - name: S3_S3V4
          value: "yes"
        # - name: AWS_S3_FORCE_PATH_STYLE       # often helpful with MinIO
        #   value: "true"

        # --- Schedule & retention ---
        - name: SCHEDULE
          value: "@daily"
        - name: DELETE_OLDER_THAN
          value: "30 days ago"

        # --- Optional encryption / compression ---
        # - name: ENCRYPTION_PASSWORD
        #   value: "mysupersecret"
        # - name: COMPRESSION_CMD               # default "gzip -c"; set "" to disable
        #   value: "gzip -c"

        volumeMounts:
        - name: sqlite-data
          mountPath: /mnt/data
          readOnly: true
      volumes:
      - name: sqlite-data
        persistentVolumeClaim:
          claimName: jellyfin-config
```

---

## Environment Variables

| Variable                  | Default       | Required | Description                                                                                                                  |
| ------------------------- | ------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `SQLITE_DB_PATHS`         |               | ✅\*      | **One or many** absolute file paths; semicolon **`;`** or newline‑separated. *(Required unless using `SQLITE_DB_ROOT_DIR`.)* |
| `SQLITE_DB_ROOT_DIR`      |               | ✅\*      | Root directory to scan for files. *(Required unless using `SQLITE_DB_PATHS`.)*                                               |
| `INCLUDE_SUB_DIR`         | `no`          |          | If `yes`/`true`/`1`, scans subdirectories recursively.                                                                       |
| `SQLITE_EXTS`             | *(unset)*     |          | Optional allow‑list of extensions, e.g. `sqlite,sqlite3,db`. **If unset/empty, no extension filter** is applied.             |
| `S3_ACCESS_KEY_ID`        |               | ✅        | S3 access key.                                                                                                               |
| `S3_SECRET_ACCESS_KEY`    |               | ✅        | S3 secret key.                                                                                                               |
| `S3_BUCKET`               |               | ✅        | Destination bucket. (Bucket will be auto‑created if missing, best‑effort.)                                                   |
| `S3_PREFIX`               | `backup`      |          | Key prefix/folder in the bucket. Each run adds a timestamp folder under this path.                                           |
| `S3_ENDPOINT`             |               |          | Custom endpoint for S3‑compatible APIs (e.g. MinIO).                                                                         |
| `S3_REGION`               | `us-west-1`   |          | S3 region (used for bucket creation when needed).                                                                            |
| `S3_S3V4`                 | `no`          |          | Set to `yes` to enable AWS Signature Version 4 (often used with MinIO).                                                      |
| `AWS_S3_FORCE_PATH_STYLE` | *(unset)*     |          | Set to `true` for path‑style addressing with MinIO (helps avoid DNS‑style issues).                                           |
| `SCHEDULE`                |               | ✅        | Cron schedule, e.g. `@daily`, `0 2 * * *`. Uses [robfig/cron](https://pkg.go.dev/github.com/robfig/cron) syntax.             |
| `ENCRYPTION_PASSWORD`     |               |          | If set, encrypts the uploaded object with AES‑256‑CBC (suffix `.enc`).                                                       |
| `DELETE_OLDER_THAN`       |               |          | Deletes older objects under `S3_PREFIX` (e.g. `"14 days ago"`).                                                              |
| `COMPRESSION_CMD`         | `gzip -c`     |          | Compression command; set to empty string `""` to disable compression.                                                        |
| `TZ`                      | *(container)* |          | Timezone used by the cron runner (e.g., `"Australia/Melbourne"`).                                                            |

> **Validation behavior:** A file is considered SQLite only if it has the `SQLite format 3\0` header **and** `sqlite3 -readonly "PRAGMA schema_version;"` succeeds. Non‑SQLite files are logged as “Skipped (not SQLite)”.

---

## What gets uploaded (structure)

Each run uses a **timestamped** folder and preserves relative paths under `SQLITE_DB_ROOT_DIR`:

```
s3://<bucket>/<S3_PREFIX>/<YYYY-MM-DDTHH-MM-SSZ>/<relative/path/or/filename>[.gz][.enc]
```

**Examples**

```
s3://app-backups/sqlite/2025-07-27T05-06-00Z/test-1.sqlite.gz
s3://app-backups/sqlite/2025-07-27T05-06-00Z/sub-2/test-4.db.gz
```

---

## Periodic Backups

Set `SCHEDULE="@daily"` for one run per day (midnight by container TZ), or any cron expression supported by robfig/cron.

---

## Retention Policy

Optionally clean up older objects:

```sh
-e DELETE_OLDER_THAN="30 days ago"
```

> ⚠️ **Warning:** this deletes **any** objects under the chosen `S3_PREFIX`.

---

## Encryption

Enable AES‑256‑CBC encryption at rest:

```sh
-e ENCRYPTION_PASSWORD="mysupersecret"
```

Objects are stored with `.enc` suffix. You can decrypt manually:

```sh
openssl aes-256-cbc -d -in backup.sqlite.gz.enc -out backup.sqlite.gz
```

---

## Compression

Default compression is `gzip -c` (single‑threaded).
You can switch to another compressor or disable it:

```sh
# Use xz (smaller, slower)
-e COMPRESSION_CMD="xz -c"

# Disable compression
-e COMPRESSION_CMD=""
```

---

## Logging & Exit Codes

Each run prints:

* **Run folder** (S3 path),
* **Sources** (candidate list),
* Per‑file actions: `→ BACKUP`, `SKIP (ext filter)`, `SKIP (not SQLite)`, etc.,
* Final **SUMMARY** with counts and lists.

Example:

```
Run folder: s3://app-backups/sqlite/2025-07-27T05-06-00Z/
Sources:
  - /data/sub-2/test-4.db
  - /data/test-1.sqlite
  - /data/test-3.sqlite3
  - /data/test-2.sql
  - /data/this_is_not_a_database.db

→ BACKUP: /data/sub-2/test-4.db
   Upload -> s3://app-backups/sqlite/2025-07-27T05-06-00Z/sub-2/test-4.db.gz
   OK
→ BACKUP: /data/test-1.sqlite
   Upload -> s3://app-backups/sqlite/2025-07-27T05-06-00Z/test-1.sqlite.gz
   OK
→ BACKUP: /data/test-3.sqlite3
   Upload -> s3://app-backups/sqlite/2025-07-27T05-06-00Z/test-3.sqlite3.gz
   OK
SKIP (ext filter): /data/test-2.sql
SKIP (not SQLite): /data/this_is_not_a_database.db

----- SUMMARY -----
Backed up : 3
sub-2/test-4.db.gz
test-1.sqlite.gz
test-3.sqlite3.gz
Skipped (ext filter): 1
test-2.sql
Skipped (not SQLite): 1
this_is_not_a_database.db
Missing   : 0
Failed    : 0
-------------------
```

* Exit code is **0** when there are no failed uploads, **1** if any file failed.

---

## Local Test

```bash
cd test
docker compose up --build
```

If the bucket doesn’t exist yet, create it via MinIO console (e.g., `http://localhost:9001`) or add a small init job. The container also tries to **auto‑create** the bucket (best‑effort).

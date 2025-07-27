# sqlite-backup-s3

Backup SQLite database files to S3‑compatible storage (supports periodic backups, compression, optional encryption, retention, multi‑file and directory‑based backups, **dry‑run**, and clear per‑run logging).

> ⚠️ This service **only handles periodic backups** — restore must be done manually.
> 🏷️ **Credits**: Adapted from the excellent [`itbm/postgresql-backup-s3`](https://github.com/itbm/postgresql-backup-s3) repository.

---

## Features

* **Safe, online SQLite backups** via `sqlite3 ".backup"` (consistent even while the app is running).
* **Multiple input modes**:

  * `SQLITE_DB_PATHS` for one or many explicit files (semicolon `;` or newline‑separated).
  * `SQLITE_DB_ROOT_DIR` to scan a directory (recurse with `INCLUDE_SUB_DIR=yes|true|1`).
  * You may combine both; duplicates are de‑duplicated.
* **Optional extension filter** (`SQLITE_EXTS` like `sqlite,sqlite3,db`).
  If **unset/empty**, **no extension filtering** is performed.
* **Strong validation**: file must have the `SQLite format 3` header **and** succeed `sqlite3 -readonly "PRAGMA schema_version;"`.
* **Timestamped run folder** per execution:
  `s3://<bucket>/<prefix>/<YYYY-MM-DDTHH-MM-SSZ>/...`
* **Directory structure preserved** under `SQLITE_DB_ROOT_DIR`.
* **Compression** (default `gzip -c`) and optional **AES‑256‑CBC** encryption.
* **Retention** with `DELETE_OLDER_THAN` (e.g. `"30 days ago"`).
* **Clear plan & summary logs**: shows sources, actions (BACKUP/SKIP), and counts.
* **Bucket auto‑create** (best‑effort) for convenience with MinIO.
* **DRY RUN** mode (`DRY_RUN=yes`) to preview what would happen — no dump, no upload, no retention.

---

## Basic Usage

### Single file

```sh
docker run \
  -e S3_ACCESS_KEY_ID=key \
  -e S3_SECRET_ACCESS_KEY=secret \
  -e S3_BUCKET=my-bucket \
  -e S3_PREFIX=backup \
  -e SQLITE_DB_PATHS=/data/my_database.sqlite \
  -v /your/db/folder:/data:ro \
  mattcoulter7/sqlite-backup-s3:1.0.4
```

This performs:

```sh
sqlite3 /data/my_database.sqlite ".backup '/tmp/backup.sqlite'"
```

Then compresses (default `gzip`), optionally encrypts, and uploads to S3.

### Multiple explicit files

```sh
docker run \
  -e S3_ACCESS_KEY_ID=minio \
  -e S3_SECRET_ACCESS_KEY=miniosecret \
  -e S3_BUCKET=app-backups \
  -e S3_PREFIX=sqlite \
  -e SQLITE_DB_PATHS="/data/db1.sqlite;/data/db2.sqlite3" \
  -e S3_ENDPOINT=http://minio:9000 \
  -v /host/data:/data:ro \
  mattcoulter7/sqlite-backup-s3:1.0.4
```

### Directory scan (recursive)

```sh
docker run \
  -e S3_ACCESS_KEY_ID=minio \
  -e S3_SECRET_ACCESS_KEY=miniosecret \
  -e S3_BUCKET=app-backups \
  -e S3_PREFIX=jellyfin \
  -e SQLITE_DB_ROOT_DIR=/data \
  -e INCLUDE_SUB_DIR=yes \
  # -e SQLITE_EXTS="sqlite,sqlite3,db"  # optional; unset => no extension filtering
  -e S3_ENDPOINT=http://minio:9000 \
  -v /host/jellyfin:/data:ro \
  mattcoulter7/sqlite-backup-s3:1.0.4
```

> **Note:** Even if you disable the extension filter, non‑SQLite files are still **skipped** thanks to header + `PRAGMA` validation.

### Dry run (no changes)

Preview what would be backed up and where — no dump, no upload, no retention:

```sh
docker run \
  -e DRY_RUN=yes \
  -e SQLITE_DB_ROOT_DIR=/data \
  -e INCLUDE_SUB_DIR=yes \
  -e S3_BUCKET=app-backups -e S3_PREFIX=sqlite \
  -v /host/data:/data:ro \
  mattcoulter7/sqlite-backup-s3:1.0.4
```

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
        image: mattcoulter7/sqlite-backup-s3:1.1.0
        imagePullPolicy: IfNotPresent
        env:
        # Run cron at Melbourne time so @daily is local midnight
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
        #   value: "yes"                     # yes|true|1 to recurse
        # - name: SQLITE_EXTS
        #   value: "sqlite,sqlite3,db"       # optional; unset => no ext filtering

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
        # - name: AWS_S3_FORCE_PATH_STYLE    # often helpful with MinIO
        #   value: "true"

        # --- Schedule & retention ---
        - name: SCHEDULE
          value: "@daily"
        - name: DELETE_OLDER_THAN
          value: "30 days ago"

        # --- Optional encryption / compression / dry-run ---
        # - name: ENCRYPTION_PASSWORD
        #   value: "mysupersecret"
        # - name: COMPRESSION_CMD            # default "gzip -c"; set "" to disable
        #   value: "gzip -c"
        # - name: DRY_RUN
        #   value: "no"

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

| Variable                  | Default       | Required | Description                                                                                                                    |
| ------------------------- | ------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `SQLITE_DB_PATHS`         |               | ✅\*      | **One or many** absolute file paths; semicolon **`;`** or newline‑separated. *(Required unless `SQLITE_DB_ROOT_DIR` is used.)* |
| `SQLITE_DB_ROOT_DIR`      |               | ✅\*      | Root directory to scan for files. *(Required unless `SQLITE_DB_PATHS` is used.)*                                               |
| `INCLUDE_SUB_DIR`         | `no`          |          | If `yes`/`true`/`1`, recurses into subdirectories.                                                                             |
| `SQLITE_EXTS`             | *(unset)*     |          | Optional allow‑list of extensions (e.g. `sqlite,sqlite3,db`). If unset/empty, **no extension filter** is applied.              |
| `DRY_RUN`                 | `no`          |          | If `yes`/`true`/`1`, prints plan + validation only (no dump/compress/encrypt/upload/retention).                                |
| `S3_ACCESS_KEY_ID`        |               | ✅†       | S3 access key. †Required for real runs (not required in dry‑run).                                                              |
| `S3_SECRET_ACCESS_KEY`    |               | ✅†       | S3 secret key. †Required for real runs (not required in dry‑run).                                                              |
| `S3_BUCKET`               |               | ✅†       | Destination bucket. †Required for real runs; auto‑created best‑effort.                                                         |
| `S3_PREFIX`               | `backup`      |          | Key prefix/folder in the bucket. Each run uses a timestamp folder under this path.                                             |
| `S3_ENDPOINT`             |               |          | Custom endpoint for S3‑compatible APIs (e.g. MinIO).                                                                           |
| `S3_REGION`               | `us-west-1`   |          | S3 region (used when creating buckets if needed).                                                                              |
| `S3_S3V4`                 | `no`          |          | Set to `yes` for AWS Signature Version 4 (often with MinIO).                                                                   |
| `AWS_S3_FORCE_PATH_STYLE` | *(unset)*     |          | Set to `true` for path‑style addressing (helps avoid DNS‑style issues on MinIO).                                               |
| `SCHEDULE`                |               | ✅        | Cron schedule, e.g. `@daily`, `0 2 * * *`. Uses [robfig/cron](https://pkg.go.dev/github.com/robfig/cron).                      |
| `ENCRYPTION_PASSWORD`     |               |          | If set, encrypts uploaded object with AES‑256‑CBC (suffix `.enc`).                                                             |
| `DELETE_OLDER_THAN`       |               |          | Deletes older objects under `S3_PREFIX` (e.g. `"14 days ago"`).                                                                |
| `COMPRESSION_CMD`         | `gzip -c`     |          | Compression command; set to empty string `""` to disable compression.                                                          |
| `TZ`                      | *(container)* |          | Timezone used by the cron runner (e.g., `"Australia/Melbourne"`).                                                              |

> **Validation:** A file is considered SQLite only if it has the `SQLite format 3\0` header **and** `sqlite3 -readonly "PRAGMA schema_version;"` succeeds. Non‑SQLite files are logged as “Skipped (not SQLite)”.

---

## What gets uploaded

Each run uses a **timestamped** folder and preserves relative paths under `SQLITE_DB_ROOT_DIR`:

```
s3://<bucket>/<S3_PREFIX>/<YYYY-MM-DDTHH-MM-SSZ>/<relative/path/or/filename>[.gz][.enc]
```

**Examples:**

```
s3://app-backups/sqlite/2025-07-27T05-06-00Z/test-1.sqlite.gz
s3://app-backups/sqlite/2025-07-27T05-06-00Z/sub-2/test-4.db.gz
```

---

## Periodic Backups

Set `SCHEDULE="@daily"` for one run per day (midnight by container timezone), or any cron expression supported by robfig/cron.

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

Objects are stored with `.enc` suffix. Decrypt manually:

```sh
openssl aes-256-cbc -d -in backup.sqlite.gz.enc -out backup.sqlite.gz
```

---

## Compression

Default is `gzip -c`. You can change or disable it:

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

Exit code is **0** when there are no failed uploads, **1** if any file failed.
In **DRY\_RUN**, exit code is **0** unless a validation step itself fails.

---

## Local Test

```bash
cd test
docker compose up --build
```

If the bucket doesn’t exist yet, create it via MinIO console (e.g., `http://localhost:9001`) or rely on the container’s best‑effort **auto‑create**.

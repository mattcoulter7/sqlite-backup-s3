# sqlite-backup-s3

Backup a SQLite database file to S3-compatible storage (supports periodic backups, compression, encryption, and retention policies).

> ⚠️ This service **only handles periodic backups** — restore must be done manually.
>
> 🏷️ **Credits**: This script is adapted from the excellent [`itbm/postgresql-backup-s3`](https://github.com/itbm/postgresql-backup-s3) repository.

---

## Basic Usage

### Backup

```sh
docker run \
  -e S3_ACCESS_KEY_ID=key \
  -e S3_SECRET_ACCESS_KEY=secret \
  -e S3_BUCKET=my-bucket \
  -e S3_PREFIX=backup \
  -e SQLITE_DB_PATH=/data/my_database.sq3 \
  -v /your/db/folder:/data \
  your-image:tag
```

This will create a safe `.backup` of the SQLite database using:

```sh
sqlite3 /data/my_database.sq3 ".backup '/tmp/backup_timestamped.sq3'"
```

The backup will be compressed (default: `gzip`), optionally encrypted, and uploaded to your S3-compatible bucket.

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
        image: mattcouulter7/sqlite-backup-s3
        imagePullPolicy: Always
        env:
        - name: SQLITE_DB_PATH
          value: /mnt/data/jellyfin.db
        - name: S3_ACCESS_KEY_ID
          value: minio
        - name: S3_SECRET_ACCESS_KEY
          value: miniosecret
        - name: S3_BUCKET
          value: app-backups
        - name: S3_PREFIX
          value: jellyfin
        - name: S3_ENDPOINT
          value: http://minio.default.svc.cluster.local:9000
        - name: SCHEDULE
          value: "@daily"
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

| Variable               | Default     | Required | Description                                                        |
| ---------------------- | ----------- | -------- | ------------------------------------------------------------------ |
| `SQLITE_DB_PATH`       |             | ✅        | Full path to the SQLite `.db` file to back up                      |
| `S3_ACCESS_KEY_ID`     |             | ✅        | Your S3 access key                                                 |
| `S3_SECRET_ACCESS_KEY` |             | ✅        | Your S3 secret key                                                 |
| `S3_BUCKET`            |             | ✅        | Destination bucket                                                 |
| `S3_PREFIX`            | `backup`    |          | Key prefix/folder inside the bucket                                |
| `S3_ENDPOINT`          |             |          | Custom endpoint for S3-compatible APIs (e.g. MinIO)                |
| `S3_REGION`            | `us-west-1` |          | Region for AWS                                                     |
| `S3_S3V4`              | `no`        |          | Set to `yes` for S3 Signature Version 4 (e.g. MinIO)               |
| `SCHEDULE`             |             | ✅        | Cron format schedule (e.g. `@daily`, `0 2 * * *`)                  |
| `ENCRYPTION_PASSWORD`  |             |          | If set, encrypts backup with AES-256-CBC                           |
| `DELETE_OLDER_THAN`    |             |          | Delete backups older than this duration (e.g. `14 days ago`)       |
| `COMPRESSION_CMD`      | `gzip -c`   |          | Compression tool (e.g. `xz -c`, or leave empty for no compression) |

---

## Periodic Backups

The container will automatically run the backup at the schedule set in `SCHEDULE`, e.g.:

```sh
-e SCHEDULE="@daily"
```

Uses [robfig/cron](https://pkg.go.dev/github.com/robfig/cron) format.

---

## Retention Policy

Optionally clean up older backups:

```sh
-e DELETE_OLDER_THAN="30 days ago"
```

⚠️ **Warning**: this deletes *any* object in the specified `S3_PREFIX`.

---

## Encryption

You can encrypt your backups with:

```sh
-e ENCRYPTION_PASSWORD="mysupersecret"
```

They’ll be saved with `.enc` suffix. Decrypt manually with:

```sh
openssl aes-256-cbc -d -in backup.sqlite.gz.enc -out backup.sqlite.gz
```

---

## Compression

By default, backups are compressed with `gzip -c`.

You can override this with:

```sh
-e COMPRESSION_CMD="xz -c"
```

To disable compression:

```sh
-e COMPRESSION_CMD=""
```

---

## Local Test

```shell
cd test
docker compose up --build
```


The first time it runs, you should see an output like

```shell
sqlite-backup-1  | [2025-07-27 14:01:50] INFO: Cron job scheduled: * * * * *
sqlite-backup-1  | [2025-07-27 14:01:50] INFO: Command to run: /bin/sh backup.sh
sqlite-backup-1  | [2025-07-27 14:02:00] INFO: Executing command: /bin/sh [backup.sh]                                                                                             
sqlite-backup-1  | [2025-07-27 14:02:00] STDERR: -----
sqlite-backup-1  | [2025-07-27 14:02:00] STDOUT: Creating SQLite backup of /data/test.sqlite...                                                                                   
sqlite-backup-1  | [2025-07-27 14:02:00] STDOUT: Compressing backup (gzip -c)...                                                                                                  
sqlite-backup-1  | [2025-07-27 14:02:00] STDOUT: Uploading backup to s3://app-backups/sqlite/test_2025-07-27T04:02:00Z.sqlite.gz
sqlite-backup-1  | [2025-07-27 14:02:00] STDERR: upload failed: - to s3://app-backups/sqlite/test_2025-07-27T04:02:00Z.sqlite.gz An error occurred (NoSuchBucket) when calling the PutObject operation: The specified bucket does not exist
```

Manually create the bucket `app-backups` in `localhost:9001`

On the next run you should see

```
sqlite-backup-1  | [2025-07-27 14:10:22] INFO: Cron job scheduled: * * * * *
sqlite-backup-1  | [2025-07-27 14:10:22] INFO: Command to run: /bin/sh backup.sh
sqlite-backup-1  | [2025-07-27 14:11:00] INFO: Executing command: /bin/sh [backup.sh]
sqlite-backup-1  | [2025-07-27 14:11:00] STDERR: -----
sqlite-backup-1  | [2025-07-27 14:11:00] STDOUT: Creating SQLite backup of /data/test.sqlite...                                                                                   
sqlite-backup-1  | [2025-07-27 14:11:00] STDOUT: Compressing backup (gzip -c)...                                                                                                  
sqlite-backup-1  | [2025-07-27 14:11:00] STDOUT: Uploading backup to s3://app-backups/sqlite/test_2025-07-27T04:11:00Z.sqlite.gz
sqlite-backup-1  | [2025-07-27 14:11:00] STDERR: -----                                                                                                                            
sqlite-backup-1  | [2025-07-27 14:11:00] STDOUT: SQLite backup finished
sqlite-backup-1  | [2025-07-27 14:11:00] INFO: Command finished successfully
```
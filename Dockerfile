# --- build the tiny cron runner ---
FROM alpine:3.22 AS build
WORKDIR /app

RUN apk add --no-cache go

COPY main.go /app/main.go

# (Optional) rename the module path to sqlite-backup-s3
RUN go mod init github.com/mattcoulter7/sqlite-backup-s3 \
    && go get github.com/robfig/cron/v3 \
    && go build -o out/go-cron

# --- runtime image ---
FROM alpine:3.22
LABEL maintainer="mattcoulter7"

# sqlite3 CLI for .backup, aws-cli for S3, openssl for optional encryption, pigz for faster gzip, tzdata for cron TZ if you set TZ
RUN apk add --no-cache coreutils sqlite aws-cli openssl pigz tzdata \
    && rm -rf /var/cache/apk/*

COPY --from=build /app/out/go-cron /usr/local/bin/go-cron

# ---- Environment (SQLite + S3) ----
# Sources (choose one or both)
ENV SQLITE_DB_PATHS ""
ENV SQLITE_DB_ROOT_DIR ""
ENV INCLUDE_SUB_DIR "no"
ENV SQLITE_EXTS ""
ENV DRY_RUN "no"

# S3 / MinIO
ENV S3_ACCESS_KEY_ID ""
ENV S3_SECRET_ACCESS_KEY ""
ENV S3_BUCKET ""
ENV S3_REGION "us-west-1"
ENV S3_PREFIX "backup"
ENV S3_ENDPOINT ""
ENV S3_S3V4 "no"
ENV AWS_S3_FORCE_PATH_STYLE ""

# Scheduling / security / retention
ENV SCHEDULE ""
ENV ENCRYPTION_PASSWORD ""
ENV DELETE_OLDER_THAN ""

# Compression (default matches script expectation: writes to stdout)
ENV COMPRESSION_CMD "gzip -c"

# Timezone for cron inside container (optional)
ENV TZ "UTC"

# Scripts
ADD run.sh run.sh
ADD backup.sh backup.sh
RUN sed -i 's/\r$//' run.sh backup.sh
RUN chmod +x run.sh backup.sh

CMD ["sh", "run.sh"]

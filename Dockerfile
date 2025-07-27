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
ENV SQLITE_DB_PATH **None**
ENV S3_ACCESS_KEY_ID **None**
ENV S3_SECRET_ACCESS_KEY **None**
ENV S3_BUCKET **None**
ENV S3_REGION us-west-1
ENV S3_PREFIX backup
ENV S3_ENDPOINT **None**
ENV S3_S3V4 no
ENV SCHEDULE **None**
ENV ENCRYPTION_PASSWORD **None**
ENV DELETE_OLDER_THAN **None**
# Default matches the script expectation (writes to stdout)
ENV COMPRESSION_CMD 'gzip -c'

# Scripts
ADD run.sh run.sh
ADD backup.sh backup.sh
RUN sed -i 's/\r$//' run.sh backup.sh
RUN chmod +x run.sh backup.sh

CMD ["sh", "run.sh"]

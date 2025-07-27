docker build -f Dockerfile -t mattcoulter7/sqlite-backup-s3:latest -t mattcoulter7/sqlite-backup-s3:1.0.4 .
docker login
docker push mattcoulter7/sqlite-backup-s3:1.0.4
docker push mattcoulter7/sqlite-backup-s3:latest

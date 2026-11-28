# Image of the backup Profile: restic + rclone + sqlite3, scheduled by supercronic; jq and
# openssl build and sign the failure event published to the hub.
# Built locally by `docker compose build`; Renovate bumps the Alpine base.
FROM alpine:3.24

RUN apk add --no-cache bash ca-certificates coreutils curl findutils jq openssl rclone restic sqlite supercronic tzdata

COPY media-backup.sh /usr/local/bin/media-backup

ENTRYPOINT ["media-backup"]
CMD ["schedule"]

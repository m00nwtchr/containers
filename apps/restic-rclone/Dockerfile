ARG VERSION
ARG RESTIC_VERSION=0.18.0
ARG RCLONE_VERSION=1.71.0

FROM ghcr.io/restic/restic:${RESTIC_VERSION} as restic
FROM docker.io/rclone/rclone:${RCLONE_VERSION} as rclone

FROM scratch

COPY --from=restic /usr/bin/restic /restic
COPY --from=rclone /usr/local/bin/rclone /rclone
ENV PATH="/usr/bin"

FROM alpine:3.19

RUN apk add --no-cache \
    borgbackup \
    openssh-client \
    bash \
    coreutils \
    tzdata \
    msmtp \
    ca-certificates

COPY backup.sh     /usr/local/bin/backup.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Pinned Alpine (this is the one image not pinned via .env). 3.24.2
# verified 2026-10-18 to publish a linux/arm/v7 manifest.
ARG ALPINE_TAG=3.24.2
FROM alpine:${ALPINE_TAG}
RUN apk add --no-cache bash openssh-client
COPY crontab /etc/crontabs/root
ENTRYPOINT ["crond", "-f", "-d", "8"]

# syntax=docker/dockerfile:1.7
FROM docker.io/library/alpine:3.23.5@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

ARG IMAGE_VERSION=development
ARG SOURCE_REVISION=local
LABEL org.opencontainers.image.title="Noodle Computer Shell" \
      org.opencontainers.image.description="Minimal Alpine workspace for Noodle Computer" \
      org.opencontainers.image.source="https://github.com/pdparchitect/noodle" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${SOURCE_REVISION}"

RUN apk add --no-cache sudo \
    && addgroup -g 1000 agent \
    && adduser -D -u 1000 -G agent -h /home/agent -s /bin/ash agent \
    && mkdir -p /workspace /etc/sudoers.d \
    && chown agent:agent /workspace \
    && printf 'agent ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/agent \
    && chmod 0440 /etc/sudoers.d/agent \
    && visudo -cf /etc/sudoers
WORKDIR /workspace
ENV HOME=/home/agent TERM=xterm-256color
ENV ENV=/etc/noodle/interactive-shell.sh
COPY shared/noodle-welcome /usr/local/bin/noodle-welcome
COPY shared/interactive-shell.sh /etc/noodle/interactive-shell.sh
RUN chmod 0755 /usr/local/bin/noodle-welcome \
    && ln -s /etc/noodle/interactive-shell.sh /etc/profile.d/noodle-welcome.sh
COPY shared/verify.sh /usr/local/lib/noodle-image-check
RUN sh /usr/local/lib/noodle-image-check shell
USER agent
CMD ["/bin/sh", "-i"]

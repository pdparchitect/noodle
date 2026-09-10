# syntax=docker/dockerfile:1.7
# Layer only our product defaults over the same tested Launcher substrate.
FROM ghcr.io/pdparchitect/launcher-image-base-desktop@sha256:1c6eeebbdfbbd00426a60e8284b9ffa9ec0619166efeeca179ac5eb132f1f061

USER root
ARG IMAGE_VERSION=development
ARG SOURCE_REVISION=local
LABEL org.opencontainers.image.title="Noodle Computer Desktop" \
      org.opencontainers.image.description="Launcher-based desktop with Noodle wallpaper and terminal defaults" \
      org.opencontainers.image.source="https://github.com/pdparchitect/noodle" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${SOURCE_REVISION}"

COPY desktop/overlay/ /
COPY shared/verify.sh /usr/local/lib/noodle-image-check
# Noodle owns authenticated VNC startup. Do not expose the inherited,
# unauthenticated helper or start a desktop merely by running this image.
RUN chmod -x /usr/local/bin/desktop-bridge && sh /usr/local/lib/noodle-image-check desktop
ENV DESKTOP_TITLE="Noodle Computer" \
    DESKTOP_WALLPAPER=/usr/share/backgrounds/desktop-wallpaper.svg
WORKDIR /workspace
HEALTHCHECK NONE
ENTRYPOINT ["/bin/sh"]
CMD ["-i"]

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
# The session hook owns Picom; disable its generic XDG autostart duplicate.
RUN chmod 0755 /etc/desktop/session.d/noodle-compositor \
    && printf '\nHidden=true\n' >> /etc/xdg/autostart/picom.desktop
COPY shared/noodle-welcome /usr/local/bin/noodle-welcome
COPY shared/interactive-shell.sh /etc/noodle/interactive-shell.sh
RUN chmod 0755 /usr/local/bin/noodle-welcome \
    && ln -s /etc/noodle/interactive-shell.sh /etc/profile.d/noodle-welcome.sh \
    && ln -s /etc/noodle/interactive-shell.sh /etc/bash.bashrc.d/noodle-welcome.sh
ENV ENV=/etc/noodle/interactive-shell.sh
RUN sed -i '$r /usr/share/kasmvnc/www/assets/noodle.css' /usr/share/kasmvnc/www/assets/custom.css
COPY shared/verify.sh /usr/local/lib/noodle-image-check
# Keep the pinned base's panel behavior and theme; change only product styling.
RUN grep -q '^rounded = 0$' /etc/xdg/tint2/tint2rc \
    && sed -i '0,/^rounded = 0$/s//rounded = 12/' /etc/xdg/tint2/tint2rc \
    && grep -q '^window.active.border.color: #ffffff$' /usr/share/themes/Desktop/openbox-3/themerc \
    && sed -i 's/^window.active.border.color: #ffffff$/window.active.border.color: #000000/' /usr/share/themes/Desktop/openbox-3/themerc
# Noodle owns authenticated VNC startup. Do not expose the inherited,
# unauthenticated helper or start a desktop merely by running this image.
RUN chmod -x /usr/local/bin/desktop-bridge && sh /usr/local/lib/noodle-image-check desktop
ENV DESKTOP_TITLE="Noodle Computer" \
    DESKTOP_WALLPAPER=/usr/share/backgrounds/desktop-wallpaper.svg
WORKDIR /workspace
HEALTHCHECK NONE
ENTRYPOINT ["/bin/sh"]
CMD ["-i"]

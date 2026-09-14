# syntax=docker/dockerfile:1.7
# Both stages come directly from official upstream images. No Launcher layers.
ARG UBUNTU_IMAGE=docker.io/library/ubuntu:24.04@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254
ARG NODE_IMAGE=docker.io/library/node:24-bookworm-slim@sha256:2fe369e969550cde8e867afc3fe370b260140cab4a23d467074295b42163d553
FROM ${NODE_IMAGE} AS node-runtime
FROM ${UBUNTU_IMAGE}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG TARGETARCH
ARG IMAGE_VERSION=development
ARG SOURCE_REVISION=local
ARG DESKTOP_BRAND="Noodle Computer"
ARG EXTRA_APT_PACKAGES=""
ARG KASMVNC_VERSION=1.4.0
ARG KASMVNC_SHA256_ARM64=120d9462cb5e917cad91a23f6cb0b780c06f701def40e900b29f996979200638
ARG KASMVNC_SHA256_AMD64=12bac6014149c5fdee75f0d403785aaa3e5dd4ea222de73253a5d4181bc9567e
ARG CORTILE_VERSION=2.5.2
ARG CORTILE_SHA256_ARM64=acebab88ef9e2301a25ce754838b3e8a5f6d800312436e871f2fad73b6f6fc9a
ARG CORTILE_SHA256_AMD64=dcc104bb2dbdf5596b6de5e578b8988347200759ca5c1134f9d0bec3b19ef3dd
LABEL org.opencontainers.image.title="${DESKTOP_BRAND}" \
      org.opencontainers.image.description="Ubuntu desktop with Openbox, KasmVNC and a shared browser session" \
      org.opencontainers.image.source="https://github.com/pdparchitect/noodle" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      im.noodle.desktop.contract="1"

# Xvnc supplies X11: no hardware X server, display manager, Snap or systemd.
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" && \
    case "$arch" in arm64|amd64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1;; esac && \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bash ca-certificates coreutils curl dnsutils file git git-lfs gnupg \
    iproute2 jq openssh-client openssl procps python3 python3-pip python-is-python3 \
    ripgrep socat sqlite3 sudo tar unzip vim wget xz-utils zip \
    xdg-utils ssl-cert xauth xkb-data x11-xkb-utils xfonts-base \
    xterm dbus-x11 libnotify-bin x11-utils gnome-keyring libsecret-tools dunst scrot \
    openbox obconf tint2 kitty ranger feh picom htop xdotool wmctrl \
    fonts-noto fonts-noto-color-emoji \
    libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libdrm2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libgbm1 \
    libpango-1.0-0 libasound2t64 libxshmfence1 ${EXTRA_APT_PACKAGES} && \
    rm -rf /var/lib/apt/lists/*

COPY desktop/build/install-desktop.sh /tmp/install-desktop.sh
RUN bash /tmp/install-desktop.sh && rm /tmp/install-desktop.sh

# Copy the Node/npm runtime without the upstream container entrypoint or Yarn
# symlinks (which point outside /usr/local). Dependencies stay inside the image.
COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=node-runtime /usr/local/lib/node_modules/ /usr/local/lib/node_modules/
COPY --from=node-runtime /usr/local/LICENSE /usr/share/doc/node/LICENSE
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

# Keep the desktop identity stable for saved homes, file transfers and sudo.
RUN if id ubuntu >/dev/null 2>&1; then \
      usermod -l agent -d /home/agent -m ubuntu && groupmod -n agent ubuntu; \
    else groupadd --gid 1000 agent && useradd --uid 1000 --gid agent --create-home --home-dir /home/agent --shell /bin/bash agent; fi && \
    usermod -s /bin/bash -a -G ssl-cert agent && \
    mkdir -p /workspace /home/agent/.vnc /etc/desktop/startup.d /etc/desktop/session.d /etc/desktop/conf.d \
      /etc/bash.bashrc.d /etc/sudoers.d /var/log/desktop && \
    printf 'agent ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/agent && chmod 0440 /etc/sudoers.d/agent && \
    visudo -cf /etc/sudoers && touch /home/agent/.sudo_as_admin_successful /home/agent/.hushlogin

COPY desktop/browser/package.json desktop/browser/package-lock.json /opt/noodle-browser/
RUN cd /opt/noodle-browser && npm ci --omit=dev --ignore-scripts --no-audit --no-fund && npm cache clean --force
COPY desktop/browser/index.cjs /opt/noodle-browser/index.cjs
COPY desktop/overlay/ /
COPY desktop/build/generate-resource-overlay.py /tmp/generate-gtk-resource-overlay.py
COPY desktop/NOTICE.md /usr/share/doc/noodle-desktop/NOTICE.md
COPY shared/noodle-welcome /usr/local/bin/noodle-welcome
COPY shared/interactive-shell.sh /etc/noodle/interactive-shell.sh
COPY shared/verify.sh /usr/local/lib/noodle-image-check
RUN chmod 0755 /init /usr/local/bin/desktop-* /usr/local/bin/chromium /usr/local/bin/cortilectl \
    /usr/local/bin/kasm-patch /usr/local/bin/noodle-welcome /usr/local/lib/noodle-chromium-base /etc/desktop/session.d/* /etc/xdg/openbox/autostart && \
    python3 /tmp/generate-gtk-resource-overlay.py /usr/share/themes/Desktop/openbox-3 /usr/share/desktop/gtk-overlay && \
    rm /tmp/generate-gtk-resource-overlay.py && \
    kasm-patch "$DESKTOP_BRAND" && \
    cat /usr/share/kasmvnc/www/assets/noodle.css >> /usr/share/kasmvnc/www/assets/custom.css && \
    printf '\nHidden=true\n' >> /etc/xdg/autostart/picom.desktop && \
    printf '\n[ ! -d /etc/bash.bashrc.d ] || for f in /etc/bash.bashrc.d/*.sh; do [ ! -r "$f" ] || . "$f"; done\n' >> /etc/bash.bashrc && \
    ln -s /etc/noodle/interactive-shell.sh /etc/profile.d/noodle-welcome.sh && \
    ln -s /etc/noodle/interactive-shell.sh /etc/bash.bashrc.d/noodle-welcome.sh && \
    ln -s /etc/profile.d/desktop-session-bus.sh /etc/bash.bashrc.d/desktop-session-bus.sh && \
    mkdir -p /usr/share/xsessions && \
    printf '[Desktop Entry]\nName=Openbox\nExec=openbox-session\nType=Application\n' > /usr/share/xsessions/openbox.desktop && \
    chown -R agent:agent /home/agent /workspace /var/log/desktop
ENV HOME=/home/agent TERM=xterm-256color LANG=C.UTF-8 \
    ENV=/etc/noodle/interactive-shell.sh BROWSER=chromium DISPLAY=:1 GTK_THEME=Desktop \
    G_RESOURCE_OVERLAYS=/org/gtk/libgtk=/usr/share/desktop/gtk-overlay \
    XAUTHORITY=/run/desktop/Xauthority DESKTOP_DEFAULT_TITLE="${DESKTOP_BRAND}"
RUN sh /usr/local/lib/noodle-image-check desktop
EXPOSE 6901
WORKDIR /workspace
USER agent
# Noodle prepares credentials and starts /init explicitly. Derived images may
# select desktop-start as their root entrypoint for standalone authenticated use.
ENTRYPOINT ["/bin/sh"]
CMD ["-i"]

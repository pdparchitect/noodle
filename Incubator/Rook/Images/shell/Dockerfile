# syntax=docker/dockerfile:1.7
# Rook's Shell: Noodle Computer's Shell on Kali's own base instead of Alpine, so every Kali package is one
# `sudo apt install` away. Nothing else is preinstalled. Built with Computer/Images as its context and
# --build-context brand=Incubator/Rook/Images/brand, as rook-images.yml does, from the same KALI_IMAGE as Rook's Desktop.
ARG KALI_IMAGE
FROM scratch AS brand
COPY shared/noodle-welcome /welcome

FROM ${KALI_IMAGE}
ARG IMAGE_VERSION=development
ARG SOURCE_REVISION=local
ARG IMAGE_PRODUCT="Rook"
LABEL org.opencontainers.image.title="${IMAGE_PRODUCT} Shell" \
      org.opencontainers.image.description="Minimal Kali workspace for ${IMAGE_PRODUCT}" \
      org.opencontainers.image.source="https://github.com/pdparchitect/noodle" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${SOURCE_REVISION}"

# Every computer's network is set up from this image, with its ip and udhcpc, on a 256 MB disk: keep it small.
# The account starts from an empty skeleton, so Kali's own prompt never replaces the image's.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates iproute2 sudo udhcpc \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /tmp/empty-skeleton \
    && groupadd --gid 1000 agent \
    && useradd --uid 1000 --gid agent --create-home --home-dir /home/agent --skel /tmp/empty-skeleton --shell /bin/bash agent \
    && rmdir /tmp/empty-skeleton \
    && mkdir -p /workspace /etc/sudoers.d \
    && chown agent:agent /workspace \
    && printf 'agent ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/agent \
    && chmod 0440 /etc/sudoers.d/agent \
    && visudo -cf /etc/sudoers \
    && touch /home/agent/.sudo_as_admin_successful /home/agent/.hushlogin \
    && chown agent:agent /home/agent/.sudo_as_admin_successful /home/agent/.hushlogin
WORKDIR /workspace
ENV HOME=/home/agent TERM=xterm-256color LANG=C.UTF-8
ENV ENV=/etc/noodle/interactive-shell.sh
COPY --from=brand /welcome /usr/local/bin/noodle-welcome
COPY shared/interactive-shell.sh /etc/noodle/interactive-shell.sh
# Dash reads ENV, login shells /etc/profile.d and Bash its system rc; the hook prints once per shell.
RUN chmod 0755 /usr/local/bin/noodle-welcome \
    && ln -s /etc/noodle/interactive-shell.sh /etc/profile.d/noodle-welcome.sh \
    && printf '\n. /etc/noodle/interactive-shell.sh\n' >> /etc/bash.bashrc
COPY shared/verify.sh /usr/local/lib/noodle-image-check
RUN sh /usr/local/lib/noodle-image-check shell
USER agent
CMD ["/bin/bash", "-i"]

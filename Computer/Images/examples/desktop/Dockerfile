# syntax=docker/dockerfile:1.7
# Replace with a released digest when publishing your own image.
ARG DESKTOP_IMAGE=ghcr.io/pdparchitect/noodle-computer-desktop-image:latest
FROM ${DESKTOP_IMAGE}
USER root
COPY overlay/ /
RUN chmod 0755 /etc/desktop/session.d/example
ENV DESKTOP_TITLE="Example Workspace" \
    DESKTOP_BROWSER_URL=file:///usr/local/share/desktop/workspace/welcome.html \
    DESKTOP_TERMINAL_AUTOSTART=0
RUN kasm-patch "Example Workspace"
# Inherit the authenticated startup contract and the normal non-root shell.
USER agent

# syntax=docker/dockerfile:1
#
# openhost-templeos
#
# Boots TempleOS (Terry A. Davis, public domain) inside QEMU and
# proxies its VGA framebuffer to a noVNC-served browser.  The whole
# thing is one container with no persistent state outside a single
# qcow2 disk image stored on the OpenHost persistent volume.
#
# Architecture
# ------------
#
#   browser  --HTTPS-->  OpenHost router  --HTTP-->  websockify (:6080)
#                                                     |
#                                                     | (WebSocket->TCP)
#                                                     v
#                                              QEMU VNC server (:5900)
#                                                     |
#                                                     v
#                                                  TempleOS
#
# noVNC's static client is served from the same websockify on /, so
# pointing a browser at the app URL gets you both the HTML client
# and the WebSocket VNC stream from one origin.
#
# We deliberately do NOT use KVM, even where /dev/kvm is available:
# OpenHost containers don't get /dev/kvm and TempleOS is happy on
# QEMU's TCG (translation cache) JIT.  Boot to the installer takes
# ~1-2s and everything inside is responsive.

FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

# QEMU does the actual emulation; novnc + websockify bridges its VNC
# server to a browser; ca-certificates lets the entrypoint follow
# redirects to https mirrors (we don't need it at runtime, but the
# install step uses it).  procps gives us pgrep/pkill for the
# crash-restart loop in the entrypoint.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        qemu-system-x86 \
        qemu-utils \
        novnc \
        websockify \
        ca-certificates \
        curl \
        procps && \
    rm -rf /var/lib/apt/lists/*

# Stage the TempleOS install ISO into the image.  TempleOS is in the
# public domain (Terry A. Davis released it that way explicitly; see
# templeos.org), so re-distribution inside this image is fine.  We
# still verify the download against a pinned SHA256 — both because
# the upstream file is decade-old and any change means a URL
# replacement / hijack, AND because the OpenHost build container
# may run from a hostile network where DNS / TLS chain compromise
# is possible.
#
# 17,350,656 bytes = 17.3 MB, mtime 2017-12-15.
# Pinned hash and size both checked: hash is the strong claim, size
# is a quick early-out before reading the whole file in.
RUN set -eux; \
    curl -fsSL -o /opt/TempleOS.ISO https://templeos.org/Downloads/TempleOS.ISO; \
    expected_size=17350656; \
    expected_sha256=5d0fc944e5d89c155c0fc17c148646715bc1db6fa5750c0b913772cfec19ba26; \
    actual_size="$(stat -c%s /opt/TempleOS.ISO)"; \
    if [ "$actual_size" != "$expected_size" ]; then \
        echo "TempleOS.ISO size mismatch: expected $expected_size, got $actual_size" >&2; \
        exit 1; \
    fi; \
    actual_sha256="$(sha256sum /opt/TempleOS.ISO | awk '{print $1}')"; \
    if [ "$actual_sha256" != "$expected_sha256" ]; then \
        echo "TempleOS.ISO sha256 mismatch: expected $expected_sha256, got $actual_sha256" >&2; \
        exit 1; \
    fi

# Drop our own /usr/share/novnc/index.html that auto-redirects to
# vnc_lite.html with the right query string for the websockify
# proxy path.  Without this, hitting / would 404 (noVNC ships
# vnc_lite.html but no index).
COPY index.html /usr/share/novnc/index.html

COPY openhost-entrypoint.sh /usr/local/bin/openhost-entrypoint.sh
RUN chmod +x /usr/local/bin/openhost-entrypoint.sh

EXPOSE 6080

ENTRYPOINT ["/usr/local/bin/openhost-entrypoint.sh"]

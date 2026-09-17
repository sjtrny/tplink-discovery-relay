# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG ALPINE_IMAGE=alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d

FROM ${ALPINE_IMAGE} AS relay-builder

ARG RELAY_SOURCE_SHA256=4ae552728645ac1922e0393fdd66ec685c95dcbafbea3ddf6c428a24ae8c0342

RUN apk add --no-cache \
      build-base \
      linux-headers

COPY vendor/udp-broadcast-relay/main.c /src/main.c

RUN set -eux; \
    printf '%s  %s\n' "${RELAY_SOURCE_SHA256}" /src/main.c | sha256sum -c -; \
    cc -O2 -Wall -Wextra \
      /src/main.c \
      -o /usr/local/bin/udp-broadcast-relay-redux; \
    strip /usr/local/bin/udp-broadcast-relay-redux


FROM ${ALPINE_IMAGE}

ARG RELAY_COMMIT=adbbadebc9922fd0b29388b7b041689a5f2d2546
ARG S6_OVERLAY_VERSION=3.2.3.0
ARG TARGETARCH
ARG TARGETVARIANT

LABEL org.opencontainers.image.title="TP-Link discovery relay for Home Assistant" \
      org.opencontainers.image.description="Supervised UDP discovery relays with a validated Home Assistant return path" \
      org.opencontainers.image.source="https://github.com/sjtrny/tplink-discovery-relay" \
      org.opencontainers.image.licenses="GPL-2.0-or-later" \
      io.github.sjtrny.tplink-discovery-relay.upstream-revision="${RELAY_COMMIT}"

RUN apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      gawk \
      iproute2 \
      iptables \
      libcap \
      procps \
      xz

RUN set -eux; \
    s6_noarch_sha256="b720f9d9340efc8bb07528b9743813c836e4b02f8693d90241f047998b4c53cf"; \
    case "${TARGETARCH}/${TARGETVARIANT}" in \
      amd64/) \
        s6_arch="x86_64"; \
        s6_arch_sha256="a93f02882c6ed46b21e7adb5c0add86154f01236c93cd82c7d682722e8840563" \
        ;; \
      arm64/|arm64/v8) \
        s6_arch="aarch64"; \
        s6_arch_sha256="0952056ff913482163cc30e35b2e944b507ba1025d78f5becbb89367bf344581" \
        ;; \
      arm/v7) \
        s6_arch="armhf"; \
        s6_arch_sha256="1ff4721b2a51e4f4dd9dbfffa47a994f14dbc3048853a83f7fb1c6ce93d59bf4" \
        ;; \
      arm/v6) \
        s6_arch="arm"; \
        s6_arch_sha256="d20c32160e7b8931170f71772a49229955503a003fc4604e708551e1393d9dee" \
        ;; \
      386/) \
        s6_arch="i686"; \
        s6_arch_sha256="83e7b518d4c163ee9c8852ceb4e2758e2b0a24ed573f9b41b72111222dc81ce0" \
        ;; \
      ppc64le/) \
        s6_arch="powerpc64le"; \
        s6_arch_sha256="0760ec715d372461f3a69887d8afadb20be8e5eb8e370bd75c724242df07d5b4" \
        ;; \
      riscv64/) \
        s6_arch="riscv64"; \
        s6_arch_sha256="a4a4ed5eb17562879d07189cc4b3b9cd146c2d88855792fa95d99e0decbfcaf8" \
        ;; \
      *) \
        echo "Unsupported platform: ${TARGETARCH}/${TARGETVARIANT}" >&2; \
        exit 1 \
        ;; \
    esac; \
    s6_base_url="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}"; \
    curl -fsSL "${s6_base_url}/s6-overlay-noarch.tar.xz" \
      -o /tmp/s6-overlay-noarch.tar.xz; \
    curl -fsSL "${s6_base_url}/s6-overlay-${s6_arch}.tar.xz" \
      -o /tmp/s6-overlay-arch.tar.xz; \
    printf '%s  %s\n' "${s6_noarch_sha256}" /tmp/s6-overlay-noarch.tar.xz \
      | sha256sum -c -; \
    printf '%s  %s\n' "${s6_arch_sha256}" /tmp/s6-overlay-arch.tar.xz \
      | sha256sum -c -; \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz; \
    tar -C / -Jxpf /tmp/s6-overlay-arch.tar.xz; \
    rm /tmp/s6-overlay-noarch.tar.xz /tmp/s6-overlay-arch.tar.xz

COPY --from=relay-builder \
  /usr/local/bin/udp-broadcast-relay-redux \
  /usr/local/bin/udp-broadcast-relay-redux

COPY LICENSE /usr/local/share/licenses/tplink-discovery-relay/LICENSE
COPY rootfs/ /

RUN chmod 0755 \
      /usr/local/bin/tplink-firewall \
      /usr/local/bin/tplink-healthcheck \
      /usr/local/bin/tplink-relay-service \
      /etc/cont-init.d/10-tplink-validate \
      /etc/cont-finish.d/90-tplink-cleanup \
      /etc/services.d/firewall/run \
      /etc/services.d/relay-9999/run \
      /etc/services.d/relay-20002/run \
      /etc/services.d/relay-20004/run

ENV PATH="/command:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HA_PORT=8123 \
    RELAY_PORTS=9999,20002,20004 \
    FIREWALL_CHECK_INTERVAL=30 \
    RELAY_TOPOLOGY_CHECK_INTERVAL=5 \
    RELAY_DEBUG=false \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_KILL_FINISH_MAXTIME=10000 \
    S6_VERBOSITY=1

HEALTHCHECK \
  --interval=30s \
  --timeout=12s \
  --start-period=45s \
  --retries=3 \
  CMD ["/usr/local/bin/tplink-healthcheck"]

ENTRYPOINT ["/init"]

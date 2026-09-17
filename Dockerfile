# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

FROM alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d AS base

FROM base AS relay-builder

RUN apk add --no-cache \
      build-base \
      linux-headers

COPY vendor/udp-broadcast-relay/main.c /src/main.c

RUN set -eux; \
    echo '4ae552728645ac1922e0393fdd66ec685c95dcbafbea3ddf6c428a24ae8c0342  /src/main.c' \
      | sha256sum -c -; \
    cc -O2 -Wall -Wextra /src/main.c \
      -o /usr/local/bin/udp-broadcast-relay-redux; \
    strip /usr/local/bin/udp-broadcast-relay-redux

FROM base AS s6-builder

ARG TARGETARCH

RUN apk add --no-cache xz

RUN set -eux; \
    s6_version='3.2.3.0'; \
    s6_noarch_sha256='b720f9d9340efc8bb07528b9743813c836e4b02f8693d90241f047998b4c53cf'; \
    case "$TARGETARCH" in \
      amd64) \
        s6_arch='x86_64'; \
        s6_arch_sha256='a93f02882c6ed46b21e7adb5c0add86154f01236c93cd82c7d682722e8840563' \
        ;; \
      arm64) \
        s6_arch='aarch64'; \
        s6_arch_sha256='0952056ff913482163cc30e35b2e944b507ba1025d78f5becbb89367bf344581' \
        ;; \
      *) \
        echo "Unsupported platform: $TARGETARCH" >&2; \
        exit 1 \
        ;; \
    esac; \
    s6_url="https://github.com/just-containers/s6-overlay/releases/download/v$s6_version"; \
    wget -qO /tmp/s6-noarch.tar.xz "$s6_url/s6-overlay-noarch.tar.xz"; \
    wget -qO /tmp/s6-arch.tar.xz "$s6_url/s6-overlay-$s6_arch.tar.xz"; \
    echo "$s6_noarch_sha256  /tmp/s6-noarch.tar.xz" | sha256sum -c -; \
    echo "$s6_arch_sha256  /tmp/s6-arch.tar.xz" | sha256sum -c -; \
    mkdir /overlay; \
    tar -C /overlay -Jxpf /tmp/s6-noarch.tar.xz; \
    tar -C /overlay -Jxpf /tmp/s6-arch.tar.xz

FROM base

LABEL org.opencontainers.image.title="TP-Link discovery relay for Home Assistant" \
      org.opencontainers.image.description="Relays TP-Link discovery packets between a LAN and Home Assistant" \
      org.opencontainers.image.source="https://github.com/sjtrny/tplink-discovery-relay" \
      org.opencontainers.image.licenses="GPL-2.0-or-later" \
      io.github.sjtrny.tplink-discovery-relay.upstream-revision="adbbadebc9922fd0b29388b7b041689a5f2d2546"

RUN apk add --no-cache \
      bash \
      iproute2-minimal \
      iptables \
      iptables-legacy \
      procps

COPY --from=s6-builder /overlay/ /
COPY --from=relay-builder \
  /usr/local/bin/udp-broadcast-relay-redux \
  /usr/local/bin/udp-broadcast-relay-redux

COPY LICENSE /usr/local/share/licenses/tplink-discovery-relay/LICENSE
COPY lib/network.sh /usr/local/lib/tplink-network.sh
COPY rootfs/ /

ENV PATH="/command:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HA_PORT=8123 \
    FIREWALL_CHECK_INTERVAL=30 \
    RELAY_NETWORK_CHECK_INTERVAL=5 \
    RELAY_DEBUG=false \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_KILL_FINISH_MAXTIME=10000 \
    S6_VERBOSITY=1

HEALTHCHECK \
  --interval=30s \
  --timeout=12s \
  --start-period=45s \
  --retries=3 \
  CMD ["/usr/local/bin/tplink-healthcheck"]

ENTRYPOINT ["/init"]

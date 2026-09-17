# tplink-discovery-relay

TP-Link, Kasa, and Tapo discovery for Home Assistant on Docker bridge networks.

This container relays UDP discovery packets between the LAN and Home Assistant. It supports ports 9999, 20002, and 20004.

## Run

You need Linux, rootful Docker, Docker Compose, and a fixed Home Assistant address on a user-defined bridge network.

Stop other relays that use these ports.

```sh
cp .env.example .env
# Edit .env.
sudo install -m 0600 /dev/null /run/xtables.lock
./scripts/preflight-host.sh
docker compose up -d
```

Example `compose.yaml`:

```yaml
services:
  tplink-discovery-relay:
    image: ghcr.io/sjtrny/tplink-discovery-relay:latest
    network_mode: host
    cap_drop: [ALL]
    cap_add: [NET_ADMIN, NET_RAW]
    restart: unless-stopped
    environment:
      LAN_IF: eth0
      LAN_NET: 192.168.1.0/24
      DOCKER_SUBNET: 172.20.0.0/16
      HA_IP: 172.20.0.10
      HA_PORT: "8123"
    volumes:
      - type: bind
        source: /run/xtables.lock
        target: /run/xtables.lock
        bind:
          create_host_path: false
```

## Configuration

| Variable | Default | Use |
| --- | --- | --- |
| `LAN_IF` | Required | LAN interface |
| `LAN_NET` | Required | LAN subnet in CIDR notation |
| `DOCKER_SUBNET` | Required | Home Assistant Docker subnet |
| `HA_IP` | Required | Fixed Home Assistant address |
| `HA_PORT` | `8123` | Home Assistant HTTP port |
| `RELAY_DEBUG` | `false` | Packet logging |

The container finds the Docker interface. Its health check verifies the relay processes, the Home Assistant endpoint, and the firewall rules.

## License

[GPL-2.0-or-later](LICENSE). Uses [`udp-broadcast-relay-redux`](https://github.com/FirbyKirby/udp-broadcast-relay).

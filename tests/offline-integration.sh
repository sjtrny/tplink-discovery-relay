#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${IMAGE:-tplink-discovery-relay:test}"
TEST_ID="${TEST_ID:-$$}"
LAN_NETWORK="tplink-relay-test-lan-$TEST_ID"
BACKEND_NETWORK="tplink-relay-test-backend-$TEST_ID"
HA_CONTAINER="tplink-relay-test-ha-$TEST_ID"
VALID_CONTAINER="tplink-relay-test-valid-$TEST_ID"
INVALID_CONTAINER="tplink-relay-test-invalid-$TEST_ID"

LAN_SUBNET=10.251.245.0/24
BACKEND_SUBNET=10.251.246.0/24
HA_IP=10.251.246.30
VALID_BACKEND_IP=10.251.246.10
INVALID_BACKEND_IP=10.251.246.11

cleanup() {
    docker container rm --force \
        "$VALID_CONTAINER" "$INVALID_CONTAINER" "$HA_CONTAINER" \
        >/dev/null 2>&1 || true
    docker network rm "$LAN_NETWORK" "$BACKEND_NETWORK" \
        >/dev/null 2>&1 || true
}

fail() {
    echo "Integration test failed: $*" >&2
    docker logs "$VALID_CONTAINER" >&2 2>/dev/null || true
    docker logs "$INVALID_CONTAINER" >&2 2>/dev/null || true
    exit 1
}

create_relay() {
    local name="$1"
    local backend_ip="$2"
    local ha_ip="$3"

    docker create \
        --name "$name" \
        --network "$LAN_NETWORK" \
        --cap-drop ALL \
        --cap-add NET_ADMIN \
        --cap-add NET_RAW \
        --read-only \
        --tmpfs /run:rw,exec,nosuid,nodev,mode=755,size=16m \
        --security-opt no-new-privileges \
        --health-interval 1s \
        --health-timeout 8s \
        --health-retries 2 \
        --health-start-period 1s \
        -e LAN_IF=eth0 \
        -e LAN_NET="$LAN_SUBNET" \
        -e DOCKER_SUBNET="$BACKEND_SUBNET" \
        -e HA_IP="$ha_ip" \
        -e HA_PORT=8123 \
        -e FIREWALL_CHECK_INTERVAL=1 \
        -e RELAY_NETWORK_CHECK_INTERVAL=1 \
        --entrypoint /bin/sh \
        "$IMAGE" \
        -c 'iptables -N DOCKER-USER; exec /init' \
        >/dev/null

    docker start "$name" >/dev/null
    docker network connect --ip "$backend_ip" "$BACKEND_NETWORK" "$name"
}

wait_for_manual_health() {
    local name="$1"
    for _ in $(seq 1 20); do
        if docker exec "$name" /usr/local/bin/tplink-healthcheck \
            >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_docker_health() {
    local name="$1"
    local status

    for _ in $(seq 1 20); do
        status="$(
            docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' \
                "$name"
        )"
        [[ "$status" == healthy ]] && return 0
        sleep 1
    done
    return 1
}

wait_for_no_nat_chain() {
    local name="$1"
    for _ in $(seq 1 12); do
        if ! docker exec "$name" iptables -t nat -S TPLINK_HA_DNAT \
            >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_no_relay_processes() {
    local name="$1"
    local count

    for _ in $(seq 1 12); do
        count="$(
            docker exec "$name" \
                pgrep -fc '^/usr/local/bin/udp-broadcast-relay-redux ' \
                2>/dev/null || true
        )"
        [[ "$count" == 0 ]] && return 0
        sleep 1
    done
    return 1
}

trap cleanup EXIT
cleanup

docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || fail "image $IMAGE is not present"
docker network create --subnet "$LAN_SUBNET" "$LAN_NETWORK" >/dev/null
docker network create --subnet "$BACKEND_SUBNET" "$BACKEND_NETWORK" >/dev/null

docker run --detach \
    --name "$HA_CONTAINER" \
    --network "$BACKEND_NETWORK" \
    --ip "$HA_IP" \
    --entrypoint /bin/sh \
    "$IMAGE" \
    -c 'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nready" | nc -l -p 8123; done' \
    >/dev/null

create_relay "$VALID_CONTAINER" "$VALID_BACKEND_IP" "$HA_IP"
create_relay "$INVALID_CONTAINER" "$INVALID_BACKEND_IP" 10.251.246.31

wait_for_manual_health "$VALID_CONTAINER" \
    || fail "valid relay did not pass its health check"
wait_for_docker_health "$VALID_CONTAINER" \
    || fail "Docker did not mark the valid relay as healthy"

relay_count="$(
    docker exec "$VALID_CONTAINER" \
        pgrep -fc '^/usr/local/bin/udp-broadcast-relay-redux '
)"
[[ "$relay_count" == 3 ]] || fail "found $relay_count relay processes; expected 3"
docker exec "$VALID_CONTAINER" iptables -t nat -S TPLINK_HA_DNAT |
    grep -F -- "-j DNAT --to-destination $HA_IP" >/dev/null \
    || fail "DNAT rule does not target the validated Home Assistant address"
docker exec "$VALID_CONTAINER" iptables -S TPLINK_HA_FWD |
    grep -F -- "-d $HA_IP/32 -o eth1 -j ACCEPT" >/dev/null \
    || fail "forward rule does not use the Docker interface"

sleep 2
if docker exec "$INVALID_CONTAINER" /usr/local/bin/tplink-healthcheck \
    >/dev/null 2>&1; then
    fail "health check passed with an invalid Home Assistant address"
fi
wait_for_no_nat_chain "$INVALID_CONTAINER" \
    || fail "invalid Home Assistant address installed a DNAT chain"

docker stop --timeout 1 "$HA_CONTAINER" >/dev/null
wait_for_no_nat_chain "$VALID_CONTAINER" \
    || fail "DNAT chain remained after Home Assistant stopped"
if docker exec "$VALID_CONTAINER" /usr/local/bin/tplink-healthcheck \
    >/dev/null 2>&1; then
    fail "health check passed while Home Assistant was stopped"
fi

docker start "$HA_CONTAINER" >/dev/null
wait_for_manual_health "$VALID_CONTAINER" \
    || fail "relay did not recover after Home Assistant restarted"

docker network disconnect "$BACKEND_NETWORK" "$VALID_CONTAINER"
wait_for_no_relay_processes "$VALID_CONTAINER" \
    || fail "relay processes remained bound to a removed Docker interface"
wait_for_no_nat_chain "$VALID_CONTAINER" \
    || fail "DNAT chain remained after the Docker route disappeared"

docker network connect --ip "$VALID_BACKEND_IP" \
    "$BACKEND_NETWORK" "$VALID_CONTAINER"
wait_for_manual_health "$VALID_CONTAINER" \
    || fail "relay did not recover after the Docker route returned"
wait_for_docker_health "$VALID_CONTAINER" \
    || fail "Docker health did not recover after the network change"

echo "Integration test passed."

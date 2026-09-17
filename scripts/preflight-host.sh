#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
env_file="${ENV_FILE:-$project_dir/.env}"

if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
fi

DOCKER_CONTEXT="${DOCKER_CONTEXT:-default}"
HA_PORT="${HA_PORT:-8123}"

docker_cmd=(docker --context "$DOCKER_CONTEXT")

fail() {
    echo "preflight failed: $*" >&2
    exit 1
}

for name in HA_CONTAINER DOCKER_NETWORK LAN_IF LAN_NET DOCKER_SUBNET HA_IP; do
    [[ -n "${!name:-}" ]] || fail "$name is not set (use $env_file)"
done

route_device_for_ip() {
    ip -4 route get "$1" 2>/dev/null |
        awk '{
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }'
}

command -v docker >/dev/null 2>&1 || fail "docker is not installed"
command -v ip >/dev/null 2>&1 || fail "iproute2 is not installed"
command -v curl >/dev/null 2>&1 || fail "curl is not installed"

docker_security_options="$(
    "${docker_cmd[@]}" info --format '{{join .SecurityOptions "\n"}}' 2>/dev/null
)" || fail "Docker context $DOCKER_CONTEXT is unavailable"
if grep -Fxq 'name=rootless' <<<"$docker_security_options"; then
    fail "Docker context $DOCKER_CONTEXT is rootless; rootful Docker is required"
fi

"${docker_cmd[@]}" inspect "$HA_CONTAINER" >/dev/null 2>&1 \
    || fail "container $HA_CONTAINER is unavailable in Docker context $DOCKER_CONTEXT"
"${docker_cmd[@]}" network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 \
    || fail "Docker network $DOCKER_NETWORK is unavailable"

ha_running="$(
    "${docker_cmd[@]}" inspect --format '{{.State.Running}}' "$HA_CONTAINER"
)"
[[ "$ha_running" == true ]] || fail "container $HA_CONTAINER is not running"

network_template="{{with index .NetworkSettings.Networks \"$DOCKER_NETWORK\"}}{{.IPAddress}}{{end}}"
actual_ha_ip="$(
    "${docker_cmd[@]}" inspect --format "$network_template" "$HA_CONTAINER"
)"
[[ -n "$actual_ha_ip" ]] \
    || fail "$HA_CONTAINER is not attached to $DOCKER_NETWORK"
[[ "$actual_ha_ip" == "$HA_IP" ]] \
    || fail "HA_IP is $HA_IP, but $HA_CONTAINER uses $actual_ha_ip on $DOCKER_NETWORK"

mapfile -t network_subnets < <(
    "${docker_cmd[@]}" network inspect \
        --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' \
        "$DOCKER_NETWORK" |
        awk 'NF'
)
subnet_match=false
for subnet in "${network_subnets[@]}"; do
    if [[ "$subnet" == "$DOCKER_SUBNET" ]]; then
        subnet_match=true
        break
    fi
done
[[ "$subnet_match" == true ]] \
    || fail "DOCKER_SUBNET $DOCKER_SUBNET does not match $DOCKER_NETWORK (${network_subnets[*]})"

lan_ip="$(
    ip -4 -o address show dev "$LAN_IF" scope global 2>/dev/null |
        awk 'NR == 1 { split($4, address, "/"); print address[1] }'
)"
[[ -n "$lan_ip" ]] || fail "$LAN_IF has no usable IPv4 address"

mapfile -t bridge_interfaces < <(
    ip -4 route show exact "$DOCKER_SUBNET" 2>/dev/null |
        awk '{
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    break
                }
            }
        }'
)
(( ${#bridge_interfaces[@]} == 1 )) \
    || fail "expected one route for $DOCKER_SUBNET; found ${#bridge_interfaces[@]}"
bridge_if="${bridge_interfaces[0]}"
[[ "$bridge_if" != "lo" && "$bridge_if" != "$LAN_IF" ]] \
    || fail "$DOCKER_SUBNET resolves to invalid relay interface $bridge_if"

ha_route_if="$(route_device_for_ip "$HA_IP")"
[[ "$ha_route_if" == "$bridge_if" ]] \
    || fail "$HA_IP routes through ${ha_route_if:-no interface}, not $bridge_if"

curl --silent --fail \
    --connect-timeout 2 \
    --max-time 4 \
    --output /dev/null \
    "http://$HA_IP:$HA_PORT/" \
    || fail "Home Assistant endpoint http://$HA_IP:$HA_PORT/ is unavailable"

echo "preflight passed:"
echo "  Docker context=$DOCKER_CONTEXT"
echo "  LAN=$LAN_NET at $lan_ip via $LAN_IF"
echo "  Docker network=$DOCKER_NETWORK ($DOCKER_SUBNET) via $bridge_if"
echo "  Home Assistant=$HA_CONTAINER at http://$HA_IP:$HA_PORT/"

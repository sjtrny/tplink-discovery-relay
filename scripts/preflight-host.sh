#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
env_file="$project_dir/.env"

# shellcheck source=lib/network.sh
source "$project_dir/lib/network.sh"

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
    echo "Preflight failed: $*" >&2
    exit 1
}

for name in HA_CONTAINER DOCKER_NETWORK LAN_IF LAN_NET DOCKER_SUBNET HA_IP; do
    [[ -n "${!name:-}" ]] || fail "Set $name in $env_file"
done

command -v docker >/dev/null 2>&1 || fail "docker is not installed"
command -v ip >/dev/null 2>&1 || fail "iproute2 is not installed"
command -v curl >/dev/null 2>&1 || fail "curl is not installed"

docker_security_options="$(
    "${docker_cmd[@]}" info --format '{{join .SecurityOptions "\n"}}' 2>/dev/null
)" || fail "Docker context $DOCKER_CONTEXT is not available"
if grep -Fxq 'name=rootless' <<<"$docker_security_options"; then
    fail "Docker context $DOCKER_CONTEXT is rootless. Use rootful Docker."
fi

"${docker_cmd[@]}" inspect "$HA_CONTAINER" >/dev/null 2>&1 \
    || fail "Docker cannot find container $HA_CONTAINER in context $DOCKER_CONTEXT"
"${docker_cmd[@]}" network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 \
    || fail "Docker cannot find network $DOCKER_NETWORK"

ha_running="$(
    "${docker_cmd[@]}" inspect --format '{{.State.Running}}' "$HA_CONTAINER"
)"
[[ "$ha_running" == true ]] || fail "Container $HA_CONTAINER is not running"

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

# shellcheck disable=SC2153
lan_ip="$(interface_ipv4 "$LAN_IF")"
[[ -n "$lan_ip" ]] || fail "$LAN_IF has no usable IPv4 address"

mapfile -t lan_interfaces < <(route_interfaces_for_subnet "$LAN_NET")
(( ${#lan_interfaces[@]} == 1 )) \
    || fail "LAN_NET $LAN_NET must have one route"
[[ "${lan_interfaces[0]}" == "$LAN_IF" ]] \
    || fail "LAN_NET $LAN_NET uses ${lan_interfaces[0]}, not $LAN_IF"

mapfile -t bridge_interfaces < <(route_interfaces_for_subnet "$DOCKER_SUBNET")
(( ${#bridge_interfaces[@]} == 1 )) \
    || fail "DOCKER_SUBNET $DOCKER_SUBNET must have one route"
bridge_if="${bridge_interfaces[0]}"
[[ "$bridge_if" != "lo" && "$bridge_if" != "$LAN_IF" ]] \
    || fail "DOCKER_SUBNET uses invalid relay interface $bridge_if"

ha_route_if="$(route_interface_for_ip "$HA_IP")"
[[ "$ha_route_if" == "$bridge_if" ]] \
    || fail "$HA_IP uses ${ha_route_if:-no interface}, not $bridge_if"

curl --silent --fail \
    --connect-timeout 2 \
    --max-time 4 \
    --output /dev/null \
    "http://$HA_IP:$HA_PORT/" \
    || fail "Home Assistant is not available at http://$HA_IP:$HA_PORT/"

echo "Preflight passed:"
echo "  Docker context=$DOCKER_CONTEXT"
echo "  LAN=$LAN_NET at $lan_ip via $LAN_IF"
echo "  Docker network=$DOCKER_NETWORK ($DOCKER_SUBNET) via $bridge_if"
echo "  Home Assistant=$HA_CONTAINER at http://$HA_IP:$HA_PORT/"

# shellcheck shell=bash

interface_ipv4() {
    ip -4 -o address show dev "$1" scope global 2>/dev/null |
        awk 'NR == 1 { split($4, address, "/"); print address[1] }'
}

route_interface_for_ip() {
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

route_interfaces_for_subnet() {
    ip -4 route show exact "$1" 2>/dev/null |
        awk '{
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    break
                }
            }
        }'
}

bridge_for_subnet() {
    local subnet="$1"
    local lan_if="$2"
    local -a interfaces=()

    mapfile -t interfaces < <(route_interfaces_for_subnet "$subnet")
    (( ${#interfaces[@]} == 1 )) || return 1
    [[ "${interfaces[0]}" != "lo" && "${interfaces[0]}" != "$lan_if" ]] \
        || return 1
    printf '%s\n' "${interfaces[0]}"
}

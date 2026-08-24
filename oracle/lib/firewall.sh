#!/usr/bin/env bash

# Sourced by the root-owned firewall reconciler and its tests.

reset_firewall_chain() {
    local command=$1
    local chain=$2
    local parent=$3

    if "$command" --wait 10 --list "$chain" >/dev/null 2>&1; then
        "$command" --wait 10 --flush "$chain"
    else
        "$command" --wait 10 --new-chain "$chain"
    fi

    while "$command" --wait 10 --check "$parent" --jump "$chain" >/dev/null 2>&1; do
        "$command" --wait 10 --delete "$parent" --jump "$chain"
    done
    "$command" --wait 10 --insert "$parent" 1 --jump "$chain"
}

reconcile_webserver_firewall() {
    local ssh_locked_down=$1
    [[ $ssh_locked_down == true || $ssh_locked_down == false ]] ||
        die "invalid firewall lock-down state"

    reset_firewall_chain iptables WEBSERVER_INPUT INPUT
    iptables --wait 10 --append WEBSERVER_INPUT \
        --match conntrack --ctstate RELATED,ESTABLISHED --jump ACCEPT
    iptables --wait 10 --append WEBSERVER_INPUT \
        --in-interface lo --jump ACCEPT
    iptables --wait 10 --append WEBSERVER_INPUT \
        --protocol icmp --jump ACCEPT
    iptables --wait 10 --append WEBSERVER_INPUT \
        --in-interface tailscale0 --protocol tcp \
        --match multiport --destination-ports 22,2222 --jump ACCEPT
    iptables --wait 10 --append WEBSERVER_INPUT \
        --source "$WEBSERVER_NETWORK_SUBNET" --destination "$WEBSERVER_NETWORK_GATEWAY" \
        --protocol udp --destination-port 53 --jump ACCEPT
    iptables --wait 10 --append WEBSERVER_INPUT \
        --source "$WEBSERVER_NETWORK_SUBNET" --destination "$WEBSERVER_NETWORK_GATEWAY" \
        --protocol tcp --destination-port 53 --jump ACCEPT
    if [[ $ssh_locked_down == true ]]; then
        iptables --wait 10 --append WEBSERVER_INPUT \
            ! --in-interface tailscale0 --protocol tcp --destination-port 22 --jump DROP
    else
        iptables --wait 10 --append WEBSERVER_INPUT \
            --protocol tcp --destination-port 22 --jump ACCEPT
    fi
    iptables --wait 10 --append WEBSERVER_INPUT --jump RETURN

    reset_firewall_chain iptables WEBSERVER_FORWARD FORWARD
    iptables --wait 10 --append WEBSERVER_FORWARD \
        --source "$WEBSERVER_NETWORK_SUBNET" --destination "$WEBSERVER_NETWORK_SUBNET" \
        --jump ACCEPT
    iptables --wait 10 --append WEBSERVER_FORWARD \
        --destination "$WEBSERVER_NETWORK_SUBNET" --match conntrack \
        --ctstate RELATED,ESTABLISHED --jump ACCEPT
    iptables --wait 10 --append WEBSERVER_FORWARD \
        --source "$WEBSERVER_NETWORK_SUBNET" --match conntrack \
        --ctstate RELATED,ESTABLISHED --jump ACCEPT
    iptables --wait 10 --append WEBSERVER_FORWARD \
        --destination "$WEBSERVER_NETWORK_SUBNET" --protocol tcp \
        --match multiport --destination-ports 80,443 --jump ACCEPT
    iptables --wait 10 --append WEBSERVER_FORWARD \
        --destination "$WEBSERVER_NETWORK_SUBNET" --protocol udp \
        --destination-port 443 --jump ACCEPT
    iptables --wait 10 --append WEBSERVER_FORWARD \
        --source "$WEBSERVER_NETWORK_SUBNET" --protocol tcp \
        --match multiport --destination-ports 80,443 --jump ACCEPT
    iptables --wait 10 --append WEBSERVER_FORWARD \
        --source "$WEBSERVER_NETWORK_SUBNET" --jump REJECT \
        --reject-with icmp-port-unreachable
    iptables --wait 10 --append WEBSERVER_FORWARD \
        --destination "$WEBSERVER_NETWORK_SUBNET" --jump REJECT \
        --reject-with icmp-port-unreachable
    iptables --wait 10 --append WEBSERVER_FORWARD --jump RETURN

    reset_firewall_chain ip6tables WEBSERVER_INPUT INPUT
    ip6tables --wait 10 --append WEBSERVER_INPUT \
        --match conntrack --ctstate RELATED,ESTABLISHED --jump ACCEPT
    ip6tables --wait 10 --append WEBSERVER_INPUT \
        --in-interface lo --jump ACCEPT
    ip6tables --wait 10 --append WEBSERVER_INPUT \
        --protocol ipv6-icmp --jump ACCEPT
    ip6tables --wait 10 --append WEBSERVER_INPUT \
        --in-interface tailscale0 --protocol tcp \
        --match multiport --destination-ports 22,2222 --jump ACCEPT
    if [[ $ssh_locked_down == true ]]; then
        ip6tables --wait 10 --append WEBSERVER_INPUT \
            ! --in-interface tailscale0 --protocol tcp --destination-port 22 --jump DROP
    else
        ip6tables --wait 10 --append WEBSERVER_INPUT \
            --protocol tcp --destination-port 22 --jump ACCEPT
    fi
    ip6tables --wait 10 --append WEBSERVER_INPUT --jump RETURN

    iptables --wait 10 --policy INPUT DROP
    iptables --wait 10 --policy FORWARD DROP
    ip6tables --wait 10 --policy INPUT DROP
    ip6tables --wait 10 --policy FORWARD DROP
}

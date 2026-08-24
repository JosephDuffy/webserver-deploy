#!/usr/bin/env bash

set -Eeuo pipefail

# Constants are consumed by the commands that source this library, making them appear unused.
# shellcheck disable=SC2034
{
    readonly WEBSITE_REPOSITORY="JosephDuffy/josephduffy.co.uk"
    readonly WEBSITE_IMAGE="ghcr.io/josephduffy/josephduffy.co.uk"
    readonly WEBSITE_SEED_DIGEST="sha256:b5024818f78fbc6aeb72b4781863c75211ea026fb73940ac2e25de094706cbd0"
    readonly WEBSITE_LOCAL_IMAGE="localhost/josephduffy-co-uk:production"
    readonly CADDY_IMAGE="docker.io/library/caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648"
    readonly TRIAL_HOSTNAME="oracle.josephduffy.co.uk"
    readonly RELEASE_ROOT="/opt/webserver/releases"
    readonly CURRENT_RELEASE="/opt/webserver/current"
    readonly STATE_DIR="/var/lib/webserver-deploy"
    readonly ENV_FILE="/etc/webserver/josephduffy-co-uk.env"
    readonly QUADLET_DIR="/etc/containers/systemd"
    readonly FIREWALL_SERVICE="webserver-firewall.service"
    readonly WEBSERVER_NETWORK_SUBNET="10.89.0.0/24"
    readonly WEBSERVER_NETWORK_GATEWAY="10.89.0.1"
}

die() {
    printf 'webserver-deploy: %s\n' "$*" >&2
    exit 1
}

log() {
    printf 'webserver-deploy: %s\n' "$*"
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die "this command must run as root"
}

validate_digest() {
    [[ $# -eq 1 && $1 =~ ^sha256:[0-9a-f]{64}$ ]]
}

validate_commit() {
    [[ $# -eq 1 && $1 =~ ^[0-9a-f]{40}$ ]]
}

require_supported_host() {
    [[ -r /etc/os-release ]] || die "cannot identify the operating system"
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] ||
        die "Ubuntu 24.04 is required (found ${PRETTY_NAME:-unknown})"
    [[ $(uname -m) == aarch64 ]] ||
        die "aarch64 is required (found $(uname -m))"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "missing required command '$1'; bootstrap update required"
}

require_runtime_capabilities() {
    local command
    for command in podman runc systemctl curl jq gh flock tailscale iptables ip6tables; do
        require_command "$command"
    done
    [[ -x /usr/libexec/podman/quadlet ]] ||
        die "Podman Quadlet is unavailable; bootstrap update required"
    dpkg --compare-versions "$(podman version --format '{{.Client.Version}}')" ge 4.9 ||
        die "Podman 4.9 or newer is required; bootstrap update required"
    [[ $(podman info --format '{{.Host.CgroupsVersion}}') == v2 ]] ||
        die "Podman requires cgroup v2; bootstrap update required"
    dpkg --compare-versions "$(tailscale version | sed -n '1p')" ge 1.90.1 ||
        die "Tailscale 1.90.1 or newer is required; bootstrap update required"
    gh attestation verify --help >/dev/null 2>&1 ||
        die "GitHub CLI does not support attestation verification; bootstrap update required"
}

atomic_symlink() {
    local target=$1
    local link=$2
    local temporary="${link}.new"

    ln -sfn "$target" "$temporary"
    mv -Tf "$temporary" "$link"
}

install_managed_files() {
    local release=$1
    local unit

    install -o root -g root -m 0755 \
        "$release/scripts/webserver-image-deploy" /usr/local/sbin/webserver-image-deploy
    install -o root -g root -m 0755 \
        "$release/scripts/webserver-config-deploy" /usr/local/sbin/webserver-config-deploy
    install -o root -g root -m 0755 \
        "$release/scripts/lock-down-ssh" /usr/local/sbin/webserver-lock-down-ssh
    install -o root -g root -m 0755 \
        "$release/scripts/reconcile-firewall" /usr/local/sbin/webserver-reconcile-firewall
    install -o root -g root -m 0644 \
        "$release/lib/common.sh" /usr/local/lib/webserver-deploy-common.sh
    install -o root -g root -m 0644 \
        "$release/lib/image-transaction.sh" /usr/local/lib/webserver-deploy-image-transaction.sh
    install -o root -g root -m 0644 \
        "$release/lib/firewall.sh" /usr/local/lib/webserver-deploy-firewall.sh
    install -o root -g root -m 0440 \
        "$release/host/webserver-deploy.sudoers" /etc/sudoers.d/webserver-deploy
    install -o root -g root -m 0644 \
        "$release/host/webserver-firewall.service" /etc/systemd/system/webserver-firewall.service

    mkdir -p "$QUADLET_DIR"
    for unit in "$release"/quadlet/*; do
        ln -sfn "$CURRENT_RELEASE/quadlet/$(basename "$unit")" "$QUADLET_DIR/$(basename "$unit")"
    done
}

record_history() {
    local event=$1
    mkdir -p "$STATE_DIR"
    printf '%s\t%s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$event" >>"$STATE_DIR/history.log"
}

verify_attestation() (
    set +x
    [[ $# -ge 1 && $# -le 2 ]] || die "verify_attestation requires a digest and optional token file"
    local digest=$1
    local token_file=${2:-}
    local token

    if [[ -n $token_file ]]; then
        [[ -f $token_file && -s $token_file && -r $token_file && ! -L $token_file ]] ||
            die "GitHub attestation verification requires a nonempty readable token file"
        token=$(<"$token_file")
    else
        token=${GH_TOKEN:-}
    fi
    [[ -n $token && $token != *[[:space:]]* ]] ||
        die "GitHub attestation verification requires a single-line token"

    GH_TOKEN=$token GH_PROMPT_DISABLED=1 \
        gh attestation verify "oci://${WEBSITE_IMAGE}@${digest}" --repo "$WEBSITE_REPOSITORY"
)

verify_attestation_from_stdin() (
    set +x
    [[ $# -eq 1 ]] || die "verify_attestation_from_stdin requires a digest"
    local token
    IFS= read -r token || die "GitHub attestation token was not supplied on standard input"
    if IFS= read -r; then
        die "GitHub attestation input must contain exactly one line"
    fi
    GH_TOKEN=$token verify_attestation "$1"
)

image_platform() {
    local reference=$1
    podman image inspect --format '{{.Os}}/{{.Architecture}}' "$reference"
}

wait_for_container_health() {
    local container=$1
    local attempts=${2:-30}
    local delay=${3:-5}
    local index

    for ((index = 1; index <= attempts; index += 1)); do
        if ((index == attempts)); then
            if podman healthcheck run "$container"; then
                return 0
            fi
        elif podman healthcheck run "$container" >/dev/null 2>&1; then
            return 0
        fi
        ((index == attempts)) || sleep "$delay"
    done
    log "container health check did not pass for ${container}"
    return 1
}

wait_for_container_image() {
    local container=$1
    local expected_image_id=$2
    local attempts=${3:-30}
    local delay=${4:-5}
    local actual_image_id index

    for ((index = 1; index <= attempts; index += 1)); do
        actual_image_id=$(
            podman container inspect --format '{{.Image}}' "$container" 2>/dev/null || true
        )
        if [[ $actual_image_id == "$expected_image_id" ]]; then
            return 0
        fi
        ((index == attempts)) || sleep "$delay"
    done
    log "container ${container} is not running expected image ${expected_image_id}"
    return 1
}

wait_for_https_health() {
    local hostname=$1
    local path=$2
    local attempts=${3:-30}
    local delay=${4:-5}
    local index

    for ((index = 1; index <= attempts; index += 1)); do
        if curl --head --fail --silent --show-error \
            --connect-timeout 5 --max-time 15 \
            --resolve "${hostname}:443:127.0.0.1" \
            "https://${hostname}${path}" >/dev/null; then
            return 0
        fi
        ((index == attempts)) || sleep "$delay"
    done
    log "HTTPS health check did not pass for https://${hostname}${path}"
    return 1
}

wait_for_website_deployment() {
    local expected_image_id=$1
    local attempts=${2:-30}
    local delay=${3:-5}

    wait_for_container_image josephduffy-co-uk "$expected_image_id" "$attempts" "$delay" &&
        wait_for_container_health josephduffy-co-uk "$attempts" "$delay" &&
        wait_for_https_health "$TRIAL_HOSTNAME" / "$attempts" "$delay"
}

wait_for_stack_health() {
    local expected_image_id=$1
    local attempts=${2:-30}
    local delay=${3:-5}

    wait_for_container_image josephduffy-co-uk "$expected_image_id" "$attempts" "$delay" &&
        wait_for_container_health josephduffy-co-uk "$attempts" "$delay" &&
        wait_for_container_health caddy "$attempts" "$delay" &&
        wait_for_https_health "$TRIAL_HOSTNAME" / "$attempts" "$delay"
}

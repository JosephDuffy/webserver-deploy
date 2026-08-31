#!/usr/bin/env bash

set -Eeuo pipefail
set +x
umask 077

bootstrap_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly bootstrap_dir
# shellcheck source=lib/common.sh
source "$bootstrap_dir/lib/common.sh"
# shellcheck source=lib/bootstrap-support.sh
source "$bootstrap_dir/lib/bootstrap-support.sh"

require_root
[[ $# -ge 1 && $# -le 5 ]] ||
    die "usage: bootstrap.sh <commit> [tailscale-auth-key-file] [environment-file] [github-token-file] [swift-environment-file]"
validate_commit "$1" || die "invalid webserver-deploy commit"
readonly commit=$1
readonly tailscale_auth_key_file=${2:-"$bootstrap_dir/tailscale-auth-key"}
readonly supplied_env_file=${3:-"$bootstrap_dir/josephduffy-co-uk.env"}
readonly github_token_file=${4:-"$bootstrap_dir/github-attestation-token"}
readonly supplied_swift_env_file=${5:-"$bootstrap_dir/josephduffy-co-uk-swift.env"}

require_supported_host
# Fail before installing packages or changing access if no real environment exists.
load_deployment_target "$PRIMARY_DEPLOYMENT_TARGET"
readonly primary_env_file=$DEPLOY_ENV_FILE
selected_env_file=$(select_bootstrap_environment "$primary_env_file" "$supplied_env_file")
readonly selected_env_file

install_missing_packages() {
    local packages=(
        aardvark-dns
        ca-certificates
        curl
        gnupg
        gzip
        jq
        netavark
        openssh-server
        podman
        runc
        sudo
        tar
        iptables
        unattended-upgrades
        util-linux
    )
    local missing=()
    local package

    for package in "${packages[@]}"; do
        dpkg-query --show --showformat='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii ' || missing+=("$package")
    done
    if ((${#missing[@]} > 0)); then
        log "installing missing Ubuntu packages: ${missing[*]}"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends "${missing[@]}"
    fi
}

install_github_cli() {
    if command -v gh >/dev/null 2>&1 && gh attestation verify --help >/dev/null 2>&1; then
        return
    fi
    log "installing GitHub CLI from its signed apt repository"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        --output /usr/share/keyrings/githubcli-archive-keyring.gpg
    chmod 0644 /usr/share/keyrings/githubcli-archive-keyring.gpg
    install -o root -g root -m 0644 "$bootstrap_dir/host/github-cli.list" /etc/apt/sources.list.d/github-cli.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends gh
}

install_tailscale() {
    if command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1; then
        if dpkg --compare-versions "$(tailscale version | sed -n '1p')" ge 1.90.1; then
            return
        fi
    fi
    log "installing Tailscale from its signed apt repository"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
        --output /usr/share/keyrings/tailscale-archive-keyring.gpg
    chmod 0644 /usr/share/keyrings/tailscale-archive-keyring.gpg
    install -o root -g root -m 0644 "$bootstrap_dir/host/tailscale.list" /etc/apt/sources.list.d/tailscale.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends tailscale
}

create_deployment_user() {
    local user=$1
    local home="/var/lib/$user"

    if ! id "$user" >/dev/null 2>&1; then
        useradd --create-home --home-dir "$home" --shell /bin/bash --user-group "$user"
    fi
    usermod --shell /bin/bash --groups '' "$user"
    passwd --lock "$user" >/dev/null
    install -d -o "$user" -g "$user" -m 0700 "$home/.ssh"
    install -o "$user" -g "$user" -m 0600 /dev/null "$home/.ssh/authorized_keys"
}

install_missing_packages
install_github_cli
install_tailscale

require_runtime_capabilities

systemctl enable --now tailscaled.service unattended-upgrades.service

create_deployment_user webserver-image-deploy
create_deployment_user webserver-config-deploy

install -d -o root -g root -m 0755 /opt/webserver "$RELEASE_ROOT" /etc/webserver "$QUADLET_DIR"
install -d -o root -g root -m 0700 "$STATE_DIR"
install_bootstrap_environment "$selected_env_file" "$primary_env_file"
chown root:root "$primary_env_file"
load_deployment_target josephduffy-co-uk-swift
install_optional_bootstrap_environment "$DEPLOY_ENV_FILE" "$supplied_swift_env_file"
if [[ -f $DEPLOY_ENV_FILE ]]; then
    chown root:root "$DEPLOY_ENV_FILE"
fi

target="$RELEASE_ROOT/$commit"
if [[ ! -e $target ]]; then
    release_staging=$(mktemp -d "$RELEASE_ROOT/.${commit}.XXXXXX")
    cleanup_release_staging() {
        if [[ -n $release_staging ]]; then
            rm -rf "$release_staging"
        fi
    }
    trap cleanup_release_staging EXIT
    copy_bootstrap_release "$bootstrap_dir" "$release_staging"
    chown -R root:root "$release_staging"
    "$release_staging/scripts/validate-release" "$release_staging"
    mv "$release_staging" "$target"
    release_staging=''
fi
"$target/scripts/validate-release" "$target"
configuration_changed=true
if [[ -L $CURRENT_RELEASE && $(readlink -f "$CURRENT_RELEASE") == "$target" ]]; then
    configuration_changed=false
fi
atomic_symlink "$target" "$CURRENT_RELEASE"
install_managed_files "$target"
visudo -cf /etc/sudoers.d/webserver-deploy
authenticate_tailscale "$tailscale_auth_key_file"

systemctl daemon-reload
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active$'; then
    log "disabling UFW; Oracle platform-image rules are retained and the managed firewall takes over"
    ufw --force disable
fi
systemctl start webserver-network.service
podman network inspect webserver | jq --exit-status \
    --arg subnet "$WEBSERVER_NETWORK_SUBNET" \
    --arg gateway "$WEBSERVER_NETWORK_GATEWAY" \
    '.[0].subnets | any(.subnet == $subnet and .gateway == $gateway)' >/dev/null ||
    die "the existing webserver Podman network has unexpected addressing; bootstrap update required"

if [[ -f $STATE_DIR/ssh-locked-down ]]; then
    sshd_configuration="$target/host/sshd_config.locked-down"
else
    sshd_configuration="$target/host/sshd_config.transitional"
fi
install -o root -g root -m 0644 "$sshd_configuration" /etc/ssh/sshd_config.d/60-webserver.conf
/usr/sbin/sshd -t
systemctl disable --now ssh.socket >/dev/null 2>&1 || true
systemctl enable --now ssh.service
systemctl reload ssh.service

podman network reload --all || die "failed to restore Podman networking rules"
systemctl enable webserver-firewall.service
systemctl restart webserver-firewall.service

podman pull "$CADDY_IMAGE"
[[ $(image_platform "$CADDY_IMAGE") == linux/arm64 ]] || die "the pinned Caddy image is not linux/arm64"

migrate_legacy_image_state
load_deployment_target "$PRIMARY_DEPLOYMENT_TARGET"
if ! podman image exists "$DEPLOY_LOCAL_IMAGE"; then
    verify_attestation \
        "$DEPLOY_REPOSITORY" "$DEPLOY_IMAGE" "$DEPLOY_SEED_DIGEST" "$github_token_file"
    seed_reference="${DEPLOY_IMAGE}@${DEPLOY_SEED_DIGEST}"
    podman pull "$seed_reference"
    [[ $(image_platform "$seed_reference") == linux/arm64 ]] ||
        die "the seed website image is not linux/arm64"
    podman tag "$seed_reference" "$DEPLOY_LOCAL_IMAGE"
    mkdir -p "$DEPLOY_STATE_DIR"
    printf '%s\n' "$DEPLOY_SEED_DIGEST" >"$DEPLOY_STATE_DIR/current-digest"
    chmod 0600 "$DEPLOY_STATE_DIR/current-digest"
fi
enable_deployment_target

if [[ $configuration_changed == true ]]; then
    service_action=restart
else
    service_action=start
fi
readonly service_action

declare -A enabled_image_ids=()
enabled_services=()
enabled_journal_arguments=()
while IFS= read -r deployment_target_name; do
    load_deployment_target "$deployment_target_name"
    deployment_target_is_enabled || continue
    [[ -f $DEPLOY_ENV_FILE && -s $DEPLOY_ENV_FILE && ! -L $DEPLOY_ENV_FILE ]] ||
        die "missing environment for enabled target ${deployment_target_name}"
    podman image exists "$DEPLOY_LOCAL_IMAGE" ||
        die "missing promoted image for enabled target ${deployment_target_name}"
    enabled_image_ids["$deployment_target_name"]=$(
        podman image inspect --format '{{.Id}}' "$DEPLOY_LOCAL_IMAGE"
    )
    enabled_services+=("$DEPLOY_SERVICE")
    enabled_journal_arguments+=(--unit "$DEPLOY_SERVICE")
done < <(deployment_targets)

stop_stack_and_report_journal() {
    systemctl stop caddy.service "${enabled_services[@]}" >/dev/null 2>&1 || true
    journalctl \
        "${enabled_journal_arguments[@]}" \
        --unit caddy.service \
        --boot \
        --lines 100 \
        --no-pager \
        --output cat >&2 || true
}

if ! systemctl "$service_action" "${enabled_services[@]}" caddy.service; then
    stop_stack_and_report_journal
    die "failed to ${service_action} the website stack"
fi

while IFS= read -r deployment_target_name; do
    [[ -n ${enabled_image_ids[$deployment_target_name]:-} ]] || continue
    load_deployment_target "$deployment_target_name"
    if ! wait_for_container_image \
        "$DEPLOY_CONTAINER" "${enabled_image_ids[$deployment_target_name]}" 6 5 ||
        ! wait_for_container_health "$DEPLOY_CONTAINER" 6 5; then
        stop_stack_and_report_journal
        die "target ${deployment_target_name} failed its internal health checks"
    fi
done < <(deployment_targets)
if ! wait_for_container_health caddy 6 5; then
    stop_stack_and_report_journal
    die "Caddy failed its internal health check"
fi

printf '%s\n' "$commit" >"$STATE_DIR/current-config-commit"
chmod 0600 "$STATE_DIR/current-config-commit"
record_history "bootstrap reconciled ${commit}"

while IFS= read -r deployment_target_name; do
    [[ -n ${enabled_image_ids[$deployment_target_name]:-} ]] || continue
    load_deployment_target "$deployment_target_name"
    if wait_for_https_health "$DEPLOY_HOSTNAME" "$DEPLOY_HEALTH_PATH" 6 5; then
        log "bootstrap complete; ${DEPLOY_HOSTNAME} is healthy"
    else
        log "bootstrap complete and ${deployment_target_name} is internally healthy, but HTTPS is not ready yet"
    fi
done < <(deployment_targets)
log "do not remove public SSH yet; follow README.md and then run webserver-lock-down-ssh"

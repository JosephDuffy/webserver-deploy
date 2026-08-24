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
[[ $# -ge 1 && $# -le 4 ]] ||
    die "usage: bootstrap.sh <commit> [tailscale-auth-key-file] [environment-file] [github-token-file]"
validate_commit "$1" || die "invalid webserver-deploy commit"
readonly commit=$1
readonly tailscale_auth_key_file=${2:-"$bootstrap_dir/tailscale-auth-key"}
readonly supplied_env_file=${3:-"$bootstrap_dir/josephduffy-co-uk.env"}
readonly github_token_file=${4:-"$bootstrap_dir/github-attestation-token"}

require_supported_host
# Fail before installing packages or changing access if no real environment exists.
selected_env_file=$(select_bootstrap_environment "$ENV_FILE" "$supplied_env_file")
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
install_bootstrap_environment "$selected_env_file" "$ENV_FILE"
chown root:root "$ENV_FILE"

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

if ! podman image exists "$WEBSITE_LOCAL_IMAGE"; then
    verify_attestation "$WEBSITE_SEED_DIGEST" "$github_token_file"
    seed_reference="${WEBSITE_IMAGE}@${WEBSITE_SEED_DIGEST}"
    podman pull "$seed_reference"
    [[ $(image_platform "$seed_reference") == linux/arm64 ]] || die "the seed website image is not linux/arm64"
    podman tag "$seed_reference" "$WEBSITE_LOCAL_IMAGE"
    printf '%s\n' "$WEBSITE_SEED_DIGEST" >"$STATE_DIR/current-digest"
    chmod 0600 "$STATE_DIR/current-digest"
fi
website_image_id=$(podman image inspect --format '{{.Id}}' "$WEBSITE_LOCAL_IMAGE")
readonly website_image_id

if [[ $configuration_changed == true ]]; then
    service_action=restart
else
    service_action=start
fi
readonly service_action

stop_stack_and_report_journal() {
    systemctl stop caddy.service josephduffy-co-uk.service >/dev/null 2>&1 || true
    journalctl \
        --unit josephduffy-co-uk.service \
        --unit caddy.service \
        --boot \
        --lines 100 \
        --no-pager \
        --output cat >&2 || true
}

if ! systemctl "$service_action" josephduffy-co-uk.service caddy.service; then
    stop_stack_and_report_journal
    die "failed to ${service_action} the website stack"
fi

if ! wait_for_container_image josephduffy-co-uk "$website_image_id" 6 5 ||
    ! wait_for_container_health josephduffy-co-uk 6 5 ||
    ! wait_for_container_health caddy 6 5; then
    stop_stack_and_report_journal
    die "website stack failed its internal health checks"
fi

printf '%s\n' "$commit" >"$STATE_DIR/current-config-commit"
chmod 0600 "$STATE_DIR/current-config-commit"
record_history "bootstrap reconciled ${commit}"

if wait_for_https_health "$TRIAL_HOSTNAME" / 6 5; then
    log "bootstrap complete; ${TRIAL_HOSTNAME} is healthy"
else
    log "bootstrap complete and containers are healthy, but HTTPS is not ready yet (DNS, secrets, and ACME may still need configuration)"
fi
log "do not remove public SSH yet; follow README.md and then run webserver-lock-down-ssh"

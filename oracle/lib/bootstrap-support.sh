#!/usr/bin/env bash

# Sourced only by bootstrap and its tests, never by routine deployments.
select_bootstrap_environment() {
    local destination=$1
    local supplied=$2
    local selected

    if [[ -e $destination || -L $destination ]]; then
        selected=$destination
    else
        selected=$supplied
    fi
    [[ -f $selected && -s $selected && -r $selected && ! -L $selected ]] ||
        die "provide a nonempty josephduffy-co-uk.env file, or retain the existing server environment file"
    printf '%s\n' "$selected"
}

install_bootstrap_environment() {
    local selected=$1
    local destination=$2
    if [[ $selected != "$destination" ]]; then
        install -m 0600 "$selected" "$destination"
    else
        chmod 0600 "$destination"
    fi
}

copy_bootstrap_release() {
    local source_directory=$1
    local destination=$2
    local files=(
        bootstrap.sh bootstrap-remote.sh Caddyfile README.md
        lib host quadlet scripts tests
    )
    local example_files=(josephduffy-co-uk.example.env)
    if [[ -f $source_directory/.shellcheckrc ]]; then
        files+=(.shellcheckrc)
    fi
    # Use an allowlist, not a recursive copy of the directory holding local secrets.
    tar --exclude='*.env' --exclude='*.key' --exclude='tailscale-auth-key*' \
        --exclude='github-attestation-token*' \
        --exclude='._*' --exclude='.DS_Store' \
        -C "$source_directory" -cf - "${files[@]}" | tar -C "$destination" -xf -
    local example_file
    for example_file in "${example_files[@]}"; do
        [[ -f $source_directory/$example_file && ! -L $source_directory/$example_file ]] ||
            die "missing or unsafe bootstrap example: $example_file"
        install -m 0644 "$source_directory/$example_file" "$destination/$example_file"
    done
}

authenticate_tailscale() (
    # The key is never read into a shell variable or placed in a process argument.
    set +x
    local key_file=$1
    local status state attempt
    for ((attempt = 0; attempt < 15; attempt += 1)); do
        status=$(tailscale status --json 2>/dev/null || true)
        state=$(printf '%s' "$status" | jq -r '.BackendState // empty') || die "cannot read Tailscale status"
        [[ $state == Starting ]] || break
        sleep 1
    done

    case "$state" in
        Running|Stopped)
            # Preserve the existing identity and do not consume another auth key.
            tailscale set --ssh --hostname=webserver-oracle
            if [[ $state == Stopped ]]; then
                timeout 60 tailscale up
            fi
            ;;
        NoState|NeedsLogin)
            [[ -f $key_file && -s $key_file && -r $key_file && ! -L $key_file ]] ||
                die "Tailscale authentication required: supply a readable auth-key file (not a key argument)"
            local private_key
            private_key=$(mktemp /run/webserver-tailscale.XXXXXX)
            trap 'rm -f -- "$private_key"' EXIT
            install -m 0600 "$key_file" "$private_key"
            tailscale up --auth-key="file:$private_key" --timeout=60s \
                --ssh --hostname=webserver-oracle --advertise-tags=tag:webserver
            ;;
        NeedsMachineAuth)
            die "approve the server in the Tailscale admin console before retrying bootstrap"
            ;;
        *)
            die "Tailscale is not ready for bootstrap (state: ${state:-unknown})"
            ;;
    esac
    status=$(tailscale status --json 2>/dev/null || true)
    [[ $(printf '%s' "$status" | jq -r '.BackendState // empty') == Running ]] ||
        die "Tailscale did not become ready; check device approval and tag permissions"
    printf '%s' "$status" |
        jq -e '(.Self.Tags // []) | index("tag:webserver") != null' >/dev/null ||
        die "Tailscale node is missing tag:webserver; correct its tags before retrying bootstrap"
)

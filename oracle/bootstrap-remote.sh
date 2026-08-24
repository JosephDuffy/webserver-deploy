#!/usr/bin/env bash

set -Eeuo pipefail
set +x
umask 077
# Prevent macOS archive tools from serializing extended attributes as AppleDouble files or
# LIBARCHIVE.xattr headers. Those attributes are not part of the committed release.
export COPYFILE_DISABLE=1

bootstrap_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly bootstrap_dir
# shellcheck source=lib/common.sh
source "$bootstrap_dir/lib/common.sh"

[[ $# -ge 1 && $# -le 3 ]] ||
    die "usage: bootstrap-remote.sh <ssh-destination> [tailscale-auth-key-file] [github-token-file]"
readonly ssh_destination=$1
tailscale_auth_key_file=${2:-"$bootstrap_dir/tailscale-auth-key"}
if [[ -e $tailscale_auth_key_file || -L $tailscale_auth_key_file ]]; then
    key_directory=$(cd "$(dirname "$tailscale_auth_key_file")" && pwd -P)
    tailscale_auth_key_file="$key_directory/$(basename "$tailscale_auth_key_file")"
fi
readonly tailscale_auth_key_file
github_token_file=${3:-"$bootstrap_dir/github-attestation-token"}
if [[ -e $github_token_file || -L $github_token_file ]]; then
    token_directory=$(cd "$(dirname "$github_token_file")" && pwd -P)
    github_token_file="$token_directory/$(basename "$github_token_file")"
fi
readonly github_token_file
# Use an SSH config alias for the username, key and port. Do not accept SSH options
# or shell syntax through the destination argument.
[[ $ssh_destination =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]] || die "invalid SSH destination; use an SSH config alias"

repository_root=$(git -C "$bootstrap_dir" rev-parse --show-toplevel)
commit=$(git -C "$repository_root" rev-parse --verify HEAD)
validate_commit "$commit" || die "invalid local Git commit"
git -C "$repository_root" diff --quiet "$commit" -- oracle ||
    die "commit the Oracle bundle changes before bootstrapping; the release must match its commit"
[[ -z $(git -C "$repository_root" ls-files --others --exclude-standard -- oracle) ]] ||
    die "commit or ignore untracked Oracle files before bootstrapping"

if [[ $# -eq 2 ]]; then
    [[ -f $tailscale_auth_key_file && -s $tailscale_auth_key_file && ! -L $tailscale_auth_key_file ]] ||
        die "the auth-key argument must name a nonempty regular file, not contain the key"
fi
if [[ $# -eq 3 ]]; then
    [[ -f $github_token_file && -s $github_token_file && ! -L $github_token_file ]] ||
        die "the GitHub token argument must name a nonempty regular file, not contain the token"
fi
while IFS= read -r tracked_file; do
    tracked_name=${tracked_file##*/}
    case "$tracked_name" in
        tailscale-auth-key*|github-attestation-token*)
            die "bootstrap secrets must not be committed to Git"
            ;;
        *.example.env|*.example.key)
            ;;
        *.env|*.key)
            die "bootstrap secrets must not be committed to Git"
            ;;
    esac
done < <(git -C "$repository_root" ls-tree -r --name-only "$commit" -- oracle)

temporary_root=$(mktemp -d)
cleanup() { rm -rf -- "$temporary_root"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Only committed deployment code is transferred, never .git or the working tree.
git -C "$repository_root" archive --format=tar "$commit" oracle |
    tar --no-xattrs -C "$temporary_root" -xf -
mkdir -m 0700 "$temporary_root/bootstrap-input"
printf '%s\n' "$commit" >"$temporary_root/bootstrap-input/commit"
for input in \
    "$bootstrap_dir/josephduffy-co-uk.env" \
    "$tailscale_auth_key_file" \
    "$github_token_file"; do
    if [[ -e $input || -L $input ]]; then
        [[ -f $input && -s $input && -r $input && ! -L $input ]] || die "bootstrap inputs must be nonempty readable regular files"
        if git -C "$repository_root" ls-files --error-unmatch -- "$input" >/dev/null 2>&1; then
            die "bootstrap inputs must not be tracked by Git"
        fi
    fi
done
if [[ -f $bootstrap_dir/josephduffy-co-uk.env ]]; then
    install -m 0600 "$bootstrap_dir/josephduffy-co-uk.env" "$temporary_root/bootstrap-input/josephduffy-co-uk.env"
fi
if [[ -f $tailscale_auth_key_file ]]; then
    install -m 0600 "$tailscale_auth_key_file" "$temporary_root/bootstrap-input/tailscale-auth-key"
fi
if [[ -f $github_token_file ]]; then
    install -m 0600 "$github_token_file" "$temporary_root/bootstrap-input/github-attestation-token"
fi

# The script is fixed; the commit and secrets are files inside the encrypted stdin
# stream. sudo never receives secret values as arguments or environment variables.
read -r -d '' remote_command <<'REMOTE' || true
sudo -n /bin/bash -c '
set -Eeuo pipefail
set +x
umask 077
temporary_root=$(mktemp -d /var/tmp/webserver-bootstrap.XXXXXX)
cleanup() { rm -rf -- "$temporary_root"; }
trap cleanup EXIT
trap "exit 130" INT
trap "exit 143" TERM HUP
tar --extract --gzip --no-same-owner --file - --directory "$temporary_root"
commit=$(<"$temporary_root/bootstrap-input/commit")
bash "$temporary_root/oracle/bootstrap.sh" "$commit" \
    "$temporary_root/bootstrap-input/tailscale-auth-key" \
    "$temporary_root/bootstrap-input/josephduffy-co-uk.env" \
    "$temporary_root/bootstrap-input/github-attestation-token"
'
REMOTE

log "bootstrapping ${ssh_destination} with committed Oracle bundle ${commit}"
tar --no-xattrs --exclude='._*' --exclude='.DS_Store' \
    -C "$temporary_root" -czf - oracle bootstrap-input |
    ssh -T -o StrictHostKeyChecking=yes -- "$ssh_destination" "$remote_command"

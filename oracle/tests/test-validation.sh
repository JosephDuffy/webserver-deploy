#!/usr/bin/env bash

set -Eeuo pipefail

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly test_dir
oracle_dir=$(cd "$test_dir/.." && pwd)
readonly oracle_dir
# shellcheck disable=SC1091
source "$oracle_dir/lib/common.sh"
# shellcheck disable=SC1091
source "$oracle_dir/lib/image-transaction.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_accepts_digest() {
    validate_digest "$1" || fail "valid digest rejected: $1"
}

assert_rejects_digest() {
    if validate_digest "$1"; then
        fail "invalid digest accepted: $1"
    fi
}

assert_accepts_commit() {
    validate_commit "$1" || fail "valid commit rejected: $1"
}

assert_rejects_commit() {
    if validate_commit "$1"; then
        fail "invalid commit accepted: $1"
    fi
}

assert_accepts_digest 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
assert_rejects_digest 'sha256:0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef'
assert_rejects_digest 'latest'
assert_rejects_digest 'sha256:../../etc/passwd'
assert_rejects_digest 'sha256:0123 extra'
if validate_digest; then fail 'digest validator accepted zero arguments'; fi
if validate_digest \
    'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' extra; then
    fail 'digest validator accepted multiple arguments'
fi

assert_accepts_commit '0123456789abcdef0123456789abcdef01234567'
assert_rejects_commit '0123456789ABCDEF0123456789abcdef01234567'
assert_rejects_commit 'main'
assert_rejects_commit '0123456789abcdef0123456789abcdef01234567 extra'
if validate_commit; then fail 'commit validator accepted zero arguments'; fi
if validate_commit '0123456789abcdef0123456789abcdef01234567' extra; then
    fail 'commit validator accepted multiple arguments'
fi

health_calls=()
# These test doubles are called indirectly by functions in the sourced libraries.
# shellcheck disable=SC2317,SC2329
podman() {
    health_calls+=("podman $*")
    case "$*" in
        'container inspect --format {{.Image}} website') printf '%s\n' 'sha256:expected-image' ;;
        'healthcheck run website'|'healthcheck run caddy') return 0 ;;
        *) return 1 ;;
    esac
}
curl() {
    health_calls+=("curl $*")
    return 0
}

wait_for_container_image website sha256:expected-image 1 0 ||
    fail 'expected container image was not accepted'
if wait_for_container_image website sha256:different-image 1 0 >/dev/null; then
    fail 'unexpected container image was accepted'
fi
wait_for_container_health website 1 0 || fail 'successful container health check was not accepted'
wait_for_container_health caddy 1 0 || fail 'successful Caddy health check was not accepted'
wait_for_https_health example.com /ready 1 0 ||
    fail 'successful HTTPS health check was not accepted'
[[ ${health_calls[0]} == 'podman healthcheck run website' ]] ||
    fail 'container health did not execute the configured Podman health check'
[[ ${health_calls[1]} == 'podman healthcheck run caddy' ]] ||
    fail 'Caddy health did not execute the configured Podman health check'
https_call=${health_calls[2]}
[[ $https_call == *'--head'* ]] || fail 'HTTPS health did not make a HEAD request'
[[ $https_call == *'--resolve example.com:443:127.0.0.1 https://example.com/ready' ]] ||
    fail 'HTTPS health did not make a local end-to-end HEAD request'

calls=()
# These test doubles are called indirectly by restore_previous_image.
# shellcheck disable=SC2317,SC2329
podman() { calls+=("podman $*"); }
# shellcheck disable=SC2317,SC2329
systemctl() { calls+=("systemctl $*"); }
# shellcheck disable=SC2317,SC2329
wait_for_website_deployment() { calls+=("wait_for_website_deployment $*"); return 1; }

restore_previous_image 'sha256:previous-image-id'
[[ ${calls[0]} == "podman tag sha256:previous-image-id $WEBSITE_LOCAL_IMAGE" ]] ||
    fail "rollback did not restore the prior tag"
[[ ${calls[1]} == 'systemctl restart josephduffy-co-uk.service' ]] ||
    fail "rollback did not restart the website"
[[ ${calls[2]} == 'wait_for_website_deployment sha256:previous-image-id 12 5' ]] ||
    fail "rollback did not recheck the restored image"

calls=()
restore_previous_image ''
[[ ${calls[0]} == 'systemctl stop josephduffy-co-uk.service' ]] ||
    fail "empty-state rollback did not stop the website"

printf 'Validation and rollback tests passed.\n'

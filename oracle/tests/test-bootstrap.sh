#!/usr/bin/env bash

set -Eeuo pipefail
test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
oracle_dir=$(cd "$test_dir/.." && pwd)
# shellcheck source=../lib/common.sh
source "$oracle_dir/lib/common.sh"
# shellcheck source=../lib/bootstrap-support.sh
source "$oracle_dir/lib/bootstrap-support.sh"
# shellcheck source=../lib/firewall.sh
source "$oracle_dir/lib/firewall.sh"

fixture_root=$(mktemp -d)
trap 'rm -rf -- "$fixture_root"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
must_fail() {
    if ("$@") >"$fixture_root/failure.log" 2>&1; then
        fail "unexpected success: $*"
    fi
}

mkdir -p "$fixture_root/server" "$fixture_root/input"
destination="$fixture_root/server/josephduffy-co-uk.env"
supplied="$fixture_root/input/josephduffy-co-uk.env"
must_fail select_bootstrap_environment "$destination" "$supplied"
printf 'TEST_SECRET=local\n' >"$supplied"
selected=$(select_bootstrap_environment "$destination" "$supplied")
[[ $selected == "$supplied" ]] || fail 'local environment not selected on fresh host'
install_bootstrap_environment "$selected" "$destination"
cmp -s "$supplied" "$destination" || fail 'local environment was not installed'
printf 'TEST_SECRET=changed-local\n' >"$supplied"
selected=$(select_bootstrap_environment "$destination" "$supplied")
[[ $selected == "$destination" ]] || fail 'existing server environment was not preserved'
install_bootstrap_environment "$selected" "$destination"
grep -qx 'TEST_SECRET=local' "$destination" || fail 'rerun overwrote server secrets'

ln -s "$destination" "$fixture_root/unsafe.env"
must_fail select_bootstrap_environment "$fixture_root/unsafe.env" "$supplied"

optional_destination="$fixture_root/server/josephduffy-co-uk-swift.env"
optional_supplied="$fixture_root/input/josephduffy-co-uk-swift.env"
install_optional_bootstrap_environment "$optional_destination" "$optional_supplied"
[[ ! -e $optional_destination ]] || fail 'absent optional environment created an empty server file'
printf 'SWIFT_SECRET=local\n' >"$optional_supplied"
install_optional_bootstrap_environment "$optional_destination" "$optional_supplied"
cmp -s "$optional_supplied" "$optional_destination" ||
    fail 'optional Swift environment was not installed'
printf 'SWIFT_SECRET=changed-local\n' >"$optional_supplied"
install_optional_bootstrap_environment "$optional_destination" "$optional_supplied"
grep -qx 'SWIFT_SECRET=local' "$optional_destination" ||
    fail 'rerun overwrote the optional server environment'

mkdir "$fixture_root/source" "$fixture_root/release"
copy_bootstrap_release "$oracle_dir" "$fixture_root/source"
[[ -f $fixture_root/source/josephduffy-co-uk.example.env ]] ||
    fail 'release omitted environment example'
[[ -f $fixture_root/source/josephduffy-co-uk-swift.example.env ]] ||
    fail 'release omitted Swift environment example'
printf 'secret' >"$fixture_root/source/josephduffy-co-uk.env"
printf 'secret' >"$fixture_root/source/tailscale-auth-key"
printf 'secret' >"$fixture_root/source/github-attestation-token"
printf 'secret' >"$fixture_root/source/other.key"
copy_bootstrap_release "$fixture_root/source" "$fixture_root/release"
[[ -f $fixture_root/release/josephduffy-co-uk.example.env ]] ||
    fail 'release omitted environment example'
[[ ! -e $fixture_root/release/josephduffy-co-uk.env ]] || fail 'release includes environment secrets'
[[ ! -e $fixture_root/release/tailscale-auth-key ]] || fail 'release includes the auth key'
[[ ! -e $fixture_root/release/github-attestation-token ]] ||
    fail 'release includes the GitHub token'
[[ ! -e $fixture_root/release/other.key ]] || fail 'release includes a key file'
bash "$oracle_dir/scripts/validate-release" "$fixture_root/release" --static
printf 'AppleDouble metadata' >"$fixture_root/release/lib/._common.sh"
must_fail bash "$oracle_dir/scripts/validate-release" "$fixture_root/release" --static
grep -q 'macOS filesystem metadata' "$fixture_root/failure.log" ||
    fail 'AppleDouble metadata did not produce a clear validation error'
rm "$fixture_root/release/lib/._common.sh"
must_fail bash "$oracle_dir/scripts/validate-release" "$fixture_root/source" --static

# shellcheck disable=SC2329
ip() {
    printf '%s\n' \
        '2606:4700:4700::1111 via fe80::1 dev enp0s6 src 2603:c020:c011:2500:6358:: metric 100'
}
require_public_ipv6_route
# shellcheck disable=SC2329
# shellcheck disable=SC2317
ip() {
    printf '%s\n' \
        '2606:4700:4700::1111 via fe80::1 dev enp0s6 src fd7a:115c:a1e0::1 metric 100'
}
must_fail require_public_ipv6_route
grep -q 'no global unicast source address' "$fixture_root/failure.log" ||
    fail 'a Tailscale-only IPv6 source was accepted as public IPv6'
unset -f ip

printf 'tskey-auth-fake-test-value\n' >"$fixture_root/key"
tailscale() {
    printf '%s\n' "$*" >>"$fixture_root/tailscale-calls"
    case "$1" in
        status)
            printf '{"BackendState":"%s","Self":{"Tags":%s}}\n' \
                "$(<"$fixture_root/tailscale-state")" \
                "${tailscale_tags:-[\"tag:webserver\"]}"
            ;;
        set) ;;
        up)
            local argument private_key=''
            for argument in "$@"; do
                case "$argument" in --auth-key=file:*) private_key=${argument#--auth-key=file:} ;; esac
            done
            if [[ -n $private_key ]]; then
                cmp -s "$private_key" "$fixture_root/key" || fail 'Tailscale did not receive the key file'
                [[ -n $(find "$private_key" -perm 0600 -print) ]] || fail 'auth-key permissions are not 0600'
            fi
            if [[ ${fail_auth:-false} == true ]]; then return 1; fi
            printf 'Running\n' >"$fixture_root/tailscale-state"
            ;;
        *) fail "unexpected Tailscale command: $*" ;;
    esac
}
mktemp() { command mktemp "$fixture_root/auth.XXXXXX"; }
timeout() { shift; "$@"; }

printf 'NeedsLogin\n' >"$fixture_root/tailscale-state"
authenticate_tailscale "$fixture_root/key"
grep -q 'up --auth-key=file:' "$fixture_root/tailscale-calls" || fail 'new node was not authenticated'
if grep -q 'tskey-auth-fake-test-value' "$fixture_root/tailscale-calls"; then fail 'auth key leaked into argv'; fi
[[ -z $(find "$fixture_root" -name 'auth.*' -print) ]] || fail 'temporary auth key was not removed'
printf '' >"$fixture_root/tailscale-calls"
authenticate_tailscale "$fixture_root/nonexistent-key"
if grep -q '^up' "$fixture_root/tailscale-calls"; then fail 'rerun consumed an auth key'; fi
grep -qx 'set --ssh --hostname=webserver-oracle' "$fixture_root/tailscale-calls" ||
    fail 'rerun did not reconcile mutable Tailscale preferences'
if grep -q -- '--advertise-tags' "$fixture_root/tailscale-calls"; then
    fail 'rerun attempted to change tags using tailscale set'
fi
printf 'Stopped\n' >"$fixture_root/tailscale-state"
authenticate_tailscale "$fixture_root/nonexistent-key"
printf 'NeedsLogin\n' >"$fixture_root/tailscale-state"
must_fail authenticate_tailscale "$fixture_root/nonexistent-key"
fail_auth=true
must_fail authenticate_tailscale "$fixture_root/key"
[[ -z $(find "$fixture_root" -name 'auth.*' -print) ]] || fail 'failed authentication left a key behind'
unset fail_auth
printf 'Running\n' >"$fixture_root/tailscale-state"
tailscale_tags='[]'
must_fail authenticate_tailscale "$fixture_root/nonexistent-key"
grep -q 'missing tag:webserver' "$fixture_root/failure.log" ||
    fail 'missing server tag did not produce a clear error'
unset tailscale_tags
unset -f tailscale mktemp timeout

gh() {
    [[ ${GH_TOKEN:-} == github_pat_test_attestation_token ]] ||
        fail 'GitHub token was not passed only through the environment'
    printf '%s\n' "$*" >"$fixture_root/gh-call"
}
printf 'github_pat_test_attestation_token\n' >"$fixture_root/github-token"
verify_attestation \
    'JosephDuffy/josephduffy.co.uk' \
    'ghcr.io/josephduffy/josephduffy.co.uk' \
    'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
    "$fixture_root/github-token"
grep -q '^attestation verify oci://' "$fixture_root/gh-call" || fail 'attestation was not verified'
printf 'github_pat_test_attestation_token\n' |
    verify_attestation_from_stdin \
        'JosephDuffy/josephduffy.co.uk' \
        'ghcr.io/josephduffy/josephduffy.co.uk' \
        'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
# Bash locals use dynamic scope. The image command's readonly digest must not collide with a local
# variable inside the shared attestation verifier.
(
    readonly digest='sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    printf 'github_pat_test_attestation_token\n' |
        verify_attestation_from_stdin \
            'JosephDuffy/josephduffy.co.uk' \
            'ghcr.io/josephduffy/josephduffy.co.uk' \
            "$digest"
)
must_fail verify_attestation \
    'JosephDuffy/josephduffy.co.uk' \
    'ghcr.io/josephduffy/josephduffy.co.uk' \
    'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
    "$fixture_root/missing-token"
printf 'first\nsecond\n' |
    must_fail verify_attestation_from_stdin \
        'JosephDuffy/josephduffy.co.uk' \
        'ghcr.io/josephduffy/josephduffy.co.uk' \
        'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
unset -f gh

firewall_calls=()
iptables() {
    firewall_calls+=("iptables $*")
    case " $* " in
        *' --list '*) return 1 ;;
        *' --check '*) return 1 ;;
    esac
}
ip6tables() {
    firewall_calls+=("ip6tables $*")
    case " $* " in
        *' --list '*) return 1 ;;
        *' --check '*) return 1 ;;
    esac
}

reconcile_webserver_firewall false
printf '%s\n' "${firewall_calls[@]}" >"$fixture_root/firewall-transitional"
expected_dns_rule='iptables --wait 10 --append WEBSERVER_INPUT --source 10.90.0.0/24'
expected_dns_rule+=' --destination 10.90.0.1 --protocol udp --destination-port 53 --jump ACCEPT'
expected_caddy_rule='iptables --wait 10 --append WEBSERVER_FORWARD'
expected_caddy_rule+=' --destination 10.90.0.0/24 --protocol tcp --match multiport'
expected_caddy_rule+=' --destination-ports 80,443 --jump ACCEPT'
expected_caddy_reply='iptables --wait 10 --append WEBSERVER_FORWARD --source 10.90.0.0/24'
expected_caddy_reply+=' --match conntrack --ctstate RELATED,ESTABLISHED --jump ACCEPT'
expected_ssh_allow='iptables --wait 10 --append WEBSERVER_INPUT'
expected_ssh_allow+=' --protocol tcp --destination-port 22 --jump ACCEPT'
expected_ipv6_dns_rule='ip6tables --wait 10 --append WEBSERVER_INPUT'
expected_ipv6_dns_rule+=' --source fd9d:7a3b:6f2c:1::/64'
expected_ipv6_dns_rule+=' --destination fd9d:7a3b:6f2c:1::1'
expected_ipv6_dns_rule+=' --protocol udp --destination-port 53 --jump ACCEPT'
expected_dhcpv6_rule='ip6tables --wait 10 --append WEBSERVER_INPUT --source fe80::/10'
expected_dhcpv6_rule+=' --protocol udp --source-port 547 --destination-port 546 --jump ACCEPT'
expected_ipv6_caddy_rule='ip6tables --wait 10 --append WEBSERVER_FORWARD'
expected_ipv6_caddy_rule+=' --destination fd9d:7a3b:6f2c:1::/64 --protocol tcp'
expected_ipv6_caddy_rule+=' --match multiport --destination-ports 80,443 --jump ACCEPT'
expected_ipv6_reply='ip6tables --wait 10 --append WEBSERVER_FORWARD'
expected_ipv6_reply+=' --source fd9d:7a3b:6f2c:1::/64 --match conntrack'
expected_ipv6_reply+=' --ctstate RELATED,ESTABLISHED --jump ACCEPT'
grep -Fq \
    'iptables --wait 10 --insert INPUT 1 --jump WEBSERVER_INPUT' \
    "$fixture_root/firewall-transitional" || fail 'managed INPUT chain was not inserted first'
grep -Fq "$expected_dns_rule" \
    "$fixture_root/firewall-transitional" || fail 'Aardvark UDP DNS was not allowed'
grep -Fq "$expected_caddy_rule" \
    "$fixture_root/firewall-transitional" || fail 'published Caddy TCP ports were not allowed'
grep -Fq "$expected_ssh_allow" \
    "$fixture_root/firewall-transitional" || fail 'transitional public SSH was not allowed'
grep -Fq "$expected_caddy_reply" \
    "$fixture_root/firewall-transitional" || fail 'published Caddy replies were not allowed'
grep -Fq 'iptables --wait 10 --policy INPUT DROP' "$fixture_root/firewall-transitional" ||
    fail 'IPv4 INPUT policy was not set to DROP'
grep -Fq \
    'ip6tables --wait 10 --insert FORWARD 1 --jump WEBSERVER_FORWARD' \
    "$fixture_root/firewall-transitional" ||
    fail 'managed IPv6 FORWARD chain was not inserted first'
grep -Fq "$expected_dhcpv6_rule" \
    "$fixture_root/firewall-transitional" || fail 'DHCPv6 replies were not allowed'
grep -Fq "$expected_ipv6_dns_rule" \
    "$fixture_root/firewall-transitional" || fail 'IPv6 Aardvark UDP DNS was not allowed'
grep -Fq "$expected_ipv6_caddy_rule" \
    "$fixture_root/firewall-transitional" || fail 'published Caddy IPv6 TCP ports were not allowed'
grep -Fq "$expected_ipv6_reply" \
    "$fixture_root/firewall-transitional" || fail 'published Caddy IPv6 replies were not allowed'
grep -Fq 'ip6tables --wait 10 --policy FORWARD DROP' "$fixture_root/firewall-transitional" ||
    fail 'IPv6 FORWARD policy was not set to DROP'

firewall_calls=()
reconcile_webserver_firewall true
printf '%s\n' "${firewall_calls[@]}" >"$fixture_root/firewall-locked"
expected_ssh_drop='iptables --wait 10 --append WEBSERVER_INPUT ! --in-interface tailscale0'
expected_ssh_drop+=' --protocol tcp --destination-port 22 --jump DROP'
grep -Fq "$expected_ssh_drop" \
    "$fixture_root/firewall-locked" || fail 'locked-down public SSH was not dropped'
if grep -Fq "$expected_ssh_allow" "$fixture_root/firewall-locked"; then
    fail 'locked-down firewall retained its transitional public SSH allowance'
fi
unset -f iptables ip6tables

# Bash locals use dynamic scope. The service caller's readonly state variable must not collide
# with a local variable inside the firewall library.
(
    readonly locked_down=false
    iptables() {
        case " $* " in
            *' --list '*) return 1 ;;
            *' --check '*) return 1 ;;
        esac
    }
    ip6tables() {
        case " $* " in
            *' --list '*) return 1 ;;
            *' --check '*) return 1 ;;
        esac
    }
    reconcile_webserver_firewall "$locked_down"
)

# Exercise the actual remote launcher with a temporary repository and fake SSH.
# No server, credentials, system services, or root privileges are needed.
repository="$fixture_root/repository"
mkdir -p "$repository/oracle" "$fixture_root/bin" "$fixture_root/payload" "$fixture_root/scratch"
copy_bootstrap_release "$oracle_dir" "$repository/oracle"
printf '%s\n' \
    'oracle/*.env' \
    '!oracle/*.example.env' \
    'oracle/*.key' \
    '!oracle/*.example.key' \
    'oracle/tailscale-auth-key*' \
    'oracle/github-attestation-token*' >"$repository/.gitignore"
git init --quiet "$repository"
git -C "$repository" add .
git -C "$repository" -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit --quiet -m fixture
expected_commit=$(git -C "$repository" rev-parse HEAD)
install -m 0755 "$test_dir/fixtures/ssh.sh" "$fixture_root/bin/ssh"
export PATH="$fixture_root/bin:$PATH"
export TMPDIR="$fixture_root/scratch"
export BOOTSTRAP_TEST_SSH_ARGS="$fixture_root/ssh-args"
export BOOTSTRAP_TEST_PAYLOAD="$fixture_root/payload"
printf 'TEST_SECRET=transport\n' >"$repository/oracle/josephduffy-co-uk.env"
printf 'SWIFT_SECRET=transport\n' >"$repository/oracle/josephduffy-co-uk-swift.env"
install -m 0600 "$fixture_root/key" "$repository/oracle/tailscale-auth-key"
install -m 0600 "$fixture_root/github-token" "$repository/oracle/github-attestation-token"
bash "$repository/oracle/bootstrap-remote.sh" admin@server-alias >"$fixture_root/remote.log" 2>&1
[[ $(<"$fixture_root/payload/bootstrap-input/commit") == "$expected_commit" ]] || fail 'wrong commit transferred'
[[ -f $fixture_root/payload/oracle/josephduffy-co-uk.example.env ]] ||
    fail 'example environment was rejected'
[[ -z $(find "$fixture_root/payload" \( -name '._*' -o -name '.DS_Store' \) -print) ]] ||
    fail 'macOS filesystem metadata was transferred'
[[ ! -e $fixture_root/payload/oracle/josephduffy-co-uk.env ]] || fail 'secret was placed in the release'
[[ ! -e $fixture_root/payload/.git ]] || fail '.git was uploaded'
cmp -s "$repository/oracle/josephduffy-co-uk.env" "$fixture_root/payload/bootstrap-input/josephduffy-co-uk.env" || fail 'environment was not uploaded'
cmp -s \
    "$repository/oracle/josephduffy-co-uk-swift.env" \
    "$fixture_root/payload/bootstrap-input/josephduffy-co-uk-swift.env" ||
    fail 'Swift environment was not uploaded'
cmp -s "$fixture_root/key" "$fixture_root/payload/bootstrap-input/tailscale-auth-key" || fail 'key was not uploaded'
cmp -s "$fixture_root/github-token" "$fixture_root/payload/bootstrap-input/github-attestation-token" ||
    fail 'GitHub token was not uploaded'
if grep -q \
    'tskey-auth-fake-test-value\|github_pat_test_attestation_token\|TEST_SECRET=transport\|SWIFT_SECRET=transport' \
    "$fixture_root/ssh-args" "$fixture_root/remote.log"; then
    fail 'secret leaked into SSH arguments or output'
fi
grep -qx 'StrictHostKeyChecking=yes' "$fixture_root/ssh-args" || fail 'SSH host checking was disabled'
[[ -z $(find "$fixture_root/scratch" -mindepth 1 -print) ]] || fail 'local staging was not cleaned'
BOOTSTRAP_TEST_SSH_STATUS=1 must_fail bash "$repository/oracle/bootstrap-remote.sh" server-alias
[[ -z $(find "$fixture_root/scratch" -mindepth 1 -print) ]] || fail 'failed SSH left staging behind'
must_fail bash "$repository/oracle/bootstrap-remote.sh" '-oProxyCommand=bad'
must_fail bash "$repository/oracle/bootstrap-remote.sh" 'host;echo bad'
must_fail bash "$repository/oracle/bootstrap-remote.sh" server-alias 'tskey-auth-raw-argument'
must_fail bash "$repository/oracle/bootstrap-remote.sh" \
    server-alias "$repository/oracle/tailscale-auth-key" 'github_pat_raw_argument'
printf '# dirty\n' >>"$repository/oracle/Caddyfile"
must_fail bash "$repository/oracle/bootstrap-remote.sh" server-alias
grep -q 'commit the Oracle bundle' "$fixture_root/failure.log" || fail 'dirty bundle was not rejected'
cp "$oracle_dir/Caddyfile" "$repository/oracle/Caddyfile"
printf 'untracked code' >"$repository/oracle/untracked.txt"
must_fail bash "$repository/oracle/bootstrap-remote.sh" server-alias
grep -q 'untracked Oracle files' "$fixture_root/failure.log" || fail 'untracked code was not rejected'
mv "$repository/oracle/untracked.txt" "$fixture_root/untracked.txt"
printf 'fake-secret' >"$repository/oracle/committed-secret.env"
git -C "$repository" add --force oracle/committed-secret.env
git -C "$repository" -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null commit --quiet -m secret-suffix-fixture
must_fail bash "$repository/oracle/bootstrap-remote.sh" server-alias
grep -q 'bootstrap secrets' "$fixture_root/failure.log" ||
    fail 'tracked environment secret was not rejected'
git -C "$repository" rm --quiet oracle/committed-secret.env
git -C "$repository" -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null commit --quiet -m remove-secret-suffix-fixture
printf 'fake-secret' >"$repository/oracle/nonstandard-secret-name"
git -C "$repository" add oracle/nonstandard-secret-name
git -C "$repository" -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit --quiet -m secret-fixture
(
    cd "$repository/oracle"
    must_fail bash bootstrap-remote.sh server-alias nonstandard-secret-name
)
grep -q 'must not be tracked' "$fixture_root/failure.log" || fail 'tracked key with a relative path was not rejected'

printf 'Bootstrap environment, authentication, and remote transport tests passed.\n'

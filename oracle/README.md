# ARM Deployment

This bundle provisions a web-only Ubuntu 24.04 ARM64 host. It uses rootful Podman Quadlets, a
pinned Caddy image, allow-listed attested application images, and two single-purpose deployment
identities. Routine deployments do not clone this repository and do not install host packages.

## Trust Boundaries

- The `webserver-image-deploy` user may run only the root-owned image deployment command.
- The `webserver-config-deploy` user may run only the root-owned configuration deployment command.
- Both accounts have locked passwords, empty `authorized_keys`, no supplementary groups, and no
  general sudo access. OpenSSH explicitly denies these accounts; Tailscale SSH authorizes them
  separately. Other administrator accounts are not hard-coded in this bundle.
- The image command accepts only an allow-listed target and `sha256:<64 lowercase hex>`. Each
  target maps to a fixed repository, image, local tag, service, hostname, environment file, and
  health endpoint in the root-owned deployment library.
- The configuration command accepts only a 40-character lowercase commit and downloads only that
  immutable public GitHub archive.
- The server is administered through a separate account, authenticated with a personal SSH key
  over a Tailscale connection on port 2222. Tailscale SSH on port 22 is reserved for workflows.

## First bootstrap

This repo assumes an Oracle cloud ARM instance with Ubuntu 24.04. Confirm serial-console
recovery access and initially retain public TCP/22. Do not expose TCP/2222, TCP/3000, or TCP/2019.
In the security list or NSG attached to the instance's VNIC, create separate stateful ingress rules
from `0.0.0.0/0` for destinations TCP/80, TCP/443, and UDP/443. Leave the source port as All; it is
the client's ephemeral port.

Assign one reserved global IPv6 address to the instance's VNIC, rather than assigning an IPv6
prefix. The subnet route table must send `::/0` to the Internet Gateway. In the same security list
or NSG, allow stateful ingress from `::/0` to TCP/80, TCP/443, and UDP/443, allow ICMPv6, and allow
egress to `::/0`. These rules are administered independently from the host firewall in this bundle.

Enable DHCPv6 and router advertisements for the primary interface before bootstrapping. Netplan
keeps Oracle's assigned `/128` on the host; the repository does not hard-code the public address:

```bash
interface=$(ip -4 route show default | awk 'NR == 1 { print $5 }')
sudo netplan set "ethernets.${interface}.dhcp6=true"
sudo netplan set "ethernets.${interface}.accept-ra=true"
sudo netplan try --timeout 120
sudo reboot
```

After reconnecting, confirm that the interface has a global address, the default route selects it,
and native IPv6 egress works:

```bash
interface=$(ip -4 route show default | awk 'NR == 1 { print $5 }')
ip -brief -6 address show dev "$interface"
ip -6 route get 2606:4700:4700::1111
curl --noproxy '*' -6 --fail --show-error https://api64.ipify.org
```

Bootstrap and routine deployments deliberately stop if the selected IPv6 route has only a
Tailscale address. Add DNS AAAA records only after the dual-stack configuration deployment succeeds
and both address families have been tested externally.

Configure a local SSH alias (for example, `bootstrap-server`) with your administrator account,
personal key, host and port. Verify its host key and normal SSH access first. Remote bootstrap
requires non-interactive `sudo` on the server, but **does not require local root**. It keeps strict
SSH host-key checking enabled and does not install any administrator key in GitHub Actions.

Prepare the ignored local environment file and fill in the real values:

```bash
cp oracle/josephduffy-co-uk.example.env oracle/josephduffy-co-uk.env
chmod 600 oracle/josephduffy-co-uk.env
```

The Swift service does not start until its first image deployment. If it needs environment values,
prepare its ignored file before that deployment; a nonempty comment-only file is sufficient when
the application does not currently need any variables:

```bash
cp oracle/josephduffy-co-uk-swift.example.env oracle/josephduffy-co-uk-swift.env
chmod 600 oracle/josephduffy-co-uk-swift.env
```

Create a short-lived, one-off, non-ephemeral Tailscale auth key authorized for `tag:webserver` and
save it in a file.

```bash
touch oracle/tailscale-auth-key
chmod 600 oracle/tailscale-auth-key
```

Configure the tailnet policy at [Access controls](https://console.tailscale.com/admin/acls/file) by
merging the contents of `tailscale-policy.example.hujson`.

Create two separate GitHub Actions OIDC federated identities at
[Trust credentials](https://console.tailscale.com/admin/settings/trust-credentials). For each one,
select **Credential**, **OpenID Connect**, and the **GitHub Actions** issuer. These are federated
identities rather than OAuth clients; no client secret is generated.

Create the configuration deployment identity with:

- Subject: `repo:JosephDuffy/webserver-deploy:ref:refs/heads/master`
- Custom claim: `workflow_ref`
- Custom claim value:
  `JosephDuffy/webserver-deploy/.github/workflows/oracle-config.yml@refs/heads/master`
- Scope: `auth_keys` write only
- Tag: `tag:webserver-config-deploy`

Store its generated Client ID and Audience in this repository's GitHub Actions secrets as
`TS_CONFIG_CLIENT_ID` and `TS_CONFIG_AUDIENCE`.

Create the image deployment identity with:

- Subject:
  `repo:JosephDuffy/josephduffy.co.uk:ref:refs/heads/<deployment-branch>`
- Custom claim: `job_workflow_ref`
- Custom claim value:
  `JosephDuffy/webserver-deploy/.github/workflows/deploy-image.yml@refs/heads/master`
- Scope: `auth_keys` write only
- Tag: `tag:webserver-image-deploy`

Replace `<deployment-branch>` with the branch in the website repository that calls the reusable
workflow. Generate the credential and copy its Client ID and Audience; no client secret or auth key
is generated. In the `JosephDuffy/josephduffy.co.uk` repository, open **Settings**, **Secrets and
variables**, **Actions**, and create these repository secrets:

- `TS_CLIENT_ID`: the generated Client ID.
- `TS_AUDIENCE`: the generated Audience.

The values identify the federated trust relationship rather than granting access by themselves,
but storing them as GitHub Actions secrets keeps them out of logs and matches the reusable
workflow's interface. The caller uses `@master`, while GitHub records the expanded
`@refs/heads/master` value in `job_workflow_ref`.

The configuration workflow is a normal workflow, so it is restricted by `workflow_ref`. The image
deployment runs through a reusable workflow, so it is additionally restricted by
`job_workflow_ref`.

Create a one-day fine-grained GitHub token using the
[pre-filled token form](https://github.com/settings/personal-access-tokens/new?name=Oracle+bootstrap+attestation&description=One-off+attestation+verification+for+Oracle+bootstrap&target_name=JosephDuffy&expires_in=1&attestations=read).
Select **Only select repositories**, choose `JosephDuffy/josephduffy.co.uk`, and confirm that its
only repository permission is **Attestations: Read-only**. Save the generated value in an ignored
local file:

```bash
touch oracle/github-attestation-token
chmod 600 oracle/github-attestation-token
```

The GitHub CLI can print its existing credential with `gh auth token`, but it cannot create a new
fine-grained token. Do not use the existing credential here because it is likely broader than the
one-repository, read-only bootstrap token.

```bash
./oracle/bootstrap-remote.sh \
  bootstrap-server \
  oracle/tailscale-auth-key \
  oracle/github-attestation-token
```

The second and third arguments are **file paths, never raw credentials**. They default to the two
ignored paths shown above. The Tailscale key may be absent when the server is already authenticated;
the GitHub token may be absent when the seeded website image already exists. Do not commit secrets,
including under other filenames.

The launcher refuses a dirty Oracle bundle, takes the commit from local `HEAD`, and sends a Git
archive of `oracle/` over SSH. It does not clone, push a Git branch, or transfer `.git`. Environment
and credential inputs travel separately in the encrypted stream and are extracted into a root-only
temporary directory on the server. The one-day GitHub token is used only to verify the seed image's
attestation. Temporary copies are removed on success or failure. Secrets are never copied into
versioned releases or included in SSH/sudo arguments. Source files remain on the device performing
the bootstrapping and can be deleted when the bootstrap is complete.

Bootstrap verifies Ubuntu 24.04 and `aarch64`, installs missing prerequisites, authenticates
Tailscale if necessary, and configures the managed services and access policies. The containers use
Ubuntu's packaged `runc` OCI runtime explicitly. This avoids a `crun` AppArmor profile-transition
problem on Ubuntu 24.04 while retaining `no-new-privileges`. An already authenticated node keeps its
identity without consuming another key. The managed node is named `webserver-oracle`, tagged
`tag:webserver`, and has Tailscale SSH enabled. The private Podman network may reach its local DNS
resolver and make outbound HTTP/HTTPS connections. A repository-owned firewall chain is evaluated
before Oracle's terminal platform-image rules. It preserves Oracle's metadata and iSCSI protections,
allows only the required Podman and Tailscale paths, and rejects other forwarded container traffic.
Bootstrap disables UFW if it was previously enabled because [Oracle warns that UFW can interfere
with the essential rules included in its Ubuntu platform images][oracle-platform-images].
Next.js generated pages use a bounded writable tmpfs; the application image and other paths remain
read-only.

The active Podman network is dual-stack. Containers receive addresses from `10.90.0.0/24` and a
repository-owned IPv6 ULA prefix; Netavark translates the IPv6 address through the host's assigned
global address. Caddy publishes TCP/80, TCP/443, and UDP/443 explicitly on both host address
families. The legacy IPv4-only `webserver` network retains `10.89.0.0/24` during this migration so
a failed configuration deployment can restore the previous release without recreating network
state or conflicting with the new bridge.

Bootstrap fails before package installation if an environment file is not on the device performing
the bootstrap or on the web server at `/etc/webserver/josephduffy-co-uk.env`. The example is never
installed. An existing server file takes precedence over the uploaded copy and is preserved as
root-owned mode `0600`. The Swift environment is optional until its first image deployment and is
handled with the same preserve-existing behavior. Persistent volumes, per-target image state, and
deployment history are also preserved.

For manual bootstrap from an extracted bundle, the equivalent server-side interface is:

```bash
sudo bash ./oracle/bootstrap.sh \
  '<40-character-commit>' \
  /secure/path/server-tailscale.key \
  /secure/path/josephduffy-co-uk.env \
  /secure/path/github-attestation-token \
  /secure/path/josephduffy-co-uk-swift.env
```

The optional arguments supply the Tailscale key, primary website environment, one-off GitHub token,
and Swift environment. They default to files in `oracle/` and can be absent when their corresponding
state already exists. For later secret edits:

```bash
sudoedit /etc/webserver/josephduffy-co-uk.env
sudo systemctl restart josephduffy-co-uk.service

sudoedit /etc/webserver/josephduffy-co-uk-swift.env
sudo systemctl restart josephduffy-co-uk-swift.service
```

Set the repository variable `ORACLE_DEPLOY_ENABLED` to `true` only after bootstrap and Tailscale
policy testing. Missing, empty, or any other value leaves the configuration workflow in
validation-only mode.

## Reusable image deployment

The public `deploy-image.yml` workflow accepts an opaque allow-listed `target` and the exact
`sha256:` digest emitted by that target's image build. The target defaults to
`josephduffy-co-uk`, so existing callers that pass only `digest` continue to work. It accepts calls
only from `JosephDuffy/josephduffy.co.uk`, verifies the selected image's attestation before joining
the tailnet, and passes only the validated target and digest to the fixed server-side command.

The available targets are:

| Target | Attested OCI image | Public hostname |
| --- | --- | --- |
| `josephduffy-co-uk` | `ghcr.io/josephduffy/josephduffy.co.uk` | `oracle.josephduffy.co.uk` |
| `josephduffy-co-uk-swift` | `ghcr.io/josephduffy/josephduffy.co.uk-swift` | `swift.josephduffy.co.uk` |

In the website repository, expose the digest from the existing build job. The build step must have
an `id`; this example assumes it is named `build`:

```yaml
jobs:
  build_image:
    outputs:
      digest: ${{ steps.build.outputs.digest }}
    steps:
      # Existing checkout, login, metadata, and setup steps.
      - name: Build and push the image
        id: build
        uses: docker/build-push-action@<pinned-action-commit>
        with:
          # Existing multi-platform build and push configuration.
```

Add a dependent job that calls the reusable workflow. Pass only the build output and the two
federated identity values created above:

```yaml
  deploy_oracle:
    name: Deploy to Oracle
    needs: build_image
    permissions:
      attestations: read
      contents: read
      id-token: write
    uses: JosephDuffy/webserver-deploy/.github/workflows/deploy-image.yml@master
    with:
      target: josephduffy-co-uk
      digest: ${{ needs.build_image.outputs.digest }}
    secrets:
      TS_CLIENT_ID: ${{ secrets.TS_CLIENT_ID }}
      TS_AUDIENCE: ${{ secrets.TS_AUDIENCE }}
```

The caller permissions are required because permissions can only be maintained or reduced across a
reusable-workflow call. `attestations: read` verifies the image provenance, and `id-token: write`
allows the Tailscale client to request the short-lived GitHub OIDC token. The workflow does not need
a Tailscale client secret or reusable auth key.

Both targets are built by the same repository and call the same reusable workflow, so they use the
same `TS_CLIENT_ID` and `TS_AUDIENCE` credential pair.

Use the same pattern for the Swift build, changing only the build dependency and target:

```yaml
  deploy_swift_oracle:
    name: Deploy Swift server to Oracle
    needs: build_swift_image
    permissions:
      attestations: read
      contents: read
      id-token: write
    uses: JosephDuffy/webserver-deploy/.github/workflows/deploy-image.yml@master
    with:
      target: josephduffy-co-uk-swift
      digest: ${{ needs.build_swift_image.outputs.digest }}
    secrets:
      TS_CLIENT_ID: ${{ secrets.TS_CLIENT_ID }}
      TS_AUDIENCE: ${{ secrets.TS_AUDIENCE }}
```

The Swift image contract is `linux/arm64`, UID/GID `1001:1001`, HTTP on port `8080`, and a bundled
`/usr/bin/curl` capable of making the container's `HEAD /` health request. Its root filesystem is
read-only apart from a bounded `/tmp` tmpfs. Before its first deployment, install the environment
file and create a DNS-only A record for `swift.josephduffy.co.uk` pointing to the server. The first
deployment enables the service only after the image is pulled and verified; a failed first
deployment removes that enable marker again.

The `master` reference is intentionally a moving deployment channel. Protect `master` in this
repository with required pull-request review and status checks, restricted direct pushes, and force
pushes and branch deletion disabled. A caller will use newly accepted workflow changes on its next
run without changing its own workflow file.

During the Oracle trial this job can run alongside the existing webhook deployment. Both jobs use
the same multi-platform OCI index digest, while each server pulls the image matching its own
architecture.

## SSH lock-down

The bootstrap intentionally leaves OpenSSH on public port 22 as a migration safety net. Before
removing it, test administrative SSH using a local alias configured with the administrator username
and the tailnet hostname:

```bash
ssh -p 2222 webserver-admin
```

Confirm both deployment workflows succeed. The workload identities used by GitHub Actions are the
only identities authorized to use the deployment Unix accounts; the following commands are not
expected to work from a personal Tailscale node:

```bash
tailscale ssh webserver-image-deploy@webserver-oracle
tailscale ssh webserver-config-deploy@webserver-oracle
```

Also open and test an Oracle serial-console session. Then run the script to lock down the SSH
configuration, acknowledging that the above checks have been performed:

```bash
sudo /opt/webserver/current/scripts/lock-down-ssh \
  --admin-tested \
  --workflows-tested \
  --serial-console-tested
```

Finally remove public TCP/22 from the Oracle VCN security list or NSG. The managed host firewall
permits OpenSSH TCP/2222 only on `tailscale0`; Oracle public ingress must also keep 2222 closed.
Locked passwords and empty key files are not the sole protection: the managed `DenyUsers` rules keep
deployment accounts out of OpenSSH even if keys are added later. Existing host
`AllowUsers`/`AllowGroups` rules, if any, are still respected and should be reviewed.

## Health Checks

- Each application container sends a local `HEAD /` request with a five-second timeout. The Next.js
  image uses Node and the Swift image uses its bundled `curl`; both check the homepage route without
  downloading a response body.
- Caddy checks `GET http://localhost:2019/config/` with its bundled `curl`. Its admin listener is
  bound only to container loopback, and port 2019 is not published or available to the website
  container. The liveness probe itself does not depend on website availability.
- Deployment success also requires an HTTPS `HEAD /` check through Caddy for the selected target,
  including certificate verification and proxying to that application. A healthy admin API alone
  would not prove TLS or routing works.

The host has two vCPUs and 12 GB RAM. Caddy has a 512 MB memory limit and the default CPU share
weight of 1024. Next.js has a 2 GB limit and the Swift service has a 4 GB limit; both have a lower
CPU share weight of 512. CPU shares are relative priority only when the host is contended, not a
core-count ceiling, so either application may use both cores when capacity is available.

## Operation and rollback

Configuration releases are stored at `/opt/webserver/releases/<commit>` and activated through
`/opt/webserver/current`. Per-target image state is stored under
`/var/lib/webserver-deploy/images/<target>`, while shared history remains at
`/var/lib/webserver-deploy/history.log`. Both deployment commands use a shared lock.

An image deployment verifies GitHub provenance on both the runner and server, pulls the target's
exact OCI index digest, verifies that Podman selected ARM64, retags it locally as `production`,
confirms the target container is running that immutable image ID, runs its configured health check,
and checks its public HTTPS hostname. Failure restores only that target's prior local image.
The reusable workflow requires the caller to grant `attestations: read`; it sends that job's
short-lived GitHub token to the fixed deployment command over SSH standard input. The token is used
only by `gh attestation verify` and is never stored on the server.

A configuration deployment validates scripts, sudo policy, Quadlet generation, and the Caddy
configuration before switching releases. It restarts only affected services and restores the prior
release if startup, TLS, or health checks fail.

Useful checks:

```bash
sudo systemctl status josephduffy-co-uk.service caddy.service
sudo systemctl status josephduffy-co-uk-swift.service
sudo systemctl status webserver-dual-stack-network.service webserver-firewall.service
sudo podman network inspect webserver-dual-stack | jq '.[0] | {ipv6_enabled, subnets}'
sudo podman port caddy
sudo podman image inspect --format '{{.Os}}/{{.Architecture}}' localhost/josephduffy-co-uk:production
sudo podman image inspect --format '{{.Os}}/{{.Architecture}}' localhost/josephduffy-co-uk-swift:production
sudo podman image inspect --format '{{.Os}}/{{.Architecture}}' docker.io/library/caddy:2.11.4-alpine
sudo tail -n 50 /var/lib/webserver-deploy/history.log
curl -4 --head --fail https://oracle.josephduffy.co.uk/
curl -6 --head --fail https://oracle.josephduffy.co.uk/
curl -4 --head --fail https://swift.josephduffy.co.uk/
curl -6 --head --fail https://swift.josephduffy.co.uk/
```

Keep the legacy `webserver` network while the previous configuration release is a useful rollback
target. It consumes no public address and can remain unused. Remove its Quadlet and network in a
later configuration release after dual-stack operation and rollback have both been exercised.

[oracle-platform-images]: https://docs.oracle.com/iaas/Content/Compute/References/images.htm

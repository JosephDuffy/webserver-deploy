# ARM Deployment

This bundle provisions a website-only Ubuntu 24.04 ARM64 host. It uses rootful Podman Quadlets, a
pinned Caddy image, an attested website image, and two single-purpose deployment identities. Routine
deployments do not clone this repository and do not install host packages.

## Trust Boundaries

- The `webserver-image-deploy` user may run only the root-owned image deployment command.
- The `webserver-config-deploy` user may run only the root-owned configuration deployment command.
- Both accounts have locked passwords, empty `authorized_keys`, no supplementary groups, and no
  general sudo access. OpenSSH explicitly denies these accounts; Tailscale SSH authorizes them
  separately. Other administrator accounts are not hard-coded in this bundle.
- The image command accepts only `sha256:<64 lowercase hex>` and always uses the fixed
  josephduffy.co.uk image, service, hostname, and health endpoint.
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

Configure a local SSH alias (for example, `bootstrap-server`) with your administrator account,
personal key, host and port. Verify its host key and normal SSH access first. Remote bootstrap
requires non-interactive `sudo` on the server, but **does not require local root**. It keeps strict
SSH host-key checking enabled and does not install any administrator key in GitHub Actions.

Prepare the ignored local environment file and fill in the real values:

```bash
cp oracle/josephduffy-co-uk.example.env oracle/josephduffy-co-uk.env
chmod 600 oracle/josephduffy-co-uk.env
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

- Subject: `repo:JosephDuffy/webserver-deploy:ref:refs/heads/feature/oracle-arm`
- Custom claim: `workflow_ref`
- Custom claim value:
  `JosephDuffy/webserver-deploy/.github/workflows/oracle-config.yml@refs/heads/feature/oracle-arm`
- Scope: `auth_keys` write only
- Tag: `tag:webserver-config-deploy`

Store its generated Client ID and Audience in this repository's GitHub Actions secrets as
`TS_CONFIG_CLIENT_ID` and `TS_CONFIG_AUDIENCE`.

Create the image deployment identity with:

- Subject:
  `repo:JosephDuffy/josephduffy.co.uk:ref:refs/heads/<deployment-branch>`
- Custom claim: `job_workflow_ref`
- Custom claim value:
  `JosephDuffy/webserver-deploy/.github/workflows/deploy-image.yml@<exact-commit-sha>`
- Scope: `auth_keys` write only
- Tag: `tag:webserver-image-deploy`

Replace `<deployment-branch>` with the branch in the website repository that calls the reusable
workflow. Replace `<exact-commit-sha>` with the full commit SHA used in that workflow's `uses`
reference. Store this identity's Client ID and Audience in the website repository's GitHub Actions
secrets as `TS_CLIENT_ID` and `TS_AUDIENCE`.

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

Bootstrap fails before package installation if an environment file is not on the device performing
the bootstrap or on the web server at `/etc/webserver/josephduffy-co-uk.env`. The example is never
installed. An existing server file takes precedence over the uploaded copy and is preserved as
root-owned mode `0600`. Persistent volumes, image state, and deployment history are also preserved.

For manual bootstrap from an extracted bundle, the equivalent server-side interface is:

```bash
sudo bash ./oracle/bootstrap.sh \
  '<40-character-commit>' \
  /secure/path/server-tailscale.key \
  /secure/path/josephduffy-co-uk.env \
  /secure/path/github-attestation-token
```

The optional arguments supply the Tailscale key, website environment, and one-off GitHub token.
They default to files in `oracle/` and can be absent when their corresponding state already exists.
For later website secret edits:

```bash
sudoedit /etc/webserver/josephduffy-co-uk.env
sudo systemctl restart josephduffy-co-uk.service
```

Set the repository variable `ORACLE_DEPLOY_ENABLED` to `true` only after bootstrap and Tailscale
policy testing. Missing, empty, or any other value leaves the configuration workflow in
validation-only mode.

## SSH lock-down

The bootstrap intentionally leaves OpenSSH on public port 22 as a migration safety net. Before
removing it, test administrative SSH using a local alias configured with the administrator username
and the tailnet hostname:

```bash
ssh -p 2222 webserver-admin
```

Test each deployment account from its respective workflow identity (not a personal Tailscale
identity, which the example policy does not authorize for these accounts):

```bash
tailscale ssh webserver-image-deploy@webserver-oracle
tailscale ssh webserver-config-deploy@webserver-oracle
```

Also open and test an Oracle serial-console session. Then run the script to lock down the SSH
configuration, acknowledging that the above checks have been performed:

```bash
sudo webserver-lock-down-ssh \
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

- The website container sends a local `HEAD /` request with a five-second timeout. It checks the
  homepage route without downloading a response body; the server may still render that page.
- Caddy checks `GET http://localhost:2019/config/` with its bundled `curl`. Its admin listener is
  bound only to container loopback, and port 2019 is not published or available to the website
  container. The liveness probe itself does not depend on website availability.
- Deployment success also requires an HTTPS `HEAD /` check through Caddy, including certificate
  verification and proxying to the website. A healthy admin API alone would not prove TLS or
  routing works.

## Operation and rollback

Configuration releases are stored at `/opt/webserver/releases/<commit>` and activated through
`/opt/webserver/current`. Image state and history remain under `/var/lib/webserver-deploy`. Both
deployment commands use a shared lock.

An image deployment verifies GitHub provenance on both the runner and server, pulls the exact OCI
index digest, verifies that Podman selected ARM64, retags it locally as `production`, confirms the
container is running that immutable image ID, runs the container's configured health check,
and checks `https://oracle.josephduffy.co.uk/`. Failure restores the prior local image.
The reusable workflow requires the caller to grant `attestations: read`; it sends that job's
short-lived GitHub token to the fixed deployment command over SSH standard input. The token is used
only by `gh attestation verify` and is never stored on the server.

A configuration deployment validates scripts, sudo policy, Quadlet generation, and the Caddy
configuration before switching releases. It restarts only affected services and restores the prior
release if startup, TLS, or health checks fail.

Useful checks:

```bash
sudo systemctl status josephduffy-co-uk.service caddy.service
sudo podman image inspect --format '{{.Os}}/{{.Architecture}}' localhost/josephduffy-co-uk:production
sudo podman image inspect --format '{{.Os}}/{{.Architecture}}' docker.io/library/caddy:2.11.4-alpine
sudo tail -n 50 /var/lib/webserver-deploy/history.log
curl --head --fail https://oracle.josephduffy.co.uk/
```

[oracle-platform-images]: https://docs.oracle.com/iaas/Content/Compute/References/images.htm

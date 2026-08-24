# webserver-deploy

The configuration and automatic deployment of my webserver.

## Oracle ARM trial

The `feature/oracle-arm` branch contains a parallel, clone-free deployment for the
Oracle ARM server. It provisions Podman Quadlet, Caddy, Tailscale access, restricted
deployment identities, immutable configuration releases, attested image promotion,
health checks, and rollback. See [the Oracle deployment guide](oracle/README.md).

The existing Docker Compose deployment remains on `master`; its legacy SSH workflow is
restricted to pushes to that branch during the trial.

## Server setup

The server will need Docker and Docker Compose installed.

### Environment Variables

| Variable | Reason |
|----------|--------|
| `LETSENCRYPT_USER_MAIL` | The email used to register Let's Encrypt certifcates |
| `LEXICON_CLOUDFLARE_USERNAME` | The username used to access the Cloudflare API for DNS-based domain validation |
| `LEXICON_CLOUDFLARE_TOKEN` | The token used to access the Cloudflare API for DNS-based domain validation |
| `GITHUB_ACCESS_TOKEN`| The access token used to load PRs, releases, and repos from GitHub (for josephduffy.co.uk) |

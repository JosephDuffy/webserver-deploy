# webserver-deploy

The configuration and automatic deployment of my webserver.

## Server setup

The server will need Docker and Docker Compose installed.

### Environment Variables

| Variable | Reason |
|----------|--------|
| `LETSENCRYPT_USER_MAIL` | The email used to register Let's Encrypt certifcates |
| `LEXICON_CLOUDFLARE_USERNAME` | The username used to access the Cloudflare API for DNS-based domain validation |
| `LEXICON_CLOUDFLARE_TOKEN` | The token used to access the Cloudflare API for DNS-based domain validation |
| `GITHUB_ACCESS_TOKEN`| The access token used to load PRs, releases, and repos from GitHub (for josephduffy.co.uk) |

# webserver-deploy

The configuration and automatic deployment of my webserver.

It pulls https://github.com/josephduffy/josephduffy.co.uk, builds it using the included Dockerfile, and serves the website over HTTPS via NGINX.

Statistics are provided via goaccess.

Deployments are via GitHub actions. The secrets (such as API keys) are inserted by GitHub.

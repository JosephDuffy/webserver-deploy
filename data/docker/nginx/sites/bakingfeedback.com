server {
	server_name www.bakingfeedback.com api.bakingfeedback.com bakingfeedback.com;
	listen 80;
	listen [::]:80;
	listen 443 ssl http2;
	listen [::]:443 ssl http2;

	ssl_certificate /etc/letsencrypt/live/bakingfeedback.com/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/bakingfeedback.com/privkey.pem;
	ssl_trusted_certificate /etc/letsencrypt/live/bakingfeedback.com/chain.pem;

	add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

	return 301 https://josephduffy.co.uk/projects/baking-feedback;
}

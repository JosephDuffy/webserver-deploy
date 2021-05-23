FROM almir/webhook
RUN apk --update --upgrade add docker curl py-pip python3-dev libffi-dev openssl-dev gcc libc-dev rust cargo make
RUN curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
RUN chmod +x /usr/local/bin/docker-compose
RUN rm -rf /var/cache/apk/*

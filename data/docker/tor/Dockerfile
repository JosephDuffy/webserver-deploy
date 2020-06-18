FROM alpine:latest

RUN apk --no-cache add tor haproxy
COPY start.sh /
COPY torrc /etc/tor/torrc
COPY jduffyuk /var/lib/tor/jduffyuk/
RUN chmod 600 -R /var/lib/tor/jduffyuk/
RUN chmod 700 /var/lib/tor/jduffyuk/
RUN chown -R root:root /var/lib/tor/jduffyuk/
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg

EXPOSE 9050

CMD ["/start.sh"]

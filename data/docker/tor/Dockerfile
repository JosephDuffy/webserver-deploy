FROM alpine:latest

RUN apk --no-cache add tor haproxy
COPY start.sh /
COPY torrc /etc/tor/torrc
COPY josephdepqbvoq7tm7uvynwmsji4354zmd3yp3rrtc245rilvq4ixayd.onion /var/lib/tor/josephdepqbvoq7tm7uvynwmsji4354zmd3yp3rrtc245rilvq4ixayd.onion/
RUN chmod 600 -R /var/lib/tor/josephdepqbvoq7tm7uvynwmsji4354zmd3yp3rrtc245rilvq4ixayd.onion/
RUN chmod 700 /var/lib/tor/josephdepqbvoq7tm7uvynwmsji4354zmd3yp3rrtc245rilvq4ixayd.onion/
RUN chown -R root:root /var/lib/tor/josephdepqbvoq7tm7uvynwmsji4354zmd3yp3rrtc245rilvq4ixayd.onion/
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg

EXPOSE 9050

CMD ["/start.sh"]

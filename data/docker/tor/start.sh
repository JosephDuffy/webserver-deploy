#!/bin/sh

tor -f /etc/tor/torrc --runasdaemon 1
haproxy -f /usr/local/etc/haproxy/haproxy.cfg

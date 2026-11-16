#!/bin/sh
# Dev helper: push files/ to a router. Usage: ./deploy.sh root@host
set -e
H=${1:?usage: deploy.sh root@host}
tar cf - -C "$(dirname "$0")/files" usr | ssh "$H" 'tar xf - -C / && chmod +x /usr/sbin/owrt-supervisor /usr/sbin/owrt-supervisor-http && mkdir -p /var/run/owrt-supervisor'

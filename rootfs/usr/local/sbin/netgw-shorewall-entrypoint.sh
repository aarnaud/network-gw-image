#!/bin/bash
# Entrypoint for the Shorewall role of this image (selected by overriding
# the Pod container's `command` to point here instead of the default
# networkd entrypoint). Unlike networkd, Shorewall has no long-running
# daemon of its own -- `shorewall reload` applies rules and exits -- so the
# watch loop itself is the one process that must run in the foreground.
set -euo pipefail

source /usr/local/sbin/netgw-lib.sh

mkdir -p /run/netgw

log "applying firewall configuration"
/usr/local/sbin/netgw-shorewall-apply

log "starting config watcher (debounce ${NETGW_RECONCILE_DEBOUNCE_SECONDS}s)"
exec /usr/local/sbin/netgw-shorewall-watch

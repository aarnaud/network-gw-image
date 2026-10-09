#!/bin/bash
# PID 1 is tini; this script is its single direct child. We write our own
# PID to a file *before* exec-ing systemd-networkd, because exec replaces
# this process's program image but keeps its PID -- so the PID recorded
# here is the PID netgw-watch must SIGHUP for the rest of this container's
# life, with no further process discovery needed.
set -euo pipefail

source /usr/local/sbin/netgw-lib.sh

mkdir -p /run/netgw /etc/systemd/network /etc/systemd/network-secrets

echo $$ >/run/netgw/networkd.pid

# systemd-networkd drops privileges to the systemd-network user before
# reading WireGuard PrivateKeyFile= paths. Secret volumes mount as
# root-owned regardless of pod spec, so fix ownership here (still root at
# this point) rather than requiring the user to set fsGroup correctly.
chown -R systemd-network:systemd-network /etc/systemd/network-secrets 2>/dev/null || true

log "starting config watcher (debounce ${NETGW_RECONCILE_DEBOUNCE_SECONDS}s)"
/usr/local/sbin/netgw-watch /run/netgw/networkd.pid &

log "starting udevd"
/usr/lib/systemd/systemd-udevd --daemon

log "starting systemd-networkd"
exec /usr/lib/systemd/systemd-networkd

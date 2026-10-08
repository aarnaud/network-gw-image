#!/bin/bash
# Shared helpers for netgw-entrypoint.sh and netgw-watch.

: "${NETGW_LOG_LEVEL:=info}"
: "${NETGW_RECONCILE_DEBOUNCE_SECONDS:=2}"

log() {
	printf '[netgw] %s\n' "$*" >&2
}

debug() {
	[ "$NETGW_LOG_LEVEL" = "debug" ] && log "$@"
	return 0
}

# Drain any further inotify lines arriving within the debounce window so a
# burst of events (e.g. Kubernetes' ConfigMap/Secret ..data symlink swap,
# which touches several paths at once) collapses into a single reload.
drain_debounce() {
	local deadline=$NETGW_RECONCILE_DEBOUNCE_SECONDS
	while read -r -t "$deadline" _; do
		:
	done
}

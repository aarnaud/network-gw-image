# Runtime contract

This single image supports two roles, selected by which entrypoint script the Pod
container invokes. Both roles are containers in the same three-container gateway Pod
(Multus-attached, one network "scope" per sibling container); a separate CrowdSec
firewall-bouncer container is not built here and is not covered by this contract. The
two roles here are fully independent of each other and of the bouncer — no shared
volumes, no startup ordering, no handoff — each only touches its own concern against the
Pod's shared network namespace.

| Role | Entrypoint | What it owns |
|---|---|---|
| `networkd` (default) | `/usr/local/sbin/netgw-entrypoint.sh` (the image's default `ENTRYPOINT`) | Interfaces, addressing, routing, native WireGuard (client + server) via `systemd-networkd`. |
| `shorewall` | override `command: ["/usr/bin/tini", "--", "/usr/local/sbin/netgw-shorewall-entrypoint.sh"]` | All firewall/NAT rules, via Shorewall + Shorewall6. |

None of the following can be set by the Dockerfile — they must be provided by the Pod
spec, and differ by role.

## `networkd` role

### Privileged container required

```yaml
securityContext:
  privileged: true
```

`systemd-networkd` drops privilege from root to a dedicated `systemd-network` user at
startup, retaining a specific set of capabilities (`NET_ADMIN`, `NET_RAW`,
`NET_BIND_SERVICE`, `NET_BROADCAST`, `SYS_ADMIN`, `BPF`) via Linux's ambient-capability
mechanism. This was tested directly against this image: an explicit `--cap-add` list
covering that set plus `SETUID`/`SETGID`/`SETPCAP` (needed to perform the drop itself),
and even a much broader ~18-capability list, both still failed with `Failed to increase
capabilities` / `Failed to drop privileges` and the process exited. Only
`--privileged` (Docker) / `securityContext.privileged: true` (Kubernetes) — the
equivalent of granting the full capability set — worked. This is a known rough edge of
running systemd components standalone (not under a full `systemd` PID 1, which has its
own internal machinery for this transition) inside a container runtime, and matches
common practice for other node-level networking daemons (Calico, Cilium, Multus itself
typically also run privileged).

### Volume mounts

| Container path | Source | Why |
|---|---|---|
| `/etc/systemd/network` | ConfigMap | `*.network`/`*.netdev`/`*.link` files: interface matches, addressing, routes, WireGuard `ListenPort`/`Address`, `[WireGuardPeer]` `PublicKey`/`AllowedIPs`/`Endpoint`. None of this is secret. |
| `/etc/systemd/network-secrets` | Secret | One file per WireGuard interface holding its `PrivateKey`, referenced from the matching `.netdev` via `PrivateKeyFile=/etc/systemd/network-secrets/<name>.key`. The entrypoint `chown -R`s this directory to the `systemd-network` user at startup, so the Secret's own `defaultMode`/ownership doesn't need to match what the dropped-privilege networkd process can read — no `fsGroup` configuration needed. |

**Mount both as whole-directory volumes — never `subPath`.** The container's config
watcher relies on inotify events on these directories to detect changes and reload live;
`subPath` mounts are explicitly excluded from kubelet's ConfigMap/Secret live-update
mechanism, so a `subPath` mount would never trigger a reload.

### Config authoring notes

- Use `IPv4Forwarding=`/`IPv6Forwarding=` in `.network` files, not the deprecated
  `IPForward=`.
- Do not set `IPMasquerade=` in any `.network`/`.netdev` file shipped here — NAT is the
  Shorewall role's responsibility. Enabling it here risks two containers racing to
  manage overlapping nftables state in the same network namespace.
- `[Match] Name=` values must match whatever interface names Multus actually assigns
  (commonly `net1`, `net2`, … unless renamed via the `k8s.v1.cni.cncf.io/networks`
  annotation).
- The node kernel must already have WireGuard support; this container cannot load kernel
  modules (no `CAP_SYS_MODULE`).

### Diagnostics

No D-Bus is included in this image, so `networkctl status`/`networkctl reload` are not
available. Use `wg show`, `ip link`, `ip addr`, and container logs instead. Reload is
automatic — the watcher sends `systemd-networkd` a `SIGHUP` whenever the mounted
ConfigMap/Secret changes; there is no manual reload step.

## `shorewall` role

### Capabilities — much lighter than `networkd`, not privileged

```yaml
securityContext:
  capabilities:
    add:
      - NET_ADMIN
      - NET_RAW
```

Verified directly: `shorewall check`/`start`/`reload` all work under exactly this pair,
no privilege-drop dance like `systemd-networkd` has (Shorewall is just a root-run script
driving `iptables-restore`/`nft`, nothing forks to a lesser-privileged user).

Shorewall also tries to tune `net.ipv4.conf.*.rp_filter` and `log_martians` via
`/proc/sys` on every start/reload. Docker/Kubernetes mount `/proc/sys` read-only by
default, so you'll see benign `cannot create .../rp_filter: Read-only file system`
warnings in the logs — these do not stop the ruleset from applying (`iptables-restore`
still runs and completes). If you don't want the warnings, set `ROUTE_FILTER=no` and
`LOG_MARTIANS=no` in `shorewall.conf`; otherwise ignore them, or allow those specific
sysctls as unsafe sysctls on the node if you want Shorewall to actually manage them.

### Volume mounts

| Container path | Source | Why |
|---|---|---|
| `/etc/shorewall` | ConfigMap | IPv4 ruleset: `zones`, `interfaces`, `policy`, `rules`, `snat`, `shorewall.conf`, etc. |
| `/etc/shorewall6` | ConfigMap (optional) | IPv6 ruleset, same file set. Omit entirely if IPv6 isn't needed — the container detects an unconfigured `shorewall6` (no `zones` content) and skips it without error. |

**Mount as whole-directory volumes — never `subPath`** (same live-reload reasoning as
the `networkd` role).

### Config authoring notes

- The `interfaces` file needs `?FORMAT 2` as its first line to use the modern 3-column
  `ZONE INTERFACE OPTIONS` syntax; without it, Shorewall expects an extra `BROADCAST`
  column (format 1) and will reject the file with a confusing `Invalid BROADCAST
  address` error if that column is missing.
- Use the `snat` file, not `masq` — `masq` was removed before Shorewall 5.2.8, which is
  what ships in `debian:stable-slim`.
- At least one real (non-`firewall`) zone with a matching `interfaces` entry is required
  for `shorewall check` to pass; the bare package defaults (no zones) intentionally fail
  `check` and are left unstarted until the real ConfigMap is mounted.

### Diagnostics

`shorewall status`, `iptables -L -n`, `nft list ruleset`, and container logs. Reload is
automatic — the watcher re-runs `shorewall check && shorewall reload` (and the `6`
equivalent) whenever the mounted ConfigMap changes; there is no manual reload step. A
config that fails `check` is never applied — the previously-running ruleset is left in
place and the failure is logged.

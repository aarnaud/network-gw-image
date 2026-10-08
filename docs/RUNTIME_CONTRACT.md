# Runtime contract

This image runs `systemd-networkd` standalone (not under full `systemd` PID 1) to manage
interfaces, addressing, routing, and native WireGuard for one container in a Kubernetes
Pod. It is one of three independent containers in that Pod — a separate Shorewall
container owns firewall/NAT rules, and a separate CrowdSec firewall-bouncer container
owns dynamic IP banning. This container does not coordinate with either; it only touches
its own concern against the Pod's shared network namespace.

None of the following can be set by the Dockerfile — they must be provided by the Pod
spec.

## Privileged container required

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

## Volume mounts

| Container path | Source | Why |
|---|---|---|
| `/etc/systemd/network` | ConfigMap | `*.network`/`*.netdev`/`*.link` files: interface matches, addressing, routes, WireGuard `ListenPort`/`Address`, `[WireGuardPeer]` `PublicKey`/`AllowedIPs`/`Endpoint`. None of this is secret. |
| `/etc/systemd/network-secrets` | Secret | One file per WireGuard interface holding its `PrivateKey`, referenced from the matching `.netdev` via `PrivateKeyFile=/etc/systemd/network-secrets/<name>.key`. The entrypoint `chown -R`s this directory to the `systemd-network` user at startup, so the Secret's own `defaultMode`/ownership doesn't need to match what the dropped-privilege networkd process can read — no `fsGroup` configuration needed. |

**Mount both as whole-directory volumes — never `subPath`.** The container's config
watcher relies on inotify events on these directories to detect changes and reload live;
`subPath` mounts are explicitly excluded from kubelet's ConfigMap/Secret live-update
mechanism, so a `subPath` mount would never trigger a reload.

## Config authoring notes

- Use `IPv4Forwarding=`/`IPv6Forwarding=` in `.network` files, not the deprecated
  `IPForward=`.
- Do not set `IPMasquerade=` in any `.network`/`.netdev` file shipped here — NAT is the
  Shorewall container's responsibility. Enabling it here risks two containers racing to
  manage overlapping nftables state in the same network namespace.
- `[Match] Name=` values must match whatever interface names Multus actually assigns
  (commonly `net1`, `net2`, … unless renamed via the `k8s.v1.cni.cncf.io/networks`
  annotation).
- The node kernel must already have WireGuard support; this container cannot load kernel
  modules (no `CAP_SYS_MODULE`).

## Diagnostics

No D-Bus is included in this image, so `networkctl status`/`networkctl reload` are not
available. Use `wg show`, `ip link`, `ip addr`, and container logs instead. Reload is
automatic — the watcher sends `systemd-networkd` a `SIGHUP` whenever the mounted
ConfigMap/Secret changes; there is no manual reload step.

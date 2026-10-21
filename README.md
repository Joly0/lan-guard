# lan-guard

lan-guard is a sidecar container that keeps every container sharing its network namespace away from private and local networks while the public internet stays reachable. An app is attached with compose's `network_mode: "service:lan-guard"`: it then shares the guard's network stack and the guard's firewall rules apply to it. Blocked destinations cover your LAN and router, the Docker host, the CGNAT range used by Tailscale, and IPv4 and IPv6 link-local. This exists for bandwidth-sharing and residential-proxy apps such as Honeygain, Pawns and Repocket: they relay strangers' traffic from inside your home network, and nothing in those apps stops that traffic from reaching LAN devices.

Source and issues: https://github.com/Joly0/lan-guard

## How it works

lan-guard is a single POSIX shell script in a small Alpine image with iptables and ip6tables installed. It only changes firewall rules inside its own network namespace; nothing on the host is touched. Every app attached with `network_mode: "service:lan-guard"` shares that namespace, so the rules cover all of them.

On startup the guard applies an iptables-restore document in one atomic transaction, so there is never a moment with half-applied rules. The OUTPUT rules, in order:

1. Accept loopback, which keeps Docker's embedded DNS at 127.0.0.11 working.
2. Accept established and related connections.
3. Accept destinations on the `ALLOW_SUBNETS` list (empty by default).
4. REJECT or DROP destinations on the `BLOCK_SUBNETS` list.

Default blocked ranges:

| Range | Covers |
| --- | --- |
| `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` | private IPv4: your LAN, the router behind it, and the Docker host, which is the guard's default gateway |
| `100.64.0.0/10` | carrier-grade NAT, which includes Tailscale's default address range |
| `169.254.0.0/16` | IPv4 link-local |
| `fc00::/7` | IPv6 unique local addresses |
| `fe80::/10` | IPv6 link-local |

Details:

- Blocked packets are REJECTed, with `icmp-admin-prohibited` for IPv4 and `adm-prohibited` for IPv6, so attempts fail at once instead of hanging until a timeout. When the kernel cannot provide the REJECT target to this namespace, the guard logs why and blocks with DROP instead.
- Rules are stored with the nft backend when the kernel supports nf_tables, with a fallback to the legacy iptables backend otherwise. `BACKEND` can force either one.
- IPv6 rules are applied whenever IPv6 exists in the namespace. When it does not, there is nothing to block and the health check accounts for that.
- Only outbound traffic is filtered. Inbound traffic, for example to ports published on the guard, is not restricted by these rules.

## Fail-closed design

The goal is that apps never run with unprotected access.

- The ruleset is applied before anything else runs. Any failure exits non-zero, so the container is never healthy and, with `depends_on` set to `condition: service_healthy`, the apps behind it never start. Docker keeps restarting the guard according to its restart policy until the rules apply.
- The image ships the healthcheck for that: `lan-guard health`, which Docker runs every 30 seconds and once a second during startup, so dependents are released within a second of the rules landing instead of a full interval later.
- `lan-guard health` runs two checks. First, the rules the kernel reports now must match the snapshot stored when they were applied, so a flushed chain or an inserted bypass rule fails the check. Second, the guard connects to the default gateway, which is the Docker host, and requires the packet counters on the block rules to rise while the connection fails. That proves the probe was stopped by lan-guard itself and not merely refused by the host. The probe is skipped when the gateway is not a blocked destination, for instance because you allowed it on `ALLOW_SUBNETS`.
- The guard process keeps the shared namespace alive. If it stops, the apps behind it lose their network entirely rather than running unprotected. lan-guard fails closed, never open.

You can check a running setup by hand with `docker exec lan-guard lan-guard health`.

## Quick start

`compose.example.yml` in the repository is a runnable minimal example. The essential part:

```yaml
services:
  lan-guard:
    image: ghcr.io/joly0/lan-guard:1
    container_name: lan-guard
    # Only needed to set firewall rules inside the guard's own network
    # namespace. It grants nothing on the host.
    cap_add: [NET_ADMIN]
    restart: unless-stopped
    # Ports of the services behind the guard are published here, on the guard.
    # ports:
    #   - "8080:8080"
    environment:
      # Destinations that stay reachable even though they are private,
      # e.g. a local DNS server. Comma or space separated. Empty by default.
      ALLOW_SUBNETS: ""

  app:
    image: your-app
    network_mode: "service:lan-guard"
    depends_on:
      lan-guard:
        condition: service_healthy
        # Recreate the app when compose restarts the guard: a restarted guard
        # has a new network namespace and the app would otherwise stay offline.
        restart: true
    restart: unless-stopped
```

Notes:

- `cap_add: [NET_ADMIN]` goes on the guard only. It is needed to set the firewall rules in the guard's namespace and grants nothing on the host.
- Replace the `app` image with whatever should stay off your LAN.
- `docker compose up -d` starts the app only after the guard reports healthy.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `BLOCK_SUBNETS` | `10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 fc00::/7 fe80::/10` | Destinations to block. Setting the variable replaces the default list entirely. |
| `ALLOW_SUBNETS` | empty | Destinations that stay reachable even though they are private or blocked, for example a local DNS server. Matched before the block rules. |
| `LOG_BLOCKED` | `false` | Set to `true` to log blocked packets to the kernel log before they are rejected or dropped, limited to 6 per minute. See the caveats on where those logs appear. |
| `BACKEND` | `auto` | Which iptables backend stores the rules: `auto` tests nft first and falls back to legacy, `nft` and `legacy` force one. |

`BLOCK_SUBNETS` and `ALLOW_SUBNETS` accept entries separated by commas, spaces or newlines.

## Caveats

### After a guard restart, apps behind it are offline

Restarting the guard gives it a new network namespace. Apps attached to the old one keep it and stay offline until they are recreated. The `restart: true` under `depends_on` handles this when compose restarts the guard. Restarts compose does not perform, such as `docker restart lan-guard` or a Docker daemon restart, need the apps restarted as well.

### Ports must be published on the guard

Apps behind the guard share its namespace and have no network of their own to publish ports on. Put the `ports:` section on the `lan-guard` service.

### NET_ADMIN

The guard needs `cap_add: [NET_ADMIN]`. An app behind the guard that is also granted NET_ADMIN could remove the rules from inside the shared namespace. The healthcheck would flag it and the container turns unhealthy, but it cannot stop or revert the tampering, so do not grant NET_ADMIN to apps behind the guard.

### LOG_BLOCKED writes to the host kernel log

Blocked packets are logged by the kernel, so the output lands in the host kernel log, not in `docker logs`. The kernel also ignores netfilter logging from container network namespaces unless the host sets the sysctl `net.netfilter.nf_log_all_netns=1`, so on an unmodified host `LOG_BLOCKED` produces no output at all.

### What lan-guard does not change

lan-guard only controls where the relayed traffic is allowed to go. The traffic still leaves from your public IP, so abuse by proxy customers is still attributed to your connection.

## Testing

`tests/run.sh` is an end-to-end test. It needs Docker with compose and internet access:

```
docker build -t lan-guard:dev .
IMAGE=lan-guard:dev sh tests/run.sh
```

It starts a compose project with the guard, a client behind it, a control container that is not behind the guard, and a web server published on the host. It then checks:

- the guard becomes healthy and the client, which waits on `service_healthy`, starts
- the control container reaches the same targets without the guard, so a blocked result is really lan-guard's doing and not Docker's isolation
- the host service is blocked through the guard
- the internet is reachable (1.1.1.1:443)
- DNS works (a lookup of github.com)
- `lan-guard health` passes on an intact guard
- health catches a bypass rule inserted into OUTPUT
- health catches a flushed OUTPUT chain

The same script runs in CI as part of the build workflow, on every pull request and on pushes to main.

## Images

- Published to `ghcr.io/joly0/lan-guard` and `docker.io/joly0/lan-guard` for linux/amd64, linux/arm64 and linux/arm/v7.
- Releases get the exact version tag (for example 1.2.3), the major.minor tag (for example 1.2), the major tag in both spellings (`1` and `v1`) and `latest`, so `1` always points at the newest 1.x release and `latest` at the newest release overall. `edge` tracks the main branch. The examples above use `1`.
- A scheduled weekly rebuild keeps the Alpine base current with security updates.

## Credits

The sidecar approach, sharing the network namespace through `network_mode: "service:..."`, granting `NET_ADMIN` only to the guard, and gating dependents on a healthcheck-driven `depends_on`, was inspired by [aevrin/filter](https://hub.docker.com/r/aevrin/filter), an allowlist-based filter container. lan-guard is an independent implementation: no code was taken from it (its source is not published under an open license), and it blocks a default list of private ranges instead of filtering by an allowlist.

## License

AGPL-3.0, see [LICENSE](LICENSE).
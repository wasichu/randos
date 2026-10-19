# coturn audit (2026-10-19)

**Decisions (2026-10-19):** option C (harden in place now, then rebuild from
cloud-init), logging **errors only** (`log-min-level=error`, native in
coturn 4.18), infra on **OpenTofu with encrypted, committed state**.

**Status:** the hardened config is in `cloud-init.yaml.tftpl` / `variables.tf`
(pinned `coturn/coturn:4.18.0`, `denied-peer-ip` incl. metadata and
IPv4-mapped IPv6, `no-tcp-relay`, `no-multicast-peers`, `external-ip`
mapped reserved→anchor from metadata, `total-quota`/`max-bps`, errors-only
logs with Docker log rotation, key/conf `0640 root:nogroup` since the image
runs as `nobody`, relay range 49152–65535, TTL 3600). **Not applied.**
Step A applies the same turnserver.conf on the live host once SSH works;
step B is `just tofu apply` after state is rebuilt by import.

Read-only audit of the TURN/STUN server (`randos-coturn`, DigitalOcean nyc3,
reserved IP 129.212.147.247 = `turn.slowinput.org`). Nothing was changed.

**Method and limits.** Repo review of `infra/coturn/`, `doctl` reads, and
external probes. SSH was not possible from this machine: the DO firewall
allows port 22 only from 73.155.84.140/32, and the only DO SSH key isn't the
local key. So on-host state (exact coturn version, live `turnserver.conf`,
logs, ufw, patch level) is **inferred from the repo**, not observed.
Terraform state is not on this machine, and `terraform` isn't installed here.

## Verified

- STUN answers on 3478 (UDP and TCP). An unauthenticated Allocate gets
  `401` with `realm=turn.slowinput.org`, which matches the app's TURN REST
  credentials (`use-auth-secret`; username `<expiry>`, HMAC-SHA1 password).
- TLS on 5349: cert valid until 2026-12-21 (renewed 2026-09-22, so the
  renewal hook has worked once). TLS 1.0/1.1 refused, 1.2/1.3 OK.
- Ubuntu 24.04 LTS image; droplet created 2026-05-24; `s-1vcpu-1gb`.
- No DO monitoring alerts, no uptime checks, no snapshots/backups.
- TCP 80 times out from outside although the DO firewall allows it, which
  points to an on-host drop. HTTP-01 renewal (next ~2026-11-21) may fail.

## From the repo (cloud-init `infra/coturn/cloud-init.yaml.tftpl`)

| # | Severity | Finding | Where |
| --- | --- | --- | --- |
| 1 | High | **coturn image is unpinned and pulled once at bootstrap** (`docker pull coturn/coturn`). The running version is whatever `latest` was on 2026-05-24 (likely 4.11.x), never updated. Upstream is 4.18.0. Fixed since then: loopback-guard bypass via `::ffff:127.0.0.1` (4.13.0), TCP-relay peer-IP check bypass (4.13.1), IPv6 `denied-peer-ip` bypass (4.16.0), and mobility-only quota/memory issues (4.17.0). Every site visitor gets valid credentials, so "authenticated" attacks are effectively anonymous. | `:137` |
| 2 | High | **No `denied-peer-ip`.** The relay can be pointed at private, VPC (10.108.0.0/20), loopback, and **metadata (169.254.169.254)** addresses. DO metadata serves `user_data`, which contains the TURN shared secret, so a visitor could relay to metadata, steal the secret, and mint unlimited credentials (inferred, not tested). | `:81-99` |
| 3 | High (product) | **IP logging vs. the anonymity promise.** `log-file=stdout` goes to Docker's json-file log with no rotation, kept on disk. coturn's default session logs include client and peer IPs and the username timestamp, which links two callers' IPs. | `:98`, `docker run` has no `--log-opt` |
| 4 | Medium | **No abuse limits:** no `user-quota`, `total-quota`, `max-bps`/`bps-capacity`, `no-tcp-relay`, or `no-multicast-peers`, on a 1 vCPU / 1 GB box. | `:81-99` |
| 5 | Medium | **Relay capacity is tiny.** `min-port 49152`–`max-port 49252` is 100 ports, so roughly 100 concurrent relay allocations (~50 relayed calls). | `variables.tf:62-71` |
| 6 | Medium | **No `external-ip`/`relay-ip`.** The host has a public IP, a reserved IP, and a VPC address; coturn may advertise the wrong relay address (inferred). | `:81-99` |
| 7 | Low | Secret is in TF state (location unknown), droplet `user_data`/metadata, `/etc/randos-coturn.env`, and a world-readable `turnserver.conf`; private key copy is `0644`. | `:100-106` |
| 8 | Low | `turn_credential_ttl_seconds` defaults to 900; the app now raises anything below 2400 (default 3600). | `variables.tf:86-89` |
| 9 | Info | DO provider pinned 2.87.0 (latest 2.106.0); image slug floats (`ubuntu-24-04-x64`). | `.terraform.lock.hcl` |
| 10 | Info | **Drift:** SSH ingress live is `73.155.84.140/32`, repo default `0.0.0.0/0`; the override isn't in the repo. | `variables.tf:36-39` |

## Proposed config (both rollout options use this)

```
# cloud-init turnserver.conf additions
external-ip=<reserved IP>/<droplet private IP>   # verify on host first
no-multicast-peers
no-tcp-relay                # browsers relay UDP; TCP to peers isn't needed
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=198.18.0.0-198.19.255.255
denied-peer-ip=224.0.0.0-255.255.255.255
denied-peer-ip=::1
denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff
total-quota=…  max-bps=…    # sized to the droplet
no-stdout-log + syslog off / or simple-log with no per-session IPs
```

Plus a **pinned image tag** (`coturn/coturn:4.18.0`, upgraded deliberately),
`docker run --log-driver none` (or `--log-opt max-size/max-file` if some
logging is wanted), a wider relay port range with matching firewall rule,
`0600` on the conf and key, and TTL default 3600.

Not using `user-quota`: all credentials minted in the same second share a
username (the expiry timestamp), so a per-user quota would couple strangers.

## Rollout options

- **A. Harden in place.** SSH in from the allowed IP, edit
  `/etc/coturn/turnserver.conf`, recreate the container from the pinned image
  with logging limits, and fix port 80. Minutes, a few seconds of downtime.
  The repo still has to be updated to match, or it drifts further.
- **B. Rebuild from updated cloud-init.** Change the template, then
  `terraform apply`. The reserved IP keeps DNS stable. Reproducible, but a
  `user_data` change replaces the droplet, and it needs the TF state (not on
  this machine), working port 80 for certbot, and a secret rotation (the
  old secret is in old metadata/state).
- **C. A now, then B.** Close the SSRF and stale-version exposure today; do the
  reproducible rebuild later, adding a remote TF backend and DO
  monitoring/alerts.

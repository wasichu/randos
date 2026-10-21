# randos coturn (OpenTofu)

This directory contains OpenTofu (Terraform-compatible) config and cloud-init for a reproducible
DigitalOcean Droplet that runs coturn for randos WebRTC calls.

## What It Provisions

- DigitalOcean provider configuration
- Ubuntu Droplet
- Uploaded DigitalOcean SSH key from an existing local public key
- DigitalOcean firewall rules for SSH, Let's Encrypt HTTP-01, STUN/TURN, TURN
  over TLS, and the UDP relay port range
- Optional reserved IP assigned to the Droplet
- Generated TURN shared secret when one is not supplied
- Rendered cloud-init `user_data` that bootstraps Docker, certbot, and coturn
- Outputs for DNS and future randos TURN configuration

## DNS

The default TURN hostname and realm are:

```text
turn.slowinput.org
```

DNS is managed manually in Cloudflare. OpenTofu does not create Cloudflare
resources.

After `tofu apply`, create this Cloudflare record manually:

```text
A record:
  turn.slowinput.org -> <dns_target_ip output>
```

The Cloudflare record must be **DNS only**. Do not proxy TURN traffic through
Cloudflare.

## Bootstrap Flow

On first boot, cloud-init runs:

```bash
/usr/local/sbin/randos-coturn-bootstrap
```

The bootstrap script:

1. Updates apt package lists.
2. Installs Docker, certbot, curl, DNS tools, netcat, and ufw.
3. Enables and starts Docker.
4. Attempts Let's Encrypt HTTP-01 certificate issuance for `turn_hostname`.
5. Writes `/etc/coturn/turnserver.conf`.
6. Copies the Let's Encrypt cert and key into `/etc/coturn/certs/` for the
   Docker container to read.
7. Installs a certbot deploy hook that refreshes those cert copies and restarts
   coturn after renewal.
8. Enables the certbot systemd timer.
9. Starts coturn in Docker when certificate files are present.

The coturn container uses host networking:

```bash
docker run ... --network host coturn/coturn -c /etc/coturn/turnserver.conf
```

The server is configured for:

```text
stun:turn.slowinput.org:3478
turn:turn.slowinput.org:3478
turns:turn.slowinput.org:5349
```

## DNS Timing And Certbot Recovery

OpenTofu does not assume DNS already exists during `tofu apply`. If
Cloudflare DNS is not ready when the Droplet first boots, certbot may fail.
That is expected and handled gracefully.

The bootstrap will leave coturn container startup deferred when certificate
files are missing. After creating the DNS-only Cloudflare record and waiting for
propagation, SSH into the Droplet and rerun:

```bash
sudo /usr/local/sbin/randos-coturn-bootstrap
```

Verify DNS from your machine:

```bash
dig turn.slowinput.org
nslookup turn.slowinput.org
```

Verify DNS from the Droplet:

```bash
dig turn.slowinput.org
```

Inspect certificates:

```bash
sudo certbot certificates
```

If coturn reports default certificate filenames such as
`turn_server_cert.pem` or `turn_server_pkey.pem`, rerun the bootstrap so it
refreshes `/etc/coturn/certs/` and restarts the container with explicit cert and
key arguments:

```bash
sudo /usr/local/sbin/randos-coturn-bootstrap
sudo docker logs coturn --tail 200
sudo ss -tulpn | grep -E '(:3478|:5349)'
```

## Required Inputs

`do_token` is required and sensitive. Pass it with an environment variable:

```bash
export TF_VAR_do_token="dop_v1_..."
```

`ssh_public_key_path` is also required. OpenTofu reads this public key,
uploads it to DigitalOcean, and associates it with the Droplet.

Example SSH key generation:

```bash
ssh-keygen -t ed25519 -C "randos-coturn" -f ~/.ssh/randos-coturn
```

Then pass:

```bash
export TF_VAR_ssh_public_key_path="$HOME/.ssh/randos-coturn.pub"
```

Set a Let's Encrypt email when possible:

```bash
export TF_VAR_letsencrypt_email="you@example.com"
```

## Important Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `project_name` | `randos-coturn` | Resource name prefix. |
| `region` | `nyc3` | DigitalOcean region. |
| `droplet_size` | `s-1vcpu-1gb-amd` | Small inexpensive Droplet size. |
| `ssh_public_key_path` | none | Existing local SSH public key path. |
| `ssh_allowed_cidrs` | `[]` | CIDRs allowed to SSH. Empty means no SSH rule; `0.0.0.0/0` is rejected. Set your IPs in `terraform.tfvars`. |
| `turn_hostname` | `turn.slowinput.org` | Public TURN hostname. |
| `turn_realm` | `turn.slowinput.org` | coturn realm. |
| `turn_shared_secret` | `null` | If unset, OpenTofu generates a secret. |
| `relay_min_port` | `49152` | Minimum UDP relay port. |
| `relay_max_port` | `65535` | Maximum UDP relay port (one port per relayed participant). |
| `letsencrypt_email` | empty | Email for certbot registration. |
| `assign_reserved_ip` | `true` | Create and assign a DigitalOcean reserved IP. |
| `turn_credential_ttl_seconds` | `3600` | TTL to set for the app's TURN credentials (the app enforces ≥ 2400). |
| `coturn_image` | `coturn/coturn:4.18.0` | Pinned image; bump deliberately after checking releases/advisories. |
| `total_quota` | `400` | Max concurrent relay allocations. |
| `max_bps` | `32000` | Per-allocation bandwidth cap (bytes/s); voice needs ~8 KB/s. |

## Firewall

Inbound rules:

- TCP `22` from `ssh_allowed_cidrs` (no SSH rule if empty)
- TCP `80` from anywhere for Let's Encrypt HTTP-01 validation
- UDP `3478` from anywhere for STUN/TURN
- TCP `3478` from anywhere for STUN/TURN over TCP
- TCP `5349` from anywhere for TURN over TLS
- UDP relay range from `relay_min_port` to `relay_max_port`

Outbound TCP, UDP, and ICMP are allowed.

## State (encrypted and committed)

`terraform.tfstate` in this directory **is committed**, encrypted with
OpenTofu state encryption (AES-GCM, key derived from a passphrase; see the
`encryption` block in `versions.tf`). Encryption is enforced: OpenTofu refuses
to write plaintext state or plans.

- The passphrase lives in your password manager and, on macOS, in the
  Keychain item `randos-tofu-state-passphrase`, which `just tofu …` reads.
  Create it once (generates a random passphrase without printing it):
  `security add-generic-password -a "$USER" -s randos-tofu-state-passphrase -w "$(openssl rand -base64 32)"`,
  then copy it into your password manager:
  `security find-generic-password -s randos-tofu-state-passphrase -w | pbcopy`.
  Elsewhere, export `TF_VAR_state_passphrase` instead.
- The DigitalOcean token comes from `doctl auth token` (context `default`, or
  `DO_CONTEXT=<name> just tofu …`); `TF_VAR_do_token` overrides it. Read-only
  is enough for `plan`/`import`; `apply` needs a write-scoped context.
- Commit `terraform.tfstate` after every `apply`/`import`. Don't commit
  `terraform.tfstate.backup` (ignored).
- Losing the passphrase means losing the state, not the infrastructure: it can
  be rebuilt with `tofu import` (see below).

### Rebuilding state from live resources

```bash
tofu import 'digitalocean_ssh_key.coturn' <ssh key id>        # doctl compute ssh-key list
tofu import 'digitalocean_droplet.coturn' <droplet id>         # doctl compute droplet list
tofu import 'digitalocean_firewall.coturn' <firewall id>       # doctl compute firewall list
tofu import 'digitalocean_reserved_ip.coturn[0]' <reserved ip> # doctl compute reserved-ip list
tofu import 'digitalocean_reserved_ip_assignment.coturn[0]' <reserved ip>,<droplet id>
```

`random_password.turn_shared_secret` can't be imported without the live
secret; leaving it out means the next `apply` generates a new secret (and
replaces the droplet), which is the intended rotation path.

## Commands

Initialize (from the repo root, `just tofu init`; or inside this directory):

```bash
cd infra/coturn
tofu init
```

Review the plan:

```bash
tofu plan
```

Apply the infrastructure:

```bash
tofu apply
```

The expected flow is:

1. Run `tofu apply`.
2. Read the `dns_target_ip` output.
3. Create the manual Cloudflare DNS-only A record.
4. Verify DNS resolution.
5. Rerun the bootstrap script if initial certbot issuance happened before DNS
   was ready.

Destroy the infrastructure:

```bash
tofu destroy
```

After destroy, verify the Droplet and reserved IP are gone in the DigitalOcean
UI.

## Outputs

OpenTofu outputs:

- Droplet public IP
- Reserved IP, when enabled
- DNS target IP
- TURN hostname
- TURN realm
- UDP relay port range
- Sensitive TURN shared secret
- Sensitive example randos environment variables

To display sensitive outputs after apply:

```bash
tofu output turn_shared_secret
tofu output randos_environment
```

## Inspecting The Server

SSH as root:

```bash
ssh root@$(tofu output -raw dns_target_ip)
```

Inspect bootstrap logs:

```bash
sudo tail -n 200 /var/log/randos-coturn-bootstrap.log
sudo tail -n 200 /var/log/cloud-init-output.log
```

Inspect Docker and coturn:

```bash
sudo systemctl status docker
sudo docker ps
sudo docker logs coturn
```

Restart coturn:

```bash
sudo docker restart coturn
```

Rerun the full bootstrap:

```bash
sudo /usr/local/sbin/randos-coturn-bootstrap
```

Check listening ports on the Droplet:

```bash
sudo ss -tulpn | grep -E '(:3478|:5349)'
```

Check port reachability from your machine:

```bash
nc -vz turn.slowinput.org 3478
nc -vz turn.slowinput.org 5349
```

UDP reachability is harder to verify with basic shell tools, but coturn logs and
WebRTC ICE connection behavior will show whether UDP relay traffic is working.

## Certificate Renewal

Certbot's systemd timer is enabled by the bootstrap:

```bash
sudo systemctl status certbot.timer
```

A deploy hook is installed at:

```text
/etc/letsencrypt/renewal-hooks/deploy/restart-coturn
```

When certbot renews the certificate, the hook restarts the `coturn` container so
it picks up renewed cert files.

You can test renewal behavior without changing certificates:

```bash
sudo certbot renew --dry-run
```

certbot renews over HTTP-01 with `--standalone`: it listens on port 80
only for the seconds a renewal takes. So port 80 normally doesn't answer
from outside (connections time out), and that's not a fault: this
droplet's certificate was issued that way at boot, and the previous one
renewed that way. Let's Encrypt no longer emails expiry warnings, so
`.github/workflows/cert-check.yml` checks the live certificate daily and
fails (emailing the repository owner) once fewer than 21 days are left,
which means a renewal (due 30 days before expiry) has failed.

## Security Notes

coturn uses TURN REST API shared-secret authentication:

```conf
use-auth-secret
static-auth-secret=...
```

It does not create static username/password users and does not run as an open
relay.

The TURN shared secret is written to:

```text
/etc/randos-coturn.env
/etc/coturn/turnserver.conf
```

`/etc/randos-coturn.env` remains root-readable only. The mounted coturn config
and cert files under `/etc/coturn` are readable by the container process so the
Docker image can load its config and TLS key:

```text
/etc/coturn/turnserver.conf
/etc/coturn/certs/privkey.pem
```

The Phoenix app will later use the same shared secret to generate temporary TURN
credentials for browsers.

TURN relays encrypted WebRTC packets only when direct peer-to-peer connectivity
fails. TURN does not give randos server-side audio access, and it is not
recording infrastructure. It is fallback relay infrastructure.

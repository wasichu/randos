# Randos coturn Terraform

This directory contains Terraform and cloud-init for a reproducible
DigitalOcean Droplet that runs coturn for Randos WebRTC calls.

## What It Provisions

- DigitalOcean provider configuration
- Ubuntu Droplet
- Uploaded DigitalOcean SSH key from an existing local public key
- DigitalOcean firewall rules for SSH, Let's Encrypt HTTP-01, STUN/TURN, TURN
  over TLS, and the UDP relay port range
- Optional reserved IP assigned to the Droplet
- Generated TURN shared secret when one is not supplied
- Rendered cloud-init `user_data` that bootstraps Docker, certbot, and coturn
- Outputs for DNS and future Randos TURN configuration

## DNS

The default TURN hostname and realm are:

```text
turn.slowinput.org
```

DNS is managed manually in Cloudflare. Terraform does not create Cloudflare
resources.

After `terraform apply`, create this Cloudflare record manually:

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
6. Installs a certbot deploy hook that restarts coturn after renewal.
7. Enables the certbot systemd timer.
8. Starts coturn in Docker when certificate files are present.

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

Terraform does not assume DNS already exists during `terraform apply`. If
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

## Required Inputs

`do_token` is required and sensitive. Pass it with an environment variable:

```bash
export TF_VAR_do_token="dop_v1_..."
```

`ssh_public_key_path` is also required. Terraform reads this public key,
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
| `droplet_size` | `s-1vcpu-1gb` | Small inexpensive Droplet size. |
| `ssh_public_key_path` | none | Existing local SSH public key path. |
| `ssh_allowed_cidr` | `0.0.0.0/0` | CIDR allowed to connect to SSH. Tighten this when possible. |
| `turn_hostname` | `turn.slowinput.org` | Public TURN hostname. |
| `turn_realm` | `turn.slowinput.org` | coturn realm. |
| `turn_shared_secret` | `null` | If unset, Terraform generates a secret. |
| `relay_min_port` | `49152` | Minimum UDP relay port. |
| `relay_max_port` | `49252` | Maximum UDP relay port. |
| `letsencrypt_email` | empty | Email for certbot registration. |
| `assign_reserved_ip` | `true` | Create and assign a DigitalOcean reserved IP. |
| `turn_credential_ttl_seconds` | `900` | Suggested TTL for future Randos TURN credentials. |

## Firewall

Inbound rules:

- TCP `22` from `ssh_allowed_cidr`
- TCP `80` from anywhere for Let's Encrypt HTTP-01 validation
- UDP `3478` from anywhere for STUN/TURN
- TCP `3478` from anywhere for STUN/TURN over TCP
- TCP `5349` from anywhere for TURN over TLS
- UDP relay range from `relay_min_port` to `relay_max_port`

Outbound TCP, UDP, and ICMP are allowed.

## Commands

Initialize Terraform:

```bash
cd infra/coturn
terraform init
```

Review the plan:

```bash
terraform plan
```

Apply the infrastructure:

```bash
terraform apply
```

The expected flow is:

1. Run `terraform apply`.
2. Read the `dns_target_ip` output.
3. Create the manual Cloudflare DNS-only A record.
4. Verify DNS resolution.
5. Rerun the bootstrap script if initial certbot issuance happened before DNS
   was ready.

Destroy the infrastructure:

```bash
terraform destroy
```

After destroy, verify the Droplet and reserved IP are gone in the DigitalOcean
UI.

## Outputs

Terraform outputs:

- Droplet public IP
- Reserved IP, when enabled
- DNS target IP
- TURN hostname
- TURN realm
- UDP relay port range
- Sensitive TURN shared secret
- Sensitive example Randos environment variables

To display sensitive outputs after apply:

```bash
terraform output turn_shared_secret
terraform output randos_environment
```

## Inspecting The Server

SSH as root:

```bash
ssh root@$(terraform output -raw dns_target_ip)
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

## Security Notes

coturn uses TURN REST API shared-secret authentication:

```conf
use-auth-secret
static-auth-secret=...
```

It does not create static username/password users and does not run as an open
relay.

The TURN shared secret is written to root-readable files only:

```text
/etc/randos-coturn.env
/etc/coturn/turnserver.conf
```

The Phoenix app will later use the same shared secret to generate temporary TURN
credentials for browsers.

TURN relays encrypted WebRTC packets only when direct peer-to-peer connectivity
fails. TURN does not give Randos server-side audio access, and it is not
recording infrastructure. It is fallback relay infrastructure.

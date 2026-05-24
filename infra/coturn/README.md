# Randos coturn Terraform

This directory contains the Terraform scaffold for a reproducible DigitalOcean
Droplet that will eventually run coturn for Randos WebRTC calls.

This task provisions infrastructure only. The actual Docker, certbot, and
coturn bootstrap logic will be added separately.

## What It Provisions

- DigitalOcean provider configuration
- Ubuntu Droplet
- Uploaded DigitalOcean SSH key from an existing local public key
- DigitalOcean firewall rules for SSH, Let's Encrypt HTTP-01, STUN/TURN, TURN
  over TLS, and the UDP relay port range
- Optional reserved IP assigned to the Droplet
- Generated TURN shared secret when one is not supplied
- Rendered cloud-init `user_data` placeholder
- Outputs for DNS and future Randos TURN configuration

## DNS

The default TURN hostname and realm are:

```text
turn.slowinput.com
```

DNS is managed manually in Cloudflare. Terraform does not create Cloudflare
resources.

After `terraform apply`, create this Cloudflare record manually:

```text
A record:
  turn.slowinput.com -> <dns_target_ip output>
```

The Cloudflare record must be **DNS only**. Do not proxy TURN traffic through
Cloudflare.

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

## Important Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `project_name` | `randos-coturn` | Resource name prefix. |
| `region` | `nyc3` | DigitalOcean region. |
| `droplet_size` | `s-1vcpu-1gb` | Small inexpensive Droplet size. |
| `ssh_public_key_path` | none | Existing local SSH public key path. |
| `ssh_allowed_cidr` | `0.0.0.0/0` | CIDR allowed to connect to SSH. Tighten this when possible. |
| `turn_hostname` | `turn.slowinput.com` | Public TURN hostname. |
| `turn_realm` | `turn.slowinput.com` | coturn realm. |
| `turn_shared_secret` | `null` | If unset, Terraform generates a secret. |
| `relay_min_port` | `49152` | Minimum UDP relay port. |
| `relay_max_port` | `49252` | Maximum UDP relay port. |
| `letsencrypt_email` | empty | Email for later certbot bootstrap. |
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
5. Run the future Task 2 bootstrap once implemented.

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

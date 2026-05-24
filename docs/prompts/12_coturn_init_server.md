# Randos coturn Infra Task 1: Terraform DigitalOcean Scaffold

Create the Terraform scaffold for a reproducible coturn server deployment.

Place all infrastructure files under:

```text
infra/coturn/
```

This task should focus on:

- Terraform resources
- variables
- outputs
- firewall configuration
- SSH key wiring
- rendering cloud-init into Droplet `user_data`

Do not fully implement the coturn bootstrap logic yet.

The actual Docker/certbot/coturn bootstrap will be implemented in Task 2.

## Goal

Provision a small Ubuntu DigitalOcean Droplet that will eventually run coturn.

Terraform should manage:

- DigitalOcean provider configuration
- Ubuntu Droplet
- SSH key association
- firewall rules
- optional reserved/static IP if practical
- generated TURN shared secret if one is not supplied
- rendering `cloud-init.yaml.tftpl`
- useful outputs for configuring Randos

## Files to Create

Create:

```text
infra/coturn/
  versions.tf
  variables.tf
  main.tf
  outputs.tf
  cloud-init.yaml.tftpl
  README.md
```

## Provider

Use DigitalOcean.

The DigitalOcean token should come from a sensitive Terraform variable:

```text
do_token
```

Do not hardcode credentials.

## Domain and DNS

Use:

```text
turn.slowinput.com
```

as the default TURN hostname and TURN realm.

DNS is managed manually in Cloudflare.

Do not create Cloudflare resources in Terraform.

Assume the operator will manually create:

```text
A record:
  turn.slowinput.com -> Droplet public IP
```

IMPORTANT:

The Cloudflare record must be:

```text
DNS only (gray cloud)
```

Do not proxy TURN traffic through Cloudflare.

## Expected Deployment Flow

The infrastructure should support this workflow:

```text
1. terraform apply
2. Terraform outputs Droplet public IP
3. operator manually creates Cloudflare DNS record
4. operator verifies DNS resolution
5. Task 2 bootstrap completes successfully
```

Do not assume DNS already exists during `terraform apply`.

## SSH Key Handling

Do not generate SSH private keys inside Terraform.

Assume the operator already has or will manually create an SSH keypair locally.

Terraform should only:

- read an existing public SSH key from disk
- upload the public key to DigitalOcean
- associate the uploaded key with the Droplet

Example workflow:

```bash
ssh-keygen -t ed25519 -C "randos-coturn"
```

Terraform should support a variable such as:

```text
ssh_public_key_path
```

Example usage:

```hcl
public_key = file(var.ssh_public_key_path)
```

Do not:

- generate private SSH keys
- store private keys in Terraform state
- output private keys
- create insecure default SSH credentials

## Variables

Support variables such as:

```text
do_token
project_name
region
droplet_size
ssh_public_key_path
ssh_allowed_cidr
turn_hostname
turn_realm
turn_shared_secret
relay_min_port
relay_max_port
letsencrypt_email
```

Defaults:

```text
project_name = "randos-coturn"
region = "nyc3"
droplet_size = small inexpensive default
turn_hostname = "turn.slowinput.com"
turn_realm = "turn.slowinput.com"
relay_min_port = 49152
relay_max_port = 49252
```

If `turn_shared_secret` is empty or null, generate one with Terraform.

Mark secrets as sensitive.

## Firewall

Create firewall rules for:

- TCP 22 for SSH, restricted to `ssh_allowed_cidr`
- TCP 80 for Let’s Encrypt HTTP-01 validation
- UDP 3478 for STUN/TURN
- TCP 3478 for STUN/TURN over TCP
- TCP 5349 for TURN over TLS
- UDP relay port range from `relay_min_port` to `relay_max_port`

Do not open unnecessary ports.

## cloud-init Template Wiring

Create a placeholder:

```text
cloud-init.yaml.tftpl
```

Terraform should render it with values including:

```text
turn_hostname
turn_realm
turn_shared_secret
relay_min_port
relay_max_port
letsencrypt_email
```

Pass the rendered result into the Droplet as:

```text
user_data
```

The placeholder cloud-init file can be minimal for this task.

It should simply demonstrate that Terraform variable rendering works.

Example placeholder behavior:

- write a small file under `/etc/randos-coturn.env`
- include rendered values
- echo a bootstrap placeholder message

The full Docker/certbot/coturn setup will be implemented in Task 2.

## Outputs

Output:

- Droplet public IP
- TURN hostname
- TURN realm
- relay port range
- sensitive TURN shared secret
- example Randos environment variables

Example env output:

```text
TURN_HOST=turn.slowinput.com
TURN_REALM=turn.slowinput.com
TURN_SHARED_SECRET=...
TURN_CREDENTIAL_TTL_SECONDS=900
```

## README

Create a basic README explaining:

- what this Terraform config provisions
- required variables
- how to run `terraform init`
- how to run `terraform plan`
- how to run `terraform apply`
- how to run `terraform destroy`
- how to generate an SSH keypair locally
- how to manually create the Cloudflare DNS record
- that `turn.slowinput.com` must be DNS-only, not proxied
- how to verify DNS resolution with `dig`
- that Task 2 implements the full bootstrap logic

## Constraints

Do not modify the Phoenix application.

Do not implement TURN credential generation in Phoenix.

Do not add Cloudflare DNS automation.

Do not add Kubernetes, Ansible, or extra orchestration tooling.

Keep this boring, minimal, reproducible, and understandable.

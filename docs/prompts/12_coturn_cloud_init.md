# Randos coturn Infra Task 2: cloud-init Bootstrap

Implement the full `cloud-init.yaml.tftpl` bootstrap for the coturn server.

This task assumes Task 1 already created the Terraform scaffold under:

```text
infra/coturn/
```

Focus on the server bootstrap logic.

Terraform should continue to render this file and pass it to the Droplet as `user_data`.

## Goal

When the DigitalOcean Droplet first boots, cloud-init should configure a working coturn server with:

- Docker
- certbot
- Let’s Encrypt certificate for `turn.slowinput.com`
- coturn running in Docker
- TURN REST API shared-secret authentication
- plain TURN/STUN on port 3478
- TURN over TLS on port 5349
- automatic certificate renewal
- coturn restart after certificate renewal

## Domain

Use the rendered variable:

```text
${turn_hostname}
```

Default value from Terraform should be:

```text
turn.slowinput.com
```

DNS is managed manually in Cloudflare.

The Cloudflare record must be DNS-only, not proxied.

## Important DNS Assumption

Do not assume DNS exists immediately during Droplet creation.

The expected operator workflow is:

```text
1. terraform apply
2. obtain Droplet public IP from Terraform output
3. manually create Cloudflare DNS record
4. wait for DNS propagation
5. verify DNS with dig/nslookup
6. Let’s Encrypt succeeds
```

The bootstrap process should tolerate initial certbot failure gracefully if DNS is not ready yet.

Do not assume Let’s Encrypt issuance always succeeds immediately on first boot.

## Bootstrap Steps

The cloud-init file should:

1. update apt package lists
2. install required packages:
   - docker.io or Docker CE if preferred
   - certbot
   - useful troubleshooting tools such as curl, netcat, ufw if appropriate
3. enable and start Docker
4. attempt to obtain a Let’s Encrypt certificate for `${turn_hostname}`
5. write coturn configuration
6. run coturn in Docker
7. configure automatic certificate renewal
8. restart coturn after certificate renewal

## Let’s Encrypt

Use certbot standalone HTTP-01 validation.

This requires TCP port 80 to be open.

Use rendered variable:

```text
${letsencrypt_email}
```

If certificate issuance initially fails due to DNS propagation, the system should:

- fail gracefully
- leave useful logs
- allow the operator to rerun certbot manually later

Document the manual recovery workflow in the README.

Certificate paths should be:

```text
/etc/letsencrypt/live/${turn_hostname}/fullchain.pem
/etc/letsencrypt/live/${turn_hostname}/privkey.pem
```

## coturn Configuration

Write a config file such as:

```text
/etc/coturn/turnserver.conf
```

It should include:

```conf
listening-port=3478
tls-listening-port=5349

fingerprint
realm=${turn_realm}

use-auth-secret
static-auth-secret=${turn_shared_secret}

min-port=${relay_min_port}
max-port=${relay_max_port}

cert=/etc/letsencrypt/live/${turn_hostname}/fullchain.pem
pkey=/etc/letsencrypt/live/${turn_hostname}/privkey.pem

no-cli
log-file=stdout
```

Do not create an open relay.

Do not use static username/password users.

Use shared-secret authentication.

## Docker

Run coturn via Docker.

Use host networking if appropriate for TURN simplicity.

Example conceptual command:

```bash
docker run -d \
  --name coturn \
  --restart unless-stopped \
  --network host \
  -v /etc/coturn/turnserver.conf:/etc/coturn/turnserver.conf:ro \
  -v /etc/letsencrypt:/etc/letsencrypt:ro \
  coturn/coturn \
  -c /etc/coturn/turnserver.conf
```

A systemd service wrapping the container is acceptable if cleaner.

## Certificate Renewal

Configure automatic renewal using certbot’s systemd timer or cron.

Ensure coturn restarts after renewal so it picks up renewed certs.

A deploy hook is acceptable:

```bash
certbot renew --deploy-hook "docker restart coturn"
```

or equivalent.

## Logging and Debugging

The bootstrap should leave useful logs.

Prefer:

- cloud-init logs
- Docker logs from coturn
- clear troubleshooting commands

Document commands such as:

```bash
docker ps
docker logs coturn
sudo certbot certificates
sudo systemctl status docker
dig turn.slowinput.com
```

## Security

Do not print the TURN shared secret unnecessarily in logs.

Do not write secrets world-readable if avoidable.

Config files containing secrets should use restrictive permissions where practical.

## Expected Services

After successful bootstrap, the server should support:

```text
stun:turn.slowinput.com:3478
turn:turn.slowinput.com:3478
turns:turn.slowinput.com:5349
```

## README Update

Update `infra/coturn/README.md` to explain:

- how bootstrap works
- how DNS setup fits into the workflow
- how certbot obtains certs
- how renewal works
- how to manually rerun certbot if DNS was not ready initially
- how to inspect coturn logs
- how to manually restart coturn
- how to verify DNS resolution
- how to verify opened ports
- how the Phoenix app will later use the TURN shared secret to generate temporary credentials

Also explain:

- coturn relays encrypted WebRTC packets only when direct peer-to-peer fails
- TURN does not give Randos server-side audio access
- TURN is fallback relay infrastructure, not recording infrastructure

## Constraints

Do not modify the Phoenix app.

Do not add Membrane, SFU, MCU, or server-side media processing.

Do not add Cloudflare DNS automation.

Keep the bootstrap boring, reproducible, understandable, and easy to inspect.

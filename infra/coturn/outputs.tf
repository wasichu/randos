output "droplet_public_ip" {
  description = "Public IPv4 address assigned directly to the coturn Droplet."
  value       = digitalocean_droplet.coturn.ipv4_address
}

output "reserved_public_ip" {
  description = "Reserved IPv4 address assigned to the coturn Droplet, when enabled."
  value       = var.assign_reserved_ip ? digitalocean_reserved_ip.coturn[0].ip_address : null
}

output "dns_target_ip" {
  description = "IP address to use for the manual Cloudflare DNS-only A record."
  value       = var.assign_reserved_ip ? digitalocean_reserved_ip.coturn[0].ip_address : digitalocean_droplet.coturn.ipv4_address
}

output "turn_hostname" {
  description = "TURN hostname."
  value       = var.turn_hostname
}

output "turn_realm" {
  description = "TURN realm."
  value       = var.turn_realm
}

output "relay_port_range" {
  description = "UDP relay port range opened by the firewall."
  value       = local.relay_port_range
}

output "turn_shared_secret" {
  description = "coturn static auth secret. Store this securely."
  value       = local.turn_shared_secret
  sensitive   = true
}

output "randos_environment" {
  description = "Example environment variables for configuring Randos once TURN support is wired into the app."
  sensitive   = true
  value       = <<-EOT
    TURN_HOST=${var.turn_hostname}
    TURN_SERVER_URL=turn:${var.turn_hostname}:3478
    TURNS_SERVER_URL=turns:${var.turn_hostname}:5349
    TURN_REALM=${var.turn_realm}
    TURN_SHARED_SECRET=${local.turn_shared_secret}
    TURN_CREDENTIAL_TTL_SECONDS=${var.turn_credential_ttl_seconds}
  EOT
}

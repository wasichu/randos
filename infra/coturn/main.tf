locals {
  turn_shared_secret = (
    var.turn_shared_secret != null && trimspace(var.turn_shared_secret) != ""
  ) ? var.turn_shared_secret : random_password.turn_shared_secret.result

  relay_port_range = "${var.relay_min_port}-${var.relay_max_port}"

  common_tags = [
    var.project_name,
    "coturn",
    "randos"
  ]
}

resource "random_password" "turn_shared_secret" {
  length  = 48
  special = false
}

resource "digitalocean_ssh_key" "coturn" {
  name       = "${var.project_name}-ssh"
  public_key = file(var.ssh_public_key_path)
}

resource "digitalocean_droplet" "coturn" {
  name     = var.project_name
  region   = var.region
  size     = var.droplet_size
  image    = var.droplet_image
  ssh_keys = [digitalocean_ssh_key.coturn.fingerprint]
  tags     = local.common_tags

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    project_name             = var.project_name
    turn_hostname            = var.turn_hostname
    turn_realm               = var.turn_realm
    turn_shared_secret       = local.turn_shared_secret
    relay_min_port           = var.relay_min_port
    relay_max_port           = var.relay_max_port
    letsencrypt_email        = var.letsencrypt_email
    turn_credential_ttl_secs = var.turn_credential_ttl_seconds
  })
}

resource "digitalocean_reserved_ip" "coturn" {
  count  = var.assign_reserved_ip ? 1 : 0
  region = var.region
}

resource "digitalocean_reserved_ip_assignment" "coturn" {
  count      = var.assign_reserved_ip ? 1 : 0
  ip_address = digitalocean_reserved_ip.coturn[0].ip_address
  droplet_id = digitalocean_droplet.coturn.id
}

resource "digitalocean_firewall" "coturn" {
  name        = "${var.project_name}-firewall"
  droplet_ids = [digitalocean_droplet.coturn.id]
  tags        = local.common_tags

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = [var.ssh_allowed_cidr]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "udp"
    port_range       = "3478"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "3478"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "5349"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "udp"
    port_range       = local.relay_port_range
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

variable "state_passphrase" {
  description = "Passphrase that encrypts the OpenTofu state and plans (at least 16 characters). Keep it in a password manager; set TF_VAR_state_passphrase."
  type        = string
  sensitive   = true
}

variable "do_token" {
  description = "DigitalOcean API token used by the provider."
  type        = string
  sensitive   = true
}

variable "project_name" {
  description = "Name prefix used for DigitalOcean resources."
  type        = string
  default     = "randos-coturn"
}

variable "region" {
  description = "DigitalOcean region for the coturn Droplet."
  type        = string
  default     = "nyc3"
}

variable "droplet_size" {
  description = "DigitalOcean Droplet size slug."
  type        = string
  default     = "s-1vcpu-1gb-amd"
}

variable "droplet_image" {
  description = "Ubuntu image slug for the coturn Droplet."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "ssh_public_key_path" {
  description = "Path to an existing local SSH public key to upload and associate with the Droplet."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to SSH (TCP 22). Empty (the default) means no SSH access; set your own IPs in terraform.tfvars. Never 0.0.0.0/0."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.ssh_allowed_cidrs, "0.0.0.0/0") && !contains(var.ssh_allowed_cidrs, "::/0")
    error_message = "SSH must not be open to the whole internet."
  }
}

variable "turn_hostname" {
  description = "Public TURN hostname. DNS is managed manually outside Terraform."
  type        = string
  default     = "turn.slowinput.org"
}

variable "turn_realm" {
  description = "TURN realm."
  type        = string
  default     = "turn.slowinput.org"
}

variable "turn_shared_secret" {
  description = "coturn static auth secret. If empty or null, Terraform generates one."
  type        = string
  default     = null
  nullable    = true
  sensitive   = true
}

variable "relay_min_port" {
  description = "Minimum UDP relay port for coturn."
  type        = number
  default     = 49152
}

variable "relay_max_port" {
  description = "Maximum UDP relay port for coturn."
  type        = number
  default     = 65535
}

variable "letsencrypt_email" {
  description = "Email address certbot will use for Let's Encrypt registration in a later bootstrap task."
  type        = string
  default     = ""
}

variable "assign_reserved_ip" {
  description = "Whether Terraform should create and assign a DigitalOcean reserved IP to the Droplet."
  type        = bool
  default     = true
}

variable "turn_credential_ttl_seconds" {
  description = "Suggested TTL for Randos-generated temporary TURN credentials."
  type        = number
  default     = 3600
}

variable "coturn_image" {
  description = "Pinned coturn Docker image. Upgrade deliberately (check https://github.com/coturn/coturn/releases and security advisories)."
  type        = string
  default     = "coturn/coturn:4.18.0"
}

variable "total_quota" {
  description = "Max concurrent relay allocations (one per relayed participant)."
  type        = number
  default     = 400
}

variable "max_bps" {
  description = "Per-allocation bandwidth cap in bytes/second. Opus voice needs ~8 KB/s; 32000 leaves headroom while preventing bulk relaying."
  type        = number
  default     = 32000
}

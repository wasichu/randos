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
  default     = "s-1vcpu-1gb"
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

variable "ssh_allowed_cidr" {
  description = "CIDR range allowed to connect to SSH on TCP 22."
  type        = string
  default     = "0.0.0.0/0"
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
  default     = 49252
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
  default     = 900
}

terraform {
  # OpenTofu (pinned in mise.toml). State encryption needs >= 1.8.
  required_version = ">= 1.9.0"

  # State and plans are always encrypted (enforced), so the state file can be
  # committed: it contains the TURN shared secret. The passphrase lives only
  # in your password manager; export it as TF_VAR_state_passphrase.
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = ">= 2.34.0, < 3.0.0"
    }

    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0, < 4.0.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

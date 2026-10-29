variable "port" {
  type    = number
  default = 2222
}

variable "alice_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "samba" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  workgroup = "HOMELAB"

  shares = {
    family = {
      path        = "/srv/samba/family"
      comment     = "Family files"
      writable    = true
      valid_users = ["alice"]
      owner       = "alice"
      mode        = "0770"
    }
    public = {
      path     = "/srv/samba/public"
      comment  = "Read-only, no password"
      guest_ok = true
    }
  }

  users          = ["alice"]
  user_passwords = { alice = var.alice_password }
}

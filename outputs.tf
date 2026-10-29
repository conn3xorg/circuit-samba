output "config_file" {
  description = "Path of the Samba configuration the circuit writes on each host."
  value       = "/etc/samba/smb.conf"
}

output "shares" {
  description = "Share names, each mapped to its path."
  value       = { for name, s in var.shares : name => s.path }
}

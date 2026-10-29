variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "workgroup" {
  type        = string
  default     = "WORKGROUP"
  description = "Workgroup or NetBIOS domain name the server shows in. WORKGROUP is what Windows uses out of the box."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,14}$", var.workgroup))
    error_message = "workgroup uses letters, digits, ., - and _, and is at most 15 characters."
  }
}

variable "server_string" {
  type        = string
  default     = "Samba %v on %h"
  description = "Description the server gives clients. Samba expands %h to the host name and %v to its version."

  validation {
    condition     = !can(regex("[\\n\\r]", var.server_string))
    error_message = "server_string must be one line."
  }
}

variable "min_protocol" {
  type        = string
  default     = "SMB2"
  description = "Oldest SMB dialect the server accepts. SMB1 stays off at any setting here."

  validation {
    condition     = contains(["SMB2", "SMB2_02", "SMB2_10", "SMB3", "SMB3_00", "SMB3_02", "SMB3_11"], var.min_protocol)
    error_message = "min_protocol is one of SMB2, SMB2_02, SMB2_10, SMB3, SMB3_00, SMB3_02 or SMB3_11."
  }
}

variable "netbios" {
  type        = bool
  default     = false
  description = "Run nmbd and listen on port 139, so older clients can find the server by NetBIOS name. Off, the server answers on 445 only."
}

variable "shares" {
  type = map(object({
    path           = string
    comment        = optional(string)
    writable       = optional(bool, false)
    browseable     = optional(bool, true)
    guest_ok       = optional(bool, false)
    valid_users    = optional(list(string), [])
    create_mask    = optional(string, "0664")
    directory_mask = optional(string, "0775")
    owner          = optional(string)
    group          = optional(string)
    mode           = optional(string, "0755")
  }))
  default     = {}
  description = "Shares, by name, such as { media = { path = \"/srv/media\", writable = true, valid_users = [\"alice\"] } }. The circuit creates each path with owner, group and mode."

  validation {
    condition     = alltrue([for name in keys(var.shares) : can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$", name)) && !contains(["global", "homes", "printers", "print$", "ipc$"], lower(name))])
    error_message = "Share names use letters, digits, ., - and _, and can't be global, homes, printers or IPC$."
  }

  validation {
    condition     = alltrue([for s in values(var.shares) : can(regex("^/[A-Za-z0-9_./-]*[A-Za-z0-9_.-]$", s.path)) && !strcontains(s.path, "..") && !contains(["/", "/etc", "/usr", "/var", "/root", "/boot", "/home"], s.path)])
    error_message = "A share's path must be an absolute path of letters, digits, ., -, _ and /, with no trailing slash or .., and not a system directory such as / or /etc."
  }

  validation {
    condition     = alltrue([for s in values(var.shares) : s.comment == null || can(regex("^[^\\n\\r\\[\\]]*$", coalesce(s.comment, "-")))])
    error_message = "A share's comment must be one line without [ or ]."
  }

  validation {
    condition     = alltrue(flatten([for s in values(var.shares) : [for u in s.valid_users : can(regex("^[@+&]{0,2}[a-z_][a-z0-9_.-]{0,31}$", u))]]))
    error_message = "Each of valid_users is a user name, or a group name after @, such as \"alice\" or \"@family\"."
  }

  validation {
    condition     = alltrue([for s in values(var.shares) : alltrue([for m in [s.create_mask, s.directory_mask, s.mode] : can(regex("^0?[0-7]{3,4}$", m))])])
    error_message = "create_mask, directory_mask and mode are octal, such as \"0664\"."
  }
}

variable "users" {
  type        = list(string)
  default     = []
  description = "Samba users, each with a password in user_passwords. A user needs a Unix account of the same name; the circuit creates one with no login shell when it's missing."

  validation {
    condition     = alltrue([for u in var.users : can(regex("^[a-z_][a-z0-9_-]{0,31}$", u)) && !contains(["root", "nobody"], u)])
    error_message = "User names use lowercase letters, digits, - and _, start with a letter or _, are at most 32 characters, and can't be root or nobody."
  }
}

variable "user_passwords" {
  type        = map(string)
  default     = {}
  ephemeral   = true
  sensitive   = true
  nullable    = false
  description = "Password for each of users, by name. Pass it at run time with -var or TF_VAR_user_passwords; it never reaches state or the plan."

  validation {
    condition     = alltrue([for u in var.users : length(lookup(var.user_passwords, u, "")) > 0 && !can(regex("[\\n\\r]", lookup(var.user_passwords, u, "")))])
    error_message = "Each of users needs a non-empty, one-line password in user_passwords."
  }
}

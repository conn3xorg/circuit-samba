# Facts give each host's distribution, which picks the service names and
# whether SELinux labels need setting.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  family = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "debian" : "redhat" }

  redhat_hosts = { for name, h in var.hosts : name => h if local.family[name] == "redhat" }

  # Debian and Ubuntu name the units after the daemons; the Red Hat family
  # drops the d.
  smbd = { for name, f in local.family : name => f == "debian" ? "smbd" : "smb" }
  nmbd = { for name, f in local.family : name => f == "debian" ? "nmbd" : "nmb" }

  password_dir = "/etc/conn3x/samba"

  # Guests only get in when some share lets them. "Bad User" maps a name
  # Samba doesn't know to the guest account; a known name with the wrong
  # password is still refused.
  guest = anytrue([for s in values(var.shares) : s.guest_ok])

  bool = { true = "yes", false = "no" }

  # Printing is off: this is a file server, and on the Red Hat family the
  # defaults otherwise look for CUPS.
  smb_conf = join("\n", concat(
    [
      <<-EOT
      # Written by Conn3x. Changes here are overwritten on the next apply.
      [global]
      workgroup = ${var.workgroup}
      server string = ${var.server_string}
      server role = standalone server
      security = user
      passdb backend = tdbsam
      server min protocol = ${var.min_protocol}
      map to guest = ${local.guest ? "Bad User" : "Never"}
      disable netbios = ${local.bool[!var.netbios]}
      smb ports = ${var.netbios ? "445 139" : "445"}
      load printers = no
      printing = bsd
      printcap name = /dev/null
      disable spoolss = yes
      EOT
    ],
    [
      for name, s in var.shares : "${join("\n", compact([
        "[${name}]",
        "path = ${s.path}",
        s.comment == null ? "" : "comment = ${s.comment}",
        "read only = ${local.bool[!s.writable]}",
        "browseable = ${local.bool[s.browseable]}",
        "guest ok = ${local.bool[s.guest_ok]}",
        length(s.valid_users) == 0 ? "" : "valid users = ${join(" ", s.valid_users)}",
        "create mask = ${s.create_mask}",
        "directory mask = ${s.directory_mask}",
      ]))}\n"
    ],
  ))
}

circuit "samba" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "server" {
    package {
      name = "samba"
    }
  }

  # A Samba user needs a Unix account of the same name, which owns what it
  # writes. An account that's missing gets one with no home and no login
  # shell; one that exists, such as from circuit-users, is left alone.
  step "account" {
    for_each = toset(var.users)
    command {
      command = "useradd -M -s /usr/sbin/nologin '${item.key}'"
      unless  = "id -u '${item.key}' >/dev/null 2>&1"
    }
  }

  step "share_dir" {
    for_each = var.shares
    directory {
      path  = item.value.path
      owner = item.value.owner
      group = item.value.group
      mode  = item.value.mode
    }
  }

  step "config" {
    file {
      path    = "/etc/samba/smb.conf"
      content = local.smb_conf
    }
    notify = [handler.reload]
  }

  # testparm parses the file as smbd will, so a bad value fails the apply
  # before anything reloads, and the running server keeps what it had.
  step "check" {
    command {
      command  = "testparm -s /etc/samba/smb.conf >/dev/null"
      triggers = { config = conn3x_file.samba__config[each.key].revision }
    }
  }

  # smbd only changes the ports it listens on when it restarts, and on
  # Debian and Ubuntu the package has already started it on 139 as well as
  # 445. This runs on a host's first apply and when netbios changes; other
  # changes only need the reload.
  step "restart" {
    command {
      command  = "systemctl restart ${local.smbd[each.key]}"
      triggers = { netbios = var.netbios }
    }
  }

  step "running" {
    service {
      name    = local.smbd[each.key]
      state   = "started"
      enabled = true
    }
  }

  # Debian and Ubuntu start nmbd when the package installs. With NetBIOS
  # off it has nothing to do, and a stray name server on a LAN is one more
  # thing answering broadcasts.
  step "nmbd" {
    service {
      name    = local.nmbd[each.key]
      state   = var.netbios ? "started" : "stopped"
      enabled = var.netbios
    }
  }

  step "password_dir" {
    directory {
      path = local.password_dir
      mode = "0700"
    }
  }

  # Each password lands in a root-only file, never in state or the plan.
  step "password" {
    for_each = toset(var.users)
    file {
      path       = "${local.password_dir}/${item.key}"
      content_wo = var.user_passwords[item.key]
    }
  }

  # Adds the user to Samba's own password database when it's missing from
  # it. The password goes to smbpasswd on stdin, through printf, which is a
  # shell builtin, so it never shows in ps.
  step "smbuser" {
    for_each = toset(var.users)
    command {
      command = "p=$(cat '${local.password_dir}/${item.key}') && printf '%s\\n%s\\n' \"$p\" \"$p\" | smbpasswd -s -a '${item.key}' >/dev/null"
      unless  = "pdbedit -u '${item.key}' >/dev/null 2>&1"
    }
  }

  # Sets the password again when its file changed or the user was added.
  step "set_password" {
    for_each = toset(var.users)
    command {
      command = "p=$(cat '${local.password_dir}/${item.key}') && printf '%s\\n%s\\n' \"$p\" \"$p\" | smbpasswd -s -a '${item.key}' >/dev/null"
      triggers = {
        password = conn3x_file.samba__password["${each.key}/${item.key}"].revision
        smbuser  = conn3x_command.samba__smbuser["${each.key}/${item.key}"].revision
      }
    }
  }

  handler "reload" {
    service {
      name   = local.smbd[each.key]
      action = "reload"
    }
  }
}

# SELinux only lets smbd read and write files labelled samba_share_t. Each
# share path, and everything under it, gets that label, on hosts where
# SELinux is on. The rule lives in the policy store, so a relabel keeps it.
circuit "samba_selinux" {
  hosts = local.redhat_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "semanage" {
    package {
      name = "policycoreutils-python-utils"
    }
    depends_on = [conn3x_directory.samba__share_dir]
  }

  step "label" {
    for_each = var.shares
    command {
      command = "semanage fcontext -a -t samba_share_t '${item.value.path}(/.*)?' 2>/dev/null || semanage fcontext -m -t samba_share_t '${item.value.path}(/.*)?'; restorecon -R '${item.value.path}'"
      unless  = "! selinuxenabled 2>/dev/null || { semanage fcontext -l -C | awk -v p='${item.value.path}(/.*)?' '$1 == p' | grep -q ':samba_share_t:' && [ \"$(stat -c %C '${item.value.path}' | cut -d: -f3)\" = samba_share_t ]; }"
    }
  }
}

# circuit-samba

A Conn3x circuit that turns a Linux box into a file server for the Windows, macOS and Linux machines around it, with Samba. You list the shares and who can use them; the circuit installs Samba, creates the folders, writes `smb.conf`, checks it with `testparm`, and adds each user to Samba with the password you pass at run time. It's the file-sharing half of a homelab NAS, or the shared drive in a small office.

The defaults are the ones you'd pick by hand today. SMB1 is off and the oldest dialect accepted is SMB2. NetBIOS is off too, so `nmbd` doesn't run and the server listens on 445 only. On Rocky Linux and Fedora with SELinux enforcing, each share's folder gets the `samba_share_t` label, so smbd can read and write it without turning SELinux off.

## Usage

```hcl
variable "samba_passwords" {
  type      = map(string)
  ephemeral = true
  sensitive = true
}

module "samba" {
  source = "github.com/conn3xorg/circuit-samba?ref=v0.1.0"

  hosts                = { nas = "192.168.1.20" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  workgroup = "HOMELAB"

  shares = {
    family = {
      path        = "/srv/samba/family"
      comment     = "Family files"
      writable    = true
      valid_users = ["@family"]
      group       = "family"
      mode        = "0770"
    }
    media = {
      path     = "/srv/samba/media"
      guest_ok = true
    }
  }

  users          = ["alice", "bob"]
  user_passwords = var.samba_passwords
}
```

Then pass the passwords and apply:

```sh
export TF_VAR_samba_passwords='{"alice":"...","bob":"..."}'
conn3x init
conn3x apply
```

A second `conn3x plan` says `No changes.` On Windows, open `\\192.168.1.20\family` in File Explorer; on a Mac, Finder's Go > Connect to Server with `smb://192.168.1.20/family`.

To try it on a throwaway container first, see [examples/local](examples/local).

### Passwords

`user_passwords` is ephemeral and sensitive, so passwords never reach the plan, saved plan files or state. Each one lands in a root-only file under `/etc/conn3x/samba` on the host, written with `content_wo`, which records only an HMAC in state. From there the circuit hands it to `smbpasswd` on stdin. Change a password in `user_passwords` and the next apply sets the new one.

`users` is a separate list because OpenTofu can't loop over the keys of an ephemeral value.

### Unix accounts

Samba maps every user to a Unix account of the same name, which owns the files that user writes. When the account is missing, the circuit creates it with `useradd -M -s /usr/sbin/nologin`: no home directory and no shell, so the password only opens shares, not SSH. An account that already exists is left exactly as it is.

So if you manage people with [circuit-users](https://github.com/conn3xorg/circuit-users), give them their accounts, groups and UIDs there and put `depends_on = [module.users]` on this module. Samba then uses those accounts instead. With `depends_on`, give each host's `os` too, as below.

The circuit doesn't create groups. A `valid_users` entry such as `@family`, or a share's `group`, needs the group to exist already, from circuit-users or by hand.

### Guest access

A share with `guest_ok = true` lets anyone on the network in without a password, as the `nobody` account. When any share does, the server maps a user name it doesn't know to the guest account (`map to guest = Bad User`). A name it does know with the wrong password is still refused, and shares without `guest_ok` still want a real login. Leave `writable` off on a guest share unless you mean anyone on the LAN to fill it.

### Hosts created in the same plan

Pass host objects with the host key you generated, and give each one's distribution in `os`, since Conn3x can't ask a host that doesn't exist yet which service names it uses. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module.

```hcl
hosts = {
  for name, d in digitalocean_droplet.nas : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "rocky"
  }
}
```

## What it does

On each host, in order:

1. Installs `samba`.
2. Creates a Unix account, with no home and no login shell, for each of `users` that doesn't have one.
3. Creates each share's folder with its `owner`, `group` and `mode`.
4. Writes `/etc/samba/smb.conf` and checks it with `testparm -s`. A value Samba rejects fails the apply before anything reloads, and the running server keeps what it had.
5. Restarts smbd on a host's first apply and when `netbios` changes, since that's the only way it picks up which ports to listen on. On Debian and Ubuntu the package has already started it listening on 139 as well as 445.
6. Starts smbd now and at boot (`smbd` on Debian and Ubuntu, `smb` on the Red Hat family). Stops and disables nmbd unless `netbios` is on.
7. Writes each password to `/etc/conn3x/samba/<user>`, adds the user to Samba's password database when it's missing from it, and sets the password again when it changes.
8. Reloads smbd when `smb.conf` changed, which picks up share changes without dropping clients.
9. On Rocky Linux, AlmaLinux, RHEL and Fedora, installs `policycoreutils-python-utils` and gives each share path, and everything under it, the `samba_share_t` label with `semanage fcontext` and `restorecon`. The rule lives in the SELinux policy store, so a full relabel keeps it. Hosts with SELinux off skip the labelling.

The `[global]` section sets `server role = standalone server`, `security = user` and the `tdbsam` password backend, and turns printer sharing off. Share options map one to one: `writable` to `read only`, `browseable`, `guest_ok` to `guest ok`, `valid_users`, `create_mask` and `directory_mask`.

### What it doesn't do

- It doesn't open the firewall. Allow TCP 445, and 137-139 if `netbios` is on, with [circuit-firewall](https://github.com/conn3xorg/circuit-firewall) or your own rules, and only from the networks that should see your files.
- It doesn't join an Active Directory domain or act as a domain controller. This is a standalone server with its own users.
- It doesn't share home directories (`[homes]`) or printers.
- Deleting a user from `users` leaves them in Samba's password database and leaves their Unix account; remove them with `smbpasswd -x` and `userdel` if you want them gone. Deleting a share takes it out of `smb.conf` but leaves the folder and its files.
- SELinux labels aren't removed when a share goes away.
- Pointing a share at a folder another confined service uses, such as `/var/www`, relabels it for Samba and takes it away from that service. Keep shares in folders of their own, such as under `/srv/samba`.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"192.168.1.20"`, or a host object such as `{ address = "192.168.1.20", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `workgroup` | string | `"WORKGROUP"` | Workgroup the server shows in, up to 15 characters. `WORKGROUP` is what Windows uses out of the box. |
| `server_string` | string | `"Samba %v on %h"` | Description clients see. Samba expands `%h` to the host name and `%v` to its version. |
| `min_protocol` | string | `"SMB2"` | Oldest SMB dialect accepted: `SMB2`, `SMB2_02`, `SMB2_10`, `SMB3`, `SMB3_00`, `SMB3_02` or `SMB3_11`. SMB1 is never on. |
| `netbios` | bool | `false` | Run nmbd and listen on 139 as well as 445, so older clients can find the server by NetBIOS name. Changing it restarts smbd. |
| `shares` | map(object) | `{}` | Shares, by name. Each takes `path`, which must be absolute and not a system folder such as `/etc` or `/home`, and optional `comment`, `writable` (default `false`), `browseable` (default `true`), `guest_ok` (default `false`), `valid_users` (user names, or `@group`; empty lets any Samba user in), `create_mask` (default `"0664"`), `directory_mask` (default `"0775"`), and the folder's `owner`, `group` and `mode` (default `"0755"`). A share can't be named `global`, `homes`, `printers` or `IPC$`. |
| `users` | list(string) | `[]` | Samba users. Each needs a password in `user_passwords`, and gets a Unix account with no login shell if it doesn't have one. Can't be `root` or `nobody`. |
| `user_passwords` | map(string), ephemeral | `{}` | Password for each of `users`, by name, one line each. Pass it at run time with `-var` or `TF_VAR_user_passwords`. |

## Outputs

| Name | Description |
| --- | --- |
| `config_file` | Path of the file the circuit writes, `/etc/samba/smb.conf`. |
| `shares` | Share names, each mapped to its path, such as `{ family = "/srv/samba/family" }`. |

## Requirements

Requires Conn3x v0.6.5 or later and systemd on each host, with a package mirror the host can reach. Samba comes from each distribution's own repositories.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64 and checks that the second plan has no changes. Then, with `smbclient` on the host, it lists the shares, puts a file on the private share as `alice` and gets it back, checks the file is owned by `alice`, and checks that a wrong password, a guest on the private share, a guest writing to the read-only guest share, and anything on port 139 are all refused. By hand, the same container runs also changed `alice`'s password: the new one worked, the old one was refused, and neither appeared in the state file.

The CI containers run with SELinux off. On an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet with SELinux enforcing, the same checks passed, before and after a reboot, and the plan after the reboot had no changes. On Rocky, smbd ran confined as `smbd_t`, the uploaded file was labelled `samba_share_t`, and the audit log had no denials.

## License

MPL-2.0. See [LICENSE](LICENSE). Samba itself is GPL-3.0.

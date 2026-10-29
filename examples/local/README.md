# Local example

Applies circuit-samba to a throwaway Rocky Linux 10 container with systemd: a private, writable `family` share for `alice`, and a read-only `public` share guests can open without a password. You need Conn3x and Podman.

The container runs systemd, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
export TF_VAR_alice_password='correct horse 9'
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` The password comes from `TF_VAR_alice_password` on every run and never lands in the state file. To try the shares, install the client in the container and log in as alice:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1
dnf -y install samba-client
smbclient -N -L //127.0.0.1
smbclient //127.0.0.1/family -U 'alice%correct horse 9' -c ls
```

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.

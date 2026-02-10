#!/bin/sh
set -e

echo "tinfoil-ssh-installer: starting"

# Validate required environment variable
if [ -z "$SSH_AUTHORIZED_KEYS" ]; then
    echo "tinfoil-ssh-installer: ERROR - SSH_AUTHORIZED_KEYS not set (pass via secrets in external config)"
    exit 1
fi

DROPBEAR_DIR=/host/mnt/ramdisk/dropbear

# 1. Set up directory structure on the ramdisk (writable)
echo "tinfoil-ssh-installer: setting up ramdisk directory"
mkdir -p "$DROPBEAR_DIR/.ssh"

# 2. Copy dropbear binary from container to CVM host ramdisk
echo "tinfoil-ssh-installer: copying dropbear to host ramdisk"
cp /usr/sbin/dropbear "$DROPBEAR_DIR/dropbear"
chmod +x "$DROPBEAR_DIR/dropbear"

# 3. Write authorized keys to ramdisk
echo "tinfoil-ssh-installer: writing authorized keys"
echo "$SSH_AUTHORIZED_KEYS" > "$DROPBEAR_DIR/.ssh/authorized_keys"
chmod 700 "$DROPBEAR_DIR/.ssh"
chmod 600 "$DROPBEAR_DIR/.ssh/authorized_keys"

# 4. Bind mount ramdisk dropbear dir over /root on the CVM host
#    This works even on a read-only root filesystem (VFS-level overlay).
#    Dropbear looks for authorized_keys at ~/.ssh/authorized_keys,
#    so after this mount, /root/.ssh/authorized_keys points to our ramdisk file.
echo "tinfoil-ssh-installer: bind mounting over /root on host"
nsenter -t 1 -m -u -i -n -- mount --bind /mnt/ramdisk/dropbear /root

# 5. Write systemd unit to runtime directory (/run/systemd/system/ is writable tmpfs)
echo "tinfoil-ssh-installer: creating systemd service on host"
cat > /host/run/systemd/system/dropbear-debug.service <<'UNIT'
[Unit]
Description=Dropbear SSH Server (Debug)
After=network.target

[Service]
ExecStart=/mnt/ramdisk/dropbear/dropbear -F -E -R -r /mnt/ramdisk/dropbear/dropbear_ed25519_host_key -p 22
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

# 6. Start dropbear on the CVM host via nsenter
#    systemd creates the process in its own cgroup, so it survives container exit.
echo "tinfoil-ssh-installer: starting dropbear on host via systemd"
nsenter -t 1 -m -u -i -n -- systemctl daemon-reload
nsenter -t 1 -m -u -i -n -- systemctl start dropbear-debug

echo "tinfoil-ssh-installer: dropbear SSH server installed and running on CVM host"

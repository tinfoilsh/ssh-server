#!/bin/sh
set -e

echo "tinfoil-ssh-installer: starting"

# Validate required environment variable
if [ -z "$SSH_AUTHORIZED_KEYS" ]; then
    echo "tinfoil-ssh-installer: ERROR - SSH_AUTHORIZED_KEYS not set (pass via secrets in external config)"
    exit 1
fi

# Layout on the ramdisk:
#   /mnt/ramdisk/dropbear/bin/       - dropbear binaries
#   /mnt/ramdisk/dropbear/lib/       - shared libraries
#   /mnt/ramdisk/dropbear/etc/       - host keys
#   /mnt/ramdisk/dropbear/home/      - bind-mounted over /root (clean home dir)
#   /mnt/ramdisk/dropbear/home/.ssh/ - authorized_keys

BASE=/host/mnt/ramdisk/dropbear

# 1. Set up directory structure on the ramdisk (writable)
echo "tinfoil-ssh-installer: setting up ramdisk directory"
mkdir -p "$BASE/bin" "$BASE/lib" "$BASE/etc" "$BASE/home/.ssh"

# 2. Copy dropbear binaries and all shared library dependencies to CVM host ramdisk
echo "tinfoil-ssh-installer: copying dropbear binaries to host ramdisk"
cp /usr/sbin/dropbear "$BASE/bin/dropbear"
cp /usr/bin/dropbearkey "$BASE/bin/dropbearkey"
chmod +x "$BASE/bin/dropbear" "$BASE/bin/dropbearkey"

# Copy all shared library dependencies so dropbear can run on the CVM host
# which may not have these libs installed (e.g., libtomcrypt, libtommath)
echo "tinfoil-ssh-installer: copying shared libraries"
for bin in /usr/sbin/dropbear /usr/bin/dropbearkey; do
    ldd "$bin" | awk '/=>/ {print $3}' | while read -r lib; do
        if [ -f "$lib" ] && [ ! -f "$BASE/lib/$(basename "$lib")" ]; then
            cp "$lib" "$BASE/lib/"
            echo "tinfoil-ssh-installer:   copied $(basename "$lib")"
        fi
    done
done

# 3. Pre-generate host key on the ramdisk
#    We do this BEFORE starting dropbear so it never tries to write to /etc/dropbear/
#    (which is on the read-only root filesystem)
echo "tinfoil-ssh-installer: generating host key"
LD_LIBRARY_PATH="$BASE/lib" "$BASE/bin/dropbearkey" -t ed25519 -f "$BASE/etc/dropbear_ed25519_host_key"

# 4. Write authorized keys to ramdisk
echo "tinfoil-ssh-installer: writing authorized keys"
echo "$SSH_AUTHORIZED_KEYS" > "$BASE/home/.ssh/authorized_keys"
chmod 700 "$BASE/home/.ssh"
chmod 600 "$BASE/home/.ssh/authorized_keys"

# 5. Bind mount the clean home directory over /root on the CVM host
#    This works even on a read-only root filesystem (VFS-level overlay).
#    Dropbear looks for authorized_keys at ~/.ssh/authorized_keys,
#    so after this mount, /root/.ssh/authorized_keys points to our ramdisk file.
echo "tinfoil-ssh-installer: bind mounting home over /root on host"
nsenter -t 1 -m -u -i -n -- mount --bind /mnt/ramdisk/dropbear/home /root

# 6. Write systemd unit to runtime directory (/run/systemd/system/ is writable tmpfs)
#    Note: no -R flag -- we pre-generated the host key above so dropbear never
#    needs to write to /etc/dropbear/ (which is read-only).
echo "tinfoil-ssh-installer: creating systemd service on host"
cat > /host/run/systemd/system/dropbear-debug.service <<'UNIT'
[Unit]
Description=Dropbear SSH Server (Debug)
After=network.target

[Service]
Environment=LD_LIBRARY_PATH=/mnt/ramdisk/dropbear/lib
ExecStart=/mnt/ramdisk/dropbear/bin/dropbear -F -E -r /mnt/ramdisk/dropbear/etc/dropbear_ed25519_host_key -p 22
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

# 7. Start dropbear on the CVM host via nsenter
#    systemd creates the process in its own cgroup, so it survives container exit.
echo "tinfoil-ssh-installer: starting dropbear on host via systemd"
nsenter -t 1 -m -u -i -n -- systemctl daemon-reload
nsenter -t 1 -m -u -i -n -- systemctl start dropbear-debug

echo "tinfoil-ssh-installer: dropbear SSH server installed and running on CVM host"

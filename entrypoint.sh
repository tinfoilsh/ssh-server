#!/bin/sh
set -eu

# Tinfoil Debug SSH Installer
# Runs once inside a privileged container to install Dropbear on the CVM host.
# All state goes to /mnt/ramdisk (tmpfs), nothing touches the read-only root.

log() { echo "tinfoil-ssh-installer: $1"; }
die() { echo "tinfoil-ssh-installer: ERROR - $1" >&2; exit 1; }

# Clean up temp files on any exit (success or failure)
cleanup() { rm -f "${BASE:-/nonexistent}/etc/"*.pem "${BASE:-/nonexistent}/etc/"*.tmp 2>/dev/null || true; }
trap cleanup EXIT

# --- Validate inputs -----------------------------------------------------------

[ -n "${SSH_AUTHORIZED_KEYS:-}" ] || die "SSH_AUTHORIZED_KEYS not set (pass via secrets in external config)"

# Sanity-check: every non-empty line must look like an SSH public key.
# Uses here-doc (not pipe) so die() exits the main shell, not a subshell.
while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*|sk-ssh-*|ssh-dss\ *) ;;
        \#*) ;;  # allow comments
        *) die "SSH_AUTHORIZED_KEYS contains invalid line: ${line%% *}..." ;;
    esac
done <<EOF
$SSH_AUTHORIZED_KEYS
EOF

# --- Layout on the ramdisk -----------------------------------------------------
#   /mnt/ramdisk/dropbear/bin/       - static binaries
#   /mnt/ramdisk/dropbear/etc/       - host key
#   /mnt/ramdisk/dropbear/home/      - bind-mounted over /root
#   /mnt/ramdisk/dropbear/home/.ssh/ - authorized_keys

BASE=/host/mnt/ramdisk/dropbear

# 1. Directory structure
log "setting up ramdisk directory"
mkdir -p "$BASE/bin" "$BASE/etc" "$BASE/home/.ssh"

# 2. Copy static binaries (no shared libraries needed)
log "copying static binaries to host ramdisk"
cp /usr/local/bin/dropbear \
   /usr/local/bin/dropbearkey \
   /usr/local/bin/dropbearconvert \
   /usr/local/bin/scp \
   /usr/local/bin/sftp-server \
   "$BASE/bin/"
chmod 755 "$BASE/bin/"*

# 3. Host key setup
#    Accepts OpenSSH PEM format (native output of ssh-keygen / Go crypto/ssh).
#    Converted to Dropbear format at install time via dropbearconvert.
#    If not provided, generates an ephemeral key (changes every boot).
HOST_KEY="$BASE/etc/dropbear_ed25519_host_key"
if [ -n "${SSH_HOST_KEY:-}" ]; then
    case "$SSH_HOST_KEY" in
        "-----BEGIN OPENSSH PRIVATE KEY-----"*)
            log "converting OpenSSH host key to Dropbear format"
            printf '%s\n' "$SSH_HOST_KEY" > "$BASE/etc/hostkey.pem"
            chmod 600 "$BASE/etc/hostkey.pem"
            "$BASE/bin/dropbearconvert" openssh dropbear "$BASE/etc/hostkey.pem" "$HOST_KEY" \
                || die "dropbearconvert failed — is SSH_HOST_KEY a valid OpenSSH ed25519 private key?"
            ;;
        *)
            die "SSH_HOST_KEY must be an OpenSSH PEM private key (-----BEGIN OPENSSH PRIVATE KEY-----). Generate with: ssh-keygen -t ed25519 -f host_key -N ''"
            ;;
    esac
    chmod 600 "$HOST_KEY"
else
    log "generating ephemeral host key (set SSH_HOST_KEY secret for stable identity)"
    "$BASE/bin/dropbearkey" -t ed25519 -f "$HOST_KEY"
fi

# 4. Write authorized keys and shell profile
log "writing authorized keys"
printf '%s\n' "$SSH_AUTHORIZED_KEYS" > "$BASE/home/.ssh/authorized_keys"
chmod 700 "$BASE/home/.ssh"
chmod 600 "$BASE/home/.ssh/authorized_keys"

# Start SSH sessions at / instead of ~ (more useful for debugging)
printf 'cd /\n' > "$BASE/home/.profile"

# 5. Bind mount clean home over /root on CVM host
#    Works on read-only root (VFS-level overlay). After this,
#    /root/.ssh/authorized_keys points to our ramdisk file.
log "bind mounting home over /root on host"
nsenter -t 1 -m -u -i -n -- mount --bind /mnt/ramdisk/dropbear/home /root

# 6. Systemd unit in /run (writable tmpfs)
log "creating systemd service on host"
cat > /host/run/systemd/system/dropbear-debug.service <<'UNIT'
[Unit]
Description=Dropbear SSH Server (Debug)
After=network.target

[Service]
ExecStart=/mnt/ramdisk/dropbear/bin/dropbear -F -E -r /mnt/ramdisk/dropbear/etc/dropbear_ed25519_host_key -p 22
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

# 7. Start dropbear — systemd owns the process, survives container exit
log "starting dropbear on host via systemd"
nsenter -t 1 -m -u -i -n -- systemctl daemon-reload
nsenter -t 1 -m -u -i -n -- systemctl start dropbear-debug

log "dropbear SSH server installed and running on CVM host"

#!/bin/bash
set -e

echo "Building statically-linked Linux binary for pecan-agent natively..."
swift build -c release --product pecan-agent --swift-sdk swift-6.2.4-RELEASE_static-linux-0.1.0

VM_DIR="$HOME/.pecan/vm"
mkdir -p "$VM_DIR"

echo "Downloading Alpine Linux kernel..."
if [ ! -f "$VM_DIR/vmlinuz" ]; then
    curl -L -o "$VM_DIR/vmlinuz" "https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/netboot/vmlinuz-virt"
fi

echo "Creating custom initramfs..."
ROOTFS_DIR="/tmp/pecan_builder_rootfs"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"
cd "$ROOTFS_DIR"

echo "Downloading Alpine minirootfs..."
curl -sL "https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/alpine-minirootfs-3.19.1-aarch64.tar.gz" | tar -xz

echo "Copying compiled pecan-agent binary..."
cp "$OLDPWD/.build/aarch64-swift-linux-musl/release/pecan-agent" "$ROOTFS_DIR/bin/pecan-agent"
chmod +x "$ROOTFS_DIR/bin/pecan-agent"

echo "Injecting custom init script..."
cat << 'EOF' > "$ROOTFS_DIR/init"
#!/bin/sh
export PATH=/sbin:/bin:/usr/sbin:/usr/bin

# Redirect all output to the virtio console
exec >/dev/console 2>&1

echo "========================================="
echo " Starting Pecan Agent VM"
echo "========================================="

echo "Mounting essential filesystems..."
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

echo "Setting up networking..."
ip link set lo up
ip link set eth0 up
udhcpc -i eth0 -n -q

# Identify the Host IP
HOST_IP=$(ip route show default | awk '/default/ {print $3}')

# Parse kernel command line for session_id
SESSION_ID=""
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        session_id=*) SESSION_ID="${arg#*=}" ;;
    esac
done

if [ -z "$SESSION_ID" ]; then
    echo "ERROR: session_id not found in kernel command line!"
    exec /bin/sh
fi

echo "Executing agent..."
/bin/pecan-agent "$SESSION_ID" "$HOST_IP"

echo "Agent process terminated. Powering off..."
poweroff -f
EOF
chmod +x "$ROOTFS_DIR/init"

echo "Packaging initramfs..."
find . -print0 | cpio --null --create --format=newc | gzip > "$VM_DIR/initrd.img"
cd "$OLDPWD"

echo "Done! The Linux VM assets have been provisioned in $VM_DIR"
echo "You can now run ./dev_restart.sh to start the server with the VZLinuxSpawner enabled."

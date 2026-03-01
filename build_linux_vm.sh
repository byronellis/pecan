#!/bin/bash
set -e

echo "Setting up PecanBuilder VM Environment..."

VM_DIR="$HOME/.pecan/vm"
mkdir -p "$VM_DIR"

echo "Downloading Alpine Linux kernel..."
if [ ! -f "$VM_DIR/vmlinuz" ]; then
    curl -L -o "$VM_DIR/vmlinuz" "https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/netboot/vmlinuz-virt"
fi

echo "Compiling PecanBuilder helper (macOS native)..."
swift build -c release --product pecan-builder

echo "Codesigning PecanBuilder with Virtualization entitlement..."
codesign --entitlements Entitlements.plist -f -s - .build/release/pecan-builder

echo "Launching native compilation VM..."
.build/release/pecan-builder

echo "Done! If successful, the Linux agent binary is located at .build/aarch64-unknown-linux-gnu/release/pecan-agent"

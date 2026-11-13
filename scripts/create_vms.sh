#!/bin/bash
set -euo pipefail

IMG=/var/lib/libvirt/images
BASE=$IMG/noble-base.img
SSH_KEY=$(cat /home/${SUDO_USER:-$USER}/.ssh/id_ed25519.pub)
GW=192.168.122.1

# name  ip              mac                 vcpus  ram(MB)
VMS=(
  "jumpbox 192.168.122.10 52:54:00:00:00:0a 1 512"
  "server  192.168.122.11 52:54:00:00:00:0b 1 2048"
  "node-0  192.168.122.12 52:54:00:00:00:0c 1 2048"
  "node-1  192.168.122.13 52:54:00:00:00:0d 1 2048"
)

for vm in "${VMS[@]}"; do
  read -r name ip mac vcpus ram <<< "$vm"
  work=$(mktemp -d)

  cat > "$work/user-data" <<EOF
#cloud-config
hostname: $name
manage_etc_hosts: true
ssh_authorized_keys:
  - $SSH_KEY
EOF

  cat > "$work/network-config" <<EOF
version: 2
ethernets:
  eth0:
    match:
      macaddress: "$mac"
    set-name: eth0
    addresses: [$ip/24]
    routes:
      - to: default
        via: $GW
    nameservers:
      addresses: [$GW, 1.1.1.1]
EOF

  qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$IMG/$name.qcow2" 20G
  cloud-localds --network-config "$work/network-config" \
       "$IMG/$name-seed.iso" "$work/user-data"

  virt-install \
    --name "$name" \
    --vcpus "$vcpus" \
    --memory "$ram" \
    --disk path="$IMG/$name.qcow2",format=qcow2 \
    --disk path="$IMG/$name-seed.iso",device=cdrom \
    --network network=default,mac="$mac" \
    --osinfo detect=on,require=off \
    --import \
    --graphics none \
    --noautoconsole

  rm -rf "$work"
  echo "Created $name at $ip"
done

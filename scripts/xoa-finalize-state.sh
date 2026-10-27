#!/bin/bash
# Image-build-only: remove the build's default XO database before exporting.
set -euo pipefail
systemctl stop xo-server.service
systemctl stop redis.service
if [ -f /etc/redis/redis.conf ]; then
    conf=/etc/redis/redis.conf
else
    conf=/etc/redis.conf
fi
[ -f "$conf" ]
# Strip active duplicates, then make these authoritative on every boot.
sed -i -E '/^[[:space:]]*(appendonly|appendfsync)[[:space:]]/d' "$conf"
printf '\n# XOA-HL crash durability (xcp-hl#311)\nappendonly yes\nappendfsync everysec\n' >> "$conf"
# An IP address is XO Lite's signal to clear XAPI provisioning keys. Do not
# bring up networking if phase 1 failed to durably capture those credentials.
mkdir -p /etc/systemd/system/NetworkManager.service.d
printf '[Unit]\nRequires=xoa-first-boot.service\nAfter=xoa-first-boot.service\n' \
    > /etc/systemd/system/NetworkManager.service.d/xoa-provisioning.conf
# This is a fresh, disposable build VM, never an upgrade/migration operation.
# Refuse unexpected storage locations rather than exporting a stale database.
dir=$(awk '$1 == "dir" { gsub(/"/, "", $2); print $2 }' "$conf")
[ "$dir" = /var/lib/redis ] || { echo 'Unexpected Redis data directory'; exit 1; }
rm -rf /var/lib/redis/*
rm -f /etc/xoa-first-boot.env /etc/xoa-first-boot.env.tmp /var/lib/xoa-credentials.done
sync

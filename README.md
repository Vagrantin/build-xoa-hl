# build-xoa-hl-vm

Packer-based pipeline that builds the **XOA Home-laber Edition VM appliance** (AlmaLinux 9) on an XCP-ng hypervisor, producing the XVA image that XO Lite CE deploys.

## Layout

```text
.
├── build.config.sample   # Infrastructure config: XCP-ng host credentials, AlmaLinux ISO,
│                         # VM name/passwords, xe-guest-utilities URLs
├── scripts/
│   ├── setup-xoa-builder.sh   # Runs on the build machine: loads build.config, generates
│   │                          # the Kickstart (inst.ks) and Packer JSON, launches the build
│   ├── xoa-first-boot.sh      # In-VM: reads XO Lite xenstore provisioning data on first boot
│   └── xoa-credentials.sh     # In-VM phase 2: sets XO admin credentials via xo-cli, then
│                              # disables itself (falls back to admin@admin.net / admin)
├── systemd/
│   ├── xoa-first-boot.service
│   └── xoa-credentials.service
├── bin/                  # Vendored binaries (VMware VDDK tarball for V2V support)
└── artefact/             # Build/debug artefacts: logs, installed-RPM list, preseed, memo
```

## Usage

1. Copy `build.config.sample` to `build.config` and fill in your XCP-ng host IP/credentials, network name, and passwords.
2. Run `scripts/setup-xoa-builder.sh` from the build machine (developed on Linux Mint).
3. Packer installs AlmaLinux via Kickstart, provisions xe-guest-utilities, and installs the first-boot systemd units so the resulting appliance self-configures (xenstore data, then admin credentials) when deployed through XO Lite.

⚠️ `build.config` contains plaintext credentials — never commit it.

## Related

- `../xoa-hl` — builds the patched Xen Orchestra that runs inside this VM.
- `../xolite-ce` — the XO Lite build that deploys this image.
- `../xoa-proxy` — HTTPS/gzip bridge used during image deployment.

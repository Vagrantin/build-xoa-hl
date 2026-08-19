# build-xoa-hl-vm

Packer-based pipeline that builds the **XOA Home-laber Edition VM appliance** (AlmaLinux 9) on an XCP-ng hypervisor, producing the XVA image that XO Lite CE deploys.

## Layout

```text
.
├── build.config.sample   # Infrastructure config: XCP-ng host credentials, AlmaLinux ISO,
│                         # VM name/passwords, xoa-hl repo/tag, xe-guest-utilities URLs
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

⚠️ `build.config` contains plaintext credentials, never commit it.

## Which xoa-hl RPM gets installed

`../xoa-hl` publishes one GitHub release per build, tagged `v<version>-ce<N>`,
carrying a single fat RPM that ships the whole Xen Orchestra tree under
`/opt/xo`. There is no separate tarball asset.

`scripts/setup-xoa-builder.sh` resolves that RPM from the GitHub API and never
guesses the filename:

- `XOA_HL_TAG` set (in `build.config` or as an environment variable, the
  environment wins): the release is read from `releases/tags/<tag>` and its
  `.rpm` asset is used. A missing tag or a tag without an RPM aborts the build.
- `XOA_HL_TAG` unset: releases are scanned, only tags matching `v*-ce<N>` are
  kept, and the highest `<N>` that actually carries an RPM is used. The chosen
  tag is echoed in the build log. If nothing matches, the build aborts instead
  of falling back to an arbitrary asset.

`XOA_HL_REPO` (default `Vagrantin/xoa-hl`) selects the source repository.

Pin `XOA_HL_TAG` for reproducible images, the unpinned path is a convenience
for local runs.

## Releases

The XVA appliance is published as a **GitHub Release on this repository**,
tagged `xoa-image-<date>-<sha7>` with the `xoa-almalinux.xva` asset. `<sha7>` is
the `../xoa-hl` commit the image was built from. Releases are created by the
orchestrator's `xoa-vm-agent` (see
[`xcp-orchestrator`](https://github.com/Vagrantin/buildorchestration/tree/main/xcp-orchestrator)),
and XO Lite's deploy button resolves the newest one at deploy time.

Images used to be published on the `xoa-hl` repo
([xcp-hl#22](https://github.com/Vagrantin/xcp-hl/issues/22)); the ones from
before that switch are [still
there](https://github.com/Vagrantin/xoa-hl/releases) so already-shipped ISOs
keep resolving them.

## Related

- `../xoa-hl`, builds the patched Xen Orchestra that runs inside this VM.
- `../xolite-ce`, the XO Lite build that deploys this image.
- `../xoa-proxy`, HTTPS/gzip bridge used during image deployment.

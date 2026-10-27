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
│   └── xoa-credentials.sh     # In-VM phase 2: sets XO admin credentials (JSON-RPC), then
│                              # disables itself only after durable success
├── systemd/
│   ├── xoa-first-boot.service
│   └── xoa-credentials.service
├── bin/                  # Vendored binaries (VMware VDDK tarball for V2V support)
└── artefact/             # Build/debug artefacts: logs, installed-RPM list, preseed, memo
```

## Build and provisioning

Builds run through the CI `build/xoa-vm-agent` pipeline. Its setup script generates the Packer configuration; it is not a workstation build workflow. Packer installs AlmaLinux, guest utilities and the two first-boot services. Keep build credentials in the CI configuration, outside the repository.

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
for unpinned CI builds.

## Releases

The XVA appliance is published as a **GitHub Release on this repository**,
tagged `xoa-image-<date>-<sha7>` with the `XOA-hl.xva` asset. `<sha7>` is
the `../xoa-hl` commit the image was built from. Releases are created by the
orchestrator's `xoa-vm-agent` (see
[`xcp-orchestrator`](https://github.com/Vagrantin/buildorchestration/tree/main/xcp-orchestrator)),
and XO Lite's deploy button resolves the newest one at deploy time.

Images used to be published on the `xoa-hl` repo
([xcp-hl#22](https://github.com/Vagrantin/xcp-hl/issues/22)); the ones from
before that switch are [still
there](https://github.com/Vagrantin/xoa-hl/releases) so already-shipped ISOs
keep resolving them.

## Release stamp

The image carries `/etc/xoa-hl-vm-release`, one readable line such as
`built 2026-10-08, commit abc1234, release v5.113.2_e281c536-ce1`: the build
date, the xoa-hl commit and the xoa-hl release tag the image was built from.
The XOA-HL About page shows it as the VM version.

## Related

- `../xoa-hl`, builds the patched Xen Orchestra that runs inside this VM.
- `../xolite-ce`, the XO Lite build that deploys this image.
- `../xoa-proxy`, HTTPS/gzip bridge used during image deployment.

## Provisioning security (#310 / #311)

Applies to the image rebuilt on 2026-10-27 from `build-xoa-hl@fa0c987`:
`qa-xoa-build-59.xva` in release `xoa-image-20261027-ca44911`, SHA-256
`cc20b9398d5ab0dc03eae6706d3b54236e2d245fa1d0dd1232d59836387057aa`.
The removed `qa-xoa-build-58.xva` used the same tag and About version strings
but did not contain the fix. An application RPM update does not replace the
image's provisioning scripts or migrate its Redis configuration.

Inside the appliance as root, `redis-cli config get appendonly` returns
`appendonly` followed by `yes` on the rebuilt image, versus `no` on the previous
image. This follows `scripts/xoa-finalize-state.sh@fa0c987`. A manually changed
or custom image can also return `yes`; retain the asset name and checksum.

- Phase 1 never dumps XenStore. It finishes network configuration and writes a
  root-only, base64-encoded envelope via atomic rename and filesystem sync
  before removing live guest credential keys. Base64 is encoding, not encryption.
  A retry keeps the existing envelope even after XO Lite has cleared XAPI.
  NetworkManager requires successful phase-1 capture before starting, so an
  early capture failure cannot publish the IP that triggers XAPI cleanup.
- On the rebuilt image, guest cleanup also removed `vm-data/admin-account`
  and `vm-data/system-account-xoa-password` from XAPI's persistent map after
  first boot. This was observed on one XCP-HL v8.3 host, as recorded in
  [xcp-hl#311](https://github.com/Vagrantin/xcp-hl/issues/311#issuecomment-6439980771).
  Do not assume that guest `xenstore-rm` has the same effect for older images,
  Vates, Ronivay, custom images, or failed or abandoned deployments. Keep the
  XO Lite deployment tab open until completion. After credentials are applied,
  check for remaining keys on the host and remove them if present, including
  `vm-data/xoa-updater-credentials`. The companion `Vagrantin/xolite-ce` cleanup
  fix covers other image sources too. Existing metadata backups, exports and
  old first-boot logs can contain secrets and require credential rotation.
- Finalization stops XO and Redis, removes all build-time database state from
  the fresh build VM, and enables AOF with `appendfsync everysec`. It must
  never run on an existing installation. The image does not carry the build's
  default administrator database.
- Phase 2 requires AOF, uses `appendfsync always` during credential mutation,
  updates the original default user, verifies a fresh login, checks `SAVE`,
  restores `everysec`, syncs the filesystem, and only then writes/syncs the done
  flag and removes the envelope. API, SSH and persistence failures keep retry
  state and leave the services enabled. Sign-ins respect XO 5.113.2's per-user
  authentication throttle, including the final verification. Transient API and
  connection failures get up to three fresh sessions with bounded backoff; the
  helper has a 120-second overall deadline. Restart `xoa-credentials.service` to
  retry after repairing the failure. Subsequent XO changes have approximately
  a one-second crash-loss window under Redis's every-second fsync policy;
  a normal shutdown remains preferable.

Before accepting a rebuilt image, record its tag and RPM release and verify on
an isolated appliance: both enabled/disabled SSH deployments, boolean-looking
passwords, absence of credential keys in live XenStore and XAPI, no secrets in
logs, exactly the intended administrator, and rejection of the old default
password. Force-stop immediately after provisioning, boot and verify the same
account; repeat after changing its password and allowing the AOF fsync interval.
Test API/SAVE failure and reboot retry. Use halted snapshots for lab baselines.
The automated tests exercise injected failure paths, API state transitions and
real Redis AOF replay after SIGKILL; they do not replace deployed acceptance.

Configuration import can retain destination-only users: after recovery sign in
as the restored administrator, compare the full user list with the export,
remove unexpected accounts or assign unique new passwords to intentionally
retained accounts, and verify that old credentials fail. Persist the corrected
state before reconnecting production resources.

### Diagnosing first-boot failures

New images require a complete administrator email/password from XO Lite. A
manual XVA import without provisioning data deliberately fails closed; it is
not silently marked complete with the default account. Missing, incomplete or
malformed credentials stop phase 1 before networking and before guest key
cleanup. Use XO Lite deployment with valid credentials for these images.

If XO Lite reports "XOA not responding" and no IP appears, inspect
`systemctl status xoa-first-boot.service` and `/var/log/xoa-first-boot.log`
from the VM console (using the build-configured console credentials). Repair the
provisioning data on the host before rebooting; do not bypass the NetworkManager
dependency or remove credential keys before successful capture. After phase 1
succeeds, a phase-2 failure is diagnosed with
`systemctl status xoa-credentials.service`. Keep the root-only retry envelope
and restart that service after correcting the cause. Never paste its contents
into logs or reports.

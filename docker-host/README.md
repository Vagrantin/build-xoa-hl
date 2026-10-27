# Dedicated Docker workload template (protocol v1, draft)

This is the guest half of [xcp-hl#7](https://github.com/Vagrantin/xcp-hl/issues/7),
paired with [xoa-hl#1](https://github.com/Vagrantin/xoa-hl/pull/1).
It is separate from the normal XOA-HL appliance builder.

`docker-host.yml` runs unit/contract tests and a real Docker lifecycle in a
privileged disposable Docker-in-Docker container on GitHub's hosted runner.
PRs never run a guest build against infrastructure secrets.

For an XVA, use the **Dedicated Docker host template** workflow dispatch with
`build_image=true`. This requires a disposable self-hosted runner labelled
`xcp-hl-docker-builder`, with Docker and network access to a QA XCP-ng pool, its
DHCP guest network and the Packer HTTP port range. Configure:

| Setting | Kind | Purpose |
|---|---|---|
| `DOCKER_BUILD_XCPNG_IP` | secret | QA pool master address |
| `DOCKER_BUILD_XCPNG_USER` | secret | Pool account |
| `DOCKER_BUILD_XCPNG_PASSWORD` | secret | Pool credential |
| `DOCKER_BUILD_NETWORK` | variable | DHCP network name |
| `DOCKER_BUILD_SR` | variable | Writable SR name |
| `DOCKER_BUILD_ISO_URL` | variable | Pinned AlmaLinux 9 x86_64 minimal ISO |
| `DOCKER_BUILD_ISO_CHECKSUM` | variable | `sha256:` followed by its 64-digit hash |

CI generates a masked temporary root password, deletes the generated Packer and
Kickstart files even on failure, builds Packer in Docker, and uploads the XVA as
a seven-day artifact. Packer 1.11.2 and the official Vates XenServer plugin
0.11.4 are pinned in `Packer.Containerfile`. There is no release publishing step
and no workstation build workflow. New workflows may need to exist on the
repository's default branch before GitHub allows a manual dispatch; keep this
PR draft until its source and CI changes have been reviewed.

The guest is AlmaLinux 9 on ext4, 2 GiB RAM, a 32 GiB disk, stable Docker CE,
cloud-init and EPEL's Xen guest utilities. The installer refuses XOA and Dom0,
keeps the vendor Docker systemd units and default supported storage driver, and
configures rotated local logs. It does not install Node.js, XO, Redis, Compose,
or an externally reachable Docker API. No nightly repository is enabled. The
Docker package version is selected from the vendor's stable repository at build
time; record the installed version with each QA result. This is not a claim of
bit-for-bit reproducible builds.

Import the XVA with XO; convert to a template if necessary, and add the exact tag
`xcp-hl-docker-template-v1`. Do not boot the clean template before using it.
The XOA-HL Containers page can then deploy copies in the same pool to a chosen
SR/network, injecting unique restricted SSH access through cloud-init. Guest
application ports are explicit Docker published ports. The surrounding network
must enforce who may reach them; ordinary firewalld INPUT rules alone do not
restrict Docker-published traffic reliably.

The helper is `/usr/local/libexec/xoa-hl-docker-command`. It accepts JSON on stdin
with `version=1` and an allowlisted operation; it never executes caller-provided
shell commands. Only labelled XOA-HL containers are changed. Creation requires
hard CPU/RAM limits and permits named volumes, environment variables and explicit
ports; port 22 is reserved. Removal never forces running-container deletion or
removes named volumes. Standard Docker image removal refuses images in use.
The helper also reports whole-guest resource usage and bounded log snapshots.

The installed guest is password-locked. XOA-HL supplies a per-guest SSH host key
and a restricted management key when it deploys the template. For recovery,
retain XO backups of both XOA-HL's private management state and the Docker guest.
Guest OS/Docker patching is a separate maintenance action. This PR supplies
source and CI paths; a successful XVA build, first-boot deployment and the full
[appliance acceptance checklist](https://github.com/Vagrantin/xoa-hl/blob/vibe/container-support-27a085/docs/containers.md#validation-before-release)
are required before declaring the feature shipped.

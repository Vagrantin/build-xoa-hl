#!/usr/bin/env bash
# What "checked" means for this repo (xcp-hl#148). Jenkins dev/build-xoa-hl runs it on every PR; run it locally too.
# Contract: exit 0 when clean; results under $CI_RESULTS; on failure $CI_RESULTS/current-step names the failed check.
# The image is built by build/xoa-vm-agent and tested deployed by Test's xoa-deploy-test (xcp-hl#151).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${CI_RESULTS:-ci-results}"
mkdir -p "$OUT"
step() { echo "==> $1"; echo "$1" > "$OUT/current-step"; }

step "bash -n"
git ls-files -z '*.sh' | xargs -0 -n1 bash -n

step "shellcheck (warnings and errors)"
git ls-files -z '*.sh' | xargs -0 shellcheck -S warning

step "systemd units parse"
for u in systemd/*.service; do
  grep -q '^\[Service\]' "$u" || { echo "$u has no [Service] section" >&2; exit 1; }
done

rm -f "$OUT/current-step"
echo "all checks passed"

#!/usr/bin/env bash

# Runs INSIDE the disposable archlinux:latest container started by
# validate-release-archive.sh. Never run this on the host.
#
# Expects, mounted read-only by the caller:
#   /package        the ravn-trio package sources (PKGBUILD)
#
# Deliberately does not create a sudoers entry or install any packages:
# `makepkg --verifysource` only downloads and hashes sources, so the builder
# user needs no elevated privileges. Compare container-validate.sh, which
# does grant NOPASSWD sudo because it runs `makepkg -si`.

set -Eeuo pipefail

phase_create_builder_user() {
  printf '\n==> [container 1/3] Creating the unprivileged makepkg user\n'
  useradd --create-home builder
}

phase_prepare_workspace() {
  printf '==> [container 2/3] Preparing the writable verification workspace\n'
  install -d -m 0755 -o builder -g builder /work/package
  cp -a /package/PKGBUILD /work/package/
  chown builder:builder /work/package/PKGBUILD
}

phase_verify_sources() {
  printf '==> [container 3/3] Downloading and verifying all source entries\n'
  su --shell /bin/bash builder --command \
    'cd /work/package && makepkg --verifysource'
}

main() {
  phase_create_builder_user
  phase_prepare_workspace
  phase_verify_sources
}

main "$@"

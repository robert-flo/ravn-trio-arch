#!/usr/bin/env bash

# Verify every PKGBUILD source entry against its fixed checksum.
#
# This validator does not build or install ravn-trio. It copies PKGBUILD
# into a disposable Arch Linux container and runs only
# `makepkg --verifysource` as an unprivileged user. The stock archlinux:latest
# image already contains makepkg, curl, and SHA-256 tooling, so no container
# packages need to be installed.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly PACKAGE_DIR
readonly CONTAINER_SCRIPT="$SCRIPT_DIR/lib/container-verify-source.sh"

# shellcheck disable=SC1091 # The library path is derived from this script's location.
source "$SCRIPT_DIR/lib/host-checks.sh"

# Populated by resolve_package_version / resolve_archive_checksum.
package_version=""
archive_checksum=""

usage() {
  cat <<'USAGE'
Usage:
  tests/validate-release-archive.sh

Purpose:
  Check that PKGBUILD records a fixed SHA-256 checksum for the release archive,
  then ask makepkg to download and verify every source entry. The current source
  entries are the tagged GitHub release archive.

Container phases (see lib/container-verify-source.sh):
  1. Create an unprivileged builder account required by makepkg.
  2. Copy PKGBUILD from the read-only mount to a writable area.
  3. Run `makepkg --verifysource` to download sources and compare their hashes.

Packages installed inside the container:
  None. archlinux:latest already provides makepkg, curl, and sha256sum.

What this script does not do:
  - It does not build or install the ravn-trio package.
  - It does not execute ravn-trio or its public commands.
  - It does not read RAVN_TRIO_SOURCE_DIR or local source-checkout code.
  Use validate-local-install.sh for the installation and public-command checks.

Host impact:
  - No host or container packages are installed or upgraded.
  - No host HOME, Git configuration, SSH keys, or GPG keys are mounted.
  - The package repository is mounted read-only.
  - Docker may pull/cache archlinux:latest and use bandwidth and disk space.
  - `docker run --rm` deletes the container and downloaded archive on exit.

Network behavior:
  makepkg downloads the tagged GitHub archive declared by PKGBUILD. Failure to
  reach GitHub, a missing tag, or any checksum mismatch fails the validation.

Exit status:
  0  The release archive matched their fixed checksums.
  2  Usage, Docker access, or PKGBUILD metadata error.
  *  Docker, download, or checksum verification failed.
USAGE
}

check_host_deps() {
  require_docker
  [[ -f "$CONTAINER_SCRIPT" ]] || die "missing companion script: $CONTAINER_SCRIPT"
}

resolve_package_version() {
  package_version="$(awk -F '=' '$1 == "pkgver" { print $2; exit }' "$PACKAGE_DIR/PKGBUILD")"
  [[ -n $package_version ]] || die 'PKGBUILD does not define pkgver.'
}

resolve_archive_checksum() {
  # The first checksum maps to the first source entry: the GitHub release archive.
  archive_checksum="$(
    awk -F "'" '
      /^sha256sums=/ { in_checksums = 1 }
      in_checksums && /[^[:space:]]/ {
        for (field = 2; field <= NF; field += 2) {
          print $field
          exit
        }
      }
    ' "$PACKAGE_DIR/PKGBUILD"
  )"

  # Requiring exactly 64 hexadecimal characters explicitly rejects SKIP.
  if [[ ! $archive_checksum =~ ^[[:xdigit:]]{64}$ ]]; then
    die "the v${package_version} release archive must use a fixed SHA-256 checksum."
  fi
}

print_plan() {
  cat <<PLAN
Published release archive validation
------------------------------------
Package version:  $package_version
Archive checksum: $archive_checksum
Package files:    $PACKAGE_DIR
Container:        archlinux:latest (ephemeral)

No packages will be installed on the host or inside the container.
makepkg will only download the declared sources and verify their checksums.
PLAN
}

run_container_validation() {
  printf '\n==> Starting the disposable Arch Linux container\n'
  docker run --rm \
    --volume "$PACKAGE_DIR:/package:ro" \
    --volume "$CONTAINER_SCRIPT:/container-verify-source.sh:ro" \
    archlinux:latest \
    bash /container-verify-source.sh
}

main() {
  parse_help_arg "$@"
  check_host_deps
  resolve_package_version
  resolve_archive_checksum
  print_plan
  run_container_validation
  printf '\nPASS: published release archive checksum validation\n\n'
}

main "$@"

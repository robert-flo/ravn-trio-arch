#!/usr/bin/env bash

# Runs INSIDE the disposable archlinux:latest container started by
# validate-local-install.sh. Never run this on the host.
#
# Expects, mounted read-only by the caller:
#   /package               the ravn-trio package sources (PKGBUILD, etc.)
#   /archive/ravn-trio-${PKG_VERSION}.tar.gz   the local source snapshot
#
# Expects, from the environment:
#   PKG_VERSION             package version, matches the archive filename

set -Eeuo pipefail

readonly TEST_HOME=/tmp/ravn-trio-package-test

phase_install_prereqs() {
  printf '\n==> [container 1/5] Refreshing Arch and installing exact prerequisites\n'
  printf '    These packages exist only inside this disposable container.\n\n'
  pacman -Syu --noconfirm --needed fakeroot sudo make bash jq git github-cli libnotify
}

phase_create_builder_user() {
  printf '\n==> [container 2/5] Creating the unprivileged makepkg user\n'
  useradd --create-home builder
  printf 'builder ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
  chmod 0440 /etc/sudoers.d/builder
}

phase_prepare_workspace() {
  printf '==> [container 3/5] Preparing the writable package workspace\n'
  install -d -m 0755 /work/package
  cp -a /package/. /work/package/

  # The checkout may contain ignored makepkg artifacts.  They must not let this
  # validation install an older package instead of building the current
  # PKGBUILD.
  find /work/package -maxdepth 1 -type f -name '*.pkg.tar.*' -delete

  # A local git archive has different bytes from the published GitHub archive.
  # Redirect PKGBUILD to it here; validate-release-archive.sh independently
  # checks the published checksums.
  sed -i \
    "s|\${url}/archive/refs/tags/v\${pkgver}.tar.gz|file:///archive/ravn-trio-${PKG_VERSION}.tar.gz|" \
    /work/package/PKGBUILD

  chown -R builder:builder /work/package
}

phase_build_and_install() {
  printf '==> [container 4/5] Building and installing the local package\n'
  su --shell /bin/bash builder --command \
      'cd /work/package && makepkg -Cf --nodeps --noconfirm --skipchecksums'
  # herdr viene de omarchy-personal-repo, no de los repos de Arch:
  # el contenedor instala sin chequear dependencias (el payload no las usa).
  pacman -U --noconfirm --nodeps --nodeps /work/package/*.pkg.tar.*
}

phase_verify_payload() {
  local share=/usr/share/ravn/trio
  test -L /usr/bin/pj-trio
  test "$(readlink /usr/bin/pj-trio)" = "$share/pj-trio"
  test -x "$share/pj-trio"
  test -x "$share/trio-status"
  test -x "$share/runtime/scripts/start"
  test -x "$share/runtime/plugin/new-trio"
  test -f "$share/trio-pm-prompt.md"
  test -f "$share/trio.conf.example"
  grep -Fxq 'id = "ravn.trio"' "$share/herdr-plugin.toml"
  test -f /usr/share/licenses/ravn-trio/LICENSE
  test -e /usr/share/bash-completion/completions/pj-trio
  pacman -Qkk ravn-trio > /dev/null
}

phase_verify_help_command() {
  NO_COLOR=1 HOME="$TEST_HOME" TERM=dumb /usr/bin/pj-trio help > /tmp/pj-trio-help-output
  grep -Fq 'COMMANDS' /tmp/pj-trio-help-output
  grep -Fq 'start' /tmp/pj-trio-help-output
}

phase_verify_dry_run() {
  # Un proyecto y un miembro con remotos; herdr falso. --dry-run no toca nada.
  local root="$TEST_HOME/tries" herdr="$TEST_HOME/bin/herdr"
  mkdir -p "$TEST_HOME/bin"
  git init -q "$root/pj-demo"
  git -C "$root/pj-demo" remote add origin https://github.com/robert-flo/pj-demo.git
  git init -q "$root/pj-demo/rf-miembro"
  git -C "$root/pj-demo/rf-miembro" remote add origin https://github.com/robert-flo/miembro.git
  printf '#!/bin/sh\necho "{}"\n' > "$herdr"
  chmod +x "$herdr"
  (cd "$root" && NO_COLOR=1 HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" PJ_TRIO_ROOTS="$root" \
    /usr/bin/pj-trio start --dry-run pj-demo 7 --repo miembro) > /tmp/pj-trio-dry-run 2>&1
  grep -Fq 'trio pj-demo/miembro#7' /tmp/pj-trio-dry-run
}

phase_exercise_public_commands() {
  printf '\n==> [container 5/5] Confirming the installed public commands behave as expected\n'
  phase_verify_payload
  phase_verify_help_command
  phase_verify_dry_run
  printf '==> [container 5/5] PASS: payload, help, and pj-trio start --dry-run behaved as expected\n'
}

main() {
  phase_install_prereqs
  phase_create_builder_user
  phase_prepare_workspace
  phase_build_and_install
  phase_exercise_public_commands
}

main "$@"

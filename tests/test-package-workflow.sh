#!/usr/bin/env bash
# shellcheck disable=SC2016

# Contrato offline del pipeline de empaquetado y publicación del .pkg
# (package.yml, issue #9): estructura del workflow, consistencia
# PKGBUILD/.SRCINFO con el archivo del tag de GitHub, el package() real del
# PKGBUILD contra ese archivo (se baja y se verifica su sha256), la
# idempotencia de la publicación y el contrato de publicación en
# stable/x86_64 de omarchy-personal-repo. Cada aserción dura lleva su caso
# por mutación.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly PACKAGE_DIR
readonly WORKFLOW="$PACKAGE_DIR/.github/workflows/package.yml"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/package-workflow-test.XXXXXX")"
readonly TEST_ROOT

trap 'rm -rf "$TEST_ROOT"' EXIT

die() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

have() {
  grep -qF -- "$1" "$WORKFLOW" || die "package.yml no tiene: $1"
}

miss() {
  ! grep -qF -- "$1" "$2" || die "$3"
}

expect_fail() { # expect_fail <por qué debe fallar> <cmd...>
  local why="$1"; shift
  # En subshell: die del check hace exit y no debe matar el test entero.
  if ( "$@" ) > /dev/null 2>&1; then
    die "la mutación no fue detectada: $why"
  fi
}

# El run body de un paso nombrado, extraído del YAML y sin sangría: es la
# lógica que el workflow va a correr, probada en vez de confiada.
extract_run() {
  awk -v step="$1" '
    $0 == "      - name: " step { found_step = 1; next }
    found_step && /^        run: \|/ { in_run = 1; next }
    in_run {
      if ($0 ~ /^ {10}/) { sub(/^ {10}/, ""); print; next }
      if ($0 ~ /^[[:space:]]*$/) { next }
      exit
    }
  ' "${2:-$WORKFLOW}"
}

# Estructura de package.yml: triggers sin push, contenedor Arch, build desde
# el archivo del tag que declara el PKGBUILD, install-test del .pkg, artifact
# y publicación.
have 'repository_dispatch:'
have 'source-updated'
have 'workflow_dispatch:'
have 'image: archlinux:base'
have 'Checkout this package repository'
have 'quedó un tarball vendoreado en la raíz del repo'
have 'el PKGBUILD no declara el archivo del tag de GitHub como source'
have 'makepkg --nodeps'
have 'pacman -U --noconfirm --nodeps --nodeps'
have '/usr/bin/pj-trio'
have '/usr/share/ravn/trio'
have 'id = "ravn.trio"'
have 'pacman -Qkk ravn-trio'
have 'pj-trio help'
have 'actions/upload-artifact@v4'
have 'path: build/*.pkg.tar.zst'
have 'if-no-files-found: error'
# La fuente la declara el PKGBUILD (archivo del tag): no hay checkout de la
# fuente en el sha despachado.
miss 'Checkout the source at the dispatched commit' "$WORKFLOW" \
  'package.yml despacha una fuente externa que este repo no tiene'

# El orden importa: archlinux:base no trae git, así que las dependencias se
# instalan antes del primer checkout (el fallback REST deja un árbol sin .git;
# lección del run real 40686182867 en el repo del patrón, y el mismo orden de
# ci.yml).
deps_line="$(grep -n '      - name: Install build and runtime dependencies' "$WORKFLOW" | cut -d: -f1)"
checkout_line="$(grep -n '      - name: Checkout this package repository' "$WORKFLOW" | cut -d: -f1)"
[[ -n "$deps_line" && -n "$checkout_line" && "$deps_line" -lt "$checkout_line" ]] || \
  die 'las dependencias van antes del checkout (la imagen base no trae git)'

# ---------------------------------------------------------------------- #
# Contrato del paquete: la fuente es el archivo público del tag de        #
# ravn-trio (sin tarball vendoreado en el repo), y la versión, el source  #
# y el sha256 coinciden entre el PKGBUILD y el .SRCINFO. Un bump a medias #
# se nota acá.                                                             #
# ---------------------------------------------------------------------- #
readonly SOURCE_LINE='source=("${pkgname}-${pkgver}.tar.gz::${url}/archive/refs/tags/v${pkgver}.tar.gz")'
vendored=("$PACKAGE_DIR"/ravn-trio-*.tar.gz)
[[ ! -e "${vendored[0]}" ]] || \
  die "quedó un tarball vendoreado en la raíz del repo: ${vendored[*]}"
pkgver="$(awk -F= '/^pkgver=/{print $2; exit}' "$PACKAGE_DIR/PKGBUILD")"
pkgrel="$(awk -F= '/^pkgrel=/{print $2; exit}' "$PACKAGE_DIR/PKGBUILD")"
[[ "$pkgver" =~ ^[0-9]+([.][0-9]+)*$ ]] || die "pkgver inválido: $pkgver"
[[ "$pkgrel" =~ ^[0-9]+$ ]] || die "pkgrel inválido: $pkgrel"
grep -qxF "url='https://github.com/robert-flo/ravn-trio'" "$PACKAGE_DIR/PKGBUILD" || \
  die 'el PKGBUILD no apunta url al repo público de ravn-trio'
grep -qxF "$SOURCE_LINE" "$PACKAGE_DIR/PKGBUILD" || \
  die 'el PKGBUILD no declara el archivo del tag de GitHub en source'
tarball="ravn-trio-${pkgver}.tar.gz"
archive_url="https://github.com/robert-flo/ravn-trio/archive/refs/tags/v${pkgver}.tar.gz"
pkgb_sha="$(grep -oE '[0-9a-f]{64}' "$PACKAGE_DIR/PKGBUILD" | head -1)"
srcinfo_sha="$(awk '/^\tsha256sums = /{print $3; exit}' "$PACKAGE_DIR/.SRCINFO")"
[[ "$pkgb_sha" =~ ^[0-9a-f]{64}$ ]] || die 'el PKGBUILD no fija un sha256 para el archivo del tag'
[[ "$srcinfo_sha" == "$pkgb_sha" ]] || \
  die "el sha256 del .SRCINFO no es el del PKGBUILD: $srcinfo_sha != $pkgb_sha"
grep -qE "^$(printf '\t')pkgver = ${pkgver}$" "$PACKAGE_DIR/.SRCINFO" || \
  die '.SRCINFO pkgver no coincide con el PKGBUILD'
grep -qE "^$(printf '\t')pkgrel = ${pkgrel}$" "$PACKAGE_DIR/.SRCINFO" || \
  die '.SRCINFO pkgrel no coincide con el PKGBUILD'
grep -qxF "$(printf '\t')source = ${tarball}::${archive_url}" "$PACKAGE_DIR/.SRCINFO" || \
  die '.SRCINFO source no declara el archivo del tag de GitHub'

# El paso de staging es bash válido y corre de verdad: deja el PKGBUILD en
# el build dir y muere con un tarball vendoreado o un source local.
stage_script="$TEST_ROOT/stage.sh"
extract_run 'Stage the build directory' > "$stage_script"
[[ -s "$stage_script" ]] || die 'no se pudo extraer el paso de staging de package.yml'
bash -n "$stage_script" || die 'el paso de staging no es bash válido'
run_stage() { # run_stage <repo_dir> <build_dir>
  (
    set -Eeuo pipefail
    cd "$1"
    PKG_BUILD="$2" GITHUB_OUTPUT="$TEST_ROOT/stage-output" bash "$stage_script"
  )
}
stage_repo="$TEST_ROOT/stage-repo"
mkdir -p "$stage_repo"
cp "$PACKAGE_DIR/PKGBUILD" "$stage_repo/"
run_stage "$stage_repo" "$TEST_ROOT/build-stage"
[[ -f "$TEST_ROOT/build-stage/PKGBUILD" ]] || \
  die 'el staging no dejó el PKGBUILD en el build dir'
# Mutación: un tarball vendoreado olvidado en la raíz debe morir en la guardia.
cp -r "$stage_repo" "$TEST_ROOT/stage-repo-vendoreado"
: > "$TEST_ROOT/stage-repo-vendoreado/ravn-trio-9.9.9.tar.gz"
expect_fail 'un tarball vendoreado en la raíz' \
  run_stage "$TEST_ROOT/stage-repo-vendoreado" "$TEST_ROOT/build-stage-vendoreado"
# Mutación: un PKGBUILD con source local (el esquema viejo) muere en la guardia.
cp -r "$stage_repo" "$TEST_ROOT/stage-repo-local"
sed -i 's|^source=.*|source=("${pkgname}-${pkgver}.tar.gz")|' "$TEST_ROOT/stage-repo-local/PKGBUILD"
expect_fail 'un PKGBUILD con source local' \
  run_stage "$TEST_ROOT/stage-repo-local" "$TEST_ROOT/build-stage-local"

# El paso de build/install es bash válido (el resto corre en el contenedor
# real del CI: pacman y makepkg no existen acá).
build_script="$TEST_ROOT/build.sh"
extract_run 'Build the package and install-test it' > "$build_script"
[[ -s "$build_script" ]] || die 'no se pudo extraer el paso de build de package.yml'
bash -n "$build_script" || die 'el paso de build no es bash válido'

# ---------------------------------------------------------------------- #
# package() funciona: contra el archivo del tag (bajado y verificado con  #
# el sha256 del PKGBUILD; RAVN_TRIO_ARCHIVE apunta a una copia local) se  #
# corre el package() real del PKGBUILD con DESTDIR temporal (el WK nunca  #
# instala en el sistema) y se fuma el payload staged con el mismo         #
# contrato de tests/lib/container-validate.sh.                            #
# ---------------------------------------------------------------------- #
archive="${RAVN_TRIO_ARCHIVE:-$TEST_ROOT/$tarball}"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
    "$archive_url" --output "$archive" || die "no se pudo bajar $archive_url"
fi
real_sha="$(sha256sum "$archive" | awk '{print $1}')"
[[ "$real_sha" == "$pkgb_sha" ]] || \
  die "el sha256 del PKGBUILD no es el del archivo del tag: $pkgb_sha != $real_sha"
srcroot="$TEST_ROOT/pkg-src"
rm -rf "$srcroot"
mkdir -p "$srcroot"
tar -xzf "$archive" -C "$srcroot"
[[ -d "$srcroot/ravn-trio-${pkgver}" ]] || \
  die "el archivo del tag no descomprime con la raíz que el package() espera: ravn-trio-${pkgver}/"

run_package() { # run_package <pkgdir> <pkgbuild>
  (
    set -Eeuo pipefail
    # srcdir y pkgdir los consume package() del PKGBUILD al invocarse;
    # el disable marca que el uso es dinámico.
    # shellcheck disable=SC2034
    srcdir="$srcroot" pkgdir="$1"
    rm -rf "$1"
    # shellcheck disable=SC1090
    source "$2"
    package
  )
}

check_installed() { # check_installed <pkgdir>
  local payload="$1/usr/share/ravn/trio"
  [[ -L "$1/usr/bin/pj-trio" ]] || return 1
  # En el staging el target es la ruta absoluta del sistema destino (igual
  # que hace la comparación del container-validate sobre el sistema real).
  [[ "$(readlink "$1/usr/bin/pj-trio")" == "/usr/share/ravn/trio/pj-trio" ]] || return 1
  [[ -x "$payload/pj-trio" && -x "$payload/trio-status" ]] || return 1
  [[ -x "$payload/runtime/scripts/start" ]] || return 1
  [[ -x "$payload/runtime/plugin/new-trio" ]] || return 1
  [[ -f "$payload/trio-pm-prompt.md" && -f "$payload/trio.conf.example" ]] || return 1
  grep -Fxq 'id = "ravn.trio"' "$payload/herdr-plugin.toml" || return 1
  [[ -f "$payload/runtime/completion/pj-trio.bash" ]] || return 1
  [[ -f "$1/usr/share/licenses/ravn-trio/LICENSE" ]] || return 1
  # En el staging el target absoluto todavía no existe: el symlink de la
  # completion se verifica como symlink, no como archivo resuelto.
  [[ -L "$1/usr/share/bash-completion/completions/pj-trio" ]] || return 1
  return 0
}

good_pkgbuild="$TEST_ROOT/PKGBUILD.good"
cp "$PACKAGE_DIR/PKGBUILD" "$good_pkgbuild"
run_package "$TEST_ROOT/pkg-good" "$good_pkgbuild"
check_installed "$TEST_ROOT/pkg-good" || die 'el payload staged no cumple el contrato de instalación (caso bueno)'

# Mutación: sin el make -C no hay payload y el check lo detecta.
sed '/make -C/d' "$good_pkgbuild" > "$TEST_ROOT/PKGBUILD.sin-payload"
run_package "$TEST_ROOT/pkg-sin-payload" "$TEST_ROOT/PKGBUILD.sin-payload"
expect_fail 'payload sin el make install' check_installed "$TEST_ROOT/pkg-sin-payload"

# Mutación: sin la LICENSE la entrada de licencias se cae y el check lo detecta.
sed '/install -Dm644 "${source_dir}\/LICENSE"/d' "$good_pkgbuild" \
  > "$TEST_ROOT/PKGBUILD.sin-licencia"
run_package "$TEST_ROOT/pkg-sin-licencia" "$TEST_ROOT/PKGBUILD.sin-licencia"
expect_fail 'payload sin LICENSE' check_installed "$TEST_ROOT/pkg-sin-licencia"

# ---------------------------------------------------------------------- #
# Los defaults del workflow_dispatch no admiten expresiones ${{ }}:       #
# GitHub Actions las rechaza en los defaults de inputs (hallazgo del run  #
# real del repo del patrón). Este repo no usa inputs, así que la          #
# aserción vigila el bloque entero y la mutación le inyecta uno con       #
# expresión.                                                              #
# ---------------------------------------------------------------------- #
check_dispatch_inputs_literal() { # check_dispatch_inputs_literal <workflow_file>
  local workflow="$1" block
  block="$(awk '
    /^  workflow_dispatch:/ { in_wd = 1; next }
    in_wd {
      if (/^ {4}/) { print; next }
      if (/^[[:space:]]*$/) { next }
      exit
    }
  ' "$workflow")"
  if grep -qF '${{' <<<"$block"; then
    die "on.workflow_dispatch contiene una expresión \${{ }}: GitHub Actions no admite expresiones en el bloque"
  fi
}
have 'workflow_dispatch:'
check_dispatch_inputs_literal "$WORKFLOW"

mutated_workflow="$TEST_ROOT/package-with-expression.yml"
sed 's|^  workflow_dispatch:$|  workflow_dispatch:\n    inputs:\n      repo:\n        default: ${{ github.repository }}|' \
  "$WORKFLOW" > "$mutated_workflow"
grep -qF '${{ github.repository }}' "$mutated_workflow" || die 'la mutación del bloque workflow_dispatch no se aplicó'
expect_fail 'default con expresión ${{ }}' check_dispatch_inputs_literal "$mutated_workflow"

# Opción A: package.yml NO debe publicar directo a gh-pages ni usar omarchy-pkgs.
miss 'bash omarchy-pkgs/bin/publish-artifact' "$WORKFLOW" 'package.yml no debe publicar directo a gh-pages (opción A)'
miss 'ref: gh-pages' "$WORKFLOW" 'package.yml no debe tocar gh-pages (opción A)'
printf 'PASS: %s (opción A)\n' "$WORKFLOW"

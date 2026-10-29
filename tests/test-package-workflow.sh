#!/usr/bin/env bash
# shellcheck disable=SC2016

# Contrato offline del pipeline de empaquetado y publicación del .pkg
# (package.yml, issue #9): estructura del workflow, consistencia
# PKGBUILD/.SRCINFO/tarball vendoreado, el package() real del PKGBUILD contra
# el tarball commiteado, y el contrato de publicación en stable/x86_64 de
# omarchy-personal-repo. Cada aserción dura lleva su caso por mutación.

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
# el tarball vendoreado, install-test del .pkg, artifact y publicación.
have 'repository_dispatch:'
have 'source-updated'
have 'workflow_dispatch:'
have 'image: archlinux:base'
have 'Checkout this package repository'
have 'no quedó exactamente un tarball vendoreado'
have 'no coincide con pkgver del PKGBUILD'
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
# Este repo no despacha una fuente: el tarball vendoreado ES la fuente.
miss 'Checkout the source at the dispatched commit' "$WORKFLOW" \
  'package.yml despacha una fuente externa que este repo no tiene'
miss 'ready-for-agent' "$WORKFLOW" \
  'el issue de fallo usa un label que no existe en este repo (solo labels estándar)'

# El orden importa: archlinux:base no trae git, así que las dependencias se
# instalan antes del primer checkout (el fallback REST deja un árbol sin .git;
# lección del run real 40686182867 en el repo del patrón, y el mismo orden de
# ci.yml).
deps_line="$(grep -n '      - name: Install build and runtime dependencies' "$WORKFLOW" | cut -d: -f1)"
checkout_line="$(grep -n '      - name: Checkout this package repository' "$WORKFLOW" | cut -d: -f1)"
[[ -n "$deps_line" && -n "$checkout_line" && "$deps_line" -lt "$checkout_line" ]] || \
  die 'las dependencias van antes del checkout (la imagen base no trae git)'

# ---------------------------------------------------------------------- #
# Contrato del paquete: exactamente un tarball vendoreado, y la versión,  #
# el nombre de source y el sha256 coinciden entre el archivo real, el     #
# PKGBUILD y el .SRCINFO. Un release bumped a medias se nota acá.         #
# ---------------------------------------------------------------------- #
tarballs=("$PACKAGE_DIR"/ravn-trio-*.tar.gz)
if (( ${#tarballs[@]} != 1 )) || [[ ! -e "${tarballs[0]}" ]]; then
  die 'no hay exactamente un tarball vendoreado en la raíz del repo'
fi
tarball="$(basename "${tarballs[0]}")"
pkgver="$(awk -F= '/^pkgver=/{print $2; exit}' "$PACKAGE_DIR/PKGBUILD")"
pkgrel="$(awk -F= '/^pkgrel=/{print $2; exit}' "$PACKAGE_DIR/PKGBUILD")"
[[ "$tarball" == "ravn-trio-${pkgver}.tar.gz" ]] || \
  die "el tarball vendoreado ($tarball) no coincide con pkgver del PKGBUILD ($pkgver)"
[[ "$pkgver" =~ ^[0-9]+([.][0-9]+)*$ ]] || die "pkgver inválido: $pkgver"
[[ "$pkgrel" =~ ^[0-9]+$ ]] || die "pkgrel inválido: $pkgrel"
grep -qF 'source=("${pkgname}-${pkgver}.tar.gz")' "$PACKAGE_DIR/PKGBUILD" || \
  die 'el PKGBUILD no declara el tarball vendoreado parametrizado en source'
real_sha="$(sha256sum "${tarballs[0]}" | awk '{print $1}')"
pkgb_sha="$(grep -oE '[0-9a-f]{64}' "$PACKAGE_DIR/PKGBUILD" | head -1)"
srcinfo_sha="$(awk '/^\tsha256sums = /{print $3; exit}' "$PACKAGE_DIR/.SRCINFO")"
[[ "$pkgb_sha" == "$real_sha" ]] || \
  die "el sha256 del PKGBUILD no es el del tarball commiteado: $pkgb_sha != $real_sha"
[[ "$srcinfo_sha" == "$real_sha" ]] || \
  die "el sha256 del .SRCINFO no es el del tarball commiteado: $srcinfo_sha != $real_sha"
grep -qE "^$(printf '\t')pkgver = ${pkgver}$" "$PACKAGE_DIR/.SRCINFO" || \
  die '.SRCINFO pkgver no coincide con el PKGBUILD'
grep -qE "^$(printf '\t')pkgrel = ${pkgrel}$" "$PACKAGE_DIR/.SRCINFO" || \
  die '.SRCINFO pkgrel no coincide con el PKGBUILD'
grep -qE "^$(printf '\t')source = ${tarball}$" "$PACKAGE_DIR/.SRCINFO" || \
  die '.SRCINFO source no declara el tarball vendoreado'

# El paso de staging es bash válido y corre de verdad: deja PKGBUILD y el
# tarball en el build dir, con su guardia de tarball único.
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
cp "$PACKAGE_DIR/PKGBUILD" "$PACKAGE_DIR/$tarball" "$stage_repo/"
run_stage "$stage_repo" "$TEST_ROOT/build-stage"
[[ -f "$TEST_ROOT/build-stage/PKGBUILD" && -f "$TEST_ROOT/build-stage/$tarball" ]] || \
  die 'el staging no dejó PKGBUILD y tarball en el build dir'
# Mutación: un tarball viejo olvidado en la raíz debe morir en la guardia.
cp -r "$stage_repo" "$TEST_ROOT/stage-repo-doble"
: > "$TEST_ROOT/stage-repo-doble/ravn-trio-9.9.9.tar.gz"
expect_fail 'dos tarballs vendoreados en la raíz' \
  run_stage "$TEST_ROOT/stage-repo-doble" "$TEST_ROOT/build-stage-doble"

# El paso de build/install es bash válido (el resto corre en el contenedor
# real del CI: pacman y makepkg no existen acá).
build_script="$TEST_ROOT/build.sh"
extract_run 'Build the package and install-test it' > "$build_script"
[[ -s "$build_script" ]] || die 'no se pudo extraer el paso de build de package.yml'
bash -n "$build_script" || die 'el paso de build no es bash válido'

# ---------------------------------------------------------------------- #
# package() funciona: contra el tarball vendoreado commiteado se corre el  #
# package() real del PKGBUILD con DESTDIR temporal (el WK nunca instala   #
# en el sistema) y se fuma el payload staged con el mismo contrato de     #
# tests/lib/container-validate.sh.                                        #
# ---------------------------------------------------------------------- #
srcroot="$TEST_ROOT/pkg-src"
rm -rf "$srcroot"
mkdir -p "$srcroot"
tar -xzf "$PACKAGE_DIR/$tarball" -C "$srcroot"
[[ -d "$srcroot/ravn-trio-${pkgver}" ]] || \
  die "el tarball no descomprime con la raíz que el package() espera: ravn-trio-${pkgver}/"

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

# ---------------------------------------------------------------------- #
# Reporte de fallo: los gh run view de los pasos de reporte llevan        #
# -R "$GITHUB_REPOSITORY". Sin -R gh intenta detectar el repo base con    #
# git dentro del contenedor y muere por dubious ownership (run real       #
# 40778999252 del repo del patrón).                                       #
# ---------------------------------------------------------------------- #
check_failure_report_repo_flag() { # check_failure_report_repo_flag <workflow_file>
  local workflow="$1" script step
  for step in 'Collect the failure log' 'Open the failure issue'; do
    script="$TEST_ROOT/failure-report.sh"
    extract_run "$step" "$workflow" > "$script"
    [[ -s "$script" ]] || die "no se pudo extraer el paso del workflow: $step"
    grep -qF 'gh run view -R "$GITHUB_REPOSITORY"' "$script" || \
      die "el paso '$step' corre gh run view sin -R \"\$GITHUB_REPOSITORY\": gh detecta el repo base con git y muere por dubious ownership en el contenedor (run 40778999252)"
  done
}
check_failure_report_repo_flag "$WORKFLOW"

mutated_workflow="$TEST_ROOT/package-without-r-flag.yml"
sed 's|gh run view -R "$GITHUB_REPOSITORY"|gh run view|' "$WORKFLOW" \
  > "$mutated_workflow"
expect_fail 'gh run view sin -R' check_failure_report_repo_flag "$mutated_workflow"

# ---------------------------------------------------------------------- #
# Publicación: el .pkg entra al canal stable de gh-pages con              #
# bin/publish-artifact (firma + repo-add) contra un remote rclone local,  #
# poda de los últimos N por pkgname con bin/unpublish-packages como      #
# mecanismo del db, e issue automático ante fallo. El gate de            #
# repository_dispatch vive en cada paso de publicación.                   #
# ---------------------------------------------------------------------- #
publish_checks() { # publish_checks <workflow-path>
  local wf="$1"
  grep -qF "repository: robert-flo/omarchy-pkgs" "$wf" || return 1
  grep -qF "ref: personal" "$wf" || return 1
  grep -qF "repository: robert-flo/omarchy-personal-repo" "$wf" || return 1
  grep -qF "ref: gh-pages" "$wf" || return 1
  grep -qF 'ssh-key: ${{ secrets.SSH_DEPLOY_KEY }}' "$wf" || return 1
  grep -qF 'bin/publish-artifact --remote' "$wf" || return 1
  grep -qF -- '--mirror stable --arch x86_64' "$wf" || return 1
  grep -qF 'bin/unpublish-packages' "$wf" || return 1
  grep -qF 'PRUNE_KEEP_N:-5' "$wf" || return 1
  grep -qF 'secrets.GPG_PRIVATE_KEY' "$wf" || return 1
  grep -qF 'secrets.GPG_PASSPHRASE' "$wf" || return 1
  grep -qF 'omarchy-personal.db' "$wf" || return 1
  grep -qF 'omarchy.db.sig' "$wf" || return 1
  grep -qF 'issues: write' "$wf" || return 1
  grep -qF 'actions: read' "$wf" || return 1
  grep -qF 'concurrency:' "$wf" || return 1
  local a b c d e f
  a="$(grep -n '      - name: Upload the package artifact' "$wf" | cut -d: -f1)"
  b="$(grep -n '      - name: Install the publish tooling' "$wf" | cut -d: -f1)"
  c="$(grep -n '      - name: Publish the package into the stable channel' "$wf" | cut -d: -f1)"
  d="$(grep -n '      - name: Prune the channel to the last N packages' "$wf" | cut -d: -f1)"
  e="$(grep -n '      - name: Sign the databases and push gh-pages' "$wf" | cut -d: -f1)"
  f="$(grep -n '      - name: Open the failure issue' "$wf" | cut -d: -f1)"
  [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" && -n "$e" && -n "$f" ]] || return 1
  (( a < b && b < c && c < d && d < e && e < f )) || return 1
  return 0
}
publish_checks "$WORKFLOW" || die 'package.yml no cumple el contrato de publicación en omarchy-personal-repo'

# El gate de repository_dispatch vive pegado a cada paso de publicación.
check_publish_gates() { # check_publish_gates <workflow-path>
  local wf="$1" step line
  for step in 'Install the publish tooling' \
              'Checkout the omarchy-pkgs publish tooling' \
              'Checkout the personal repo (gh-pages)' \
              'Publish the package into the stable channel' \
              'Prune the channel to the last N packages' \
              'Sign the databases and push gh-pages'; do
    line="$(grep -nF "      - name: $step" "$wf" | cut -d: -f1)"
    [[ -n "$line" ]] || return 1
    # El gate va pegado al paso, pero puede quedar tras un id: o un env:
    # del propio paso; mirar las tres líneas siguientes alcanza.
    local off found=0
    for off in 1 2 3; do
      if [[ "$(sed -n "$((line + off))p" "$wf")" == "        if: github.event_name == 'repository_dispatch'" ]]; then
        found=1
      fi
    done
    (( found == 1 )) || return 1
  done
  return 0
}
check_publish_gates "$WORKFLOW" || die 'los pasos de publicación no llevan el gate de repository_dispatch'

# Mutación: un publish que no usa el mecanismo elegido (publish-artifact)
# debe morir en el check.
sed 's|bash omarchy-pkgs/bin/publish-artifact --remote|bash omarchy-pkgs/bin/otro-mecanismo --remote|' \
  "$WORKFLOW" > "$TEST_ROOT/package.mutated-publish.yml"
expect_fail 'publish sin publish-artifact' publish_checks "$TEST_ROOT/package.mutated-publish.yml"

# Mutación: si el gate se pierde, el dogfooding por workflow_dispatch
# publicaría; el check por paso lo detecta.
sed "/^        if: github.event_name == 'repository_dispatch'$/d" "$WORKFLOW" \
  > "$TEST_ROOT/package.sin-gate.yml"
expect_fail 'pasos de publicación sin gate' check_publish_gates "$TEST_ROOT/package.sin-gate.yml"

# Los pasos de publicación y el issue de fallo son bash válido.
for step in 'Publish the package into the stable channel' \
            'Prune the channel to the last N packages' \
            'Sign the databases and push gh-pages' \
            'Collect the failure log' \
            'Open the failure issue'; do
  script="$TEST_ROOT/step.sh"
  extract_run "$step" > "$script"
  [[ -s "$script" ]] || die "no se pudo extraer el paso de package.yml: $step"
  bash -n "$script" || die "el paso extraído no es bash válido: $step"
done

# ---------------------------------------------------------------------- #
# Poda funcional: contra un canal de juguete con db de verdad (tar con    #
# desc), la ventana N conserva las últimas versiones por sort -V (así     #
# 0.1.10 queda más nueva que 0.1.9) y el db manda: un archivo que el db   #
# todavía sirve no se toca; si la poda lo tocaría, la reparación corre    #
# bin/unpublish-packages y re-agrega la más nueva con bin/publish-artifact. #
# ---------------------------------------------------------------------- #
prune_script="$TEST_ROOT/prune.sh"
extract_run 'Prune the channel to the last N packages' > "$prune_script"
[[ -s "$prune_script" ]] || die 'no se pudo extraer el paso de poda de package.yml'

# Stubs del toolkit de omarchy-pkgs (offline): registran la llamada y el
# publish-artifact del stub emula el repo-add reescribiendo el db.
ws="$TEST_ROOT/ws"
mkdir -p "$ws/omarchy-pkgs/bin"
stub_log="$TEST_ROOT/stub.log"
: > "$stub_log"
cat > "$ws/omarchy-pkgs/bin/unpublish-packages" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$STUB_LOG"
STUB
cat > "$ws/omarchy-pkgs/bin/publish-artifact" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$STUB_LOG"
remote=""
pkgfile=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --remote) remote="$2"; shift 2 ;;
    --mirror|--arch) shift 2 ;;
    *) pkgfile="$1"; shift ;;
  esac
done
[[ -n "$remote" && -n "$pkgfile" && -f "$pkgfile" ]] || exit 1
db="$remote/stable/x86_64/omarchy.db.tar.zst"
dir="$(mktemp -d)"
for other in "$pkgfile" $STUB_OTHER; do
  entry="$(basename "$other")"
  entry="${entry%.pkg.tar.zst}"
  mkdir -p "$dir/$entry"
  printf '%%FILENAME%%\n%s\n' "$(basename "$other")" > "$dir/$entry/desc"
done
( cd "$dir" && find . -name desc | sed 's|^\./||' | tar -cf "$db" -T - )
rm -rf "$dir"
STUB

make_db() { # make_db <db_path> <filename servido>...
  local db="$1"; shift
  local dir="$TEST_ROOT/db-build"
  rm -rf "$dir"; mkdir -p "$dir"
  local f entry
  for f in "$@"; do
    entry="${f%.pkg.tar.zst}"
    mkdir -p "$dir/$entry"
    printf '%%FILENAME%%\n%s\n' "$f" > "$dir/$entry/desc"
  done
  ( cd "$dir" && find . -name desc | sed 's|^\./||' | tar -cf "$db" -T - )
}

make_channel() { # make_channel <channel_dir> <filename servido por el db>...
  local channel="$1"; shift
  rm -rf "$channel"; mkdir -p "$channel"
  local v f
  # Ocho versiones seguidas, con el salto a dos dígitos incluido: la
  # ventana ordena por sort -V, no por orden de bytes (0.1.10 > 0.1.9).
  for v in 0.1.3 0.1.4 0.1.5 0.1.6 0.1.7 0.1.8 0.1.9 0.1.10; do
    f="ravn-trio-${v}-1-x86_64.pkg.tar.zst"
    : > "$channel/$f"
    : > "$channel/$f.sig"
  done
  : > "$channel/omarchy-4.0.6-109-x86_64.pkg.tar.zst"
  : > "$channel/omarchy-4.0.6-109-x86_64.pkg.tar.zst.sig"
  make_db "$channel/omarchy.db.tar.zst" "$@"
}

run_prune() { # run_prune <script> <repo_dir> <keep_n> <pkgname>
  local script="$1" repo_dir="$2" keep="$3" pkgname="$4"
  (
    set -Eeuo pipefail
    cd "$ws"
    STUB_LOG="$stub_log" STUB_OTHER='omarchy-4.0.6-109-x86_64.pkg.tar.zst' \
      REPO_DIR="$repo_dir" PKG_NAMES="$pkgname" PKG_BASES="$pkgname" PRUNE_KEEP_N="$keep" \
      bash "$script"
  )
}

db_served_exists() { # db_served_exists <channel>: todo archivo que el db sirve está en el árbol
  local channel="$1" f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$channel/$f" ]] || return 1
  done < <(tar -xO -f "$channel/omarchy.db.tar.zst" --wildcards '*/desc' \
             | awk '/^%FILENAME%$/{getline; print}')
  return 0
}

count_versions() { # count_versions <channel> <pkgname>
  local f count=0
  local re="^$2-[0-9][0-9a-zA-Z.]*-[0-9]+-x86_64\.pkg\.tar\.zst$"
  for f in "$1"/*.pkg.tar.zst; do
    [[ -e "$f" ]] || continue
    if [[ "$(basename "$f")" =~ $re ]]; then count=$(( count + 1 )); fi
  done
  printf '%s\n' "$count"
}

# Caso A (normal): el db sirve la más nueva; la poda borra las 3 más viejas
# (8 versiones, ventana 5) y no llama al toolkit del db.
repo_a="$TEST_ROOT/repo-a"
make_channel "$repo_a/stable/x86_64" \
  'ravn-trio-0.1.10-1-x86_64.pkg.tar.zst' \
  'omarchy-4.0.6-109-x86_64.pkg.tar.zst'
: > "$stub_log"
run_prune "$prune_script" "$repo_a" 5 ravn-trio
channel_a="$repo_a/stable/x86_64"
[[ "$(count_versions "$channel_a" ravn-trio)" == 5 ]] || \
  die "poda normal: esperaba 5 ravn-trio, quedaron $(count_versions "$channel_a" ravn-trio)"
[[ -e "$channel_a/ravn-trio-0.1.6-1-x86_64.pkg.tar.zst" ]] || die 'poda normal: 0.1.6 se fue de más'
[[ -e "$channel_a/ravn-trio-0.1.10-1-x86_64.pkg.tar.zst" ]] || die 'poda normal: la más nueva se fue'
[[ ! -e "$channel_a/ravn-trio-0.1.5-1-x86_64.pkg.tar.zst" ]] || die 'poda normal: 0.1.5 sobrevivió'
[[ -e "$channel_a/ravn-trio-0.1.6-1-x86_64.pkg.tar.zst.sig" ]] || die 'poda normal: la firma de 0.1.6 se fue'
[[ ! -e "$channel_a/ravn-trio-0.1.3-1-x86_64.pkg.tar.zst" ]] || die 'poda normal: 0.1.3 sobrevivió'
[[ ! -e "$channel_a/ravn-trio-0.1.3-1-x86_64.pkg.tar.zst.sig" ]] || die 'poda normal: la firma de 0.1.3 sobrevivió'
[[ -e "$channel_a/omarchy-4.0.6-109-x86_64.pkg.tar.zst" ]] || die 'poda: tocó un paquete ajeno'
db_served_exists "$channel_a" || die 'poda normal: el db quedó sirviendo un archivo que ya no está'
[[ ! -s "$stub_log" ]] || die "poda normal no debió llamar al toolkit del db: $(cat "$stub_log")"

# Caso B (reparación): el db sirve una versión vieja (estado anómalo); la
# poda la protegería para siempre, así que retira la entrada con
# bin/unpublish-packages y re-agrega la más nueva con bin/publish-artifact.
repo_b="$TEST_ROOT/repo-b"
make_channel "$repo_b/stable/x86_64" \
  'ravn-trio-0.1.4-1-x86_64.pkg.tar.zst' \
  'omarchy-4.0.6-109-x86_64.pkg.tar.zst'
: > "$stub_log"
run_prune "$prune_script" "$repo_b" 5 ravn-trio
channel_b="$repo_b/stable/x86_64"
[[ "$(count_versions "$channel_b" ravn-trio)" == 5 ]] || \
  die "reparación: esperaba 5 ravn-trio, quedaron $(count_versions "$channel_b" ravn-trio)"
[[ ! -e "$channel_b/ravn-trio-0.1.4-1-x86_64.pkg.tar.zst" ]] || die 'reparación: 0.1.4 quedó en el árbol'
grep -q 'unpublish-packages' "$stub_log" || die 'la reparación no corrió bin/unpublish-packages'
grep -q 'publish-artifact' "$stub_log" || die 'la reparación no re-agregó la versión nueva'
db_served_exists "$channel_b" || die 'reparación: el db quedó sirviendo un archivo que ya no está'

# Mutación (poda que borra de más): sin reparación y sin guardia, la poda
# borra el archivo que el db todavía sirve y el check del db lo detecta.
prune_bad="$TEST_ROOT/prune-bad.sh"
sed -e 's/^  if \[\[ -n "\$danger" \]\]; then$/  if false; then/' \
    -e 's/^    if grep -qxF "\$f" <<<"\$db_files"; then$/    if false; then/' \
  "$prune_script" > "$prune_bad"
grep -qF 'if false; then' "$prune_bad" || die 'la mutación de la poda no se aplicó al fixture'
repo_c="$TEST_ROOT/repo-c"
make_channel "$repo_c/stable/x86_64" \
  'ravn-trio-0.1.4-1-x86_64.pkg.tar.zst' \
  'omarchy-4.0.6-109-x86_64.pkg.tar.zst'
: > "$stub_log"
run_prune "$prune_bad" "$repo_c" 5 ravn-trio || die 'la mutación de la poda no llegó a ejecutarse'
expect_fail 'una poda que borra de más deja el db sirviendo un archivo borrado' \
  db_served_exists "$repo_c/stable/x86_64"

# Mutación (default de la ventana): si el N default deja de ser 5, la poda
# conserva menos de lo prometido y el check del conteo lo detecta.
prune_n3="$TEST_ROOT/prune-n3.sh"
sed 's/PRUNE_KEEP_N:-5/PRUNE_KEEP_N:-3/' "$prune_script" > "$prune_n3"
grep -qF 'PRUNE_KEEP_N:-3' "$prune_n3" || die 'la mutación del N default no se aplicó al fixture'
repo_d="$TEST_ROOT/repo-d"
make_channel "$repo_d/stable/x86_64" \
  'ravn-trio-0.1.10-1-x86_64.pkg.tar.zst' \
  'omarchy-4.0.6-109-x86_64.pkg.tar.zst'
: > "$stub_log"
run_prune "$prune_n3" "$repo_d" 3 ravn-trio
[[ "$(count_versions "$repo_d/stable/x86_64" ravn-trio)" == 3 ]] || \
  die 'la mutación del N default no cambió la ventana'

printf '%s\n' 'ok package-workflow'

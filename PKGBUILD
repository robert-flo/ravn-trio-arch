pkgname=ravn-trio
pkgver=0.1.16
pkgrel=1
pkgdesc='Trío PM/WK/RV local en herdr: pj-trio y plugin ravn.trio'
arch=('any')
url='https://github.com/robert-flo/ravn-trio'
license=('MIT')
options=('!debug')
# herdr lo sirve omarchy-personal-repo (robert-flo/omarchy-pkgs).
depends=('bash' 'git' 'jq' 'libnotify' 'github-cli' 'herdr>=0.9.5')
makedepends=('make')
optdepends=('tobi-try: clonar con try-clone el proyecto meta que falte (PJ_TRIO_CLONE_CMD)')
# Fuente pública: el archivo del tag en GitHub. scripts/update_package.sh
# sube pkgver y este sha256 cuando sale un release nuevo de ravn-trio.
source=("${pkgname}-${pkgver}.tar.gz::${url}/archive/refs/tags/v${pkgver}.tar.gz")
sha256sums=(
  '28b125566f69ea9f535565535cfee092f4a3073651f8fa06351e0f7231d04fa1'
)

package() {
  local source_dir="${srcdir}/${pkgname}-${pkgver}"

  make -C "${source_dir}" DESTDIR="${pkgdir}" install
  install -Dm644 "${source_dir}/LICENSE" "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
  install -d "${pkgdir}/usr/share/bash-completion/completions"
  ln -s /usr/share/ravn/trio/runtime/completion/pj-trio.bash \
    "${pkgdir}/usr/share/bash-completion/completions/pj-trio"
}

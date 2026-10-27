pkgname=ravn-trio
pkgver=0.1.2
pkgrel=1
pkgdesc='Trío PM/WK/RV local en herdr: pj-trio y plugin ravn.trio'
arch=('any')
url='https://github.com/robert-flo/ravn-trio'
license=('MIT')
options=('!debug')
# herdr lo sirve omarchy-personal-repo (robert-flo/omarchy-pkgs).
depends=('bash' 'git' 'jq' 'libnotify' 'github-cli' 'herdr>=0.9.5')
makedepends=('make')
# Fuente privada: tarball vendoreado (git archive --prefix=${pkgname}-${pkgver}/
# v${pkgver} | gzip -n), así makepkg no necesita credenciales de GitHub.
source=("${pkgname}-${pkgver}.tar.gz")
sha256sums=(
  'ee09ec38cd6d660845bb1c1fe1955469c45693af2f8efd66d4ca033a9b9b9791'
)

package() {
  local source_dir="${srcdir}/${pkgname}-${pkgver}"

  make -C "${source_dir}" DESTDIR="${pkgdir}" install
  install -Dm644 "${source_dir}/LICENSE" "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
  install -d "${pkgdir}/usr/share/bash-completion/completions"
  ln -s /usr/share/ravn/trio/runtime/completion/pj-trio.bash \
    "${pkgdir}/usr/share/bash-completion/completions/pj-trio"
}

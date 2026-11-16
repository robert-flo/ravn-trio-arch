# ravn-trio-arch

Paquete Arch de [`ravn-trio`](https://github.com/robert-flo/ravn-trio): instala `pj-trio`
(trío PM/WK/RV en herdr) y el plugin `ravn.trio`.

- Comando: `/usr/bin/pj-trio` → `/usr/share/ravn/trio/pj-trio`
- Plugin herdr, prompt del PM, `trio-status` y `trio.conf.example`: `/usr/share/ravn/trio/`
- Completion: `/usr/share/bash-completion/completions/pj-trio`
- Dependencias: `bash git jq libnotify github-cli herdr>=0.9.5` (herdr sale de `omarchy-personal-repo`).

## Fuente y actualización automática

`robert-flo/ravn-trio` es público: el PKGBUILD baja el archivo del tag
(`https://github.com/robert-flo/ravn-trio/archive/refs/tags/v${pkgver}.tar.gz`) y lo
verifica con el `sha256sums` fijado. No hay tarball en este repo.

Cadena sin pasos manuales:

1. ravn-trio crea el GitHub Release de cada versión (`release.yml`) y despacha
   `upstream-released` acá; el cron diario de `update-upstream.yml` es la red.
2. `update-upstream.yml` compara el release con el PKGBUILD (`scripts/check_upstream.sh`),
   sube `pkgver`/`sha256sums` (`scripts/update_package.sh`), regenera `.SRCINFO`,
   construye, commitea a `main` y despacha `source-updated`.
3. `package.yml` construye lo que declara el PKGBUILD, prueba la instalación y lo publica
   en `omarchy-personal-repo`, salvo que el canal ya sirva ese mismo `pkgver-pkgrel`.

A mano: `make update-upstream` hace el chequeo y el bump del paso 2 en local, sin construir ni commitear.

## Instalar en local

```bash
makepkg -si
```

## Validar

`make help` lista los comandos; `RAVN_TRIO_SOURCE_DIR=../ravn-trio tests/validate-local-install.sh`
construye e instala el paquete en un contenedor Arch desechable. CI hace lo mismo con el archivo del tag verificado contra el sha256 del PKGBUILD.

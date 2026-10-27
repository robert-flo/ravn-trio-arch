# ravn-trio-arch

Paquete Arch de [`ravn-trio`](https://github.com/robert-flo/ravn-trio): instala `pj-trio`
(trío PM/WK/RV en herdr) y el plugin `ravn.trio`.

- Comando: `/usr/bin/pj-trio` → `/usr/share/ravn/trio/pj-trio`
- Plugin herdr, prompt del PM, `trio-status` y `trio.conf.example`: `/usr/share/ravn/trio/`
- Completion: `/usr/share/bash-completion/completions/pj-trio`
- Dependencias: `bash git jq libnotify github-cli herdr>=0.9.5` (herdr sale de `omarchy-personal-repo`).

## Fuente vendoreada

`robert-flo/ravn-trio` es privado, así que el tarball del release va en este repo:

```bash
git -C ../ravn-trio archive --format=tar --prefix=ravn-trio-0.1.1/ v0.1.1 | gzip -n > ravn-trio-0.1.1.tar.gz
sha256sum ravn-trio-0.1.1.tar.gz   # actualizá sha256sums y .SRCINFO
```

## Instalar en local

```bash
makepkg -si
```

## Validar

`make help` lista los comandos; `RAVN_TRIO_SOURCE_DIR=../ravn-trio tests/validate-local-install.sh`
construye e instala el paquete en un contenedor Arch desechable. CI hace lo mismo con el tarball vendoreado.

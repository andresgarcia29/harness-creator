#!/usr/bin/env bash
# instance-repo.sh — quién es el repo de la INSTANCIA, en un solo lugar.
#
# POR QUÉ EXISTE: el repo de la instancia (el que versiona `docs/`, `specs/`,
# los ADR y `harness-answers.yaml`) es el único del workspace que NO tiene
# `repos/<repo>` ni worktree: vive en el árbol del workspace y se publica por
# `instance-ship.sh`. Varios artefactos del pipeline necesitan reconocerlo para
# no exigirle algo que por construcción no puede tener, y cada uno resolviéndolo
# a su manera es la forma segura de que dos gates discrepen sobre el mismo repo.
#
# Se SOURCEA, no se ejecuta:
#   . "$WS/scripts/instance-repo.sh"
#   instance_repo_slug            → el nombre, o vacío si la instancia no lo declara
#   es_repo_de_la_instancia <x>   → 0 si <x> ES ese repo
#
# El nombre sale de `instance.repo` del answers y NO se infiere de "no existe el
# worktree": un repo mal tipeado tiene que seguir dando error, no apuntar en
# silencio a la raíz del workspace.

# WS lo pone quien sourcea (todos los scripts del harness ya lo tienen). El
# fallback existe para que sourcearlo suelto no muera bajo `set -u`.
instance_repo_slug() {  # → nombre del repo de la instancia, o vacío
  local ws="${WS:-.}" v
  [ -f "$ws/harness-answers.yaml" ] || return 0
  # El bloque `instance:` y su clave `repo:`, sin traer un parser de YAML: se
  # entra al bloque y se sale en cuanto aparece otra clave de primer nivel, que
  # es lo que impide leer el `repo:` de otra sección.
  v="$(awk '/^instance:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/^[[:space:]]*repo:[[:space:]]*/{
         sub(/^[[:space:]]*repo:[[:space:]]*/,""); gsub(/["\047]/,""); print; exit}' \
       "$ws/harness-answers.yaml" 2>/dev/null)"
  v="${v%%#*}"                                   # comentario al final de la línea
  v="${v%"${v##*[! ]}"}"                         # espacios sobrantes
  v="${v%/}"; v="${v##*/}"; v="${v%.git}"        # url completa o slug → nombre
  case "$v" in '{{'*) return 0 ;; esac           # placeholder sin sustituir
  printf '%s' "$v"
}

es_repo_de_la_instancia() {  # es_repo_de_la_instancia <repo> → 0 si lo es
  local slug
  [ -n "${1:-}" ] || return 1
  slug="$(instance_repo_slug)"
  [ -n "$slug" ] && [ "$1" = "$slug" ]
}

#!/usr/bin/env bash
# El PANEL del harness (`make ui`). Prefiere el daemon Go — trae multi-máquina,
# terminales en vivo, sonda de MCP, archivar, liveness honesta y el wizard de
# init. Orden: 1) `harness` instalado por brew (el camino canónico:
# brew install andresgarcia29/agm/harness), 2) el binario local bajado de un
# release, 3) el panel Python (server.py) — funciona, pero sin esas features.
# Solo lectura, solo 127.0.0.1.
set -euo pipefail
PORT="${1:-7717}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER="0.46.0"
REPO="andresgarcia29/harness-daemon"
BIN="$DIR/harnessd"

# 1) el binario de brew: un solo gestor de versiones, cero descargas manuales
if command -v harness >/dev/null 2>&1; then
  opener=open; command -v xdg-open >/dev/null 2>&1 && opener=xdg-open
  ( sleep 1.2; "$opener" "http://127.0.0.1:$PORT" >/dev/null 2>&1 || true ) &
  exec harness run --port "$PORT" --workspace .
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"; case "$arch" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
asset="harnessd-${os}-${arch}"

# El sha256 de un archivo con lo que haya en la máquina: sha256sum (GNU) o
# shasum -a 256 (BSD/macOS). Devuelve 1 si no hay ninguna, y quien llama declara
# "no pude verificar": una verificación que no ocurrió jamás se reporta como
# ocurrida, ni tampoco como binario malo. Es el tercer estado.
sha256_de() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
    return 0
  fi
  return 1
}

have=""
if [ -x "$BIN" ]; then
  # Si el binario está pero no sabe decir su versión (truncado, arquitectura
  # ajena, corrupto), eso se DICE y se trata como ausente. Callarlo dejaba un
  # have="" sin motivo visible y el rebaje al panel Python parecía capricho.
  if ! have="$("$BIN" version 2>&1)"; then
    echo "ℹ️  el harnessd local no dice su versión (dijo: ${have:-nada}); lo trato como ausente"
    have=""
  fi
fi

# Bajar/actualizar el binario si no tenemos la versión correcta.
if [ "$have" != "$VER" ] && command -v gh >/dev/null 2>&1; then
  # Llaves obligatorias: pegado al puntito suspensivo, bash 3.2 se come el
  # byte no ASCII como parte del NOMBRE y muere con "REPO…: unbound variable".
  echo "→ bajando $asset v$VER del release de github.com/${REPO}…"
  tmp="$(mktemp -d)"
  bajado=0
  verificado=no
  # Sin 2>/dev/null: el motivo por el que gh no pudo bajar (release inexistente,
  # sin permiso, sin red) es EXACTAMENTE lo que hace falta para entender por qué
  # después arranca el panel Python. Un fallback mudo se lee como capricho.
  if gh release download "v$VER" -R "$REPO" -p "$asset" -D "$tmp"; then
    if [ -f "$tmp/$asset" ]; then
      bajado=1
    else
      echo "  ⚠️  gh terminó bien pero no dejó $asset: no instalo nada"
    fi
  else
    echo "  ⚠️  no pude bajar $asset v$VER (el motivo lo dijo gh acá arriba)"
  fi

  # Un binario que ejecutás sin verificar es toda la cadena de suministro
  # confiando en el transporte. El release publica SHA256SUMS: si está, se
  # COMPARA de verdad, y un sha que no coincide NO se instala. Si no está, se
  # AVISA y se sigue: fingir la verificación (o callarla) sería peor que no
  # tenerla, porque el "✓ instalado" de abajo estaría mintiendo.
  if [ "$bajado" = 1 ]; then
    if gh release download "v$VER" -R "$REPO" -p SHA256SUMS -D "$tmp" && [ -f "$tmp/SHA256SUMS" ]; then
      esperado="$(awk -v a="$asset" '$2 == a || $2 == "*" a {print $1}' "$tmp/SHA256SUMS")"
      if [ -z "$esperado" ]; then
        echo "  ⚠️  SHA256SUMS no lista $asset: NO pude verificar (ni bueno ni malo)"
      elif obtenido="$(sha256_de "$tmp/$asset")"; then
        if [ "$obtenido" = "$esperado" ]; then
          verificado=si
        else
          echo "  ✕ el sha256 de $asset NO coincide con el que publica el release:"
          echo "      release: $esperado"
          echo "      bajado : $obtenido"
          echo "    no lo instalo ni lo ejecuto."
          bajado=0
        fi
      else
        echo "  ⚠️  ni sha256sum ni shasum en esta máquina: NO pude verificar"
      fi
    else
      echo "  ⚠️  el release v$VER no publica SHA256SUMS: instalo SIN verificar"
    fi
  fi

  if [ "$bajado" = 1 ]; then
    # Aterriza AL LADO del destino y recién ahí el rename. Un mv desde el tmp
    # del sistema suele cruzar filesystems, y eso copia byte a byte SOBRE $BIN:
    # si se corta a la mitad queda un harnessd truncado, ya con permiso de
    # ejecución, que ninguna verificación de antes cubre. El rename dentro del
    # mismo directorio sí es atómico: el binario está entero o no está.
    cp "$tmp/$asset" "$BIN.nuevo"
    chmod +x "$BIN.nuevo"
    mv "$BIN.nuevo" "$BIN"
    have="$VER"
    if [ "$verificado" = si ]; then
      echo "  ✓ harnessd $VER instalado (sha256 verificado contra el release)"
    else
      echo "  ✓ harnessd $VER instalado, SIN verificar (mirá el aviso de arriba)"
    fi
  fi
  rm -rf "$tmp"
fi

# Arrancar harnessd si lo tenemos (aunque sea una versión previa).
if [ -x "$BIN" ] && [ -n "$have" ]; then
  [ "$have" != "$VER" ] && echo "ℹ️  uso el harnessd que tienes (v$have); el v$VER está en los releases de $REPO."
  opener=open; command -v xdg-open >/dev/null 2>&1 && opener=xdg-open
  ( sleep 1.2; "$opener" "http://127.0.0.1:$PORT" >/dev/null 2>&1 || true ) &
  exec "$BIN" run --port "$PORT" --workspace .
fi

# Sin binario ni forma de bajarlo → panel Python (sin las features nuevas).
echo "⚠️  no hay harnessd — caigo al panel Python (server.py): funciona, pero SIN"
echo "   multi-máquina, terminales ni sonda de MCP."
echo "   Para el panel completo (daemon multi-máquina, OSS), bajando TAMBIÉN el"
echo "   SHA256SUMS del release y comparando antes de darle permiso de ejecución:"
echo "     gh release download v$VER -R $REPO -p $asset -p SHA256SUMS -D ."
echo "     shasum -a 256 -c SHA256SUMS --ignore-missing && mv $asset $BIN && chmod +x $BIN"
exec python3 "$DIR/server.py" --port "$PORT" --workspace . --open

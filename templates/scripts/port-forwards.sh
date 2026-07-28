#!/usr/bin/env bash
# port-forwards.sh: túneles supervisados con sondas de IDENTIDAD, no de vida.
#
# POR QUÉ EXISTE, con los dos casos de campo adentro:
#   1. "curl localhost:9090 responde" NO dice QUÉ responde: un port-forward
#      viejo de observabilidad tomó el puerto y tres specs salieron rojas con
#      404 que casi se leen como regresión. La sonda de identidad pregunta
#      "¿responde ESTE servicio?": un 404/200 donde se esperaba 401 es la
#      firma de OTRO proceso en el puerto, y se dice con esas palabras.
#   2. El forward se cae y nadie lo relevanta: un agente perdió 18 minutos y
#      terminó escribiendo su propio supervisor. `ensure` relanza muertos.
# Los puertos se declaran UNA vez (harness-answers.yaml, bloque port_forwards),
# no repetidos en cada prompt. El cmd lo declara la instancia (kubectl, ssh -L,
# cloud-sql-proxy, lo que sea): vendor-neutral por construcción.
#
# Uso: port-forwards.sh up|ensure|down|status|doctor [nombre]
# Portabilidad: bash 3.2, BSD userland, curl. Estado en .harness/port-forwards/.
set -uo pipefail

WS="$(cd "$(dirname "$0")/.." && pwd)"
ANSWERS="$WS/harness-answers.yaml"
PIDDIR="$WS/.harness/port-forwards"
CMD="${1:-status}"
ONLY="${2:-}"

# ── declaraciones: una línea TSV por forward ──────────────────────────
# name<TAB>port<TAB>cmd<TAB>method<TAB>path<TAB>expect_status<TAB>expect_body
declares() {
  [ -f "$ANSWERS" ] || return 0
  awk '
    BEGIN { q = sprintf("%c", 39) }
    /^[[:space:]]*#/ { next }
    /^port_forwards:/ { ind=1; next }
    ind && /^[^[:space:]]/ { ind=0 }
    # nombre a 2 espacios; el tercer caracter de un atributo (4 espacios) es
    # espacio, asi que no colisiona. Sin {n}: awk BSD.
    ind && /^[[:space:]][[:space:]][a-zA-Z0-9_-]+:/ && $0 !~ /^[[:space:]][[:space:]][[:space:]]/ {
      flushrec(); cur=$0; sub(/^[[:space:]]+/,"",cur); sub(/:.*/,"",cur); next }
    ind && cur != "" && /^[[:space:]][[:space:]][[:space:]][[:space:]][a-z_]+:/ {
      k=$0; sub(/^[[:space:]]+/,"",k); v=k
      sub(/:.*/,"",k); sub(/^[^:]*:[[:space:]]*/,"",v)
      sub(/[[:space:]]+$/,"",v)
      # SOLO el par de comillas envolvente: un cmd con comillas internas
      # ("sh -c '"'"'...'"'"'") se despedazaba con el gsub global
      if ((substr(v,1,1) == "\"" && substr(v,length(v),1) == "\"") ||
          (substr(v,1,1) == q    && substr(v,length(v),1) == q))
        v = substr(v, 2, length(v)-2)
      a[k]=v; next }
    END { flushrec() }
    function flushrec() {
      if (cur != "")
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", cur, a["port"], a["cmd"],
               a["probe_method"], a["probe_path"], a["probe_expect_status"], a["probe_expect_body"]
      split("", a); cur=""
    }
  ' "$ANSWERS" 2>/dev/null
}

alive() {  # alive <name> → 0 si el pid del pidfile vive
  local pid
  pid="$(cat "$PIDDIR/$1.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

probe_one() {  # probe_one <name> <port> <method> <path> <exp_status> <exp_body>
  # → 0 identidad ok / 1 sin respuesta / 2 IMPOSTOR
  local body="$PIDDIR/$1.probe" got
  # --compressed SIEMPRE: sin el, un body gzip hace que el grep no encuentre
  # nada y no falle (caso de campo: falso negativo en silencio)
  got="$(curl -sS --compressed -m 5 -X "${3:-GET}" -o "$body" -w '%{http_code}' \
    "http://127.0.0.1:$2${4:-/}" 2>/dev/null)" || return 1
  if [ -n "${5:-}" ] && [ "$got" != "$5" ]; then
    echo "🚨 IMPOSTOR en $1: el puerto $2 responde, pero NO es lo que declaraste:"
    echo "   esperaba HTTP $5 en ${4:-/} y contestó $got. Eso es OTRO proceso en el"
    echo "   puerto (típicamente un port-forward viejo de otra cosa)."
    echo "   ↳ remediación: scripts/port-forwards.sh down $1 && scripts/port-forwards.sh up $1"
    echo "     si persiste: lsof -nP -iTCP:$2 -sTCP:LISTEN  (Linux: ss -ltnp)"
    return 2
  fi
  if [ -n "${6:-}" ] && ! grep -q -- "$6" "$body" 2>/dev/null; then
    echo "🚨 IMPOSTOR en $1: status $got correcto pero el body NO contiene '$6'"
    echo "   ↳ misma remediación: down $1 && up $1; luego lsof/ss sobre el puerto $2"
    return 2
  fi
  return 0
}

start_one() {  # start_one <name> <port> <cmd> <method> <path> <exp_s> <exp_b>
  if alive "$1"; then
    echo "· $1 ya corre (pid $(cat "$PIDDIR/$1.pid"))"
  else
    [ -n "$3" ] || { echo "❌ $1 no declara cmd:"; return 1; }
    nohup sh -c "$3" >> "$PIDDIR/$1.log" 2>&1 &
    echo $! > "$PIDDIR/$1.pid"
    echo "→ $1 lanzado (pid $!, puerto $2): $3"
  fi
  # poll de arranque: hasta 15 s a que la sonda conteste
  local i=0
  while [ "$i" -lt 15 ]; do
    if out="$(probe_one "$1" "$2" "$4" "$5" "$6" "$7")"; then
      echo "✅ $1: identidad verificada (HTTP ${6:+$6 }en el puerto $2)"
      return 0
    elif [ $? -eq 2 ]; then
      printf '%s\n' "$out"
      return 2
    fi
    sleep 1; i=$((i+1))
  done
  echo "⚠️  $1: sin respuesta en el puerto $2 tras 15s (log: $PIDDIR/$1.log)"
  return 1
}

stop_one() {  # stop_one <name>
  local pid
  pid="$(cat "$PIDDIR/$1.pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    echo "🧹 $1 detenido (pid $pid)"
  fi
  rm -f "$PIDDIR/$1.pid"
}

check_ports_unique() {
  local dupes
  dupes="$(declares | cut -f2 | sort | uniq -d)"
  if [ -n "$dupes" ]; then
    echo "❌ puertos DUPLICADOS en port_forwards: $(printf '%s' "$dupes" | tr '\n' ' ')"
    declares | awk -F'\t' -v d="$dupes" 'index(d, $2) { print "   · " $1 " usa el puerto " $2 }'
    echo "   ↳ un puerto = un servicio; corrige harness-answers.yaml"
    return 1
  fi
}

rows="$(declares)"
if [ -z "$rows" ] && [ "$CMD" != "doctor" ]; then
  echo "ℹ️  sin port_forwards declarados en harness-answers.yaml (bloque port_forwards:)"
  exit 0
fi
mkdir -p "$PIDDIR"

rc=0
case "$CMD" in
  up|ensure)
    check_ports_unique || exit 1
    while IFS="$(printf '\t')" read -r name port cmd method path exps expb; do
      [ -n "$name" ] || continue
      [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue
      start_one "$name" "$port" "$cmd" "$method" "$path" "$exps" "$expb" || rc=1
    done <<EOF
$rows
EOF
    ;;
  down)
    while IFS="$(printf '\t')" read -r name port cmd method path exps expb; do
      [ -n "$name" ] || continue
      [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue
      stop_one "$name"
    done <<EOF
$rows
EOF
    ;;
  status)
    while IFS="$(printf '\t')" read -r name port cmd method path exps expb; do
      [ -n "$name" ] || continue
      if alive "$name"; then vivo="vivo (pid $(cat "$PIDDIR/$name.pid"))"; else vivo="MUERTO"; rc=1; fi
      if out="$(probe_one "$name" "$port" "$method" "$path" "$exps" "$expb")"; then
        ident="identidad ok"
      elif [ $? -eq 2 ]; then
        ident="IMPOSTOR"; rc=1
        printf '%s\n' "$out"
      else
        ident="sin respuesta"; rc=1
      fi
      echo "· $name  puerto $port  $vivo  $ident"
    done <<EOF
$rows
EOF
    ;;
  doctor)
    # read-only, para doctor.sh: esquema + puertos únicos + sonda best-effort
    [ -z "$rows" ] && { echo "✅ port-forwards: nada declarado"; exit 0; }
    check_ports_unique || rc=1
    while IFS="$(printf '\t')" read -r name port cmd method path exps expb; do
      [ -n "$name" ] || continue
      [ -n "$port" ] || { echo "❌ $name sin port:"; rc=1; }
      [ -n "$cmd" ] || { echo "❌ $name sin cmd:"; rc=1; }
      [ -n "$exps" ] || { echo "❌ $name sin probe_expect_status: (la sonda de identidad lo exige)"; rc=1; }
    done <<EOF
$rows
EOF
    [ "$rc" -eq 0 ] && echo "✅ port-forwards: declaraciones completas"
    ;;
  *)
    echo "uso: port-forwards.sh up|ensure|down|status|doctor [nombre]"
    exit 1 ;;
esac
exit "$rc"

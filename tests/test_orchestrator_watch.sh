#!/usr/bin/env bash
# test_orchestrator_watch.sh: el vigilante del orquestador.
#
# Lo que se prueba es exactamente lo que el número exige: el 51% del reloj de
# una ola son huecos de más de 20 min sin un solo evento de bus, o sea sesiones
# muertas que nadie relanza. Un vigilante que relanza de más es peor que
# ninguno (mata sesiones sanas y paga el modelo caro), así que las aserciones
# van en los dos sentidos: relanza lo varado Y NO toca lo que está trabajando.
set -u
. "$(dirname "$0")/lib.sh"
root="$(cd "$(dirname "$0")/.." && pwd)"

t_ws

# ── un workspace de mentira, con lo mínimo que el script toca ─────────
mkdir -p "$WS/scripts" "$WS/.harness" "$WS/bin"
cp "$root/templates/scripts/orchestrator-watch.sh" "$WS/scripts/"
cp "$root/templates/scripts/emit.sh" "$WS/scripts/"
cp "$root/templates/scripts/harness-policy.py" "$WS/scripts/"
sed 's/{{LOOP_BUDGET}}/3/' "$root/templates/policy.json.tmpl" > "$WS/harness-policy.json"

# El CLI de mentira: deja rastro y sale. Que salga rápido es parte del test:
# así el lease queda huérfano y la pasada siguiente puede reclamarlo, que es la
# situación real de una sesión que muere al arrancar.
cat > "$WS/bin/claude" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/../relanzamientos.txt"
SH
chmod +x "$WS/bin/claude"
export PATH="$WS/bin:$PATH"

# El mtime de state.json es el PISO del reloj (una tarea recién abierta no
# lleva varada desde 1970), así que un test que la crea al vuelo tiene que
# envejecerla igual que envejece los eventos: si no, mide otra cosa.
# OJO: `touch -t` lee la marca en hora LOCAL, así que acá NO va `date -u`. Con
# -u el archivo quedaba en el FUTURO por el offset del huso (medido: +6 h en
# UTC-6) y el hueco daba negativo, o sea que el test probaba lo contrario.
envejece() {  # envejece <archivo> <segundos>
  local when
  when="$(date -r "$(( $(date +%s) - $2 ))" +%Y%m%d%H%M.%S 2>/dev/null \
      || date -d "@$(( $(date +%s) - $2 ))" +%Y%m%d%H%M.%S)"
  touch -t "$when" "$1"
}

nueva_tarea() {  # nueva_tarea <id> <fase> [antigüedad-en-segundos]
  mkdir -p "$WS/tasks/$1"
  printf '{"schema":1,"task_id":"%s","phase":"%s","lane":"express","review_rounds":0,"history":[]}\n' \
    "$1" "$2" > "$WS/tasks/$1/state.json"
  [ -n "${3:-}" ] && envejece "$WS/tasks/$1/state.json" "$3"
  return 0
}

evento() {  # evento <task> <kind> <hace-cuántos-segundos>
  local ts
  ts="$(date -u -r "$(( $(date -u +%s) - $3 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
     || date -u -d "@$(( $(date -u +%s) - $3 ))" +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","kind":"%s","task":"%s","summary":"x"}\n' "$ts" "$2" "$1" >> "$WS/.harness/events.jsonl"
}

corre() {  # corre <modo> [IDLE]
  ( cd "$WS" && HARNESS_ORCH_IDLE="${2:-720}" HARNESS_ORCH_MAX=2 \
      bash scripts/orchestrator-watch.sh "$1" 2>&1 )
}

relanzos() { [ -f "$WS/relanzamientos.txt" ] && wc -l < "$WS/relanzamientos.txt" | tr -d ' ' || echo 0; }

# El relanzamiento es `nohup ... &` (tiene que serlo: el vigilante no espera a
# la sesión que lanza), así que el rastro aparece DESPUÉS de que el script
# vuelve. Contarlo sin esperar convierte el test en una moneda al aire.
espera_relanzos() {  # espera_relanzos <n-esperado> → el conteo real
  local n=0 i=0
  while [ "$i" -lt 50 ]; do
    n="$(relanzos)"
    [ "$n" -ge "$1" ] && break
    sleep 0.1; i=$((i+1))
  done
  printf '%s' "$n"
}
reposa() { sleep 0.5; }   # para las aserciones NEGATIVAS: darle chance de fallar

echo "── una tarea que acaba de emitir NO se toca"
nueva_tarea VIVA implement
evento VIVA tool 30
out="$(corre once)"; reposa
assert_eq 0 "$(relanzos)" "sin relanzar: 30s de silencio no son un hueco"
assert_contains "$out" "1 tarea(s) en fase no terminal" "y la contó igual"

echo
echo "── una tarea varada 20 min SÍ se relanza"
nueva_tarea VARADA implement 1300
evento VARADA tool 1300
out="$(corre once)"
assert_contains "$out" "VARADA" "la nombra"
assert_contains "$out" "relanzada" "y la relanza"
assert_eq 1 "$(espera_relanzos 1)" "una sola vez"
assert_contains "$(cat "$WS/relanzamientos.txt")" "/smart VARADA" \
  "con el comando que RETOMA por state.json, no uno nuevo"
assert_file "$WS/.harness/orch-watch/VARADA.json" "queda el registro del intento"
assert_eq 1 "$(jq -r '.attempts' "$WS/.harness/orch-watch/VARADA.json")" "con el contador en 1"

echo
echo "── una llamada EN VUELO no es una sesión muerta (el gate de navegador)"
rm -f "$WS/relanzamientos.txt" "$WS/.harness/events.jsonl"
rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch" "$WS/tasks"
nueva_tarea LENTA implement 2000
evento LENTA tool 2000
evento LENTA tool-start 1300      # el último evento es un tool-start SIN cierre
out="$(corre once)"; reposa
assert_contains "$out" "EN VUELO" "lo dice con todas las letras"
assert_eq 0 "$(relanzos)" "y NO la mata: matar a un agente sano cuesta doble"
# y con el cierre después, vuelve a ser un hueco
evento LENTA tool 1200
out="$(corre once)"
assert_eq 1 "$(espera_relanzos 1)" "cerrada la llamada, el hueco vuelve a contar"

echo
echo "── archive y blocked no son huecos: no hay nada que relanzar"
rm -f "$WS/relanzamientos.txt" "$WS/.harness/events.jsonl"
rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch" "$WS/tasks"
nueva_tarea CERRADA archive 9000
nueva_tarea PARADA blocked 9000
evento CERRADA tool 9000
evento PARADA tool 9000
out="$(corre once)"; reposa
assert_eq 0 "$(relanzos)" "ni la archivada ni la bloqueada se relanzan"
assert_contains "$out" "0 tarea(s) en fase no terminal" "y ninguna de las dos cuenta"

echo
echo "── dos relanzamientos sin progreso = parada a humano, registrada"
rm -f "$WS/relanzamientos.txt" "$WS/.harness/events.jsonl"
rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch" "$WS/tasks"
# Cada pasada arranca con el bus limpio y el state envejecido a mano: es la
# tarea que NO avanza (misma fase, mismo HEAD) tras cada relanzamiento. El bus
# se borra porque el propio relanzamiento emite, y ese evento es actividad: sin
# limpiarlo, la pasada siguiente ve la tarea fresca y no la vuelve a mirar (que
# es, en producción, exactamente la conducta correcta).
pasada_trabada() {
  rm -f "$WS/.harness/events.jsonl"
  nueva_tarea TRABADA implement 1300
  corre once
}
pasada_trabada >/dev/null; espera_relanzos 1 >/dev/null
pasada_trabada >/dev/null; espera_relanzos 2 >/dev/null
out="$(pasada_trabada)"; reposa
assert_eq 2 "$(relanzos)" "relanzó dos veces y paró"
assert_contains "$out" "orchestrator_stalled" "la parada tiene código de policy"
assert_eq blocked "$(jq -r '.phase' "$WS/tasks/TRABADA/state.json")" \
  "y la tarea quedó bloqueada de verdad, no solo en la consola del daemon"
assert_contains "$(jq -r '.history[-1].reason' "$WS/tasks/TRABADA/state.json")" \
  "orchestrator_stalled" "con el motivo en el historial"

echo
echo "── el progreso resetea el contador (una tarea que avanzó no está atascada)"
rm -f "$WS/relanzamientos.txt"; rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch" "$WS/tasks"
nueva_tarea AVANZA implement
corre once 0 >/dev/null; espera_relanzos 1 >/dev/null
assert_eq 1 "$(jq -r '.attempts' "$WS/.harness/orch-watch/AVANZA.json")" "primer intento"
nueva_tarea AVANZA review          # cambió la fase: eso ES progreso
rm -f "$WS/.harness/events.jsonl"
corre once 0 >/dev/null; espera_relanzos 2 >/dev/null
assert_eq 1 "$(jq -r '.attempts' "$WS/.harness/orch-watch/AVANZA.json")" \
  "el contador vuelve a 1: la huella cambió"

echo
echo "── un deploy-watch en vuelo NO es una sesión muerta"
# deploy-watch puede mirar 39 minutos (medido) y emite al bus solo en los hitos.
# Su log crece en cada poll: eso es rastro, y sin mirarlo este vigilante
# levantaria un orquestador encima de un deploy en curso.
rm -f "$WS/relanzamientos.txt"; rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch" "$WS/tasks"
nueva_tarea DESPLEGANDO deploy 3000
printf 'mirando argocd\n' > "$WS/tasks/DESPLEGANDO/deploy-atlas.log"
out="$(corre once)"; reposa
assert_eq 0 "$(relanzos)" "el log fresco del deploy cuenta como actividad"
# y si el log tambien envejece, vuelve a ser un hueco de verdad
envejece "$WS/tasks/DESPLEGANDO/deploy-atlas.log" 3000
out="$(corre once)"
assert_eq 1 "$(espera_relanzos 1)" "con el log parado, el hueco vuelve a contar"

echo
echo "── el kill switch y el modo status: dos formas de no gastar un peso"
rm -f "$WS/relanzamientos.txt"; rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch" "$WS/tasks"
nueva_tarea QUIETA implement
out="$(corre status 0)"; reposa
assert_eq 0 "$(relanzos)" "status mira y no toca (es el modo por defecto)"
assert_contains "$out" "QUIETA" "pero dice lo que ve"
touch "$WS/.harness/orch-watch.off"
out="$(corre once 0)"; reposa
assert_eq 0 "$(relanzos)" "con .harness/orch-watch.off no relanza nada"
assert_contains "$out" "kill switch" "y lo dice"
rm -f "$WS/.harness/orch-watch.off"

echo
echo "── la tarea que emite y NO avanza: la otra señal (#155)"
# El hueco de bus caza al agente que murió callado. NO caza a la que sigue
# emitiendo y lleva 12h en la misma fase con el trabajo hecho: eso es lo que
# pasó tres veces el mismo día y lo detectó un humano mirando timestamps.
rm -f "$WS/relanzamientos.txt"; rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch" "$WS/tasks" "$WS/.harness/stale"
nueva_tarea PEGADA implement
python3 - "$WS/tasks/PEGADA/state.json" <<'PY'
import datetime as dt, json, sys
p = sys.argv[1]
s = json.load(open(p))
s["phase_since"] = (dt.datetime.now(dt.timezone.utc)
                    - dt.timedelta(minutes=766)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(s, open(p, "w"))
PY
evento PEGADA tool 5          # emitiendo AHORA: para el hueco de bus está sana
out="$(corre status)"; reposa
assert_contains "$out" "PEGADA" "la nombra aunque el bus esté fresco"
assert_contains "$out" "min en la misma fase" "y dice de qué señal habla (tiempo en fase, no silencio)"
assert_eq 0 "$(relanzos)" "avisar no es relanzar: la decisión sigue siendo del hueco de bus"

echo
echo "── sin CLI de claude no se inventa un relanzamiento"
rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch"
nopath="$(t_path_without claude)"
out="$(cd "$WS" && PATH="$nopath" HARNESS_ORCH_IDLE=0 bash scripts/orchestrator-watch.sh once 2>&1)"
assert_contains "$out" "no encuentro el CLI" "lo dice en vez de reportar una pasada limpia"
assert_no_file "$WS/.harness/orch-watch/QUIETA.json" "y no cuenta como intento"

t_done

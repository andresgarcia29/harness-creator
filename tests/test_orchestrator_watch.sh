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
echo "── el relevo de fase: una fase, una sesión"
# El corte no lo puede ejecutar el orquestador (un prompt no puede terminarse a
# sí mismo ni relanzarse): la transición deja el marcador, el orquestador cierra
# su turno y ESTE vigilante arranca la sesión nueva.
rm -f "$WS/relanzamientos.txt"; rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch" "$WS/tasks"
nueva_tarea RELEVO implement 300   # 5 min quieta: NO es un hueco (IDLE=720) pero pasó la gracia
printf '{"schema":1,"phase":"implement","at":"2026-08-12T00:00:00Z","from_session":"vieja"}\n' \
  > "$WS/tasks/RELEVO/handoff.json"
evento RELEVO tool 300
out="$(corre once)"; n="$(espera_relanzos 1)"
assert_contains "$out" "relevo de fase" "toma el relevo sin esperar los 12 min del hueco de bus"
assert_eq 1 "$n" "y arranca UNA sesión nueva"
assert_no_file "$WS/tasks/RELEVO/handoff.json" "consume el marcador: un relanzamiento por relevo"

# Y el guardarraíl que impide dos orquestadores sobre la misma tarea: si el
# orquestador NO cerró su turno, sus eventos corren el reloj y el relevo espera.
rm -f "$WS/relanzamientos.txt"; rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch" "$WS/tasks"
nueva_tarea TRABAJANDO implement
printf '{"schema":1,"phase":"implement","at":"2026-08-12T00:00:00Z","from_session":"viva"}\n' \
  > "$WS/tasks/TRABAJANDO/handoff.json"
evento TRABAJANDO tool 5        # emitiendo AHORA: la sesión vieja sigue trabajando
out="$(corre once)"; reposa
assert_eq 0 "$(relanzos)" "con la sesión vieja activa NO relanza: dos orquestadores son peores que uno"
assert_file "$WS/tasks/TRABAJANDO/handoff.json" "y el relevo queda pendiente para la pasada siguiente"

# status mira y no toca, también para el relevo.
out="$(corre status)"; reposa
assert_eq 0 "$(relanzos)" "status no toma relevos (es el modo por defecto)"

# Un marcador HUERFANO (de una tarea vieja cuyo relevo nunca ocurrio) no es un
# relevo pendiente: caduca. Caso de campo: 19 marcadores acumulados, o sea 19
# sesiones ajenas al pedido si alguien arrancaba el vigilante, y por ese riesgo
# el pipeline entero se corrio en UNA sesion (el relevo por fase, desactivado de
# hecho, y el contexto del orquestador subiendo 230k → 357k).
rm -f "$WS/relanzamientos.txt"; rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch" "$WS/tasks"
nueva_tarea HUERFANA implement 300
printf '{"schema":1,"phase":"implement","at":"2026-08-01T00:00:00Z","from_session":"vieja"}\n' \
  > "$WS/tasks/HUERFANA/handoff.json"
envejece "$WS/tasks/HUERFANA/handoff.json" 25200   # 7 h: mas viejo que el TTL de 6
evento HUERFANA tool 300
out="$(corre once)"; reposa
assert_eq 0 "$(relanzos)" "un marcador huerfano NO dispara una sesion"
assert_contains "$out" "huérfano" "y lo dice antes de tirarlo"
assert_no_file "$WS/tasks/HUERFANA/handoff.json" "el marcador vencido se caduca en vez de quedarse para siempre"

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
echo "── el techo del agregado: 125 sesiones agotaron la RAM de una maquina"
# El 2026-08-14 este vigilante relanzo 125 sesiones en 71 minutos, 29 en UNA
# sola pasada, sobre un backlog de tareas de dias atras que cruzaban el umbral
# de silencio a la vez. Medido: 1,15 GB por sesion, o sea ~140 GB pedidos contra
# 12 GB de RAM. Los limites que existian eran todos POR TAREA (lease y
# MAX_TRIES) y ninguno miraba el agregado.
tres_varadas() {  # deja tres tareas varadas y el estado limpio
  rm -f "$WS/relanzamientos.txt"
  rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch" "$WS/tasks" "$WS/.harness/events.jsonl"
  for t in "$@"; do
    nueva_tarea "$t" implement 1300
    evento "$t" tool 1300
  done
}
corre_tope() {  # corre_tope <var=val>... : una pasada con las perillas dadas
  ( cd "$WS" && env HARNESS_ORCH_IDLE=720 HARNESS_ORCH_MAX=2 "$@" \
      bash scripts/orchestrator-watch.sh once 2>&1 )
}

tres_varadas UNA DOS TRES
out="$(corre_tope HARNESS_ORCH_MAX_PER_PASS=1)"; sleep 0.6
assert_eq 1 "$(relanzos)" "tope por pasada: sube en rampa, no en escalon"
assert_contains "$out" "rampa" "y dice por que dejo a las otras"

# El tope de sesiones VIVAS: se cuentan los leases con PID vivo, que es dato que
# el lease ya guardaba. Aca se falsifican dos con procesos propios de verdad.
tres_varadas CUATRO CINCO
mkdir -p "$WS/.harness/claims/orch-AJENA1.lock.d" "$WS/.harness/claims/orch-AJENA2.lock.d"
for n in 1 2; do
  sleep 30 & p=$!
  echo "$p" > "$WS/.harness/claims/orch-AJENA$n.lock.d/pid"
  if [ -r "/proc/$p/stat" ]; then
    sed 's/.*) //' "/proc/$p/stat" | awk '{print $20}' > "$WS/.harness/claims/orch-AJENA$n.lock.d/pidid"
  else
    ps -o lstart= -p "$p" | tr -s ' ' | sed 's/^ *//;s/ *$//' > "$WS/.harness/claims/orch-AJENA$n.lock.d/pidid"
  fi
done
out="$(corre_tope HARNESS_ORCH_MAX_LIVE=2)"; reposa
assert_eq 0 "$(relanzos)" "con el tope de sesiones vivas alcanzado NO lanza ni una"
assert_contains "$out" "tope 2" "y dice cuantas hay vivas y cual es el tope"
kill %1 %2 2>/dev/null; wait 2>/dev/null

# El piso de memoria es el fail-safe de verdad: un tope mal calibrado en una
# maquina mas chica reproduce el incidente igual.
tres_varadas SEIS
out="$(corre_tope HARNESS_ORCH_MIN_FREE_MB=99999999)"; reposa
if printf '%s' "$out" | grep -q "MB libres"; then
  assert_eq 0 "$(relanzos)" "con la memoria por debajo del piso NO lanza"
  assert_contains "$out" "piso" "y nombra el piso que no se cumple"
else
  pass "sin lector de memoria en este SO: fail-open declarado (no se puede medir)"
  pass "y el vigilante sigue funcionando, que es lo que fail-open significa"
fi

echo
echo "── una tarea de hace cinco dias no es una sesion que murio hace un rato"
# Es el punto de diseno del incidente: casi todas las 83 varadas eran de dias
# atras, o sea tareas ABANDONADAS. Relanzarlas no las va a terminar. Se escalan
# por el camino que ya existe, que ademas las saca de la cola: pause deja la
# fase en blocked, y blocked es terminal para este vigilante.
tres_varadas VIEJA
python3 - "$WS/tasks/VIEJA/state.json" <<'PY2'
import datetime as dt, json, sys
s = json.load(open(sys.argv[1]))
s["phase_since"] = (dt.datetime.now(dt.timezone.utc)
                    - dt.timedelta(hours=120)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(s, open(sys.argv[1], "w"))
PY2
# Reescribir el state.json le movio el mtime, que es el PISO del reloj: sin
# volver a envejecerlo la tarea se ve recien tocada y no llega ni a varada.
envejece "$WS/tasks/VIEJA/state.json" 1300
out="$(corre_tope HARNESS_ORCH_MAX_AGE_H=48)"; reposa
assert_eq 0 "$(relanzos)" "una tarea abandonada NO se relanza"
assert_contains "$out" "abandonada" "se escala a humano, con el motivo dicho"
assert_eq "blocked" "$(jq -r '.phase' "$WS/tasks/VIEJA/state.json")" \
  "y queda en blocked, o sea FUERA de la cola de la proxima pasada"
out="$(corre_tope HARNESS_ORCH_MAX_AGE_H=48)"; reposa
assert_not_contains "$out" "VIEJA" "la pasada siguiente ni la mira"

echo
echo "── el orden del tope es JUSTO: menos intentos primero"
# Con el glob alfabetico, cuando el tope muerde los slots se los llevan siempre
# las mismas tareas y la cola de atras no avanza nunca.
tres_varadas AAA ZZZ
mkdir -p "$WS/.harness/orch-watch"
printf '{"task":"AAA","attempts":1,"fingerprint":"x","at":"2026-08-14T00:00:00Z"}\n' \
  > "$WS/.harness/orch-watch/AAA.json"
out="$(corre_tope HARNESS_ORCH_MAX_PER_PASS=1)"; sleep 0.6
assert_contains "$(cat "$WS/relanzamientos.txt")" "/smart ZZZ" \
  "gana la que menos intentos lleva, aunque el glob la ponga ultima"
assert_not_contains "$(cat "$WS/relanzamientos.txt")" "/smart AAA" "y la otra espera su turno"

echo
echo "── un PID no es una identidad: los PIDs se reciclan tras un reinicio"
# lease_taken decidia con kill -0, o sea "hay UN proceso con ese numero". Tras un
# reinicio los PIDs se reasignan y un lease viejo puede apuntar a un proceso
# ajeno del mismo usuario: la tarea queda con dueno para siempre. En la maquina
# del incidente sobrevivieron 346 claims al reinicio.
tres_varadas SIETE
sleep 30 & ajeno=$!
mkdir -p "$WS/.harness/claims/orch-SIETE.lock.d"
echo "$ajeno" > "$WS/.harness/claims/orch-SIETE.lock.d/pid"
printf 'arranque-de-otra-era\n' > "$WS/.harness/claims/orch-SIETE.lock.d/pidid"
printf '%s\n' "$(( $(date -u +%s) - 99999 ))" > "$WS/.harness/claims/orch-SIETE.lock.d/at"
out="$(corre_tope)"; sleep 0.6
assert_eq 1 "$(espera_relanzos 1)" "el PID reciclado ya no reclama la tarea de otro"
kill "$ajeno" 2>/dev/null; wait 2>/dev/null

echo
echo "── el relevo no nace amordazado: las concesiones VIAJAN en la linea"
# Una sesion headless no tiene a quien pedirle aprobacion: lo que no este
# concedido queda denegado en silencio. Y el allow del settings de PROYECTO lo
# descarta el CLI mientras el workspace no este confiado, asi que confiar en el
# archivo no alcanza: las reglas tienen que ir por bandera.
rm -f "$WS/relanzamientos.txt" "$WS/.harness/events.jsonl"
rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch" "$WS/tasks"
mkdir -p "$WS/.claude"
cat > "$WS/.claude/settings.json" <<'JSON'
{"permissions":{"defaultMode":"acceptEdits",
 "allow":["Bash(bash scripts/*)","Bash(python3 scripts/*)"],
 "deny":["Bash(terraform destroy:*)"]}}
JSON
nueva_tarea MORDAZA implement 1300
evento MORDAZA tool 1300
out="$(corre once)"; espera_relanzos 1 >/dev/null
linea="$(cat "$WS/relanzamientos.txt")"
assert_contains "$linea" "--allowedTools" "el relanzamiento concede algo"
assert_contains "$linea" "Bash(bash scripts/*)" "y son las reglas del settings de la instancia, no una lista propia"
assert_contains "$linea" "Bash(python3 scripts/*)" "las dos, no la primera"
assert_not_contains "$linea" "dangerously-skip-permissions" \
  "sin tirar el deny entero por la ventana: --allowedTools concede, no revoca"
# El prompt sobrevive: --allowedTools es variadica y se come todo lo que venga
# detras, asi que el orden importa y este test es quien lo sostiene.
case "$linea" in
  "-p /smart MORDAZA --allowedTools"*) pass "el prompt va ANTES de la bandera variadica (si no, el CLI se queda sin prompt)" ;;
  *) fail "orden equivocado en la linea de relanzamiento: '$linea'" ;;
esac

echo
echo "── un settings sin allow no rompe el relanzamiento (solo no concede)"
rm -f "$WS/relanzamientos.txt" "$WS/.harness/events.jsonl"
rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch" "$WS/tasks"
echo '{"permissions":{"deny":[]}}' > "$WS/.claude/settings.json"
nueva_tarea SINALLOW implement 1300
evento SINALLOW tool 1300
out="$(corre once)"
assert_eq 1 "$(espera_relanzos 1)" "relanza igual"
assert_contains "$(cat "$WS/relanzamientos.txt")" "/smart SINALLOW" "con su prompt entero"
assert_not_contains "$(cat "$WS/relanzamientos.txt")" "--allowedTools" \
  "y sin una bandera vacia, que el CLI leeria como el prompt"
rm -rf "$WS/.claude"

echo
echo "── sin CLI de claude no se inventa un relanzamiento"
rm -rf "$WS/.harness/claims" "$WS/.harness/orch-watch"
nopath="$(t_path_without claude)"
out="$(cd "$WS" && PATH="$nopath" HARNESS_ORCH_IDLE=0 bash scripts/orchestrator-watch.sh once 2>&1)"
assert_contains "$out" "no encuentro el CLI" "lo dice en vez de reportar una pasada limpia"
assert_no_file "$WS/.harness/orch-watch/QUIETA.json" "y no cuenta como intento"

t_done

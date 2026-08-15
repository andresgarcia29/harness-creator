#!/usr/bin/env bash
# test_guard_gcloud.sh: el hook bloquea `gcloud`/`gsutil` EN POSICIÓN DE
# COMANDO, y SOLO en instancias que tienen el wrapper `scripts/gcloud.sh`.
# Caso de campo (#207): la sesión humana caduca, gcloud imprime "run gcloud auth
# login" y el agente OBEDECE (frena la tarea y pide un humano), teniendo el
# wrapper keyless al lado. Sin wrapper no hay remediación, así que el hook calla.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

HOOK="$ROOT/templates/hooks/guard-gcloud.sh"

# Dos instancias: una CON wrapper, otra sin él.
mkdir -p "$WS/inst/scripts" "$WS/sin"
printf '#!/bin/sh\nexit 0\n' > "$WS/inst/scripts/gcloud.sh"
chmod +x "$WS/inst/scripts/gcloud.sh"

run_hook() {  # run_hook <dir-instancia> <comando> → rc (2 = bloquea, 0 = pasa)
  jq -nc --arg c "$2" '{tool_input:{command:$c}}' \
    | CLAUDE_PROJECT_DIR="$1" bash "$HOOK" >/dev/null 2>&1
}

echo "── con el wrapper presente, el binario pelado se bloquea"

run_hook "$WS/inst" 'gcloud projects list --limit=1'; assert_eq 2 $? "gcloud pelado: bloquea"
run_hook "$WS/inst" 'gsutil ls gs://bucket'; assert_eq 2 $? "gsutil pelado: bloquea"
run_hook "$WS/inst" 'sudo gcloud auth login'; assert_eq 2 $? "sudo gcloud: bloquea"
run_hook "$WS/inst" 'FOO=1 gcloud compute instances list'; assert_eq 2 $? \
  "con asignación de entorno delante: bloquea"
run_hook "$WS/inst" 'cd infra && gcloud storage ls'; assert_eq 2 $? \
  "tras &&: sigue siendo posición de comando"
out="$(jq -nc --arg c 'gcloud projects list' '{tool_input:{command:$c}}' \
  | CLAUDE_PROJECT_DIR="$WS/inst" bash "$HOOK" 2>&1 >/dev/null)" || true
assert_contains "$out" "scripts/gcloud.sh" "el mensaje da la remediación exacta (el wrapper)"
assert_contains "$out" "Reauthentication failed" \
  "y desarma la orden del CLI: reautenticar NO es la salida"
assert_contains "$out" "HARNESS_GCLOUD_HUMANO=1" "y nombra el escape para lo que audita a una persona"

echo "── texto que MENCIONA gcloud no es un comando gcloud"

run_hook "$WS/inst" 'git commit -m "arreglé gcloud.sh"'; assert_eq 0 $? \
  "mensaje de commit inline que menciona gcloud: PASA"
cmd="$(printf "git commit -F- <<'EOF'\nfix: el gcloud auth del CI\n\ny documenta gsutil cp\nEOF")"
run_hook "$WS/inst" "$cmd"; assert_eq 0 $? "heredoc que menciona gcloud/gsutil: PASA"
run_hook "$WS/inst" "echo 'prueba: gcloud projects list'"; assert_eq 0 $? "echo entrecomillado: PASA"
run_hook "$WS/inst" 'grep -rn gcloud docs/'; assert_eq 0 $? "gcloud como ARGUMENTO de grep: PASA"
run_hook "$WS/inst" 'git commit -m "chore: ya no hace falta; gcloud auth login era el workaround"'
assert_eq 0 $? "texto entrecomillado con un ';' adentro: PASA (el ';' no crea posición de comando)"

echo "── el cuerpo del heredoc no esconde un comando REAL de después"

cmd="$(printf "cat <<'EOF' > nota.md\ngcloud no corre acá\nEOF\ngcloud projects list")"
run_hook "$WS/inst" "$cmd"; assert_eq 2 $? "gcloud DESPUÉS del heredoc: sigue bloqueado"

echo "── bypass legítimo, escape humano, auto-apagado y fail-open"

run_hook "$WS/inst" 'scripts/gcloud.sh projects list'; assert_eq 0 $? "ya usa el wrapper: PASA"
run_hook "$WS/inst" 'CLOUDSDK_AUTH_ACCESS_TOKEN=$(scripts/gcp-token.sh) gcloud projects list'
assert_eq 0 $? "gcloud alimentado por el token keyless del propio harness: PASA"
run_hook "$WS/inst" 'HARNESS_GCLOUD_HUMANO=1 gcloud organizations add-iam-policy-binding 123 --member=x'
assert_eq 0 $? "escape para lo que debe quedar atribuido a una persona: PASA"
run_hook "$WS/sin" 'gcloud projects list'; assert_eq 0 $? \
  "instancia SIN wrapper: el hook es inerte (auto-apagado)"
printf '{"tool_input":{"command":"gcloud projects list"}}' \
  | CLAUDE_PROJECT_DIR="$WS/inst" PATH="$(t_path_without jq)" bash "$HOOK" >/dev/null 2>&1
assert_eq 0 $? "sin jq: fail-open (no bloquea nada)"
printf '' | CLAUDE_PROJECT_DIR="$WS/inst" bash "$HOOK" >/dev/null 2>&1
assert_eq 0 $? "sin payload: fail-open"

echo "── el hook está registrado en settings.json.tmpl (si no, no corre nunca)"

grep -q 'guard-gcloud.sh' "$ROOT/templates/settings.json.tmpl" \
  && pass "guard-gcloud.sh registrado en el bloque PreToolUse/Bash" \
  || fail "el hook existe pero settings.json.tmpl no lo invoca: es letra muerta"

echo "── mutación: cada cable corta de verdad"

# 1) Sin el gate de wrapper, la instancia SIN wrapper quedaría bloqueada.
mut="$WS/mut-gate.sh"
grep -v 'scripts/gcloud.sh" \] || exit 0' "$HOOK" > "$mut"
jq -nc --arg c 'gcloud projects list' '{tool_input:{command:$c}}' \
  | CLAUDE_PROJECT_DIR="$WS/sin" bash "$mut" >/dev/null 2>&1
assert_eq 2 $? "mutar el auto-apagado cambia la conducta: la aserción muerde"

# 2) Sin sanitizador, un mensaje de commit con un ';' adentro vuelve a bloquearse:
#    la regresión de campo que ya sufrió guard-build-slot.sh.
mut="$WS/mut-sane.sh"
awk '/^sanitized=/{print "sanitized=\"$cmd\""; skip=1; next}
     skip && /^'"'"' 2>/{skip=0; next}
     skip{next} {print}' "$HOOK" > "$mut"
jq -nc --arg c 'git commit -m "chore: ya no hace falta; gcloud auth login era el workaround"' \
  '{tool_input:{command:$c}}' | CLAUDE_PROJECT_DIR="$WS/inst" bash "$mut" >/dev/null 2>&1
assert_eq 2 $? "mutar el sanitizador cambia la conducta: la aserción del commit muerde"

# 3) Sin el bypass, `VAR=$(scripts/gcp-token.sh) gcloud …` cae en la regla de
#    asignaciones de entorno y el camino keyless queda bloqueado por su propio guard.
mut="$WS/mut-bypass.sh"
grep -v '^  \*scripts/gcloud.sh\*' "$HOOK" > "$mut"
jq -nc --arg c 'CLOUDSDK_AUTH_ACCESS_TOKEN=$(scripts/gcp-token.sh) gcloud projects list' \
  '{tool_input:{command:$c}}' | CLAUDE_PROJECT_DIR="$WS/inst" bash "$mut" >/dev/null 2>&1
assert_eq 2 $? "mutar el bypass cambia la conducta: la aserción del camino keyless muerde"

t_done

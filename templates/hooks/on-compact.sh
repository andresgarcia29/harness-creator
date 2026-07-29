#!/usr/bin/env bash
# on-compact.sh — PreCompact: la señal de contexto agotado que no existía.
#
# POR QUÉ EXISTE: record-cost mide dólares y nada medía contexto. Caso de
# campo: en un /smart de nueve horas el humano tuvo que avisar A MANO varias
# veces "te estás quedando sin ventana". La compactación es el único evento
# determinista que dice "esta sesión está por resumirse": este hook lo vuelve
# observable, para el panel (bus) y para la propia sesión (marca en disco que
# /smart lee al retomar).
#
# QUÉ HACE: deriva la tarea del puntero por sesión que mantiene track-read.sh
# (.harness/session-task/<sid>, jamás estado global) y deja
# tasks/<id>/.compacted (append: timestamp + trigger) + un evento en el bus.
#
# Fail-open SIEMPRE, como todo observador (track-read, ui-emit): una señal de
# telemetría no puede impedir una compactación ni tumbar una sesión.
set -u

exit_ok() { exit 0; }
trap exit_ok EXIT
command -v jq >/dev/null 2>&1 || exit 0

WS="${CLAUDE_PROJECT_DIR:-$PWD}"

payload="$(cat 2>/dev/null)"; [ -n "$payload" ] || exit 0
sid="$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)"
trigger="$(printf '%s' "$payload" | jq -r '.trigger // "auto"' 2>/dev/null)"

case "$sid" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
task="$(head -1 "$WS/.harness/session-task/$sid" 2>/dev/null)"
[ -n "$task" ] || exit 0
case "$task" in *[!A-Za-z0-9._-]*) exit 0 ;; esac

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$WS/tasks/$task" 2>/dev/null || exit 0
printf '%s\t%s\t%s\n' "$ts" "$trigger" "$sid" >> "$WS/tasks/$task/.compacted" 2>/dev/null

if [ -f "$WS/scripts/emit.sh" ]; then
  bash "$WS/scripts/emit.sh" assumption \
    "contexto de la sesión ${sid:0:8} compactado ($trigger) durante $task: el detalle fino previo ya no está en la ventana" \
    "" "$task" >/dev/null 2>&1 || true
fi
exit 0

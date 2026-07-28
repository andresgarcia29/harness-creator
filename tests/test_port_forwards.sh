#!/usr/bin/env bash
# test_port_forwards.sh: túneles supervisados con sondas de IDENTIDAD.
# Los dos casos de campo: (1) un port-forward viejo de otra cosa tomó el
# puerto y "responde" se leyó como "sano" (tres specs rojas casi diagnosticadas
# como regresión); (2) el forward se caía y nadie lo relevantaba (18 minutos
# perdidos y un supervisor improvisado). El stub responde GZIP para probar
# que la sonda usa --compressed de verdad (sin él, grep calla).
set -u
. "$(dirname "$0")/lib.sh"
t_ws

command -v curl >/dev/null 2>&1 || { echo "── port-forwards: saltado (sin curl)"; exit 0; }

mkdir -p "$WS/scripts" "$WS/.harness"
cp "$ROOT/templates/scripts/port-forwards.sh" "$WS/scripts/"

cat > "$WS/stub.py" <<'PY'
# stub.py <port> <status> <body> [gzip]
from http.server import BaseHTTPRequestHandler, HTTPServer
import sys, gzip
port, status, body = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3].encode()
gz = len(sys.argv) > 4
class H(BaseHTTPRequestHandler):
    def _serve(self):
        data = gzip.compress(body) if gz else body
        self.send_response(status)
        if gz: self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    do_GET = _serve
    do_POST = _serve
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"

mk_answers() {  # mk_answers <status-del-stub> [expect-status]
  cat > "$WS/harness-answers.yaml" <<EOF
project: demo
port_forwards:
  atlas:
    port: $PORT
    cmd: "python3 $WS/stub.py $PORT $1 'unauthorized: invalid or missing X-E2E-Secret' gzip"
    probe_method: POST
    probe_path: /test/tenancy/create
    probe_expect_status: ${2:-401}
    probe_expect_body: "X-E2E-Secret"
EOF
}
run_pf() { ( cd "$WS" && bash scripts/port-forwards.sh "$@" 2>&1 ); }

echo "── up: identidad verificada (401 esperado ES identidad válida, y el body va gzip)"

mk_answers 401
out="$(run_pf up)"; rc=$?
assert_eq 0 "$rc" "up con identidad correcta: exit 0"
assert_contains "$out" "identidad verificada" "la sonda pregunta '¿ES este servicio?', no '¿responde?'"
assert_file "$WS/.harness/port-forwards/atlas.pid" "deja pidfile"
pid="$(cat "$WS/.harness/port-forwards/atlas.pid")"
kill -0 "$pid" 2>/dev/null && pass "el proceso vive" || fail "el proceso no vive"
# el body llegó GZIP y el grep del expect_body lo encontró: --compressed probado

echo "── supervisión: ensure relevanta al muerto"

kill -9 "$pid" 2>/dev/null || true
sleep 1
out="$(run_pf ensure)"; rc=$?
assert_eq 0 "$rc" "ensure tras kill -9: exit 0"
new_pid="$(cat "$WS/.harness/port-forwards/atlas.pid")"
[ "$new_pid" != "$pid" ] && kill -0 "$new_pid" 2>/dev/null \
  && pass "relanzado con pid nuevo y vivo" || fail "no relevantó al muerto"

echo "── IMPOSTOR: responde, pero no es lo que declaraste"

run_pf down >/dev/null 2>&1
mk_answers 200 401   # el stub contesta 200 donde se espera 401: otro proceso
out="$(run_pf up)"; rc=$?
[ "$rc" -ne 0 ] && pass "status inesperado: exit != 0" || fail "el impostor pasó"
assert_contains "$out" "OTRO proceso en el" "lo dice con esas palabras"
assert_contains "$out" "port-forward viejo" "y nombra el caso típico"
assert_contains "$out" "lsof" "con la remediación para encontrarlo"

echo "── down y esquema"

run_pf down >/dev/null 2>&1
assert_no_file "$WS/.harness/port-forwards/atlas.pid" "down borra el pidfile"

cat > "$WS/harness-answers.yaml" <<EOF
project: demo
port_forwards:
  a:
    port: 9090
    cmd: "sleep 1"
    probe_expect_status: 200
  b:
    port: 9090
    cmd: "sleep 1"
    probe_expect_status: 200
EOF
out="$(run_pf doctor)"; rc=$?
assert_eq 1 "$rc" "puertos duplicados: doctor exit 1"
assert_contains "$out" "DUPLICADOS" "nombra el problema"
out="$(run_pf up)"; rc=$?
assert_eq 1 "$rc" "up con duplicados: se niega"

cat > "$WS/harness-answers.yaml" <<EOF
project: demo
port_forwards:
  sinstatus:
    port: 9091
    cmd: "sleep 1"
EOF
out="$(run_pf doctor)"; rc=$?
assert_eq 1 "$rc" "sin probe_expect_status: doctor exit 1"
assert_contains "$out" "probe_expect_status" "nombra la clave que falta"

printf 'project: demo\n' > "$WS/harness-answers.yaml"
out="$(run_pf status)"; rc=$?
assert_eq 0 "$rc" "sin bloque declarado: exit 0 con aviso"
assert_contains "$out" "sin port_forwards" "y lo dice"

# limpieza de procesos del stub que pudieran quedar
pkill -f "stub.py $PORT" 2>/dev/null || true

t_done

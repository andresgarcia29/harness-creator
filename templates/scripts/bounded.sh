#!/usr/bin/env bash
# bounded.sh: acotar una llamada externa DE VERDAD.
#
#   source scripts/bounded.sh        → te da la función `run_bounded`
#   run_bounded <segundos> <gracia> <comando...>
#
# POR QUÉ EXISTE: el harness ya tenía un acotador, y no acotaba.
#
#   perl -e 'alarm shift @ARGV; exec @ARGV; die' "$@"
#
# Ese idiom vivía en ship.sh (con_limite) y en deploy-watch (la etapa verify).
# Es correcto en lo que promete a medias: `alarm()` sobrevive al `exec()` (POSIX
# lo lista entre los atributos que la nueva imagen HEREDA) y el handler vuelve a
# default, así que el proceso muere con SIGALRM y sale 142. Eso funciona.
#
# Lo que NO funciona son los dos casos que importan, ambos MEDIDOS:
#
#   1. MATA UN PROCESO, NO EL ÁRBOL. Un comando que deja un hijo heredando
#      stdout (o sea: cualquier script que lance curl, kubectl o un runner de
#      node) muere él solo; el nieto huérfano sigue sosteniendo el pipe y el
#      `$( )` que lo captura sigue bloqueado. Medido con la forma exacta de
#      deploy-watch: timeout de 2s → rc=142 y VEINTE SEGUNDOS de reloj. El
#      acotador reportó que acotó, y no acotó nada.
#
#   2. SIGALRM ES UNA SEÑAL QUE LA GENTE ATRAPA. Muchos programas la usan para
#      sus propios timers. Un hijo con `trap '' ALRM` ignora el timeout entero
#      y el wrapper devuelve **0**. Medido: 9s de reloj con timeout de 2s, y
#      rc=0. Un cuelgue que pasa por verde es peor que el cuelgue.
#
#   3. No hay escalada: nada manda SIGKILL al que ignora la primera señal.
#
# `timeout(1)` de GNU sí lo hace bien, y así es como: `setpgid(0,0)` mete al
# hijo en su propio grupo de procesos y después `kill(0, sig)` señala al GRUPO
# ENTERO. Pero `timeout` no viene en macOS (llegó a FreeBSD 10.3; Darwin no
# heredó ese userland) y `gtimeout` solo existe si alguien instaló coreutils.
# Así que: se usa el binario real si está, y si no se replica en perl,
# incluyendo el grupo de procesos y el kill-after, que es lo que faltaba.
#
# OJO con `timeout --foreground`: desactiva exactamente esta protección ("in
# this mode, children of COMMAND will not be timed out"). No lo pongas.
#
# CONTRATO DE SALIDA: **124** cuando se agota, como `timeout(1)`, en los dos
# caminos. No 142. Que el fallback y el binario nativo no coincidan en el código
# de salida es un bug esperando a que alguien compare contra el número
# equivocado en la máquina donde no probó.

set -u

# El binario se resuelve UNA vez, al sourcear. `command -v` por llamada, en un
# loop de polling, es syscalls gratis por nada.
HARNESS_TIMEOUT_BIN=""
for _hb in timeout gtimeout; do
  if command -v "$_hb" >/dev/null 2>&1; then HARNESS_TIMEOUT_BIN="$_hb"; break; fi
done
unset _hb

run_bounded() {  # run_bounded <segundos> <gracia> <comando...> → 124 si se agotó
  local secs="$1" gracia="$2"
  shift 2
  if [ -n "$HARNESS_TIMEOUT_BIN" ]; then
    "$HARNESS_TIMEOUT_BIN" -k "${gracia}s" "${secs}s" "$@"
    return $?
  fi
  # shellcheck disable=SC2016  # comillas simples a propósito: las $ son de perl
  perl -e '
use strict; use warnings;
use Errno qw(EINTR);
use POSIX ();

my $secs   = shift @ARGV;
my $gracia = shift @ARGV;

my $pid = fork();
die "run_bounded: fork: $!\n" unless defined $pid;

if ($pid == 0) {
    # EL HIJO LIDERA SU PROPIO GRUPO. Esta línea es la que separa "acotado" de
    # "no acotado": sin ella, kill(-$pid) no tiene a quién señalar y los nietos
    # sobreviven al timeout sosteniendo el pipe.
    POSIX::setpgid(0, 0);
    # Forma de BLOQUE, no `exec @ARGV` pelado. Con un solo elemento perl le
    # busca metacaracteres de shell y, si los hay, lanza /bin/sh: la señal
    # mataría al shell y dejaría el trabajo real huérfano. El bloque fuerza
    # la interpretación de lista y nunca pasa por un shell.
    # (mismo idiom que build-slot.sh usa para su exec bajo flock)
    exec { $ARGV[0] } @ARGV
        or do { print STDERR "run_bounded: exec $ARGV[0]: $!\n"; POSIX::_exit(127) };
}

# También del lado del padre, y con el error ignorado a propósito: es la carrera
# clásica. Si el padre alcanza a mandar la señal antes de que el hijo corra su
# setpgid, kill(-$pid) falla con ESRCH y no mata nada. Si el hijo ya hizo exec,
# este setpgid falla con EACCES y da igual: el hijo ya lo hizo por su cuenta.
POSIX::setpgid($pid, $pid);

my $vencido = 0;
$SIG{ALRM} = sub {
    if (!$vencido) {
        $vencido = 1;
        kill("TERM", -$pid);   # el PID NEGATIVO es el grupo entero
        alarm $gracia;         # el equivalente de `timeout --kill-after`
    } else {
        kill("KILL", -$pid);   # el que ignora TERM igual se muere
    }
};
alarm $secs;

# waitpid vuelve -1/EINTR cuando corre el handler: perl no reintenta solo, y sin
# este loop el wrapper se rinde en el primer TERM y reporta basura en vez del
# estado real del hijo.
my $st = 0;
while (1) {
    my $r = waitpid($pid, 0);
    if ($r == $pid)                 { $st = $?; last; }
    next if $r == -1 && $! == EINTR;
    last;
}
alarm 0;

exit 124 if $vencido;
exit(($st & 127) ? 128 + ($st & 127) : $st >> 8);
' "$secs" "$gracia" "$@"
}

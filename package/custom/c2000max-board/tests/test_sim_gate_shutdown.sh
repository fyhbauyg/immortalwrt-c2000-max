#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/../qmodem/application/qmodem/files/usr/share/qmodem/c2000max_sim_gate.sh"
STATE="$(mktemp -d)"
trap 'rm -f -- "$STATE/marker" "$STATE/status"; rmdir -- "$STATE"' EXIT
printf 'ready\n' > "$STATE/status"
MARKER="$STATE/marker"
sleeps=0
MODE=absent
qmodem_sim_boot_log() { :; }
qmodem_sim_boot_worker_active() {
    case "$MODE" in
        active) return 0 ;;
        ends_during_shutdown) : > "$MARKER"; return 1 ;;
        *) return 1 ;;
    esac
}
sleep() { sleeps=$((sleeps + 1)); : > "$MARKER"; }
check() {
    expected="$1"
    actual=0
    qmodem_sim_boot_wait "$STATE/no-pid" "$STATE/status" "$STATE" 3 "$MARKER" || actual=$?
    [ "$actual" = "$expected" ] || {
        printf 'FAIL mode=%s expected=%s actual=%s\n' "$MODE" "$expected" "$actual" >&2
        exit 1
    }
}
check 0
: > "$MARKER"
check 75
[ "$sleeps" = 0 ]
rm -f -- "$MARKER"
MODE=active
check 75
[ "$sleeps" = 1 ]
rm -f -- "$MARKER"
MODE=ends_during_shutdown
check 75
rm -f -- "$MARKER"
MODE=absent
check 0
printf 'PASS: shutdown before gate, during wait, at worker exit, and normal boot release\n'

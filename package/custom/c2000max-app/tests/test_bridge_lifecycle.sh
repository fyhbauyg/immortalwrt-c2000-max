#!/bin/bash
# Local-only process lifecycle regression: no UCI, network or real mosquitto.
set -eu

pkg_dir=$(cd "$(dirname "$0")/.." && pwd)
source_bridge="$pkg_dir/files/usr/sbin/c2000max-app-bridge"
source_init="$pkg_dir/files/etc/init.d/c2000max-app"
test_dir=$(mktemp -d /tmp/c2000max-bridge-test.XXXXXX)
wrapper_pid=
sibling_pid=

cleanup() {
    if [ -n "$wrapper_pid" ]; then
        kill -TERM "$wrapper_pid" 2>/dev/null || :
        wait "$wrapper_pid" 2>/dev/null || :
    fi
    if [ -n "$sibling_pid" ]; then
        kill -TERM "$sibling_pid" 2>/dev/null || :
        wait "$sibling_pid" 2>/dev/null || :
    fi
    case "$test_dir" in
        /tmp/c2000max-bridge-test.*) rm -rf -- "$test_dir" ;;
    esac
}
trap cleanup EXIT

# Exercise the production supervision block, changing only the executable to
# a local mock.  Runtime length is shortened for the 24-hour refresh case.
cat > "$test_dir/wrapper" <<'EOF'
#!/bin/sh
CONF="$FIXTURE_DIR/mock.conf"
bridge_state() { printf 'bridge:%s\n' "$1" >> "$FIXTURE_DIR/states"; }
bridge_session_state() { printf 'session:%s\n' "$1" >> "$FIXTURE_DIR/states"; }
EOF
sed -n '/^# BEGIN BRIDGE SUPERVISION$/,/^# END BRIDGE SUPERVISION$/p' "$source_bridge" |
    sed 's@/usr/sbin/mosquitto@"$FIXTURE_DIR/broker"@' >> "$test_dir/wrapper"

# The mock execs a real process so timeout owns exactly one broker PID.
cat > "$test_dir/broker" <<'EOF'
#!/bin/sh
printf '%s\n' "$$" > "$FIXTURE_DIR/broker.pid"
printf '%s\n' "$PPID" > "$FIXTURE_DIR/timeout.pid"
case "$FIXTURE_MODE" in
    natural) exit 7 ;;
    stubborn) trap '' TERM ;;
esac
exec sleep 300
EOF
chmod +x "$test_dir/broker"
touch "$test_dir/mock.conf"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_gone() {
    # A killed grandchild may briefly be an init-owned zombie in a container;
    # it cannot retain a listener.  A live/running process is always a failure.
    if [ -r "/proc/$1/stat" ]; then
        local proc_stat
        proc_stat=$(cat "/proc/$1/stat")
        proc_stat=${proc_stat##*) }
        [ "${proc_stat%% *}" = Z ] || fail "process $1 remains alive"
    fi
}
assert_sibling() { kill -0 "$sibling_pid" || fail 'unrelated broker was stopped'; }
start_case() {
    local mode=$1 interval=$2
    rm -f -- "$test_dir/broker.pid" "$test_dir/timeout.pid" "$test_dir/states"
    FIXTURE_DIR="$test_dir" FIXTURE_MODE="$mode" SESSION_RESTART_INTERVAL="$interval" \
        /bin/sh "$test_dir/wrapper" &
    wrapper_pid=$!
    for attempt in $(seq 1 100); do
        [ -s "$test_dir/broker.pid" ] && [ -s "$test_dir/timeout.pid" ] && break
        sleep 0.02
    done
    [ -s "$test_dir/broker.pid" ] || fail 'mock broker did not start'
    broker_pid=$(cat "$test_dir/broker.pid")
    timeout_pid=$(cat "$test_dir/timeout.pid")
}
finish_case() {
    local expected=$1 rc=0
    wait "$wrapper_pid" || rc=$?
    wrapper_pid=
    [ "$rc" -eq "$expected" ] || fail "exit $rc, expected $expected"
    assert_gone "$timeout_pid"
    assert_gone "$broker_pid"
    assert_sibling
}

# Represents another broker owned by someone else (e.g. standard port 1883).
sleep 300 &
sibling_pid=$!

start_case cooperative 86400
kill -TERM "$wrapper_pid"
finish_case 0
grep -q '^session:stopped$' "$test_dir/states" || fail 'TERM state missing'
printf 'PASS: TERM reaps only own timeout and broker\n'

start_case natural 86400
finish_case 7
grep -q '^session:stopped$' "$test_dir/states" || fail 'natural exit state missing'
printf 'PASS: natural broker exit status preserved\n'

start_case cooperative 1
finish_case 1
grep -q '^session:reconnecting$' "$test_dir/states" || fail 'scheduled reconnect missing'
printf 'PASS: shortened 24-hour timeout requests procd reconnect\n'

start_case stubborn 86400
started=$SECONDS
kill -TERM "$wrapper_pid"
finish_case 0
elapsed=$((SECONDS - started))
[ "$elapsed" -ge 14 ] && [ "$elapsed" -le 19 ] || fail "kill deadline was $elapsed seconds"
printf 'PASS: TERM-ignoring broker is killed after 15 seconds\n'

awk '/procd_open_instance bridge/{bridge=1} bridge && /procd_set_param term_timeout 20/{ok=1} bridge && /procd_close_instance/{exit !ok}' "$source_init" ||
    fail 'bridge term_timeout must leave 20 seconds for bounded cleanup'
printf 'PASS: bridge procd grace period permits cleanup\n'

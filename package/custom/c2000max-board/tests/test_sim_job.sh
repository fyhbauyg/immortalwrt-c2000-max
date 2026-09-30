#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/files/usr/sbin/c2000max-sim-job"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export C2000MAX_SIM_JOB_ROOT="$tmp/jobs" C2000MAX_SIM_JOB_CLI="$tmp/fake-cli"
cat > "$tmp/fake-cli" <<'EOF'
#!/bin/sh
sleep 1
printf '{"success":true,"message":"test card changed","iccid":"8986000000000000001"}\n'
EOF
chmod +x "$tmp/fake-cli"
initial=$(sh "$HELPER" start force external1)
id=$(printf '%s' "$initial" | jq -r .job_id)
printf '%s' "$initial" | jq -e '.success == true and .done == false' >/dev/null
if sh "$HELPER" start force external2 > "$tmp/busy"; then echo 'FAIL: accepted concurrent job'; exit 1; fi
jq -e '.success == false and .done == true' "$tmp/busy" >/dev/null
state=$(sh "$HELPER" status "$id")
printf '%s' "$state" | jq -e '.done == false' >/dev/null
for i in $(seq 1 30); do
	state=$(sh "$HELPER" status "$id")
	if printf '%s' "$state" | jq -e '.done == true' >/dev/null; then break; fi
	sleep .1
done
printf '%s' "$state" | jq -e '.done == true and .result.success == true and .result.message == "test card changed"' >/dev/null
if sh "$HELPER" status '../../etc/passwd' > "$tmp/bad-id"; then echo 'FAIL: accepted traversal'; exit 1; fi
cat > "$tmp/fake-cli" <<'EOF'
#!/bin/sh
echo invalid-json
exit 1
EOF
initial=$(sh "$HELPER" start switch internal)
id=$(printf '%s' "$initial" | jq -r .job_id)
for i in $(seq 1 30); do
	state=$(sh "$HELPER" status "$id")
	if printf '%s' "$state" | jq -e '.done == true' >/dev/null; then break; fi
	sleep .1
done
printf '%s' "$state" | jq -e '.done == true and .result.success == false' >/dev/null
echo 'PASS: asynchronous SIM result, operation exclusion, invalid ID and failed worker handling'

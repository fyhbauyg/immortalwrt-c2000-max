# C2000MAX vendor TTLM regression tests

These tests extract production functions or precisely delimited caller blocks
from a prepared `mt_wifi` tree. They do not maintain a second implementation
of the production parser. Hardware lookups and logging are stubbed.

Prerequisites: Bash, awk, GCC with ASan/UBSan, and the matching Linux header
containing `ieee80211_tid_to_link_map_size_ok()`. The Linux helper is a size
oracle only, not proof of advertised/negotiated TTLM policy compliance.

Run from the repository root after normal package preparation:

```sh
driver="$PWD/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic/mt_wifi7/mt_wifi"
header="$PWD/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic/linux-6.12.94/include/linux/ieee80211.h"
TTLM_TEST_OUT="$(mktemp -d -t ttlm-parser.XXXXXXXX)" \
  bash scripts/c2000max/ttlm/run.sh "$driver" all "$header"
bash scripts/c2000max/ttlm/run-sta-tests.sh "$driver"
```

Repeat with `mt_hwifi/mt_wifi` to verify the second independently prepared
source tree. The runner's `base` and `work` aliases are for the original local
staging layout only; use an explicit source path from this repository.

Coverage:

- Default mapping, all 256 presence masks, 1/2-byte maps, MST/ED, direction
  values, reserved bits, declared-field truncations, explicit zero maps.
- Failed parse output atomicity, successive successful parses, timestamp
  preservation, explicit generator roundtrip and selective mappings.
- Current-extension dispatch instead of sticky presence flags; the actual IE
  loop guard with zero/one remaining header bytes.
- Deterministic mixed-input fuzzing (25,000 inputs).
- STA preamble order: invalid nonempty cache cannot disconnect the old peer;
  empty fixed cache and NULL remain optional; fixed-cache bounds are enforced.

Limits:

- The pointer parser API requires a caller-bounded complete IE. It cannot
  discover the allocation size of an arbitrary pointer. Tests separately
  exercise declared length and the extracted caller header guard.
- The beacon parser and STA connection state machine are not executed in
  full. The STA test stubs the parser, whose byte parsing has separate tests.
- Firmware commands, actual radio behavior, TTLM negotiation, OPEN/EHT client
  compatibility, throughput, and long-term MLO stability are not validated.
- The generator keeps its original explicit-map policy, including lifecycle
  handling of an invalid zero map; this patch does not invent new fallback
  or omitted-IE behavior for that condition.

The original pre-021 source is expected to fail the compatibility matrix and
trigger ASan on the extracted header-boundary guard. Only run such negative
baseline cases intentionally (`nonnull`, `boundary`, `null`).

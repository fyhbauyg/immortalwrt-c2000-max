# Wi-Fi stability regressions (2026-09-12)

Run from the OpenWrt repository after preparing/building `warp`, `mt_wifi7`
and `mt_hwifi` with patches 010 and 023–025. Requires host GCC/cc and Python 3.
These tests execute extracted driver function bodies with fake hardware/API
boundaries. They do not run the router, perform real DMA, certify MCU ABI, or
measure throughput.

```sh
bash scripts/c2000max/wifi-stability-tests/rcu/test_ba_rcu.sh "$PWD"
python3 scripts/c2000max/wifi-stability-tests/bandwidth/run-regression.py \
  --source-tree build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic/mt_wifi7
python3 scripts/c2000max/wifi-stability-tests/bandwidth/run-regression.py \
  --source-tree build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic/mt_hwifi
bash scripts/c2000max/wifi-stability-tests/run-prepared-wed.sh "$PWD"
python3 scripts/c2000max/test_warp_wdma_lifecycle.py \
  --source build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic/warp
```

- RCU: recreates pre/post-patch variants in a new temporary directory; checks
  normal, absent, repeated and MLO cleanup with EHT enabled/disabled. Baseline
  underflow is expected, fixed variants must pass. Production source is read-only.
- Bandwidth: complete HT/VHT/HE/EHT width tuple, legal no-op, BE preservation,
  synchronous errors, ownership and asynchronous CSA acceptance. MCU failures
  hidden by lower-level void APIs remain outside the test's guarantee.
- WED/WARP: initialization ordering, failed allocation/mapping, per-buffer
  ownership, HIF cleanup and register/remove reference pairing. Successful RX
  token ownership stays with HWIFI. BM and HIF tests use ASan/UBSan.
- Existing WDMA lifecycle tests check the earlier callback/probe guards too.

`collect-wifi-readonly.sh` is an optional on-router, board-guarded snapshot.
It changes no settings, starts no load and enables no debug flags. It requires
`timeout`; the controlling SSH call should have an outer time limit as well.
Keep output private: station MAC/IP addresses remain even though password,
SIM/account and token configuration fields are not collected. Compare snapshots
alongside a controlled external iperf3 test before attributing upload regression.

RCU/WED and the original bandwidth callback defects also exist in the June
stack. Fixing them is not proof of the cause of the 36-to-37 regression.
The current 37 stack's experimental WM/ROM compatibility still needs device
testing. No PHY power/window tuning or flash writes are part of these changes.

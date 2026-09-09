#!/usr/bin/env python3
"""Isolated host regression test for the missing-MAC diagnostic guards.

Run on the WSL Linux host (not on the router):
  python3 scripts/c2000max/test_eth_debugfs_guards.py --source /path/to/current/mtk_eth_dbg.c

For a source file produced by kernel prepare with this patch already applied,
add --source-is-patched. The test reverses the specified patch with zero fuzz
only in its temporary copy, then reapplies it and requires byte-for-byte
equality with the supplied prepared source before running the same regressions.

Requires Python 3, a host C compiler, and GNU patch. Only reads --source.
Copies it into a temporary directory, applies the actual repository patch there,
extracts the four real function bodies, and compiles them with narrow mocks.
Checks six original crash cases, then exhaustive patched NULL topologies,
interface filtering, unchanged counter reset behavior, PCS mappings, NULL
PCS pointers, and invalid port IDs. No router access and no kernel-tree edits.

Limits: mocks do not validate MMIO, kernel locking, reset/unbind races, or
runtime hardware counters. This is not a kernel build or a device test.
After review/application, compile the kernel; hardware reads belong only on
a verified fixed kernel, never on the current vulnerable image.
"""

import argparse
import hashlib
import os
from pathlib import Path
import resource
import shlex
import subprocess
import tempfile


FUNCTIONS = (
    "mtk_eth_debugfs_mac_cnt_show",
    "mtk_eth_debugfs_xfi_cnt_show",
    "id_to_mtk_sgmii_pcs",
    "id_to_mtk_usxgmii_pcs",
)
PATCH_NAME = "999-zzzz-6017-c2000max-eth-debugfs-missing-mac-guards.patch"


def extract_function(source, name):
    # These four definitions have single-line signatures and no braces in
    # comments/strings. Fail if that expectation changes instead of guessing.
    marker = name + "("
    positions = [i for i in range(len(source)) if source.startswith(marker, i)]
    for pos in positions:
        start = source.rfind("\n", 0, pos) + 1
        end_signature = source.find("\n", pos)
        if not source[start:pos].startswith("static "):
            continue
        opening = end_signature + 1
        if source[opening:opening + 2] != "{\n":
            raise AssertionError(f"Unexpected function layout: {name}")
        depth = 0
        for end in range(opening, len(source)):
            depth += (source[end] == "{") - (source[end] == "}")
            if depth == 0:
                return source[start:end + 1] + "\n"
    raise AssertionError(f"Missing actual function definition: {name}")


PRELUDE = r'''
#include <assert.h>
#include <limits.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define MT7987_CAPS 7987
#define MT7988_CAPS 7988
enum { MTK_GMAC1_ID = 0, MTK_GMAC2_ID, MTK_GMAC3_ID, MTK_GMAC_ID_MAX };
struct phylink_pcs { int marker; };
struct mtk_pcs_lynxi { int marker; struct phylink_pcs pcs; };
struct mtk_usxgmii_pcs { int marker; struct phylink_pcs pcs; };
struct mtk_hw_stats { int stats_lock; };
struct mtk_mac {
    int interface;
    struct mtk_hw_stats *hw_stats;
    struct phylink_pcs *sgmii_pcs;
    struct phylink_pcs *usxgmii_pcs;
};
struct mtk_soc_data { unsigned int caps; };
struct mtk_eth { struct mtk_mac *mac[3]; struct mtk_soc_data *soc; };
struct seq_file { void *private; };
struct mtk_gmac_hw_stats { unsigned long count; };
struct mtk_xmac_hw_stats { unsigned long count; };
static struct mtk_gmac_hw_stats gmac_hw_stats[3];
static struct mtk_xmac_hw_stats xmac_hw_stats[3];
static unsigned int gm_dumped, xfi_dumped;

static int mtk_interface_mode_is_xgmii(int mode) { return mode == 1; }
static void seq_puts(struct seq_file *m, const char *s) { (void)m; (void)s; }
static void spin_lock(int *lock) { assert(*lock == 0); *lock = 1; }
static void spin_unlock(int *lock) { assert(*lock == 1); *lock = 0; }
static void mtk_mac_mib_dump(struct seq_file *m, unsigned int id) {
    struct mtk_eth *eth = m->private;
    assert(eth->mac[id]->hw_stats->stats_lock == 1);
    assert(!(gm_dumped & (1U << id)));
    gm_dumped |= 1U << id;
}
static void mtk_xfi_mib_dump(struct seq_file *m, unsigned int id) {
    struct mtk_eth *eth = m->private;
    assert(eth->mac[id]->hw_stats->stats_lock == 1);
    assert(!(xfi_dumped & (1U << id)));
    xfi_dumped |= 1U << id;
}
static struct mtk_pcs_lynxi *pcs_to_mtk_pcs_lynxi(struct phylink_pcs *pcs) {
    return (void *)((char *)pcs - offsetof(struct mtk_pcs_lynxi, pcs));
}
static struct mtk_usxgmii_pcs *pcs_to_mtk_usxgmii_pcs(struct phylink_pcs *pcs) {
    return (void *)((char *)pcs - offsetof(struct mtk_usxgmii_pcs, pcs));
}
'''

TESTS = r'''
static void original_crash_case(const char *which) {
    struct mtk_soc_data soc = { MT7987_CAPS };
    struct mtk_mac mac[3] = {0};
    struct mtk_hw_stats stats[3] = {0};
    struct mtk_eth eth = { .soc = &soc };
    struct seq_file seq = { .private = &eth };
    for (unsigned int i = 0; i < 3; ++i) {
        eth.mac[i] = &mac[i];
        mac[i].hw_stats = &stats[i];
        mac[i].interface = !strncmp(which, "xfi", 3);
    }
    if (strstr(which, "no-stats")) mac[2].hw_stats = NULL;
    else eth.mac[2] = NULL;
    if (!strncmp(which, "mac", 3))
        mtk_eth_debugfs_mac_cnt_show(&seq, NULL);
    else if (!strncmp(which, "xfi", 3))
        mtk_eth_debugfs_xfi_cnt_show(&seq, NULL);
    else if (!strcmp(which, "sgmii-null"))
        assert(id_to_mtk_sgmii_pcs(&eth, 1) == NULL);
    else if (!strcmp(which, "usxgmii-null"))
        assert(id_to_mtk_usxgmii_pcs(&eth, 0) == NULL);
    else abort();
}

static void counter_tests(void) {
    for (unsigned int mac_mask = 0; mac_mask < 8; ++mac_mask)
    for (unsigned int stats_mask = 0; stats_mask < 8; ++stats_mask)
    for (unsigned int xgmii_mask = 0; xgmii_mask < 8; ++xgmii_mask) {
        struct mtk_mac mac[3] = {0};
        struct mtk_hw_stats stats[3] = {0};
        struct mtk_eth eth = {0};
        struct seq_file seq = { .private = &eth };
        unsigned int expected_gm = mac_mask & stats_mask & ~xgmii_mask & 7;
        unsigned int expected_xfi = mac_mask & stats_mask & xgmii_mask & 6;
        gm_dumped = xfi_dumped = 0;
        for (unsigned int i = 0; i < 3; ++i) {
            eth.mac[i] = mac_mask & (1U << i) ? &mac[i] : NULL;
            mac[i].hw_stats = stats_mask & (1U << i) ? &stats[i] : NULL;
            mac[i].interface = !!(xgmii_mask & (1U << i));
            gmac_hw_stats[i].count = xmac_hw_stats[i].count = 123;
        }
        assert(mtk_eth_debugfs_mac_cnt_show(&seq, NULL) == 0);
        assert(mtk_eth_debugfs_xfi_cnt_show(&seq, NULL) == 0);
        assert(gm_dumped == expected_gm);
        assert(xfi_dumped == expected_xfi);
        for (unsigned int i = 0; i < 3; ++i) {
            assert(stats[i].stats_lock == 0);
            assert(gmac_hw_stats[i].count == ((expected_gm & (1U << i)) ? 0UL : 123UL));
            assert(xmac_hw_stats[i].count == ((expected_xfi & (1U << i)) ? 0UL : 123UL));
        }
    }
}

static void pcs_tests(void) {
    const unsigned int caps[] = {0, MT7987_CAPS, MT7988_CAPS};
    const unsigned int sgmii_maps[][2] = {{0, 1}, {0, 2}, {2, 1}};
    const unsigned int usxgmii_map[] = {2, 1};
    const unsigned int bad_ids[] = {2, 3, UINT_MAX};
    for (unsigned int cap = 0; cap < ARRAY_SIZE(caps); ++cap)
    for (unsigned int mac_mask = 0; mac_mask < 8; ++mac_mask)
    for (unsigned int pcs_mask = 0; pcs_mask < 8; ++pcs_mask) {
        struct mtk_soc_data soc = { caps[cap] };
        struct mtk_eth eth = { .soc = &soc };
        struct mtk_mac mac[3] = {0};
        struct mtk_pcs_lynxi sgmii[3] = {0};
        struct mtk_usxgmii_pcs usxgmii[3] = {0};
        for (unsigned int i = 0; i < 3; ++i) {
            eth.mac[i] = mac_mask & (1U << i) ? &mac[i] : NULL;
            mac[i].sgmii_pcs = pcs_mask & (1U << i) ? &sgmii[i].pcs : NULL;
            mac[i].usxgmii_pcs = pcs_mask & (1U << i) ? &usxgmii[i].pcs : NULL;
        }
        for (unsigned int id = 0; id < 2; ++id) {
            unsigned int sg = sgmii_maps[cap][id], us = usxgmii_map[id];
            struct mtk_pcs_lynxi *expected_sg =
                ((mac_mask & pcs_mask) & (1U << sg)) ? &sgmii[sg] : NULL;
            struct mtk_usxgmii_pcs *expected_us =
                ((mac_mask & pcs_mask) & (1U << us)) ? &usxgmii[us] : NULL;
            assert(id_to_mtk_sgmii_pcs(&eth, id) == expected_sg);
            assert(id_to_mtk_usxgmii_pcs(&eth, id) == expected_us);
        }
        for (unsigned int i = 0; i < ARRAY_SIZE(bad_ids); ++i) {
            assert(id_to_mtk_sgmii_pcs(&eth, bad_ids[i]) == NULL);
            assert(id_to_mtk_usxgmii_pcs(&eth, bad_ids[i]) == NULL);
        }
    }
}

int main(int argc, char **argv) {
    if (argc == 2) { original_crash_case(argv[1]); return 0; }
    counter_tests();
    pcs_tests();
    puts("PASS: 512 counter topologies and 192 PCS topologies, including invalid IDs");
    return 0;
}
'''


def run(command, **kwargs):
    result = subprocess.run(command, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"Command failed: {shlex.join(map(str, command))}\n"
                           f"{result.stdout}{result.stderr}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    parser.add_argument("--patch", type=Path, help="Override the repository patch path")
    parser.add_argument("--source-is-patched", action="store_true",
                        help="Reverse the patch in a temporary copy, then verify an exact round trip")
    args = parser.parse_args()
    source_path = args.source.resolve(strict=True)
    patch_path = args.patch or (
        Path(__file__).resolve().parents[2] / "target/linux/mediatek/patches-6.12" / PATCH_NAME
    )
    patch_path = patch_path.resolve(strict=True)
    input_bytes = source_path.read_bytes()
    input_hash = hashlib.sha256(input_bytes).hexdigest()
    quilt_path = Path(__file__).resolve().parents[2] / "staging_dir/host/bin/quilt"
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with tempfile.TemporaryDirectory(prefix="mtk-debugfs-regression-") as temp:
        root = Path(temp)
        copied_source = root / "drivers/net/ethernet/mediatek/mtk_eth_dbg.c"
        copied_source.parent.mkdir(parents=True)
        copied_source.write_bytes(input_bytes)
        if args.source_is_patched:
            reverse_cmd = ["patch", "--batch", "--force", "--reverse", "--fuzz=0",
                           "-p1", "-i", str(patch_path)]
            run(reverse_cmd + ["--dry-run"], cwd=root)
            run(reverse_cmd, cwd=root)
            print("PASS: zero-fuzz reverse application in the isolated temporary tree")
        original = copied_source.read_bytes().decode()
        patch_cmd = ["patch", "--batch", "--forward", "--fuzz=0", "-p1", "-i", str(patch_path)]
        run(patch_cmd + ["--dry-run"], cwd=root)
        if quilt_path.is_file():
            run([str(quilt_path), "import", str(patch_path)], cwd=root)
            run([str(quilt_path), "push"], cwd=root,
                env={**os.environ, "QUILT_PATCH_OPTS": "--fuzz=0"})
            print("PASS: repository quilt import/push in the isolated temporary tree")
        else:
            run(patch_cmd, cwd=root)
        patched_bytes = copied_source.read_bytes()
        if args.source_is_patched:
            if patched_bytes != input_bytes:
                raise AssertionError("Patch round trip does not reproduce the supplied source bytes")
            print("PASS: reverse/forward round trip exactly matches the supplied prepared source bytes")
        patched = patched_bytes.decode()
        executables = {}
        for label, source in (("original", original), ("patched", patched)):
            harness = PRELUDE + "\n".join(extract_function(source, n) for n in FUNCTIONS) + TESTS
            harness_path = root / (label + ".c")
            harness_path.write_text(harness)
            executable = root / label
            run(shlex.split(args.cc) + ["-std=c11", "-O1", "-Wall", "-Wextra", "-Werror",
                                       "-Wno-unused-parameter", str(harness_path), "-o", str(executable)])
            executables[label] = executable
        cases = ("mac-null", "xfi-null", "mac-no-stats", "xfi-no-stats", "sgmii-null", "usxgmii-null")
        for case in cases:
            old = subprocess.run([str(executables["original"]), case], capture_output=True, timeout=5)
            # SIGSEGV is the expected symptom in the compiled original bodies;
            # unrelated assertions/compiler errors must not count as reproductions.
            if old.returncode != -11:
                raise AssertionError(f"Original {case}: expected SIGSEGV, got {old.returncode}")
            run([str(executables["patched"]), case], timeout=5)
            print(f"PASS: original {case} faults; patched case returns safely")
        print(run([str(executables["patched"])], timeout=10).strip())
    if hashlib.sha256(source_path.read_bytes()).hexdigest() != input_hash:
        raise AssertionError("Source hash changed during test; investigate concurrent modification")
    print("PASS: repository patch applies with zero fuzz to the isolated copy")
    print(f"Source SHA256 unchanged: {input_hash}")
    print(f"Patch SHA256: {hashlib.sha256(patch_path.read_bytes()).hexdigest()}")
    print("No kernel source or image was modified; no device was contacted.")


if __name__ == "__main__":
    main()

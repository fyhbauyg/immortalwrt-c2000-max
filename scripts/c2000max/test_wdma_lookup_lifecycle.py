#!/usr/bin/env python3
"""Compile actual HNAT WDMA getters and hook toggles in an isolated host model.

No target build, module loading, MMIO, or device access. Kernel primitives and
packet hooks are mocked; this does not prove kernel scheduling/module unload.
"""

import argparse
import hashlib
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile


GETTERS = ("hnat_get_wdma_tx_port", "hnat_get_wdma_rx_port")
RUNTIME = (
    "ra_sw_nat_hook_rx", "ra_sw_nat_hook_tx", "ra_sw_nat_clear_bind_entries",
    "ppe_dev_register_hook", "ppe_dev_unregister_hook",
    "hnat_set_wdma_pse_port_state", "ppe_del_entry_by_mac",
    "ppe_del_entry_by_ip", "ppe_del_entry_by_bssid_wcid",
)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def function(source, name):
    # Definitions in this source have no brace-containing parameter list.
    match = re.search(r"(?m)^(?:static )?(?:int|void) " + re.escape(name) +
                      r"\([^;{}]*\)\s*\{", source)
    require(match, f"missing function definition: {name}")
    depth = 1
    pos = match.end()
    while depth:
        require(pos < len(source), f"unbalanced function: {name}")
        depth += (source[pos] == "{") - (source[pos] == "}")
        pos += 1
    return source[match.start():pos]


def declaration(source, name):
    match = re.search(r"(?m)^(?:int|void) \(\*" + re.escape(name) +
                      r"\)\([^;]*\)\s*=\s*[^;]+;", source)
    require(match, f"missing exported pointer declaration: {name}")
    return match.group()


def port_definitions(header):
    match = re.search(r"/\*PSE Ports\*/.*?^#define NR_WDMA2_PORT[^\n]*",
                      header, re.M | re.S)
    require(match, "missing PSE port definitions from hnat.h")
    return match.group()


def verify_source(source, baseline=None):
    for name in GETTERS:
        impl = name.replace("hnat_", "mtk_", 1)
        require(re.search(r"=\s*" + impl + r"\s*;$", declaration(source, name)),
                f"{name} must be initialized to its pure lookup at module load")
        writes = re.findall(r"(?:WRITE_ONCE|rcu_assign_pointer)\s*\(\s*" + name +
                            r"\b|\b" + name + r"\s*=(?!=)", source)
        require(not writes, f"{name} must not be republished/revoked by lifecycle code")
        body = function(source, impl)
        require(not re.search(r"hnat_priv|READ_ONCE|WRITE_ONCE|->|\breadl\b|"
                              r"\bwritel\b|\bcr_set_field\b", body),
                f"{impl} must not access provider state or MMIO")

    enable = function(source, "hnat_enable_hook")
    disable = function(source, "hnat_disable_hook")
    for name in RUNTIME:
        require(re.search(r"WRITE_ONCE\(\s*" + name + r"\s*,\s*NULL\s*\)", disable),
                f"runtime hook must still be revoked: {name}")
    last_clear = max(disable.index("WRITE_ONCE(" + name) for name in RUNTIME)
    require(last_clear < disable.index("synchronize_rcu();") <
            disable.index("synchronize_net();") < disable.index("hnat_unregister_nf_hooks();"),
            "runtime unpublish / grace periods / NF teardown order changed")
    require("mtk_set_wdma_pse_port_state" in enable,
            "MMIO setter must remain a gated runtime hook")
    setter = function(source, "mtk_set_wdma_pse_port_state")
    for token in ("hnat_priv", "ready", "removing", "quiescing", "cr_set_field"):
        require(token in setter, f"MMIO setter lost lifecycle guard/use: {token}")
    teardown = function(source, "hnat_teardown")
    require(teardown.index("hnat_disable_hook()") <
            teardown.index("WRITE_ONCE(hnat_priv, NULL)") <
            teardown.rindex("synchronize_rcu();"), "provider teardown order changed")
    if baseline:
        for impl in ("mtk_get_wdma_tx_port", "mtk_get_wdma_rx_port",
                     "mtk_set_wdma_pse_port_state", "hnat_teardown", "hnat_warm_init"):
            require(function(source, impl) == function(baseline, impl),
                    f"unexpected change to original function: {impl}")
        for name in ("hnat_enable_hook", "hnat_disable_hook"):
            old = function(baseline, name)
            for getter in GETTERS:
                old = re.sub(r"^\s*WRITE_ONCE\(" + getter + r",[^;]+;\n", "", old,
                             flags=re.M)
            require(function(source, name) == old,
                    f"changes beyond removing getter lifecycle stores: {name}")
    return enable, disable


PRELUDE = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
#include <pthread.h>

typedef uint32_t u32;
typedef uint16_t u16;
struct sk_buff { int unused; };
struct net_device { bool running; };
struct foe_entry { struct { int state; } bfib1; };
struct hnat_data { int version; bool whnat; };
struct mtk_hnat {
    bool ready, removing, quiescing, hooks_enabled;
    pthread_mutex_t hook_lock, rx_ppdev_lock, entry_lock;
    const struct hnat_data *data;
    int ppe_num, foe_etry_num_ppe[3];
    bool ppe_started[3];
    struct foe_entry *foe_table_cpu[3];
};
static struct mtk_hnat *hnat_priv;
static struct net_device *g_rx_ppdev;
static bool g_rx_ppdev_active;
static int hook_toggle;
static int register_error, register_calls, unregister_calls;
static int rcu_calls, net_calls, sma_calls, hw_calls;

#define READ_ONCE(x) __atomic_load_n(&(x), __ATOMIC_SEQ_CST)
#define WRITE_ONCE(x, v) __atomic_store_n(&(x), (v), __ATOMIC_SEQ_CST)
#define smp_load_acquire(p) __atomic_load_n((p), __ATOMIC_ACQUIRE)
#define smp_store_release(p, v) __atomic_store_n((p), (v), __ATOMIC_RELEASE)
#define mutex_lock(p) assert(pthread_mutex_lock(p) == 0)
#define mutex_unlock(p) assert(pthread_mutex_unlock(p) == 0)
#define spin_lock_bh(p) mutex_lock(p)
#define spin_unlock_bh(p) mutex_unlock(p)
#define MTK_HNAT_V2 2
#define MTK_HNAT_V3 3
#define SMA 1
#define SMA_ONLY_FWD_CPU 1
#define BIND 1

static bool netif_running(struct net_device *dev) { return dev->running; }
static int hnat_register_nf_hooks(void) { register_calls++; return register_error; }
static void hnat_unregister_nf_hooks(void) { unregister_calls++; }
static void synchronize_rcu(void) { rcu_calls++; }
static void synchronize_net(void) { net_calls++; }
static void hnat_schedule_sma(void) { sma_calls++; }
static void hnat_ppe_tb_set(struct mtk_hnat *h, int i, int f, int v)
{ (void)h; (void)i; (void)f; (void)v; hw_calls++; }
static void __entry_delete(struct mtk_hnat *h, struct foe_entry *entry)
{ (void)h; entry->bfib1.state = 0; }
static void hnat_cache_clr(int i) { (void)i; hw_calls++; }
static int mtk_sw_nat_hook_rx(struct sk_buff *skb) { (void)skb; return 0; }
static int mtk_sw_nat_hook_tx(struct sk_buff *skb, int gmac)
{ (void)skb; (void)gmac; return 0; }
static void mtk_ppe_dev_register_hook(struct net_device *dev) { (void)dev; }
static void mtk_ppe_dev_unregister_hook(struct net_device *dev) { (void)dev; }
static void foe_clear_all_bind_entries(void) {}
static int mtk_set_wdma_pse_port_state(u32 idx, bool up)
{ (void)idx; (void)up; hw_calls++; return 0; }
static int entry_delete_by_mac(unsigned char *mac) { (void)mac; return 0; }
static int entry_delete_by_ip(bool v4, void *addr)
{ (void)v4; (void)addr; return 0; }
static int entry_delete_by_bssid_wcid(u32 idx, u16 bssid, u16 wcid)
{ (void)idx; (void)bssid; (void)wcid; return 0; }
'''

TESTS = r'''
static void check_lookup(void)
{
    static const int expected_rx[] = { NR_WDMA0_PORT, NR_WDMA1_PORT, NR_WDMA2_PORT };
    int (*tx)(u32) = READ_ONCE(hnat_get_wdma_tx_port);
    int (*rx)(u32) = READ_ONCE(hnat_get_wdma_rx_port);
    assert(tx && rx);
    assert(tx == mtk_get_wdma_tx_port && rx == mtk_get_wdma_rx_port);
    for (u32 i = 0; i < 3; i++) {
        assert(tx(i) == NR_PPE0_PORT);
        assert(rx(i) == expected_rx[i]);
    }
    assert(tx(3) == -EINVAL && rx(3) == -EINVAL);
    assert(tx(UINT32_MAX) == -EINVAL && rx(UINT32_MAX) == -EINVAL);
}

static void check_runtime_off(void)
{
    assert(!ra_sw_nat_hook_rx && !ra_sw_nat_hook_tx);
    assert(!ra_sw_nat_clear_bind_entries);
    assert(!ppe_dev_register_hook && !ppe_dev_unregister_hook);
    assert(!hnat_set_wdma_pse_port_state);
    assert(!ppe_del_entry_by_mac && !ppe_del_entry_by_ip);
    assert(!ppe_del_entry_by_bssid_wcid);
    assert(!hook_toggle && !g_rx_ppdev_active);
    check_lookup();
}

static void check_runtime_on(bool whnat, int version)
{
    assert((ra_sw_nat_hook_rx != NULL) == (whnat && (version == 2 || version == 3)));
    assert((ra_sw_nat_hook_tx != NULL) == whnat);
    assert((ra_sw_nat_clear_bind_entries != NULL) == whnat);
    assert((ppe_dev_register_hook != NULL) == whnat);
    assert((ppe_dev_unregister_hook != NULL) == whnat);
    assert((hnat_set_wdma_pse_port_state != NULL) == whnat);
    assert(ppe_del_entry_by_mac && ppe_del_entry_by_ip && ppe_del_entry_by_bssid_wcid);
    assert(hook_toggle && g_rx_ppdev_active);
    check_lookup();
}

static void *lookup_reader(void *unused)
{
    (void)unused;
    for (int i = 0; i < 100000; i++)
        check_lookup();
    return NULL;
}

int main(void)
{
    struct hnat_data data = { .version = MTK_HNAT_V3, .whnat = true };
    struct net_device dev = { .running = true };
    struct mtk_hnat h = {
        .data = &data,
        .hook_lock = PTHREAD_MUTEX_INITIALIZER,
        .rx_ppdev_lock = PTHREAD_MUTEX_INITIALIZER,
        .entry_lock = PTHREAD_MUTEX_INITIALIZER,
    };
    g_rx_ppdev = &dev;
    /* Module loaded, platform provider has not probed. */
    assert(hnat_priv == NULL);
    check_runtime_off();
    assert(hnat_enable_hook() == -ENODEV);
    assert(hnat_disable_hook() == -ENODEV);
    for (u32 idx = 3; idx < 4096; idx++) {
        assert(hnat_get_wdma_tx_port(idx) == -EINVAL);
        assert(hnat_get_wdma_rx_port(idx) == -EINVAL);
    }

    WRITE_ONCE(hnat_priv, &h);
    assert(hnat_enable_hook() == -ENODEV); /* not ready */
    h.ready = true;
    h.quiescing = true;
    assert(hnat_enable_hook() == -ENODEV);
    h.quiescing = false;
    h.removing = true;
    assert(hnat_enable_hook() == -ENODEV);
    h.removing = false;
    register_error = -EIO;
    assert(hnat_enable_hook() == -EIO);
    check_runtime_off();
    register_error = 0;

    for (int version = 1; version <= 3; version++) {
        for (int whnat = 0; whnat <= 1; whnat++) {
            data.version = version;
            data.whnat = whnat;
            assert(hnat_enable_hook() == 0);
            assert(h.hooks_enabled);
            check_runtime_on(whnat, version);
            int registers = register_calls;
            assert(hnat_enable_hook() == 0); /* idempotent enable */
            assert(register_calls == registers);
            int grace = rcu_calls;
            int nets = net_calls;
            int unregs = unregister_calls;
            assert(hnat_disable_hook() == 0);
            assert(!h.hooks_enabled);
            assert(rcu_calls == grace + 1 && net_calls == nets + 1);
            assert(unregister_calls == unregs + 1);
            check_runtime_off();
            assert(hnat_disable_hook() == 0); /* idempotent disable */
            assert(rcu_calls == grace + 1 && unregister_calls == unregs + 1);
        }
    }

    /* Warm reset/removal already mark state before disabling live hooks. */
    data.version = MTK_HNAT_V3;
    data.whnat = true;
    assert(hnat_enable_hook() == 0);
    h.ready = false;
    h.quiescing = true;
    assert(hnat_disable_hook() == 0);
    assert(hnat_enable_hook() == -ENODEV);
    check_runtime_off();
    WRITE_ONCE(hnat_priv, NULL); /* modeled platform unbind, not module unload */
    assert(hnat_disable_hook() == -ENODEV);
    check_runtime_off();

    /* Lookups run concurrently with real extracted hook toggles. */
    pthread_t readers[2];
    for (unsigned i = 0; i < 2; i++)
        assert(pthread_create(&readers[i], NULL, lookup_reader, NULL) == 0);
    h.ready = true;
    h.quiescing = false;
    for (int i = 0; i < 1000; i++) {
        WRITE_ONCE(hnat_priv, &h);
        assert(hnat_enable_hook() == 0);
        check_runtime_on(true, MTK_HNAT_V3);
        assert(hnat_disable_hook() == 0);
        WRITE_ONCE(hnat_priv, NULL);
        check_runtime_off();
    }
    for (unsigned i = 0; i < 2; i++)
        assert(pthread_join(readers[i], NULL) == 0);
    assert(hw_calls == 0); /* Mapping never touches emulated MMIO. */
    assert(sma_calls == unregister_calls);
    assert(pthread_mutex_destroy(&h.hook_lock) == 0);
    assert(pthread_mutex_destroy(&h.rx_ppdev_lock) == 0);
    assert(pthread_mutex_destroy(&h.entry_lock) == 0);
    puts("PASS: pure lookup lifetime; all runtime hooks fail closed; invalid indexes; "
         "not-ready/quiescing/removing/unbound; 1000 toggles + 200000 concurrent lookup batches");
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel", type=Path, help="prepared kernel root (reads hnat.c + hnat.h)")
    parser.add_argument("--source", type=Path, help="standalone staged hnat.c")
    parser.add_argument("--ports", type=Path, help="standalone staged PSE header block")
    parser.add_argument("--baseline", type=Path, help="optional pre-6016 hnat.c for exact preservation checks")
    args = parser.parse_args()
    if args.kernel:
        if args.source or args.ports:
            parser.error("--kernel cannot be combined with --source/--ports")
        base = args.kernel / "drivers/net/ethernet/mediatek/mtk_hnat"
        source_path, ports_path = base / "hnat.c", base / "hnat.h"
    elif args.source and args.ports:
        source_path, ports_path = args.source, args.ports
    else:
        parser.error("supply --kernel, or both --source and --ports")
    source = source_path.read_text()
    ports = port_definitions(ports_path.read_text())
    baseline = args.baseline.read_text() if args.baseline else None
    enable, disable = verify_source(source, baseline)
    print("source_sha256=" + hashlib.sha256(source_path.read_bytes()).hexdigest(), flush=True)
    print("PASS: source contract and runtime-hook revocation checks" +
          ("; exact baseline lifecycle/setter/getter preservation" if baseline else ""), flush=True)
    getters = "\n\n".join(function(source, name.replace("hnat_", "mtk_", 1)) for name in GETTERS)
    declarations = "\n".join(declaration(source, name) for name in GETTERS + RUNTIME)
    program = "\n\n".join((PRELUDE, ports, getters, declarations, enable, disable, TESTS))
    compiler = shlex.split(os.environ.get("CC", "cc"))
    with tempfile.TemporaryDirectory(prefix="hnat-wdma-lifecycle-") as tmp:
        cfile = Path(tmp) / "wdma-lifecycle.c"
        binary = Path(tmp) / "wdma-lifecycle"
        cfile.write_text(program)
        for variant in (None, "CONFIG_MEDIATEK_NETSYS_V2", "CONFIG_MEDIATEK_NETSYS_V3"):
            label = variant or "legacy NETSYS"
            command = compiler + ["-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                                  "-pthread", "-fno-pie", "-no-pie", "-fsanitize=address,undefined"]
            if variant:
                command.append("-D" + variant)
            subprocess.run(command + [str(cfile), "-o", str(binary)], check=True)
            print("variant=" + label, flush=True)
            subprocess.run([str(binary)], check=True, timeout=30)
    print("PASS: all 3 NETSYS layouts under ASan/UBSan (host model; not a hardware test)")


if __name__ == "__main__":
    main()

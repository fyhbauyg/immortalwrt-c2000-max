#!/usr/bin/env python3
"""Compile actual WARP/WED functions with fault-injected host boundary stubs.

This validates control flow, not kernel DMA/RCU behaviour or router throughput.
"""
import pathlib
import subprocess
import sys
import tempfile


def function(source, name):
    text = source.read_text()
    start = text.index("\n" + name + "(") + 1
    start = text.rfind("\n", 0, start - 1) + 1
    brace = text.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


PRELUDE = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#define WED_INTER_AGENT_SUPPORT
#define WED_HW_TX_SUPPORT
#define WED_RX_D_SUPPORT
#define WED_RX_HW_RRO_3_0
#define WED_HIF_TXD_SUPPORT
#define WED_PAO_SUPPORT
#define BIT(n) (1U << (n))
#define WIFI_HW_CAP_RRO_3_0 0
#define ALL_INT_AGENT 0
#define WARP_RESET_INTERFACE 0
#define WARP_DBG_ERR 0
#define WARP_DBG_INF 1
#define HWIFI_STATE_RESET 0
#define WARP_DMA_TXRX 1
#define WARP_DMA_RX 2
#define WARP_DMA_DISABLE 0
#define warp_dbg(...) ((void)0)
#define dev_err(...) ((void)0)
struct wifi_hw { unsigned hw_cap; };
struct wifi_entry { struct wifi_hw hw; };
struct wed_entry { int unused; };
struct wdma_entry { int unused; };
struct warp_entry { struct wifi_entry wifi; int idx; };
struct warp_bus { int pcie_ints_offset; };
struct mtk_hw_dev { unsigned long state; };
struct ops { int (*start)(void *); };
struct wed_trans { bool enable; int wed_ver; struct wifi_hw *wifi_hw; struct ops *dma_ops; };
static struct warp_entry entry;
static struct wed_entry wed;
static struct wdma_entry wdma;
static struct warp_bus bus;
static struct mtk_hw_dev dev;
static struct wed_trans trans;
static int failed_stage, alive[5], exits[5], irq_enable, hw_init;
static int dma_calls, dma_mode, pci_calls, reset_calls, missing;
static int order[5], order_n;
static struct warp_bus *warp_bus_get(void) { return &bus; }
static bool check_and_update_warp(struct warp_entry **a, struct wed_entry **b,
    struct wdma_entry **c, struct wifi_entry **d, void *p) {
    if (missing) return false;
    *a=&entry; *b=&wed; *c=&wdma; *d=&entry.wifi; return true;
}
static int alloc_stage(int stage) {
    assert(!irq_enable); assert(!alive[stage]);
    if (stage == failed_stage) return -ENOMEM;
    alive[stage]=1; return 0;
}
static void free_stage(int stage) {
    assert(alive[stage]); alive[stage]=0; exits[stage]++;
    order[order_n++]=stage;
}
static int hif_txd_init(struct wed_entry *p) { return alloc_stage(1); }
static int wed_txbm_init(struct wed_entry *p, struct wifi_hw *h) { return alloc_stage(2); }
static int wed_rx_bm_init(struct wed_entry *p, struct wifi_hw *h) { return alloc_stage(3); }
static int wed_rx_page_bm_init(struct wed_entry *p, struct wifi_hw *h) { return alloc_stage(4); }
static void hif_txd_exit(struct wed_entry *p) { free_stage(1); }
static void wed_txbm_exit(struct wed_entry *p) { free_stage(2); }
static void wed_rx_bm_exit(struct wed_entry *p) { free_stage(3); }
static void wed_rx_page_bm_exit(struct wed_entry *p) { free_stage(4); }
static void warp_wdma_ring_init_hw(struct wed_entry *a, struct wdma_entry *b) {}
static void warp_wed_init_hw(struct wed_entry *a, struct wdma_entry *b) {}
static void warp_wdma_init_hw(struct wed_entry *a, struct wdma_entry *b, int i) {}
static void warp_wpdma_ring_init_hw(struct wed_entry *a, struct wifi_entry *b) { hw_init++; }
static void warp_int_ctrl_hw(struct wed_entry *a, struct wifi_entry *b,
    struct wdma_entry *c, int agent, bool on, int offset, int idx) {
    if (on) { for (int i=1;i<=4;i++) assert(alive[i]); irq_enable++; }
}
static void warp_eint_init_hw(struct wed_entry *p) {}
static void warp_eint_ctrl_hw(struct wed_entry *p, bool on) {}
static void warp_reset_hw(struct wed_entry *p, int type) { reset_calls++; }
static void hif_txd_init_hw(struct wed_entry *p, struct wifi_entry *w) { assert(alive[1]); }
static void warp_pao_init_hw(struct wed_entry *p, struct wifi_entry *w) {}
static struct wed_trans *to_wed_trans(void *p) { return &trans; }
static struct mtk_hw_dev *to_hw_dev(void *p) { return &dev; }
static void *to_bus_trans(void *p) { return p; }
static void *to_device(void *p) { return p; }
static bool test_bit(int n, unsigned long *p) { return !!(*p & BIT(n)); }
static void wed_v1_compatible_mode_config(void *p, struct wifi_hw *h) {}
static void warp_dma_handler(void *p, int mode) { dma_calls++; dma_mode=mode; }
static int pci_start(void *p) { pci_calls++; return 0; }
'''

MAIN = r'''
static void fresh(void) {
    failed_stage=irq_enable=hw_init=dma_calls=pci_calls=reset_calls=missing=order_n=0;
    memset(alive,0,sizeof(alive)); memset(exits,0,sizeof(exits));
    entry.wifi.hw.hw_cap=BIT(WIFI_HW_CAP_RRO_3_0);
    static struct ops ops={pci_start};
    trans=(struct wed_trans){true,3,&entry.wifi.hw,&ops}; dev.state=0;
}
int main(void) {
    for (int fail=1; fail<=4; fail++) {
        fresh(); failed_stage=fail;
        assert(wed_start(&trans)==-ENOMEM);
        assert(!dma_calls && !pci_calls && !irq_enable && !hw_init);
        for (int i=1;i<=4;i++) {
            assert(!alive[i]); assert(exits[i] == (i<fail));
        }
        for (int i=0;i<order_n;i++) assert(order[i] == fail-1-i);
    }
    fresh(); missing=1; assert(wed_start(&trans)==-ENODEV);
    assert(!dma_calls && !pci_calls && !irq_enable && !order_n);
    fresh(); assert(wed_start(&trans)==0);
    assert(dma_calls==1 && dma_mode==WARP_DMA_TXRX && pci_calls==1 && irq_enable==1);
    for (int i=1;i<=4;i++) assert(alive[i] && !exits[i]);
    fresh(); dev.state=BIT(HWIFI_STATE_RESET); assert(wed_start(&trans)==0);
    assert(dma_calls==1 && dma_mode==WARP_DMA_RX && pci_calls==1);
    fresh(); trans.enable=false; assert(wed_start(&trans)==0);
    assert(!dma_calls && pci_calls==1 && !irq_enable);
    puts("PASS: actual WED/WARP init: four allocation failures, missing client, normal/reset/disabled");
    return 0;
}
'''

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).parent / "patched")
hwifi = pathlib.Path(sys.argv[2]) if len(sys.argv)>2 else root
wed_file = hwifi / "mtk_wed.c"
if not wed_file.is_file():
    wed_file = hwifi / "wlan_hwifi" / "bus" / "mtk_wed.c"
source = (PRELUDE + function(root / "warp_main.c", "warp_ring_init") + "\n" +
          function(wed_file, "wed_start") + MAIN)
with tempfile.TemporaryDirectory(prefix="wed-init-host-") as work:
    binary = pathlib.Path(work) / "wed-init"
    subprocess.run(["gcc", "-std=gnu11", "-Wall", "-Wextra", "-Wno-unused-parameter",
                    "-Wno-unused-function", "-x", "c", "-", "-o", str(binary)],
                   input=source, text=True, check=True)
    subprocess.run([str(binary)], check=True)

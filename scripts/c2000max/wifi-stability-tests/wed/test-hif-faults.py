#!/usr/bin/env python3
"""Actual HIF TXD init/exit: first, middle, final allocation/map failures."""
import pathlib
import subprocess
import sys
import tempfile

def extract(path, name):
    text = path.read_text()
    start = text.index("\n" + name + "(") + 1
    start = text.rfind("\n", 0, start - 1) + 1
    brace = text.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

PRE = r'''
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
typedef uintptr_t dma_addr_t;
#define GFP_ATOMIC 0
#define __GFP_ZERO 0
#define DMA_TO_DEVICE 1
#define unlikely(v) (v)
#define warp_dbg(...) ((void)0)
struct device { int unused; };
struct pci_dev { struct device dev; };
struct wifi_hw { struct pci_dev *hif_dev; int src; };
struct wifi_entry { struct wifi_hw hw; };
struct warp_entry { struct wifi_entry wifi; };
struct wed_hif_txd_ctrl {
    unsigned hif_txd_segment_nums; int hif_txd_src;
    void *hif_txd_addr[32]; dma_addr_t hif_txd_addr_pa[32];
};
struct wed_tx_ctrl { struct wed_hif_txd_ctrl hif_txd_ctrl; };
struct wed_res_ctrl { struct wed_tx_ctrl tx_ctrl; };
struct wed_entry { struct wed_res_ctrl res_ctrl; struct warp_entry *warp; };
static int allocs,frees,maps,unmaps,alloc_calls,map_calls,fail_alloc,fail_map;
static void *live[32];
static unsigned long __get_free_pages(unsigned flags,unsigned order) {
    if(++alloc_calls==fail_alloc)return 0;
    void *p=calloc(1,65536); assert(p); live[allocs++]=p; return (unsigned long)p;
}
static void free_pages(unsigned long addr,unsigned order) {
    assert(addr); bool found=false;
    for(int i=0;i<32;i++)if(live[i]==(void *)addr){live[i]=NULL;found=true;break;}
    assert(found);frees++;free((void *)addr);
}
static dma_addr_t dma_map_single(struct device *d,void *p,unsigned size,int dir) {
    if(++map_calls==fail_map)return (dma_addr_t)-1;
    maps++;return (dma_addr_t)p;
}
static bool dma_mapping_error(struct device *d,dma_addr_t pa){return pa==(dma_addr_t)-1;}
static void dma_unmap_single(struct device *d,dma_addr_t pa,unsigned size,int dir){
    assert(pa&&pa!=(dma_addr_t)-1);unmaps++;
}
'''
MAIN = r'''
static void trial(int allocfail,int mapfail) {
    allocs=frees=maps=unmaps=alloc_calls=map_calls=0;
    fail_alloc=allocfail;fail_map=mapfail;memset(live,0,sizeof(live));
    struct pci_dev pci={0}; struct warp_entry warp={.wifi.hw.hif_dev=&pci};
    struct wed_entry wed={.warp=&warp};
    int ret=hif_txd_init(&wed);
    if(allocfail||mapfail)assert(ret==-ENOMEM); else assert(ret==0);
    if(!ret)hif_txd_exit(&wed);
    assert(allocs==frees&&maps==unmaps);
    assert(wed.res_ctrl.tx_ctrl.hif_txd_ctrl.hif_txd_segment_nums==0);
    hif_txd_exit(&wed); /* Must not release failed or already-exited segments. */
    assert(allocs==frees&&maps==unmaps);
}
int main(void){
    trial(0,0);
    for(int i=1;i<=32;i++){trial(i,0);trial(0,i);}
    puts("PASS: actual HIF TXD functions: 65 allocation/map/success paths, repeat-exit safety");
}
'''
root=pathlib.Path(sys.argv[1] if len(sys.argv)>1 else pathlib.Path(__file__).parent / "patched")
source=PRE+extract(root/"wed.c","hif_txd_init")+extract(root/"wed.c","hif_txd_exit")+MAIN
with tempfile.TemporaryDirectory(prefix="wed-hif-host-") as work:
    binary=pathlib.Path(work)/"hif-faults"
    subprocess.run(["gcc","-std=gnu11","-Wall","-Wextra","-Wno-unused-parameter",
        "-Wno-sign-compare","-fsanitize=address,undefined","-x","c","-","-o",str(binary)],
        input=source,text=True,check=True)
    subprocess.run([str(binary)],check=True)

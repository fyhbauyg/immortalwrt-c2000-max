#!/usr/bin/env python3
"""Actual TX/RX/page ring functions, fake allocators/DMA, per-item failures.

No kernel page-fragment implementation is simulated; counters check ownership
and cleanup decisions at the driver's allocation/map/free API boundary.
"""
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
#include <string.h>
#include <stdbool.h>
typedef unsigned char u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uintptr_t dma_addr_t;
#define KERNEL_VERSION(a,b,c) (((a)<<16)+((b)<<8)+(c))
#define LINUX_VERSION_CODE KERNEL_VERSION(6,12,94)
#define GFP_ATOMIC 0
#define DMA_FROM_DEVICE 0
#define DMA_TO_DEVICE 1
#define SKB_DATA_ALIGN(x) (x)
#define SKB_BUF_HEADROOM_RSV 32
#define SKB_BUF_TAILROOM_RSV 32
#define PARTIAL_RXDMAD_SDP0_L_MASK 0xffffffffU
#define PARTIAL_TXDMAD_SDP0_L_MASK 0xffffffffU
#define PARTIAL_TXDMAD_TOKEN_ID_SHIFT 16
#define PARTIAL_TXDMAD_TOKEN_ID_MASK 0xffff0000U
#define WRITE_ONCE(dst,v) ((dst)=(v))
#define warp_dbg(...) ((void)0)
struct device { int unused; };
struct platform_device { struct device dev; };
struct pci_dev { struct device dev; };
struct sk_buff { int unused; };
struct page { int unused; };
struct page_frag_cache { void *va; unsigned pagecnt_bias; };
struct idr { void *p[16]; };
struct warp_dma_buf { void *alloc_va; dma_addr_t alloc_pa; unsigned long alloc_size; };
struct warp_dma_cb {
    void *alloc_va; dma_addr_t alloc_pa; unsigned alloc_size;
    struct sk_buff *pkt; unsigned char *pkt_va; dma_addr_t pkt_pa;
    unsigned pkt_size; void *next;
};
struct warp_bm_rxdmad { u32 sdp0,token; };
struct warp_bm_txdmad { u32 sdp0,token; };
struct warp_rx_ring { struct warp_dma_cb *cell; void *head; };
struct warp_tx_ring { struct warp_dma_cb *cell; };
struct wed_rx_bm_res {
    struct pci_dev *hif_dev; unsigned rxd_len,pkt_num,pkt_len,ring_len;
    struct warp_rx_ring *ring; struct warp_dma_buf *desc;
    struct page_frag_cache rx_page[2];
};
struct wed_rx_page_bm {
    struct pci_dev *hif_dev; unsigned rxd_len,page_num,rx_page_size,ring_len;
    struct warp_rx_ring *ring; struct warp_dma_buf *desc;
    struct page_frag_cache rx_page;
};
struct wed_tx_bm {
    struct pci_dev *hif_dev; unsigned txd_len,pkt_num,pkt_size,ring_len;
    struct warp_tx_ring *ring; struct warp_dma_buf *desc;
    struct page_frag_cache tx_page; struct idr id;
};
struct wed_tx_ctrl { struct wed_tx_bm tx_bm; };
struct wed_rx_ctrl { struct wed_rx_bm_res res; struct wed_rx_page_bm page_bm; };
struct wed_res_ctrl { struct wed_rx_ctrl rx_ctrl; struct wed_tx_ctrl tx_ctrl; };
struct wed_entry { struct wed_res_ctrl res_ctrl; struct platform_device *pdev; };
static int allocs,frees,maps,unmaps,descs,cells;
static int packet_call,map_call,id_call,fail_packet,fail_map,fail_id,fail_desc,fail_cell;
static int idr_alloc(struct idr *id, void *ptr,int start,int end,int gfp) {
    if (++id_call==fail_id) return -ENOMEM;
    for (int i=start;i<end;i++) if (!id->p[i]) { id->p[i]=ptr; return i; }
    return -ENOMEM;
}
static void *idr_find(struct idr *id,unsigned idx) { return id->p[idx]; }
static void idr_remove(struct idr *id,unsigned idx) { assert(id->p[idx]); id->p[idx]=NULL; }
static void *page_frag_alloc(struct page_frag_cache *cache,unsigned size,int flags) {
    if (++packet_call==fail_packet) return NULL;
    allocs++; return calloc(1,size);
}
static struct page *virt_to_head_page(void *p) { assert(p); return p; }
static struct page *virt_to_page(void *p) { assert(p); return p; }
static void put_page(struct page *p) { assert(p); frees++; free(p); }
static void rx_bm_page_frag_cache_drain(struct page *p,unsigned n) {}
static void rx_page_bm_page_frag_cache_drain(struct page *p,unsigned n) {}
static void tx_bm_page_frag_cache_drain(struct page *p,unsigned n) {}
static dma_addr_t dma_map_single(struct device *d,void *va,unsigned size,int dir) {
    assert(va); if (++map_call==fail_map) return (dma_addr_t)-1;
    maps++; return (dma_addr_t)va;
}
static bool dma_mapping_error(struct device *d,dma_addr_t pa) { return pa==(dma_addr_t)-1; }
static void dma_unmap_single(struct device *d,dma_addr_t pa,unsigned size,int dir) {
    assert(pa && pa!=(dma_addr_t)-1); unmaps++;
}
static void *vmalloc(unsigned size) { if(fail_cell) return NULL; cells++; return malloc(size); }
static void *vzalloc(unsigned size) { if(fail_cell) return NULL; cells++; return calloc(1,size); }
static void vfree(void *p) { if(p) { cells--; free(p); } }
static int warp_dma_buf_alloc(struct platform_device *d,struct warp_dma_buf *p,unsigned size) {
    if(fail_desc) return -ENOMEM;
    descs++; p->alloc_va=calloc(1,size); p->alloc_size=size; p->alloc_pa=(dma_addr_t)p->alloc_va;
    return 0;
}
static void warp_dma_buf_free(struct platform_device *d,struct warp_dma_buf *p) {
    if(p->alloc_va) { descs--; free(p->alloc_va); memset(p,0,sizeof(*p)); }
}
static void wed_exit_msdu_page_hash(struct wed_rx_page_bm *p) {}
static void wed_init_msdu_page_hash(struct wed_rx_page_bm *p) {}
'''

MAIN = r'''
static void fresh(void) {
    allocs=frees=maps=unmaps=descs=cells=0;
    packet_call=map_call=id_call=fail_packet=fail_map=fail_id=fail_desc=fail_cell=0;
}
static void clean(void) { assert(allocs==frees && maps==unmaps && !descs && !cells); }
static void trial(int kind,int fail_kind,int nth) {
    fresh();
    if(fail_kind==1)fail_packet=nth;
    if(fail_kind==2)fail_map=nth;
    if(fail_kind==3)fail_desc=1;
    if(fail_kind==4)fail_cell=1;
    if(fail_kind==5)fail_id=nth;
    struct platform_device pdev={0}; struct pci_dev pci={0};
    struct wed_entry wed={0}; wed.pdev=&pdev;
    struct warp_dma_buf desc={0}; struct warp_rx_ring rxring={0};
    struct warp_tx_ring txring={0}; int ret;
    if(kind==1) {
        struct wed_rx_bm_res *res=&wed.res_ctrl.rx_ctrl.res;
        *res=(struct wed_rx_bm_res){.hif_dev=&pci,.rxd_len=8,.pkt_num=3,.pkt_len=64,
            .ring_len=4,.ring=&rxring,.desc=&desc};
        ret=wed_rx_bm_ring_init(&wed,0,res);
        if(!fail_kind) {
            assert(ret==0);
            /* The public initializer registers these with HWIFI. Simulate
             * HWIFI token teardown, not WARP normal-exit ownership. */
            for(int i=0;i<3;i++) {
                dma_unmap_single(&pci.dev,rxring.cell[i].pkt_pa,64,DMA_FROM_DEVICE);
                put_page(virt_to_head_page(rxring.cell[i].pkt));
            }
        } else assert(ret<0);
        wed_rx_bm_ring_exit(&wed,&rxring,4,&desc);
    } else if(kind==2) {
        struct wed_rx_page_bm *bm=&wed.res_ctrl.rx_ctrl.page_bm;
        *bm=(struct wed_rx_page_bm){.hif_dev=&pci,.rxd_len=8,.page_num=3,.rx_page_size=64,
            .ring_len=4,.ring=&rxring,.desc=&desc};
        ret=wed_rx_page_bm_ring_init(&wed,bm);
        assert(fail_kind ? ret<0 : ret==0);
        wed_rx_page_bm_ring_exit(&wed,&rxring,4,&desc);
    } else {
        struct wed_tx_bm *bm=&wed.res_ctrl.tx_ctrl.tx_bm;
        *bm=(struct wed_tx_bm){.hif_dev=&pci,.txd_len=8,.pkt_num=3,.pkt_size=64,
            .ring_len=4,.ring=&txring,.desc=&desc};
        ret=wed_tx_bm_ring_init(&wed,bm);
        assert(fail_kind ? ret<0 : ret==0);
        wed_tx_bm_ring_exit(&wed,&txring,4,&desc);
        for(int i=0;i<16;i++) assert(!bm->id.p[i]);
    }
    clean();
}
int main(void) {
    int count=0;
    for(int kind=1;kind<=3;kind++) {
        trial(kind,0,0);count++;
        for(int nth=1;nth<=3;nth++) {
            trial(kind,1,nth); trial(kind,2,nth);count+=2;
            if(kind==3) {trial(kind,5,nth);count++;}
        }
        trial(kind,3,0); trial(kind,4,0);count+=2;
    }
    printf("PASS: actual TX/RX/page BM functions: %d fault/success paths, balanced allocation/map cleanup\n",count);
}
'''

root = pathlib.Path(sys.argv[1] if len(sys.argv)>1 else pathlib.Path(__file__).parent / "patched")
functions = []
for file,names in [
    ("warp_rx_bm.c",["wed_rx_bm_dma_cb_exit","wed_rx_bm_ring_exit","wed_rx_bm_dma_cb_init","wed_rx_bm_ring_init"]),
    ("warp_rx_page_bm.c",["wed_rx_page_bm_dma_cb_init","wed_rx_page_bm_ring_init","wed_rx_page_bm_dma_cb_exit","wed_rx_page_bm_ring_exit"]),
    ("warp_tx_bm_v2.c",["wed_tx_bm_dma_cb_init","wed_tx_bm_ring_init","wed_tx_bm_dma_cb_exit","wed_tx_bm_ring_exit"]),
]:
    functions.extend(extract(root/file,n) for n in names)
source=PRE+"\n".join(functions)+MAIN
with tempfile.TemporaryDirectory(prefix="wed-bm-host-") as work:
    binary=pathlib.Path(work)/"bm-faults"
    subprocess.run(["gcc","-std=gnu11","-Wall","-Wextra","-Wno-unused-parameter",
        "-Wno-unused-function","-Wno-unused-variable","-fsanitize=address,undefined","-x","c","-","-o",str(binary)],
        input=source,text=True,check=True)
    subprocess.run([str(binary)],check=True)

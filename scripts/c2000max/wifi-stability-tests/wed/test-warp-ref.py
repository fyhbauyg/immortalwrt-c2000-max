#!/usr/bin/env python3
"""Actual register/remove/ring-exit with mocked platform-device lifecycle."""
import pathlib
import subprocess
import sys
import tempfile

def extract(path, name):
    text=path.read_text()
    start=text.index("\n"+name+"(")+1
    start=text.rfind("\n",0,start-1)+1
    brace=text.index("{",start);depth=1;end=brace+1
    while depth:
        depth+=(text[end]=="{")-(text[end]=="}");end+=1
    return text[start:end]

PRE=r'''
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#define WED_INTER_AGENT_SUPPORT
#define CONFIG_WARP_V3_1
#define MAX_NAME_SIZE 64
#define WHNAT_PLATFORM_DEV_NAME "wed"
#define THIS_MODULE NULL
#define PROBE_FORCE_SYNCHRONOUS 0
#define ALL_INT_AGENT 0
#define WARP_RESET_INTERFACE 0
#define warp_dbg(...) ((void)0)
struct platform_device;
struct device_driver { char *name;void *owner;void *of_match_table;int probe_type; };
struct platform_driver {
    int(*probe)(struct platform_device *);void(*remove)(struct platform_device *);
    struct device_driver driver;
};
struct device { struct device_driver *driver; };
struct platform_device { struct device dev; };
struct wifi_hw { void *priv; };
struct wifi_ops { int unused; };
struct wifi_entry { struct wifi_hw hw;struct wifi_ops *ops; };
struct wdma_entry { int unused; };
struct wed_entry { int unused; };
struct warp_entry {
    struct wifi_entry wifi; struct wdma_entry wdma;struct wed_entry wed;int idx;
    struct platform_driver pdriver;struct platform_device *pdev;
};
struct warp_ctrl { int warp_driver_idx;unsigned warp_ref;int warp_num;struct warp_entry entry[2]; };
struct warp_bus { int pcie_ints_offset; };
static struct warp_ctrl ctrl;
static struct warp_bus bus;
static struct platform_device devices[2];
static int fail_port,fail_register,fail_bind,unregisters,expected_remove_ref;
static void *warp_of_ids[2];
static struct warp_ctrl *warp_ctrl_get(void){return &ctrl;}
static struct warp_bus *warp_bus_get(void){return &bus;}
static void warp_increase_ref(void){ctrl.warp_ref++;}
static void warp_decrease_ref(void){assert(ctrl.warp_ref>0);ctrl.warp_ref--;}
static struct wifi_entry *to_wifi_entry(struct wifi_hw *hw){
    for(int i=0;i<2;i++)if(hw==&ctrl.entry[i].wifi.hw)return &ctrl.entry[i].wifi;
    return NULL;
}
static struct warp_entry *to_warp_entry(struct wifi_entry *wifi){
    for(int i=0;i<2;i++)if(wifi==&ctrl.entry[i].wifi)return &ctrl.entry[i];
    return NULL;
}
static int warp_get_wdma_port(struct wdma_entry *w,int i){return fail_port?-1:0;}
static int warp_probe(struct platform_device *p){return 0;}
static void warp_remove(struct platform_device *p){}
static void warp_entry_proc_init(struct warp_ctrl *c,struct warp_entry *w){}
static void warp_entry_proc_exit(struct warp_ctrl *c,struct warp_entry *w){}
static int platform_driver_register(struct platform_driver *p){
    if(fail_register)return -1;
    for(int i=0;i<2;i++)if(p==&ctrl.entry[i].pdriver){
        ctrl.entry[i].pdev=&devices[i];
        devices[i].dev.driver=fail_bind?NULL:&p->driver;
        return 0;
    }
    assert(0);return -1;
}
static void platform_driver_unregister(struct platform_driver *p){
    unregisters++;
    if(expected_remove_ref>=0)assert(ctrl.warp_ref==(unsigned)expected_remove_ref);
    for(int i=0;i<2;i++)if(p==&ctrl.entry[i].pdriver){
        ctrl.entry[i].pdev=NULL;devices[i].dev.driver=NULL;
    }
}
static bool check_and_update_warp(struct warp_entry **a,struct wed_entry **b,
    struct wdma_entry **c,struct wifi_entry **d,void *priv);
static void warp_eint_ctrl_hw(struct wed_entry *w,bool enable){}
static void warp_int_ctrl_hw(struct wed_entry *w,struct wifi_entry *f,
    struct wdma_entry *d,int agent,bool on,int offset,int idx){}
static void warp_reset_hw(struct wed_entry *w,int type){}
'''
POST_HELPERS=r'''
static bool check_and_update_warp(struct warp_entry **a,struct wed_entry **b,
    struct wdma_entry **c,struct wifi_entry **d,void *priv){
    *a=warp_entry_get_by_privdata(priv);if(!*a)return false;
    *b=&(*a)->wed;*c=&(*a)->wdma;*d=&(*a)->wifi;return true;
}
'''
MAIN=r'''
static int identities[2]; static struct wifi_ops ops;
static void fresh(void){
    memset(&ctrl,0,sizeof(ctrl));ctrl.warp_num=2;
    for(int i=0;i<2;i++){ctrl.entry[i].idx=i;ctrl.entry[i].wifi.hw.priv=&identities[i];}
    fail_port=fail_register=fail_bind=unregisters=0;expected_remove_ref=-1;
}
static void reg(int idx){assert(warp_register_client(&ctrl.entry[idx].wifi.hw,&ops)==0);}
int main(void){
    fresh();reg(0);assert(ctrl.warp_ref==1);
    /* Ring-start error exits directly to remove, without calling ring_exit. */
    expected_remove_ref=0;warp_client_remove(&identities[0]);
    assert(ctrl.warp_ref==0&&unregisters==1);
    warp_client_remove(&identities[0]);warp_client_remove(NULL);
    assert(ctrl.warp_ref==0&&unregisters==1);
    fresh();reg(0);warp_ring_exit(&identities[0]);assert(ctrl.warp_ref==1);
    expected_remove_ref=0;warp_client_remove(&identities[0]);assert(ctrl.warp_ref==0);
    fresh();reg(0); /* RESET stop/start retains the registered client. */
    assert(ctrl.warp_ref==1&&unregisters==0);
    expected_remove_ref=0;warp_client_remove(&identities[0]);assert(ctrl.warp_ref==0);
    fresh();reg(0);reg(1);assert(ctrl.warp_ref==2);
    warp_ring_exit(&identities[0]);assert(ctrl.warp_ref==2);
    expected_remove_ref=1;warp_client_remove(&identities[0]);assert(ctrl.warp_ref==1);
    expected_remove_ref=0;warp_client_remove(&identities[1]);assert(ctrl.warp_ref==0);
    for(int stage=0;stage<3;stage++){
        fresh();fail_port=stage==0;fail_register=stage==1;fail_bind=stage==2;
        assert(warp_register_client(&ctrl.entry[0].wifi.hw,&ops)==-1);
        assert(ctrl.warp_ref==0);int old_unregs=unregisters;
        warp_client_remove(&identities[0]);assert(ctrl.warp_ref==0&&unregisters==old_unregs);
    }
    puts("PASS: actual register/remove/ring-exit: failed start, normal stop, retained RESET, duplicate/failed remove, shared clients");
}
'''
root=pathlib.Path(sys.argv[1] if len(sys.argv)>1 else pathlib.Path(__file__).parent/"patched")
file=root/"warp_main.c"
source=PRE+extract(file,"warp_entry_release")+extract(file,"warp_entry_get_by_privdata")+POST_HELPERS
source+=extract(file,"warp_register_client")+extract(file,"warp_client_remove")+extract(file,"warp_ring_exit")+MAIN
with tempfile.TemporaryDirectory(prefix="warp-ref-host-")as work:
    binary=pathlib.Path(work)/"refs"
    subprocess.run(["gcc","-std=gnu11","-Wall","-Wextra","-Wno-unused-parameter",
        "-Wno-unused-variable","-Wno-sign-compare","-x","c","-","-o",str(binary)],
        input=source,text=True,check=True)
    subprocess.run([str(binary)],check=True)

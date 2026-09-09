/* Desktop-only resource stubs around mechanically extracted driver functions. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
typedef uint8_t u8;
typedef uint32_t u32;
#define READ_ONCE(x) (x)
#define warp_dbg(...) ((void)0)
#define WDMA_DEV_NODE "wdma"
#define THIS_MODULE NULL
#define MAX_NAME_SIZE 32
#define WHNAT_PLATFORM_DEV_NAME "warp"
#define PROBE_FORCE_SYNCHRONOUS 1
#define WIFI_REQUEST_IRQ 1
struct device_driver { const char *name; void *owner; const void *of_match_table; int probe_type; };
struct device { struct device_driver *driver; };
struct platform_device { struct device dev; };
struct platform_driver { int (*probe)(struct platform_device *); void (*remove)(struct platform_device *); struct device_driver driver; };
struct device_node { int x; };
struct resource { unsigned long start; };
struct wifi_hw { void *priv; int msi_enable, hif_type; u32 *p_int_mask; };
struct sk_buff { void *head; int meta[14], tail[14], have_head, have_tail; };
struct wlan_tx_info { void *pkt; int ringidx,wcid,bssidx,usr_info,tid,is_fixedrate,is_prior,is_sp,hf,amsdu_en; };
struct wifi_ops { void (*set_attach)(void *, bool); void (*txinfo_wrapper)(u8 *,struct wlan_tx_info *); void (*txinfo_set_drop)(u8 *); };
#define HIT_UNBIND_RATE_REACH 7
#define IS_SPACE_AVAILABLE_HEAD(s) ((s)->have_head)
#define IS_SPACE_AVAILABLE_TAIL(s) ((s)->have_tail)
#define FOE_AI(s) ((s)->meta[0])
#define FOE_AI_TAIL(s) ((s)->tail[0])
#define FOE_WDMA_ID(s) ((s)->meta[1])
#define FOE_RX_ID(s) ((s)->meta[2])
#define FOE_WC_ID(s) ((s)->meta[3])
#define FOE_BSS_ID(s) ((s)->meta[4])
#define FOE_WDMA_ID_TAIL(s) ((s)->tail[1])
#define FOE_RX_ID_TAIL(s) ((s)->tail[2])
#define FOE_WC_ID_TAIL(s) ((s)->tail[3])
#define FOE_BSS_ID_TAIL(s) ((s)->tail[4])
struct wifi_entry { struct wifi_hw hw; struct wifi_ops *ops; };
struct wdma_entry { int wdma_rx_port, wdma_tx_port; unsigned long base_phy_addr, base_addr; struct platform_device *pdev; void *warp, *sw_conf; int ver, res_ctrl; };
struct wed_entry { void *warp, *sw_conf; int irq, ver, sub_ver, branch, hw_cap; };
struct warp_entry { int idx, sw_conf; struct wifi_entry wifi; struct platform_driver pdriver; struct wdma_entry wdma; struct wed_entry wed; struct platform_device *pdev; struct { int fwdl_ctrl; } woif; };
struct warp_ctrl { int warp_driver_idx; };
struct warp_bus { int x; };
static struct warp_entry entry;
static struct platform_device device;
static struct warp_ctrl ctrl;
static struct warp_bus bus;
static struct device_node node;
static int warp_of_ids[3][2];
static int rcu_depth, rx_calls, tx_calls, rx_error, tx_error, change_tx;
static int state_calls, state_error, of_gets, of_puts, maps, rings;
static int node_missing, resource_error, map_error, dma_error, wed_error;
static int reg_error, no_match, withdraw_at_probe, reg_calls, unreg_calls;
static int refs, global_proc, wed_live, wed_proc, rx_proc, wdma_proc, irqs, wifi_probes, attaches, releases, msgs;
static unsigned checks;
static struct sk_buff skb;
static struct sk_buff *tx_packet;
static int tx_hook_calls, tx_hook_ret, drops;
static int (*ra_sw_nat_hook_tx)(struct sk_buff *, int);
static int (*hnat_get_wdma_rx_port)(int);
static int (*hnat_get_wdma_tx_port)(int);
static int (*hnat_set_wdma_pse_port_state)(int, bool);
static void rcu_read_lock(void) { assert(rcu_depth==0); rcu_depth++; }
static void rcu_read_unlock(void) { assert(rcu_depth==1); rcu_depth--; }
static int tx_hook_provider(struct sk_buff *s,int port) {
 assert(rcu_depth==1 && s==&skb); (void)port; tx_hook_calls++;
 ra_sw_nat_hook_tx=NULL;
 return tx_hook_ret;
}
static void tx_wrapper(u8 *t,struct wlan_tx_info *i) { (void)t; assert(rcu_depth==0); i->pkt=tx_packet; i->ringidx=2; }
static void tx_drop(u8 *t) { (void)t; assert(rcu_depth==1); drops++; }
/* The actual debug helper was separately read: only packet fields and printk. */
static void wifi_dump_skb(u8 idx,struct wlan_tx_info *info,struct sk_buff *s)
{ (void)idx; (void)info; (void)s; assert(rcu_depth==1); }
static int rx_provider(int idx) {
 assert(rcu_depth==1); rx_calls++;
 if(change_tx) hnat_get_wdma_tx_port=NULL;
 return rx_error ? rx_error : 8+idx;
}
static int tx_provider(int idx) { assert(rcu_depth==1); tx_calls++; return tx_error ? tx_error : 3+idx; }
static int state_provider(int idx, bool up) {
 assert(rcu_depth==1); (void)idx; (void)up; state_calls++;
 hnat_set_wdma_pse_port_state=NULL;
 return state_error;
}
static struct device_node *of_find_compatible_node(void *a, void *b, const char *c)
{ (void)a; (void)b; (void)c; of_gets++; return node_missing ? NULL : &node; }
static int of_address_to_resource(struct device_node *n, int idx, struct resource *r)
{ (void)n; (void)idx; r->start=0x1000; return resource_error; }
static void of_node_put(struct device_node *n) { assert(n==&node); of_puts++; }
static void *of_iomap(struct device_node *n, int idx)
{ (void)n; (void)idx; if(map_error)return NULL; maps++; return (void *)0x1000; }
static int wdma_ring_init(struct wdma_entry *w) { (void)w; rings++; return 0; }
static struct warp_ctrl *warp_ctrl_get(void) { return &ctrl; }
static struct warp_bus *warp_bus_get(void) { return &bus; }
static struct warp_entry *warp_entry_assign_by_pdev(struct platform_device *p)
{ entry.pdev=p; return &entry; }
#define warp_entry_release_pdev(w) ((w)->pdev=NULL)
#define to_wifi_entry(hwptr) ((struct wifi_entry *)((char *)(hwptr)-offsetof(struct wifi_entry,hw)))
#define to_warp_entry(wptr) ((struct warp_entry *)((char *)(wptr)-offsetof(struct warp_entry,wifi)))
static void warp_entry_release(struct warp_entry *w) { w->wifi.hw.priv=NULL; memset(&w->pdriver,0,sizeof(w->pdriver)); releases++; }
static void warp_increase_ref(void) { refs++; }
static void warp_decrease_ref(void) { assert(refs>0); refs--; }
static int warp_entry_proc_init(struct warp_ctrl *c, struct warp_entry *w) { (void)c; (void)w; global_proc++; return 0; }
static void warp_entry_proc_exit(struct warp_ctrl *c, struct warp_entry *w) { (void)c; (void)w; assert(global_proc==1); global_proc--; }
static int warp_set_dma_mask(struct platform_device *p, struct wifi_hw *h) { (void)p; (void)h; return dma_error; }
static void warp_mtable_build_hw(struct warp_entry *w) { (void)w; }
static int wed_init(struct platform_device *p, u8 idx, struct wed_entry *w) { (void)p; (void)idx; if(wed_error)return wed_error; wed_live++; w->ver=3; return 0; }
static int wed_entry_proc_init(struct warp_entry *e, struct wed_entry *w) { (void)e; (void)w; wed_proc++; return 0; }
static int rxbm_proc_init(struct warp_entry *e, struct wed_entry *w) { (void)e; (void)w; rx_proc++; return 0; }
static void wed_entry_proc_exit(struct warp_entry *e, struct wed_entry *w) { (void)e; (void)w; assert(wed_proc==1); wed_proc--; }
static void rxbm_proc_exit(struct warp_entry *e, struct wed_entry *w) { (void)e; (void)w; assert(rx_proc==1); rx_proc--; }
static void wed_exit(struct platform_device *p, struct wed_entry *w) { (void)p; assert(wed_live==1); wed_live--; memset(w,0,sizeof(*w)); }
static int wdma_entry_proc_init(struct warp_entry *e, struct wdma_entry *w) { (void)e; (void)w; wdma_proc++; return 0; }
static int wifi_chip_set_irq(struct wifi_entry *w, int op, int irq) { (void)w; (void)op; (void)irq; irqs++; return 0; }
static int warp_bus_msi_set(struct warp_entry *w, struct warp_bus *b, u8 on) { (void)w; (void)b; (void)on; return 0; }
static void wifi_chip_probe(struct wifi_entry *w, int irq, int ver, int sub, int branch, int cap)
{ (void)w; (void)irq; (void)ver; (void)sub; (void)branch; (void)cap; wifi_probes++; }
static void warp_pdma_mask_set_hw(struct wed_entry *w, u32 mask) { (void)w; (void)mask; }
static void warp_bus_set_hw(struct wed_entry *w, struct warp_bus *b, int i, int m, int h) { (void)w; (void)b; (void)i; (void)m; (void)h; }
static void warp_wifi_set_hw(struct wed_entry *w, struct wifi_entry *f) { (void)w; (void)f; }
static void set_attach(void *p, bool on) { (void)p; attaches+=on ? 1 : -1; }
static void warp_msg_init(int i) { (void)i; msgs++; }
static void warp_msg_deinit(int i) { (void)i; assert(msgs==1); msgs--; }
static int woif_init(struct warp_entry *w, struct warp_bus *b) { (void)w; (void)b; return 0; }
static void warp_fwdl_get_wo_heartbeat(void *p,u32 *v,int i) { (void)p; (void)v; (void)i; }
static void warp_wo_pc_lr_cr_dump(int i) { (void)i; }
static void warp_remove(struct platform_device *p) { (void)p; assert(!"failed probe must never call full remove"); }
static int platform_driver_register(struct platform_driver *p) {
 int ret;
 reg_calls++; assert(p->driver.probe_type==PROBE_FORCE_SYNCHRONOUS);
 if(reg_error)return reg_error;
 if(no_match)return 0;
 if(withdraw_at_probe)hnat_get_wdma_rx_port=NULL;
 device.dev.driver=&p->driver;
 ret=p->probe(&device);
 if(ret)device.dev.driver=NULL;
 return 0; /* Linux driver registration is distinct from probe success. */
}
static void platform_driver_unregister(struct platform_driver *p) {
 (void)p; unreg_calls++;
 assert(device.dev.driver==NULL); /* Only failed/no-match registrations reach this stub. */
}
/* DRIVER_FUNCTIONS */
#define CHECK(x) do { checks++; assert(x); } while(0)
static void reset(void) {
 static u32 mask;
 memset(&entry,0,sizeof(entry)); memset(&device,0,sizeof(device)); memset(&ctrl,0,sizeof(ctrl));
 rcu_depth=rx_calls=tx_calls=rx_error=tx_error=change_tx=0;
 state_calls=state_error=of_gets=of_puts=maps=rings=0;
 node_missing=resource_error=map_error=dma_error=wed_error=0;
 reg_error=no_match=withdraw_at_probe=reg_calls=unreg_calls=0;
 refs=global_proc=wed_live=wed_proc=rx_proc=wdma_proc=irqs=wifi_probes=attaches=releases=msgs=0;
 memset(&skb,0,sizeof(skb)); skb.head=&skb; skb.have_head=1; skb.have_tail=1;
 skb.meta[0]=HIT_UNBIND_RATE_REACH;
 tx_packet=&skb; tx_hook_calls=drops=0; tx_hook_ret=1; ra_sw_nat_hook_tx=tx_hook_provider;
 hnat_get_wdma_rx_port=rx_provider; hnat_get_wdma_tx_port=tx_provider;
 hnat_set_wdma_pse_port_state=state_provider;
 entry.wifi.hw.priv=&entry; entry.wifi.hw.p_int_mask=&mask;
 entry.wdma.wdma_rx_port=77; entry.wdma.wdma_tx_port=78;
}
static void check_unwound(void) {
 CHECK(refs==0 && global_proc==0 && wed_live==0 && wed_proc==0 && rx_proc==0 && msgs==0);
 CHECK(wdma_proc==0 && irqs==0 && wifi_probes==0 && attaches==0 && maps==0 && rings==0);
 CHECK(entry.pdev==NULL && entry.wifi.hw.priv==NULL && releases==1 && rcu_depth==0);
}
static void callback_tests(void) {
 reset(); hnat_get_wdma_rx_port=NULL;
 CHECK(warp_get_wdma_port(&entry.wdma,0)==-ENODEV); CHECK(rx_calls==0 && tx_calls==0 && rcu_depth==0);
 CHECK(entry.wdma.wdma_rx_port==77 && entry.wdma.wdma_tx_port==78);
 reset(); hnat_get_wdma_tx_port=NULL;
 CHECK(warp_get_wdma_port(&entry.wdma,0)==-ENODEV); CHECK(rx_calls==0 && tx_calls==0 && rcu_depth==0);
 reset(); rx_error=-EINVAL;
 CHECK(warp_get_wdma_port(&entry.wdma,0)==-EINVAL); CHECK(rx_calls==1 && tx_calls==0 && rcu_depth==0);
 CHECK(entry.wdma.wdma_rx_port==77 && entry.wdma.wdma_tx_port==78);
 reset(); tx_error=-EIO;
 CHECK(warp_get_wdma_port(&entry.wdma,0)==-EIO); CHECK(rx_calls==1 && tx_calls==1 && rcu_depth==0);
 CHECK(entry.wdma.wdma_rx_port==77 && entry.wdma.wdma_tx_port==78);
 reset(); change_tx=1;
 CHECK(warp_get_wdma_port(&entry.wdma,1)==0); CHECK(hnat_get_wdma_tx_port==NULL && tx_calls==1 && rcu_depth==0);
 CHECK(entry.wdma.wdma_rx_port==9 && entry.wdma.wdma_tx_port==4);
 reset(); hnat_set_wdma_pse_port_state=NULL;
 CHECK(wdma_pse_port_config_state(0,true)==-EOPNOTSUPP); CHECK(state_calls==0 && rcu_depth==0);
 reset(); state_error=-ENODEV;
 CHECK(wdma_pse_port_config_state(0,true)==-ENODEV); CHECK(state_calls==1 && rcu_depth==0);
 reset(); CHECK(wdma_pse_port_config_state(1,false)==0); CHECK(state_calls==1 && rcu_depth==0);
}
static void init_tests(void) {
 reset(); hnat_get_wdma_rx_port=NULL;
 CHECK(wdma_init(&device,0,&entry.wdma,3)==-ENODEV); CHECK(of_gets==0 && maps==0 && rings==0);
 reset(); node_missing=1;
 CHECK(wdma_init(&device,0,&entry.wdma,3)==-ENODEV); CHECK(of_puts==0 && maps==0 && rings==0);
 reset(); resource_error=-EINVAL;
 CHECK(wdma_init(&device,0,&entry.wdma,3)==-ENODEV); CHECK(of_puts==1 && maps==0 && rings==0);
 reset(); map_error=1;
 CHECK(wdma_init(&device,0,&entry.wdma,3)==-ENOMEM); CHECK(of_puts==1 && maps==0 && rings==0);
 reset(); CHECK(wdma_init(&device,0,&entry.wdma,3)==0); CHECK(of_puts==1 && maps==1 && rings==1);
}
static void register_tests(void) {
 struct wifi_ops ops={.set_attach=set_attach};
 reset(); CHECK(warp_register_client(NULL,&ops)==-1); CHECK(reg_calls==0 && refs==0);
 reset(); hnat_get_wdma_rx_port=NULL;
 CHECK(warp_register_client(&entry.wifi.hw,&ops)==-1); CHECK(reg_calls==0 && unreg_calls==0); check_unwound();
 reset(); withdraw_at_probe=1;
 CHECK(warp_register_client(&entry.wifi.hw,&ops)==-1); CHECK(reg_calls==1 && unreg_calls==1); check_unwound();
 reset(); reg_error=-EBUSY;
 CHECK(warp_register_client(&entry.wifi.hw,&ops)==-1); CHECK(reg_calls==1 && unreg_calls==0); check_unwound();
 reset(); no_match=1;
 CHECK(warp_register_client(&entry.wifi.hw,&ops)==-1); CHECK(reg_calls==1 && unreg_calls==1); check_unwound();
 reset(); dma_error=-EIO;
 CHECK(warp_register_client(&entry.wifi.hw,&ops)==-1); CHECK(of_gets==0); check_unwound();
 reset(); wed_error=-EINVAL;
 CHECK(warp_register_client(&entry.wifi.hw,&ops)==-1); CHECK(of_gets==0); check_unwound();
 reset(); node_missing=1;
 CHECK(warp_register_client(&entry.wifi.hw,&ops)==-1); check_unwound();
 reset(); resource_error=-EINVAL;
 CHECK(warp_register_client(&entry.wifi.hw,&ops)==-1); CHECK(of_puts==1); check_unwound();
 reset(); map_error=1;
 CHECK(warp_register_client(&entry.wifi.hw,&ops)==-1); CHECK(of_puts==1); check_unwound();
 reset(); CHECK(warp_register_client(&entry.wifi.hw,&ops)==0);
 CHECK(refs==1 && global_proc==1 && wed_live==1 && wed_proc==1 && rx_proc==1);
 CHECK(maps==1 && rings==1 && irqs==1 && wifi_probes==1 && attaches==1 && releases==0);
 CHECK(device.dev.driver==&entry.pdriver.driver && unreg_calls==0 && rcu_depth==0);
}
static void tx_hook_tests(void) {
 struct wifi_ops ops={.txinfo_wrapper=tx_wrapper,.txinfo_set_drop=tx_drop};
 reset(); entry.wifi.ops=&ops; ra_sw_nat_hook_tx=NULL;
 CHECK(wifi_tx_tuple_add(&entry.wifi,0,NULL,8)==0); CHECK(rcu_depth==0 && tx_hook_calls==0 && drops==0);
 reset(); entry.wifi.ops=&ops; tx_packet=NULL;
 CHECK(wifi_tx_tuple_add(&entry.wifi,0,NULL,8)==-EFAULT); CHECK(rcu_depth==0 && tx_hook_calls==0);
 reset(); entry.wifi.ops=&ops; skb.head=NULL;
 CHECK(wifi_tx_tuple_add(&entry.wifi,0,NULL,8)==-EFAULT); CHECK(rcu_depth==0 && tx_hook_calls==0);
 reset(); entry.wifi.ops=&ops;
 CHECK(wifi_tx_tuple_add(&entry.wifi,1,NULL,9)==0);
 CHECK(rcu_depth==0 && tx_hook_calls==1 && drops==0 && ra_sw_nat_hook_tx==NULL);
 CHECK(skb.meta[1]==1 && skb.tail[1]==1 && skb.meta[2]==2);
 reset(); entry.wifi.ops=&ops; tx_hook_ret=0;
 CHECK(wifi_tx_tuple_add(&entry.wifi,0,NULL,8)==0); CHECK(rcu_depth==0 && tx_hook_calls==1 && drops==1);
}
int main(void) { callback_tests(); init_tests(); register_tests(); tx_hook_tests(); printf("PASS: %u checks\n",checks); return 0; }

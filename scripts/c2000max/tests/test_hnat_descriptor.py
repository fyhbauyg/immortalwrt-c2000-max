#!/usr/bin/env python3
"""Exercise actual HNAT hook bodies with explicit kernel/device mocks.

Use --source with the kernel's prepared hnat_nf_hook.c and --header with its
nf_hnat_mtk.h. This is a logic regression test, not a packet or performance test.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

PREFIX=r'''
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <arpa/inet.h>
typedef uint32_t u32;
#define __packed __attribute__((packed))

#define CONFIG_MEDIATEK_NETSYS_V3 1
'''
MOCKS=r'''
#define NF_DROP 0
#define NF_ACCEPT 1
#define NF_BR_LOCAL_OUT 3
#define NF_BR_POST_ROUTING 4
#define IS_ENABLED(x) 1
#define unlikely(x) (x)
#define READ_ONCE(x) (x)
#define BIT(x) (1UL << (x))
#define KERN_WARNING ""
#define trace_printk(...) ((void)0)
#define pr_debug(...) ((void)0)
#define printk_ratelimited(...) ((void)0)
#define HNAT_MAGIC_TAG 0x6789
#define HNAT_EXCEPTION_TAG 0x00800000
#define ETH_ALEN 6
#define ETH_P_IP 0x0800
#define ETH_P_IPV6 0x86DD
#define IPVERSION_V4 4
#define IPVERSION_V6 6
#define DEV_PATH_TNL 1
#define TCP_FIN_SYN_RST 0x0d
#define HIT_UNBIND_RATE_REACH 0x0f
#define HIT_BIND_KEEPALIVE_DUP_OLD_HDR 0x15
#define HIT_BIND_MULTICAST_TO_CPU 0x18
#define HIT_BIND_MULTICAST_TO_GMAC_CPU 0x19
#define FIN 3
#define BIND 2
#define MTK_HNAT_V1_3 3
#define IPV6_6RD 5
#define IPV4_DSLITE 3
#define IPV4_MAP_E 7
#define IPV6_HDR_LEN 40
#define NEXTHDR_IPIP IPPROTO_IPIP
#define FOE_INFO_LEN 16
#define IS_GMAC1_MODE 0
#define IS_HNAT_API_SUPPORTED(e) 0
struct flow_offload_hw_path;
struct sk_buff;
struct net_device;
struct net_device_ops {
    struct net_device *(*ndo_get_xmit_slave)(struct net_device *, struct sk_buff *, bool);
    int (*ndo_flow_offload_check)(struct flow_offload_hw_path *);
};
struct net_device { const char *name; const struct net_device_ops *netdev_ops; int group; };
struct ethhdr { unsigned char h_dest[6], h_source[6]; uint16_t h_proto; };
struct iphdr { int version, protocol, ihl; unsigned tos; uint32_t saddr, daddr; uint16_t frag_off; };
struct ipv6hdr { unsigned nexthdr; };
struct tcpudphdr { uint16_t src, dst; };
struct sk_buff { unsigned char *head; unsigned char cb[48]; unsigned mark, protocol; int skb_iif;
    bool cloned, shared, cow_fails, bridge_info; unsigned headroom;
    struct ethhdr eth; struct iphdr ip, inner_ip; struct ipv6hdr ip6;
    struct tcpudphdr ports;
    struct net_device *dev; };
struct nf_hook_state { unsigned hook; const struct net_device *in, *out; };
struct flow_offload_hw_path { struct net_device *virt_dev, *dev; unsigned long flags;
    unsigned tnl_type; unsigned char eth_dest[6], eth_src[6]; };
struct foe_entry { struct { unsigned state, sta, udp, pkt_type; } bfib1; struct {unsigned pkt_type;} udib1;
    struct { unsigned m_timestamp; } ipv4_hnapt;
    struct { struct { unsigned dscp; } iblk2; } ipv4_dslite;
    struct { uint32_t new_sip, new_dip; uint16_t new_sport, new_dport; } ipv4_mape; };
struct mock_data { int per_flow_accounting, version; };
struct mock_hnat { struct mock_data *data; struct foe_entry *foe_table_cpu[1]; };
static struct mock_data data = {1, 5};
static struct foe_entry entries[2];
static struct mock_hnat priv = { &data, { entries } };
static struct mock_hnat *hnat_priv = &priv;
static int debug_level, xlat_toggle, mcast_hook_toggle;
static int bind_calls, acct_calls, dscp_calls, mape_toggle;
static int (*mtk_tnl_encap_offload)(struct sk_buff *, struct ethhdr *);
static void (*hnat_fin_callback)(struct sk_buff *);
#define skb_hnat_info(s) ((struct hnat_desc *)((s)->head))
#define skb_hnat_magic_tag(s) (skb_hnat_info(s)->magic_tag_protect)
#define is_magic_tag_valid(s) (skb_hnat_magic_tag(s) == HNAT_MAGIC_TAG)
#define skb_hnat_reason(s) (skb_hnat_info(s)->crsn)
#define skb_hnat_entry(s) (skb_hnat_info(s)->entry)
#define skb_hnat_alg(s) (skb_hnat_info(s)->alg)
#define skb_hnat_tops(s) (skb_hnat_info(s)->tops)
#define skb_hnat_iface(s) (skb_hnat_info(s)->iface)
#define skb_hnat_sport(s) (skb_hnat_info(s)->sport)
#define skb_hnat_set_tops(s,v) (skb_hnat_tops(s) = (v))
#define skb_hnat_is_encap(s) (!skb_hnat_info(s)->is_decap)
#define skb_hnat_is_decap(s) (skb_hnat_info(s)->is_decap)
#define skb_hnat_cdrt(s) (skb_hnat_info(s)->cdrt)
#define skb_hnat_is_encrypt(s) (!skb_hnat_info(s)->is_decrypt)
#define skb_headroom(s) ((s)->headroom)
#define skb_hnat_ppe(s) 0
#define skb_hnat_is_hashed(s) (skb_hnat_entry(s) < 2)
#define HNAT_SKB_CB2(s) ((struct {uint32_t magic;} *)(&(s)->cb[44]))
#define IS_SPACE_AVAILABLE_HEAD(s) 1
#define skb_mac_header_was_set(s) 1
#define netif_is_bond_master(d) 0
#define netif_is_bridge_master(d) 0
#define IS_LAN_GRP(d) ((d)->group == 1)
#define IS_WAN(d) ((d)->group == 2)
#define IS_EXT(d) ((d)->group == 3)
#define IS_DSA_LAN(d) 0
#define eth_hdr(s) (&(s)->eth)
#define ip_hdr(s) (&(s)->ip)
#define ipv6_hdr(s) (&(s)->ip6)
static const void *skb_header_pointer(struct sk_buff *s, unsigned offset, unsigned length, void *buffer) {
    return offset == IPV6_HDR_LEN ? (const void *)&s->inner_ip : (const void *)&s->ports;
}
static int ip_is_fragment(const struct iphdr *ip) { return ip->frag_off != 0; }
#define entry_hnat_is_bound(e) ((e)->bfib1.state == BIND)
#define skb_shared(s) ((s)->shared)
#define nf_bridge_info_exists(s) ((s)->bridge_info)
static int skb_cow_head(struct sk_buff *s, int unused) {
    if (s->cow_fails) return -1;
    if (s->cloned) { unsigned char *h = malloc(sizeof(struct hnat_desc));
        memcpy(h, s->head, sizeof(struct hnat_desc)); s->head=h; s->cloned=false; }
    return 0;
}
static int hnat_datapath_ready(void) { return 1; }
static int mtk_464xlat_post_process(struct sk_buff *s, const struct net_device *d) { return 1; }
static int mtk_hnat_accel_type(struct sk_buff *s) { return 1; }
static unsigned foe_timestamp(struct mock_hnat *h, bool b) { return 0; }
static void hnat_trigger_callback(void (*cb)(struct sk_buff *), struct sk_buff *s) { cb(s); }
static void skb_to_hnat_info(struct sk_buff *s,const struct net_device *d,struct foe_entry *e,struct flow_offload_hw_path *p) { bind_calls++; }
static void mtk_hnat_update_acct_ifindex(struct sk_buff *s,bool b) { acct_calls++; }
static void hnat_get_count(struct mock_hnat *h,unsigned p,unsigned e,void *n) {}
static void mtk_hnat_dscp_update(struct sk_buff *s,struct foe_entry *e) { dscp_calls++; }
static void post_routing_print(struct sk_buff *s,const struct net_device *i,const struct net_device *o,const char *f) {}
static int hnat_ipv4_get_nexthop(struct sk_buff *s,const struct net_device *d,struct flow_offload_hw_path *p) { return 0; }
static int hnat_ipv6_get_nexthop(struct sk_buff *s,const struct net_device *d,struct flow_offload_hw_path *p) { return 0; }
static void hnat_set_alg(const struct nf_hook_state *st,struct sk_buff *s,int v) { skb_hnat_alg(s)=v; }
static void hnat_set_head_frags(const struct nf_hook_state *st,struct sk_buff *s,int v,
    void (*fn)(const struct nf_hook_state *,struct sk_buff *,int)) { fn(st,s,v); }
'''
TESTS=r'''
static unsigned checked, failed;
#define CHECK(name, condition) do { checked++; if (!(condition)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", name, __LINE__); } } while (0)
static void init(struct sk_buff *s, struct hnat_desc *d, struct net_device *dev) {
    memset(s, 0, sizeof(*s)); memset(d, 0, sizeof(*d)); memset(entries, 0, sizeof(entries));
    d->magic_tag_protect=HNAT_MAGIC_TAG; d->iface=1; d->crsn=HIT_UNBIND_RATE_REACH;
    s->head=(unsigned char *)d; s->dev=dev; s->headroom=64; s->skb_iif=10;
    s->ip.version=4; s->inner_ip.ihl=5; s->inner_ip.protocol=IPPROTO_UDP;
    bind_calls=acct_calls=dscp_calls=0;
}
static void release(struct sk_buff *s, struct hnat_desc *d) { if (s->head != (unsigned char *)d) free(s->head); }
int main(void) {
    struct net_device_ops ops={0}; struct net_device lan={"eth1", &ops, 1};
    struct nf_hook_state st={NF_BR_POST_ROUTING, NULL, &lan};
    unsigned (*hooks[])(void *,struct sk_buff *,const struct nf_hook_state *)={
        mtk_hnat_br_nf_local_out, mtk_hnat_ipv4_nf_post_routing, mtk_hnat_ipv6_nf_post_routing};
    const char *names[]={"bridge","ipv4","ipv6"};
    const struct { const char *name; unsigned reason, iface, verdict; bool clone, shared, fail, bound; } cases[]={
        {"stale_keepalive", HIT_BIND_KEEPALIVE_DUP_OLD_HDR, 0, NF_ACCEPT, false,false,false,true},
        {"stale_multicast", HIT_BIND_MULTICAST_TO_CPU, 0, NF_ACCEPT, false,false,false,true},
        {"stale_unbind", HIT_UNBIND_RATE_REACH, 0, NF_ACCEPT, false,false,false,false},
        {"stale_clone", HIT_BIND_KEEPALIVE_DUP_OLD_HDR, 0, NF_ACCEPT, true,false,false,true},
        {"stale_shared_skb", HIT_BIND_KEEPALIVE_DUP_OLD_HDR, 0, NF_DROP, true,true,false,true},
        {"stale_cow_failure", HIT_BIND_KEEPALIVE_DUP_OLD_HDR, 0, NF_DROP, true,false,true,true},
        {"valid_bound_keepalive", HIT_BIND_KEEPALIVE_DUP_OLD_HDR, 1, NF_DROP, false,false,false,true},
        {"valid_bound_keepalive_clone", HIT_BIND_KEEPALIVE_DUP_OLD_HDR, 1, NF_DROP, true,false,false,true},
        {"valid_keepalive_shared_skb", HIT_BIND_KEEPALIVE_DUP_OLD_HDR, 1, NF_DROP, true,true,false,true},
        {"valid_keepalive_cow_failure", HIT_BIND_KEEPALIVE_DUP_OLD_HDR, 1, NF_DROP, true,false,true,true},
        {"valid_unbound_keepalive", HIT_BIND_KEEPALIVE_DUP_OLD_HDR, 1, NF_ACCEPT, false,false,false,false},
        {"valid_multicast_cpu", HIT_BIND_MULTICAST_TO_CPU, 1, NF_DROP, false,false,false,true},
        {"valid_multicast_gmac", HIT_BIND_MULTICAST_TO_GMAC_CPU, 1, NF_DROP, false,false,false,true},
        {"valid_multicast_clone", HIT_BIND_MULTICAST_TO_CPU, 1, NF_DROP, true,false,false,true},
        {"valid_port_zero", TCP_FIN_SYN_RST, 1, NF_ACCEPT, false,false,false,true},
        {"valid_unbind", HIT_UNBIND_RATE_REACH, 1, NF_ACCEPT, false,false,false,false},
    };
    for (unsigned h=0;h<3;h++) for (unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++) {
        struct sk_buff s; struct hnat_desc d; init(&s,&d,&lan);
        d.crsn=cases[i].reason; d.iface=cases[i].iface;
        s.cloned=cases[i].clone; s.shared=cases[i].shared; s.cow_fails=cases[i].fail;
        if (!d.iface) { d.entry=32767; d.tops=1; d.cdrt=1; s.skb_iif=0; }
        entries[0].bfib1.state=cases[i].bound ? BIND : 0;
        struct sk_buff sibling=s; unsigned v=hooks[h](NULL,&s,&st);
        char name[160]; snprintf(name,sizeof(name),"%s/%s",names[h],cases[i].name);
        CHECK(name, v==cases[i].verdict);
        if (!cases[i].iface) {
            CHECK("stale packet must never touch hardware accounting/binding", !bind_calls && !acct_calls && !dscp_calls);
            if (v==NF_ACCEPT) { struct hnat_desc zero={0}; CHECK("clear all stale descriptor fields", !memcmp(s.head,&zero,sizeof(zero))); }
        }
        if (cases[i].clone) CHECK("preserve sibling head", skb_hnat_magic_tag(&sibling)==HNAT_MAGIC_TAG);
        if (cases[i].reason==HIT_BIND_KEEPALIVE_DUP_OLD_HDR && cases[i].iface && cases[i].bound && !cases[i].shared && !cases[i].fail)
            CHECK("bound keepalive descriptor cleared while still dropped", !skb_hnat_magic_tag(&s));
        if (cases[i].reason==HIT_UNBIND_RATE_REACH && cases[i].iface) CHECK("ordinary valid flow still binds", bind_calls==1);
        printf("%s verdict=%s\n",name,v==NF_ACCEPT?"ACCEPT":"DROP"); release(&s,&d);
    }
    for (unsigned iface=0;iface<=1;iface++) for (unsigned clone=0;clone<=1;clone++) {
        struct sk_buff s; struct hnat_desc d; init(&s,&d,&lan); d.iface=iface; d.tops=1; d.cdrt=1; s.cloned=clone;
        struct sk_buff sibling=s; unsigned v=mtk_hnat_nf_local_out_sanitize(NULL,&s,&st);
        CHECK("sanitize verdict",v==NF_ACCEPT);
        CHECK("sanitize preserves only valid ingress metadata",skb_hnat_magic_tag(&s)==(iface?HNAT_MAGIC_TAG:0));
        if (clone) CHECK("sanitize sibling ownership",skb_hnat_magic_tag(&sibling)==HNAT_MAGIC_TAG);
        release(&s,&d);
    }
    for (unsigned reset_iif=0;reset_iif<=1;reset_iif++) {
        struct sk_buff s; struct hnat_desc d; init(&s,&d,&lan); s.ip.protocol=IPPROTO_IPV6; s.skb_iif=reset_iif?0:10;
        CHECK("6rd sanitizer",mtk_hnat_nf_local_out_sanitize(NULL,&s,&st)==NF_ACCEPT);
        mtk_hnat_ipv4_nf_local_out(NULL,&s,&st); mtk_hnat_br_nf_local_out(NULL,&s,&st);
        CHECK("forwarded 6rd keeps descriptor and binds",skb_hnat_magic_tag(&s)==HNAT_MAGIC_TAG && entries[0].udib1.pkt_type==IPV6_6RD && bind_calls==1);
        printf("6rd/%s bind_calls=%d\n",reset_iif?"scrubbed_iif":"ingress_iif",bind_calls);
    }
    for (unsigned map=0;map<=1;map++) {
        struct sk_buff s; struct hnat_desc d; init(&s,&d,&lan); s.skb_iif=0; s.ip6.nexthdr=NEXTHDR_IPIP;
        s.inner_ip.tos=32; s.inner_ip.saddr=htonl(0xc0000201); s.inner_ip.daddr=htonl(0xc6336402);
        s.ports.src=htons(1234); s.ports.dst=htons(443); mape_toggle=map;
        CHECK("IPv6 tunnel sanitizer",mtk_hnat_nf_local_out_sanitize(NULL,&s,&st)==NF_ACCEPT);
        mtk_hnat_ipv6_nf_local_out(NULL,&s,&st); mtk_hnat_ipv6_nf_post_routing(NULL,&s,&st);
        CHECK("IPv6 tunnel keeps metadata and binds",skb_hnat_magic_tag(&s)==HNAT_MAGIC_TAG && entries[0].bfib1.pkt_type==(map?IPV4_MAP_E:IPV4_DSLITE) && bind_calls==1);
        if (map) CHECK("MAP-E inner tuple retained",entries[0].ipv4_mape.new_sip==0xc0000201 && entries[0].ipv4_mape.new_dip==0xc6336402 && entries[0].ipv4_mape.new_sport==1234 && entries[0].ipv4_mape.new_dport==443 && entries[0].bfib1.udp==1);
        printf("%s/scrubbed_iif bind_calls=%d\n",map?"MAP-E":"DS-Lite",bind_calls);
    }
    for (unsigned tops=0;tops<=1;tops++) {
        struct sk_buff s; struct hnat_desc d; init(&s,&d,&lan); s.skb_iif=0; s.ip.protocol=IPPROTO_UDP; d.tops=tops; d.cdrt=!tops;
        CHECK("encrypted/tunnel sanitizer",mtk_hnat_nf_local_out_sanitize(NULL,&s,&st)==NF_ACCEPT);
        mtk_hnat_ipv4_nf_local_out(NULL,&s,&st); mtk_hnat_br_nf_local_out(NULL,&s,&st);
        CHECK("TOPS/CDRT retains descriptor and binds",skb_hnat_magic_tag(&s)==HNAT_MAGIC_TAG && bind_calls==1);
    }
    for (unsigned family=0;family<=1;family++) {
        struct sk_buff s; struct hnat_desc d; init(&s,&d,&lan); d.iface=0; d.tops=1; d.cdrt=1;
        s.ip.protocol=IPPROTO_IPV6; s.ip6.nexthdr=NEXTHDR_IPIP;
        CHECK("stale outer tunnel header sanitizer",mtk_hnat_nf_local_out_sanitize(NULL,&s,&st)==NF_ACCEPT);
        if (family) mtk_hnat_ipv6_nf_local_out(NULL,&s,&st); else mtk_hnat_ipv4_nf_local_out(NULL,&s,&st);
        CHECK("stale outer tunnel header cannot change FOE",!entries[0].udib1.pkt_type && !entries[0].bfib1.pkt_type && !skb_hnat_magic_tag(&s));
    }
    {
        struct sk_buff s; struct hnat_desc d; init(&s,&d,&lan); d.iface=0; s.headroom=0;
        CHECK("short headroom ignored",mtk_hnat_nf_local_out_sanitize(NULL,&s,&st)==NF_ACCEPT && skb_hnat_magic_tag(&s)==HNAT_MAGIC_TAG);
        CHECK("null skb ignored",mtk_hnat_nf_local_out_sanitize(NULL,NULL,&st)==NF_ACCEPT);
    }
    printf("RESULT checks=%u failures=%u\n",checked,failed); return failed?1:0;
}
'''

def extract_function(source, name):
    match=re.search(r'(?:static (?:unsigned int|bool)\s+)'+name+r'\(', source)
    if not match:
        raise ValueError('Missing function: '+name)
    start=source.index('{',match.start())
    end=source.index('\n}',start)+2
    return source[match.start():end]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--header',type=Path,required=True)
    parser.add_argument('--cc',default='gcc')
    args=parser.parse_args()
    source=args.source.read_text()
    header=args.header.read_text()
    descriptor='struct hnat_desc {'+header.split('struct hnat_desc {',1)[1].split('#elif',1)[0]
    names=['mtk_hnat_nf_post_routing','hnat_stale_descriptor','mtk_hnat_nf_local_out_sanitize',
           'mtk_hnat_br_nf_local_out','mtk_hnat_ipv4_nf_post_routing','mtk_hnat_ipv6_nf_post_routing',
           'mtk_hnat_ipv4_nf_local_out','mtk_hnat_ipv6_nf_local_out']
    # Check the hook registration as well as calling the functions directly.
    for family in ['NFPROTO_IPV4','NFPROTO_IPV6']:
        assert re.search(r'\.hook = mtk_hnat_nf_local_out_sanitize,\s*\.pf = '+family+
                         r',\s*\.hooknum = NF_INET_LOCAL_OUT,\s*\.priority = NF_IP_PRI_FIRST,',source)
    with tempfile.TemporaryDirectory(prefix='hnat-descriptor-test-') as temp:
        cfile=Path(temp)/'test.c'; executable=Path(temp)/'test'
        cfile.write_text(PREFIX+descriptor+MOCKS+'\n'.join(extract_function(source,n) for n in names)+TESTS)
        subprocess.run([args.cc,'-std=gnu11','-O2','-g','-Wall','-Wextra','-Werror',
                        '-Wno-unused-parameter','-Wno-unused-variable','-Wno-unused-function',
                        '-Wno-implicit-fallthrough',str(cfile),'-o',str(executable)],check=True)
        subprocess.run([str(executable)],check=True)

if __name__=='__main__':
    main()

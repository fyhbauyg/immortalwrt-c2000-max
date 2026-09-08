#!/usr/bin/env python3
"""Check the fully prepared kernel and execute its queue/protocol selection.

This is host-side regression coverage, not a PPE/driver hardware test.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

kernel = pathlib.Path(sys.argv[1]).resolve(strict=True)
eth = kernel / 'drivers/net/ethernet/mediatek'
header = (eth / 'mtk_eth_soc.h').read_text()
source = (eth / 'mtk_hnat/hnat_nf_hook.c').read_text()
mask = re.findall(r'^#define MTK_QDMA_QUEUE_MASK\s+(.+)$', header, re.M)
assert mask == ['(MTK_QDMA_NUM_QUEUES - 1)'], mask
assert '#define MTK_QDMA_NUM_QUEUES\t64' in header
assert '#define MTK_QDMA_NUM_QUEUES\t16' in header
assert source.count('flow_entry = kzalloc(sizeof(*flow_entry), GFP_ATOMIC);') == 1
assert 'flow_entry = kmalloc(sizeof(*flow_entry), GFP_KERNEL);' not in source
assert re.search(r'flow_entry = kzalloc\(sizeof\(\*flow_entry\), GFP_ATOMIC\);\s*'
                 r'if \(!flow_entry\) \{\s*spin_unlock_bh\(&hnat_priv->flow_entry_lock\);\s*return -1;', source)
admission = source.index('static int skb_to_hnat_info(')
begin = source.index('\tif (IS_L2_BRIDGE(&entry)) {\n\t\tif (!l2br_toggle)', admission)
end = source.index('\n\tswitch (h_proto)', begin)
selection = source[begin:end]
assert source.index('HNAT_EXCEPTION_TAG', admission) < begin
assert 'hnat_offload_engine_done(skb, hw_path)' in source[admission:begin]
assert 'entry.l2_bridge.sp_tag = htons(h_proto);' in source[end:]

harness = r'''
#include <assert.h>
#include <stdint.h>
#include <arpa/inet.h>
#include <stdio.h>
#define ETH_P_IP 0x0800
#define ETH_P_IPV6 0x86dd
#define ETH_P_PPP_SES 0x8864
#define IPVERSION_V4 4
#define IPVERSION_V6 6
#define DEV_PATH_PPPOE 0
#define BIT(x) (1u << (x))
#define IS_L2_BRIDGE(e) ((e)->l2)
struct ethhdr { uint16_t h_proto; };
struct iphdr { int version; };
struct ppphdr { uint16_t sid; };
struct sk_buff { struct ethhdr eth; struct iphdr ip; struct ppphdr ppp; int inner; };
struct path { unsigned flags; unsigned pppoe_sid; };
static unsigned ip_reads;
static struct ethhdr *eth_hdr(struct sk_buff *s) { return &s->eth; }
static struct iphdr *ip_hdr(struct sk_buff *s) { ip_reads++; return &s->ip; }
static struct ppphdr *pppoe_hdr(struct sk_buff *s) { return &s->ppp; }
static int hnat_get_hdr_protocol(struct sk_buff *s, int *o) { *o=8; return s->inner; }
static int select_protocol(struct sk_buff *skb, int l2, int l2br_toggle, struct path *hw_path) {
    struct { int l2; } entry = {l2};
    int h_proto = -99, h_offset = 0;
__SELECTION__
    return h_proto;
}
int main(void) {
    /* Every low-16-bit mark, with high flags and uplink direction retained. */
    for (unsigned m=0; m<65536; ++m) {
        assert((m & MTK_QDMA_QUEUE_MASK) < MTK_QDMA_NUM_QUEUES);
        assert((m & MTK_QDMA_QUEUE_MASK) == m % MTK_QDMA_NUM_QUEUES);
        assert(((0x00800000u | m) & MTK_QDMA_QUEUE_MASK) == (m & MTK_QDMA_QUEUE_MASK));
    }
    for (unsigned q=0; q<MTK_QDMA_NUM_QUEUES; ++q) assert((q & MTK_QDMA_QUEUE_MASK) == q);
    for (unsigned up=0; up<MTK_QDMA_NUM_QUEUES; ++up) {
        for (unsigned down=0; down<MTK_QDMA_NUM_QUEUES; ++down) {
            uint32_t ctmark = (up << 16) | down | 0xa5c0f0c0u;
            assert((ctmark & MTK_QDMA_QUEUE_MASK) == down);
            assert(((ctmark >> 16) & MTK_QDMA_QUEUE_MASK) == up);
        }
    }
    if (MTK_QDMA_NUM_QUEUES == 64) {
        for (unsigned q=60; q<=63; ++q) assert((q & MTK_QDMA_QUEUE_MASK) == q);
    }
    for (unsigned proto=0; proto<65536; ++proto) {
        struct sk_buff s = {{htons(proto)}, {0}, {htons(7)}, ETH_P_IPV6};
        struct path p = {0};
        ip_reads=0;
        assert(select_protocol(&s, 1, 0, &p) == -1);
        assert(ip_reads == 0 && p.flags == 0);
        assert(select_protocol(&s, 1, 1, &p) == (int)proto);
        assert(ip_reads == 0 && p.flags == 0);
    }
    struct sk_buff s = {{htons(0x0800)}, {4}, {htons(7)}, ETH_P_IPV6};
    struct path p = {0};
    assert(select_protocol(&s, 0, 0, &p) == ETH_P_IP);
    s.ip.version=6; assert(select_protocol(&s, 0, 0, &p) == ETH_P_IPV6);
    s.ip.version=0; assert(select_protocol(&s, 0, 0, &p) == -1);
    s.eth.h_proto=htons(ETH_P_PPP_SES); ip_reads=0;
    assert(select_protocol(&s, 0, 0, &p) == ETH_P_IPV6);
    assert(ip_reads == 0 && p.flags == BIT(DEV_PATH_PPPOE) && p.pppoe_sid == 7);
    printf("PASS %u queues: all mark values, all L2 EtherTypes/gates, IP/PPPoE\n", MTK_QDMA_NUM_QUEUES);
}
'''.replace('__SELECTION__', selection)
with tempfile.TemporaryDirectory(prefix='c2000max-network-regression-') as task_tmp:
    task_tmp = pathlib.Path(task_tmp)
    test = task_tmp / 'test.c'
    test.write_text(harness)
    for count in (16, 64):
        binary = task_tmp / f'test-{count}'
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                        f'-DMTK_QDMA_NUM_QUEUES={count}', f'-DMTK_QDMA_QUEUE_MASK={mask[0]}',
                        str(test), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
print('PASS prepared WHNAT atomic allocation/failure unlock and preserved admission guard')

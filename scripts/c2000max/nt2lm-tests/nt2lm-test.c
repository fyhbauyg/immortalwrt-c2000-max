/* Host compatibility checks for production functions extracted by run.sh.
 * No device access or radio state is used by these tests. */
#include <assert.h>
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint8_t UINT8;
typedef uint16_t UINT16;
typedef uint32_t UINT32;
typedef uint8_t UCHAR;
typedef unsigned long ULONG;
typedef void *PRTMP_ADAPTER;
#define IN
#define OUT
#define TRUE 1
#define FALSE 0
#define IE_WLAN_EXTENSION 255
#define EID_EXT_EHT_TID2LNK_MAP 109
#define MLD_LINK_MAX 16
#define TID_MAX 8
#define T2LM_BI 2
#define BIT(n) (1U << (n))
#define CAP_BITS_MASK(n) (((1U << n##_BITS) - 1U) << n##_SHIFT)
#define GET_CAP_BITS(n,v) (((v) & n##_MASK) >> n##_SHIFT)
#define SET_CAP_BITS(n,v,x) ((v) = ((v) & ~n##_MASK) | (((x) << n##_SHIFT) & n##_MASK))
#define NdisMoveMemory memcpy
#define NdisCopyMemory memcpy
#define NdisZeroMemory(p,n) memset(p,0,n)
#define cpu_to_le16(x) (x)
#define cpu_to_le32(x) (x)
#define MTWF_DBG(...) ((void)0)
#define hex_dump_with_cat_and_lvl(...) ((void)0)
struct __attribute__((packed)) _EID_STRUCT { u8 Eid, Len, Octet[1]; };
typedef struct _EID_STRUCT *PEID_STRUCT;
#include "macros.inc"
#include "struct.inc"
#include "parser.inc"
#include "nt-parser.inc"

/* Actual scalar contract layout; only peer lookup/policy side effects are stubbed. */
#include "contract.inc"
struct bmgr_mld_sta { int valid; struct nt2lm_contract_t nt2lm_contract; };
struct mld_dev { struct { int valid; struct nt2lm_contract_t nt2lm_contract; } peer_mld; };
struct wifi_dev { int wdev_type; struct mld_dev *mld_dev; };
struct __attribute__((packed)) eht_prot_action_frame { u8 Hdr[24], category, prot_eht_action, data[]; };
#define WDEV_TYPE_AP 1
#define WDEV_TYPE_STA 2
static struct mld_dev mld_device;
static struct bmgr_mld_sta ap_peer;
static int policy_result, policy_calls;
static int find_mld_sta_by_wcid(PRTMP_ADAPTER ad, u16 wcid, struct bmgr_mld_sta **out)
{ *out=&ap_peer; return 0; }
static int nt2lm_request_sanity_check(PRTMP_ADAPTER ad, struct wifi_dev *wdev,
                                    u16 wcid, struct nt2lm_contract_t *contract)
{
    policy_calls++;
    contract->link_id_bitmap=3;
    contract->link_id_to_wcid[0]=42; contract->link_id_to_wcid[1]=43;
    for(unsigned i=0;i<2;i++) {
        contract->tid_map_dl[i]=contract->tid_map[i];
        contract->tid_map_ul[i]=contract->tid_map[i];
    }
    return policy_result;
}
#include "request-sanity.inc"
#include "response-sanity.inc"
#include "control.inc"

#define EHT_PROT_ACT_T2LM_REQUEST 0
#define EHT_PROT_ACT_T2LM_RESPONSE 1
#define EHT_PROT_ACT_T2LM_TEARDOWN 2
#define VALID_UCAST_ENTRY_WCID(ad,wcid) ((wcid)>0)
typedef struct { u8 Msg[2304]; ULONG MsgLen; struct wifi_dev *wdev; u16 Wcid; } MLME_QUEUE_ELEM;
static int action_calls, action_kind;
static ULONG action_length;
static int nt2lm_peer_t2lm_request_action(PRTMP_ADAPTER ad, struct wifi_dev *wdev,
    u16 wcid, struct eht_prot_action_frame *frame, ULONG length)
{ action_calls++; action_kind=0; action_length=length; return 0; }
static int nt2lm_peer_t2lm_response_action(PRTMP_ADAPTER ad, struct wifi_dev *wdev,
    u16 wcid, struct eht_prot_action_frame *frame, ULONG length)
{ action_calls++; action_kind=1; action_length=length; return 0; }
static int nt2lm_peer_t2lm_teardown_action(PRTMP_ADAPTER ad, struct wifi_dev *wdev,
    u16 wcid, struct eht_prot_action_frame *frame)
{ action_calls++; action_kind=2; return 0; }
#include "action-dispatch.inc"

#define END_OF_ARGS -1
/* Minimal replacement of the existing frame concatenator. */
static void concatenate_frame(u8 *out, ULONG *length, const size_t *sizes,
                              const void *const *parts, size_t count)
{
    *length=0;
    for(size_t i=0;i<count;i++) {
        assert(*length+sizes[i]<=80);
        memcpy(out+*length,parts[i],sizes[i]); *length+=sizes[i];
    }
}
#define MakeOutgoingFrame(out,len,s1,p1,s2,p2,s3,p3,s4,p4,s5,p5,s6,p6,s7,p7,end) \
    concatenate_frame(out,len,(size_t[]){s1,s2,s3,s4,s5,s6,s7}, \
                       (const void *[]){p1,p2,p3,p4,p5,p6,p7},7)
static ULONG encode_request(struct nt2lm_contract_t *nt2lm_contract, u8 *out_buffer)
{
    struct eht_prot_action_frame n2tlm_req={0};
    struct t2lm_ctrl_t t2lm_ctrl={0};
    ULONG frame_len;
    u8 dialog_token=7, eid=255, length=0, eid_ext=109, tid;
    u8 link_map_le[TID_MAX*2];
#include "tx-frame.inc"
    return frame_len;
}

static unsigned checks;
#define CHECK(x) do { checks++; assert(x); } while (0)

static void check_map(const u8 *bytes, size_t length, int success,
                      const u8 *expected, u8 expected_dir)
{
    u8 input[64] = {0}, map[16], before[16], dir=0xa5;
    assert(length <= sizeof(input));
    memcpy(input,bytes,length);
    memset(map,0xa5,sizeof(map)); memcpy(before,map,sizeof(map));
    int result=nt2lm_t2lm_ie_link_map_to_tid_map(input,length,map,&dir);
    CHECK((result==0)==success);
    if (success) {
        CHECK(dir==expected_dir);
        CHECK(memcmp(map,expected,sizeof(map))==0);
    } else {
        CHECK(dir==0xa5);
        CHECK(memcmp(map,before,sizeof(map))==0);
    }
}

int main(void)
{
    u8 all[16], selected[16]={0xff,0xff}, ie[64]={255,2,109,6};
    memset(all,255,sizeof(all));
    check_map(ie,4,1,all,2);
    /* Complete explicit maps, both size encodings. */
    ie[1]=19; ie[3]=2; ie[4]=255;
    for(unsigned i=0;i<8;i++) { ie[5+i*2]=3; ie[6+i*2]=0; }
    check_map(ie,21,1,selected,2);
    for(size_t n=0;n<21;n++) check_map(ie,n,0,NULL,0);
    ie[1]=11; ie[3]=0x22;
    for(unsigned i=0;i<8;i++) ie[5+i]=3;
    check_map(ie,13,1,selected,2);
    /* A complete header is not evidence that the advertised IE is present. */
    for(size_t n=0;n<13;n++) check_map(ie,n,0,NULL,0);
    /* NT mode keeps its existing full-contract policy. */
    { const u8 partial[]={255,4,109,0x22,1,3}; check_map(partial,sizeof(partial),0,NULL,0); }
    { const u8 mst[]={255,4,109,0x0e,0x34,0x12}; check_map(mst,sizeof(mst),0,NULL,0); }
    { const u8 ed[]={255,5,109,0x16,1,2,3}; check_map(ed,sizeof(ed),0,NULL,0); }
    ie[5]=0; check_map(ie,13,0,NULL,0);
    ie[5]=3; ie[0]=1; check_map(ie,13,0,NULL,0);
    ie[0]=255; ie[2]=108; check_map(ie,13,0,NULL,0);
    { const u8 twice[]={255,2,109,6,255,2,109,6}; check_map(twice,sizeof(twice),0,NULL,0); }
    { const u8 unrelated[]={0,0,255,2,109,6,255,1,108}; check_map(unrelated,sizeof(unrelated),1,all,2); }
    { const u8 trailing_header[]={255,2,109,6,1}; check_map(trailing_header,sizeof(trailing_header),0,NULL,0); }
    { const u8 down[]={255,2,109,4}; check_map(down,sizeof(down),0,NULL,0); }
    { const u8 up[]={255,2,109,5}; check_map(up,sizeof(up),0,NULL,0); }

    /* Request checks commit a complete candidate, never partial live state. */
    struct wifi_dev dev={WDEV_TYPE_AP,NULL};
    u8 frame_data[80]={0}, token=0;
    struct eht_prot_action_frame *frame=(void *)frame_data;
    CHECK(sizeof(*frame)==26);
    frame->data[0]=7;
    memcpy(frame->data+1,(u8[]){255,2,109,6},4);
    ap_peer.valid=1;
    memset(&ap_peer.nt2lm_contract,0x55,sizeof(ap_peer.nt2lm_contract));
    struct nt2lm_contract_t saved=ap_peer.nt2lm_contract;
    policy_result=0; policy_calls=0;
    for(size_t n=0;n<31;n++) {
        CHECK(nt2lm_peer_mld_tid_sanity_check(&dev,&dev,42,frame,n,&token)!=0);
        CHECK(memcmp(&saved,&ap_peer.nt2lm_contract,sizeof(saved))==0);
    }
    CHECK(policy_calls==0);
    policy_result=-EINVAL;
    CHECK(nt2lm_peer_mld_tid_sanity_check(&dev,&dev,42,frame,31,&token)!=0);
    CHECK(policy_calls==1);
    CHECK(memcmp(&saved,&ap_peer.nt2lm_contract,sizeof(saved))==0);
    policy_result=0;
    CHECK(nt2lm_peer_mld_tid_sanity_check(&dev,&dev,42,frame,31,&token)==0);
    CHECK(token==7 && ap_peer.nt2lm_contract.dir==2);
    CHECK(ap_peer.nt2lm_contract.tid_map[0]==255 && ap_peer.nt2lm_contract.tid_map[1]==255);
    CHECK(ap_peer.nt2lm_contract.link_id_bitmap==3);
    for(unsigned i=2;i<16;i++) CHECK(ap_peer.nt2lm_contract.tid_map[i]==0);
    for(unsigned i=0;i<8;i++) CHECK(ap_peer.nt2lm_contract.link_map[i]==3);
    CHECK(ap_peer.nt2lm_contract.request_type==saved.request_type);
    CHECK(ap_peer.nt2lm_contract.in_nego_tid==saved.in_nego_tid);

    /* Response status is a complete little-endian u16, not a low byte. */
    frame->data[1]=0; frame->data[2]=1;
    u16 status=0xa55a;
    for(size_t n=0;n<29;n++) {
        CHECK(nt2lm_peer_t2lm_rsp_sanity_check(&dev,&dev,42,frame,n,&status)!=0);
        CHECK(status==0xa55a);
    }
    CHECK(nt2lm_peer_t2lm_rsp_sanity_check(&dev,&dev,42,frame,29,&status)==0);
    CHECK(status==256);
    frame->data[1]=0; frame->data[2]=0;
    CHECK(nt2lm_peer_t2lm_rsp_sanity_check(&dev,&dev,42,frame,29,&status)==0);
    CHECK(status==0);

    MLME_QUEUE_ELEM elem={0};
    elem.wdev=&dev; elem.Wcid=42;
    struct eht_prot_action_frame *dispatch_frame=(void *)elem.Msg;
    for(unsigned kind=0;kind<3;kind++) {
        dispatch_frame->prot_eht_action=kind;
        ULONG minimum=kind==0 ? 31 : kind==1 ? 29 : 26;
        for(ULONG n=0;n<minimum;n++) {
            elem.MsgLen=n; action_calls=0;
            nt2lm_peer_t2lm_req_action(&dev,&elem);
            CHECK(action_calls==0);
        }
        elem.MsgLen=minimum; action_calls=0;
        nt2lm_peer_t2lm_req_action(&dev,&elem);
        CHECK(action_calls==1 && action_kind==(int)kind);
        if(kind<2) CHECK(action_length==minimum);
    }
    action_calls=0; nt2lm_peer_t2lm_req_action(&dev,NULL); CHECK(action_calls==0);
    elem.Wcid=0; nt2lm_peer_t2lm_req_action(&dev,&elem); CHECK(action_calls==0);

    /* Production TX block must round-trip with its declared IE length. */
    struct nt2lm_contract_t tx={0};
    tx.dir=2; tx.tid_bit_map=1;
    for(unsigned i=0;i<8;i++) tx.link_map[i]=0x0103;
    u8 out[80]={0}, tx_map[16]={0xff,0xff};
    tx_map[8]=0xff;
    ULONG tx_length=encode_request(&tx,out);
    CHECK(tx_length==48 && out[28]==19 && out[31]==0xff);
    check_map(out+27,tx_length-27,1,tx_map,2);
    printf("NT2LM parser compatibility: %u checks passed\n",checks);
    return 0;
}

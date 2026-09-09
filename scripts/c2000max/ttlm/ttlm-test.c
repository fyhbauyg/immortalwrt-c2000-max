/* Independent host tests: parser, generator and dispatch are mechanically
 * extracted unchanged from the selected driver tree by run.sh. Firmware-only
 * BSS lookup and logging are stubbed; no radio/hardware behavior is simulated. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint8_t UINT8;
typedef uint16_t UINT16;
typedef uint32_t UINT32;
#define TRUE 1
#define FALSE 0
#define IE_WLAN_EXTENSION 255
#define EID_EXT_EHT_TID2LNK_MAP 109
#define MLD_LINK_MAX 16
#define BSS_MNGR_MAX_BAND_NUM 3
#define BIT(n) (1U << (n))
#define CAP_BITS_MASK(n) (((1U << n##_BITS) - 1U) << n##_SHIFT)
#define GET_CAP_BITS(n, v) (((v) & n##_MASK) >> n##_SHIFT)
#define SET_CAP_BITS(n, v, x) ((v) = ((v) & ~n##_MASK) | (((x) << n##_SHIFT) & n##_MASK))
#define NdisMoveMemory memcpy
#define NdisZeroMemory(p,n) memset(p,0,n)
#define NdisFillMemory(p,n,v) memset(p,v,n)
#define cpu_to_le16(x) (x)
#define cpu_to_le32(x) (x)
#define le16_to_cpu(x) (x)
#define le32_to_cpu(x) (x)
#define MTWF_DBG(...) ((void)0)
#define hex_dump_with_cat_and_lvl(...) ((void)0)
#include "macros.inc"
struct __attribute__((packed)) _EID_STRUCT { u8 Eid, Len, Octet[1]; };
#include "struct.inc"
struct bmgr_mlo_dev { u8 bss_idx_mld[BSS_MNGR_MAX_BAND_NUM]; };
struct bmgr_entry { int bss_idx; struct bmgr_mlo_dev *mld_ptr; u8 tid_map; };
static struct bmgr_entry bss[3];
#define BMGR_INVALID_BSS_IDX 255
#define BMGR_VALID_BSS_IDX(i) ((unsigned)(i) < 3)
#define BMGR_VALID_MLO_DEV(m) ((m) != NULL)
#define GET_BSS_ENTRY_BY_IDX(i) (&bss[i])
#include "builder.inc"
#include "parser.inc"

/* Linux 6.12's original structural validator (not a full semantics oracle). */
#define IEEE80211_TTLM_CONTROL_DEF_LINK_MAP 4
#define IEEE80211_TTLM_CONTROL_SWITCH_TIME_PRESENT 8
#define IEEE80211_TTLM_CONTROL_EXPECTED_DUR_PRESENT 16
#define IEEE80211_TTLM_CONTROL_LINK_MAP_SIZE 32
struct __attribute__((packed)) ieee80211_ttlm_elem { u8 control; u8 optional[]; };
static unsigned hweight8(u8 x) { return __builtin_popcount((unsigned)x); }
#include "linux-size.inc"

static unsigned checks, failures;
static const char *case_name;
#define CHECK(c) do { checks++; if (!(c)) { failures++; if (failures < 60) \
 fprintf(stderr, "FAIL %s line %d: %s\n", case_name, __LINE__, #c); } } while (0)

/* Wire-level independently expressed oracle. The API requires two readable
 * header bytes and the advertised Len payload; no hidden buffer length exists.
 * Default and omitted TIDs mean all links, pending consumer valid-link mask. */
static int oracle(const u8 *ie, struct tid2lnk_ie_info *out)
{
    struct tid2lnk_ie_info x = {0};
    size_t payload, cursor = 1, need;
    unsigned tid, link, size, control, present = 0;
    if (!ie || !out || ie[0] != 255 || ie[1] < 2 || ie[2] != 109) return -1;
    payload = ie[1] - 1;
    ie += 3;
    control = ie[0];
    if ((control & 3) == 3) return -1;
    if (!(control & 4)) { if (payload < 2) return -1; present = ie[cursor++]; }
    size = (control & 32) ? 1 : 2;
    need = cursor + ((control & 8) ? 2 : 0) + ((control & 16) ? 3 : 0) + hweight8(present) * size;
    if (payload < need) return -1;
    x.state = 1; x.ctrl_dir = control & 3; x.ctrl_default = !!(control & 4);
    x.ctrl_mst = !!(control & 8); x.ctrl_ed = !!(control & 16);
    x.ctrl_size = !!(control & 32); x.ctrl_map_pres = present; x.bcn_tsf = out->bcn_tsf;
    if (control & 8) { x.mst_tsf = ie[cursor] + 256U * ie[cursor+1]; cursor += 2; }
    if (control & 16) { x.ed_tsf = ie[cursor] + 256U * ie[cursor+1] + 65536U * ie[cursor+2]; cursor += 3; }
    memset(x.tid_map, 255, sizeof(x.tid_map));
    for (tid = 0; tid < 8; tid++) if (present & BIT(tid)) {
        unsigned map = ie[cursor++];
        if (size == 2) map += 256U * ie[cursor++];
        if (!map) return -1;
        for (link = 0; link < 16; link++) {
            x.tid_map[link] &= ~BIT(tid);
            if (map & BIT(link)) x.tid_map[link] |= BIT(tid);
        }
    }
    *out = x;
    return 0;
}

static bool equivalent(const struct tid2lnk_ie_info *a, const struct tid2lnk_ie_info *b)
{
    return a->state == b->state && a->ctrl_dir == b->ctrl_dir &&
        a->ctrl_default == b->ctrl_default && a->ctrl_mst == b->ctrl_mst &&
        a->ctrl_ed == b->ctrl_ed && a->ctrl_size == b->ctrl_size &&
        a->ctrl_map_pres == b->ctrl_map_pres && a->bcn_tsf == b->bcn_tsf &&
        a->mst_tsf == b->mst_tsf && a->ed_tsf == b->ed_tsf &&
        memcmp(a->tid_map, b->tid_map, sizeof(a->tid_map)) == 0;
}

/* Allocate exactly the declared extent. ASan therefore catches overreads even
 * when adjacent IEs happen to exist in a real management-frame allocation. */
static int vector(const char *name, const u8 *bytes, size_t extent, int want)
{
    struct tid2lnk_ie_info actual, before, expected;
    u8 *ie = malloc(extent);
    memcpy(ie, bytes, extent);
    memset(&actual, 0xa5, sizeof(actual)); actual.bcn_tsf = 0x7931;
    before = actual; expected = actual;
    case_name = name;
    CHECK(extent >= 2 && ie[1] + 2U == extent);
    int ref = oracle(ie, &expected);
    int got = parse_tid_to_link_map_ie(ie, &actual);
    CHECK((got == 0) == (want == 0));
    CHECK((ref == 0) == (want == 0));
    if (got == 0 && ref == 0) CHECK(equivalent(&actual, &expected));
    if (got != 0) CHECK(memcmp(&actual, &before, sizeof(actual)) == 0);
    if (ref == 0) CHECK(ieee80211_tid_to_link_map_size_ok(ie + 3, extent - 3));
    free(ie);
    return got;
}

static size_t make_ie(u8 *ie, unsigned control, unsigned present, unsigned seed)
{
    size_t n = 0; unsigned tid;
    ie[n++] = 255; ie[n++] = 0; ie[n++] = 109; ie[n++] = control;
    if (!(control & 4)) ie[n++] = present;
    if (control & 8) { ie[n++] = 0x34; ie[n++] = 0x12; }
    if (control & 16) { ie[n++] = 0x56; ie[n++] = 0x34; ie[n++] = 0xf2; }
    if (!(control & 4)) for (tid = 0; tid < 8; tid++) if (present & BIT(tid)) {
        unsigned mask = (seed + tid * 7U) & ((control & 32) ? 255 : 65535);
        if (!mask) mask = 1;
        ie[n++] = mask;
        if (!(control & 32)) ie[n++] = mask >> 8;
    }
    ie[1] = n - 2;
    return n;
}

static void wire_vectors(void)
{
    u8 ie[64]; unsigned dir, optional, size, present, bit; size_t n, cut;
    for (dir=0; dir<3; dir++) for (optional=0; optional<4; optional++) {
        n = make_ie(ie, dir | 4 | (optional << 3), 0, 3);
        vector("default mapping/MST/ED all directions", ie, n, 0);
        for (cut=2; cut<n; cut++) { u8 short_ie[64]; memcpy(short_ie,ie,cut); short_ie[1]=cut-2;
            vector("default every declared truncation", short_ie, cut, -1); }
    }
    for (dir=0; dir<3; dir++) for (optional=0; optional<4; optional++)
    for (size=0; size<2; size++) for (present=0; present<256; present++) {
        n = make_ie(ie, dir | (optional << 3) | (size << 5), present, 0x8135);
        vector("all subset masks including 0 and full 8", ie, n, 0);
        if (present==0xff || present==0x81) for (cut=2; cut<n; cut++) {
            u8 short_ie[64]; memcpy(short_ie,ie,cut); short_ie[1]=cut-2;
            vector("explicit every declared truncation", short_ie, cut, -1);
        }
    }
    n=make_ie(ie, 0x22, 0xff, 3);
    for (bit=6; bit<8; bit++) { ie[3] |= BIT(bit); vector("reserved control bits ignored",ie,n,0); }
    ie[0]=1; vector("wrong primary IE",ie,n,-1); ie[0]=255;
    ie[2]=108; vector("wrong extension IE",ie,n,-1); ie[2]=109;
    ie[3] = 0x23; vector("reserved direction",ie,n,-1);
    n=make_ie(ie,0x22,1,1); ie[n-1]=0; vector("zero explicit link map",ie,n,-1);
    n=make_ie(ie,2,1,1); ie[n-2]=ie[n-1]=0; vector("zero explicit wide map",ie,n,-1);
    n=make_ie(ie,0x1e,0,0); ie[n++]=0xde; ie[1]++; vector("future trailing field tolerated",ie,n,0);
    n=make_ie(ie,0x3e,0,0); vector("default plus size bit omits presence",ie,n,0);
}

static void repeat_vectors(void)
{
    u8 ie[64]; struct tid2lnk_ie_info actual={0},expected={0};
    actual.bcn_tsf=expected.bcn_tsf=0xef01;
    case_name="successful reparse clears prior timing and link/TID state";
    make_ie(ie,0x1a,0xff,0x5555);
    CHECK(parse_tid_to_link_map_ie(ie,&actual)==0); CHECK(oracle(ie,&expected)==0);
    CHECK(equivalent(&actual,&expected)); CHECK(actual.mst_tsf==0x1234 && actual.ed_tsf==0xf23456);
    make_ie(ie,0x22,0x81,2);
    CHECK(parse_tid_to_link_map_ie(ie,&actual)==0); CHECK(oracle(ie,&expected)==0);
    CHECK(equivalent(&actual,&expected)); CHECK(actual.mst_tsf==0 && actual.ed_tsf==0);
    CHECK(actual.tid_map[15]==0x7e); CHECK(actual.bcn_tsf==0xef01);
    make_ie(ie,6,0,0);
    CHECK(parse_tid_to_link_map_ie(ie,&actual)==0); CHECK(oracle(ie,&expected)==0);
    CHECK(equivalent(&actual,&expected));
    for(unsigned i=0;i<16;i++) CHECK(actual.tid_map[i]==255);
    struct tid2lnk_ie_info saved=actual;
    case_name="failure preserves previously successful result including state";
    ie[3]=3; CHECK(parse_tid_to_link_map_ie(ie,&actual)<0);
    CHECK(memcmp(&actual,&saved,sizeof(actual))==0);
    make_ie(ie,0x1a,0xff,0x1234); ie[1]=4;
    CHECK(parse_tid_to_link_map_ie(ie,&actual)<0);
    CHECK(memcmp(&actual,&saved,sizeof(actual))==0);
}

static void builder_vectors(void)
{
    struct bmgr_mlo_dev mld={{0,1,2}};
    struct bmgr_entry entry={.bss_idx=0,.mld_ptr=&mld,.tid_map=255};
    struct tid2lnk_ie_info got={0}; u8 buf[64]; u8 *end;
    case_name="builder exact nondefault full mapping roundtrip";
    bss[0].tid_map=0xff; bss[1].tid_map=0x55; bss[2].tid_map=0x80;
    memset(buf,0xa5,sizeof(buf)); end=build_tid_to_link_map_ie(&entry,buf);
    CHECK(end==buf+21); CHECK(buf[0]==255 && buf[1]==19 && buf[2]==109);
    CHECK(!(buf[3]&4)); CHECK(buf[4]==255);
    CHECK(ieee80211_tid_to_link_map_size_ok(buf+3,end-buf-3));
    CHECK(parse_tid_to_link_map_ie(buf,&got)==0);
    CHECK(got.ctrl_default==0 && got.ctrl_map_pres==255);
    CHECK(got.tid_map[0]==255 && got.tid_map[1]==0x55 && got.tid_map[2]==0x80);
    for(unsigned i=3;i<16;i++) CHECK(got.tid_map[i]==0);
    for(unsigned i=21;i<sizeof(buf);i++) CHECK(buf[i]==0xa5);
    case_name="builder absent link is omitted";
    mld.bss_idx_mld[2]=255; end=build_tid_to_link_map_ie(&entry,buf);
    CHECK(end==buf+21); CHECK(parse_tid_to_link_map_ie(buf,&got)==0); CHECK(got.tid_map[2]==0);
}

/* The real dispatch if-block is extracted; only its surrounding large caller
 * environment is stubbed. A sticky bitmap models previous TTLM observation. */
#define HAS_EHT_ML_T2LM_EXIST(x) ((x)&1)
#define os_free_mem free
struct dispatch_list { struct { unsigned ie_exists; } cmm_ies; struct tid2lnk_ie_info t2lm_info; };
static bool dispatch(struct _EID_STRUCT *pEid, struct dispatch_list *ie_list)
{
    void *pPeerWscIe=NULL;
#include "dispatch.inc"
    return TRUE;
}
static void dispatch_vectors(void)
{
    u8 valid[]={255,2,109,6}, caps[]={255,1,108}, op[]={255,1,106}, other[]={255,1,42};
    u8 empty[]={255,0}; struct dispatch_list list={0};
    case_name="TTLM followed by unrelated extension keeps earlier valid mapping";
    list.cmm_ies.ie_exists=1;
    CHECK(dispatch((void*)valid,&list)); CHECK(list.t2lm_info.state==1);
    struct tid2lnk_ie_info saved=list.t2lm_info;
    CHECK(dispatch((void*)caps,&list)); CHECK(equivalent(&saved,&list.t2lm_info));
    CHECK(dispatch((void*)op,&list)); CHECK(equivalent(&saved,&list.t2lm_info));
    CHECK(dispatch((void*)other,&list)); CHECK(equivalent(&saved,&list.t2lm_info));
    case_name="dispatch exact two-byte empty extension never reads Octet[0]";
    CHECK(dispatch((void*)empty,&list)); CHECK(equivalent(&saved,&list.t2lm_info));
}

/* Execute the real top-level variable-IE loop predicate in isolation, not the
 * full management-frame parser or other IE handlers. */
static bool loop_guard(const u8 *frame, size_t Length, size_t MsgLen)
{
    const struct _EID_STRUCT *pEid=(const void *)(frame+Length);
#include "loop-guard.inc"
        return true;
    }
    return false;
}
static void boundary_vectors(void)
{
    u8 *frame=malloc(5); memset(frame,0,5);
    case_name="real loop guard protects end-of-frame and one-byte suffix";
    CHECK(!loop_guard(frame,5,5)); CHECK(!loop_guard(frame,4,5));
    frame[4]=0; CHECK(loop_guard(frame,3,5));
    frame[4]=1; CHECK(!loop_guard(frame,3,5));
    free(frame);
}

static void random_vectors(void)
{
    uint32_t seed=0x79930909; unsigned i,j;
    for(i=0;i<25000;i++) {
        u8 bytes[48]; seed=seed*1664525U+1013904223U;
        size_t n=2+(seed%40); bytes[0]=255; bytes[1]=n-2;
        for(j=2;j<n;j++) { seed=seed*1664525U+1013904223U; bytes[j]=seed>>24; }
        if(n>2) bytes[2]=109;
        struct tid2lnk_ie_info out={0}; int ref=oracle(bytes,&out);
        vector("deterministic malformed/valid mixed fuzz",bytes,n,ref);
    }
}

static void run_group(const char *name, void (*fn)(void))
{
    unsigned c=checks, f=failures;
    fn();
    printf("GROUP %s: %u checks, %u failures\n",name,checks-c,failures-f);
}

int main(int argc,char **argv)
{
    const char *mode=argc>1?argv[1]:"all";
    if(!strcmp(mode,"null") || !strcmp(mode,"all")) {
        u8 valid[]={255,2,109,6}; struct tid2lnk_ie_info out={0};
        case_name="null arguments";
        CHECK(parse_tid_to_link_map_ie(NULL,&out)<0);
        CHECK(parse_tid_to_link_map_ie(valid,NULL)<0);
        CHECK(build_tid_to_link_map_ie(NULL,NULL)==NULL);
    }
    if(!strcmp(mode,"all") || !strcmp(mode,"boundary")) run_group("loop-boundary",boundary_vectors);
    if(strcmp(mode,"null") && strcmp(mode,"boundary")) {
        run_group("wire-vectors",wire_vectors);
        run_group("repeat-success",repeat_vectors);
        run_group("generator-roundtrip",builder_vectors);
        run_group("extension-dispatch",dispatch_vectors);
        run_group("deterministic-fuzz",random_vectors);
    }
    printf("TTLM independent tests: %u checks, %u failures; source functions extracted, ASan+UBSan enabled\n",checks,failures);
    return failures?1:0;
}

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#define DOT11_EHT_BE 1
#define DOT11_HE_AX 1
#define DOT11_VHT_AC 1
typedef unsigned char UCHAR;
typedef unsigned char UINT8;
typedef int INT32;
typedef int BOOLEAN;
typedef unsigned int UINT32;
#define TRUE 1
#define FALSE 0
#define WLAN_OPER_OK 0
#define WLAN_OPER_FAIL -1
#define EXTCHA_NONE 0
#define EXTCHA_ABOVE 1
#define EXTCHA_BELOW 3
enum ht_bw_def { HT_BW_20, HT_BW_40 };
enum vht_config_bw { VHT_BW_2040, VHT_BW_80, VHT_BW_160, VHT_BW_8080 };
enum { EHT_BW_20, EHT_BW_2040, EHT_BW_80, EHT_BW_160, EHT_BW_320 };
enum { HE_BW_20, HE_BW_2040, HE_BW_80, HE_BW_160, HE_BW_8080 };
enum { BW_20, BW_40, BW_80, BW_160, BW_8080, BW_320 };
enum { MTK_NL80211_CHAN_WIDTH_20_NOHT, MTK_NL80211_CHAN_WIDTH_20,
 MTK_NL80211_CHAN_WIDTH_40, MTK_NL80211_CHAN_WIDTH_80,
 MTK_NL80211_CHAN_WIDTH_80P80, MTK_NL80211_CHAN_WIDTH_160 };
enum { WMODE_A=1, WMODE_B=2, WMODE_G=4, WMODE_AN=8, WMODE_GN=16,
 WMODE_AC=32, WMODE_AX_5G=64, WMODE_AX_24G=128, WMODE_BE_5G=512, WMODE_BE_24G=1024 };
#define WMODE_CAP_BE(x) ((x) & (WMODE_BE_5G|WMODE_BE_24G))
#define CMD_CH_BAND_24G 0
#define CMD_CH_BAND_5G 1
#define CH_OP_OWNER_SET_CHN 1
#define CH_LIST_STATE_NONE 0
#define MTWF_DBG(...) ((void)0)
#define RTMP_OS_REINIT_COMPLETION(x) ((void)0)
#define os_zero_mem(x,n) memset((x),0,(n))
typedef int CHANNEL_CTRL;
struct freq_cfg { UCHAR ch_band, ht_bw, vht_bw, ext_cha, prim_ch, eht_bw; };
struct wifi_dev {
 unsigned int PhyMode;
 UCHAR channel, ch_band, cbw, cvht, che, ceht, cext, bw, ht, vht, eht, ext;
 void *wpf_cfg, *wpf_op;
};
typedef struct { struct { int HT_Disable; } CommonCfg;
 struct { int iwpriv_event_flag, set_ch_async_flag, set_ch_aync_done; } ApCfg;
 void *hdev_ctrl;
} RTMP_ADAPTER;
struct mt_priv_ops_chan_info { int ChanType; UCHAR ChanId, CenterChanId; };
static int locks, releases, loads, sync_calls, channel_calls, fail_lock, fail_channel;
static int injected, sync_failure, channel_async, bad_tuple, common_after_async;
static CHANNEL_CTRL cc;
static CHANNEL_CTRL *hc_get_channel_ctrl(void *p) { return &cc; }
static void hc_set_ChCtrlChListStat(CHANNEL_CTRL *p, int s) { }
static void BuildChannelList(RTMP_ADAPTER *a, struct wifi_dev *w) { }
static void RTMPSetPhyMode(RTMP_ADAPTER *a, struct wifi_dev *w, unsigned int mode) { w->PhyMode=mode; }
static UCHAR wlan_config_get_ht_bw(struct wifi_dev *w) { return w->cbw; }
static UCHAR wlan_config_get_vht_bw(struct wifi_dev *w) { return w->cvht; }
static UCHAR wlan_config_get_he_bw(struct wifi_dev *w) { return w->che; }
static UCHAR wlan_config_get_eht_bw(struct wifi_dev *w) { return w->ceht; }
static UCHAR wlan_config_get_ext_cha(struct wifi_dev *w) { return w->cext; }
static UCHAR wlan_config_get_ch_band(struct wifi_dev *w) { return w->ch_band; }
static UCHAR wlan_operate_get_ht_bw(struct wifi_dev *w) { return w->ht; }
static UCHAR wlan_operate_get_vht_bw(struct wifi_dev *w) { return w->vht; }
static UCHAR wlan_operate_get_eht_bw(struct wifi_dev *w) { return w->eht; }
static UCHAR wlan_operate_get_bw(struct wifi_dev *w) { return w->bw; }
static UCHAR wlan_operate_get_ext_cha(struct wifi_dev *w) { return w->ext; }
static void wlan_config_set_ht_bw(struct wifi_dev *w, UCHAR b) { w->cbw=b; }
static void wlan_config_set_vht_bw(struct wifi_dev *w, UCHAR b) { w->cvht=b; }
static void wlan_config_set_he_bw(struct wifi_dev *w, UCHAR b) { w->che=b; }
static void wlan_config_set_eht_bw(struct wifi_dev *w, UCHAR b) { w->ceht=b; }
static void wlan_config_set_ext_cha(struct wifi_dev *w, UCHAR b) { w->cext=b; }
static UCHAR rf_bw_2_ht_bw(UCHAR b) { return b==BW_20?HT_BW_20:HT_BW_40; }
static UCHAR rf_bw_2_vht_bw(UCHAR b) { return b==BW_80?VHT_BW_80:b==BW_160?VHT_BW_160:b==BW_8080?VHT_BW_8080:VHT_BW_2040; }
static UCHAR rf_bw_2_eht_bw(UCHAR b) { return b==BW_20?EHT_BW_20:b==BW_40?EHT_BW_2040:b==BW_80?EHT_BW_80:b==BW_160?EHT_BW_160:EHT_BW_20; }
static void phy_freq_get_cfg(struct wifi_dev *w, struct freq_cfg *f) {
 f->ht_bw=w->cbw; f->vht_bw=w->cvht; f->eht_bw=w->ceht; f->ext_cha=w->cext;
 f->prim_ch=w->channel; f->ch_band=w->ch_band;
}
static void operate_loader_phy(struct wifi_dev *w, struct freq_cfg *f) {
 loads++; w->ht=f->ht_bw; w->vht=f->vht_bw; w->eht=f->eht_bw; w->ext=f->ext_cha;
 w->bw=f->ht_bw==HT_BW_20?BW_20:f->vht_bw==VHT_BW_80?BW_80:f->vht_bw==VHT_BW_160?BW_160:f->vht_bw==VHT_BW_8080?BW_8080:BW_40;
 if (WMODE_CAP_BE(w->PhyMode) && w->eht<w->bw) w->bw=w->eht;
}
static int wlan_operate_sync_bw_for_ht_eht_vht(struct wifi_dev *w, UCHAR b) {
 struct freq_cfg f; sync_calls++; phy_freq_get_cfg(w,&f);
 if(f.ht_bw!=rf_bw_2_ht_bw(b)||f.vht_bw!=rf_bw_2_vht_bw(b)||f.eht_bw!=rf_bw_2_eht_bw(b)) bad_tuple++;
 if(injected==1) return WLAN_OPER_FAIL;
 if(injected==2) return WLAN_OPER_OK; /* underlying loader silently did nothing */
 if(injected==3) f.ht_bw=HT_BW_20; /* regulatory/coexistence clamp */
 if(injected==4) f.ext_cha=EXTCHA_BELOW;
 operate_loader_phy(w,&f);
 return sync_failure?WLAN_OPER_FAIL:WLAN_OPER_OK;
}
static int wlan_operate_set_ht_bw(struct wifi_dev *w,UCHAR b,UCHAR e) {
 struct freq_cfg f;
 if(injected==1) return WLAN_OPER_FAIL;
 if(b==w->ht && (w->ch_band==CMD_CH_BAND_5G || e==w->ext)) return WLAN_OPER_OK;
 phy_freq_get_cfg(w,&f); f.ht_bw=b; f.ext_cha=e; operate_loader_phy(w,&f); return WLAN_OPER_OK;
}
static int wlan_operate_set_vht_bw(struct wifi_dev *w,UCHAR b) {
 struct freq_cfg f;
 if(injected==1) return WLAN_OPER_FAIL;
 if(b==w->vht) return WLAN_OPER_OK;
 phy_freq_get_cfg(w,&f); f.vht_bw=b; operate_loader_phy(w,&f); return WLAN_OPER_OK;
}
static void SetCommonHtVht(RTMP_ADAPTER *a, struct wifi_dev *w) { if(a->ApCfg.set_ch_async_flag)common_after_async++; }
static int TakeChannelOpCharge(RTMP_ADAPTER *a,struct wifi_dev *w,int o,int wait) { if(fail_lock)return FALSE; locks++; return TRUE; }
static void ReleaseChannelOpCharge(RTMP_ADAPTER *a,struct wifi_dev *w,int o) { releases++; }
static int rtmp_set_channel(RTMP_ADAPTER *a,struct wifi_dev *w,UCHAR ch) {
 struct freq_cfg f;
 channel_calls++; if(fail_channel)return FALSE;
 if(channel_async) a->ApCfg.set_ch_async_flag=TRUE;
 else { w->channel=ch; phy_freq_get_cfg(w,&f); operate_loader_phy(w,&f); }
 return TRUE;
}

/* The runner inserts the exact extracted production function bodies here. */
/* FUNCTIONS */

static RTMP_ADAPTER a;
static struct wifi_dev w;
static struct mt_priv_ops_chan_info c;
static int failures, assertions;
#define CHECK(cond, msg) do { assertions++; if(!(cond)){fprintf(stderr,"FAIL: %s\n",msg);failures++;} } while(0)
static void reset(UCHAR b,int be) {
 memset(&a,0,sizeof(a)); memset(&w,0,sizeof(w)); memset(&c,0,sizeof(c));
 w.channel=36; w.ch_band=CMD_CH_BAND_5G; w.PhyMode=WMODE_A|WMODE_AN|WMODE_AC|WMODE_AX_5G|(be?WMODE_BE_5G:0);
 w.wpf_cfg=&w; w.wpf_op=&w;
 w.cbw=w.ht=rf_bw_2_ht_bw(b); w.cvht=w.vht=rf_bw_2_vht_bw(b); w.ceht=w.eht=rf_bw_2_eht_bw(b);
 w.bw=b; w.cext=w.ext=b==BW_20?EXTCHA_NONE:EXTCHA_ABOVE; w.che=b;
 locks=releases=loads=sync_calls=channel_calls=fail_lock=fail_channel=injected=sync_failure=channel_async=bad_tuple=common_after_async=0;
 c.ChanId=36; c.CenterChanId=38; c.ChanType=MTK_NL80211_CHAN_WIDTH_40;
}
static void check_restored(void) {
 CHECK(w.cbw==HT_BW_40&&w.cvht==VHT_BW_160&&w.che==HE_BW_160&&w.ceht==EHT_BW_160,"restore all configured width components");
 CHECK(w.bw==BW_160,"restore previous operating width");
 CHECK(w.channel==36&&!a.CommonCfg.HT_Disable,"failure leaves channel/HT enable alone");
 CHECK(locks==releases&&!a.ApCfg.iwpriv_event_flag,"failure releases channel ownership");
}
int main(void) {
 int r, b;
 for(b=BW_80;b<=BW_160;b++) {
  reset(b,1); r=CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c);
  CHECK(r==TRUE&&w.bw==BW_40,"80/160 to 40 must actually narrow RF width");
  CHECK(w.vht==VHT_BW_2040&&w.eht==EHT_BW_2040&&w.cvht==VHT_BW_2040&&w.ceht==EHT_BW_2040&&w.che==HE_BW_2040,"40 MHz complete tuple");
  CHECK(WMODE_CAP_BE(w.PhyMode),"bandwidth change must preserve BE");
  CHECK(locks==1&&releases==1&&!bad_tuple,"one serialized complete apply");
 }
 reset(BW_40,1); CHECK(CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)==TRUE,"successful unchanged-width no-op");
 CHECK(!loads&&!locks,"no-op does not reload radio");
 reset(BW_40,1); w.cvht=VHT_BW_160; w.ceht=EHT_BW_160;
 CHECK(CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&w.cvht==VHT_BW_2040&&w.ceht==EHT_BW_2040,"same operating width still repairs stale configured width");
 reset(BW_20,1); CHECK(CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&w.bw==BW_40&&WMODE_CAP_BE(w.PhyMode),"20 to 40 preserves EHT mode");
 reset(BW_20,0); CHECK(CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&!WMODE_CAP_BE(w.PhyMode),"do not enable BE on HE interface");
 reset(BW_20,1); injected=1;
 CHECK(!CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c),"real width setter failure from HT20 must propagate");
 CHECK(w.cbw==HT_BW_20&&w.cvht==VHT_BW_2040&&w.ceht==EHT_BW_20&&w.che==HE_BW_20&&w.bw==BW_20,"failed expansion restores prior narrow config/runtime");
 for(b=BW_80;b<=BW_160;b++) {
  reset(BW_40,1); c.ChanType=b==BW_80?MTK_NL80211_CHAN_WIDTH_80:MTK_NL80211_CHAN_WIDTH_160;
  CHECK(CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&w.bw==b&&w.che==b&&w.ceht==b&&WMODE_CAP_BE(w.PhyMode),"40 to 80/160 stages all PHY widths");
  CHECK(CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&sync_calls==1,"80/160 successful repeat is no-op");
 }
 reset(BW_160,1); c.ChanType=99; c.ChanId=40;
 CHECK(!CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c),"unsupported width returns failure");
 CHECK(w.bw==BW_160&&w.channel==36&&!loads&&!locks&&!channel_calls,"unsupported width is side-effect free");
 reset(BW_160,1); c.CenterChanId=36;
 CHECK(!CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&!loads,"invalid 40 MHz center rejected before apply");
 for(injected=0,b=1;b<=4;b++) {
  reset(BW_160,1); injected=b;
  CHECK(!CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c),"setter failure, silent no-op, clamp or wrong extension is not success");
  check_restored();
 }
 reset(BW_160,1); sync_failure=1;
 CHECK(!CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c),"partial setter application with failure not success"); check_restored();
 reset(BW_160,1); fail_lock=1; c.ChanId=40; c.CenterChanId=42;
 CHECK(!CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&!loads&&w.cbw==HT_BW_40&&w.cvht==VHT_BW_160,"ownership failure must not mutate width");
 reset(BW_160,1); fail_channel=1; c.ChanId=40; c.CenterChanId=42;
 CHECK(!CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c),"channel failure propagated"); check_restored();
 reset(BW_40,1); c.ChanId=40; c.CenterChanId=42;
 CHECK(CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&w.channel==40&&locks==releases,"same-width channel change works");
 reset(BW_160,1); c.ChanId=40; c.CenterChanId=38;
 CHECK(CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&w.channel==40&&w.bw==BW_40&&w.ext==EXTCHA_BELOW&&!sync_calls,"combined width/channel switch stages secondary with new primary");
 reset(BW_40,1); c.ChanId=40; c.CenterChanId=42; channel_async=1;
 CHECK(CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&a.ApCfg.set_ch_async_flag&&locks==1&&releases==0,"accepted CSA keeps completion-owned lock");
 reset(BW_160,1); c.ChanId=40; c.CenterChanId=38; channel_async=1;
 CHECK(CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&w.bw==BW_160&&w.channel==36&&!common_after_async&&!sync_calls&&w.ceht==EHT_BW_2040,"queued combined CSA does not load staged widths against old primary");
 reset(BW_160,1); c.ChanType=MTK_NL80211_CHAN_WIDTH_20_NOHT;
 CHECK(CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&w.bw==BW_20&&a.CommonCfg.HT_Disable,"20 NOHT tuple and global HT state");
 CHECK(CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&sync_calls==1,"20 NOHT repeat succeeds without reload");
 c.ChanType=MTK_NL80211_CHAN_WIDTH_20;
 CHECK(CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&w.bw==BW_20&&!a.CommonCfg.HT_Disable,"20 MHz HT enable transition succeeds");
 reset(BW_40,1); c.ChanType=MTK_NL80211_CHAN_WIDTH_80P80;
 CHECK(!CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&!loads,"EHT 80+80 explicitly unsupported");
 reset(BW_40,0); c.ChanType=MTK_NL80211_CHAN_WIDTH_80P80;
 CHECK(CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&w.bw==BW_8080,"legacy VHT 80+80 remains accepted");
 reset(BW_40,1); w.ch_band=CMD_CH_BAND_24G; w.PhyMode=WMODE_B|WMODE_G|WMODE_GN|WMODE_AX_24G|WMODE_BE_24G; w.channel=c.ChanId=6; c.CenterChanId=8; c.ChanType=MTK_NL80211_CHAN_WIDTH_160;
 CHECK(!CFG80211DRV_AP_SetChanBw_byWdev(&a,&w,&c)&&!loads,"2.4 GHz wide bandwidth rejected");
 CHECK(!CFG80211DRV_AP_SetChanBw_byWdev(NULL,&w,&c),"null adapter rejected");
 printf("%d assertions, %d failures\n",assertions,failures);
 return failures?1:0;
}

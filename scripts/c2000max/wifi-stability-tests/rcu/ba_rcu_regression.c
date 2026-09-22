/* Include ba_free_rec_entry extracted verbatim from the selected source tree.
 * Models API accounting, not concurrent execution or on-device throughput. */
#include <stdio.h>
#include <string.h>

#define VOID void
#define FALSE 0
#define MAX_LEN_OF_BA_REC_TABLE 4
#define Recipient_NONE 0
#define SN_HISTORY 1
#define CONFIG_BA_REORDER_ARRAY_SUPPORT 1
#define PD_GET_BA_CTRL_PTR(p) ((struct ba_control *)(p))
#define IS_VALID_ENTRY(p) ((p) && (p)->valid)
#define IS_ENTRY_MLO(p) ((p)->mlo)
#define MTWF_DBG(...) ((void)0)
#define os_lockless_ctx_get() NULL
#define mt_os_lockless_access_pointer(ctx, p) (p)

typedef unsigned long ULONG;
struct BA_INFO { unsigned RecWcidArray[8]; unsigned RxBitmap; };
struct mld_entry_t { struct BA_INFO ba_info; };
typedef struct MAC_TABLE_ENTRY {
	int valid, mlo, wcid;
	struct BA_INFO ba_info;
	struct mld_entry_t *mld_entry;
} MAC_TABLE_ENTRY;
struct BA_REC_ENTRY {
	int RxReRingLock, REC_BA_Status;
	MAC_TABLE_ENTRY *pEntry;
	int TID, WaitWM, Session_id, RetryCnt, reorder_buf_id;
	void *ba_rec_dbg;
};
struct ba_control {
	struct BA_REC_ENTRY BARecEntry[MAX_LEN_OF_BA_REC_TABLE];
	int BATabLock, numAsRecipient, dbg_flag, free_ba_buf[4];
};
typedef struct { void *physical_dev; } RTMP_ADAPTER;

static int readers, underflows, enters, exits, spin_errors, released_bufs, freed_debug;
static void NdisAcquireSpinLock(int *lock)
{
	if (*lock != 0) spin_errors++;
	++*lock;
}
static void NdisReleaseSpinLock(int *lock)
{
	if (*lock != 1) spin_errors++;
	--*lock;
}
#ifdef DOT11_EHT_BE
static void mt_os_lockless_enter(void *ctx)
{
	(void)ctx;
	readers++;
	enters++;
}
static void mt_os_lockless_exit(void *ctx)
{
	(void)ctx;
	if (readers <= 0) underflows++;
	readers--;
	exits++;
}
#endif
static void release_ba_buf(struct ba_control *ctl, int *buf)
{
	(void)ctl;
	(void)buf;
	released_bufs++;
}
static void os_free_mem(void *ptr)
{
	(void)ptr;
	freed_debug++;
}

#include "ba_free_rec_entry.inc"

static int failures;
#define CHECK(expr) do { if (!(expr)) { \
	fprintf(stderr, "%s:%d: %s: %s\n", __FILE__, __LINE__, name, #expr); \
	failures++; } } while (0)

static void run_case(const char *name, ULONG idx, int active, int valid,
	int missing_entry, int mlo, int missing_mld, int twice, int zero_count)
{
	int before = failures;
	struct ba_control ctl;
	MAC_TABLE_ENTRY entry;
	struct mld_entry_t mld;
	struct BA_INFO *info;
	RTMP_ADAPTER ad = { .physical_dev = &ctl };
	struct BA_REC_ENTRY *rec = &ctl.BARecEntry[1];
	int can_release = idx == 1 && active && valid && !missing_entry;
	int expected_rcu = can_release;
	memset(&ctl, 0, sizeof(ctl));
	memset(&entry, 0, sizeof(entry));
	memset(&mld, 0, sizeof(mld));
	entry.valid = valid;
	entry.mlo = mlo;
	entry.mld_entry = missing_mld ? NULL : &mld;
	entry.ba_info.RecWcidArray[2] = mld.ba_info.RecWcidArray[2] = 9;
	entry.ba_info.RxBitmap = mld.ba_info.RxBitmap = 7;
	rec->REC_BA_Status = active;
	rec->pEntry = missing_entry ? NULL : &entry;
	rec->TID = 2;
	rec->WaitWM = rec->Session_id = rec->RetryCnt = 7;
	rec->ba_rec_dbg = &ctl;
	ctl.numAsRecipient = zero_count ? 0 : 1;
	ctl.dbg_flag = SN_HISTORY;
	info = &entry.ba_info;
#ifdef DOT11_EHT_BE
	if (mlo) {
		info = &mld.ba_info;
		if (missing_mld) can_release = 0;
	}
#else
	expected_rcu = 0;
#endif
	readers = underflows = enters = exits = spin_errors = released_bufs = freed_debug = 0;
	ba_free_rec_entry(&ad, idx);
	if (twice) ba_free_rec_entry(&ad, idx);
	if (twice && !can_release) expected_rcu *= 2;
	CHECK(readers == 0);
	CHECK(underflows == 0);
	CHECK(enters == expected_rcu);
	CHECK(exits == expected_rcu);
	CHECK(spin_errors == 0);
	CHECK(rec->RxReRingLock == 0);
	CHECK(ctl.BATabLock == 0);
	CHECK(released_bufs == can_release);
	CHECK(freed_debug == can_release);
	CHECK(ctl.numAsRecipient == (zero_count ? 0 : 1 - can_release));
	CHECK(rec->REC_BA_Status == (can_release ? Recipient_NONE : active));
	CHECK(rec->WaitWM == (can_release ? 0 : 7));
	CHECK(rec->Session_id == (can_release ? 0 : 7));
	CHECK(rec->RetryCnt == (can_release ? 0 : 7));
	CHECK(rec->ba_rec_dbg == (can_release ? NULL : &ctl));
	CHECK(info->RecWcidArray[2] == (can_release ? 0U : 9U));
	CHECK(info->RxBitmap == (can_release ? 3U : 7U));
	printf("%s: %s; RCU enter/exit=%d/%d underflow=%d releases=%d debug=%d\n",
		name, failures == before ? "PASS" : "FAIL", enters, exits, underflows,
		released_bufs, freed_debug);
}

int main(void)
{
	run_case("none", 1, 0, 1, 0, 0, 0, 0, 0);
	run_case("none-null-entry", 1, 0, 0, 1, 0, 0, 0, 0);
	run_case("normal", 1, 1, 1, 0, 0, 0, 0, 0);
	run_case("repeated", 1, 1, 1, 0, 0, 0, 1, 0);
	run_case("invalid-entry", 1, 1, 0, 0, 0, 0, 0, 0);
	run_case("null-entry", 1, 1, 0, 1, 0, 0, 0, 0);
	run_case("mlo-normal", 1, 1, 1, 0, 1, 0, 0, 0);
	run_case("mlo-repeated", 1, 1, 1, 0, 1, 0, 1, 0);
	run_case("mlo-missing", 1, 1, 1, 0, 1, 1, 0, 0);
	run_case("mlo-missing-repeated", 1, 1, 1, 0, 1, 1, 1, 0);
	run_case("zero-index", 0, 1, 1, 0, 0, 0, 0, 0);
	run_case("out-of-range-index", MAX_LEN_OF_BA_REC_TABLE, 1, 1, 0, 0, 0, 0, 0);
	run_case("zero-recipient-count", 1, 1, 1, 0, 0, 0, 0, 1);
	printf("13 cases, %d failed assertions\n", failures);
	return failures ? 1 : 0;
}

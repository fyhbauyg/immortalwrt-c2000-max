/* Caller-state tests. The parser is stubbed: its byte-level cases are tested separately. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MAX_LEN_OF_T2LIE 255
struct tid2lnk_ie_info { unsigned int sentinel; };
struct mld_link_entry { unsigned int sentinel; };
struct mld_dev { struct { int valid; } peer_mld; };
struct wifi_dev { struct mld_dev *mld_dev; };
struct mld_conn_req { uint8_t *t2l_ie; };
static struct mld_dev mld_device;
static struct mld_link_entry link;
static int parser_calls, parser_result, disconnect_calls, link_available;
static int events[4], event_count;

static struct mld_link_entry *get_sta_mld_link_by_wdev(struct mld_dev *mld, struct wifi_dev *wdev)
{
	assert(mld == wdev->mld_dev);
	return link_available ? &link : NULL;
}

static int parse_tid_to_link_map_ie(uint8_t *ie, struct tid2lnk_ie_info *out)
{
	assert(ie);
	assert(mld_device.peer_mld.valid == 1);
	parser_calls++;
	events[event_count++] = 1;
	out->sentinel = 0x42;
	return parser_result;
}

static void sta_mld_disconn_req(struct wifi_dev *wdev)
{
	disconnect_calls++;
	events[event_count++] = 2;
	wdev->mld_dev->peer_mld.valid = 0;
}

static int run_preamble(struct wifi_dev *wdev, struct mld_conn_req *mld_conn)
{
	struct mld_dev *mld = wdev->mld_dev;
	struct mld_link_entry *set_up_link = NULL;
	struct tid2lnk_ie_info t2l_info = {0};
#include <sta-preamble.inc>
	return 0;
}

static void reset(void)
{
	mld_device.peer_mld.valid = 1;
	parser_calls = disconnect_calls = event_count = 0;
	parser_result = -1;
	link_available = 1;
	memset(events, 0, sizeof(events));
}

int main(void)
{
	struct wifi_dev wdev = { &mld_device };
	uint8_t cache[MAX_LEN_OF_T2LIE] = {0};
	struct mld_conn_req req = { cache };

	reset();
	assert(run_preamble(&wdev, &req) == 0);
	assert(parser_calls == 0 && disconnect_calls == 1);
	puts("PASS empty fixed cache remains optional, not parsed/rejected");

	reset();
	req.t2l_ie = NULL;
	assert(run_preamble(&wdev, &req) == 0);
	assert(parser_calls == 0 && disconnect_calls == 1);
	puts("PASS NULL TTLM remains optional");

	reset();
	req.t2l_ie = cache;
	cache[0] = 255; cache[1] = 2; cache[2] = 109; cache[3] = 6;
	assert(run_preamble(&wdev, &req) == -1);
	assert(parser_calls == 1 && disconnect_calls == 0 && mld_device.peer_mld.valid == 1);
	puts("PASS parser failure preserves existing peer/connection and returns failure");

	reset();
	parser_result = 0;
	assert(run_preamble(&wdev, &req) == 0);
	assert(parser_calls == 1 && disconnect_calls == 1 && events[0] == 1 && events[1] == 2);
	puts("PASS valid TTLM parsed before disconnect, no mapping programming added");

	reset();
	parser_result = 12;
	assert(run_preamble(&wdev, &req) == 0);
	assert(parser_calls == 1 && disconnect_calls == 1);
	puts("PASS nonnegative parser success return remains accepted");

	reset();
	cache[0] = 0; cache[1] = 1;
	assert(run_preamble(&wdev, &req) == -1);
	assert(parser_calls == 1 && disconnect_calls == 0);
	puts("PASS nonzero malformed cache is not treated as absent");

	reset();
	cache[0] = 255; cache[1] = 0;
	assert(run_preamble(&wdev, &req) == -1);
	assert(parser_calls == 1 && disconnect_calls == 0);
	puts("PASS extension ID with zero length is not treated as absent");

	for (unsigned len = 254; len <= 255; ++len) {
		reset();
		cache[0] = 255; cache[1] = (uint8_t)len;
		assert(run_preamble(&wdev, &req) == -1);
		assert(parser_calls == 0 && disconnect_calls == 0 && mld_device.peer_mld.valid == 1);
	}
	puts("PASS declared IE larger than fixed cache rejected before parser");

	reset();
	cache[1] = 253;
	parser_result = 0;
	assert(run_preamble(&wdev, &req) == 0);
	assert(parser_calls == 1 && disconnect_calls == 1);
	puts("PASS cache size boundary reaches parser");

	reset();
	assert(run_preamble(&wdev, NULL) == -1);
	assert(parser_calls == 0 && disconnect_calls == 0);
	link_available = 0;
	assert(run_preamble(&wdev, &req) == -1);
	assert(parser_calls == 0 && disconnect_calls == 0);
	puts("PASS invalid request or missing setup link causes no state changes");
	return 0;
}

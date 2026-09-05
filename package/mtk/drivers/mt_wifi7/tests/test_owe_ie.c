#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

#define HOSTAPD_OWE_SUPPORT 1
#define EID_EXT_ECDH 32
#define TRUE 1
#define FALSE 0
#define MTWF_DBG(...) ((void)0)
#define NdisMoveMemory memmove
#define os_zero_mem(p, n) memset(p, 0, n)
typedef struct __attribute__((packed)) {
    uint8_t ext_ie_id, length, ext_id_ecdh;
    uint16_t group;
    uint8_t public_key[128];
} ecdh_t;
typedef struct { uint8_t id, Len, Octet[255]; } ie_t;
typedef struct { uint64_t before; ecdh_t ecdh_ie; uint64_t after; } list_t;

/* The case body is extracted from the real patched driver, not reimplemented. */
static int parse(list_t *ie_lists, ie_t *eid_ptr) {
    switch (eid_ptr->Octet[0]) {
#include "owe-copy-fragment.inc"
        break;
    default: return FALSE;
    }
    return TRUE;
}
int main(void) {
    ie_t src;
    list_t dst;
    for (unsigned len = 0; len <= 255; ++len) {
        memset(&src, 0x5a, sizeof(src));
        src.id = 255; src.Len = len; src.Octet[0] = EID_EXT_ECDH;
        memset(&dst, 0xa5, sizeof(dst));
        int accepted = parse(&dst, &src);
        assert(accepted == (len >= 3 && len <= sizeof(ecdh_t)-2));
        assert(dst.before == UINT64_C(0xa5a5a5a5a5a5a5a5));
        assert(dst.after == UINT64_C(0xa5a5a5a5a5a5a5a5));
        if (accepted) {
            assert(memcmp(&dst.ecdh_ie, &src, len+2) == 0);
            for (unsigned i=len+2; i<sizeof(ecdh_t); ++i)
                assert(((uint8_t *)&dst.ecdh_ie)[i] == 0);
        }
    }
    puts("OWE: all 256 IE lengths passed, canaries intact (ASan/UBSan/FORTIFY)");
}

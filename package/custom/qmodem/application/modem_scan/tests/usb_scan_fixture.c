#include <assert.h>
#include <fcntl.h>
#include <errno.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
static const char *fixture_root;
static int fixture_open(const char *path, int flags, ...)
{
    /* Never register drivers or mutate real sysfs during this test. */
    if (!strncmp(path, "/sys/", 5)) { errno = ENOENT; return -1; }
    return open(path, flags);
}
#define QMODEM_USB_SYSFS fixture_root
#define open fixture_open
#define main modem_scand_main
#include "../src/modem_scand.c"
#undef main
#undef open
int main(int argc, char **argv)
{
    struct scan_result res = {0};
    assert(argc == 5);
    int expected_ports = atoi(argv[4]);
    fixture_root = argv[1];
    g.port_rule_json = json_object_from_file(argv[2]);
    assert(g.port_rule_json);
    scan_usb_slot("2-1", &res);
    if (!sl_contains(&res.net_devices, "usb0")) {
        fprintf(stderr, "FAIL: bound network interface was hidden by AT include rule (%s)\n", argv[3]);
        return 1;
    }
    assert(res.net_devices.len == 1);
    assert(res.at_ports.len == (size_t)expected_ports);
    assert(sl_contains(&res.at_ports, "/dev/ttyUSB1"));
    if (expected_ports == 1) {
        assert(!sl_contains(&res.at_ports, "/dev/ttyUSB0"));
        assert(!sl_contains(&res.at_ports, "/dev/ttyUSB4"));
    }
    assert(!sl_contains(&res.net_devices, "unrelated0"));
    sl_free(&res.net_devices); sl_free(&res.at_ports);
    json_object_put(g.port_rule_json);
    printf("PASS: %s network retained, AT filter and slot isolation preserved\n", argv[3]);
    return 0;
}

#!/usr/bin/env python3
"""Replay redacted SRM825 USB topology using the actual C scanner, without hardware."""
import os, pathlib, subprocess, tempfile
here = pathlib.Path(__file__).resolve().parent
repo = here.parents[5]
include = os.environ.get("JSON_C_INCLUDE", str(repo / "staging_dir/host/include"))
library = os.environ.get("JSON_C_LIBRARY", str(repo / "staging_dir/host/lib/libjson-c.a"))
rule = here.parents[1] / "qmodem/files/usr/share/qmodem/modem_port_rule.json"
with tempfile.TemporaryDirectory(prefix="qmodem-usb-test-") as tmp:
    tmp = pathlib.Path(tmp)
    binary = tmp / "test-usb"
    subprocess.run(["cc", "-D_GNU_SOURCE", "-std=c99", "-O0", "-ffunction-sections", "-fdata-sections", "-I"+include, str(here/"usb_scan_fixture.c"), "-Wl,--gc-sections", library, "-lpthread", "-o", str(binary)], check=True)
    cases = [(d, "2dee", "4d23", 1) for d in ("cdc_ether", "rndis_host", "qmi_wwan_q", "cdc_mbim", "cdc_ncm")]
    cases.append(("cdc_ether", "3466", "3301", 5))
    for driver, vid, pid, expected in cases:
        root = tmp / (driver+vid); slot = root / "2-1"; slot.mkdir(parents=True)
        (slot/"idVendor").write_text(vid+"\n"); (slot/"idProduct").write_text(pid+"\n")
        drivers = root / "drivers"; drivers.mkdir()
        for name in ("option", driver): (drivers/name).mkdir(exist_ok=True)
        for number in range(7):
            interface = slot / f"2-1:1.{number}"; interface.mkdir()
            (interface/"driver").symlink_to(drivers/("option" if number < 5 else driver))
            if number < 5: (interface/f"ttyUSB{number}").mkdir()
            if number == 5: (interface/"net/usb0").mkdir(parents=True)
        (root/"3-1/3-1:1.5/net/unrelated0").mkdir(parents=True)
        subprocess.run([str(binary), str(root), str(rule), driver+" "+vid+":"+pid, str(expected)], check=True)

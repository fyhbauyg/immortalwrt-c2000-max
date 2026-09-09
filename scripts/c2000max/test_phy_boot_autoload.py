#!/usr/bin/env python3
"""Host-only check of the MT798x PHY package's early-boot installation.

Run in WSL: python3 test_phy_boot_autoload.py /path/to/openwrt-tree
Only reads the supplied tree. GNU make writes into an isolated temporary
directory; this script never accesses the router or changes network settings.
"""

import argparse
import re
import subprocess
import tempfile
from pathlib import Path


PACKAGE = Path("package/mtk/drivers/mt798x-2p5g-phy-firmware-internal")
MODULE_PACKAGE = "mt798x-2p5g-phy"
MODULE_NAME = "mtk-2p5ge"
FIRMWARE_NAMES = ("i2p5ge-phy-pmb.bin", "i2p5ge-phy-DSPBitTb.bin")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def make_definition(source, name):
    match = re.search(
        rf"^define {re.escape(name)}[ \t]*\n.*?^endef[ \t]*$",
        source,
        flags=re.MULTILINE | re.DOTALL,
    )
    require(match is not None, f"Missing make definition: {name}")
    return match.group(0)


def check_boot_autoload(root):
    package_text = (root / PACKAGE / "Makefile").read_text()
    kernel_text = (root / "include/kernel.mk").read_text()
    package_definition = make_definition(
        package_text, f"KernelPackage/{MODULE_PACKAGE}"
    )
    autoload_line = re.search(
        r"^[ \t]*AUTOLOAD\s*:=\s*(.+)$", package_definition, re.MULTILINE
    )
    require(autoload_line is not None, "PHY kernel package has no AUTOLOAD")
    autoload_expression = autoload_line.group(1).strip()
    autoload_call = re.fullmatch(
        r"\$\(call\s+AutoLoad\s*,\s*(\d+)\s*,\s*mtk-2p5ge\s*,\s*(\d+)\s*\)",
        autoload_expression,
    )
    require(autoload_call is not None, "Expected explicit PHY AutoLoad priority and boot flag")
    priority, boot_flag = map(int, autoload_call.groups())
    require(15 < priority < 20, "PHY must load after priority 15 and before priority 20")
    require(boot_flag == 1, "PHY must be included in modules-boot.d")

    # Evaluate the actual repository macros, including AutoLoad's helper,
    # rather than approximating their filesystem behavior in Python.
    version_filter = re.search(r"^version_filter=.*$", kernel_text, re.MULTILINE)
    require(version_filter is not None, "Missing actual version_filter helper")
    macros = "\n\n".join(
        (
            version_filter.group(0),
            make_definition(kernel_text, "AutoLoad"),
            make_definition(kernel_text, "ModuleAutoLoad"),
        )
    )
    # This is the argument expansion used by KernelPackage's installation
    # recipe; OUT replaces that recipe's installation-prefix argument.
    install_call = (
        "$(call ModuleAutoLoad," + MODULE_PACKAGE + ",$(OUT),"
        "$(filter-out 0-,$(word 1,$(AUTOLOAD))-),"
        "$(filter-out 0,$(word 2,$(AUTOLOAD))),"
        "$(sort $(wordlist 3,99,$(AUTOLOAD))))"
    )
    with tempfile.TemporaryDirectory(prefix="c2000-phy-boot-") as directory:
        temporary = Path(directory)
        makefile = temporary / "Makefile"
        makefile.write_text(
            macros
            + "\n\nAUTOLOAD:=" + autoload_expression
            + "\nOUT:=output\n.PHONY: all\nall:\n\t"
            + install_call + "\n"
        )
        completed = subprocess.run(
            ["make", "--no-print-directory", "-f", str(makefile), "all"],
            cwd=temporary,
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
        require(
            completed.returncode == 0,
            "Actual make macro installation failed:\n"
            + completed.stdout + completed.stderr,
        )
        filename = f"{priority:02d}-{MODULE_PACKAGE}"
        module_file = temporary / "output/etc/modules.d" / filename
        boot_link = temporary / "output/etc/modules-boot.d" / filename
        require(module_file.is_file(), f"Missing installed module list: {filename}")
        require(module_file.read_text() == MODULE_NAME + "\n", "Wrong module list contents")
        require(boot_link.is_symlink(), "Early-boot entry must be a symlink")
        require(
            boot_link.readlink() == Path("../modules.d") / filename,
            "Early-boot symlink must point relatively to the matching module list",
        )
        require(boot_link.resolve() == module_file.resolve(), "Early-boot symlink is broken")
        print(f"PASS: actual make macros install {filename} and its relative boot symlink")

    require(
        "+mt798x-2p5g-phy-firmware-internal" in package_definition,
        "PHY module must depend on its firmware package",
    )
    install_definition = make_definition(
        package_text, "Package/mt798x-2p5g-phy-firmware-internal/install"
    )
    for name in FIRMWARE_NAMES:
        firmware = root / PACKAGE / "files/mt7987" / name
        require(firmware.is_file() and firmware.stat().st_size > 0, f"Missing/empty firmware: {name}")
        expected_copy = (
            rf"^[ \t]*cp[ \t]+\./files/mt7987/{re.escape(name)}"
            rf"[ \t]+\$\(1\)/lib/firmware/mediatek/mt7987/{re.escape(name)}[ \t]*$"
        )
        require(
            re.search(expected_copy, install_definition, re.MULTILINE) is not None,
            f"Firmware install recipe does not copy {name} to the early rootfs path",
        )
    print("PASS: both MT7987 firmware files are nonempty, installed, and package-required")


def check_preinit_port(root):
    source = (
        root / "target/linux/mediatek/base-files/lib/preinit/05_set_preinit_iface"
    ).read_text()
    branch = re.search(r"nradio,c2000-max[^\n]*\n(.*?)^[ \t]*;;", source, re.MULTILINE | re.DOTALL)
    require(branch is not None, "Missing C2000-MAX preinit board branch")
    body = branch.group(1)
    require(re.search(r"^[ \t]*ip link set eth1 up[ \t]*$", body, re.MULTILINE), "Preinit must bring up eth1")
    require(re.search(r"^[ \t]*ifname=eth1[ \t]*$", body, re.MULTILINE), "Preinit must select eth1")
    require("ethtool" not in body, "Preinit must not override user link settings using ethtool")
    print("PASS: C2000-MAX preinit retains eth1 without an ethtool override")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path, help="OpenWrt source tree; read-only")
    args = parser.parse_args()
    root = args.source_root.resolve(strict=True)
    check_boot_autoload(root)
    check_preinit_port(root)
    print("PASS: all host-only PHY early-boot checks")


if __name__ == "__main__":
    main()

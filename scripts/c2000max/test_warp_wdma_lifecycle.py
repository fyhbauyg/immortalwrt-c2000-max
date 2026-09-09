#!/usr/bin/env python3
"""Desktop-only WARP lifecycle tests against an explicitly supplied source tree.

Usage: python3 test_wdma_lifecycle.py --source /path/to/prepared/warp [--json]
Requires GCC with AddressSanitizer and UndefinedBehaviorSanitizer support.
The supplied source directory and this test directory are read-only inputs;
all generated C and executables live in an automatically removed temp directory.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile


FUNCTIONS = (
    ("regs/reg_v3_1/warp_mt7987.c", "warp_get_wdma_port("),
    ("warp_platform/warp_mtk.c", "wifi_tx_tuple_add("),
    ("warp_platform/warp_mtk.c", "wdma_pse_port_config_state("),
    ("wdma.c", "wdma_init("),
    ("warp_main.c", "warp_probe("),
    ("warp_main.c", "warp_register_client("),
)
TOKENS = re.compile(
    r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]',
    re.S,
)


def extract(source, name):
    """Copy the actual function; ignore comment/string braces when delimiting."""
    start = source.index(name)
    # These WARP definitions put the return type on the preceding line.
    start = source.rfind("\n", 0, start - 1) + 1
    body = source.index("{", start)
    depth = 0
    for match in TOKENS.finditer(source, body):
        if match.group() == "{":
            depth += 1
        elif match.group() == "}":
            depth -= 1
            if depth == 0:
                return source[start:match.end()] + "\n"
    raise ValueError(f"Cannot delimit {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path,
                        help="Prepared/patched WARP source directory (read only)")
    parser.add_argument("--json", action="store_true", help="Emit result JSON to stdout")
    args = parser.parse_args()
    source_dir = args.source.resolve(strict=True)
    if not source_dir.is_dir():
        parser.error("--source must name a WARP directory")
    fixture = Path(__file__).resolve().with_name("wdma_lifecycle_host.c")
    source_text = {}
    source_hashes = {}
    for relative, _ in FUNCTIONS:
        if relative not in source_text:
            data = (source_dir / relative).read_bytes()
            source_hashes[relative] = hashlib.sha256(data).hexdigest()
            source_text[relative] = data.decode("utf-8")
    functions = [extract(source_text[relative], name) for relative, name in FUNCTIONS]
    harness = fixture.read_text(encoding="utf-8")
    if harness.count("/* DRIVER_FUNCTIONS */") != 1:
        raise ValueError("Fixture must contain one function insertion marker")
    generated = harness.replace("/* DRIVER_FUNCTIONS */", "\n".join(functions))
    runs = []
    # No artifact is written beside the script or inside the source tree.
    with tempfile.TemporaryDirectory(prefix="c2000max-wdma-lifecycle-") as temporary:
        work = Path(temporary)
        test_file = work / "wdma_lifecycle_generated.c"
        test_file.write_text(generated, encoding="utf-8")
        for rro2 in (False, True):
            binary = work / ("test-rro2" if rro2 else "test-v31")
            flags = ["-DCONFIG_WARP_V3_1", "-DCONFIG_WARP_DBG_SUPPORT",
                     "-DWED_INTER_AGENT_SUPPORT", "-DWED_RX_D_SUPPORT"]
            if rro2:
                flags.append("-DWED_RX_HW_RRO_2_0")
            subprocess.run(
                ["gcc", "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                 "-Wno-unused-function", "-Wno-unused-parameter", "-g",
                 "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-no-pie",
                 *flags, str(test_file), "-o", str(binary)],
                check=True, cwd=work,
            )
            result = subprocess.run([str(binary)], check=True, capture_output=True,
                                    text=True, cwd=work)
            match = re.fullmatch(r"PASS: (\d+) checks\s*", result.stdout)
            if not match:
                raise RuntimeError(f"Unexpected test output: {result.stdout!r}")
            count = int(match.group(1))
            if count != 91:
                raise RuntimeError(f"Expected 91 checks per configuration, got {count}")
            runs.append({"rro2": rro2, "checks": count, "result": "PASS"})
    total = sum(run["checks"] for run in runs)
    record = {
        "result": "PASS", "checks": total, "runs": runs,
        "source": str(source_dir), "source_sha256": source_hashes,
        "fixture_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
        "generated_sha256": hashlib.sha256(generated.encode("utf-8")).hexdigest(),
        "temporary_outputs_removed": True,
    }
    if args.json:
        print(json.dumps(record, indent=2))
    else:
        for run in runs:
            print(f"rro2={run['rro2']}: PASS: {run['checks']} checks")
        print(f"PASS: {total} checks; temporary outputs removed")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Replay SRM825L model replies using the actual scanner, without a modem."""
import os
import pathlib
import subprocess
import tempfile

here = pathlib.Path(__file__).resolve().parent
repo = here.parents[5]
include = os.environ.get("JSON_C_INCLUDE", str(repo / "staging_dir/host/include"))
library = os.environ.get("JSON_C_LIBRARY", str(repo / "staging_dir/host/lib/libjson-c.a"))
support = here.parents[1] / "qmodem/files/usr/share/qmodem/modem_support.json"
with tempfile.TemporaryDirectory(prefix="qmodem-profile-test-") as tmp:
    binary = pathlib.Path(tmp) / "test-profile"
    subprocess.run([
        "cc", "-D_GNU_SOURCE", "-std=c99", "-O0", "-ffunction-sections",
        "-fdata-sections", "-I" + include, str(here / "model_profile_fixture.c"),
        "-Wl,--gc-sections", library, "-lpthread", "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary), str(support)], check=True)

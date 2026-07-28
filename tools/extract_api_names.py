#!/usr/bin/env python3
"""Extract the Vectric Lua binding names from an installed VCarve/Aspire build.

The gadget's integration test (tests/run_api_tests.lua) asserts that every
property and method name the gadget touches actually exists in the host
application. That list comes from here.

Why this exists: Vectric's own sample gadgets set `tool.VBitAngle`, which is
not a real binding - the property is `VBit_Angle`. Setting the wrong name
fails silently and produces a V-carve at the default angle. Checking against
the shipped binary catches that class of mistake before it reaches a router.

Usage:
    python tools/extract_api_names.py [path-to-exe] [-o tests/api_names.lua]

The default exe path is the VCarve Pro 12.5 trial install location.
"""

import argparse
import re
import sys
from pathlib import Path

DEFAULT_EXE = Path(
    r"C:\Program Files\VCarve Pro Trial Edition 12.5"
    r"\x64\VCarveProTrialEdition.exe"
)

# The luabind registration strings sit in one contiguous run of .rdata.
# These bounds bracket that run in the 12.5 build; they are deliberately
# generous. Widen them if a future build moves the table.
REGION_START = 0x039E0000
REGION_END = 0x03BB0400

IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]{1,45}\Z")

# Minimum 2, not 4: several real bindings are three characters (Box3D.BLC,
# .TRC, .TLC, .BRC) and a longer minimum silently drops them.
PRINTABLE = re.compile(rb"[ -~]{2,}")

# Names we expect to find. If any of these is missing the region bounds are
# wrong and the generated table would be uselessly incomplete.
CANARIES = [
    "CreatePocketingToolpath",
    "CreateProfilingToolpath",
    "CreateDrillingToolpath",
    "CreateVCarvingToolpath",
    "PocketParameterData",
    "ProfileParameterData",
    "GeometryFilterUsed",
    "VBit_Angle",
    "ToolDia",
    "BLC",   # three-character names: guards the PRINTABLE minimum length
    "TRC",
]


def extract(exe_path: Path) -> set[str]:
    data = exe_path.read_bytes()
    names = set()
    for match in PRINTABLE.finditer(data):
        if not (REGION_START <= match.start() <= REGION_END):
            continue
        text = match.group().decode("ascii")
        if IDENTIFIER.match(text):
            names.add(text)
    return names


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("exe", nargs="?", type=Path, default=DEFAULT_EXE)
    parser.add_argument("-o", "--output", type=Path,
                        default=Path(__file__).parent.parent / "tests" / "api_names.lua")
    args = parser.parse_args()

    if not args.exe.is_file():
        print(f"error: no such file: {args.exe}", file=sys.stderr)
        print("Pass the path to your VCarve or Aspire executable.", file=sys.stderr)
        return 1

    names = extract(args.exe)

    missing = [c for c in CANARIES if c not in names]
    if missing:
        print(f"error: expected names not found: {', '.join(missing)}", file=sys.stderr)
        print("The binding string region has moved; adjust REGION_START/REGION_END.",
              file=sys.stderr)
        return 2

    lines = [
        f"-- Generated from {args.exe.name} - luabind binding string table.",
        "-- Regenerate with tools/extract_api_names.py. Do not hand-edit.",
        "return {",
    ]
    lines += [f'   ["{name}"] = true,' for name in sorted(names)]
    lines.append("}")

    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {len(names)} names to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

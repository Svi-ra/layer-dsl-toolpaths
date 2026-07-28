#!/usr/bin/env python3
"""Run the gadget's Lua test suites.

VCarve embeds Lua 5.2 but does not expose an interpreter, and Windows rarely
has a standalone `lua` on PATH. This driver runs the suites through lupa so
the tests are runnable without installing Lua:

    pip install lupa
    python tools/run_tests.py

If you do have a Lua interpreter, the suites run directly too:

    lua tests/run_tests.lua
    lua tests/run_api_tests.lua
    lua tests/run_runner_tests.lua

The gadget targets Lua 5.2 syntax; the suites are plain enough to run on any
5.x, which is why a newer embedded Lua is an acceptable test host.
"""

import sys
from pathlib import Path

try:
    from lupa import LuaRuntime
except ImportError:
    print("error: lupa is not installed.  pip install lupa", file=sys.stderr)
    raise SystemExit(1)

ROOT = Path(__file__).resolve().parent.parent

SUITES = [
    ("JSON codec", "tests/run_json_tests.lua"),
    ("SmartCAM database", "tests/run_db_tests.lua"),
    ("DSL parser", "tests/run_tests.lua"),
    ("Toolpath factory / VCarve API contract", "tests/run_api_tests.lua"),
    ("Layer scan, plan and execute", "tests/run_runner_tests.lua"),
]


def run(script: Path) -> tuple[int, str]:
    """Run one suite in a fresh Lua state. Returns (exit_code, output)."""
    lua = LuaRuntime(unpack_returned_tuples=True)

    captured: list[str] = []
    lua.globals().python_print = captured.append

    # Route print() into the buffer and turn os.exit into a catchable error so
    # a failing suite does not tear down this process.
    lua.execute("""
        local emit = python_print
        print = function(...)
           local parts = {}
           for i = 1, select("#", ...) do
              parts[#parts + 1] = tostring((select(i, ...)))
           end
           emit(table.concat(parts, "\\t"))
        end
        _exit_code = 0
        os.exit = function(code) _exit_code = code or 0; error("__EXIT__", 0) end
    """)

    lua.globals().arg = lua.table_from({0: script.as_posix()})

    try:
        chunk = lua.eval(f'assert(loadfile("{script.as_posix()}"))')
        chunk()
    except Exception as exc:  # noqa: BLE001 - any Lua error is a suite failure
        if "__EXIT__" not in str(exc):
            captured.append(f"LUA ERROR: {exc}")
            return 2, "\n".join(captured)

    return int(lua.eval("_exit_code") or 0), "\n".join(captured)


def main() -> int:
    worst = 0
    for label, relative in SUITES:
        script = ROOT / relative
        if not script.is_file():
            print(f"  MISSING  {relative}")
            worst = max(worst, 2)
            continue

        code, output = run(script)
        status = "PASS" if code == 0 else "FAIL"
        print(f"{status}  {label}  ({relative})")
        print(output.rstrip())
        worst = max(worst, code)

    print("=" * 62)
    print("All suites passed." if worst == 0 else "SUITE FAILURES - see above.")
    return worst


if __name__ == "__main__":
    raise SystemExit(main())

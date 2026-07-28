#!/usr/bin/env python3
"""Check that every JSON example in docs/TOOLS.md actually works.

Documentation that drifts from the code is worse than none, so each example
is decoded by the gadget's own JSON codec, validated by the real
ToolRepository, and built into a VCarve Tool through the recording mock -
which also asserts that only genuine VCarve property names are touched.

Run directly, or as part of `python tools/run_tests.py`.
"""

import re
import sys
from pathlib import Path

try:
    from lupa import LuaRuntime
except ImportError:
    print("error: lupa is not installed.  pip install lupa", file=sys.stderr)
    raise SystemExit(1)

ROOT = Path(__file__).resolve().parent.parent
DOC = ROOT / "docs" / "TOOLS.md"

# Examples that are illustrative rather than real records.
PLACEHOLDER = '"..."'


def json_blocks(text: str) -> list[tuple[int, str]]:
    """Every ```json fenced block, with the line it starts on."""
    blocks = []
    for match in re.finditer(r"```json\n(.*?)```", text, re.DOTALL):
        line = text[: match.start()].count("\n") + 1
        blocks.append((line, match.group(1)))
    return blocks


def build_runtime() -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lib = (ROOT / "LayerDSL_Toolpaths" / "lib").as_posix()
    tests = (ROOT / "tests").as_posix()

    lua.execute(f'''
        API  = dofile("{tests}/api_names.lua")
        Mock = dofile("{tests}/mock_vectric.lua")

        Json   = dofile("{lib}/db/json.lua")
        Coerce = dofile("{lib}/coerce.lua")
        Store  = dofile("{lib}/db/store.lua")
        Seed   = dofile("{lib}/db/seed.lua").init(Json)
        Repo   = dofile("{lib}/db/tool_repository.lua")

        function CheckExample(text)
            local record, err = Json.decode(text)
            if record == nil then return "JSON did not parse: " .. tostring(err) end
            if type(record) ~= "table" then return "not a JSON object" end

            local problems = Repo.validate(record)
            if #problems > 0 then
                return "rejected by validation: " .. table.concat(problems, "; ")
            end

            -- Build it for real, against the recording mock.
            Mock.install(API, {{}})
            local Enums   = dofile("{lib}/enums.lua")
            local Tooling = dofile("{lib}/tooling.lua").init(Enums, Coerce, Repo)

            local tool, build_err = Tooling.build_tool(record)
            if tool == nil then return "did not build: " .. tostring(build_err) end

            if #Mock.violations > 0 then
                return "touched names VCarve does not have: "
                       .. table.concat(Mock.violations, ", ")
            end

            local store = Mock.last("Tool")
            return nil, store.__name, store.__type
        end
    ''')
    return lua


def main() -> int:
    if not DOC.is_file():
        print(f"error: {DOC} not found", file=sys.stderr)
        return 2

    text = DOC.read_text(encoding="utf-8")
    lua = build_runtime()
    check = lua.eval("CheckExample")

    checked = failed = skipped = 0

    for line, block in json_blocks(text):
        label = f"{DOC.name}:{line}"

        if PLACEHOLDER in block:
            skipped += 1
            print(f"  skip  {label}  (illustrative, has placeholders)")
            continue

        # Only single tool records are runnable examples.
        stripped = block.strip()
        if not stripped.startswith("{") or '"id"' not in stripped:
            skipped += 1
            print(f"  skip  {label}  (not a tool record)")
            continue

        result = check(stripped)
        problem, name, kind = (result if isinstance(result, tuple)
                               else (result, None, None))

        checked += 1
        if problem:
            failed += 1
            print(f"  FAIL  {label}\n        {problem}")
        else:
            print(f"  ok    {label}  {name} -> {kind}")

    print()
    print(f"  {checked} example(s) checked, {failed} failed, {skipped} skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

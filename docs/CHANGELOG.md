# Project Change Log

All changes to this installed VCarve gadget copy must be recorded here.

Each entry should say:

- date
- files changed
- reason for the change
- what was attempted
- what failed or was uncertain
- final decision
- verification performed

## 2026-07-28 - Correct SmartCAM Path For Active Fork

Files changed:

- `LayerDSL_Toolpaths/config.lua`
- `docs/CHANGELOG.md`

Reason:

- The active project is the Git fork installed at `C:\Users\Public\Documents\Vectric Files\Gadgets\VCarve Pro V12.5\LayerDSL_Toolpaths\layer-dsl-toolpaths`.
- The correct SmartCAM database for this fork is `C:\SmartCAM`, not `C:\Users\Victor\Desktop\vcrv\SmartCAM`.

What was done:

- Changed `database.path` to `C:\SmartCAM`.
- Kept `use_environment = false` so `SMARTCAM_DB` cannot silently point VCarve to another database.

What failed or was uncertain:

- The previous path change to `C:\Users\Victor\Desktop\vcrv\SmartCAM` was based on the older working copy context, not the active fork context.

Final decision:

- Work directly in the installed Git fork and use `C:\SmartCAM` as the active SmartCAM JSON database.

Verification:

- Ran `tools/run_tests.py` with the bundled Codex Python.
- Result: 757 passed, 0 failed.
- Confirmed `C:\SmartCAM\tools.json` exists and contains the active local SmartCAM tool records.

## 2026-07-28 - Add Missing SmartCAM Tool 5 Placeholder

Files changed:

- `C:\SmartCAM\tools.json`
- `docs/CHANGELOG.md`

Reason:

- VCarve reported that layer `Profile_tool_5_depth_2.7` could not create a toolpath because no tool with `id = 5` existed in `C:\SmartCAM\tools.json`.

What was done:

- Added SmartCAM tool record `id = 5`, `tool_number = 5`, named `End Mill 5mm`.
- Set it as `type = "end_mill"` so `Profile_tool_5_depth_2.7` can resolve a profile cutter.
- Marked the record as a placeholder that must be checked before cutting.

What failed or was uncertain:

- No existing authoritative definition for tool 5 was found in the local SmartCAM copies.
- Feed, plunge, spindle, stepdown and stepover values are provisional and must be replaced with the real workshop cutter parameters before production machining.

Final decision:

- Add a safe, explicit placeholder for tool 5 rather than changing the layer name, because the current VCarve error is specifically a missing SmartCAM tool id.

Verification:

- Validated `C:\SmartCAM\tools.json` as JSON.
- Ran `tools/run_tests.py` with the bundled Codex Python.
- Result: 757 passed, 0 failed.
- Pending: rerun the gadget in VCarve and confirm `Profile_tool_5_depth_2.7` creates its toolpath.

## 2026-07-28 - Improve Profile Calculation Failure Message

Files changed:

- `LayerDSL_Toolpaths/lib/ops/profile.lua`
- `docs/CHANGELOG.md`

Reason:

- After tool 5 was added, VCarve found the tool but still returned no profile toolpath for `Profile_tool_5_depth_2.7`.
- The previous message did not show the active profile defaults, so it was not clear whether VCarve failed because of open/closed vector selection, inside/outside side selection, or another geometry issue.

What was done:

- Expanded the profile calculation failure message to include `side`, `vector_selection`, `tool` and `depth`.
- Added a direct hint that open vectors should use `side_on_vector_selection_open`.

What failed or was uncertain:

- VCarve does not return a detailed failure reason from `CreateProfilingToolpath`; it only returns no id.
- The actual drawing geometry still needs to be checked in VCarve.

Final decision:

- Keep the profile operation behavior unchanged and make the runtime error more diagnostic.

Verification:

- Ran `tools/run_tests.py` with the bundled Codex Python.
- Result: 757 passed, 0 failed.
- Pending: rerun the gadget in VCarve; if the same geometry fails, the dialog should now show the active profile side and vector selection.

## 2026-07-28 - Restore Tool 5 From Previous SmartCAM Definition

Files changed:

- `C:\SmartCAM\tools.json`
- `docs/CHANGELOG.md`

Reason:

- `Profile_tool_5_depth_2.7` still failed after adding a generic `End Mill 5mm` placeholder.
- The previous SmartCAM share at `\\Desktop-0rne27t\c\SmartCAM\tools.json` showed that tool `id = 5` was actually a `V-Bit 90 degree`, not an end mill.

What was done:

- Replaced the placeholder `End Mill 5mm` record with the previous tool 5 definition:
  `type = "vbit"`, `diameter = 12.0`, `included_angle = 90.0`, `tool_number = 5`.

What failed or was uncertain:

- The old share still has unrelated bad data for tool `id = 1` because it is a V-bit without `included_angle`.
- Only tool `id = 5` was copied from the old share to avoid reintroducing the previous `tool 1` error.

Final decision:

- Keep `C:\SmartCAM` as the active database, but restore tool 5 to the definition that matched the earlier working VCarve behavior.

Verification:

- Validated `C:\SmartCAM\tools.json` as JSON.
- Ran `tools/run_tests.py` with the bundled Codex Python.
- Result: 757 passed, 0 failed.
- Pending: rerun the same VCarve job with `Profile_tool_5_depth_2.7` unchanged.

## 2026-07-28 - Default V-Bit Profile Layers To On-Line Cutting

Files changed:

- `LayerDSL_Toolpaths/lib/ops/profile.lua`
- `tests/db_helper.lua`
- `tests/run_api_tests.lua`
- `docs/CHANGELOG.md`

Reason:

- `Profile_tool_5_depth_2.7` uses tool 5, which is a V-bit in the previous working SmartCAM database.
- The Profile operation defaulted to `side = outside`, which is natural for end mills but can make VCarve fail or offset incorrectly for V-bit line engraving/profile work.

What was done:

- If a Profile layer uses a V-bit and does not explicitly set `side`, the operation now uses `side = on`.
- Explicit layer choices still win: `side_outside`, `side_inside` and `side_on` keep the user's requested value.
- Removed the V-bit mismatch warning for this automatic on-line case.
- Added an API regression test for `Profile_tool_5_depth_2.7`.

What failed or was uncertain:

- VCarve only reports that profile calculation failed; it does not return detailed geometry diagnostics.
- This change targets the known V-bit case without changing normal end mill Profile defaults.

Final decision:

- Preserve existing end mill Profile behavior, but make V-bit Profile layers default to on-line cutting when the layer did not specify a side.

Verification:

- Ran `tools/run_tests.py` with the bundled Codex Python.
- Result: 765 passed, 0 failed.
- Added regression coverage confirming `Profile_tool_5_depth_2.7` uses `PROFILE_ON` when tool 5 is a V-bit and no side was explicitly set.

## 2026-07-28 - Default V-Bit Profile Selection To All Vectors

Files changed:

- `LayerDSL_Toolpaths/lib/ops/profile.lua`
- `tests/run_api_tests.lua`
- `docs/CHANGELOG.md`

Reason:

- After the V-bit profile side default changed to `on`, VCarve still reported failure with `vector_selection = closed`.
- `Profile_tool_5_depth_2.7` does not explicitly say whether the vectors are open or closed, so selecting only closed vectors can drop open engraving lines from the operation.

What was done:

- If a Profile layer uses a V-bit and does not explicitly set `side`, it now defaults to `side = on`.
- If that same layer also does not explicitly set `vector_selection`, it now defaults to `vector_selection = all`.
- Explicit layer choices still win.

What failed or was uncertain:

- The actual VCarve job geometry is not visible to the tests.
- The previous failure suggests the target layer may contain open vectors or a mixed open/closed set.

Final decision:

- Treat implicit V-bit Profile layers as line-engraving/profile layers over all vectors, while keeping normal end mill Profile defaults unchanged.

Verification:

- Ran `tools/run_tests.py` with the bundled Codex Python.
- Result: 767 passed, 0 failed.
- Added regression coverage confirming implicit V-bit Profile layers select both open and closed vectors.

## 2026-07-28 - Add Moulding Reference Analysis And Probe

Files changed:

- `tools/moulding_probe/MouldingProbe.lua`
- `tools/moulding_probe/README.md`
- `docs/MOULDING-REFERENCE-2026-07-28.md`
- `docs/CHANGELOG.md`

Reason:

- A manual VCarve file `C:\Users\Victor\Desktop\1233123.crv` and DXF exports
  were provided as references for adding Moulding Toolpath support.
- Direct implementation would be risky because the VCarve API name list exposes
  `MouldingToolpath` and `uiMouldingToolpathForm`, but no clear
  `CreateMouldingToolpath` constructor.

What was done:

- Inspected `14.dxf` and recorded the rail/profile layers and geometry counts.
- Inspected `1233123.crv` as a proprietary OLE/Compound Document and confirmed
  it contains `Swept Profile 1`, `uiExtrudedToolpathForm` and `Ball Nose (8 mm)`.
- Inspected `fa123.dxf` and recorded that it only contains the exterior contour.
- Added a safe `MouldingProbe.lua` gadget that reads existing saved toolpath
  metadata from an open VCarve job and writes a report.

What failed or was uncertain:

- `.crv` is not plain text and cannot be fully decoded without VCarve's own API.
- `fa123.dxf` does not include the rail/profile geometry.
- It is still unknown whether VCarve allows creating a new Moulding Toolpath
  directly from Lua.

Final decision:

- Run the probe on the manual `.crv` reference before adding Moulding to the
  main Layer DSL operation list.

Verification:

- Pending: run `MouldingProbe.lua` inside VCarve with `1233123.crv` open.

## 2026-07-28 - Add Experimental Moulding DSL Operation

Files changed:

- `LayerDSL_Toolpaths/lib/schema.lua`
- `LayerDSL_Toolpaths/lib/factory.lua`
- `LayerDSL_Toolpaths/lib/ops/moulding.lua`
- `LayerDSL_Toolpaths/config.lua`
- `tests/db_helper.lua`
- `tests/mock_vectric.lua`
- `tests/run_tests.lua`
- `tests/run_api_tests.lua`
- `tests/run_db_tests.lua`
- `C:\SmartCAM\tools.json`
- `C:\Users\Victor\Desktop\fa124_layerdsl_moulding.dxf`
- `docs/CHANGELOG.md`

Reason:

- `fa124.dxf` contains all required geometry for the Moulding test: exterior
  contour, 36 rail vectors and a profile/section layer.
- The project needs a first DSL-aligned Moulding attempt that can be run the
  same way as the existing operations.

What was done:

- Added operation aliases `Moulding`, `Molding`, `sweep` and `swept`.
- Added parameter `profile_layer`.
- Added default Moulding config: `vector_selection = "open"` and
  `profile_layer = "mouldingprofile"`.
- Added `ops/moulding.lua` using the experimental
  `MouldingToolpath` + `ToolpathManager:AddToolpath` path exposed by VCarve's
  API name list.
- Added SmartCAM tool `id = 11`, `Ball Nose 8mm`, for the Moulding reference.
- Created `C:\Users\Victor\Desktop\fa124_layerdsl_moulding.dxf`:
  - rail layer renamed to `Moulding_tool_11_profile_layer_mouldingprofile`
  - profile layer renamed to `mouldingprofile`

What failed or was uncertain:

- Local tests can confirm API names and argument shape, but cannot prove VCarve
  will calculate a real Moulding Toolpath.
- VCarve exposes `MouldingToolpath` but no documented
  `CreateMouldingToolpath`; this first implementation is therefore
  experimental.
- Properties `RailSelector` and `ProfileSelector` were rejected by the API-name
  tests and were removed.

Final decision:

- Keep the implementation isolated as a normal `Moulding` operation and test it
  in VCarve with the renamed DXF before expanding the feature further.

Verification:

- Ran `tools/run_tests.py` with the bundled Codex Python.
- Result: 782 passed, 0 failed.
- VCarve test failed with: `variable 'MouldingToolpath' is not declared`.
- Updated `ops/moulding.lua` to detect the missing global with `rawget(_G, ...)`
  and report a controlled error instead of an internal crash.
- Reran `tools/run_tests.py`; result: 782 passed, 0 failed.

## 2026-07-28 - Point Installed Gadget To Reviewed SmartCAM Database

Files changed:

- `LayerDSL_Toolpaths/config.lua`
- `docs/CHANGELOG.md`

Reason:

- The installed gadget copy under `C:\Users\Public\Documents\Vectric Files\Gadgets\VCarve Pro V12.5\LayerDSL_Toolpaths\layer-dsl-toolpaths` still pointed to `\\Desktop-0rne27t\c\SmartCAM` and allowed `SMARTCAM_DB` to override the configured path.
- The earlier reviewed project copy uses `C:\Users\Victor\Desktop\vcrv\SmartCAM`; keeping the installed VCarve copy on a different SmartCAM database can produce different tool records and errors.

What was done:

- Changed `database.path` to `C:\Users\Victor\Desktop\vcrv\SmartCAM`.
- Changed `use_environment` to `false`.

What failed or was uncertain:

- This copy is the current workspace and appears to be the installed gadget location, but VCarve should still be restarted before testing so it reloads the changed Lua file.
- Existing unrelated local changes were present before this edit: `.autocad-mcp/` is untracked and `README — копия.md` is deleted in Git status.

Final decision:

- Make the installed VCarve gadget read the same SmartCAM JSON database as the reviewed `Desktop\vcrv` project copy.

Verification:

- Ran `tools/run_tests.py` with the bundled Codex Python.
- Result: 757 passed, 0 failed.
- Pending: restart VCarve, run the gadget again and confirm the old `V-bit 120 degrees, 45 mm` database error no longer appears.

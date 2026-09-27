# Layer DSL Toolpaths — a Vectric Gadget for VCarve Pro 12.x

Creates VCarve toolpaths from machining parameters embedded in **layer names**.

```
classic                               DXF-safe
------------------------------------  ------------------------------------
Pocket|tool=1|depth=8                 Pocket_tool_1_depth_8
Profile|side=outside|tool=1|depth=18  Profile_side_outside_tool_1_depth_18
Drill|tool=2|depth=20|peck=2          Drill_tool_2_depth_20_peck_2
VCarve|tool=3|flat=3|flat_tool=1      VCarve_tool_3_flat_3_flat_tool_1
```

`tool` is an **id in the SmartCAM JSON tool database**, not a diameter.
Diameter, V-bit angle, feeds and speeds all come from that record &mdash; see
[Tools come from the SmartCAM database](#tools-come-from-the-smartcam-database).

Both columns mean the same thing. **Use the right-hand form if your layers
come from DXF** — see [DXF-safe layer names](#dxf-safe-layer-names).

There are **no fixed layer names**. A layer is a machining layer because it
*starts with a known operation*, not because it is called something in
particular. Everything after the operation is an unordered bag of `key=value`
pairs, so these three are the same toolpath:

```
Pocket|depth=8|tool=1        Pocket_depth_8_tool_1
Pocket|tool=1|depth=8        Pocket_tool_1_depth_8
Pocket|depth=8|tool=1|stepover=40
```

Layers that do not start with a known operation (`Layer 1`, `Dimensions`,
`Milling_path`) are ignored silently, as are layers that start with an
operation but carry no parameters (`Pocket_2`, `Drill_holes`).

---

## Install

Copy the `LayerDSL_Toolpaths` folder into your gadgets directory:

```
%PROGRAMDATA%\Vectric\VCarve Pro\V12.5\Gadgets\LayerDSL_Toolpaths\
```

The exact path varies by edition — inside VCarve, **Gadgets → Browse Gadget
Files** opens the right folder. The layout must stay intact:

```
LayerDSL_Toolpaths/
├── LayerDSL_Toolpaths.lua      entry point
├── LayerDSL_Toolpaths.htm      confirmation dialog
├── config.lua                  your defaults — edit this
└── lib/
    ├── schema.lua              the parameter dictionary
    ├── parser.lua              the DSL parser
    ├── coerce.lua              value coercion
    ├── enums.lua               DSL tokens → VCarve constants
    ├── tooling.lua             JSON record → VCarve Tool
    ├── factory.lua             dispatch on params.operation
    ├── runner.lua              scan → plan → execute
    ├── log.lua                 diagnostics
    ├── db/                     the SmartCAM database
    │   ├── config.lua            WHERE it lives — the only such place
    │   ├── fileio.lua            disk access
    │   ├── json.lua              JSON codec (VCarve ships none)
    │   ├── store.lua             one JSON document
    │   ├── seed.lua              what a new database contains
    │   ├── tool_repository.lua   tools.json: CRUD and lookup
    │   └── database.lua          opens the folder and every document
    └── ops/
        ├── pocket.lua  profile.lua  drill.lua  vcarve.lua
```

Restart VCarve, then run it from the **Gadgets** menu.

---

## How a run works

1. The SmartCAM database is opened, creating the folder and any missing
   JSON file.
2. Every layer in the job is read and parsed. Non-DSL layers are ignored.
   Tools are resolved against `tools.json`.
3. A **plan** is shown: what will be created, with what settings, and which
   layers are being skipped and why.
4. On confirmation, the toolpaths are created. One bad layer is reported and
   skipped; it does not abort the rest of the run.
5. A report summarises what was created, plus every warning.

Tick **Dry run** in the dialog to see the plan without creating anything.

---

## Grammar

```
layer     := operation ( SEP field )*
field     := key ASSIGN value
operation := IDENT                    -- or given as a field: operation=Pocket

SEP       := "|" | "_"                -- configurable; see config.lua syntax
ASSIGN    := "=" | "_"
```

* Parameter **order is irrelevant**.
* Keys and enum values are **case-insensitive**; `-` and space fold to `_`,
  so `start-depth`, `Start Depth` and `start_depth` are the same key.
* Values may carry a unit that is then ignored: `depth=8mm`, `stepover=45%`,
  `ramp_angle=25deg`, `spindle=18000rpm`. **The DSL is unit-less — every
  length is in job units** (mm if the job is metric, inches if not).
* An **unknown key warns and is skipped**; it never stops the run.
* A known key with a **bad value warns and falls back to the configured
  default**; it never stops the run.
* A duplicated key warns; the last value wins.

### Operations

| Canonical | Also accepted |
|---|---|
| `Pocket`  | `pockets` |
| `Profile` | `cutout`, `contour` |
| `Drill`   | `drilling`, `bore` |
| `VCarve`  | `v_carve`, `carve`, `engrave` |

---

## DXF-safe layer names

A DXF layer name may not contain any of:

```
< > / \ " : ; ? * | , = `
```

**Both** delimiters of the classic form are on that list — not just `=`. A
layer called `Pocket|tool=1|depth=8` cannot survive a DXF round trip at all,
so swapping only the `=` would still fail on the `|`.

The underscore form uses no reserved characters:

| Classic | DXF-safe |
|---|---|
| `Pocket\|tool=1\|depth=8` | `Pocket_tool_1_depth_8` |
| `Pocket\|tool=1\|depth=18\|stepover=45` | `Pocket_tool_1_depth_18_stepover_45` |
| `Profile\|side=outside\|tool=1\|depth=18` | `Profile_side_outside_tool_1_depth_18` |
| `Profile\|side=inside\|tool=1\|tabs=true` | `Profile_side_inside_tool_1_tabs_true` |
| `Drill\|tool=2\|depth=20\|peck=2` | `Drill_tool_2_depth_20_peck_2` |
| `VCarve\|tool=3\|flat=3` | `VCarve_tool_3_flat_3` |

**Both forms work, including in the same job.** The first configured
separator that actually appears in a layer name decides how that name is
read, so DXF-imported layers and hand-named layers can coexist. You can also
mix within one name: `Pocket|tool=1|depth_8`.

To enforce one convention, edit `syntax` in `config.lua`:

```lua
syntax = {
   separators = { "_" },   -- drop "|" to reject the classic form
   assigns    = { "_" },
},
```

### How the underscore form stays unambiguous

With `_` doing both jobs there is no punctuation separating keys from values,
so the **schema** resolves it — which is exactly what the dictionary-based
architecture buys you:

* **Longest known key wins.** `start_depth_2` is `start_depth=2`, not
  `start=depth_2`, because `start_depth` is a key and `start` is not.
* **Value length comes from the parameter's type.** Enum values match the
  longest *valid* token run, so `rate_units_mm_sec` keeps `mm_sec` together;
  numbers and booleans take exactly one token.
* **A value may share a name with a key.** `offset` is a Profile parameter
  *and* a valid `strategy` value, so `Pocket_strategy_offset_depth_9` reads
  correctly as `strategy=offset, depth=9`.
* **Existing layers are not hijacked.** A name that starts with an operation
  but has no recognisable parameters — `Pocket_2`, `Drill_holes`,
  `Milling_path_pocket` — is treated as an ordinary drawing layer and
  ignored. A bare `Pocket` is still accepted, since that one is unambiguous.

### Name length

Modern DXF (AC1015 / AutoCAD 2000 and later, which includes the AC1021 files
in this project) allows 255-character layer names. Older revisions cap them
at 31, and some importers still reject or silently truncate longer names.

If your toolchain is one of those, set `gadget.max_layer_name_length = 31` in
`config.lua` to get a warning, and use the short aliases:

| Long (36 chars) | Short (28 chars) |
|---|---|
| `Profile_side_outside_tool_1_depth_18` | `Profile_side_out_tool_1_d_18` |
| `Pocket_tool_2_depth_6_allowance_0.2`  | `Pocket_tool_2_d_6_leave_0.2` |

Useful short aliases: `d` (depth), `so` (stepover), `f` (feed), `tn` (tool),
`out`/`in` (side), `leave` (allowance), `flat` (flat_depth).

---

## Tools come from the SmartCAM database

Tools live in a plain JSON database, **not** in VCarve's tool database. The
gadget has no dependency on Vectric's `ToolDatabase`, `ToolDBId` or tool
picker at all.

```
C:\ProgramData\SmartCAM├── tools.json        the tool library
├── machines.json     machine definitions
├── materials.json    material definitions
├── presets.json      named parameter bundles
└── settings.json     database settings
```

The folder and all five files are **created on first run** if they do not
exist, seeded with placeholder entries so the gadget works immediately. Every
seeded tool carries conservative real feeds, so nothing plunges at zero, and
every one should be checked before it cuts.

`tool` in a layer name is a **tool id** in `tools.json` — or a tool **name**,
if you prefer (`Pocket|tool=End Mill 12mm|depth=8`). Names only work in the
`|`/`=` syntax, because a value in the underscore syntax is a single token.

### A tool record

```json
{
  "id": 3,
  "name": "V-Bit 90 degree",
  "type": "vbit",
  "units": "mm",
  "diameter": 12.0,
  "included_angle": 90.0,
  "tool_number": 3,
  "stepdown": 3.0,
  "stepover": 4.0,
  "clear_stepover": 4.0,
  "feed_rate": 150.0,
  "plunge_rate": 50.0,
  "spindle_speed": 16000,
  "rate_units": "mm_min",
  "notes": ""
}
```

`type` is one of `end_mill`, `ball_nose`, `vbit`, `engraving`,
`through_drill`, `radiused_end_mill`, `radiused_engraving`. `units` is the
units of *that tool's* sizes, so a millimetre tool stays correct in an inch
job. `stepover` here is a **distance**; the `stepover` in a layer name is a
**percentage** and is resolved against this record's diameter.

### Changing where the database lives

One line in `config.lua`:

```lua
database = {
   path = "\\server\cnc\SmartCAM",
   use_environment = true,
},
```

Or set `SMARTCAM_DB` in the environment to repoint a seat without editing the
file. Every module asks `Config` for its paths and none of them builds one,
so a network share needs no other change.

### What overrides what

1. The **tool record** supplies feeds, speeds, stepdown, stepover and all
   geometry.
2. A value in a **layer name** overrides it for that layer only:
   `Pocket_tool_1_depth_8_feed_200`.
3. `config.lua` **cannot** override the record. It deliberately has no
   `feed`, `plunge`, `spindle`, `pass_depth`, `stepover` or `rate_units`
   default — a default there would silently beat your tool library.

### When a tool cannot be used

The layer is **skipped and named in the report**, before anything is created.
Nothing is machined with invented feeds. That happens when:

* no tool in `tools.json` has that id or name
* the record has no positive `diameter`, `feed_rate`, `plunge_rate` or
  `spindle_speed`
* a `vbit` record has no sensible `included_angle`

A record with zero feeds is refused outright rather than patched by a
layer-name override — a broken record should be fixed in `tools.json`.

Using an odd tool type — an end mill on a `Drill` layer — only warns.

### If tools.json is damaged

Malformed JSON is **reported, never overwritten**: losing a tool library to a
stray comma would be worse than refusing to run. The error names the file,
the line and the column. An *empty* file is treated as a fresh start, since
that is what an interrupted write looks like.

Writes are staged through a `.tmp` file and the previous version is kept as
`.bak`, so a failure part way through a save cannot leave a half-written
library behind.

---

## Parameter reference

| Parameter | Aliases | Type | Applies to | Default | Meaning |
|---|---|---|---|---|---|
| `operation` | — | string | all | — | Operation to run. Normally the first field of the layer name. |
| `tool` | `bit`, `cutter`, `tool_no`, `toolnum`, `tn` | id or name | all | `1` | **Tool id** (or name) in `tools.json`. |
| `pass_depth` | `stepdown`, `step_down`, `doc`, `depth_per_pass` | number (≥0.001) | all | *library* | Cut depth per pass (tool stepdown). |
| `stepover` | `pover`, `step_over`, `so` | number (0.1–100) | all | *library* | Stepover as a PERCENTAGE of tool diameter. |
| `feed` | `feed_rate`, `feedrate`, `f` | number (≥0.001) | all | *library* | Cutting feed rate, in `rate_units`. |
| `plunge` | `plunge_rate`, `plungerate` | number (≥0.001) | all | *library* | Plunge feed rate, in `rate_units`. |
| `spindle` | `rpm`, `spindle_speed`, `speed` | integer (≥0) | all | *library* | Spindle speed in RPM. |
| `rate_units` | — | `mm_sec` \| `mm_min` \| `m_min` \| `in_sec` \| `in_min` \| `ft_min` | all | *library* | Units for feed and plunge. |
| `depth` | `cut_depth`, `cutdepth`, `d` | number (≥0) | all | `5.0` | Cut depth BELOW `start_depth`. |
| `start_depth` | `startdepth`, `start`, `z_start` | number (≥0) | all | `0.0` | Depth below the surface at which cutting begins. |
| `cut_direction` | `direction`, `dir` | `climb` \| `conventional` | all | `climb` | Cutting direction. |
| `allowance` | `stock`, `leave`, `offset_allowance` | number | all | `0.0` | Material left on the cut (negative removes extra). |
| `vector_selection` | `vectors`, `select`, `selection` | `closed` \| `open` \| `all` \| `circles` | all | `closed`, `circles` (Drill) | Which vectors on the layer to machine. |
| `safe_z` | `safez`, `rapid_z`, `safe_height` | number (≥0) | all | `5.0` | Rapid-move clearance above the surface. |
| `clearance` | `start_z_gap`, `plunge_gap` | number (≥0) | all | `2.0` | Height at which rapid plunges become feed plunges. |
| `home_z` | `homez`, `home_height` | number | all | surface + 20% | **Absolute** Z for the toolpath home position. |
| `side` | `profile_side` | `outside` \| `inside` \| `on` | Profile | `outside` | Machining side. |
| `tabs` | `use_tabs`, `bridges` | boolean | Profile | `false` | Use holding tabs. See the caveat below. |
| `tab_width` | `tab_length` | number (≥0) | Profile | `5.0` | Tab length along the vector. |
| `tab_height` | `tab_thickness` | number (≥0) | Profile | `1.5` | Tab thickness (height left uncut). |
| `lead_in` | `leadin` | number or bool | Profile | `0.0` | Lead-in length. `0`/`false` disables. |
| `lead_out` | `leadout` | number or bool | Profile | `0.0` | Lead-out length. `0`/`false` disables. |
| `lead_type` | — | `circular` \| `linear` | Profile | `circular` | Lead geometry. |
| `lead_angle` | `linear_lead_angle` | number (0–90) | Profile | `45.0` | Approach angle for linear leads. |
| `offset` | `overcut`, `overcut_distance` | number (≥0) | Profile | `0.0` | Distance to continue past the start point. |
| `inside_corner` | `corner_sharpen`, `sharpen_corners` | boolean | Profile | `false` | 3D corner sharpening on internal corners (V-bits only). |
| `square_corners` | — | boolean | Profile | `false` | Square external corners instead of rounded. |
| `keep_start_points` | — | boolean | Profile | `false` | Keep vector start points instead of optimising. |
| `strategy` | `clearance_strategy`, `pocket_strategy` | `offset` \| `raster` | Pocket, VCarve | `offset` | Area-clearance strategy. |
| `raster_angle` | — | number | Pocket, VCarve | `0.0` | Raster angle, when `strategy=raster`. |
| `last_pass` | `profile_pass`, `finish_pass` | `none` \| `first` \| `last` | Pocket, VCarve | `last` | Where the pocket's profile pass runs. `true`→`last`. |
| `roughing` | `two_tool`, `rough` | boolean | Pocket | `false` | Two-tool pocketing with a larger roughing tool. |
| `roughing_tool` | `rough_tool`, `clearance_tool` | id or name | Pocket | — | **Tool id** of the larger roughing tool. |
| `finishing` | `finish` | boolean | Pocket, Profile | `false` | Forces `allowance` to 0 and adds a final profile pass. |
| `ramp` | — | number or bool | Pocket, Profile | `false` | Ramp into the cut; a number sets the distance. |
| `ramp_angle` | — | number (0.1–89) | Pocket, Profile | `25.0` | Ramp angle; setting it constrains the ramp by angle. |
| `ramp_type` | — | `zigzag` \| `spiral` \| `linear` | Profile | `zigzag` | Ramp geometry. |
| `peck` | `peck_depth`, `peck_gap`, `retract` | number or bool | Drill | `0.0` | Peck retract gap. `0`/`false` disables pecking. |
| `flat_depth` | `flat`, `flat_bottom` | number (≥0) | VCarve | `0.0` | Flat-bottom depth. `0` = pure V-carve. |
| `flat_tool` | `clear_tool`, `area_tool` | id or name | VCarve | — | **Tool id** of the end mill that clears the flat bottom. |

*library* means the value comes from the `tools.json` record; write one in a
layer name to override it for that layer.

Booleans accept `true/false`, `yes/no`, `y/n`, `on/off`, `1/0`,
`enable(d)/disable(d)`.

A parameter that does not apply to the operation is still recorded but warns
that it will have no effect — `Pocket|side=inside` tells you `side` is a
Profile setting.

---

## Configuration

`config.lua` holds the defaults. Precedence, lowest to highest:

1. schema built-in default (`lib/schema.lua`)
2. `config.defaults` — every operation
3. `config.operations.<Op>` — one operation
4. the layer name

Tool properties sit outside this chain entirely: feeds, speeds, stepdown and
stepover come from the **tool record in tools.json**, and only an explicit
layer-name value overrides them. See [What overrides what](#what-overrides-what).

Config values are coerced through the same schema as layer values, so
`last_pass = true` and `last_pass = "last"` both work, and a typo in
`config.lua` is reported rather than passed to VCarve.

`config.gadget` also controls run behaviour: `show_dialog`, `dry_run`,
`create_2d_previews`, `interactive_warnings`, `toolpath_name` (templated with
`{layer}`, `{operation}`, `{tool}`, `{depth}`, `{index}`), `replace_existing`
and `empty_layer_is_error`.

Setting `show_dialog = false` and `interactive_warnings = false` gives a fully
unattended run.

---

## Extending

### A new parameter — one entry

Add to `PARAMS` in `lib/schema.lua`:

```lua
{  key = "climb_final", type = "boolean",
   applies_to = { Profile = true },
   aliases = { "final_climb" },
   doc = "Run the last pass climb-milled." },
```

The parser now accepts, validates, defaults, reports and documents it. Only
if it must drive a VCarve setting do you also touch the relevant `lib/ops/`
module — in exactly one place.

### A new value type — one function

Add a coercer to `lib/coerce.lua` and name it from a schema entry's `type`.

### A new operation — one module

Create `lib/ops/chamfer.lua` returning `{ name = "Chamfer", build = ... }`,
add its spellings to `Schema.OPERATIONS`, and register it in
`Factory.load_standard`.

There is **no `if layer_name == ...` chain anywhere in this gadget**.
Dispatch is a dictionary lookup on `params.operation`.

### The parser/factory boundary

The parser returns a plain Lua table and knows nothing about VCarve:

```lua
{ operation = "Pocket", tool = 1, depth = 8,
  stepover = 45, allowance = 0.15, tabs = false, ... }
```

The factory consumes that table and never looks at a layer name. This is why
the DSL is testable outside VCarve — and it means the same factory could be
driven from a CSV or a dialog instead.

---

## Tests

721 assertions across five suites, none of which need VCarve running:

```bash
pip install lupa
python tools/run_tests.py
```

With a standalone Lua interpreter:

```bash
lua tests/run_json_tests.lua
lua tests/run_db_tests.lua
lua tests/run_tests.lua
lua tests/run_api_tests.lua
lua tests/run_runner_tests.lua
```

| Suite | Covers |
|---|---|
| `run_json_tests.lua` | the JSON codec: escapes, unicode, surrogate pairs, BOM, determinism, malformed input |
| `run_db_tests.lua` | Config paths, file IO, first-run creation, repository CRUD and lookup, validation, damaged files |
| `run_tests.lua` | grammar, ordering, aliases, coercion, config precedence, unknown keys, hostile input |
| `run_api_tests.lua` | the operation modules against a recording mock of the VCarve API, building tools from JSON records |
| `run_runner_tests.lua` | layer scanning, skip reasons, tool resolution, name templating, replace-on-rerun, HTML escaping |

### The API contract test

`tests/api_names.lua` is generated from the installed VCarve executable by
`tools/extract_api_names.py`; it is the set of names the Lua bindings actually
expose. The mock fails any test that writes a property or calls a method not
in that set.

This is not theoretical. **Vectric's own sample gadgets set
`tool.VBitAngle`, which is not a real binding — the property is
`VBit_Angle`.** The wrong name fails silently and leaves the V-bit at its
default angle, so a layer asking for a 60° carve would be cut with a 90° bit.
The test suite catches it; verified by deliberately reintroducing the bug.

Taking tools from the library removes that bug class altogether: the angle is
now *read* from a real V-bit rather than written, and a tool with no usable
angle is refused instead of silently carved wrong.

Regenerate the name table against your own install:

```bash
python tools/extract_api_names.py "C:\Program Files\Vectric\VCarve Pro 12.5\x64\VCarvePro.exe"
```

---

## What was verified, and what to check on your machine

Built against a **VCarve Pro 12.5 trial install**, with the Lua API surface
cross-checked two ways: the `luabind` binding strings extracted from
`VCarveProTrialEdition.exe`, and the official *Vectric Lua Interface
Documentation* shipped in the V12 Gadget SDK.

**Verified against both sources**

* All four `ToolpathManager:Create*Toolpath` signatures, including argument
  order and count (asserted in the test suite).
* Every property name on `Tool`, `ToolpathPosData`, `GeometrySelector`,
  and the four `*ParameterData` classes.
* Layer enumeration, and that `GeometrySelector` needs
  `GeometryFilterUsed = true` before `OnlyOnLayers` has any effect.
* VCarve's embedded Lua exposes only `socket`, `mime` and `ltn12` — no JSON
  and no SQLite — which is why the database is JSON with its own codec.
  `io.open`, `os.execute` and `os.getenv` are all present and are what the
  storage layer uses.
* Embedded Lua is **5.2.3** — the code avoids 5.3+ syntax.

**Not verified — please confirm on a scrap job first**

* No toolpath has been cut, or calculated in a live VCarve session, by me.
  The tests prove the right API is called with the right values; they cannot
  prove VCarve is happy with those values for your geometry. **Run a dry run,
  then check the toolpaths and simulate before cutting.**
* Some DSL names in the requested parameter list are ambiguous, so I picked a
  defensible reading and documented it. Change these in `lib/schema.lua` if
  your intent differs:
  * `pover` → treated as an alias of `stepover`
  * `clearance` → `ToolpathPosData.StartZGap`, distinct from `safe_z`
  * `offset` → profile overcut distance past the start point
  * `roughing` → two-tool pocketing; `finishing` → zero allowance + final pass
  * `last_pass` → *where* the pocket profile pass runs (`none`/`first`/`last`)
* `tabs=true` switches tabbing on, but **VCarve needs tab positions to already
  exist on the vectors**. The Lua API has no call to place them, so a layer
  with `tabs=true` and no tabs drawn produces an untabbed cut.
* Folder creation falls back to `Path:CreateDir` (an undocumented VCarve
  binding, attempted defensively) and then to `mkdir`. Creation is verified
  by actually writing a probe file, so a failure is reported rather than
  assumed away — but it has not been exercised against a locked-down
  `C:\ProgramData` under a restricted account.
* **VCarve's `io.open` rejects the bare `"r"` and `"w"` modes** that stock
  Lua accepts, raising `bad argument #2 to 'open' (invalid mode)`. All file
  access uses `"rb"`/`"wb"` and goes through `FileIO.open`; a test replaces
  `io.open` with VCarve's stricter version so a bare mode fails the suite
  rather than only failing on the machine.
* The seeded `tools.json` is **placeholder data**. Replace it with your real
  cutters before machining anything.
* Trial builds restrict toolpath saving; behaviour on a licensed install may
  differ in ways a trial cannot show.

---

## Licence

Same terms as the Vectric gadget samples: use freely, including commercially;
provided as-is with no warranty. Gadgets are an optional add-in and you use
them at your own risk.

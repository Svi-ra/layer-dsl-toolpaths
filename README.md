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
| `keep_start_points` | — | boolean | Profile | `false` | Keep vector start points instead of optimising. Optimisation only happens because new toolpaths are [recalculated](#new-toolpaths-are-recalculated-and-why-they-have-to-be). |
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
`{layer}`, `{operation}`, `{tool}`, `{depth}`, `{index}`), `replace_existing`,
`recalculate` and `empty_layer_is_error`.

Setting `show_dialog = false` and `interactive_warnings = false` gives a fully
unattended run.

### New toolpaths are recalculated, and why they have to be

Creating a toolpath through VCarve's Lua API is not the same thing as pressing
**Calculate**. `CreateProfilingToolpath` and its siblings store the parameters
they are given, but the stage that *acts* on the ones decided during
calculation does not run. The visible casualty is start point optimisation:

```
Profile_side_outside_tool_1_depth_18_keep_start_points_false
```

The toolpath appears, its form correctly reads **Optimize Start Points** — the
parameter arrived — and the cut still starts at each vector's own start point.
Select those toolpaths in VCarve, press Calculate, and the start points move.
No parameter changed in between; only the calculation stage ran.

So the gadget runs it, per toolpath, the moment each one is created. The
awkward part is getting hold of the toolpath again, and there are **two
routes** because the documented one may not work on your build:

1. `Find(id)` → `GetAt(pos)`, the documented route.
2. Failing that, walk the list and take the **last** toolpath carrying the name
   just used. Creation appends, so that is the new one — and in a nested job
   the earlier namesakes belong to sheets already machined, so "last" is exact.

Route 2 is not belt-and-braces. `Find` takes `UUID const&`, and
`tools/Sheet_Diagnostics` already measured on this build that the id creation
hands back is a *different* bound type which `DeleteToolpathWithId` — same
parameter type — refuses outright. If `Find` refuses it too, an id-only lookup
means the recalculation silently never happens.

The object is always looked up fresh, never cached: the API reference is
explicit that *“the passed toolpath is invalid after this call as a new
toolpath with the same id is created internally”*.

Recalculation happens immediately rather than in a sweep at the end because a
toolpath is calculated against the **active sheet**, and a nested-job run walks
the sheets. Recalculating later, with a different sheet active, is not the same
operation.

`RecalculateAllToolpaths()` exists as a last resort for a build where the
per-toolpath route cannot run, and is **off** (`recalculate_all = false`). It
destroys and rebuilds every toolpath in the job, including work this run never
touched — too blunt to have happen unasked when the per-toolpath route is known
to work here. Left off, a run that cannot recalculate says so and the new
toolpaths need a manual Calculate.

Cost: every toolpath is calculated twice. `recalculate = false` buys that time
back and hands you the manual Calculate step instead.

### If the start points ever stop being optimised

Run **`tools/Recalc_Diagnostics`**, a throwaway probe in the mould of
`tools/Sheet_Diagnostics`. It creates two profile toolpaths on one of your
layers differing *only* in `KeepStartPoints`, compares them, recalculates one,
compares again, then deletes them all. It separates three things that look
identical from the outside:

- Does creation act on `KeepStartPoints` at all?
- Does this build accept the creation id in `Find`? (**it does not**, on 12.5 —
  which is why route 2 above exists, and why the first version of this fix
  changed nothing)
- Does `RecalculateToolpath` move the start points? (**it does**, on 12.5)

If that last answer ever comes back *no*, the gadget cannot fix it from Lua:
VCarve's UI has three start-point modes and the binding exposes one boolean.
The probe says so rather than leaving you to guess.

### Machining order follows the DXF

Toolpaths are machined in the order they are created, so the gadget creates
them in the order the layers appear in the imported DXF: first layer becomes
the first toolpath, last layer the last. The same sequence is used on every
sheet of a nested job.

This needs saying because VCarve's layer manager enumerates layers in the
*reverse* of the DXF order, so the scan is reversed to put it back. That is
observed behaviour of VCarve 12.5 rather than a documented guarantee, which is
why `layer_order` in `config.lua` exists — set it to `"vcarve"` to use the
layer manager's own order if a future build ever enumerates the other way.
Either setting is deterministic: the same job always produces the same
sequence.

### Nested jobs: one run covers every sheet

Run the gadget once and it creates the toolpaths for **all** sheets. It walks
the sheets in order, points VCarve at each one, and builds the plan there:

- A sheet is only machined once VCarve confirms it is the active sheet. An
  unverified switch would put toolpaths on the wrong sheet, so it is reported
  as an error and that sheet is skipped rather than guessed at.
- A layer with no vectors on the sheet in hand is skipped **for that sheet**.
  The layer manager is job-wide, so a layer can look populated while holding
  nothing for the sheet being machined.
- The active sheet you started on is restored at the end.
- Toolpath names stay equal to layer names on every sheet. VCarve accepts the
  same toolpath name on different sheets and does not rename them.

Nothing here is assumed about the API — `tools/Sheet_Diagnostics` measured it
against VCarve Pro 12.5: creation follows `ActiveSheetId` in both directions,
and each toolpath cuts only its own sheet's vectors (a layer split 6/8 across
two sheets produced plunge lengths of exactly 36 and 48).

### Existing toolpaths are never deleted unasked

A run **adds** toolpaths. Before the confirmation dialog the gadget counts the
toolpaths already in the job that carry the names it is about to use, shows
that count, and marks the affected rows in the plan table — but it deletes
nothing unless you tick **Delete existing toolpaths that share a name**.
`replace_existing` in `config.lua` is off by default and only sets the
starting state of that checkbox.

When you do ask for it, replacement is scoped to the sheet being machined:
same-named toolpaths belonging to other sheets are left alone and reported,
and a toolpath that will not say which sheet it belongs to is never deleted.
This is what the original bug was about — the Lua toolpath list spans every
sheet while VCarve's Toolpaths pane shows only the active one, so matching on
name alone reached across sheets and deleted finished work.

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
* `ToolpathManager:RecalculateToolpath`, used to run the calculation stage on
  each new toolpath — measured on a live 467-vector job, and the reason start
  points come out optimised without a manual Calculate. `Find` is present but
  **rejects the id creation returns** on this build, so the toolpath is located
  by name instead. `ProfileParameterData` carries
  exactly one start-point control, `KeepStartPoints` — the third UI option
  ("closest on bounding box") has no Lua binding, which is why the DSL offers
  only keep-or-optimise.
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
* Recalculation was confirmed on a live job (VCarve Pro 12.5, 467 vectors):
  start points come out optimised straight after the run, no manual Calculate.
  It is listed under *verified* above rather than here.
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

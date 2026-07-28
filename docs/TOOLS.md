# The SmartCAM tool database — `tools.json`

Complete reference for the tool library the gadget machines from.

Every statement here is checked by the test suite: all eight tool types are
built against the real VCarve property names in
[`tests/run_api_tests.lua`](../tests/run_api_tests.lua), and the validation
rules in [`tests/run_db_tests.lua`](../tests/run_db_tests.lua).

---

## Contents

- [Where it lives](#where-it-lives)
- [File structure](#file-structure)
- [Field reference](#field-reference)
- [Tool types](#tool-types) — the eight supported types, with examples
- [Enumerations](#enumerations)
- [What makes a tool unusable](#what-makes-a-tool-unusable)
- [Referring to tools from layer names](#referring-to-tools-from-layer-names)
- [Editing the file](#editing-the-file)

---

## Where it lives

```
C:\ProgramData\SmartCAM\tools.json
```

Change it in the `database` section of `config.lua`, or set the `SMARTCAM_DB`
environment variable. That is the only place a storage location is decided,
so a network share is a one-line change:

```lua
database = {
   path = "\\\\server\\cnc\\SmartCAM",
   use_environment = true,
},
```

The folder and file are created on first run if missing, seeded with
**placeholder** tools. Replace them with your real cutters before machining.

If the gadget cannot write — a locked-down machine, a read-only share, a
restricted script host — it still runs: existing files are read normally, and
a database it cannot create falls back to the seeded tools in memory with a
loud warning. **Saving is optional; reading is not.**

---

## File structure

```json
{
  "schema": 1,
  "notes": "Workshop tool library",
  "tools": [
    { "id": 1, "name": "End Mill 6mm", "...": "..." },
    { "id": 2, "name": "V-Bit 90",     "...": "..." }
  ]
}
```

| Key | Type | Meaning |
|---|---|---|
| `schema` | integer | On-disk format version. Currently `1`. |
| `notes` | string | Free text. Ignored by the gadget. |
| `tools` | array | The tool records. May be empty (`[]`). |

Unknown keys — at document level or inside a tool — are **kept but ignored**.
You can annotate records freely without upsetting the gadget.

---

## Field reference

Every field a tool record may carry, and the VCarve property it drives.

| Field | Type | Required | Default | VCarve property | Meaning |
|---|---|---|---|---|---|
| `id` | integer | **yes** | — | — | Unique. This is what `tool_1` in a layer name refers to. |
| `name` | string | recommended | `"Tool <id>"` | `.Name` | Shown in the plan, the report and VCarve's toolpath list. Can also be used to reference the tool. |
| `type` | string | recommended | `end_mill` | constructor | One of the [eight types](#tool-types). |
| `units` | string | no | `mm` | `.InMM` | Units of **this record's** sizes. `mm` or `inch`. |
| `diameter` | number | **yes** | — | `.ToolDia` | Cutter diameter. Must be > 0. |
| `included_angle` | number | per type | — | `.VBit_Angle` | Full included angle in degrees. V-bit, engraving, diamond drag. |
| `tip_radius` | number | per type | — | `.Tip_Radius` | Corner/tip radius. Radiused end mill, radiused engraving. |
| `flat_diameter` | number | no | — | `.Flat_Diameter` | Width of the flat at the tip. Engraving tools. |
| `line_width` | number | no | — | `.Line_Width` | Scribed line width. Diamond drag only. |
| `tool_number` | integer | no | `id` | `.ToolNumber` | Tool number emitted in the posted G-code. |
| `stepdown` | number | no | `0` | `.Stepdown` | Cut depth per pass, in tool units. |
| `stepover` | number | no | `0` | `.Stepover` | **A distance, not a percentage.** In tool units. |
| `clear_stepover` | number | no | `stepover` | `.ClearStepover` | Stepover for the flat-area clearance pass. V-bits only. |
| `feed_rate` | number | **yes** | — | `.FeedRate` | Cutting feed, in `rate_units`. Must be > 0. |
| `plunge_rate` | number | **yes** | — | `.PlungeRate` | Plunge feed, in `rate_units`. Must be > 0. |
| `spindle_speed` | integer | **yes** | — | `.SpindleSpeed` | RPM. Must be > 0. |
| `rate_units` | string | no | `mm_min` | `.RateUnits` | Units for feed and plunge. Validated — see below. |
| `notes` | string | no | — | `.Notes` | Free text; travels with the tool into the toolpath. |

> **`stepover` is a distance here, a percentage in a layer name.**
> In `tools.json`, `"stepover": 2.4` on a 6 mm cutter means 2.4 mm (40%).
> In a layer name, `stepover_40` means 40%, resolved against this record's
> `diameter`. They are different units on purpose: the file describes the
> tool, the layer name describes the job.

---

## Tool types

Eight types can be constructed. These are exactly the types VCarve's
`Tool(name, type)` constructor accepts — `FORM_TOOL` and `LASER` exist in the
API but cannot be created from a script, so they are not supported.

| Type | Needs | Also uses |
|---|---|---|
| [`end_mill`](#end_mill) | `diameter` | — |
| [`ball_nose`](#ball_nose) | `diameter` | — |
| [`radiused_end_mill`](#radiused_end_mill) | `diameter`, `tip_radius` | — |
| [`vbit`](#vbit) | `diameter`, `included_angle` | `clear_stepover` |
| [`engraving`](#engraving) | `diameter`, `included_angle` | `flat_diameter` |
| [`radiused_engraving`](#radiused_engraving) | `diameter`, `included_angle`, `tip_radius` | — |
| [`through_drill`](#through_drill) | `diameter` | — |
| [`diamond_drag`](#diamond_drag) | `diameter`, `included_angle` | `line_width` |

---

### `end_mill`

A flat-bottomed cutter — the everyday tool for pocketing and profiling.
`diameter` is the full cutting diameter.

Use for: **Pocket**, **Profile**, and as `roughing_tool` or `flat_tool`.

```json
{
  "id": 1,
  "name": "End Mill 6mm",
  "type": "end_mill",
  "units": "mm",
  "diameter": 6.0,
  "tool_number": 1,
  "stepdown": 2.0,
  "stepover": 2.4,
  "feed_rate": 220.0,
  "plunge_rate": 75.0,
  "spindle_speed": 10000,
  "rate_units": "mm_min",
  "notes": "3 flute upcut, general purpose"
}
```

---

### `ball_nose`

A hemispherical tip, radius = `diameter` / 2. There is no separate radius
field; the diameter defines the ball.

Use for: **Pocket**, **Profile**. Usually a small `stepover` since the
scallop height depends on it.

```json
{
  "id": 2,
  "name": "Ball Nose 6mm",
  "type": "ball_nose",
  "units": "mm",
  "diameter": 6.0,
  "tool_number": 2,
  "stepdown": 2.0,
  "stepover": 0.6,
  "feed_rate": 200.0,
  "plunge_rate": 70.0,
  "spindle_speed": 14000,
  "rate_units": "mm_min",
  "notes": "Stepover 0.6mm = ~0.015mm scallop"
}
```

---

### `radiused_end_mill`

A "bull nose": flat bottom with a rounded corner. `tip_radius` is the corner
radius and **must be greater than zero** — with no radius it is just an end
mill, and the gadget refuses it rather than quietly building the wrong shape.

`tip_radius` should be at most half the diameter (at exactly half, it is a
ball nose).

```json
{
  "id": 3,
  "name": "Bull Nose 6mm R1",
  "type": "radiused_end_mill",
  "units": "mm",
  "diameter": 6.0,
  "tip_radius": 1.0,
  "tool_number": 3,
  "stepdown": 2.0,
  "stepover": 2.4,
  "feed_rate": 210.0,
  "plunge_rate": 70.0,
  "spindle_speed": 12000,
  "rate_units": "mm_min"
}
```

---

### `vbit`

A V-shaped cutter. **`included_angle` is the full angle, not the half
angle** — a "90 degree V-bit" is `90.0`. It must be between 0 and 180.

`diameter` is the physical diameter of the cutter, which sets the maximum
depth the V can reach before it stops widening.

`clear_stepover` is used for the flat-bottom clearance pass and applies to
V-bits only; it defaults to `stepover`.

Use for: **VCarve**. This is the only type a `VCarve` layer should reference.

```json
{
  "id": 4,
  "name": "V-Bit 90 degree",
  "type": "vbit",
  "units": "mm",
  "diameter": 12.0,
  "included_angle": 90.0,
  "tool_number": 4,
  "stepdown": 3.0,
  "stepover": 4.0,
  "clear_stepover": 3.5,
  "feed_rate": 150.0,
  "plunge_rate": 50.0,
  "spindle_speed": 16000,
  "rate_units": "mm_min",
  "notes": "60 and 30 degree bits are separate records"
}
```

> The included angle comes from **this record** and nothing else. There is no
> way to set it from a layer name, which is deliberate: a V-carve cut with
> the wrong angle is wrong in a way that is invisible until it is cut.

---

### `engraving`

A tapered cutter with a small **flat** at the tip, rather than a point.
`included_angle` is the taper, `flat_diameter` is the width of the flat.

Omit `flat_diameter` (or set `0`) for a true point — though at that stage a
`vbit` record is usually the better description.

```json
{
  "id": 5,
  "name": "Engraver 30 degree 0.5mm flat",
  "type": "engraving",
  "units": "mm",
  "diameter": 6.0,
  "included_angle": 30.0,
  "flat_diameter": 0.5,
  "tool_number": 5,
  "stepdown": 1.0,
  "stepover": 0.4,
  "feed_rate": 120.0,
  "plunge_rate": 40.0,
  "spindle_speed": 18000,
  "rate_units": "mm_min"
}
```

---

### `radiused_engraving`

A tapered cutter with a **rounded** tip instead of a flat. Needs both
`included_angle` and `tip_radius`.

```json
{
  "id": 6,
  "name": "Radiused Engraver 30 degree R0.25",
  "type": "radiused_engraving",
  "units": "mm",
  "diameter": 6.0,
  "included_angle": 30.0,
  "tip_radius": 0.25,
  "tool_number": 6,
  "stepdown": 1.0,
  "stepover": 0.4,
  "feed_rate": 120.0,
  "plunge_rate": 40.0,
  "spindle_speed": 18000,
  "rate_units": "mm_min"
}
```

---

### `through_drill`

A drill that plunges without lateral movement. `stepdown` is the peck depth
when the layer asks for pecking.

Use for: **Drill**. A `Drill` layer selects circles by default and drills one
hole at the centre of each.

```json
{
  "id": 7,
  "name": "Drill 5mm",
  "type": "through_drill",
  "units": "mm",
  "diameter": 5.0,
  "tool_number": 7,
  "stepdown": 5.0,
  "stepover": 1.0,
  "feed_rate": 100.0,
  "plunge_rate": 40.0,
  "spindle_speed": 8000,
  "rate_units": "mm_min",
  "notes": "Matches 5mm shelf pin holes"
}
```

---

### `diamond_drag`

A non-rotating diamond point that scribes a line by being dragged through the
surface. Used for engraving metal and acrylic.

`included_angle` is the point angle; `line_width` is the width of the scribed
line. Set `spindle_speed` to whatever your post processor needs — the tool
does not cut by rotating, but the field is still required.

```json
{
  "id": 8,
  "name": "Diamond Drag 120 degree",
  "type": "diamond_drag",
  "units": "mm",
  "diameter": 3.0,
  "included_angle": 120.0,
  "line_width": 0.2,
  "tool_number": 8,
  "stepdown": 0.5,
  "stepover": 0.3,
  "feed_rate": 90.0,
  "plunge_rate": 30.0,
  "spindle_speed": 6000,
  "rate_units": "mm_min",
  "notes": "Spring loaded holder, does not rotate"
}
```

---

## Enumerations

### `type`

```
ball_nose   diamond_drag   end_mill    engraving
radiused_end_mill   radiused_engraving   through_drill   vbit
```

**Case sensitive.** `"End_Mill"` is rejected — this file is data, not the
layer-name DSL, so nothing is folded or guessed at.

An unknown type stops the layer with a message listing the valid ones.
A **missing** `type` is treated as `end_mill`.

### `units`

| Value | Meaning |
|---|---|
| `mm` | Millimetres (default) |
| `inch`, `inches`, `in` | Inches |

Applies to `diameter`, `tip_radius`, `flat_diameter`, `line_width`,
`stepdown`, `stepover` and `clear_stepover` in **that record only**. A
millimetre tool stays a millimetre tool in an inch job.

`included_angle` is always degrees. `spindle_speed` is always RPM.

### `rate_units`

| Value | Meaning |
|---|---|
| `mm_sec` | mm per second |
| `mm_min` | mm per minute (default) |
| `m_min` | metres per minute |
| `in_sec` | inches per second |
| `in_min` | inches per minute |
| `ft_min` | feet per minute |

**Validated, not guessed.** A misspelling such as `"mm/min"` or `"mmmin"`
stops the layer with a message. This one field is strict because getting it
wrong is dangerous in a way the others are not: a feed of `220` read as
mm/sec instead of mm/min is sixty times too fast, and nothing downstream
would question it.

---

## What makes a tool unusable

A tool that fails any of these **skips its layer** and is named in the run
report. Other layers still run. Nothing is ever machined with invented feeds.

| Rule | Why |
|---|---|
| `diameter` > 0 | A zero-width cutter has no toolpath. |
| `feed_rate` > 0 | It would cut at zero feed. |
| `plunge_rate` > 0 | It would plunge at zero feed. |
| `spindle_speed` > 0 | Almost always an unfinished record. |
| `type` is one of the eight | An unknown type would silently become an end mill. |
| `included_angle` in 0–180 for `vbit`, `engraving`, `diamond_drag` | A V-carve with the wrong angle is invisible until cut. |
| `tip_radius` > 0 for `radiused_end_mill`, `radiused_engraving` | Without a radius it is a different tool. |
| `rate_units` is one of the six | See above — a 60× error. |

Two things that only **warn**:

- Using an odd tool type for an operation (an end mill on a `Drill` layer).
  You may have a reason.
- A `roughing_tool` no larger than the tool it is roughing for. The roughing
  pass is skipped and the pocket is cut with the single tool.

A record with zero feeds is refused **outright** — a layer-name override such
as `feed_200` will not rescue it, because a broken record should be fixed in
`tools.json` rather than worked around per layer.

---

## Referring to tools from layer names

By **id**, in either layer-name syntax:

```
Pocket_tool_1_depth_8
Pocket|tool=1|depth=8
```

By **name**, in the `|`/`=` syntax only:

```
Pocket|tool=End Mill 6mm|depth=8
```

Name matching ignores case and surrounding spaces. It does not work in the
underscore syntax, where a value is a single token — use the id there.

Secondary tools take the same references:

```
Pocket_tool_1_depth_12_roughing_true_roughing_tool_2
VCarve_tool_4_flat_3_flat_tool_1
```

The record supplies feeds, speeds, stepdown, stepover and all geometry. A
value written in a layer name overrides it **for that layer only**;
`config.lua` never overrides the record.

---

## Editing the file

Any text editor. It is strict JSON:

- **No comments** and **no trailing commas**. Use the `notes` fields instead.
- Keys are case sensitive and double-quoted.
- Decimals use a point: `6.0`, never `6,0`.

A malformed file is **reported, never overwritten** — the message names the
file, the line and the column. Losing a tool library to a stray comma would
be worse than refusing to run. An *empty* file is treated as a fresh start,
since that is what an interrupted write looks like.

When the gadget writes the file itself, the previous version is kept as
`tools.json.bak` and the new content is staged through `tools.json.tmp`, so a
failure part way through cannot leave a half-written library behind.

Keys are written back in alphabetical order and the output is stable, so the
file diffs cleanly in version control.

### Adding a tool by hand

1. Copy an example above into the `tools` array.
2. Give it an `id` no other tool uses.
3. Set the real diameter, feeds and speeds.
4. Run the gadget — a dry run is enough. Any problem with the record is
   reported before anything is created.

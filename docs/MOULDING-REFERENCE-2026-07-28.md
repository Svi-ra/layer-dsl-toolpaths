# Moulding Reference - 2026-07-28

## Files Reviewed

- `C:\Users\Victor\Desktop\Fatade\14.dxf`
- `C:\Users\Victor\Desktop\1233123.crv`
- `C:\Users\Victor\Desktop\fa123.dxf`

## DXF Geometry

`14.dxf` contains the useful modelling geometry:

- `01_CONTUR_EXTERIOR_FREZA_D8_COMPRESSION`: one closed exterior contour,
  bounding box `0,0` to `414,1833`.
- `02_VCARVE_CANELURI_AXE_SIMETRICE_FREZA_V90`: 36 open vertical rail vectors,
  bounding box `0,0` to `414,1833`.
- `06_DETALIU_PROFIL_SECTIUNE_NU_SE_PRELUCREAZA`: profile/reference detail
  geometry below the panel, including a spline and two line entities.

The text note in `14.dxf` says:

`Moulding rail | Ball-nose R4.00mm | latime profil/canelura 6.000mm | adancimea se seteaza din profil in VCarve`

`fa123.dxf` currently contains only one closed exterior contour on
`01_CONTUR_EXTERIOR_FREZA_D`. It does not contain the rail/profile geometry
needed for automated Moulding analysis.

## CRV Evidence

`1233123.crv` is a proprietary VCarve OLE/Compound Document file, not plain
text. Direct string inspection shows:

- saved toolpath name: `Swept Profile 1`
- editing dialog: `uiExtrudedToolpathForm`
- toolpath class string near the saved toolpath: `mcToolpath`
- tool: `Ball Nose (8 mm)`

This confirms the manual reference contains a saved VCarve Moulding/Extruded
Toolpath.

## API Status

The extracted VCarve API names include:

- `MouldingToolpath`
- `uiMouldingToolpathForm`

No public constructor named like `CreateMouldingToolpath` has been found in the
API name list. Existing supported operations use public creation methods such
as `CreateProfilingToolpath` and `CreateVCarvingToolpath`; Moulding may need a
different creation path or may not be directly creatable from Lua.

## Decision

Do not add `Moulding` to the main DSL yet. First run
`tools\moulding_probe\MouldingProbe.lua` on the manually-created `.crv` job and
inspect the report.

After the probe, decide whether Moulding can be:

- created directly from Lua,
- cloned/edited from an existing saved Moulding toolpath,
- or only prepared by selecting/organising rail and profile geometry for manual
  VCarve calculation.

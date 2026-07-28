# Moulding Probe

This is a safe diagnostic gadget for a manually-created VCarve Moulding
Toolpath. It does not create, delete or recalculate toolpaths.

## How To Run

1. Open the manual reference file in VCarve:
   `C:\Users\Victor\Desktop\1233123.crv`
2. Run `MouldingProbe.lua` as a Vectric gadget.
3. Send back the generated report:
   `tools\moulding_probe\moulding_probe_report.txt`

## Why

The saved `.crv` contains `Swept Profile 1` with
`EditingDialog = uiExtrudedToolpathForm`, which is VCarve's saved Moulding
Toolpath form. The probe records which saved fields and tool data are exposed
to Lua before the Layer DSL project tries to create Moulding toolpaths
automatically.

## Current Reference Files

- Manual VCarve project: `C:\Users\Victor\Desktop\1233123.crv`
- Original geometry-rich DXF: `C:\Users\Victor\Desktop\Fatade\14.dxf`
- Later DXF export: `C:\Users\Victor\Desktop\fa123.dxf`

Note: `fa123.dxf` currently contains only the exterior contour layer. The rail
and profile geometry are visible in `14.dxf` and the saved Moulding toolpath is
visible inside `1233123.crv`.

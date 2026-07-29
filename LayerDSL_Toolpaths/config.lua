--[[--------------------------------------------------------------------------
| config.lua - Global default configuration for the Layer DSL Toolpath gadget.
|
| Every value here can be overridden per-layer by a key=value pair in the
| layer name. Precedence, lowest to highest:
|
|     1. schema built-in default   (lib/schema.lua, `default` field)
|     2. defaults        (this file - applies to every operation)
|     3. operations.<Op> (this file - applies to one operation)
|     4. layer name parameters     (Pocket|tool=6|depth=8)
|
| All linear values are in JOB UNITS (mm if the job is metric, inches if not).
| Feed / plunge rates are in the units named by `rate_units`.
|
| This file is plain Lua and is loaded with dofile(). It must return a table.
----------------------------------------------------------------------------]]

return {

   ---------------------------------------------------------------------------
   -- Where the SmartCAM database lives
   --
   -- Tools, machines, materials, presets and settings are plain JSON files in
   -- this folder. The folder and the files are created on first run if they
   -- do not exist.
   --
   -- This is the ONLY place a storage location is set, so pointing the whole
   -- gadget at a network share is a one-line change:
   --
   --     path = "\\\\server\\cnc\\SmartCAM",
   ---------------------------------------------------------------------------
   database = {
      path = "Y:\\CNC\\SmartCAM",

      -- Let the SMARTCAM_DB environment variable override `path`, so a
      -- workshop can repoint several seats without editing this file on each.
      use_environment = true,
   },

   ---------------------------------------------------------------------------
   -- Layer name syntax
   ---------------------------------------------------------------------------
   --[[
   | DXF layer names cannot contain any of   < > / \ " : ; ? * | , =
   | so BOTH delimiters of the classic form are illegal in an exported DXF:
   |
   |     Pocket|tool=6|depth=8          <-- pipes and equals: NOT DXF-safe
   |     Pocket_tool_6_depth_8          <-- underscores only: DXF-safe
   |
   | Both are listed below and both work, including in the same job: the
   | first separator that actually appears in a layer name decides how that
   | name is read. Reorder or trim these lists to enforce one convention.
   |
   | With underscores there is no punctuation telling keys from values, so
   | the parser matches the longest known key at each position and takes a
   | value span based on the parameter's type. That is why "start_depth_2"
   | reads as start_depth=2 and not start=depth_2.
   |
   | Two things to know about the underscore form:
   |   * A value that is itself several words still works: rate_units_mm_sec.
   |   * A layer that begins with an operation but has no recognisable
   |     parameters (say "Pocket_2") is treated as an ordinary drawing layer
   |     and ignored, so existing layer names are not hijacked.
   ]]
   syntax = {
      separators = { "|", "_" },
      assigns    = { "=", "_" },
   },

   ---------------------------------------------------------------------------
   -- Gadget behaviour
   ---------------------------------------------------------------------------
   gadget = {
      -- Show the confirmation dialog before creating toolpaths.
      -- false = create immediately (useful for unattended batch use).
      show_dialog = true,

      -- Build toolpaths but do not commit them. Overridden by the dialog.
      dry_run = false,

      -- Create the 2D toolpath preview vectors in the 2D view.
      create_2d_previews = true,

      -- Let VCarve show its own warning dialogs during toolpath calculation.
      -- Turn off for unattended runs so nothing blocks.
      interactive_warnings = true,

      -- Toolpath naming. Available placeholders:
      --   {layer}  full layer name       {operation} operation name
      --   {tool}   tool value            {depth}     cut depth
      --   {index}  1-based plan index
      toolpath_name = "{layer}",

      --[[
      | Delete existing toolpaths that share a name with one about to be
      | created. OFF, and only the starting state of the dialog checkbox - the
      | user has the last word on every run.
      |
      | Replacement is scoped to the sheet being machined: a same-named toolpath
      | belonging to another sheet is left alone and reported, and one that will
      | not say which sheet it belongs to is never deleted. That is what makes
      | it safe in a nested job, where every sheet carries the same layer names
      | and VCarve's Lua toolpath list spans all of them.
      |
      | Still off by default, because the intended workflow does not need it:
      | run the gadget once on a fresh project, post the G-code, and if the DXF
      | was wrong, re-import into a new project.
      ]]
      replace_existing = false,

      -- Write a plain-text run report next to the VCarve job file.
      write_report = false,

      -- Treat a layer whose name parses but which holds no usable vectors as
      -- a warning (false) or an error that aborts the run (true).
      empty_layer_is_error = false,

      -- Warn when a machining layer's name is longer than this many
      -- characters. 0 disables the check.
      --
      -- Modern DXF (AC1015 / AutoCAD 2000 and later) allows 255-character
      -- layer names, but older revisions cap them at 31 and some importers
      -- still reject or silently truncate anything longer. Set this to 31 if
      -- your CAD package or machine controller is one of them.
      max_layer_name_length = 0,
   },

   ---------------------------------------------------------------------------
   -- Global parameter defaults - apply to every operation
   ---------------------------------------------------------------------------
   defaults = {
      start_depth   = 0.0,
      depth         = 5.0,

      -- `tool` is a TOOL NUMBER in your VCarve tool database, not a
      -- diameter. Diameter, V-bit angle, feeds, speeds, stepdown and
      -- stepover all come from that library tool.
      tool          = 1,

      --[[
      | Deliberately absent from this file: pass_depth, stepover, feed,
      | plunge, spindle and rate_units.
      |
      | Those belong to the tool, and the tool database is the only place
      | they can be right. A default here would silently override your
      | library on every layer. Write one in a LAYER NAME to override the
      | library for that layer only:
      |
      |     Pocket_tool_1_depth_8_feed_200
      ]]

      -- Machining
      cut_direction = "climb",   -- climb | conventional
      allowance     = 0.0,

      -- Z clearance. safe_z is the rapid-move gap above the material surface;
      -- clearance is the height at which plunges slow to the plunge feedrate.
      safe_z        = 5.0,
      clearance     = 2.0,
      -- home_z is absolute. nil = material surface + 20% of thickness.
      home_z        = nil,

      -- Which vectors on the layer to machine.
      -- closed | open | all | circles
      vector_selection = "closed",
   },

   ---------------------------------------------------------------------------
   -- Per-operation defaults - override `defaults` for one operation only
   ---------------------------------------------------------------------------
   operations = {

      Pocket = {
         strategy      = "offset",  -- offset | raster
         raster_angle  = 0.0,
         last_pass     = true,      -- final profile pass around the pocket
         ramp          = false,
         ramp_angle    = 25.0,
         -- Two-tool pocketing. Set roughing=true AND give roughing_tool the
         -- TOOL NUMBER of a larger cutter, e.g.
         --     Pocket_tool_1_depth_12_roughing_true_roughing_tool_2
         roughing      = false,
      },

      Profile = {
         side          = "outside", -- outside | inside | on
         tabs          = false,
         tab_width     = 5.0,
         tab_height    = 1.5,
         lead_in       = 0.0,       -- 0 disables; >0 = lead length
         lead_out      = 0.0,
         lead_type     = "circular",-- circular | linear
         lead_angle    = 45.0,      -- linear leads only
         ramp          = false,
         ramp_angle    = 25.0,
         inside_corner = false,     -- corner sharpening (V-bits only)
         offset        = 0.0,       -- extra overcut past the start point
      },

      Drill = {
         peck             = 0.0,    -- 0 disables peck drilling
         vector_selection = "circles",
      },

      VCarve = {
         -- `tool` is the tool number of a V-BIT. Its included angle comes
         -- from the library, so there is no angle to set here.
         flat_depth = 0.0,          -- 0 = pure V-carve, >0 = flat bottom
         -- A flat bottom also needs flat_tool = the tool number of the end
         -- mill that clears it, e.g. VCarve_tool_3_flat_3_flat_tool_1
         strategy   = "offset",
      },
   },
}

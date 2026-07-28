--[[--------------------------------------------------------------------------
| lib/schema.lua - The parameter dictionary.
|
| THIS IS THE EXTENSION POINT. To teach the DSL a new layer-name parameter,
| add one entry to PARAMS below. Nothing else in the gadget needs to change
| for the parser to accept, validate, default and report on it. (Only if the
| new parameter must drive a VCarve setting do you also touch lib/ops/*.lua,
| in exactly one place.)
|
| Entry fields
| ------------
|   key         string  canonical name; the key used in the returned table
|   type        string  a function name in lib/coerce.lua
|                       number | integer | boolean | string | enum | switch
|   aliases     table   other spellings accepted in a layer name
|   values      table   enum only: accepted spelling -> canonical token
|   min / max   number  numeric bounds, inclusive
|   default     any     fallback when neither config.lua nor the layer says
|   applies_to  table   set of operation names this parameter affects.
|                       nil = every operation. Used only to warn about
|                       parameters that will be silently ignored.
|   doc         string  one-line help, surfaced in the run report
|
| Pure Lua - no VCarve API dependency.
----------------------------------------------------------------------------]]

local Coerce = nil  -- injected by Schema.init; keeps this file dependency-free

local Schema = {}

---------------------------------------------------------------------------
-- Shared enum vocabularies
---------------------------------------------------------------------------

local CUT_DIRECTION = {
   climb        = "climb",
   cw           = "climb",
   clockwise    = "climb",
   conventional = "conventional",
   ccw          = "conventional",
   counter      = "conventional",
   anticlockwise= "conventional",
}

local PROFILE_SIDE = {
   outside = "outside", out = "outside", external = "outside", ext = "outside",
   inside  = "inside",  ["in"] = "inside", internal = "inside", int = "inside",
   on      = "on",      centre = "on", center = "on", middle = "on",
}

local CLEAR_STRATEGY = {
   offset = "offset", spiral = "offset",
   raster = "raster", zigzag = "raster", zig_zag = "raster", linear = "raster",
}

local VECTOR_SELECTION = {
   closed  = "closed",
   open    = "open",
   all     = "all",  both = "all", any = "all",
   circles = "circles", circle = "circles", holes = "circles",
}

local LEAD_TYPE = {
   circular = "circular", arc = "circular", curved = "circular",
   linear   = "linear",   line = "linear",  straight = "linear",
}

local RAMP_TYPE = {
   zigzag = "zigzag", zig_zag = "zigzag",
   spiral = "spiral", helix = "spiral", helical = "spiral",
   linear = "linear", line = "linear", smooth = "linear",
}

local RATE_UNITS = {
   mm_sec = "mm_sec", mmsec = "mm_sec", mm_s = "mm_sec", mms = "mm_sec",
   mm_min = "mm_min", mmmin = "mm_min", mm_m = "mm_min",
   m_min  = "m_min",  metres_min = "m_min", meters_min = "m_min",
   in_sec = "in_sec", inch_sec = "in_sec", inches_sec = "in_sec", ips = "in_sec",
   in_min = "in_min", inch_min = "in_min", inches_min = "in_min", ipm = "in_min",
   ft_min = "ft_min", feet_min = "ft_min", fpm = "ft_min",
}

local PASS_POSITION = {
   none  = "none",  never = "none", off = "none",
   first = "first", before = "first",
   last  = "last",  after = "last", ["true"] = "last", on = "last", yes = "last",
}

---------------------------------------------------------------------------
-- Operation names. Adding an operation = one entry here plus one module in
-- lib/ops/. lib/factory.lua wires them together by name.
---------------------------------------------------------------------------

Schema.OPERATIONS = {
   pocket  = "Pocket",
   pockets = "Pocket",
   profile = "Profile",
   cutout  = "Profile",
   contour = "Profile",
   drill   = "Drill",
   drilling= "Drill",
   bore    = "Drill",
   vcarve  = "VCarve",
   v_carve = "VCarve",
   carve   = "VCarve",
   engrave = "VCarve",
   moulding = "Moulding",
   molding  = "Moulding",
   sweep    = "Moulding",
   swept    = "Moulding",
}

---------------------------------------------------------------------------
-- The parameter dictionary
---------------------------------------------------------------------------

Schema.PARAMS = {

   -- ---- identity ---------------------------------------------------------
   {  key = "operation", type = "string",
      doc = "Operation to run. Normally the first field of the layer name." },

   -- ---- tooling ----------------------------------------------------------
   --[[
   | `tool` identifies a tool in the SmartCAM library (tools.json) - by id,
   | or by name. It is not a diameter. Every piece of tool geometry -
   | diameter, V-bit included angle, tip radius - comes from that record,
   | which is the only place it can be correct.
   |
   | In the underscore syntax a value is one token, so use the id there.
   ]]
   {  key = "tool", type = "tool_ref",
      aliases = { "bit", "cutter", "tool_no", "toolnum", "tn" },
      doc = "Tool id (or name) in the SmartCAM tool library." },

   {  key = "pass_depth", type = "number", min = 0.001,
      aliases = { "stepdown", "step_down", "doc", "depth_per_pass" },
      doc = "Cut depth per pass (tool stepdown)." },

   {  key = "stepover", type = "number", min = 0.1, max = 100,
      aliases = { "pover", "step_over", "so" },
      doc = "Stepover as a PERCENTAGE of tool diameter." },

   {  key = "feed", type = "number", min = 0.001,
      aliases = { "feed_rate", "feedrate", "f" },
      doc = "Cutting feed rate, in the units given by rate_units." },

   {  key = "plunge", type = "number", min = 0.001,
      aliases = { "plunge_rate", "plungerate" },
      doc = "Plunge feed rate, in the units given by rate_units." },

   {  key = "spindle", type = "integer", min = 0,
      aliases = { "rpm", "spindle_speed", "speed" },
      doc = "Spindle speed in RPM." },

   {  key = "rate_units", type = "enum", values = RATE_UNITS,
      doc = "Units for feed and plunge: mm_sec mm_min m_min in_sec in_min ft_min." },

   -- ---- depths -----------------------------------------------------------
   {  key = "depth", type = "number", min = 0,
      aliases = { "cut_depth", "cutdepth", "d" },
      doc = "Cut depth BELOW start_depth." },

   {  key = "start_depth", type = "number", min = 0,
      aliases = { "startdepth", "start", "z_start" },
      doc = "Depth below the material surface at which cutting begins." },

   -- ---- general machining ------------------------------------------------
   {  key = "cut_direction", type = "enum", values = CUT_DIRECTION,
      aliases = { "direction", "dir" },
      doc = "climb or conventional." },

   {  key = "allowance", type = "number",
      aliases = { "stock", "leave", "offset_allowance" },
      doc = "Material left on the cut (negative removes extra)." },

   {  key = "vector_selection", type = "enum", values = VECTOR_SELECTION,
      aliases = { "vectors", "select", "selection" },
      doc = "Which vectors on the layer to machine: closed open all circles." },

   {  key = "profile_layer", type = "string",
      applies_to = { Moulding = true },
      aliases = { "profile", "section_layer", "section" },
      doc = "Layer containing the Moulding cross-section profile." },

   -- ---- Z clearance ------------------------------------------------------
   {  key = "safe_z", type = "number", min = 0,
      aliases = { "safez", "rapid_z", "safe_height" },
      doc = "Rapid-move clearance above the material surface." },

   {  key = "clearance", type = "number", min = 0,
      aliases = { "start_z_gap", "plunge_gap" },
      doc = "Height above the surface at which rapid plunges become feed plunges." },

   {  key = "home_z", type = "number",
      aliases = { "homez", "home_height" },
      doc = "ABSOLUTE Z for the toolpath home position." },

   -- ---- Profile ----------------------------------------------------------
   {  key = "side", type = "enum", values = PROFILE_SIDE,
      applies_to = { Profile = true },
      aliases = { "profile_side" },
      doc = "Machining side: outside, inside or on." },

   {  key = "tabs", type = "boolean",
      applies_to = { Profile = true },
      aliases = { "use_tabs", "bridges" },
      doc = "Use holding tabs. Tab POSITIONS must already exist on the vectors." },

   {  key = "tab_width", type = "number", min = 0,
      applies_to = { Profile = true },
      aliases = { "tab_length" },
      doc = "Tab length along the vector." },

   {  key = "tab_height", type = "number", min = 0,
      applies_to = { Profile = true },
      aliases = { "tab_thickness" },
      doc = "Tab thickness (height left uncut)." },

   {  key = "lead_in", type = "switch", min = 0,
      applies_to = { Profile = true },
      aliases = { "leadin" },
      doc = "Lead-in length. 0 or false disables." },

   {  key = "lead_out", type = "switch", min = 0,
      applies_to = { Profile = true },
      aliases = { "leadout" },
      doc = "Lead-out length. 0 or false disables." },

   {  key = "lead_type", type = "enum", values = LEAD_TYPE,
      applies_to = { Profile = true },
      doc = "Lead geometry: circular or linear." },

   {  key = "lead_angle", type = "number", min = 0, max = 90,
      applies_to = { Profile = true },
      aliases = { "linear_lead_angle" },
      doc = "Approach angle for linear leads, in degrees." },

   {  key = "offset", type = "number", min = 0,
      applies_to = { Profile = true },
      aliases = { "overcut", "overcut_distance" },
      doc = "Distance to continue past the start point when closing a profile." },

   {  key = "inside_corner", type = "boolean",
      applies_to = { Profile = true },
      aliases = { "corner_sharpen", "sharpen_corners" },
      doc = "Add 3D corner-sharpening moves to internal corners (V-bits only)." },

   {  key = "square_corners", type = "boolean",
      applies_to = { Profile = true },
      doc = "Create square external corners instead of rounded ones." },

   {  key = "keep_start_points", type = "boolean",
      applies_to = { Profile = true },
      doc = "Keep vector start points instead of optimising them." },

   -- ---- Pocket -----------------------------------------------------------
   {  key = "strategy", type = "enum", values = CLEAR_STRATEGY,
      applies_to = { Pocket = true, VCarve = true },
      aliases = { "clearance_strategy", "pocket_strategy" },
      doc = "Area-clearance strategy: offset or raster." },

   {  key = "raster_angle", type = "number",
      applies_to = { Pocket = true, VCarve = true },
      doc = "Raster angle in degrees, when strategy=raster." },

   {  key = "last_pass", type = "enum", values = PASS_POSITION,
      applies_to = { Pocket = true, VCarve = true },
      aliases = { "profile_pass", "finish_pass" },
      doc = "Where the pocket's profile pass runs: none, first or last." },

   {  key = "roughing", type = "boolean",
      applies_to = { Pocket = true },
      aliases = { "two_tool", "rough" },
      doc = "Two-tool pocketing: clear the bulk with a larger roughing tool." },

   {  key = "roughing_tool", type = "tool_ref",
      applies_to = { Pocket = true },
      aliases = { "rough_tool", "clearance_tool" },
      doc = "Tool id of the larger roughing tool." },

   {  key = "finishing", type = "boolean",
      applies_to = { Pocket = true, Profile = true },
      aliases = { "finish" },
      doc = "Finishing mode: forces allowance to 0 and adds a final profile pass." },

   -- ---- ramping ----------------------------------------------------------
   {  key = "ramp", type = "switch", min = 0,
      applies_to = { Pocket = true, Profile = true },
      doc = "Ramp into the cut. A number sets the ramp distance." },

   {  key = "ramp_angle", type = "number", min = 0.1, max = 89,
      applies_to = { Pocket = true, Profile = true },
      doc = "Ramp angle in degrees. Setting it constrains the ramp by angle." },

   {  key = "ramp_type", type = "enum", values = RAMP_TYPE,
      applies_to = { Profile = true },
      doc = "Ramp geometry: zigzag, spiral or linear." },

   -- ---- Drill ------------------------------------------------------------
   {  key = "peck", type = "switch", min = 0,
      applies_to = { Drill = true },
      aliases = { "peck_depth", "peck_gap", "retract" },
      doc = "Peck-drill retract gap. 0 or false disables pecking." },

   -- ---- VCarve -----------------------------------------------------------
   {  key = "flat_depth", type = "number", min = 0,
      applies_to = { VCarve = true },
      aliases = { "flat", "flat_bottom" },
      doc = "Flat-bottom depth. 0 = a pure V-carve with no flat bottom." },

   {  key = "flat_tool", type = "tool_ref",
      applies_to = { VCarve = true },
      aliases = { "clear_tool", "area_tool" },
      doc = "Tool id of the end mill that clears the flat bottom." },
}

---------------------------------------------------------------------------
-- Index construction
---------------------------------------------------------------------------

--- Build the lookup index. Call once at load.
-- @param coerce the lib/coerce module (injected to keep this file pure data)
function Schema.init(coerce)
   Coerce = coerce

   local by_key, canonical = {}, {}

   local function claim(name, spec, kind)
      local existing = by_key[name]
      if existing ~= nil and existing ~= spec then
         error(string.format(
            "schema: %s %q collides with parameter %q", kind, name, existing.key))
      end
      by_key[name] = spec
   end

   for i = 1, #Schema.PARAMS do
      local spec = Schema.PARAMS[i]

      if type(spec.key) ~= "string" or spec.key == "" then
         error("schema: entry " .. i .. " has no key")
      end
      if Coerce[spec.type] == nil then
         error(string.format("schema: parameter %q has unknown type %q",
                             spec.key, tostring(spec.type)))
      end
      if spec.type == "enum" and type(spec.values) ~= "table" then
         error(string.format("schema: enum parameter %q has no values table", spec.key))
      end

      claim(spec.key, spec, "key")
      for _, alias in ipairs(spec.aliases or {}) do
         claim(alias, spec, "alias")
      end

      canonical[#canonical + 1] = spec.key
   end

   Schema.by_key    = by_key
   Schema.canonical = canonical

   --[[
   | Token spans, for the underscore syntax.
   |
   | When '_' is both the field separator and the assignment character
   | (Pocket_tool_6_depth_8, the only form every DXF tool accepts), the
   | parser cannot tell key from value by punctuation. It resolves them by
   | matching the LONGEST known key at each position - "start_depth_2" is
   | start_depth=2, not start=depth_2 - which needs to know how many tokens
   | the longest name spans. Same for enum values like "mm_sec".
   ]]
   local function token_count(name)
      local n = 1
      for _ in name:gmatch("_") do n = n + 1 end
      return n
   end

   local max_key, max_enum, max_op = 1, 1, 1

   for name in pairs(by_key) do
      max_key = math.max(max_key, token_count(name))
   end
   for name in pairs(Schema.OPERATIONS) do
      max_op = math.max(max_op, token_count(name))
   end
   for i = 1, #Schema.PARAMS do
      local spec = Schema.PARAMS[i]
      if spec.type == "enum" then
         for spelling in pairs(spec.values) do
            max_enum = math.max(max_enum, token_count(spelling))
         end
      end
   end

   Schema.max_key_tokens       = max_key
   Schema.max_enum_tokens      = max_enum
   Schema.max_operation_tokens = max_op

   return Schema
end

--- Look up a parameter spec by key or alias. Returns nil if unknown.
function Schema.find(name)
   return Schema.by_key[name]
end

--- Resolve an operation token to its canonical name, or nil.
function Schema.find_operation(token)
   return Schema.OPERATIONS[token]
end

--- Distinct canonical operation names, sorted.
function Schema.operation_names()
   local seen, out = {}, {}
   for _, name in pairs(Schema.OPERATIONS) do
      if not seen[name] then seen[name] = true; out[#out + 1] = name end
   end
   table.sort(out)
   return out
end

return Schema

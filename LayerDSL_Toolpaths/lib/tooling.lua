--[[--------------------------------------------------------------------------
| lib/tooling.lua - Turn SmartCAM tool records into VCarve Tool objects.
|
| The one place that knows both the JSON tool format and the VCarve Tool
| API. Lookup lives in lib/db/tool_repository.lua and stays free of VCarve;
| this module is where the two meet.
|
| Every operation gets its cutter from here, so feeds, speeds, stepdown and
| units are applied identically no matter which toolpath is being built.
|
| Requires the VCarve API (Tool, ToolpathPosData, MaterialBlock).
----------------------------------------------------------------------------]]

local Tooling = {}

local Enums, Coerce

--- @param enums      lib/enums.lua
-- @param coerce     lib/coerce.lua       for token normalisation
-- @param repository lib/db/tool_repository.lua  for validate/describe
function Tooling.init(enums, coerce, repository)
   Enums             = enums
   Coerce            = coerce
   Tooling.repository = repository
   return Tooling
end

---------------------------------------------------------------------------
-- Job context
---------------------------------------------------------------------------

--- Gather the job-level facts every toolpath needs.
function Tooling.context(job)
   local material = MaterialBlock()
   return {
      job       = job,
      material  = material,
      in_mm     = job.InMM,
      thickness = material.Thickness,
      box       = material.MaterialBox,
   }
end

---------------------------------------------------------------------------
-- Tool construction
---------------------------------------------------------------------------

--- Build a VCarve Tool from a SmartCAM tool record, applying layer overrides.
--
-- The record from tools.json is authoritative: geometry, feeds, speeds,
-- stepdown and stepover all come from it. Only values the LAYER NAME states
-- explicitly override it - a config.lua default never does, because config
-- cannot know better than the tool library.
--
-- @param spec table
--    reference       any    tool id or name, as written in the layer
--    role            string what this tool is for, used in messages
--    params          table  the parsed DSL parameters
--    ctx             table  from Tooling.context, carrying ctx.tools
--    stepover        number optional stepover % override (used by the rougher)
-- @return Tool | nil, warnings, error_string
function Tooling.from_library(spec)
   local params   = spec.params
   local explicit = params.explicit or {}
   local warnings = {}

   local function note(msg) if msg then warnings[#warnings + 1] = msg end end

   ------------------------------------------------------------------
   -- Look the record up, and refuse anything unusable before building.
   ------------------------------------------------------------------
   local record, lookup_err = spec.ctx.tools:find(spec.reference)
   if record == nil then
      return nil, warnings, lookup_err
   end

   local problems = Tooling.repository.validate(record)
   if #problems > 0 then
      return nil, warnings, string.format(
         "%s (%s) cannot be used: %s",
         spec.role or "tool", Tooling.repository.describe(record),
         table.concat(problems, "; "))
   end

   ------------------------------------------------------------------
   -- Construct the VCarve tool.
   ------------------------------------------------------------------
   local tool, build_err = Tooling.build_tool(record, note)
   if tool == nil then
      return nil, warnings, build_err
   end

   ------------------------------------------------------------------
   -- Overrides the layer name asked for, and nothing else.
   ------------------------------------------------------------------
   if explicit.pass_depth then tool.Stepdown = params.pass_depth end

   -- `stepover` in the DSL is a PERCENTAGE; the tool stores an absolute
   -- distance, so it is resolved against the record's real diameter.
   local stepover_pct = spec.stepover or (explicit.stepover and params.stepover)
   if stepover_pct then
      local diameter = tonumber(record.diameter)
      if diameter and diameter > 0 then
         local stepover = diameter * (stepover_pct / 100.0)
         tool.Stepover      = stepover
         tool.ClearStepover = stepover
      else
         note("cannot apply stepover: the tool record has no diameter")
      end
   end

   if explicit.rate_units then
      local rate_units, warn = Enums.rate_units(params.rate_units)
      note(warn)
      tool.RateUnits = rate_units
   end

   if explicit.feed    then tool.FeedRate     = params.feed    end
   if explicit.plunge  then tool.PlungeRate   = params.plunge  end
   if explicit.spindle then tool.SpindleSpeed = params.spindle end

   return tool, warnings, nil, record
end

--- Turn one tool record into a VCarve Tool object.
--
-- Kept separate from lookup and from override handling so it can be tested
-- on its own, and so nothing else needs to know the VCarve property names.
--
-- @return Tool, or nil plus a reason
function Tooling.build_tool(record, note)
   note = note or function() end

   local tool_type, type_warning = Enums.tool_type(record.type or "end_mill")
   if type_warning then note(type_warning) end

   local name = tostring(record.name or ("Tool " .. tostring(record.id)))

   local ok, tool = pcall(function() return Tool(name, tool_type) end)
   if not ok or tool == nil then
      return nil, string.format("VCarve refused to create tool %q (%s)",
                                name, tostring(tool))
   end

   -- Units first: VCarve reads every geometry field against this flag, so a
   -- millimetre tool stays a millimetre tool even in an inch job.
   tool.InMM = Tooling.record_in_mm(record)

   tool.ToolDia = tonumber(record.diameter) or 0

   --[[
   | Shape fields that only some tool types carry. Note VBit_Angle: the
   | Vectric sample gadgets spell this `VBitAngle`, which is not a real
   | binding, so the angle silently stays at its default and the carve comes
   | out wrong. tests/api_names.lua pins the correct spelling.
   ]]
   local angle = tonumber(record.included_angle)
   if angle then tool.VBit_Angle = angle end

   local tip = tonumber(record.tip_radius)
   if tip then tool.Tip_Radius = tip end

   local flat = tonumber(record.flat_diameter)
   if flat then tool.Flat_Diameter = flat end

   local line_width = tonumber(record.line_width)
   if line_width then tool.Line_Width = line_width end

   -- Cutting data. Validation has already refused zero feeds.
   tool.Stepdown = tonumber(record.stepdown) or 0
   local stepover = tonumber(record.stepover) or 0
   tool.Stepover      = stepover
   tool.ClearStepover = tonumber(record.clear_stepover) or stepover

   local rate_units, rate_warning = Enums.rate_units(
      Coerce.normalise_token(record.rate_units or "mm_min"))
   if rate_warning then note(rate_warning) end
   tool.RateUnits = rate_units

   tool.FeedRate     = tonumber(record.feed_rate) or 0
   tool.PlungeRate   = tonumber(record.plunge_rate) or 0
   tool.SpindleSpeed = tonumber(record.spindle_speed) or 0
   tool.ToolNumber   = tonumber(record.tool_number) or tonumber(record.id) or 1

   return tool
end

--- Is this record expressed in millimetres?
function Tooling.record_in_mm(record)
   local units = Coerce.normalise_token(record.units or "mm")
   if units == "inch" or units == "inches" or units == "in" then return false end
   return true
end

--- Warn when a tool is an odd fit for the operation.
-- Never fatal: the operator may know something the gadget does not.
function Tooling.check_tool_type(record, reference, expected, operation)
   if record == nil then return nil end

   local actual = Coerce.normalise_token(record.type or "end_mill")
   if actual == expected then return nil end

   return string.format(
      "tool %s is a %s; a %s toolpath normally uses a %s",
      tostring(reference), actual:gsub("_", " "),
      operation, expected:gsub("_", " "))
end

---------------------------------------------------------------------------
-- Position data
---------------------------------------------------------------------------

--- Build the home position / safe Z object for a toolpath.
function Tooling.position(params, ctx)
   local pos = ToolpathPosData()

   local box = ctx.box
   local blc = box.BLC

   -- Home Z is ABSOLUTE. Default to a fifth of the stock above the top of
   -- the material, matching the Vectric samples.
   local home_z = params.home_z
   if home_z == nil then
      home_z = box.TRC.z + (ctx.thickness * 0.2)
   end

   pos:SetHomePosition(blc.x, blc.y, home_z)

   pos.SafeZGap  = params.safe_z
   pos.StartZGap = params.clearance

   -- Guard against a home_z the user set inside the stock.
   pos:EnsureHomeZIsSafe()

   return pos
end

---------------------------------------------------------------------------
-- Shared validation
---------------------------------------------------------------------------

--- Checks that apply to every operation. Returns an array of problem strings;
--- empty means the parameters are usable.
function Tooling.validate(params, ctx)
   local problems = {}

   if params.depth <= 0 then
      problems[#problems + 1] = "depth must be greater than zero"
   end

   local total = (params.start_depth or 0) + params.depth
   if ctx.thickness > 0 and total > ctx.thickness + 1e-6 then
      -- A through-cut is normal, so this is only worth flagging when it is
      -- large enough to look like a units mistake.
      if total > ctx.thickness * 1.5 then
         problems[#problems + 1] = string.format(
            "start_depth + depth (%.3f) is far below the material thickness (%.3f)"
            .. " - check the units", total, ctx.thickness)
      end
   end

   if params.pass_depth and params.pass_depth > params.depth then
      -- Not fatal: VCarve clamps it to a single full-depth pass.
      problems[#problems + 1] = string.format(
         "pass_depth (%.3f) exceeds depth (%.3f); the cut will be a single pass",
         params.pass_depth, params.depth)
   end

   return problems
end

return Tooling

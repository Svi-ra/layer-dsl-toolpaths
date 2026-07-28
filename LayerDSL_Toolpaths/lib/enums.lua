--[[--------------------------------------------------------------------------
| lib/enums.lua - Bridge between DSL tokens and VCarve constants.
|
| The parser deliberately knows nothing about VCarve: it stores plain strings
| like "climb" or "outside". This module is the ONLY place those strings turn
| into ProfileParameterData.CLIMB_DIRECTION and friends.
|
| The lookups are built lazily, inside functions, because the Vectric globals
| exist only while running inside VCarve. That keeps every other module
| loadable (and testable) in a plain Lua interpreter.
|
| Verified against VCarve Pro 12.5 and the V12 Gadget SDK documentation.
----------------------------------------------------------------------------]]

local Enums = {}

--- Look a token up in a table, falling back to the first listed default.
local function pick(map, token, fallback_token, what)
   local value = map[token]
   if value ~= nil then return value end
   return map[fallback_token], string.format(
      "unsupported %s %q; using %q", what, tostring(token), fallback_token)
end

--- climb / conventional
-- NOTE: pocket toolpaths use the ProfileParameterData constants too - this is
-- documented behaviour, not a typo. (SDK: PocketParameterData.CutDirection)
function Enums.cut_direction(token)
   return pick({
      climb        = ProfileParameterData.CLIMB_DIRECTION,
      conventional = ProfileParameterData.CONVENTIONAL_DIRECTION,
   }, token, "climb", "cut direction")
end

--- outside / inside / on
function Enums.profile_side(token)
   return pick({
      outside = ProfileParameterData.PROFILE_OUTSIDE,
      inside  = ProfileParameterData.PROFILE_INSIDE,
      on      = ProfileParameterData.PROFILE_ON,
   }, token, "outside", "profile side")
end

--- none / first / last
function Enums.profile_pass(token)
   return pick({
      none  = PocketParameterData.PROFILE_NONE,
      first = PocketParameterData.PROFILE_FIRST,
      last  = PocketParameterData.PROFILE_LAST,
   }, token, "last", "profile pass position")
end

--- circular / linear
function Enums.lead_type(token)
   return pick({
      circular = LeadInOutData.CIRCULAR_LEAD,
      linear   = LeadInOutData.LINEAR_LEAD,
   }, token, "circular", "lead type")
end

--- zigzag / spiral / linear
function Enums.ramp_type(token)
   return pick({
      zigzag = RampingData.RAMP_ZIG_ZAG,
      spiral = RampingData.RAMP_SPIRAL,
      linear = RampingData.RAMP_ZIG_ZAG,   -- no distinct linear ramp constant
   }, token, "zigzag", "ramp type")
end

--- feed rate units
function Enums.rate_units(token)
   return pick({
      mm_sec = Tool.MM_SEC,
      mm_min = Tool.MM_MIN,
      m_min  = Tool.METRES_MIN,
      in_sec = Tool.INCHES_SEC,
      in_min = Tool.INCHES_MIN,
      ft_min = Tool.FEET_MIN,
   }, token, "mm_sec", "rate units")
end

--- Tool type by name, used by the operation modules.
--[[
| The eight tool types VCarve can CREATE from Lua.
|
| Tool(name, type) accepts exactly these; the documentation lists two more
| (FORM_TOOL, LASER) that can be read back from an existing toolpath but
| cannot be constructed, so they are deliberately absent.
|
| Keep this in step with VALID_TYPES in lib/db/tool_repository.lua. A type
| the repository accepts but this cannot build would silently become an end
| mill, which is exactly the class of quiet wrongness this gadget avoids.
]]
function Enums.tool_type(name)
   return pick({
      end_mill           = Tool.END_MILL,
      ball_nose          = Tool.BALL_NOSE,
      radiused_end_mill  = Tool.RADIUSED_END_MILL,
      vbit               = Tool.VBIT,
      engraving          = Tool.ENGRAVING,
      radiused_engraving = Tool.RADIUSED_ENGRAVING,
      through_drill      = Tool.THROUGH_DRILL,
      diamond_drag       = Tool.DIAMOND_DRAG,
   }, name, "end_mill", "tool type")
end

---------------------------------------------------------------------------
-- GeometrySelector wiring
---------------------------------------------------------------------------

--- Configure a GeometrySelector to pick up exactly the vectors on one layer.
--
-- Without this the toolpath would calculate against whatever the user happens
-- to have selected in the 2D view. Restricting by layer name is what lets the
-- gadget process a whole job unattended.
--
-- @param layer_name       string   layer to restrict to
-- @param selection_token  string   closed | open | all | circles
-- @param tool_diameter    number   used when matching circles to the tool
-- @return GeometrySelector
function Enums.build_selector(layer_name, selection_token, tool_diameter)
   local selector = GeometrySelector()

   -- Activating the filter. Without GeometryFilterUsed the selector stays
   -- inert and VCarve falls back to the current 2D selection.
   selector.GeometryFilterUsed = true

   selector.OnlyOnLayers = true
   selector:AddLayerName(layer_name)

   -- Groups whose members only partly match still get taken; otherwise a
   -- grouped set of vectors on a machining layer would be silently dropped.
   selector.MixedGroupsOk = true

   if selection_token == "open" then
      selector.SelectOpen   = true
      selector.SelectClosed = false
      selector.AllowOpen    = true
   elseif selection_token == "all" then
      selector.SelectOpen   = true
      selector.SelectClosed = true
      selector.AllowOpen    = true
   elseif selection_token == "circles" then
      selector.SelectClosed  = true
      selector.SelectCircles = true
      selector.CircleMatchAll = true
   else -- "closed" is the default
      selector.SelectClosed = true
      selector.SelectOpen   = false
   end

   if tool_diameter then selector.ToolDia = tool_diameter end

   selector:ApplySelector()
   return selector
end

return Enums

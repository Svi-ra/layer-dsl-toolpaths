--[[--------------------------------------------------------------------------
| lib/runner.lua - Orchestration: scan layers, plan, execute, report.
|
| Two clean phases:
|
|   Runner.plan(...)     reads every layer, parses the machining ones, and
|                        returns an ordered list of jobs. Touches nothing.
|   Runner.execute(...)  hands each job to the factory.
|
| Splitting them is what makes the confirmation dialog and `dry_run` possible:
| the user sees exactly what will be created before anything is created.
----------------------------------------------------------------------------]]

local Runner = {}

local Parser, Factory, Tooling, Log, Tools

function Runner.init(deps)
   Parser  = deps.parser
   Factory = deps.factory
   Tooling = deps.tooling
   Log     = deps.log
   Tools   = deps.tool_repository   -- for validate/describe, not for lookup
   return Runner
end

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

--- Expand the toolpath_name template from config.lua.
local function format_name(template, params, index)
   local subs = {
      layer     = params.layer_name,
      operation = params.operation,
      tool      = string.format("%.3g", params.tool or 0),
      depth     = string.format("%.3g", params.depth or 0),
      index     = tostring(index),
   }
   local name = (template or "{layer}"):gsub("{(%w+)}", function(key)
      return subs[key] ~= nil and subs[key] or ("{" .. key .. "}")
   end)
   name = name:gsub("^%s+", ""):gsub("%s+$", "")
   return name ~= "" and name or params.layer_name
end

--- Does the layer hold anything a toolpath could use?
local function layer_has_geometry(layer)
   return layer:GetHeadPosition() ~= nil
end

--- Every layer in the job, in the order the toolpaths should be built.
--
-- Order is not cosmetic here: toolpaths are machined in the order they are
-- created, and the DXF's layer order IS the machining sequence the CAM
-- upstream of this gadget decided on. Getting it backwards runs the job
-- inside out.
--
-- Walking VCarve's layer manager head-to-tail produces the REVERSE of the
-- DXF order, so the walk is reversed to put it back. `layer_order` in
-- config.lua exists because that is an observed behaviour of VCarve 12.5
-- rather than a documented guarantee: if a future build enumerates the other
-- way round, one setting corrects it without touching this file.
--
--   "dxf"     first layer in the DXF is machined first        (default)
--   "vcarve"  whatever order the layer manager hands them out
--
-- Either way the result is deterministic: the manager's order is stable, so
-- the same job always produces the same sequence.
local function ordered_layers(layer_manager, config)
   local layers = {}

   local pos = layer_manager:GetHeadPosition()
   while pos ~= nil do
      local layer
      layer, pos = layer_manager:GetNext(pos)
      if layer ~= nil then layers[#layers + 1] = layer end
   end

   if (config.gadget.layer_order or "dxf") ~= "vcarve" then
      -- math.floor, not the // operator: VCarve embeds Lua 5.2, where // is a
      -- syntax error the test host would happily accept.
      for i = 1, math.floor(#layers / 2) do
         layers[i], layers[#layers - i + 1] = layers[#layers - i + 1], layers[i]
      end
   end

   return layers
end

--- Every tool a parameter table refers to, in a stable order.
--
-- A reference is an id (number) or a name (string); the repository resolves
-- either. Secondary tools only count when the setting that uses them is on,
-- so a stale `roughing_tool` on a layer that is not roughing is not required
-- to exist.
local function tool_numbers_of(params)
   local references = {}

   local relevant = {
      tool          = true,
      roughing_tool = params.roughing and true or false,
      flat_tool     = (tonumber(params.flat_depth) or 0) > 0,
   }

   for _, key in ipairs{ "tool", "roughing_tool", "flat_tool" } do
      local reference = params[key]
      local kind = type(reference)
      if relevant[key] and (kind == "number" or kind == "string") then
         references[#references + 1] = reference
      end
   end

   return references
end

---------------------------------------------------------------------------
-- split passes
---------------------------------------------------------------------------

--[[
| `split_passes` in a layer name: one toolpath per pass.
|
| VCarve spreads a cut EVENLY over its passes - a 12 mm pass depth over 19 mm
| cuts 9.5 + 9.5 - and the Lua API has no way to ask for "Maintain exact tool
| pass depth". What it can do is cut a toolpath that is only one pass deep. So
| a flagged layer becomes a stack of toolpaths, each starting where the last
| one finished and cutting the tool's full pass depth, the final one cutting
| whatever is left:
|
|     depth 19, pass depth 12   ->   0 to 12,  then 12 to 19
|
| No single toolpath is deeper than the pass depth, so VCarve has nothing to
| spread, and the last one ends at exactly the depth the layer name gives.
|
| Without the flag, or when the cut already fits in one pass, the layer is one
| toolpath built exactly as before.
]]

local SPLIT_OPERATIONS = { Profile = true, Pocket = true }
local SPLIT_EPSILON    = 1e-6

--- The toolpath name with any " [2 of 3]" part suffix removed.
local function base_name(name)
   if type(name) ~= "string" then return name end
   return (name:gsub(" %[%d+ of %d+%]$", ""))
end

--- The parameter tables to build for one layer: one per pass when the layer
--- asks for split passes, otherwise just the layer's own.
--
-- @param tools ToolRepository (may be nil: then nothing is split)
-- @param in_mm whether the JOB is in millimetres
local function pass_parts(params, tools, in_mm)
   if not params.split_passes or not SPLIT_OPERATIONS[params.operation]
      or tools == nil
   then
      return { params }
   end

   local record = tools:find(params.tool)
   if record == nil then return { params } end

   -- The same pass depth the tool is built with: the library's, unless the
   -- layer name overrode it. It is in the TOOL's units; depths are in the job's.
   local stepdown = tonumber(record.stepdown)
   if (params.explicit or {}).pass_depth then stepdown = params.pass_depth end
   if type(stepdown) ~= "number" or stepdown <= 0 then return { params } end

   local tool_in_mm = Tooling.record_in_mm(record)
   if tool_in_mm and in_mm == false then stepdown = stepdown / 25.4 end
   if not tool_in_mm and in_mm ~= false then stepdown = stepdown * 25.4 end

   local depth = params.depth or 0
   if depth <= stepdown + SPLIT_EPSILON then return { params } end

   local count = math.ceil((depth - SPLIT_EPSILON) / stepdown)
   local parts = {}

   for k = 1, count do
      local part = {}
      for key, value in pairs(params) do part[key] = value end

      local cut_so_far = (k - 1) * stepdown
      part.start_depth = (params.start_depth or 0) + cut_so_far
      part.depth       = math.min(stepdown, depth - cut_so_far)

      -- A tab is measured up from the bottom of the cut it belongs to, so
      -- only the pass that reaches full depth may leave one.
      if k < count then part.tabs = false end

      if params.toolpath_name ~= nil then
         part.toolpath_name = string.format("%s [%d of %d]",
                                            params.toolpath_name, k, count)
      end

      parts[k] = part
   end

   return parts
end

--- The distinct tools a whole plan needs, sorted for stable display.
function Runner.required_tools(plan)
   local seen, out = {}, {}
   for i = 1, #plan do
      if not plan[i].skipped then
         for _, reference in ipairs(tool_numbers_of(plan[i].params)) do
            local key = tostring(reference)
            if not seen[key] then
               seen[key] = true
               out[#out + 1] = reference
            end
         end
      end
   end
   -- Mixed ids and names, so compare as text.
   table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
   return out
end

---------------------------------------------------------------------------
-- plan
---------------------------------------------------------------------------

--- Walk every layer in the job and build the list of toolpaths to create.
--
-- @param job    VectricJob
-- @param config table from config.lua
-- @param ctx    table from Tooling.context
-- @param log    Log
-- @return array of { params = ..., layer = ..., warnings = {...} }
function Runner.plan(job, config, ctx, log)
   local plan = {}
   local layer_manager = job.LayerManager

   local scanned, matched = 0, 0

   -- Machining sequence follows this list, so it is settled before anything
   -- is parsed rather than being whatever order the manager felt like.
   for _, layer in ipairs(ordered_layers(layer_manager, config)) do

      if not layer.IsSystemLayer and not layer.IsBitmapLayer then
         scanned = scanned + 1

         local name = layer.Name
         local params = Parser.parse(name, config, log)

         if params ~= nil then
            matched = matched + 1
            local entry = { params = params, layer = layer, warnings = {} }

            local function reject(reason)
               entry.skipped = true
               entry.reason  = reason
            end

            if not Factory.supports(params.operation) then
               reject(string.format("no factory registered for %q", params.operation))
               log:error(name, entry.reason)
            elseif not layer_has_geometry(layer) then
               reject("layer is empty")
               if config.gadget.empty_layer_is_error then
                  log:error(name, "layer is empty; nothing to machine")
               else
                  log:warn(name, "layer is empty; skipped")
               end
            elseif not layer.Visible then
               reject("layer is hidden")
               log:warn(name, "layer is hidden; skipped")
            else
               local problems = Tooling.validate(params, ctx)
               for _, problem in ipairs(problems) do
                  log:warn(name, problem)
                  entry.warnings[#entry.warnings + 1] = problem
               end
            end

            -- Not a reason to skip the layer, but worth saying: a name this
            -- long may not survive a DXF round trip on older toolchains.
            local limit = config.gadget.max_layer_name_length or 0
            if limit > 0 and #name > limit then
               log:warn(name, string.format(
                  "layer name is %d characters; some DXF tools truncate or "
                  .. "reject names over %d", #name, limit))
            end

            params.toolpath_name =
               format_name(config.gadget.toolpath_name, params, #plan + 1)

            plan[#plan + 1] = entry
         end
      end
   end

   log:info("", string.format(
      "scanned %d layer(s); %d matched the DSL", scanned, matched))

   return plan
end

--- Skip any layer whose tools are missing or unusable in tools.json.
--
-- Checked up front, before anything is created, so the plan the user
-- confirms is the plan that runs. Nothing is ever machined with invented
-- feeds: an unusable tool skips its layer and is named in the report.
--
-- @param tools ToolRepository
-- @return number of layers skipped
function Runner.check_tools(plan, tools, log)
   local skipped = 0

   for i = 1, #plan do
      local entry = plan[i]
      if not entry.skipped then
         local problems = {}

         for _, reference in ipairs(tool_numbers_of(entry.params)) do
            local record, err = tools:find(reference)

            if record == nil then
               problems[#problems + 1] = err
            else
               local faults = Tools.validate(record)
               if #faults > 0 then
                  problems[#problems + 1] = string.format(
                     "%s: %s", Tools.describe(record), table.concat(faults, "; "))
               end
            end
         end

         if #problems > 0 then
            entry.skipped = true
            entry.reason  = problems[1]
            skipped = skipped + 1
            log:error(entry.params.layer_name,
                      "no toolpath created - " .. table.concat(problems, "; "))
         end
      end
   end

   return skipped
end

--- Count the toolpaths already in the job that share each planned name.
--
-- Disclosure only: this deletes nothing and decides nothing. It sets
-- `entry.existing` so the confirmation dialog can say what is already there
-- before the user commits.
--
-- Worth knowing what the count spans: the Lua toolpath list is JOB-wide,
-- while VCarve's Toolpaths pane shows only the active sheet. In a nested job
-- the same layer names exist on every sheet, so a non-zero count here usually
-- means "another sheet already has a toolpath by this name", not "you have
-- run this before on this sheet". Neither the gadget nor the API can tell
-- those two apart, which is precisely why the decision is the user's.
--
-- @return total number of pre-existing toolpaths matching planned names
function Runner.survey_existing(plan, manager)
   manager = manager or ToolpathManager()

   local counts = {}
   local pos = manager:GetHeadPosition()
   while pos ~= nil do
      local toolpath
      toolpath, pos = manager:GetNext(pos)
      if toolpath ~= nil and toolpath.Name ~= nil then
         -- The passes of a split layer count under the layer's own name.
         local name = base_name(toolpath.Name)
         counts[name] = (counts[name] or 0) + 1
      end
   end

   local total = 0
   for i = 1, #plan do
      local entry = plan[i]
      entry.existing = 0
      if not entry.skipped then
         entry.existing = counts[entry.params.toolpath_name] or 0
         total = total + entry.existing
      end
   end

   return total
end

--- Resolve the tools a plan entry uses, for display in the plan table.
--
-- Also records how many toolpaths each layer will become (`entry.parts`), so
-- the dialog can say what a split_passes layer is about to create.
--
-- @param in_mm whether the job is in millimetres
function Runner.annotate_tools(plan, tools, in_mm)
   for i = 1, #plan do
      local entry = plan[i]
      local record = tools:find(entry.params.tool)
      entry.tool_label = record and Tools.describe(record) or nil
      entry.parts = #pass_parts(entry.params, tools, in_mm)
   end
   return plan
end

---------------------------------------------------------------------------
-- execute
---------------------------------------------------------------------------

--- Delete toolpaths carrying this name, on the active sheet only.
--
-- Only ever called when the user has explicitly asked to replace.
--
-- The toolpath list is JOB-WIDE while a toolpath's name is just the layer name
-- it came from, and nesting puts the same layer names on every sheet. Matching
-- on name alone therefore reaches across sheets - that is the bug that deleted
-- sheet 1's work when the gadget was run on sheet 2.
--
-- So when sheet information is available (ctx.sheets, and a sheet that reports
-- its name) a candidate is only removed if it belongs to the sheet being
-- machined. A toolpath that will not say which sheet it is on is left alone:
-- the whole point is to stop deleting things whose ownership is unproven.
--
-- Without sheets - an unsheeted job - every toolpath is by definition on the
-- only sheet there is, and matching by name is exact again.
--
-- The passes of a split_passes layer ("name [1 of 2]") belong to the layer's
-- name too, so replacing a layer clears them whether or not this run splits it.
local function delete_existing(manager, name, sheets, sheet_name)
   local function named(toolpath)
      return toolpath ~= nil and base_name(toolpath.Name) == name
   end

   local function mine(toolpath)
      if sheets == nil or sheet_name == nil then return true end
      return sheets:sheet_of(toolpath) == sheet_name
   end

   local removed = 0

   -- Re-scan from the head after each delete: the list is mutated underneath
   -- us, so holding a POSITION across a delete is not safe.
   local again = true
   while again do
      again = false
      local pos = manager:GetHeadPosition()
      while pos ~= nil do
         local toolpath
         toolpath, pos = manager:GetNext(pos)
         if named(toolpath) and mine(toolpath) then
            manager:DeleteToolpath(toolpath)
            removed = removed + 1
            again = true
            break
         end
      end
   end

   -- What is left under this name belongs to other sheets. Counted in ONE pass
   -- once the deleting has finished - counting inside the loop above would
   -- tally the same survivors again on every re-scan. Reported rather than
   -- silent: leaving a same-named toolpath in place looks like a bug unless
   -- the report says it was deliberate.
   local spared = 0
   local pos = manager:GetHeadPosition()
   while pos ~= nil do
      local toolpath
      toolpath, pos = manager:GetNext(pos)
      if named(toolpath) then spared = spared + 1 end
   end

   return removed, spared
end

---------------------------------------------------------------------------
-- recalculation
---------------------------------------------------------------------------

--[[
| Why a toolpath is recalculated the moment it is created.
|
| CreateProfilingToolpath and its siblings return a toolpath that CARRIES the
| parameters handed to them but has not been through the calculation stage
| VCarve's own Calculate button runs. The visible symptom is the profile
| option `keep_start_points=false`: the toolpath form shows "Optimize Start
| Points" selected - the parameter did arrive - yet the toolpath still starts
| at each vector's own start point. Select those toolpaths in VCarve, press
| Calculate, and the start points move. Nothing about the parameters changed
| in between; only the calculation stage ran.
|
| ToolpathManager:RecalculateToolpath IS that button. From the V12 Lua API
| reference:
|
|    RecalculateToolpath(toolpath) -> bool
|       "Recalculates passed toolpath. Returns true if toolpath recalculated
|        ok. The passed toolpath is invalid after this call as a new toolpath
|        with the same id is created internally."
|
| Two things follow from that last sentence, and both shape the code below:
|
|   * the toolpath OBJECT cannot be held across the call. The ID can - so the
|     object is always looked up fresh, never cached.
|   * RecalculateAllToolpaths() is not the per-toolpath route, because it
|     destroys and rebuilds every toolpath in the job including finished work
|     on other sheets this run never touched. It is kept as a LAST RESORT only
|     (Runner.recalculate_all), for when the per-toolpath route cannot run at
|     all.
|
| Finding the toolpath again: two routes, and the second is not decoration.
|
|   Find(id) -> GetAt(pos) is the documented route, and it is tried first.
|   On VCarve Pro 12.5 it DOES NOT WORK: `Find` takes `UUID const&` and the id
|   creation hands back is a different bound type, exactly as
|   tools/Sheet_Diagnostics found for DeleteToolpathWithId. The first version
|   of this fix used the id alone, and the result was a run that reported
|   success and changed nothing - the start points stayed unoptimised until the
|   user pressed Calculate, which is the bug it was meant to fix.
|
|   The fallback therefore uses what is definitely comparable: the NAME. The
|   toolpath just created carries the name just used, and creation appends to
|   the list, so the LAST toolpath of that name is the new one. That is exact
|   in a nested job too - the earlier same-named toolpaths belong to sheets
|   already machined, and they come first.
|
| Guarded end to end. If neither route reaches the toolpath, the run reports
| it rather than quietly producing toolpaths whose settings never took.
]]

--- The Toolpath object behind an id, if VCarve will accept the id at all.
local function toolpath_by_id(manager, id)
   if id == nil then return nil, "creation returned no toolpath id" end

   local found, pos = pcall(function() return manager:Find(id) end)
   if not found then
      return nil, "Find rejected the id (" .. tostring(pos) .. ")"
   end
   if pos == nil then
      return nil, "Find matched no toolpath"
   end

   local got, toolpath = pcall(function() return manager:GetAt(pos) end)
   if not got or toolpath == nil then
      return nil, "GetAt failed (" .. tostring(toolpath) .. ")"
   end

   return toolpath
end

--- The LAST toolpath in the list carrying this name - the one just created.
local function toolpath_by_name(manager, name)
   local match = nil

   local ok, err = pcall(function()
      local pos = manager:GetHeadPosition()
      while pos ~= nil do
         local toolpath
         toolpath, pos = manager:GetNext(pos)
         if toolpath ~= nil and toolpath.Name == name then match = toolpath end
      end
   end)

   if not ok then
      return nil, "walking the toolpath list failed (" .. tostring(err) .. ")"
   end
   if match == nil then
      return nil, string.format("no toolpath named %q is in the job", name)
   end

   return match
end

--- Run the calculation stage on one just-created toolpath.
-- @return true | false, reason
local function recalculate(manager, id, name)
   local toolpath, why = toolpath_by_id(manager, id)

   if toolpath == nil then
      local fallback, why2 = toolpath_by_name(manager, name)
      if fallback == nil then
         return false, string.format("could not find the new toolpath: %s; %s",
                                     why, why2)
      end
      toolpath = fallback
   end

   local ok, result = pcall(function()
      return manager:RecalculateToolpath(toolpath)
   end)

   if not ok then
      return false, "ToolpathManager:RecalculateToolpath is unusable ("
                    .. tostring(result) .. ")"
   end
   if result == false then
      return false, "VCarve declined to recalculate the toolpath"
   end

   return true
end

--- Last resort: VCarve's own Toolpaths > Recalculate All Toolpaths.
--
-- Only reached when the per-toolpath route could not run at all. It rebuilds
-- EVERY toolpath in the job, so it is announced in the report rather than done
-- quietly, and config.gadget.recalculate_all can switch it off for a job that
-- holds hand-built toolpaths this gadget must not touch.
--
-- @return true | false, reason
function Runner.recalculate_all(manager)
   manager = manager or ToolpathManager()

   local ok, result = pcall(function()
      return manager:RecalculateAllToolpaths()
   end)

   if not ok then
      return false, "ToolpathManager:RecalculateAllToolpaths is unusable ("
                    .. tostring(result) .. ")"
   end
   if result == nil or result == false then
      return false, "VCarve declined to recalculate the toolpaths"
   end

   return true
end

--- Create the toolpaths described by the plan.
--
-- Adding to the job is the whole job here: nothing existing is touched unless
-- the run was explicitly asked to replace (ctx.replace_existing, set from the
-- dialog; config.gadget.replace_existing is only the default). The gadget is
-- run once on a fresh project and the G-code is posted straight out, so there
-- is nothing to reconcile - and guessing wrong about that costs the user
-- finished toolpaths on another sheet.
--
-- @return number created, number failed
function Runner.execute(plan, config, ctx, log)
   local manager = ToolpathManager()
   local created, failed = 0, 0

   local replace = ctx.replace_existing
   if replace == nil then replace = config.gadget.replace_existing end

   -- On unless config.lua turns it off: without it every profile toolpath
   -- keeps the vectors' start points no matter what keep_start_points says.
   local recalculating = config.gadget.recalculate ~= false
   local recalculated  = 0

   for i = 1, #plan do
      local entry  = plan[i]
      local params = entry.params

      if entry.skipped then
         -- already reported during planning
      else
         local label = params.layer_name

         if replace then
            local removed, spared = delete_existing(
               manager, params.toolpath_name, ctx.sheets, ctx.sheet_name)

            if removed > 0 then
               log:warn(label, string.format(
                  "deleted %d existing toolpath(s) named %q%s",
                  removed, params.toolpath_name,
                  ctx.sheet_name and (" on sheet " .. ctx.sheet_name) or ""))
            end
            if spared > 0 then
               log:info(label, string.format(
                  "left %d toolpath(s) named %q belonging to other sheets alone",
                  spared, params.toolpath_name))
            end
         elseif (entry.existing or 0) > 0 then
            -- Left in place deliberately. Say so, because two toolpaths with
            -- one name are confusing enough to be worth a line in the report.
            log:warn(label, string.format(
               "%d toolpath(s) named %q already exist and were left alone; "
               .. "the new one is in addition to them",
               entry.existing, params.toolpath_name))
         end

         -- One toolpath, or one per pass for a split_passes layer. Built in
         -- cutting order, shallowest first, so they are machined in it too.
         for _, part in ipairs(pass_parts(params, ctx.tools, ctx.in_mm)) do
            local id, err, warnings = Factory.build(part, ctx)

            for _, warning in ipairs(warnings or {}) do
               log:warn(label, warning)
            end

            if id == nil then
               failed = failed + 1
               log:error(label, err or "toolpath creation failed")
            else
               created = created + 1
               log:info(label, string.format(
                  "created %q (%s, tool %s, depth %.3g)%s",
                  part.toolpath_name, part.operation,
                  tostring(part.tool), part.depth or 0,
                  ctx.sheet_name and (" on sheet " .. ctx.sheet_name) or ""))

               --[[
               | Immediately, and on this sheet. Recalculation is done here
               | rather than in one sweep at the end because in a nested job
               | the run walks the sheets, and a toolpath is calculated against
               | the ACTIVE sheet - recalculating it later, with a different
               | sheet active, is not the same operation.
               ]]
               if recalculating then
                  local done, why = recalculate(manager, id, part.toolpath_name)
                  if done then
                     recalculated = recalculated + 1
                     ctx.recalculated = (ctx.recalculated or 0) + 1
                  elseif not ctx.recalculation_warned then
                     -- Once per run. The cause is the same for every toolpath,
                     -- so a line each would bury the rest of the report.
                     ctx.recalculation_warned = true
                     log:warn(label, string.format(
                        "could not run the calculation stage on the new toolpaths "
                        .. "(%s); settings that only take effect on calculation - "
                        .. "keep_start_points above all - will not be applied "
                        .. "until you select the toolpaths in VCarve and press "
                        .. "Calculate", why))
                  end
               end
            end
         end
      end
   end

   if recalculating and created > 0 then
      log:info("", string.format("recalculated %d of %d new toolpath(s)%s",
                                 recalculated, created,
                                 ctx.sheet_name and (" on sheet " .. ctx.sheet_name) or ""))
   end

   return created, failed
end

--- Create the toolpaths for every sheet in the job, in one run.
--
-- Toolpath creation follows the active sheet and cuts only that sheet's
-- vectors - both measured, not assumed (tools/Sheet_Diagnostics). So one pass
-- per sheet, over the SAME plan, produces the correct per-sheet toolpaths: the
-- plan describes what to machine, the active sheet decides which copies of it
-- get machined.
--
-- Two things make this safe rather than merely possible:
--
--   * a sheet is only machined once VCarve confirms it is the active one. An
--     unverified switch would put a sheet's toolpaths on the wrong sheet,
--     which is worse than not creating them.
--   * layers with no geometry on the sheet in hand are skipped. The layer
--     manager is job-wide, so a layer can look populated while holding nothing
--     for this sheet, and building from no vectors just fails confusingly.
--
-- The active sheet is always put back, whatever happens in between.
--
-- @param sheets handle from lib/sheets.lua, or nil for an unsheeted job
-- @return number created, number failed
function Runner.execute_sheets(plan, config, ctx, log, sheets)
   if sheets == nil or sheets.count <= 1 then
      return Runner.execute(plan, config, ctx, log)
   end

   local created, failed = 0, 0

   for _, sheet in ipairs(sheets:list()) do
      local switched, why = sheets:activate(sheet)

      if not switched then
         -- Not fatal for the rest of the job: the other sheets are still worth
         -- doing, and the report names the one that was missed.
         failed = failed + 1
         log:error("", string.format(
            "sheet %q was skipped entirely: %s", sheet.name, why or "unknown"))
      else
         ctx.sheet_name = sheet.name

         local todo = {}
         for i = 1, #plan do
            local entry = plan[i]
            if not entry.skipped then
               local objects = sheets:objects_on(entry.layer, sheet.name)
               if objects > 0 then
                  todo[#todo + 1] = entry
               else
                  log:info(entry.params.layer_name, string.format(
                     "nothing on sheet %q; skipped there", sheet.name))
               end
            end
         end

         log:info("", string.format("sheet %q: %d toolpath(s) to create",
                                    sheet.name, #todo))

         local made, lost = Runner.execute(todo, config, ctx, log)
         created = created + made
         failed  = failed + lost
      end
   end

   ctx.sheet_name = nil

   local restored, why = sheets:restore()
   if not restored then
      log:warn("", why or "could not restore the active sheet")
   end

   return created, failed
end

---------------------------------------------------------------------------
-- reporting
---------------------------------------------------------------------------

--- HTML table of the planned toolpaths, for the confirmation dialog.
function Runner.plan_to_html(plan)
   if #plan == 0 then
      return "<p class='empty'>No layers in this job use the "
          .. "<code>Operation|key=value</code> naming convention.</p>"
   end

   local rows = {}
   local function esc(s)
      return tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
   end

   for i = 1, #plan do
      local entry  = plan[i]
      local params = entry.params

      local detail
      if entry.skipped then
         detail = "<span class='skip'>skipped &mdash; " .. esc(entry.reason) .. "</span>"
      else
         local bits = {
            string.format("T%s", tostring(params.tool or "?")),
            string.format("depth %.3g", params.depth or 0),
         }
         if (params.start_depth or 0) > 0 then
            bits[#bits + 1] = string.format("start %.3g", params.start_depth)
         end
         if params.side then bits[#bits + 1] = params.side end
         if params.tabs then bits[#bits + 1] = "tabs" end
         if (entry.parts or 1) > 1 then
            bits[#bits + 1] = string.format("split into %d passes", entry.parts)
         end
         if (params.flat_depth or 0) > 0 then
            bits[#bits + 1] = string.format("flat %.3g", params.flat_depth)
         end
         if (params.peck or 0) ~= 0 and params.peck ~= false then
            bits[#bits + 1] = string.format("peck %.3g", params.peck)
         end
         if (params.allowance or 0) ~= 0 then
            bits[#bits + 1] = string.format("allow %.3g", params.allowance)
         end
         detail = esc(table.concat(bits, ", "))
      end

      local unknown = ""
      if #(params.unknown_parameters or {}) > 0 then
         unknown = " <span class='warn'>(ignored: "
                 .. esc(table.concat(params.unknown_parameters, ", ")) .. ")</span>"
      end

      if (entry.existing or 0) > 0 then
         unknown = unknown .. string.format(
            " <span class='exists'>(%d already named this)</span>", entry.existing)
      end

      rows[#rows + 1] = string.format(
         "<tr class='%s'><td class='op'>%s</td><td class='layer'>%s%s</td>"
         .. "<td class='detail'>%s</td></tr>",
         entry.skipped and "is-skipped" or "",
         esc(params.operation), esc(params.layer_name), unknown, detail)
   end

   return "<table class='plan'><thead><tr><th>Operation</th><th>Layer</th>"
       .. "<th>Settings</th></tr></thead><tbody>"
       .. table.concat(rows) .. "</tbody></table>"
end

--- Plain-text version of the plan, used for the fallback dialog and the
--- optional report file.
function Runner.plan_to_text(plan)
   if #plan == 0 then
      return "No layers use the Operation|key=value naming convention."
   end
   local lines = {}
   for i = 1, #plan do
      local entry, params = plan[i], plan[i].params
      if entry.skipped then
         lines[#lines + 1] = string.format(
            "  [skip] %s  (%s)", params.layer_name, entry.reason)
      else
         lines[#lines + 1] = string.format(
            "  %-8s %s\r\n           %s",
            params.operation, params.layer_name, Parser.describe(params))
         if (entry.existing or 0) > 0 then
            lines[#lines + 1] = string.format(
               "           (%d toolpath(s) in this job already carry this name)",
               entry.existing)
         end
      end
   end
   return table.concat(lines, "\r\n")
end

return Runner

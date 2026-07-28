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

   local pos = layer_manager:GetHeadPosition()
   while pos ~= nil do
      local layer
      layer, pos = layer_manager:GetNext(pos)

      if layer ~= nil and not layer.IsSystemLayer and not layer.IsBitmapLayer then
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

--- Resolve the tools a plan entry uses, for display in the plan table.
function Runner.annotate_tools(plan, tools)
   for i = 1, #plan do
      local entry = plan[i]
      local record = tools:find(entry.params.tool)
      entry.tool_label = record and Tools.describe(record) or nil
   end
   return plan
end

---------------------------------------------------------------------------
-- execute
---------------------------------------------------------------------------

--- Remove an existing toolpath of the same name, so re-running the gadget
--- refreshes toolpaths instead of stacking duplicates.
local function delete_existing(manager, name)
   if not manager:ToolpathWithNameExists(name) then return 0 end

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
         if toolpath ~= nil and toolpath.Name == name then
            manager:DeleteToolpath(toolpath)
            removed = removed + 1
            again = true
            break
         end
      end
   end
   return removed
end

--- Create the toolpaths described by the plan.
--
-- @return number created, number failed
function Runner.execute(plan, config, ctx, log)
   local manager = ToolpathManager()
   local created, failed = 0, 0

   for i = 1, #plan do
      local entry  = plan[i]
      local params = entry.params

      if entry.skipped then
         -- already reported during planning
      else
         local label = params.layer_name

         if config.gadget.replace_existing then
            local removed = delete_existing(manager, params.toolpath_name)
            if removed > 0 then
               log:info(label, string.format(
                  "replaced %d existing toolpath(s) named %q",
                  removed, params.toolpath_name))
            end
         end

         local id, err, warnings = Factory.build(params, ctx)

         for _, warning in ipairs(warnings or {}) do
            log:warn(label, warning)
         end

         if id == nil then
            failed = failed + 1
            log:error(label, err or "toolpath creation failed")
         else
            created = created + 1
            log:info(label, string.format(
               "created %q (%s, tool %s, depth %.3g)",
               params.toolpath_name, params.operation,
               tostring(params.tool), params.depth or 0))
         end
      end
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
      end
   end
   return table.concat(lines, "\r\n")
end

return Runner

-- VECTRIC LUA SCRIPT
--[[--------------------------------------------------------------------------
| Recalc_Diagnostics.lua - Why is "Optimize Start Points" not applied?
|
| A throwaway probe, not part of the gadget.
|
| The problem
| -----------
| The gadget sets ProfileParameterData.KeepStartPoints = false. The toolpath
| appears, its form correctly reads "Optimize Start Points" - so the parameter
| arrived - and the cut still starts at each vector's own start point. Select
| the toolpath in VCarve, press Calculate, and the start points move.
|
| Two explanations fit that, and they need opposite fixes:
|
|   A. CREATION SKIPS THE CALCULATION STAGE.
|      CreateProfilingToolpath stores the parameter but does not act on it.
|      ToolpathManager:RecalculateToolpath would then fix it, and the gadget
|      only has to reach the toolpath object to call it.
|
|   B. KeepStartPoints IS NOT WHAT THE CALCULATION READS.
|      The 12.5 UI offers THREE start-point modes (keep / optimise / closest
|      on bounding box) and the Lua binding exposes ONE boolean. If the
|      calculation reads a tri-state the binding does not write, then
|      recalculating changes nothing, and pressing Calculate in the UI only
|      works because the FORM re-derives the mode when it opens. No amount of
|      recalculation from script would help, and the gadget cannot fix this.
|
| Guessing between them is what this file exists to stop.
|
| ANSWERED (VCarve Pro 12.5, measured 2026-07-30)
| -----------------------------------------------
| Explanation A. Once the gadget could actually REACH the new toolpath and
| call RecalculateToolpath on it, the start points came out optimised straight
| after the run, with no manual Calculate. The first attempt at the fix looked
| up the toolpath by the id creation returned, which this build would not
| accept; looking it up by NAME instead is what made it work. See the two-route
| lookup in LayerDSL_Toolpaths/lib/runner.lua.
|
| So this probe is a record and a regression check, not an open question. Run
| it again if a future VCarve build stops applying the setting.
|
| What it measures
| ----------------
|  1. Which of Find, GetAt, RecalculateToolpath, RecalculateAllToolpaths this
|     build actually exposes, and whether Find ACCEPTS the id creation returns.
|     (Sheet_Diagnostics already found that DeleteToolpathWithId, same
|     `UUID const&` parameter, refuses that id - so this is a real question.)
|
|  2. Two identical profile toolpaths on one layer, differing ONLY in
|     KeepStartPoints, and their FirstPoint compared.
|
|         different  -> creation DOES honour the flag; the problem is elsewhere
|         identical  -> creation ignores it at calculation time
|
|  3. FirstPoint of the KeepStartPoints=false toolpath before and after
|     RecalculateToolpath.
|
|         moved      -> explanation A. Recalculation is the fix.
|         unmoved    -> explanation B, or recalculation never really ran -
|                       and step 1 says which.
|
|  4. The same again through RecalculateAllToolpaths, in case the per-toolpath
|     call is the weaker of the two.
|
| What this does to your job
| --------------------------
| Creates toolpaths named ZZ_RECALC_PROBE_* on whichever visible layer holds
| the most vectors, and DELETES them all again by object. It tries an outside
| profile over closed vectors first and an on-the-line profile over everything
| second, so a layer of OPEN vectors is measurable too rather than simply
| refusing to calculate.
| Removes any leftover from an earlier run first. No vector is modified and no
| toolpath of yours is touched - except in step 4, which recalculates every
| toolpath in the job because that is the only thing that call can do. That
| step is skipped unless you set g_try_recalculate_all = true below.
|
| Prefer a scratch copy of the job if you would rather not have toolpaths
| created and deleted in a live project.
|
| Files
| -----
| Recalc_Diagnostics.htm must sit beside this file. Without it the report
| still appears, in a plain message box with no way to copy it.
----------------------------------------------------------------------------]]

require "strict"

g_version = "1.1"
g_title   = "Recalculate Diagnostics"

g_probe_prefix = "ZZ_RECALC_PROBE"

-- Step 4 rebuilds EVERY toolpath in the job. Off unless you ask for it.
g_try_recalculate_all = false

---------------------------------------------------------------------------
-- helpers that cannot raise
---------------------------------------------------------------------------

function Tidy(text)
   local flat = tostring(text):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
   if #flat > 300 then flat = flat:sub(1, 300) .. " [...]" end
   return flat
end

--- Read a binding that may be a property OR a method, without assuming which.
-- The lesson Sheet_Diagnostics learned twice: reading the wrong form throws.
function Probe(holder, name)
   local as_property_ok, value = pcall(function() return holder[name] end)
   if as_property_ok and value ~= nil and type(value) ~= "function" then
      return true, value
   end
   local as_method_ok, result = pcall(function() return holder[name](holder) end)
   if as_method_ok and result ~= nil then return true, result end
   return false, nil
end

function Value(holder, name)
   local ok, value = Probe(holder, name)
   if not ok then return nil end
   return value
end

--- A point as text, to whatever precision it will give up.
--
-- FirstPoint is the measurement this whole probe turns on, so it is read
-- defensively: x/y/z as fields, then as methods, then tostring.
function PointText(point)
   if point == nil then return "unreadable" end

   local parts = {}
   for _, axis in ipairs{ "x", "y", "z" } do
      local ok, value = pcall(function() return point[axis] end)
      if not ok or type(value) ~= "number" then
         ok, value = pcall(function() return point[axis:upper()] end)
      end
      if ok and type(value) == "number" then
         parts[#parts + 1] = string.format("%s=%.4f", axis, value)
      end
   end

   if #parts == 0 then
      local ok, text = pcall(tostring, point)
      return ok and Tidy(text) or "unreadable"
   end
   return table.concat(parts, " ")
end

--- Everything about a toolpath that could show the start point moved.
--
-- FirstPoint is the direct answer. MachiningTime and the statistics are the
-- corroboration: optimising start points changes the link-up moves, so the
-- cutting time moves with it. If FirstPoint will not read on this build, the
-- time still answers the question.
function Fingerprint(toolpath)
   if toolpath == nil then return "no toolpath" end

   local parts = {}
   parts[#parts + 1] = "FirstPoint(" .. PointText(Value(toolpath, "FirstPoint")) .. ")"
   parts[#parts + 1] = "LastPoint("  .. PointText(Value(toolpath, "LastPoint"))  .. ")"

   local time = Value(toolpath, "MachiningTime")
   if type(time) == "number" then
      parts[#parts + 1] = string.format("MachiningTime=%.3f", time)
   end

   local stats = Value(toolpath, "Statistics")
   if stats ~= nil then
      for _, field in ipairs{ "FeedLength", "RapidLength", "PlungeLength" } do
         local v = Value(stats, field)
         if type(v) == "number" then
            parts[#parts + 1] = string.format("%s=%.3f", field, v)
         end
      end
   end

   return table.concat(parts, "  ")
end

---------------------------------------------------------------------------
-- toolpath list
---------------------------------------------------------------------------

function AllToolpaths()
   local manager, found = ToolpathManager(), {}
   pcall(function()
      local pos = manager:GetHeadPosition()
      while pos ~= nil do
         local toolpath
         toolpath, pos = manager:GetNext(pos)
         if toolpath ~= nil then found[#found + 1] = toolpath end
      end
   end)
   return manager, found
end

--- The LAST toolpath carrying this name. Creation appends, so that is the
--- one just made - the same rule the gadget itself now relies on.
function ToolpathNamed(name)
   local _, all = AllToolpaths()
   local match = nil
   for _, toolpath in ipairs(all) do
      local ok, actual = pcall(function() return toolpath.Name end)
      if ok and actual == name then match = toolpath end
   end
   return match
end

function DeleteByPrefix(prefix)
   local removed = 0
   local again = true

   while again do
      again = false
      local manager, all = AllToolpaths()
      for _, toolpath in ipairs(all) do
         local ok, name = pcall(function() return toolpath.Name end)
         if ok and type(name) == "string" and name:sub(1, #prefix) == prefix then
            if pcall(function() return manager:DeleteToolpath(toolpath) end) then
               removed = removed + 1
               again = true
            end
            break
         end
      end
   end

   return removed
end

---------------------------------------------------------------------------
-- the probe toolpath
---------------------------------------------------------------------------

--- The first visible layer holding vectors, and how many it holds.
function ChooseProbeLayer(job)
   local best, count = nil, 0

   pcall(function()
      local manager = job.LayerManager
      local pos = manager:GetHeadPosition()
      while pos ~= nil do
         local layer
         layer, pos = manager:GetNext(pos)
         if layer ~= nil and not layer.IsSystemLayer and not layer.IsBitmapLayer
            and layer.Visible and layer:GetHeadPosition() ~= nil
         then
            local n, p = 0, layer:GetHeadPosition()
            while p ~= nil do
               local object
               object, p = layer:GetNext(p)
               n = n + 1
            end
            -- More vectors means more scope for the optimiser to reorder, so
            -- the busiest layer is the one that shows a difference.
            if n > count then best, count = layer.Name, n end
         end
      end
   end)

   return best, count
end

function ProbeTool()
   local tool = Tool("Recalc probe", Tool.END_MILL)
   tool.InMM          = true
   tool.ToolDia       = 6.0
   tool.Stepdown      = 3.0
   tool.Stepover      = 3.0
   tool.ClearStepover = 3.0
   tool.RateUnits     = Tool.MM_MIN
   tool.FeedRate      = 1000.0
   tool.PlungeRate    = 300.0
   tool.SpindleSpeed  = 12000.0
   tool.ToolNumber    = 1
   return tool
end

--[[
| The two shapes a probe toolpath can take, tried in this order.
|
| v1.0 only had the first and could not run on the layer it chose - 467 OPEN
| vectors on a `side=on` layer. An outside profile needs a closed loop to
| offset from, and the selector was asking for closed vectors only, so it
| selected nothing and VCarve refused to calculate. Same trap the gadget's own
| profile.lua works around.
|
| So: closed-and-outside first, because that is the ordinary case, then
| on-the-line over everything, which is what open geometry can actually be cut
| with. Whichever calculates is the one the measurement uses - the comparison
| only requires that BOTH probes are built the same way, not that they are
| built any particular way.
]]
g_probe_shapes = {
   { label = "outside, closed vectors", side = "outside", open = false },
   { label = "on the line, all vectors", side = "on", open = true },
}

--- One profile toolpath, identical to its sibling but for keep_start_points.
function CreateProbe(layer_name, probe_name, keep_start_points, shape)
   local tool = ProbeTool()

   local profile = ProfileParameterData()
   profile.StartDepth          = 0.0
   profile.CutDepth            = 1.0
   profile.ProfileSide         = (shape.side == "on")
                                 and ProfileParameterData.PROFILE_ON
                                 or  ProfileParameterData.PROFILE_OUTSIDE
   profile.CutDirection        = ProfileParameterData.CLIMB_DIRECTION
   profile.Allowance           = 0.0
   profile.UseTabs             = false
   profile.ProjectToolpath     = false
   profile.KeepStartPoints     = keep_start_points
   profile.CreateSquareCorners = false
   profile.CornerSharpen       = false

   local ramping = RampingData()
   ramping.DoRamping = false

   local leads = LeadInOutData()
   leads.DoLeadIn  = false
   leads.DoLeadOut = false

   local material = MaterialBlock()
   local pos = ToolpathPosData()
   pos:SetHomePosition(material.MaterialBox.BLC.x, material.MaterialBox.BLC.y,
                       material.MaterialBox.TRC.z + 10.0)
   pos.SafeZGap  = 5.0
   pos.StartZGap = 2.0
   pos:EnsureHomeZIsSafe()

   local selector = GeometrySelector()
   selector.GeometryFilterUsed = true
   selector.OnlyOnLayers       = true
   selector:AddLayerName(layer_name)
   selector.MixedGroupsOk      = true
   selector.SelectClosed       = true
   selector.SelectOpen         = shape.open
   selector.AllowOpen          = shape.open
   selector.ToolDia            = tool.ToolDia
   selector:ApplySelector()

   local ok, id = pcall(function()
      return ToolpathManager():CreateProfilingToolpath(
         probe_name, tool, profile, ramping, leads, pos, selector, false, false)
   end)

   if not ok then return nil, Tidy(id) end
   if id == nil then return nil, "VCarve could not calculate the toolpath" end
   return id
end

---------------------------------------------------------------------------
-- step 1: what does this build expose, and does Find accept the id?
---------------------------------------------------------------------------

function ReportBindings(lines, id)
   local manager = ToolpathManager()

   lines[#lines + 1] = ""
   lines[#lines + 1] = "=== 1. the recalculation bindings ==="

   for _, name in ipairs{ "Find", "GetAt", "RecalculateToolpath",
                          "RecalculateAllToolpaths", "GetSelectedToolpath" } do
      local ok, value = pcall(function() return manager[name] end)
      lines[#lines + 1] = string.format("  %-24s %s", name,
         (ok and value ~= nil) and "present" or "MISSING")
   end

   lines[#lines + 1] = ""
   lines[#lines + 1] = string.format("  id creation returned     %s (%s)",
                                     Tidy(tostring(id)), type(id))

   -- The question Sheet_Diagnostics raised: DeleteToolpathWithId wants
   -- `UUID const&` and refuses this id. Find has the same parameter type.
   local found, pos = pcall(function() return manager:Find(id) end)
   if not found then
      lines[#lines + 1] = "  Find(id)                 REJECTED THE ID"
      lines[#lines + 1] = "                           " .. Tidy(pos)
      lines[#lines + 1] = "  -> an id-only lookup cannot reach the new toolpath on"
      lines[#lines + 1] = "     this build; the gadget must find it by NAME."
      return false
   end
   if pos == nil then
      lines[#lines + 1] = "  Find(id)                 accepted, but matched nothing"
      return false
   end

   lines[#lines + 1] = "  Find(id)                 accepted, returned a POSITION"

   local got, toolpath = pcall(function() return manager:GetAt(pos) end)
   lines[#lines + 1] = string.format("  GetAt(pos)               %s",
      (got and toolpath ~= nil) and "returned a Toolpath" or "FAILED")

   return got and toolpath ~= nil
end

---------------------------------------------------------------------------
-- step 2: does creation honour KeepStartPoints at all?
---------------------------------------------------------------------------

function CompareCreation(lines, layer_name)
   lines[#lines + 1] = ""
   lines[#lines + 1] = "=== 2. does CREATION honour KeepStartPoints? ==="
   lines[#lines + 1] = "  Two toolpaths on the same layer, identical but for the flag."

   local kept_name = g_probe_prefix .. "_KEEP"
   local opt_name  = g_probe_prefix .. "_OPT"

   --[[
   | Both probes must be built the same way for the comparison to mean
   | anything, so a shape only counts if BOTH of them calculate. A shape that
   | half-works is torn down before the next is tried, or the leftover would
   | be picked up later as "the last toolpath of that name".
   ]]
   local kept_id, opt_id, used = nil, nil, nil

   for _, shape in ipairs(g_probe_shapes) do
      local k, k_err = CreateProbe(layer_name, kept_name, true, shape)
      local o, o_err = CreateProbe(layer_name, opt_name, false, shape)

      if k ~= nil and o ~= nil then
         kept_id, opt_id, used = k, o, shape
         break
      end

      lines[#lines + 1] = string.format("  %-26s could not be calculated on this layer",
                                        shape.label)
      lines[#lines + 1] = "    KeepStartPoints=true   " .. tostring(k_err or "ok")
      lines[#lines + 1] = "    KeepStartPoints=false  " .. tostring(o_err or "ok")
      DeleteByPrefix(g_probe_prefix)
   end

   if opt_id == nil then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "  No probe toolpath would calculate on this layer, so nothing"
      lines[#lines + 1] = "  could be measured. Try a layer holding closed vectors."
      return nil, nil, opt_name
   end

   lines[#lines + 1] = "  probe shape   " .. used.label

   local kept = Fingerprint(ToolpathNamed(kept_name))
   local opt  = Fingerprint(ToolpathNamed(opt_name))

   lines[#lines + 1] = ""
   lines[#lines + 1] = "  KeepStartPoints=true   " .. kept
   lines[#lines + 1] = "  KeepStartPoints=false  " .. opt
   lines[#lines + 1] = ""

   if kept == "no toolpath" or opt == "no toolpath" then
      lines[#lines + 1] = "  INCONCLUSIVE - a probe toolpath could not be read back."
      return nil, opt_id, opt_name
   end

   if kept ~= opt then
      lines[#lines + 1] = "  VERDICT: DIFFERENT. Creation DOES act on KeepStartPoints,"
      lines[#lines + 1] = "  so the start points you are seeing are not explained by"
      lines[#lines + 1] = "  a skipped calculation stage. Look elsewhere: check the"
      lines[#lines + 1] = "  value the gadget actually passed for this layer."
      return true, opt_id, opt_name
   end

   lines[#lines + 1] = "  VERDICT: IDENTICAL. Creation produces the same toolpath"
   lines[#lines + 1] = "  either way, so the flag is stored but not acted on at"
   lines[#lines + 1] = "  creation. Step 3 says whether recalculating fixes that."
   return false, opt_id, opt_name
end

---------------------------------------------------------------------------
-- step 3: does recalculating apply it?
---------------------------------------------------------------------------

function TryRecalculate(lines, opt_id, opt_name)
   lines[#lines + 1] = ""
   lines[#lines + 1] = "=== 3. does RecalculateToolpath apply it? ==="

   local before = Fingerprint(ToolpathNamed(opt_name))
   lines[#lines + 1] = "  before  " .. before

   local manager = ToolpathManager()

   -- By name, not by id: step 1 may have shown the id is not usable here, and
   -- the name is what the gadget itself falls back to.
   local toolpath = ToolpathNamed(opt_name)
   if toolpath == nil then
      lines[#lines + 1] = "  Could not find the probe toolpath to recalculate."
      return
   end

   local ok, result = pcall(function()
      return manager:RecalculateToolpath(toolpath)
   end)

   if not ok then
      lines[#lines + 1] = "  RecalculateToolpath RAISED: " .. Tidy(result)
      lines[#lines + 1] = "  -> this build cannot recalculate a toolpath from script."
      return
   end

   lines[#lines + 1] = "  RecalculateToolpath returned " .. tostring(result)

   -- The object handed in is invalid now ("a new toolpath with the same id is
   -- created internally"), so the toolpath is looked up again from scratch.
   local after = Fingerprint(ToolpathNamed(opt_name))
   lines[#lines + 1] = "  after   " .. after
   lines[#lines + 1] = ""

   if after == "no toolpath" then
      lines[#lines + 1] = "  INCONCLUSIVE - the toolpath could not be read back."
   elseif before ~= after then
      lines[#lines + 1] = "  VERDICT: THE TOOLPATH CHANGED. Recalculation applies"
      lines[#lines + 1] = "  the setting, and the gadget calling it is the fix."
   else
      lines[#lines + 1] = "  VERDICT: UNCHANGED. Recalculating from script does not"
      lines[#lines + 1] = "  apply the setting, even though pressing Calculate in"
      lines[#lines + 1] = "  VCarve does. The calculation is not reading what the"
      lines[#lines + 1] = "  KeepStartPoints binding writes - explanation B, and"
      lines[#lines + 1] = "  nothing the gadget can do from Lua will fix it."
   end
end

---------------------------------------------------------------------------
-- step 4: the whole-job call, if asked for
---------------------------------------------------------------------------

function TryRecalculateAll(lines, opt_name)
   lines[#lines + 1] = ""
   lines[#lines + 1] = "=== 4. RecalculateAllToolpaths ==="

   if not g_try_recalculate_all then
      lines[#lines + 1] = "  Skipped. It rebuilds every toolpath in the job, so it"
      lines[#lines + 1] = "  only runs if you set g_try_recalculate_all = true at"
      lines[#lines + 1] = "  the top of this file."
      return
   end

   local before = Fingerprint(ToolpathNamed(opt_name))
   lines[#lines + 1] = "  before  " .. before

   local ok, result = pcall(function()
      return ToolpathManager():RecalculateAllToolpaths()
   end)

   if not ok then
      lines[#lines + 1] = "  RecalculateAllToolpaths RAISED: " .. Tidy(result)
      return
   end

   lines[#lines + 1] = "  returned " .. Tidy(tostring(result))

   local after = Fingerprint(ToolpathNamed(opt_name))
   lines[#lines + 1] = "  after   " .. after
   lines[#lines + 1] = ""
   lines[#lines + 1] = (before ~= after)
      and "  VERDICT: CHANGED - the whole-job call does what the per-toolpath one did not."
      or  "  VERDICT: UNCHANGED."
end

---------------------------------------------------------------------------
-- report
---------------------------------------------------------------------------

function Escape(text)
   return (tostring(text)
      :gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

function ShowReport(script_path, text)
   local shown = pcall(function()
      local html_path = "file:" .. script_path .. "\\Recalc_Diagnostics.htm"
      local dialog = HTML_Dialog(false, html_path, 940, 700, g_title)

      dialog:AddLabelField("GadgetVersion", g_version)
      pcall(function()
         dialog:SetInnerHtml("ReportText", "<pre>" .. Escape(text) .. "</pre>")
      end)
      pcall(function() dialog:AddLabelField("ReportLabel", text) end)

      dialog:ShowDialog()
   end)

   if not shown then DisplayMessageBox(text) end
   return shown
end

---------------------------------------------------------------------------
-- main
---------------------------------------------------------------------------

function main(script_path)
   local lines = {}

   lines[#lines + 1] = g_title .. " v" .. g_version
   lines[#lines + 1] = "Lua: " .. tostring(_VERSION)
   lines[#lines + 1] = ""

   local job = VectricJob()
   if not job.Exists then
      DisplayMessageBox("Open a job with some closed vectors before running this.")
      return false
   end

   local leftover = DeleteByPrefix(g_probe_prefix)
   if leftover > 0 then
      lines[#lines + 1] = string.format(
         "Removed %d leftover probe toolpath(s) from an earlier run.", leftover)
   end

   local layer_name, vectors = ChooseProbeLayer(job)
   if layer_name == nil then
      DisplayMessageBox("No visible layer in this job holds any vectors.")
      return false
   end

   lines[#lines + 1] = string.format("probe layer   %q (%d object(s))",
                                     layer_name, vectors)
   if vectors < 2 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "WARNING: start point optimisation reorders and re-enters"
      lines[#lines + 1] = "vectors, so a layer with one vector may show no difference"
      lines[#lines + 1] = "even when it is working. Run this on a layer with several."
   end

   ------------------------------------------------------------------
   -- Everything is wrapped: a probe that dies half way must still
   -- clean up after itself and still show what it managed to learn.
   ------------------------------------------------------------------
   local ok, err = pcall(function()
      local _, opt_id, opt_name = CompareCreation(lines, layer_name)

      if opt_id ~= nil then
         ReportBindings(lines, opt_id)
         TryRecalculate(lines, opt_id, opt_name)
         TryRecalculateAll(lines, opt_name)
      end
   end)

   if not ok then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "The probe stopped early: " .. Tidy(err)
   end

   local removed = DeleteByPrefix(g_probe_prefix)
   lines[#lines + 1] = ""
   lines[#lines + 1] = string.format("Cleaned up %d probe toolpath(s).", removed)

   pcall(function() job:Refresh2DView() end)

   ShowReport(script_path, table.concat(lines, "\r\n"))
   return true
end

-- VECTRIC LUA SCRIPT
--[[--------------------------------------------------------------------------
| Sheet_Diagnostics.lua - Can this VCarve drive SHEETS from Lua?
|
| A throwaway probe, not part of the gadget.
|
| Established (12.5, measured on a two-sheet nested job)
| -----------------------------------------------------
|    ActiveSheetId          UUID, WRITABLE; assigning another sheet's id works
|    GetSheetIds()          a Lua iterator over sheet UUIDs
|    GetSheetName(uuid)     names a sheet
|    LayerManager           JOB-WIDE: one layer holds objects from both sheets
|                           (profile..18.2 = Sheet 1:6 + Sheet 2:8)
|    toolpath list          JOB-WIDE: both sheet-1 toolpaths enumerate while
|                           sheet 2 is active - the deletion bug's root cause
|    Toolpath.SheetId       names the sheet the toolpath belongs to
|    creation FOLLOWS the active sheet: switched to Sheet 1, created a
|                           toolpath, and it landed on Sheet 1
|
| Also measured, and settled
| --------------------------
|    creation follows ActiveSheetId in BOTH directions - Sheet 1 -> Sheet 1,
|    Sheet 2 -> Sheet 2. A single-pass, all-sheets gadget is possible.
|
| Two id types, easily confused
| -----------------------------
| The luaUUID class registers AsString, IsEqual, CreateNew, SetId - but that
| is the type CREATION RETURNS, and it prints as 4f3b6806-22e8-...
|
| The id behind ActiveSheetId and GetSheetIds is a different bound type: it
| answers to neither AsString nor IsEqual, and has no __eq, so two reads of the
| same sheet id do not compare equal by any means available. SHEET NAMES ARE
| THE KEY. An implementation must match sheets by GetSheetName, never by id.
|
| Also: DeleteToolpathWithId wants `UUID const&` and will not take the luaUUID
| that creation returns, so deletion goes through the toolpath OBJECT - which
| is what the gadget itself does.
|
| NAMING: answered, by v1.6
| -------------------------
| Two toolpaths were created on two sheets under one name, and BOTH were still
| listed under that name afterwards. VCarve accepts a duplicate name across
| sheets and does not rename. Single-pass can keep toolpath names equal to
| layer names.
|
| v1.6 printed the opposite verdict, because it worked out which toolpath was
| new by asking which NAME it had not seen before - which cannot work once two
| toolpaths share a name. The second sheet's row came back "not found" and two
| verdicts fired on that sentinel rather than on data. Fixed twice over here:
| each probe toolpath now gets its own name, and a verdict that cannot be
| supported says INCONCLUSIVE instead of asserting failure.
|
| The one question left
| ---------------------
| SCOPING. The layer manager is job-wide and GeometrySelector filters by LAYER
| NAME only, so when a toolpath is created for a layer holding vectors from
| both sheets, does it cut only the active sheet's vectors or all of them?
|
| v1.5 could not tell: it read toolpath.Statistics as a property and got
| "unreadable" every time. Read through Probe now, which tries the method form
| too, with MachiningTime as a second opinion. v1.6 got one reading
| (FeedLength=22521.1 on Sheet 1) but lost the other to the naming bug, so
| there is still nothing to compare it against.
|
| Different figures per sheet = creation is properly scoped. Identical figures
| = every toolpath cut every sheet's vectors, which would be a correctness
| problem in the gadget as it stands today.
|
| What this does to your job
| --------------------------
| Creates one toolpath per sheet, named ZZ_SHEET_PROBE_1, ZZ_SHEET_PROBE_2 and
| so on, reads its statistics, and deletes them all again by object. Switches
| the active sheet and restores it. Removes any leftover from an earlier run.
|
| Nothing else is touched: no toolpath of yours is modified or removed, and no
| vector changes. Prefer a scratch copy if you would rather not have a
| toolpath created and deleted in a live project.
|
| Files
| -----
| Sheet_Diagnostics.htm must sit beside this file. It renders the report and
| carries the Copy Report button; without it the report still appears, in a
| plain message box with no way to copy.
----------------------------------------------------------------------------]]

require "strict"

g_version = "1.7"
g_title   = "Sheet Diagnostics"

g_probe_prefix        = "ZZ_SHEET_PROBE"
g_max_sheets          = 64

---------------------------------------------------------------------------
-- helpers that cannot raise
---------------------------------------------------------------------------

function Tidy(text)
   local flat = tostring(text):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
   if #flat > 400 then flat = flat:sub(1, 400) .. " [...]" end
   return flat
end

--- A UUID as text, via the AsString the luaUUID class registers.
function IdText(id)
   if id == nil then return "nil" end
   local ok, text = pcall(function() return id:AsString() end)
   if ok and type(text) == "string" and text ~= "" then return text end
   local plain_ok, plain = pcall(tostring, id)
   if plain_ok and type(plain) == "string" and plain:gsub("%s+", "") ~= "" then
      return plain
   end
   return string.format("<%s, opaque>", type(id))
end

function Show(value)
   if value == nil then return "nil" end
   local kind = type(value)
   if kind == "string" then return string.format("%q", value) end
   if kind == "number" or kind == "boolean" then return tostring(value) end
   return IdText(value)
end

--- Compare two ids, reporting HOW they were compared.
-- @return equal (boolean or nil), how
function IdEqual(a, b)
   if a == nil or b == nil then return nil, "nil" end

   local ok, equal = pcall(function() return a:IsEqual(b) end)
   if ok and type(equal) == "boolean" then return equal, "IsEqual" end

   local raw_ok, raw_equal = pcall(function() return a == b end)
   if raw_ok then return raw_equal, "==" end

   return nil, "neither"
end

function Probe(holder, name)
   local as_property_ok, value = pcall(function() return holder[name] end)
   if as_property_ok and value ~= nil and type(value) ~= "function" then
      return true, value, "property"
   end
   local as_method_ok, result = pcall(function() return holder[name](holder) end)
   if as_method_ok and result ~= nil then return true, result, "method" end
   if as_property_ok and value ~= nil then return true, value, "property (uncalled)" end
   return false, (as_property_ok and result or value), nil
end

function Value(holder, name)
   local ok, value = Probe(holder, name)
   if not ok then return nil end
   return value
end

function SheetNameOf(sheets, id)
   if id == nil then return nil end
   local ok, name = pcall(function() return sheets:GetSheetName(id) end)
   if ok and type(name) == "string" then return name end
   return nil
end

function CollectSheetIds(sheets)
   local ids, raw = {}, nil
   if not pcall(function() raw = sheets:GetSheetIds() end) then return ids end

   if type(raw) == "table" then
      pcall(function() for _, id in ipairs(raw) do ids[#ids + 1] = id end end)
   elseif type(raw) == "function" then
      pcall(function()
         for id in raw do
            ids[#ids + 1] = id
            if #ids >= g_max_sheets then break end
         end
      end)
   end
   return ids
end

---------------------------------------------------------------------------
-- toolpath list helpers
---------------------------------------------------------------------------

--- Every toolpath currently in the job.
function AllToolpaths()
   local found = {}
   local manager = ToolpathManager()
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

--- Every toolpath whose name starts with `prefix`, with the name read out.
--
-- Prefix, not equality: if VCarve renames a duplicate to "NAME (1)" then
-- matching on equality would miss the very thing worth seeing.
function ToolpathsNamed(prefix)
   local _, found = AllToolpaths()
   local matches = {}

   for _, toolpath in ipairs(found) do
      local name = nil
      pcall(function() name = tostring(toolpath.Name) end)
      if name ~= nil and name:sub(1, #prefix) == prefix then
         matches[#matches + 1] = { toolpath = toolpath, name = name }
      end
   end

   return matches
end

--- Delete every toolpath whose name starts with `prefix`, by OBJECT.
function DeleteByPrefix(prefix)
   local removed, failures = 0, {}

   local again = true
   while again do
      again = false
      local manager = ToolpathManager()
      local matches = ToolpathsNamed(prefix)

      if #matches > 0 then
         local ok, err = pcall(function()
            return manager:DeleteToolpath(matches[1].toolpath)
         end)
         if ok then
            removed = removed + 1
            again = true
         else
            failures[#failures + 1] = Tidy(err)
         end
      end
   end

   return removed, failures
end


--- The statistics that say what a toolpath actually cut.
--
-- v1.5 read toolpath.Statistics directly and got "unreadable" every time. The
-- lesson already learned twice in this build applies here too: a binding may
-- be a property OR a method, and reading the wrong form throws. Everything
-- below goes through Probe, which tries both.
--
-- MachiningTime sits on the Toolpath itself, beside Statistics, and answers
-- the same question on its own - so it is captured as a second opinion in
-- case the ToolpathStats object stays out of reach.
function StatsText(toolpath)
   local parts, feed = {}, nil

   local machining = Value(toolpath, "MachiningTime")
   if type(machining) == "number" then
      parts[#parts + 1] = string.format("MachiningTime=%.2f", machining)
      feed = machining
   end

   local stats = Value(toolpath, "Statistics")
   if stats == nil then
      parts[#parts + 1] = "Statistics=unavailable"
   else
      for _, key in ipairs{ "IsValid", "FeedLength", "PlungeLength",
                            "RapidLength", "MinimumZ" } do
         local value = Value(stats, key)
         if value == nil then
            parts[#parts + 1] = key .. "=?"
         elseif type(value) == "number" then
            -- FeedLength is the cleanest measure of "how much was cut", so it
            -- wins over MachiningTime as the comparison key when present.
            if key == "FeedLength" then feed = value end
            parts[#parts + 1] = string.format("%s=%.1f", key, value)
         else
            parts[#parts + 1] = string.format("%s=%s", key, tostring(value))
         end
      end
   end

   if #parts == 0 then return "nothing readable", nil end
   return table.concat(parts, " "), feed
end

---------------------------------------------------------------------------
-- choosing a probe layer
---------------------------------------------------------------------------

--- The smallest layer that holds objects on more than one sheet.
--
-- Smallest so the two probe toolpaths calculate quickly; spanning sheets
-- because a layer confined to one sheet cannot show whether creation is
-- scoped.
function ChooseProbeLayer(job, sheets)
   local best, best_total, best_split = nil, nil, nil

   pcall(function()
      local manager = job.LayerManager
      local pos = manager:GetHeadPosition()

      while pos ~= nil do
         local layer
         layer, pos = manager:GetNext(pos)

         if layer ~= nil and not layer.IsSystemLayer and layer.Visible then
            local per_sheet, order, total = {}, {}, 0

            local p = layer:GetHeadPosition()
            while p ~= nil do
               local object
               object, p = layer:GetNext(p)
               total = total + 1
               if object ~= nil then
                  local ok, id = pcall(function() return object.SheetId end)
                  local name = ok and SheetNameOf(sheets, id) or nil
                  if name ~= nil then
                     if per_sheet[name] == nil then
                        per_sheet[name] = 0
                        order[#order + 1] = name
                     end
                     per_sheet[name] = per_sheet[name] + 1
                  end
               end
            end

            if #order > 1 and (best_total == nil or total < best_total) then
               local parts = {}
               for _, name in ipairs(order) do
                  parts[#parts + 1] = string.format("%s=%d", name, per_sheet[name])
               end
               best, best_total, best_split = layer.Name, total, table.concat(parts, " ")
            end
         end
      end
   end)

   return best, best_total, best_split
end

---------------------------------------------------------------------------
-- creating a throwaway toolpath
---------------------------------------------------------------------------

function ProbeTool()
   local tool = Tool("Sheet probe", Tool.END_MILL)
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

function CreateProbeToolpath(layer_name, probe_name)
   local tool = ProbeTool()

   local profile = ProfileParameterData()
   profile.StartDepth      = 0.0
   profile.CutDepth        = 1.0
   profile.ProfileSide     = ProfileParameterData.PROFILE_OUTSIDE
   profile.CutDirection    = ProfileParameterData.CLIMB_DIRECTION
   profile.Allowance       = 0.0
   profile.UseTabs         = false
   profile.ProjectToolpath = false

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
   selector.SelectOpen         = true
   selector.AllowOpen          = true
   selector.ToolDia            = tool.ToolDia
   selector:ApplySelector()

   return ToolpathManager():CreateProfilingToolpath(
      probe_name, tool, profile, ramping, leads, pos, selector,
      false, false)
end

---------------------------------------------------------------------------
-- the measurement: one toolpath per sheet, compared
---------------------------------------------------------------------------

function MeasurePerSheet(job, sheets, lines)
   lines[#lines + 1] = ""
   lines[#lines + 1] = "=== is creation scoped to the active sheet? ==="

   local original = Value(sheets, "ActiveSheetId")
   local ids      = CollectSheetIds(sheets)

   local layer_name, layer_total, layer_split = ChooseProbeLayer(job, sheets)
   if layer_name == nil then
      lines[#lines + 1] = "  No layer holds objects on more than one sheet, so this"
      lines[#lines + 1] = "  cannot be measured."
      return
   end

   lines[#lines + 1] = string.format("  probe layer        %q", layer_name)
   lines[#lines + 1] = string.format("  its objects        %d total  (%s)",
                                     layer_total, layer_split)
   lines[#lines + 1] = ""

   local results = {}

   --[[
   | Each probe toolpath gets its OWN name, one per sheet.
   |
   | v1.6 gave them all the same name and then tried to work out which one was
   | new by asking which name it had not seen before. That cannot work once
   | VCarve accepts two toolpaths with one name - which is exactly what it does
   | - so the second sheet's row came back "not found" and two verdicts fired
   | on a sentinel value instead of on data. Identification and the naming
   | question have to be separate things.
   |
   | The naming question is already answered, by that same run: both toolpaths
   | were created as ZZ_SHEET_PROBE_DELETE_ME and BOTH were still listed under
   | that name afterwards. VCarve accepts a duplicate name across sheets and
   | does not rename. So single-pass can keep toolpath names equal to layer
   | names, and this version needs only to measure scoping.
   ]]
   for index, id in ipairs(ids) do
      local sheet_name = SheetNameOf(sheets, id) or "?"
      local probe_name = string.format("%s_%d", g_probe_prefix, index)

      local switched = pcall(function() sheets.ActiveSheetId = id end)
      local now      = SheetNameOf(sheets, Value(sheets, "ActiveSheetId"))

      if not switched or now ~= sheet_name then
         lines[#lines + 1] = string.format("  %-10s switch failed (now %s)",
                                           sheet_name, tostring(now))
      else
         local created = nil
         local ran, err = pcall(function()
            created = CreateProbeToolpath(layer_name, probe_name)
         end)

         if created == nil then
            lines[#lines + 1] = string.format("  %-10s creation failed: %s",
               sheet_name, ran and "no id returned" or Tidy(err))
         else
            -- Unambiguous: this name belongs to this creation alone.
            local fresh = nil
            for _, match in ipairs(ToolpathsNamed(g_probe_prefix)) do
               if match.name == probe_name then fresh = match end
            end

            local landed, stats, feed = nil, "unreadable", nil

            if fresh ~= nil then
               local ok, sheet_id = pcall(function() return fresh.toolpath.SheetId end)
               if ok then landed = SheetNameOf(sheets, sheet_id) end
               stats, feed = StatsText(fresh.toolpath)
            end

            lines[#lines + 1] = string.format("  created while %q active:", sheet_name)
            lines[#lines + 1] = string.format("     named           %q", probe_name)
            lines[#lines + 1] = string.format("     found again     %s",
                                              fresh ~= nil and "yes" or "NO")
            lines[#lines + 1] = string.format("     landed on       %s",
               landed and string.format("%q", landed) or "unknown")
            lines[#lines + 1] = string.format("     %s", stats)

            results[#results + 1] = {
               sheet = sheet_name, landed = landed, feed = feed, name = probe_name,
            }
         end
      end
   end

   local removed, failures = DeleteByPrefix(g_probe_prefix)
   lines[#lines + 1] = string.format("  cleaned up         %d removed%s", removed,
      #failures > 0 and (", FAILED " .. failures[1]) or "")

   ------------------------------------------------------------------
   -- Restore, then interpret.
   ------------------------------------------------------------------
   pcall(function() sheets.ActiveSheetId = original end)
   lines[#lines + 1] = string.format("  sheet restored     %q",
      SheetNameOf(sheets, Value(sheets, "ActiveSheetId")) or "?")

   lines[#lines + 1] = ""

   --[[
   | Three outcomes, not two. v1.6 collapsed "could not tell" into "failed" and
   | announced that single-pass was unsafe on the strength of a placeholder
   | string. Missing data is now its own answer.
   ]]
   local known, correct = 0, 0
   for _, r in ipairs(results) do
      if r.landed ~= nil then
         known = known + 1
         if r.landed == r.sheet then correct = correct + 1 end
      end
   end

   if known < #results then
      lines[#lines + 1] = string.format(
         "  -> INCONCLUSIVE on landing: %d of %d toolpath(s) could not be read"
         .. " back.", #results - known, #results)
   elseif known > 1 and correct == known then
      lines[#lines + 1] = "  -> every toolpath landed on the sheet that was active when"
      lines[#lines + 1] = "     it was created, in BOTH directions. Creation follows"
      lines[#lines + 1] = "     ActiveSheetId; that is confirmed, not a coincidence."
   elseif known > 1 then
      lines[#lines + 1] = "  -> a toolpath did NOT land on the sheet active at creation."
      lines[#lines + 1] = "     Single-pass is not safe."
   end

   if #results > 1 and results[1].feed ~= nil and results[2].feed ~= nil then
      local a, b = results[1].feed, results[2].feed
      local difference = math.abs(a - b)
      local scale = math.max(math.abs(a), math.abs(b), 1)

      lines[#lines + 1] = ""
      lines[#lines + 1] = string.format("  FeedLength %s=%.1f  %s=%.1f",
         results[1].sheet, a, results[2].sheet, b)

      if difference / scale < 0.001 then
         lines[#lines + 1] = "  -> IDENTICAL. Both toolpaths cut the same geometry, so"
         lines[#lines + 1] = "     creation is NOT scoped to the active sheet: each cut"
         lines[#lines + 1] = "     every sheet's vectors on that layer. That would be a"
         lines[#lines + 1] = "     correctness problem in the gadget as it stands."
      else
         lines[#lines + 1] = "  -> DIFFERENT, so each toolpath cut only its own sheet's"
         lines[#lines + 1] = "     vectors. Creation is properly sheet-scoped: single-pass"
         lines[#lines + 1] = "     would produce correct per-sheet toolpaths."
      end
   end
end

---------------------------------------------------------------------------
-- UUID capabilities, corrected
---------------------------------------------------------------------------

function TestIdComparison(sheets, lines)
   lines[#lines + 1] = ""
   lines[#lines + 1] = "=== comparing and printing sheet ids ==="

   local first  = Value(sheets, "ActiveSheetId")
   local second = Value(sheets, "ActiveSheetId")

   lines[#lines + 1] = "  AsString           " .. IdText(first)

   local equal, how = IdEqual(first, second)
   lines[#lines + 1] = string.format(
      "  two reads equal    %s  (via %s)", tostring(equal), how)

   local ids = CollectSheetIds(sheets)
   for _, id in ipairs(ids) do
      local same, method = IdEqual(id, first)
      lines[#lines + 1] = string.format("  %-10s equals active: %-5s (%s)  %s",
         SheetNameOf(sheets, id) or "?", tostring(same), method, IdText(id))
   end

   if equal == true then
      lines[#lines + 1] = "  -> ids ARE comparable: a real implementation can match"
      lines[#lines + 1] = "     sheets by id and need not rely on sheet names."
   else
      lines[#lines + 1] = "  -> ids still do not compare equal; names remain the key."
   end
end

---------------------------------------------------------------------------
-- showing the report
---------------------------------------------------------------------------

--- Escape text for injection into the dialog.
--
-- The report is full of angle brackets ("<userdata, opaque>", "->"), which
-- would be eaten as tags. Ampersand first, or the escapes escape each other.
function Escape(text)
   return (tostring(text)
      :gsub("&", "&amp;")
      :gsub("<", "&lt;")
      :gsub(">", "&gt;"))
end

--- Show the report in the HTML dialog, which has a Copy Report button.
--
-- The report is sent by TWO independent routes, because the first attempt at
-- this used SetInnerHtml on a <pre> and a <textarea> and this VCarve silently
-- ignored both - the dialog opened still showing its placeholder:
--
--   SetInnerHtml  <pre> markup into an EMPTY <div>, which is the exact shape
--                 of the one call known to work in this host (the main
--                 gadget's plan table). Escaped, so it is byte-exact.
--   AddLabelField the same text as a plain label, as the safety net.
--
-- Whichever the host honours, the report is readable and copyable; the dialog
-- names the route that supplied it. Each call is separately pcall'd so that one
-- of them failing cannot stop the dialog from opening.
--
-- Vectric's Lua API has no text clipboard binding - CopyToClipboard is for
-- vectors - and this build rejects io.open write modes, so neither Lua nor a
-- temp file can do the copying. The dialog's browser control is the only route,
-- and the .htm tries three clipboard APIs in turn.
--
-- Falls back to the plain message box if the dialog cannot be built: a report
-- without a Copy button still beats no report.
function ShowReport(script_path, text)
   local shown = pcall(function()
      local html_path = "file:" .. script_path .. "\\Sheet_Diagnostics.htm"
      local dialog = HTML_Dialog(false, html_path, 940, 700, g_title)

      dialog:AddLabelField("GadgetVersion", g_version)

      -- Route 1: markup into an empty div.
      pcall(function()
         dialog:SetInnerHtml("ReportText", "<pre>" .. Escape(text) .. "</pre>")
      end)

      -- Route 2: plain text as a label. NOT escaped - a label field is set as
      -- text, so escaping it here would show literal &lt; to the user.
      pcall(function()
         dialog:AddLabelField("ReportLabel", text)
      end)

      dialog:ShowDialog()
   end)

   if not shown then
      DisplayMessageBox(text)
   end

   return shown
end

---------------------------------------------------------------------------
-- main
---------------------------------------------------------------------------

function main(script_path)
   local lines = {}

   lines[#lines + 1] = g_title .. " v" .. g_version
   lines[#lines + 1] = "Lua: " .. tostring(_VERSION)

   local job = VectricJob()
   if not job.Exists then
      DisplayMessageBox("Open a nested job (two or more sheets) before running this.")
      return false
   end

   local sheets = Value(job, "SheetManager")
   if sheets == nil then
      DisplayMessageBox("job.SheetManager is unavailable - no sheet API at all.")
      return false
   end

   ------------------------------------------------------------------
   -- Tidy up after v1.4 first, whatever else happens below.
   ------------------------------------------------------------------
   lines[#lines + 1] = ""
   lines[#lines + 1] = "=== leftover from the previous run ==="
   local removed, failures = DeleteByPrefix(g_probe_prefix)
   if removed > 0 then
      lines[#lines + 1] = string.format(
         "  removed %d toolpath(s) named %s*", removed, g_probe_prefix)
   elseif #failures > 0 then
      lines[#lines + 1] = "  FAILED to remove it: " .. failures[1]
      lines[#lines + 1] = "  Delete " .. g_probe_prefix .. "* by hand."
   else
      lines[#lines + 1] = "  none found (already gone)"
   end

   lines[#lines + 1] = ""
   lines[#lines + 1] = "=== sheets ==="
   lines[#lines + 1] = string.format("  NumberOfSheets     %s",
      Show(Value(sheets, "NumberOfSheets")))
   lines[#lines + 1] = string.format("  active             %q",
      SheetNameOf(sheets, Value(sheets, "ActiveSheetId")) or "?")

   local ok, err = pcall(TestIdComparison, sheets, lines)
   if not ok then lines[#lines + 1] = "  id probe raised: " .. Tidy(err) end

   ok, err = pcall(MeasurePerSheet, job, sheets, lines)
   if not ok then lines[#lines + 1] = "  measurement raised: " .. Tidy(err) end

   ShowReport(script_path, table.concat(lines, "\r\n"))
   return true
end

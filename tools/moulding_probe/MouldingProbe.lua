-- VECTRIC LUA SCRIPT
--[[--------------------------------------------------------------------------
| MouldingProbe.lua - Inspect saved VCarve Moulding toolpaths.
|
| Run this with a VCarve job open that already contains a manually-created
| Moulding Toolpath. It does not create or edit toolpaths. It only lists what
| VCarve exposes to Lua, so we can design Layer DSL Moulding support from a
| real saved reference instead of guessing.
----------------------------------------------------------------------------]]

require "strict"

local REPORT_NAME = "moulding_probe_report.txt"

local function append_line(lines, text)
   lines[#lines + 1] = tostring(text or "")
end

local function safe_call(label, fn)
   local ok, value = pcall(fn)
   if ok then return tostring(value) end
   return "<error: " .. tostring(value) .. ">"
end

local function get_string(tp, key)
   return safe_call(key, function() return tp:GetString(key, "<missing>") end)
end

local function get_bool(name)
   return safe_call(name, function() return _G[name] ~= nil end)
end

local function toolpath_kind(tp)
   local editing = get_string(tp, "EditingDialog")
   if editing == "uiExtrudedToolpathForm" then return "Moulding" end
   if editing == "uiProfileMachineForm" then return "Profile" end
   if editing == "uiPocketMachineForm" then return "Pocket" end
   if editing == "uiDrillForm" then return "Drill" end
   if editing == "uiVCarvingForm" or editing == "VCarveFlatToolpathDialog" then
      return "VCarve"
   end
   return editing
end

local function visit_toolpath_nodes(node, callback, level)
   node.processchildren = true
   if level > 0 then callback(node, level) end

   if node:HasChildren() and node.processchildren then
      local num_children = node:GetNumberOfChildren()
      for i = 0, (num_children - 1) do
         visit_toolpath_nodes(node:GetChild(i), callback, level + 1)
      end
   end
end

local function describe_toolpath(node, lines, index)
   append_line(lines, "")
   append_line(lines, string.format("[%d] Node: %s", index, node:GetName()))

   local tp = node:GetToolpath()
   if tp == nil then
      append_line(lines, "  group/no toolpath")
      return
   end

   append_line(lines, "  kind: " .. toolpath_kind(tp))
   append_line(lines, "  name: " .. tostring(tp.Name))
   append_line(lines, "  class: " .. tostring(tp.ClassName))
   append_line(lines, "  EditingDialog: " .. get_string(tp, "EditingDialog"))
   append_line(lines, "  ToolpathType: " .. get_string(tp, "ToolpathType"))
   append_line(lines, "  mcBaseToolpathName: " .. get_string(tp, "mcBaseToolpathName"))

   if tp.Tool ~= nil then
      append_line(lines, "  tool.name: " .. tostring(tp.Tool.Name))
      append_line(lines, "  tool.type: " .. tostring(tp.Tool.ToolTypeText))
      append_line(lines, "  tool.number: " .. tostring(tp.Tool.ToolNumber))
      append_line(lines, "  tool.diameter: " .. tostring(tp.Tool.ToolDia))
      append_line(lines, "  tool.stepdown: " .. tostring(tp.Tool.Stepdown))
      append_line(lines, "  tool.stepover: " .. tostring(tp.Tool.Stepover))
      append_line(lines, "  tool.feed: " .. tostring(tp.Tool.FeedRate))
      append_line(lines, "  tool.plunge: " .. tostring(tp.Tool.PlungeRate))
      append_line(lines, "  tool.spindle: " .. tostring(tp.Tool.SpindleSpeed))
   end

   local stats_ok, stats = pcall(function() return tp:Statistics() end)
   if stats_ok and stats ~= nil then
      append_line(lines, "  stats.MinimumZ: " .. tostring(stats.MinimumZ))
      append_line(lines, "  stats.MaximumZ: " .. tostring(stats.MaximumZ))
   else
      append_line(lines, "  stats: <unavailable>")
   end
end

local function write_report(script_path, lines)
   local path = script_path .. "\\" .. REPORT_NAME
   local f, err = io.open(path, "w")
   if f == nil then return nil, err end
   f:write(table.concat(lines, "\r\n"))
   f:write("\r\n")
   f:close()
   return path, nil
end

function main(script_path)
   local lines = {}

   append_line(lines, "Moulding Probe")
   append_line(lines, "================")
   append_line(lines, "Purpose: inspect existing saved toolpaths; no edits are made.")
   append_line(lines, "")
   append_line(lines, "API presence:")
   append_line(lines, "  MouldingToolpath global: " .. get_bool("MouldingToolpath"))
   append_line(lines, "  uiMouldingToolpathForm global: " .. get_bool("uiMouldingToolpathForm"))
   append_line(lines, "  ToolpathManager global: " .. get_bool("ToolpathManager"))

   local job = VectricJob()
   if not job.Exists then
      DisplayMessageBox("Open the manual Moulding .crv job before running MouldingProbe.")
      return false
   end

   local manager = ToolpathManager()
   append_line(lines, "")
   append_line(lines, "ToolpathManager.Count: " .. tostring(manager.Count))

   local active = manager:GetActiveSideNode()
   local count = 0
   visit_toolpath_nodes(active, function(node)
      count = count + 1
      describe_toolpath(node, lines, count)
   end, 0)

   local report_path, err = write_report(script_path, lines)
   if report_path == nil then
      DisplayMessageBox("MouldingProbe finished, but could not write report:\r\n\r\n" .. tostring(err))
      return false
   end

   DisplayMessageBox("MouldingProbe finished.\r\n\r\nReport written to:\r\n" .. report_path)
   return true
end

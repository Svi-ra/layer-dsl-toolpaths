--[[--------------------------------------------------------------------------
| lib/log.lua - Diagnostic collector.
|
| Nothing in this gadget writes directly to a message box. Everything routes
| through a Log so a run can be summarised once, at the end, in one dialog.
|
| Pure Lua - no VCarve API dependency.
----------------------------------------------------------------------------]]

local Log = {}
Log.__index = Log

local RANK = { info = 1, warn = 2, error = 3 }

function Log.new()
   return setmetatable({
      entries = {},
      counts  = { info = 0, warn = 0, error = 0 },
   }, Log)
end

--- Record a diagnostic.
-- @param level   "info" | "warn" | "error"
-- @param context short scope string, usually the layer name
-- @param message human readable text
function Log:add(level, context, message)
   if RANK[level] == nil then level = "info" end
   self.counts[level] = self.counts[level] + 1
   self.entries[#self.entries + 1] = {
      level   = level,
      context = context or "",
      message = message or "",
   }
end

function Log:info(context, message)  self:add("info",  context, message) end
function Log:warn(context, message)  self:add("warn",  context, message) end
function Log:error(context, message) self:add("error", context, message) end

function Log:has_errors()   return self.counts.error > 0 end
function Log:has_warnings() return self.counts.warn  > 0 end

--- Merge another log's entries into this one, preserving order.
function Log:absorb(other)
   if other == nil then return end
   for i = 1, #other.entries do
      local e = other.entries[i]
      self:add(e.level, e.context, e.message)
   end
end

--- Entries at or above a level, in insertion order.
function Log:filter(min_level)
   local floor = RANK[min_level] or 1
   local out = {}
   for i = 1, #self.entries do
      local e = self.entries[i]
      if RANK[e.level] >= floor then out[#out + 1] = e end
   end
   return out
end

local LABEL = { info = "INFO ", warn = "WARN ", error = "ERROR" }

--- Render as plain text, suitable for a message box or a .txt report.
function Log:to_text(min_level)
   local list = self:filter(min_level or "info")
   if #list == 0 then return "" end
   local buf = {}
   for i = 1, #list do
      local e = list[i]
      if e.context ~= "" then
         buf[#buf + 1] = string.format("%s  [%s] %s", LABEL[e.level], e.context, e.message)
      else
         buf[#buf + 1] = string.format("%s  %s", LABEL[e.level], e.message)
      end
   end
   return table.concat(buf, "\r\n")
end

function Log:summary()
   return string.format("%d error(s), %d warning(s)", self.counts.error, self.counts.warn)
end

return Log

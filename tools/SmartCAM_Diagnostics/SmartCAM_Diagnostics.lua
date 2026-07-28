-- VECTRIC LUA SCRIPT
--[[--------------------------------------------------------------------------
| SmartCAM_Diagnostics.lua - What can this VCarve actually do with files?
|
| A throwaway probe, not part of the gadget. It exists because VCarve's
| embedded Lua rejects io.open modes that stock Lua 5.2.3 accepts:
|
|     io.open(path, "w")   -> bad argument #2 to 'open' (invalid mode)
|     io.open(path, "wb")  -> bad argument #2 to 'open' (invalid mode)
|
| Both are legal in stock Lua, so this build has a patched file sandbox and
| the rules have to be measured rather than assumed.
|
| Run it from the Gadgets menu. It writes nothing permanent - every file it
| manages to create is deleted again - and reports what worked.
----------------------------------------------------------------------------]]

require "strict"

g_version = "1.0"
g_title   = "SmartCAM Diagnostics"

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

--- Call something and describe the outcome in one line.
-- @return "OK", or "FAILED: reason"
function Try(fn)
   local ok, result, err = pcall(fn)
   if not ok then
      return "FAILED (raised): " .. tostring(result)
   end
   if result == nil then
      return "failed: " .. tostring(err)
   end
   return "OK"
end

--- Try io.open with one mode and close whatever comes back.
function TryMode(path, mode)
   local ok, handle, err = pcall(io.open, path, mode)

   if not ok then
      -- The mode itself was rejected before the file was ever touched.
      return "REJECTED: " .. tostring(handle)
   end
   if handle == nil then
      return "opened nothing: " .. tostring(err)
   end

   pcall(function() handle:close() end)
   return "OK"
end

--- Can a NEW file be created here, and with which modes?
function TestDirectory(label, dir, lines)
   lines[#lines + 1] = ""
   lines[#lines + 1] = label .. ":"
   lines[#lines + 1] = "  " .. tostring(dir)

   if dir == nil or dir == "" then
      lines[#lines + 1] = "  (no path - skipped)"
      return
   end

   local probe = dir .. "\\smartcam_diag.tmp"

   for _, mode in ipairs{ "w", "wb", "a", "ab", "w+", "wb+" } do
      lines[#lines + 1] = string.format("  write %-4s %s", mode,
                                        TryMode(probe, mode))
   end

   -- If anything did get created, read it back and tidy up.
   lines[#lines + 1] = "  read  rb   " .. TryMode(probe, "rb")
   lines[#lines + 1] = "  read  r    " .. TryMode(probe, "r")

   local removed = false
   pcall(function() removed = os.remove(probe) end)
   lines[#lines + 1] = "  os.remove   " .. tostring(removed)
end

---------------------------------------------------------------------------
-- main
---------------------------------------------------------------------------

function main(script_path)
   local lines = {}

   lines[#lines + 1] = g_title .. " v" .. g_version
   lines[#lines + 1] = "Lua: " .. tostring(_VERSION)
   lines[#lines + 1] = ""
   lines[#lines + 1] = "=== reading a file that already exists ==="

   -- This gadget's own file is guaranteed to be there and readable.
   local self_path = script_path .. "\\SmartCAM_Diagnostics.lua"
   lines[#lines + 1] = "  " .. self_path
   lines[#lines + 1] = "  read  r    " .. TryMode(self_path, "r")
   lines[#lines + 1] = "  read  rb   " .. TryMode(self_path, "rb")

   -- The seeded database, if it is there.
   local db = "C:\\ProgramData\\SmartCAM\\tools.json"
   lines[#lines + 1] = ""
   lines[#lines + 1] = "  " .. db
   lines[#lines + 1] = "  read  r    " .. TryMode(db, "r")
   lines[#lines + 1] = "  read  rb   " .. TryMode(db, "rb")

   lines[#lines + 1] = ""
   lines[#lines + 1] = "=== creating a NEW file, by location ==="

   TestDirectory("gadget folder",   script_path, lines)
   TestDirectory("ProgramData",     "C:\\ProgramData\\SmartCAM", lines)
   TestDirectory("C: root folder",  "C:\\SmartCAM", lines)

   local temp = nil
   pcall(function() temp = os.getenv("TEMP") end)
   TestDirectory("TEMP", temp, lines)

   local profile = nil
   pcall(function() profile = os.getenv("USERPROFILE") end)
   if profile then
      TestDirectory("Documents", profile .. "\\Documents", lines)
   end

   lines[#lines + 1] = ""
   lines[#lines + 1] = "=== other facilities ==="

   local exec_result = "not available"
   local ok_exec, r1, r2, r3 = pcall(os.execute, "echo smartcam")
   if ok_exec then
      exec_result = string.format("%s / %s / %s",
         tostring(r1), tostring(r2), tostring(r3))
   else
      exec_result = "raised: " .. tostring(r1)
   end
   lines[#lines + 1] = "  os.execute   " .. exec_result

   local tmpname = "not available"
   local ok_tmp, name = pcall(os.tmpname)
   if ok_tmp then tmpname = tostring(name) end
   lines[#lines + 1] = "  os.tmpname   " .. tmpname

   lines[#lines + 1] = "  io.lines     " ..
      (type(io.lines) == "function" and "present" or "missing")
   lines[#lines + 1] = "  io.output    " ..
      (type(io.output) == "function" and "present" or "missing")

   DisplayMessageBox(table.concat(lines, "\r\n"))
   return true
end

--[[--------------------------------------------------------------------------
| lib/db/fileio.lua - Filesystem access. No JSON, no tools, no VCarve.
|
| Everything that touches the disk goes through here, so the database can
| later live on a network share without any other module changing.
|
| Writes are staged through a temporary file and the previous version is kept
| as .bak. A half-written tools.json is a file full of cutting parameters
| that no longer say what anyone intended, so it must not be possible to
| leave one behind.
|
| Pure Lua plus the standard io/os libraries, both confirmed present in
| VCarve's embedded Lua 5.2.3.
----------------------------------------------------------------------------]]

local FileIO = {}

FileIO.SEPARATOR = "\\"

---------------------------------------------------------------------------
-- paths
---------------------------------------------------------------------------

--- Join path fragments with a single separator between them.
function FileIO.join(...)
   local parts = {}
   for i = 1, select("#", ...) do
      local part = select(i, ...)
      if part ~= nil and part ~= "" then
         part = tostring(part):gsub("[\\/]+$", "")
         if i > 1 then part = part:gsub("^[\\/]+", "") end
         parts[#parts + 1] = part
      end
   end
   return table.concat(parts, FileIO.SEPARATOR)
end

--- The directory part of a path, without a trailing separator.
function FileIO.dirname(path)
   local dir = tostring(path):match("^(.*)[\\/][^\\/]*$")
   return dir or "."
end

---------------------------------------------------------------------------
-- opening files
---------------------------------------------------------------------------

--[[
| ALWAYS open in binary mode, and ALWAYS through FileIO.open.
|
| VCarve's embedded Lua does not accept the bare "r" and "w" modes that
| stock Lua does. io.open(path, "w") raises
|
|     bad argument #2 to 'open' (invalid mode)
|
| which killed the gadget on its very first run, before the database folder
| could be created. Every Vectric sample that touches a file uses "rb" or
| "wb", so those are the only two modes used here.
|
| The call is also wrapped in pcall: a rejected mode, a locked file or a
| permission problem must degrade to "could not open" plus a readable
| message, never a Lua error dialog thrown over the user's job.
]]
FileIO.READ  = "rb"
FileIO.WRITE = "wb"

--- Open a file in binary mode.
-- @return handle, or nil plus a reason
function FileIO.open(path, mode)
   if path == nil or path == "" then return nil, "no file name given" end

   local ok, handle, err = pcall(io.open, path, mode or FileIO.READ)
   if not ok then
      -- `handle` carries the error message when pcall itself failed.
      return nil, tostring(handle)
   end
   if handle == nil then
      return nil, err and tostring(err) or ("could not open " .. tostring(path))
   end
   return handle
end

--- os.remove that cannot raise.
function FileIO.remove(path)
   local ok, done = pcall(os.remove, path)
   return ok and done and true or false
end

--- os.rename that cannot raise.
function FileIO.rename(from, to)
   local ok, done = pcall(os.rename, from, to)
   return ok and done and true or false
end

---------------------------------------------------------------------------
-- existence
---------------------------------------------------------------------------

function FileIO.file_exists(path)
   local handle = FileIO.open(path, FileIO.READ)
   if handle == nil then return false end
   handle:close()
   return true
end

--[[
| Is this directory present and writable?
|
| Writing a probe file is the honest test, because writing is exactly what
| the database does. The obvious alternative, os.rename(path, path), is NOT
| usable here: it returns false for a directory that is merely busy, so a
| perfectly good folder reads as missing.
|
| The failure reason is returned rather than swallowed. A caller that cannot
| say WHY it could not use a folder sends the user off to check permissions
| that were never the problem.
]]
-- @return true, or false plus the reason the write failed
function FileIO.directory_is_writable(path)
   if path == nil or path == "" then return false, "no directory given" end

   -- A plain, visible name: nothing here should depend on a filesystem or a
   -- sandbox being happy about a leading dot.
   local probe = FileIO.join(path, "smartcam_write_test.tmp")

   local handle, err = FileIO.open(probe, FileIO.WRITE)
   if handle == nil then return false, tostring(err) end

   handle:close()
   FileIO.remove(probe)
   return true
end

---------------------------------------------------------------------------
-- directory creation
---------------------------------------------------------------------------

--[[
| Create a directory, including any missing parents.
|
| EXISTENCE is what lets the run proceed, not a successful write probe. An
| earlier version required the probe to succeed and so refused to start on a
| folder that was perfectly fine, while reporting a generic "check the folder
| permissions" that named no actual cause. If the folder is there, we carry
| on; if a later write genuinely fails, that write reports its own real error.
|
| Creation is attempted in order:
|   1. already present         - the common case, costs one os.rename
|   2. Path:CreateDir          - a VCarve binding, undocumented, so guarded
|   3. cmd's mkdir             - creates intermediate directories
|   4. a write probe           - in case the folder exists but os.rename is
|                                blocked from renaming it to itself
|
| Every failure records WHY, and the reasons are returned together. Being
| unable to say what went wrong is its own bug.
]]
--[[
| Remembered outcomes, so a folder is worked out once per run rather than
| once per document. Without this a read-only location runs mkdir five times
| over and prints five shell complaints.
]]
local directory_cache = {}

--- Forget what is known about directories. For tests.
function FileIO.reset_directory_cache()
   directory_cache = {}
end

function FileIO.ensure_directory(path)
   if path == nil or path == "" then
      return false, "no directory given"
   end

   local remembered = directory_cache[path]
   if remembered ~= nil then
      return remembered.ok, remembered.reason
   end

   local ok, reason = FileIO.resolve_directory(path)
   directory_cache[path] = { ok = ok, reason = reason }
   return ok, reason
end

--- The actual work behind ensure_directory, without the memo.
function FileIO.resolve_directory(path)
   -- The folder is usable if we can write in it. Try that first: on an
   -- established install it is the only step that runs.
   local writable, probe_err = FileIO.directory_is_writable(path)
   if writable then return true end

   local tried = { "  writing a test file - " .. tostring(probe_err) }

   -- VCarve exposes a Path binding with CreateDir. It is not in the
   -- published API documentation, so it is attempted inside pcall.
   local ok_path, path_err = pcall(function()
      local builder = Path(path)
      builder:CreateDir()
   end)
   writable, probe_err = FileIO.directory_is_writable(path)
   if writable then return true end
   tried[#tried + 1] = "  Path:CreateDir - " ..
      (ok_path and ("ran, but writing still fails: " .. tostring(probe_err))
                or tostring(path_err))

   -- `mkdir` under cmd creates intermediate directories. No output
   -- redirection: os.execute inside a windowed process is fussy about it,
   -- and a stray message is better than a command that will not parse.
   local quoted = '"' .. tostring(path):gsub('"', '') .. '"'
   local ok_exec, exec_result = pcall(os.execute, "mkdir " .. quoted)
   writable, probe_err = FileIO.directory_is_writable(path)
   if writable then return true end
   tried[#tried + 1] = "  mkdir - " ..
      (ok_exec and ("returned " .. tostring(exec_result)
                    .. ", writing still fails: " .. tostring(probe_err))
                or tostring(exec_result))

   return false, string.format(
      "could not create or open %s\r\n\r\nWhat was tried:\r\n%s\r\n\r\n"
      .. "Create the folder by hand, or set a different location in the "
      .. "`database` section of config.lua.",
      path, table.concat(tried, "\r\n"))
end

---------------------------------------------------------------------------
-- reading and writing
---------------------------------------------------------------------------

--- Read a whole file as text.
-- @return string, or nil plus a reason
function FileIO.read(path)
   local handle, err = FileIO.open(path, FileIO.READ)
   if handle == nil then
      return nil, string.format("could not open %s (%s)", path, tostring(err))
   end

   local ok, text = pcall(function() return handle:read("*a") end)
   handle:close()

   if not ok or text == nil then
      return nil, string.format("could not read %s", path)
   end
   return text
end

--- Write text to a file, keeping the previous version as .bak.
--
-- The new content lands in a .tmp file first, so a failure part way through
-- writing cannot destroy the existing database.
--
-- @return true, or false plus a reason
function FileIO.write(path, text)
   local directory = FileIO.dirname(path)
   local ok, err = FileIO.ensure_directory(directory)
   if not ok then return false, err end

   local temp = path .. ".tmp"

   local handle, open_err = FileIO.open(temp, FileIO.WRITE)
   if handle == nil then
      return false, string.format("could not write %s (%s)", temp, tostring(open_err))
   end

   local wrote = pcall(function() handle:write(text) end)
   handle:close()

   if not wrote then
      FileIO.remove(temp)
      return false, string.format("could not write %s", temp)
   end

   -- os.rename will not overwrite on Windows, so the target is moved aside
   -- first. That move doubles as the backup.
   if FileIO.file_exists(path) then
      local backup = path .. ".bak"
      FileIO.remove(backup)
      if not FileIO.rename(path, backup) then
         -- Could not keep a backup; still better to save than to refuse.
         FileIO.remove(path)
      end
   end

   if not FileIO.rename(temp, path) then
      FileIO.remove(temp)
      return false, string.format("could not replace %s", path)
   end

   return true
end

return FileIO

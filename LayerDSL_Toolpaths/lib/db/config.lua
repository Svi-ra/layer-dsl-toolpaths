--[[--------------------------------------------------------------------------
| lib/db/config.lua - Config: where the database lives.
|
| THE ONLY PLACE A STORAGE LOCATION IS DECIDED. Every module that reads or
| writes a database file asks Config for the path; none of them builds one.
| Pointing the gadget at a network share is therefore a one-line change:
|
|     Config.new("\\\\server\\cnc\\SmartCAM")
|
| and nothing else in the codebase needs to know.
|
| Pure Lua - no VCarve API. Depends only on lib/db/fileio.lua for path
| joining, so it can be tested against a temporary folder.
----------------------------------------------------------------------------]]

local Config = {}
Config.__index = Config

--- Where the database lives unless told otherwise.
Config.DEFAULT_ROOT = "C:\\ProgramData\\SmartCAM"

--- Logical name -> file name. Adding a document is one entry here.
Config.DOCUMENTS = {
   tools     = "tools.json",
   machines  = "machines.json",
   materials = "materials.json",
   presets   = "presets.json",
   settings  = "settings.json",
}

local FileIO

--- Inject the filesystem module.
function Config.init(fileio)
   FileIO = fileio
   return Config
end

---------------------------------------------------------------------------
-- construction
---------------------------------------------------------------------------

--- @param root string|nil  database folder; defaults to Config.DEFAULT_ROOT
function Config.new(root)
   local self = setmetatable({}, Config)
   self.root = Config.normalise_root(root)
   return self
end

--- Trim trailing separators and fall back to the default.
function Config.normalise_root(root)
   if root == nil or root == "" then return Config.DEFAULT_ROOT end
   root = tostring(root):gsub("[\\/]+$", "")
   if root == "" then return Config.DEFAULT_ROOT end
   return root
end

--- Build a Config from the gadget's config.lua `database` table.
--
-- Recognised keys:
--   path             string  database folder
--   use_environment  bool    let SMARTCAM_DB override `path`
--
-- The environment variable exists so a workshop can point several machines
-- at a share without editing a file on each one.
function Config.from_settings(settings)
   settings = settings or {}

   local root = settings.path

   if settings.use_environment ~= false then
      local ok, from_env = pcall(os.getenv, "SMARTCAM_DB")
      if ok and from_env ~= nil and from_env ~= "" then
         root = from_env
      end
   end

   return Config.new(root)
end

---------------------------------------------------------------------------
-- paths
---------------------------------------------------------------------------

--- The database folder.
function Config:root_path()
   return self.root
end

--- Full path of one document, by logical name.
function Config:path_for(document)
   local filename = Config.DOCUMENTS[document]
   if filename == nil then
      error(string.format("unknown database document %q", tostring(document)), 2)
   end
   return FileIO.join(self.root, filename)
end

--- Logical names of every document, sorted.
function Config.document_names()
   local names = {}
   for name in pairs(Config.DOCUMENTS) do names[#names + 1] = name end
   table.sort(names)
   return names
end

--- Every document path, keyed by logical name.
function Config:all_paths()
   local paths = {}
   for _, name in ipairs(Config.document_names()) do
      paths[name] = self:path_for(name)
   end
   return paths
end

---------------------------------------------------------------------------
-- readiness
---------------------------------------------------------------------------

--- Create the database folder if it is missing.
-- @return true, or false plus a reason
function Config:ensure_root()
   return FileIO.ensure_directory(self.root)
end

function Config:describe()
   return string.format("SmartCAM database at %s", self.root)
end

return Config

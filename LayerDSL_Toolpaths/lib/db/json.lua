--[[--------------------------------------------------------------------------
| lib/db/json.lua - JSON encoder and decoder in pure Lua.
|
| VCarve embeds Lua 5.2 with only `socket`, `mime` and `ltn12` - there is no
| JSON library to require, so the database needs its own.
|
| Design notes
| ------------
|   * Encoding is DETERMINISTIC: object keys are sorted, so the files diff
|     cleanly in version control and the tests can compare exact strings.
|   * Output is indented. These files are meant to be hand-edited.
|   * Arrays and objects are both Lua tables, so an empty one is ambiguous.
|     Decoded arrays carry a marker, and json.array() sets it explicitly, so
|     an empty tool list round-trips as [] rather than {}.
|   * JSON null decodes to json.null, not nil, so a key that is present but
|     null survives a load/save cycle instead of vanishing.
|
| Pure Lua - no VCarve API, no external dependencies.
----------------------------------------------------------------------------]]

local Json = {}

---------------------------------------------------------------------------
-- sentinels
---------------------------------------------------------------------------

--- Stands in for JSON null, which cannot be stored in a Lua table as nil.
Json.null = setmetatable({}, { __tostring = function() return "null" end })

local ARRAY_MARKER = { __json_array = true }

--- Mark a table as a JSON array, so an empty one encodes as [].
function Json.array(t)
   return setmetatable(t or {}, ARRAY_MARKER)
end

function Json.is_array(t)
   return getmetatable(t) == ARRAY_MARKER
end

---------------------------------------------------------------------------
-- encoding
---------------------------------------------------------------------------

local ESCAPES = {
   ['"']  = '\\"',
   ['\\'] = '\\\\',
   ['\b'] = '\\b',
   ['\f'] = '\\f',
   ['\n'] = '\\n',
   ['\r'] = '\\r',
   ['\t'] = '\\t',
}

local function escape_string(s)
   local out = s:gsub('[%c"\\]', function(c)
      local mapped = ESCAPES[c]
      if mapped then return mapped end
      return string.format("\\u%04x", string.byte(c))
   end)
   return '"' .. out .. '"'
end

local function encode_number(n)
   if n ~= n then error("cannot encode nan as JSON", 0) end
   if n == math.huge or n == -math.huge then
      error("cannot encode infinity as JSON", 0)
   end
   -- Whole numbers print without a decimal point; everything else keeps
   -- enough precision to survive a round trip.
   if n % 1 == 0 and math.abs(n) < 1e15 then
      return string.format("%d", n)
   end
   return string.format("%.14g", n)
end

--- Does this table look like a dense array?
local function looks_like_array(t)
   local count = 0
   for key in pairs(t) do
      if type(key) ~= "number" then return false end
      count = count + 1
   end
   if count == 0 then return Json.is_array(t) end
   -- every index from 1..count must be present
   for i = 1, count do
      if t[i] == nil then return false end
   end
   return true
end

--- Sorted key list, so output is stable across runs.
local function sorted_keys(t)
   local keys = {}
   for key in pairs(t) do keys[#keys + 1] = key end
   table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
   return keys
end

local encode_value

local function encode_table(value, indent, seen, path)
   if seen[value] then
      error("cannot encode a table that contains itself (at " .. path .. ")", 0)
   end
   seen[value] = true

   local pad      = string.rep("  ", indent + 1)
   local pad_end  = string.rep("  ", indent)
   local result

   if looks_like_array(value) then
      if #value == 0 then
         result = "[]"
      else
         local parts = {}
         for i = 1, #value do
            parts[#parts + 1] = pad ..
               encode_value(value[i], indent + 1, seen, path .. "[" .. i .. "]")
         end
         result = "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad_end .. "]"
      end
   else
      local keys = sorted_keys(value)
      if #keys == 0 then
         result = "{}"
      else
         local parts = {}
         for i = 1, #keys do
            local key = keys[i]
            parts[#parts + 1] = pad .. escape_string(tostring(key)) .. ": " ..
               encode_value(value[key], indent + 1, seen, path .. "." .. tostring(key))
         end
         result = "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad_end .. "}"
      end
   end

   seen[value] = nil
   return result
end

encode_value = function(value, indent, seen, path)
   if value == Json.null or value == nil then return "null" end

   local kind = type(value)
   if kind == "boolean" then return tostring(value) end
   if kind == "number"  then return encode_number(value) end
   if kind == "string"  then return escape_string(value) end
   if kind == "table"   then return encode_table(value, indent, seen, path) end

   error(string.format("cannot encode a %s as JSON (at %s)", kind, path), 0)
end

--- Encode a Lua value as indented JSON text.
-- @return string, or nil plus an error message
function Json.encode(value)
   local ok, result = pcall(encode_value, value, 0, {}, "$")
   if not ok then return nil, tostring(result) end
   return result .. "\n"
end

---------------------------------------------------------------------------
-- decoding
---------------------------------------------------------------------------

local Decoder = {}
Decoder.__index = Decoder

local function new_decoder(text)
   return setmetatable({ text = text, pos = 1, len = #text }, Decoder)
end

--- Turn a byte offset into "line N, column M" for error messages.
function Decoder:where(pos)
   pos = pos or self.pos
   local line, last_break = 1, 0
   for i = 1, math.min(pos, self.len) - 1 do
      if self.text:sub(i, i) == "\n" then
         line = line + 1
         last_break = i
      end
   end
   return string.format("line %d, column %d", line, pos - last_break)
end

function Decoder:fail(message, pos)
   error(string.format("%s at %s", message, self:where(pos)), 0)
end

function Decoder:skip_whitespace()
   local _, stop = self.text:find("^[ \t\r\n]*", self.pos)
   self.pos = stop + 1
end

function Decoder:peek()
   return self.text:sub(self.pos, self.pos)
end

function Decoder:expect(char)
   if self:peek() ~= char then
      self:fail(string.format("expected %q but found %q", char,
                              self:peek() == "" and "<end of input>" or self:peek()))
   end
   self.pos = self.pos + 1
end

--- Encode a Unicode code point as UTF-8.
local function utf8_encode(code)
   if code < 0x80 then
      return string.char(code)
   elseif code < 0x800 then
      return string.char(0xC0 + math.floor(code / 0x40),
                         0x80 + (code % 0x40))
   elseif code < 0x10000 then
      return string.char(0xE0 + math.floor(code / 0x1000),
                         0x80 + (math.floor(code / 0x40) % 0x40),
                         0x80 + (code % 0x40))
   end
   return string.char(0xF0 + math.floor(code / 0x40000),
                      0x80 + (math.floor(code / 0x1000) % 0x40),
                      0x80 + (math.floor(code / 0x40) % 0x40),
                      0x80 + (code % 0x40))
end

local STRING_ESCAPES = {
   ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
   b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

function Decoder:read_hex4()
   local hex = self.text:sub(self.pos, self.pos + 3)
   if not hex:match("^%x%x%x%x$") then
      self:fail("malformed \\u escape")
   end
   self.pos = self.pos + 4
   return tonumber(hex, 16)
end

function Decoder:read_string()
   self:expect('"')
   local parts = {}

   while true do
      local char = self:peek()
      if char == "" then self:fail("unterminated string") end

      if char == '"' then
         self.pos = self.pos + 1
         return table.concat(parts)
      end

      if char == "\\" then
         self.pos = self.pos + 1
         local code = self:peek()
         self.pos = self.pos + 1

         local simple = STRING_ESCAPES[code]
         if simple then
            parts[#parts + 1] = simple
         elseif code == "u" then
            local value = self:read_hex4()
            -- Surrogate pair: combine the two halves into one code point.
            if value >= 0xD800 and value <= 0xDBFF then
               if self.text:sub(self.pos, self.pos + 1) == "\\u" then
                  local mark = self.pos
                  self.pos = self.pos + 2
                  local low = self:read_hex4()
                  if low >= 0xDC00 and low <= 0xDFFF then
                     value = 0x10000 + (value - 0xD800) * 0x400 + (low - 0xDC00)
                  else
                     self.pos = mark   -- not a low surrogate; leave it alone
                  end
               end
            end
            parts[#parts + 1] = utf8_encode(value)
         else
            self:fail(string.format("unknown escape \\%s", code), self.pos - 1)
         end
      else
         -- Consume a plain run in one go rather than byte by byte.
         local _, stop = self.text:find('^[^"\\]+', self.pos)
         parts[#parts + 1] = self.text:sub(self.pos, stop)
         self.pos = stop + 1
      end
   end
end

function Decoder:read_number()
   local start = self.pos
   local _, stop = self.text:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", self.pos)
   if stop == nil or stop < start then self:fail("malformed number") end

   local text = self.text:sub(start, stop)
   local value = tonumber(text)
   if value == nil then self:fail(string.format("malformed number %q", text)) end

   self.pos = stop + 1
   return value
end

function Decoder:read_literal(word, value)
   if self.text:sub(self.pos, self.pos + #word - 1) ~= word then
      self:fail("unrecognised value")
   end
   self.pos = self.pos + #word
   return value
end

function Decoder:read_array()
   self:expect("[")
   local out = Json.array{}
   self:skip_whitespace()

   if self:peek() == "]" then self.pos = self.pos + 1; return out end

   while true do
      out[#out + 1] = self:read_value()
      self:skip_whitespace()
      local char = self:peek()
      if char == "," then
         self.pos = self.pos + 1
         self:skip_whitespace()
      elseif char == "]" then
         self.pos = self.pos + 1
         return out
      else
         self:fail("expected ',' or ']' in array")
      end
   end
end

function Decoder:read_object()
   self:expect("{")
   local out = {}
   self:skip_whitespace()

   if self:peek() == "}" then self.pos = self.pos + 1; return out end

   while true do
      self:skip_whitespace()
      if self:peek() ~= '"' then self:fail("expected a quoted key in object") end
      local key = self:read_string()

      self:skip_whitespace()
      self:expect(":")
      self:skip_whitespace()

      out[key] = self:read_value()

      self:skip_whitespace()
      local char = self:peek()
      if char == "," then
         self.pos = self.pos + 1
      elseif char == "}" then
         self.pos = self.pos + 1
         return out
      else
         self:fail("expected ',' or '}' in object")
      end
   end
end

function Decoder:read_value()
   self:skip_whitespace()
   local char = self:peek()

   if char == ""  then self:fail("unexpected end of input") end
   if char == "{" then return self:read_object() end
   if char == "[" then return self:read_array() end
   if char == '"' then return self:read_string() end
   if char == "t" then return self:read_literal("true",  true) end
   if char == "f" then return self:read_literal("false", false) end
   if char == "n" then return self:read_literal("null",  Json.null) end
   if char:match("[%-%d]") then return self:read_number() end

   self:fail(string.format("unexpected character %q", char))
end

--- Parse JSON text.
-- @return value, or nil plus an error message naming line and column
function Json.decode(text)
   if type(text) ~= "string" then
      return nil, "expected JSON text, got " .. type(text)
   end

   -- Tolerate a UTF-8 byte order mark; editors on Windows add them.
   text = text:gsub("^\239\187\191", "")

   local decoder = new_decoder(text)
   local ok, result = pcall(function()
      local value = decoder:read_value()
      decoder:skip_whitespace()
      if decoder.pos <= decoder.len then
         decoder:fail("unexpected trailing content")
      end
      return value
   end)

   if not ok then return nil, tostring(result) end
   return result
end

return Json

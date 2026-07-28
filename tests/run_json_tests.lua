--[[--------------------------------------------------------------------------
| tests/run_json_tests.lua - Tests for the pure-Lua JSON codec.
|
| The tool database is JSON and VCarve ships no JSON library, so this codec is
| load-bearing: a decoding bug is a wrong cutter or a wrong feed rate.
|
| Run:  lua tests/run_json_tests.lua      (from the repository root)
----------------------------------------------------------------------------]]

local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
local Json = dofile(ROOT .. "/LayerDSL_Toolpaths/lib/db/json.lua")

local passed, failed, failures = 0, 0, {}

local function check(name, ok, detail)
   if ok then passed = passed + 1
   else
      failed = failed + 1
      failures[#failures + 1] = string.format("%s\n      %s", name, detail or "")
   end
end

local function eq(name, actual, expected)
   check(name, actual == expected,
         string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end

---------------------------------------------------------------------------
-- 1. scalars round-trip
---------------------------------------------------------------------------

do
   local function roundtrip(name, value)
      local text = Json.encode(value)
      check(name .. "/encodes", text ~= nil, "encode returned nil")
      local back, err = Json.decode(text)
      check(name .. "/decodes", back ~= nil, tostring(err))
      eq(name .. "/same value", back, value)
   end

   roundtrip("scalar/int", 42)
   roundtrip("scalar/negative", -17)
   roundtrip("scalar/float", 3.25)
   roundtrip("scalar/zero", 0)
   roundtrip("scalar/true", true)
   roundtrip("scalar/false", false)
   roundtrip("scalar/string", "hello")
   roundtrip("scalar/empty string", "")

   eq("scalar/null decodes to sentinel", Json.decode("null"), Json.null)
   eq("scalar/whole numbers have no point", Json.encode(6):gsub("%s", ""), "6")
   eq("scalar/float keeps precision",
      tonumber((Json.encode(220.5):gsub("%s", ""))), 220.5)
end

---------------------------------------------------------------------------
-- 2. strings: escaping and unicode
---------------------------------------------------------------------------

do
   local function roundtrip(name, s)
      local back = Json.decode(Json.encode(s))
      eq(name, back, s)
   end

   roundtrip("string/quote",     'say "hi"')
   roundtrip("string/backslash", "C:\\ProgramData\\SmartCAM")
   roundtrip("string/newline",   "a\nb")
   roundtrip("string/tab",       "a\tb")
   roundtrip("string/cr",        "a\rb")
   roundtrip("string/control",   "a\1b")
   roundtrip("string/slash",     "a/b")
   roundtrip("string/utf8",      "6 mm \195\169 cutter")

   -- escapes on the way in
   eq("string/decode \\n",  Json.decode('"a\\nb"'), "a\nb")
   eq("string/decode \\/",  Json.decode('"a\\/b"'), "a/b")
   eq("string/decode \\u",  Json.decode('"\\u0041"'), "A")
   eq("string/decode \\u utf8", Json.decode('"\\u00e9"'), "\195\169")
   -- surrogate pair: U+1F600
   eq("string/surrogate pair", Json.decode('"\\ud83d\\ude00"'),
      "\240\159\152\128")

   -- windows paths survive, which matters for the database location
   local path = "C:\\ProgramData\\SmartCAM\\tools.json"
   eq("string/windows path", Json.decode(Json.encode(path)), path)
end

---------------------------------------------------------------------------
-- 3. objects and arrays
---------------------------------------------------------------------------

do
   local doc = Json.decode('{"a":1,"b":[1,2,3],"c":{"d":"e"}}')
   check("object/decoded", doc ~= nil, "decode failed")
   eq("object/number",  doc.a, 1)
   eq("object/array len", #doc.b, 3)
   eq("object/array item", doc.b[2], 2)
   eq("object/nested", doc.c.d, "e")

   local list = Json.decode("[]")
   eq("array/empty length", #list, 0)
   check("array/empty is marked", Json.is_array(list), "lost the array marker")
   eq("array/empty re-encodes as []", Json.encode(list):gsub("%s", ""), "[]")

   local obj = Json.decode("{}")
   eq("object/empty re-encodes as {}", Json.encode(obj):gsub("%s", ""), "{}")

   -- an empty tool list must stay a list across a save/load cycle
   local db = { tools = Json.array{} }
   local back = Json.decode(Json.encode(db))
   eq("array/empty survives round trip",
      Json.encode(back):gsub("%s", ""), '{"tools":[]}')
end

---------------------------------------------------------------------------
-- 4. deterministic output
---------------------------------------------------------------------------

do
   local doc = { zebra = 1, alpha = 2, monkey = 3, beta = 4 }
   local first  = Json.encode(doc)
   local second = Json.encode(doc)
   eq("stable/same twice", first, second)

   local order = {}
   for key in first:gmatch('"(%w+)":') do order[#order + 1] = key end
   eq("stable/key 1", order[1], "alpha")
   eq("stable/key 2", order[2], "beta")
   eq("stable/key 3", order[3], "monkey")
   eq("stable/key 4", order[4], "zebra")
end

---------------------------------------------------------------------------
-- 5. whitespace and formatting tolerance
---------------------------------------------------------------------------

do
   local doc = Json.decode('  {\n\t"a" : [ 1 , 2 ] ,\r\n "b" : true \n}  ')
   check("ws/decoded", doc ~= nil, "decode failed")
   eq("ws/array", doc.a[2], 2)
   eq("ws/bool", doc.b, true)

   -- a UTF-8 BOM, which Windows editors like to add
   local bom = Json.decode('\239\187\191{"a":1}')
   check("bom/decoded", bom ~= nil, "BOM broke decoding")
   eq("bom/value", bom and bom.a, 1)
end

---------------------------------------------------------------------------
-- 6. errors are reported, never thrown
---------------------------------------------------------------------------

do
   local bad = {
      "{", "}", "[", "]", '{"a"}', '{"a":}', '{a:1}', "[1,]", '{"a":1,}',
      "tru", "nul", '"unterminated', "{'a':1}", "[1 2]", "", "   ",
      '{"a":1} trailing', "\\", "--1", '{"a":"\\q"}', '{"a":"\\u00zz"}',
   }
   for i = 1, #bad do
      local value, err = Json.decode(bad[i])
      check("error/" .. i .. " rejected " .. string.format("%q", bad[i]),
            value == nil and type(err) == "string",
            "expected nil + message, got " .. tostring(value))
   end

   -- messages should locate the problem
   local _, err = Json.decode('{\n  "a": 1,\n  "b": }\n}')
   check("error/reports a line", (err or ""):find("line") ~= nil, tostring(err))

   -- encoding failures are returned, not raised
   local cyclic = {}; cyclic.self = cyclic
   local text, cerr = Json.encode(cyclic)
   check("error/cycle rejected", text == nil and cerr ~= nil, tostring(text))

   local ftext, ferr = Json.encode({ f = print })
   check("error/function rejected", ftext == nil and ferr ~= nil, tostring(ftext))

   local ntext = Json.encode(0 / 0)
   check("error/nan rejected", ntext == nil, tostring(ntext))
end

---------------------------------------------------------------------------
-- 7. a realistic tool document
---------------------------------------------------------------------------

do
   local text = [[
{
  "schema": 1,
  "tools": [
    {
      "id": 1,
      "name": "End Mill 6mm",
      "type": "end_mill",
      "units": "mm",
      "diameter": 6.0,
      "tool_number": 1,
      "stepdown": 2.0,
      "stepover": 2.4,
      "feed_rate": 220.0,
      "plunge_rate": 75.0,
      "spindle_speed": 10000,
      "rate_units": "mm_min",
      "notes": null
    },
    {
      "id": 3,
      "name": "V-Bit 60\u00b0",
      "type": "vbit",
      "units": "mm",
      "diameter": 12.0,
      "included_angle": 60.0,
      "tool_number": 3,
      "feed_rate": 150,
      "plunge_rate": 50,
      "spindle_speed": 16000,
      "rate_units": "mm_min"
    }
  ]
}
]]
   local db, err = Json.decode(text)
   check("doc/decoded", db ~= nil, tostring(err))
   eq("doc/schema", db.schema, 1)
   eq("doc/two tools", #db.tools, 2)
   eq("doc/first name", db.tools[1].name, "End Mill 6mm")
   eq("doc/first diameter", db.tools[1].diameter, 6.0)
   eq("doc/null note", db.tools[1].notes, Json.null)
   eq("doc/second angle", db.tools[2].included_angle, 60.0)
   eq("doc/unicode name", db.tools[2].name, "V-Bit 60\194\176")
   eq("doc/missing field is nil", db.tools[1].included_angle, nil)

   -- and it survives a save/load cycle unchanged
   local again = Json.decode(Json.encode(db))
   eq("doc/round trip stable", Json.encode(again), Json.encode(db))
end

---------------------------------------------------------------------------
-- report
---------------------------------------------------------------------------

print(string.format("\n  %d passed, %d failed\n", passed, failed))
if failed > 0 then
   for i = 1, #failures do print("  FAIL  " .. failures[i]) end
   os.exit(1)
end
os.exit(0)

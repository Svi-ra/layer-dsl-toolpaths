--[[--------------------------------------------------------------------------
| lib/ops/vcarve.lua - V-carving operation, with optional flat bottom.
|
| `tool` is the tool number of a V-BIT in the VCarve tool library. Its
| included angle and diameter are read from that library tool, so a V-carve
| can no longer be cut with an angle the gadget guessed.
|
| A flat bottom additionally needs `flat_tool`, the tool number of the end
| mill that clears it.
|
| See lib/ops/pocket.lua for the module contract.
----------------------------------------------------------------------------]]

return {
   name = "VCarve",
   summary = "V-carves between vector pairs, optionally with a flat bottom.",

   build = function(params, ctx, deps)
      local Enums, Tooling = deps.enums, deps.tooling
      local warnings = {}
      local function note(x)
         if type(x) == "table" then
            for _, w in ipairs(x) do warnings[#warnings + 1] = w end
         elseif x then
            warnings[#warnings + 1] = x
         end
      end

      ------------------------------------------------------------------
      -- V-bit, from the VCarve tool library
      --
      -- The included angle comes from the library tool, which is the only
      -- place it can be right. Nothing here invents a V-bit.
      ------------------------------------------------------------------
      local tool, w, err, record = Tooling.from_library{
         reference = params.tool,
         role      = "V-bit",
         params    = params,
         ctx       = ctx,
      }
      note(w)
      if tool == nil then return nil, err, warnings end
      note(Tooling.check_tool_type(record, params.tool, "vbit", "V-carving"))

      -- The repository already refuses a V-bit without a usable angle, so
      -- reaching here with a bad one means the record is not a V-bit at all.
      local angle = tonumber(record.included_angle)
      if angle == nil or angle <= 0 or angle >= 180 then
         return nil, string.format(
            "tool %s has no usable V-bit included angle (%s); "
            .. "point this layer at a V-bit in tools.json",
            tostring(params.tool), tostring(record.included_angle)), warnings
      end

      ------------------------------------------------------------------
      -- V-carve parameters
      ------------------------------------------------------------------
      local flat_depth = params.flat_depth or 0.0
      local flat       = (flat_depth > 0)

      local vcarve = VCarveParameterData()
      vcarve.StartDepth  = params.start_depth
      vcarve.DoFlatBottom = flat
      vcarve.FlatDepth    = flat_depth
      vcarve.ProjectToolpath = false

      ------------------------------------------------------------------
      -- Flat-bottom area clearance
      ------------------------------------------------------------------
      local area_clear_tool = nil
      local pocket = PocketParameterData()

      if flat then
         if params.flat_tool == nil then
            return nil, "flat_depth is set but no flat_tool number was given; "
                     .. "a flat bottom needs an end mill to clear it", warnings
         end

         vcarve.UseAreaClearTool = true

         local clear_err, clear_record
         area_clear_tool, w, clear_err, clear_record = Tooling.from_library{
            reference = params.flat_tool,
            role      = "flat clearance tool",
            params    = params,
            ctx       = ctx,
         }
         note(w)
         if area_clear_tool == nil then return nil, clear_err, warnings end
         note(Tooling.check_tool_type(clear_record, params.flat_tool,
                                      "end_mill", "flat-bottom clearance"))

         pocket.StartDepth = params.start_depth
         pocket.CutDepth   = flat_depth

         local dir, w2 = Enums.cut_direction(params.cut_direction)
         note(w2)
         pocket.CutDirection = dir

         pocket.Allowance         = params.finishing and 0.0 or params.allowance
         pocket.DoRasterClearance = (params.strategy == "raster")
         pocket.RasterAngle       = params.raster_angle or 0.0

         local pass, w3 = Enums.profile_pass(params.last_pass)
         note(w3)
         pocket.ProfilePassType = pass
      else
         vcarve.UseAreaClearTool = false
      end

      ------------------------------------------------------------------
      -- Position, geometry selection, and creation
      ------------------------------------------------------------------
      local pos = Tooling.position(params, ctx)

      -- V-carving needs the closed outlines it carves between.
      local selector = Enums.build_selector(
                          params.layer_name, params.vector_selection, tool.ToolDia)

      local id = ToolpathManager():CreateVCarvingToolpath(
                    params.toolpath_name,
                    tool,
                    area_clear_tool,
                    vcarve,
                    pocket,
                    pos,
                    selector,
                    ctx.create_2d_previews,
                    ctx.interactive_warnings)

      if id == nil then
         return nil, "VCarve could not calculate the V-carving toolpath", warnings
      end
      return id, nil, warnings
   end,
}

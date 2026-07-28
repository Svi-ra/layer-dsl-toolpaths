--[[--------------------------------------------------------------------------
| lib/ops/pocket.lua - Pocketing operation.
|
| An operation module returns one table describing itself. lib/factory.lua
| picks it up by `name`; nothing else needs to know it exists.
|
| Contract
| --------
|   name    string   canonical operation name (matches lib/schema.lua)
|   build   function (params, ctx, deps) -> toolpath_id | nil, error_string
|
| `params` is the plain table from the parser. The factory never inspects it,
| and this module never inspects the layer name. That separation is the whole
| point of the architecture.
----------------------------------------------------------------------------]]

return {
   name = "Pocket",
   summary = "Area-clears the inside of closed vectors.",

   build = function(params, ctx, deps)
      local Enums, Tooling = deps.enums, deps.tooling
      local warnings = {}
      local function note(list) for _, w in ipairs(list or {}) do warnings[#warnings+1] = w end end

      ------------------------------------------------------------------
      -- Cutter, from the VCarve tool library
      ------------------------------------------------------------------
      local tool, w, err, record = Tooling.from_library{
         reference = params.tool,
         role      = "pocket tool",
         params    = params,
         ctx       = ctx,
      }
      note(w)
      if tool == nil then return nil, err, warnings end
      note({ Tooling.check_tool_type(record, params.tool, "end_mill", "pocket") })

      -- Optional larger roughing tool for two-tool pocketing.
      local area_clear_tool = nil
      if params.roughing then
         if params.roughing_tool == nil then
            warnings[#warnings + 1] =
               "roughing is on but no roughing_tool number was given; "
               .. "clearing with the pocket tool alone"
         else
            local rougher, rw, rerr, rrecord = Tooling.from_library{
               reference = params.roughing_tool,
               role      = "roughing tool",
               params    = params,
               ctx       = ctx,
            }
            note(rw)
            if rougher == nil then
               return nil, rerr, warnings
            elseif rougher.ToolDia <= tool.ToolDia then
               warnings[#warnings + 1] = string.format(
                  "roughing tool %s (%.3g) is not larger than pocket tool %s (%.3g); "
                  .. "skipping two-tool pocketing",
                  tostring(params.roughing_tool), rougher.ToolDia,
                  tostring(params.tool), tool.ToolDia)
            else
               area_clear_tool = rougher
            end
         end
      end

      ------------------------------------------------------------------
      -- Pocket parameters
      ------------------------------------------------------------------
      local pocket = PocketParameterData()

      pocket.StartDepth = params.start_depth
      pocket.CutDepth   = params.depth

      local dir, w2 = Enums.cut_direction(params.cut_direction)
      if w2 then warnings[#warnings + 1] = w2 end
      pocket.CutDirection = dir

      -- `finishing` means "cut to size": no stock left, and a profile pass
      -- last so the wall is cut in one continuous move.
      if params.finishing then
         pocket.Allowance = 0.0
         pocket.ProfilePassType = PocketParameterData.PROFILE_LAST
      else
         pocket.Allowance = params.allowance
         local pass, w3 = Enums.profile_pass(params.last_pass)
         if w3 then warnings[#warnings + 1] = w3 end
         pocket.ProfilePassType = pass
      end

      pocket.DoRasterClearance = (params.strategy == "raster")
      pocket.RasterAngle       = params.raster_angle or 0.0

      -- Ramping. A number sets the distance; `true` means "on, you pick",
      -- for which ten times the stepdown is a reasonable, gentle ramp.
      local ramp = params.ramp
      if ramp == true then ramp = params.pass_depth * 10.0 end
      pocket.DoRamping = (type(ramp) == "number" and ramp > 0)
      if pocket.DoRamping then
         pocket.RampDistance = ramp
      end

      pocket.UseAreaClearTool = (area_clear_tool ~= nil)

      -- Aspire-only; harmless in VCarve Pro.
      pocket.ProjectToolpath = false

      ------------------------------------------------------------------
      -- Position, geometry selection, and creation
      ------------------------------------------------------------------
      local pos      = Tooling.position(params, ctx)
      local selector = Enums.build_selector(
                          params.layer_name, params.vector_selection, tool.ToolDia)

      local id = ToolpathManager():CreatePocketingToolpath(
                    params.toolpath_name,
                    tool,
                    area_clear_tool,
                    pocket,
                    pos,
                    selector,
                    ctx.create_2d_previews,
                    ctx.interactive_warnings)

      if id == nil then
         return nil, "VCarve could not calculate the pocket toolpath", warnings
      end
      return id, nil, warnings
   end,
}

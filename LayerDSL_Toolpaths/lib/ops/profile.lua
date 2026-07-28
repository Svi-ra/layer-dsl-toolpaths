--[[--------------------------------------------------------------------------
| lib/ops/profile.lua - Profiling / cut-out operation.
|
| See lib/ops/pocket.lua for the module contract.
----------------------------------------------------------------------------]]

return {
   name = "Profile",
   summary = "Cuts along vectors, inside, outside or on the line.",

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
      -- Cutter, from the VCarve tool library
      ------------------------------------------------------------------
      local tool, w, err, record = Tooling.from_library{
         reference = params.tool,
         role      = "profile tool",
         params    = params,
         ctx       = ctx,
      }
      note(w)
      if tool == nil then return nil, err, warnings end

      local explicit = params.explicit or {}
      local record_type = tostring(record and record.type or "end_mill"):lower()
      local side_token = params.side
      local selection_token = params.vector_selection
      if record_type == "vbit" and not explicit.side then
         side_token = "on"
         if not explicit.vector_selection then
            selection_token = "all"
         end
      else
         note(Tooling.check_tool_type(record, params.tool, "end_mill", "profile"))
      end

      ------------------------------------------------------------------
      -- Profile parameters
      ------------------------------------------------------------------
      local profile = ProfileParameterData()

      profile.StartDepth = params.start_depth
      profile.CutDepth   = params.depth

      local side, w1 = Enums.profile_side(side_token)
      note(w1)
      profile.ProfileSide = side

      local dir, w2 = Enums.cut_direction(params.cut_direction)
      note(w2)
      profile.CutDirection = dir

      profile.Allowance = params.finishing and 0.0 or params.allowance

      profile.KeepStartPoints     = params.keep_start_points or false
      profile.CreateSquareCorners = params.square_corners or false
      profile.CornerSharpen       = params.inside_corner or false

      -- Tabs. VCarve needs tab POSITIONS to already exist on the vectors;
      -- this switch only turns on the tabbing, it cannot place tabs.
      profile.UseTabs = params.tabs and true or false
      if profile.UseTabs then
         profile.TabLength    = params.tab_width
         profile.TabThickness = params.tab_height
         profile.Use3dTabs    = true
         if side_token == "on" then
            note("tabs on a 'profile on' toolpath are ignored by VCarve")
         end
      end

      profile.ProjectToolpath = false

      ------------------------------------------------------------------
      -- Ramping
      ------------------------------------------------------------------
      local ramping = RampingData()
      local ramp = params.ramp
      if ramp == true then ramp = params.pass_depth * 10.0 end

      ramping.DoRamping = (type(ramp) == "number" and ramp > 0)
      if ramping.DoRamping then
         local rtype, w3 = Enums.ramp_type(params.ramp_type or "zigzag")
         note(w3)
         ramping.RampType = rtype

         -- An explicit ramp_angle constrains by angle; otherwise the number
         -- the user gave `ramp` is a distance.
         if params.ramp_angle then
            ramping.RampConstraint   = RampingData.CONSTRAIN_ANGLE
            ramping.RampAngle        = params.ramp_angle
            ramping.RampMaxAngleDist = ramp
         else
            ramping.RampConstraint = RampingData.CONSTRAIN_DISTANCE
            ramping.RampDistance   = ramp
         end
         ramping.RampOnLeadIn = false
      end

      ------------------------------------------------------------------
      -- Leads
      ------------------------------------------------------------------
      local leads = LeadInOutData()

      local lead_in  = params.lead_in
      local lead_out = params.lead_out
      if lead_in  == true then lead_in  = tool.ToolDia end
      if lead_out == true then lead_out = tool.ToolDia end

      local has_in  = (type(lead_in)  == "number" and lead_in  > 0)
      local has_out = (type(lead_out) == "number" and lead_out > 0)

      leads.DoLeadIn  = has_in
      leads.DoLeadOut = has_out

      if has_in or has_out then
         if side_token == "on" then
            note("lead in/out is ignored on a 'profile on' toolpath")
         end
         local ltype, w4 = Enums.lead_type(params.lead_type or "circular")
         note(w4)
         leads.LeadType = ltype

         local length = has_in and lead_in or lead_out
         leads.LeadLength        = length
         leads.LinearLeadAngle   = params.lead_angle or 45.0
         leads.CirularLeadRadius = length            -- SDK spells it this way
      end

      leads.OvercutDistance = params.offset or 0.0

      ------------------------------------------------------------------
      -- Position, geometry selection, and creation
      ------------------------------------------------------------------
      local pos      = Tooling.position(params, ctx)
      local selector = Enums.build_selector(
                          params.layer_name, selection_token, tool.ToolDia)

      local id = ToolpathManager():CreateProfilingToolpath(
                    params.toolpath_name,
                    tool,
                    profile,
                    ramping,
                    leads,
                    pos,
                    selector,
                    ctx.create_2d_previews,
                    ctx.interactive_warnings)

      if id == nil then
         local hint = "VCarve could not calculate the profile toolpath"
            .. string.format(
               " (side=%s, vector_selection=%s, tool=%s, depth=%s).",
               tostring(side_token),
               tostring(selection_token),
               tostring(params.tool),
               tostring(params.depth))
            .. " Check that the vectors match the selection and profile side;"
            .. " for open vectors use side_on_vector_selection_open."
         return nil, hint, warnings
      end
      return id, nil, warnings
   end,
}

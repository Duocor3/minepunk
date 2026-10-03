-- MCPassthrough (Cyberpunk 2077 side): reads Cyberpunk's camera every tick and drives real Minecraft through the
-- MCPassthrough RED4ext plugin (Game.MCPT_*), which links to the Minecraft mod and composites its frames via ReShade.
--
-- Coordinates: 1 Cyberpunk metre = 1 block. Cyberpunk (x, y, z), Z up -> Minecraft (x, z + yoff, -y).
-- yoff puts V's feet on a whole block (y = 64) when the link starts or on re-level.

local MCPT = {
	active = true,
	yoff = nil,
	fovIsHorizontal = false, -- GetActiveCameraFOV is believed vertical; flip if the gold wall's size is off
	near = 0.02,             -- host clip planes for the depth test (calibrate with the effect's depth bands view)
	far = 100000.0,
	maxPixels = 1920 * 1080,
	frame = 0,
	gen = -1,
	viewSent = "",
	loggedFov = false,
	wallPending = false,
	plugin = false,
}

local function log(msg)
	print("[MCPassthrough] " .. msg)
	pcall(function() spdlog.info(msg) end) -- mods/mcpassthrough/mcpassthrough.log (flushed lazily)
	-- mcpt.log is written through at once, so it can be read while the game runs
	local f = io.open("mcpt.log", "a")
	if f then
		f:write(os.date("%H:%M:%S ") .. msg .. "\n")
		f:close()
	end
end

local function json_num(v)
	return string.format("%.4f", v)
end

-- Minecraft yaw/pitch (degrees; yaw 0 faces +Z, positive pitch looks down) of a Cyberpunk direction.
local function mc_angles(v)
	local dx, dy, dz = v.x, v.z, -v.y
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	if len < 1e-6 then return 0, 0 end
	dx, dy, dz = dx / len, dy / len, dz / len
	local yaw = math.deg(math.atan2(-dx, dz))
	local pitch = math.deg(-math.asin(math.max(-1, math.min(1, dy))))
	return yaw, pitch
end

-- Roll of the camera (degrees, Minecraft convention) from Cyberpunk's up vector.
local function mc_roll(yaw, pitch, up)
	local y, p = math.rad(yaw), math.rad(pitch)
	local fwd = { -math.sin(y) * math.cos(p), -math.sin(p), math.cos(y) * math.cos(p) }
	local right = { -math.cos(y), 0, -math.sin(y) }
	-- up0 = right x fwd
	local u0 = {
		right[2] * fwd[3] - right[3] * fwd[2],
		right[3] * fwd[1] - right[1] * fwd[3],
		right[1] * fwd[2] - right[2] * fwd[1],
	}
	local u = { up.x, up.z, -up.y }
	local c = u[1] * u0[1] + u[2] * u0[2] + u[3] * u0[3]
	local s = u[1] * right[1] + u[2] * right[2] + u[3] * right[3]
	return math.deg(math.atan2(-s, c))
end

local function send(msg)
	return Game.MCPT_Send(msg)
end

-- steve: his centre in Minecraft coordinates while he is drawn (third person), else nil
local function pose(active, yaw, pitch, roll, fov, x, y, z, steve)
	Game.MCPT_Pose(string.format("%d %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.5f %.1f %d %d %.4f %.4f %.4f", active and 1 or 0, yaw, pitch,
		roll, fov, x, y, z, MCPT.near, MCPT.far, math.floor(MCPT.poseLag or 0), steve and 1 or 0,
		steve and steve[1] or 0, steve and steve[2] or 0, steve and steve[3] or 0))
end

local function in_game()
	local player = Game.GetPlayer()
	if not player then return nil end
	local ok, paused = pcall(function() return Game.GetTimeSystem():IsPausedState() end)
	if ok and paused then return nil end
	local okp, photo = pcall(function() return Game.GetPhotoModeSystem():IsPhotoModeActive() end)
	if okp and photo then return nil end
	return player
end

local function camera()
	local cs = Game.GetCameraSystem()
	local fwd, up = cs:GetActiveCameraForward(), cs:GetActiveCameraUp()
	local t = Transform.new()
	local ok, a, b = pcall(function() return cs:GetActiveCameraWorldTransform(t) end)
	local pos = nil
	if ok then
		if type(b) == "userdata" and b.position then pos = b.position
		elseif type(a) == "userdata" and a.position then pos = a.position
		else pos = t.position end
	end
	local fov = cs:GetActiveCameraFOV()
	return pos, fwd, up, fov
end

-- A 5 x 4 gold wall 8 blocks ahead of V, squared to the nearest axis: the alignment test.
local function place_wall(feet, fwd)
	local yaw = mc_angles(fwd)
	local fx, fy, fz = feet.x, feet.z + MCPT.yoff, -feet.y
	local r = math.rad(yaw)
	local cx, cz = fx - math.sin(r) * 8, fz + math.cos(r) * 8
	local y0 = math.floor(fy + 0.5)
	local x1, z1, x2, z2
	if math.abs(math.sin(r)) > math.abs(math.cos(r)) then -- facing along x: wall spans z
		x1, x2 = math.floor(cx), math.floor(cx)
		z1, z2 = math.floor(cz) - 2, math.floor(cz) + 2
	else
		z1, z2 = math.floor(cz), math.floor(cz)
		x1, x2 = math.floor(cx) - 2, math.floor(cx) + 2
	end
	send(string.format('{"t":"cmd","c":"fill %d %d %d %d %d %d minecraft:gold_block"}', x1, y0, z1, x2, y0 + 3, z2))
	log(string.format("gold wall at x %d..%d y %d..%d z %d..%d", x1, x2, y0, y0 + 3, z1, z2))
end

-- Showcase spots: Appearance Menu Mod's built-in teleport locations (its db.sqlite3 "locations" table, AMM commit
-- 5427235): name, x, y, z, yaw. Teleport with "go = N" in tune.txt (or the hotkeys).
local SPOTS = {
	{ "Megabuilding H8 roof (Japantown, 337 m: jump off and glide)", -680.80, 811.03, 337.28, 97.30 },
	{ "Jig-Jig Street (neon, street level)", -652.92, 842.57, 19.27, -111.65 },
	{ "Corpo Plaza (holograms)", -1599.93, 345.70, 8.17, 2.25 },
	{ "Third Sniper's Perch (Japantown, 171 m)", -539.52, 783.01, 171.00, -149.75 },
	{ "North Oak Sign (skyline view)", 203.67, 865.08, 162.99, 146.30 },
}

local function go_spot(n)
	local s = SPOTS[n]
	local player = Game.GetPlayer()
	if not s or not player then return end
	if MCPT.fly then
		MCPT.fly, MCPT.flyPos, MCPT.flyEndedAt = nil, nil, MCPT.frame -- a teleport ends any flight
		send('{"t":"glide","on":false}')
	end
	pcall(function()
		Game.GetTeleportationFacility():Teleport(player, Vector4.new(s[2], s[3], s[4], 1.0), EulerAngles.new(0, 0, s[5]))
	end)
	log("teleport to " .. s[1])
end

local function set_heat(level)
	return pcall(function()
		local ps = Game.GetScriptableSystemsContainer():Get("PreventionSystem")
		local req = PreventionConsoleInstructionRequest.new()
		req.instruction = level > 0 and EPreventionSystemInstruction.Active or EPreventionSystemInstruction.Safe
		req.heatStage = EPreventionHeatStage["Heat_" .. math.floor(level)]
		ps:QueueRequest(req)
	end)
end

local function heat_now()
	local ok, h = pcall(function() return Game.GetScriptableSystemsContainer():Get("PreventionSystem"):GetHeatStageAsInt() end)
	return ok and h or -1
end

local function teleport_v(x, y, z, yaw)
	local player = Game.GetPlayer()
	pcall(function()
		Game.GetTeleportationFacility():Teleport(player, Vector4.new(x, y, z, 1.0), EulerAngles.new(0, 0, yaw))
	end)
	MCPT.lastFeet = { x = x, y = y, z = z } -- not a "teleport detected" re-level
end

-- "MaxTac trick": remember where V stands, drop to the street straight below (so the police can register him),
-- raise the heat to 5, and once it's 5 put V back where he was.
local function maxtac_trick()
	local player = Game.GetPlayer()
	if not player then return end
	local p = player:GetWorldPosition()
	local yaw = player:GetWorldYaw()
	local okR, hit, trace = pcall(function()
		return Game.GetSpatialQueriesSystem():SyncRaycastByCollisionGroup(Vector4.new(p.x, p.y, p.z - 3.0, 1),
			Vector4.new(p.x, p.y, p.z - 600.0, 1), "Static", false, false)
	end)
	local streetZ = (okR and hit and trace and trace.position) and trace.position.z or nil
	if not streetZ then log("maxtac: no street found below"); return end
	MCPT.trick = { x = p.x, y = p.y, z = p.z, yaw = yaw, since = MCPT.frame }
	if MCPT.fly then MCPT.fly, MCPT.flyPos, MCPT.flyEndedAt = nil, nil, MCPT.frame; send('{"t":"glide","on":false}') end
	teleport_v(p.x, p.y, streetZ + 0.1, yaw)
	set_heat(5)
	log(string.format("maxtac: down to the street (%.1f m below), heat 5 requested", p.z - streetZ))
end

local function maxtac_tick()
	local t = MCPT.trick
	if not t then return end
	local heat = heat_now()
	-- back up once the heat is 5 and has had a moment to dispatch (or after 6 s whatever happens)
	if (heat >= 5 and MCPT.frame - t.since > 90) or MCPT.frame - t.since > 180 then
		MCPT.trick = nil
		teleport_v(t.x, t.y, t.z + 0.05, t.yaw)
		MCPT.flyEndedAt = MCPT.frame -- don't take the fall onto the pillar for an elytra launch
		log("maxtac: back on the pillar (heat " .. tostring(heat) .. ")")
	end
end

-- Live tuning: mods/mcpassthrough/tune.txt, re-read every second, one "key = value" per line (numbers or true/false),
-- e.g. "fovScale = 1.0". (CET's sandbox has no load(), so it's parsed by hand.)
local function read_tune()
	local f = io.open("tune.txt", "r")
	if not f then return end
	for line in f:lines() do
		local k, v = line:match("^%s*([%w_]+)%s*=%s*([^%s#]+)")
		if k then
			local val
			if v == "true" then val = true elseif v == "false" then val = false else val = tonumber(v) end
			-- only values that changed in the file apply, so hotkey toggles aren't undone every second
			MCPT.tuneSeen = MCPT.tuneSeen or {}
			if val ~= nil and MCPT.tuneSeen[k] ~= val then
				local first = MCPT.tuneSeen[k] == nil
				MCPT.tuneSeen[k] = val
				if k == "maxtac" then
					if not first then maxtac_trick() end
				elseif k == "wanted" then
					-- police heat (0-5; 5 = MaxTac), through the prevention system's own console request
					if not first then
						local ok, err = pcall(function()
							local ps = Game.GetScriptableSystemsContainer():Get("PreventionSystem")
							local req = PreventionConsoleInstructionRequest.new()
							req.instruction = val > 0 and EPreventionSystemInstruction.Active or EPreventionSystemInstruction.Safe
							req.heatStage = EPreventionHeatStage["Heat_" .. math.floor(val)]
							ps:QueueRequest(req)
						end)
						log("wanted level " .. tostring(val) .. " " .. (ok and "" or tostring(err)))
					end
				elseif k == "go" then
					if not first and val > 0 then go_spot(val) end -- a teleport only when "go" changes, not on load
				else
					MCPT[k] = val
					log("tune " .. k .. " = " .. tostring(val))
				end
			end
		end
	end
	f:close()
end

-- Calibration: project a test point with Cyberpunk's own ProjectPoint and with our camera model; log the vertical and
-- horizontal FOV that ProjectPoint implies, so the FOV can be set from measurement instead of guessed.
local function calibrate(cs, pos, fwd, up, fov, bw, bh)
	local right = cs:GetActiveCameraRight()
	local ox, oy, oz = 3.0, 2.0, 10.0 -- metres right, up, forward
	local p = Vector4.new(pos.x + right.x * ox + up.x * oy + fwd.x * oz, pos.y + right.y * ox + up.y * oy + fwd.y * oz,
		pos.z + right.z * ox + up.z * oy + fwd.z * oz, 1)
	local ok, s = pcall(function() return cs:ProjectPoint(p) end)
	if not ok or not s then
		log("calibrate: ProjectPoint failed: " .. tostring(s))
		return
	end
	local vfov = (s.y ~= 0) and math.deg(2 * math.atan((oy / oz) / math.abs(s.y))) or -1
	local hfov = (s.x ~= 0) and math.deg(2 * math.atan((ox / oz) / math.abs(s.x))) or -1
	log(string.format("calibrate: ProjectPoint -> (%.4f, %.4f, %.4f, %.4f); implied vfov %.2f hfov %.2f (aspect %.3f -> vfov %.2f); reported fov %.2f",
		s.x, s.y, s.z, s.w, vfov, hfov, bw / bh, math.deg(2 * math.atan(math.tan(math.rad(hfov) / 2) * bh / bw)), fov))
end

-- V's look: Minecraft draws Steve (and his hand and items) where V is, so V's meshes (body, FPP arms, the weapon in
-- hand) are switched off, and Cyberpunk's HUD is hidden (Minecraft's hotbar replaces it).
local function toggle_meshes(entity, visible)
	if not entity then return 0 end
	local ok, comps = pcall(function() return entity:GetComponents() end)
	if not ok or type(comps) ~= "table" then
		if not MCPT.loggedCompErr then
			MCPT.loggedCompErr = true
			log("GetComponents: ok=" .. tostring(ok) .. " type=" .. type(comps) .. " value=" .. tostring(comps))
		end
		return 0
	end
	if not MCPT.loggedComps then
		MCPT.loggedComps = true
		local names = {}
		for i, c in ipairs(comps) do
			if i > 40 then break end
			local okc, cls = pcall(function() return NameToString(c:GetClassName()) end)
			table.insert(names, okc and tostring(cls) or ("?" .. tostring(cls)))
		end
		log("components (" .. #comps .. "): " .. table.concat(names, ","))
	end
	local n = 0
	for _, c in ipairs(comps) do
		local okc, cls = pcall(function() return NameToString(c:GetClassName()) end)
		if okc and type(cls) == "string" and cls:find("Mesh") then
			if pcall(function() c:Toggle(visible) end) then n = n + 1 end
		end
	end
	return n
end

local function held_items(player)
	local items = {}
	local ts = Game.GetTransactionSystem()
	-- weapons, and the clothing and head items (separate entities attached to V, not V's own meshes)
	for _, slot in ipairs({ "AttachmentSlots.WeaponRight", "AttachmentSlots.WeaponLeft", "AttachmentSlots.Head",
		"AttachmentSlots.Face", "AttachmentSlots.Eyes", "AttachmentSlots.Chest", "AttachmentSlots.Torso",
		"AttachmentSlots.Legs", "AttachmentSlots.Feet", "AttachmentSlots.Outfit", "AttachmentSlots.TppHead",
		"AttachmentSlots.UnderwearTop", "AttachmentSlots.UnderwearBottom", "AttachmentSlots.Splinter" }) do
		local ok, item = pcall(function() return ts:GetItemInSlot(player, TweakDBID.new(slot)) end)
		if ok and item then table.insert(items, item) end
	end
	return items
end

local function set_v_visible(player, visible)
	local n = toggle_meshes(player, visible)
	for _, item in ipairs(held_items(player)) do n = n + toggle_meshes(item, visible) end
	return n
end

-- The HUD goes through Cyberpunk's own interface settings (/interface/hud: every on/off option there). The player's
-- values are saved to hud_backup.txt first, so they come back even if the game closes while hidden.
local HUD_GROUP = "/interface/hud"
local HUD_BACKUP = "hud_backup.txt"

local function hud_vars()
	local vars = {}
	local group = Game.GetSettingsSystem():GetGroup(HUD_GROUP)
	for _, v in ipairs(group:GetVars(false)) do
		local okb, val = pcall(function() return v:GetValue() end)
		if okb and type(val) == "boolean" then
			table.insert(vars, { var = v, name = NameToString(v:GetName()), value = val })
		end
	end
	return vars
end

local function set_hud_visible(visible)
	return pcall(function()
		if not visible then
			if MCPT.hudSaved then return end
			local saved = {}
			local f = io.open(HUD_BACKUP, "w")
			for _, h in ipairs(hud_vars()) do
				saved[h.name] = h.value
				if f then f:write(h.name .. " = " .. tostring(h.value) .. "\n") end
				if h.value then h.var:SetValue(false) end
			end
			if f then f:close() end
			MCPT.hudSaved = saved
			Game.GetSettingsSystem():ConfirmChanges()
		else
			local saved = MCPT.hudSaved
			if not saved then -- after a crash or reload: from the backup file
				local f = io.open(HUD_BACKUP, "r")
				if not f then return end
				saved = {}
				for line in f:lines() do
					local k, v = line:match("^(%S+) = (%a+)")
					if k then saved[k] = (v == "true") end
				end
				f:close()
			end
			for _, h in ipairs(hud_vars()) do
				if saved[h.name] ~= nil and saved[h.name] ~= h.value then h.var:SetValue(saved[h.name]) end
			end
			Game.GetSettingsSystem():ConfirmChanges()
			MCPT.hudSaved = nil
			os.remove(HUD_BACKUP)
		end
	end)
end

-- Clicks belong to Minecraft (attack / use), so V mustn't fight: the game's own no-combat restriction (as in V's
-- apartment) holsters weapons and blocks attacks while the passthrough is on.
local NO_COMBAT = "GameplayRestriction.NoCombat"
local function set_no_combat(player, on)
	return pcall(function()
		local ses = Game.GetStatusEffectSystem()
		if on then
			ses:ApplyStatusEffect(player:GetEntityID(), TweakDBID.new(NO_COMBAT), TweakDBID.new(""), player:GetEntityID())
		else
			ses:RemoveStatusEffect(player:GetEntityID(), TweakDBID.new(NO_COMBAT))
		end
	end)
end

-- Third person on foot: Cyberpunk has none, so the FPP camera is moved back behind V (Minecraft's F5 view).
-- front = true: the camera stands in front of V looking back at him (Minecraft's second F5), turned 180 deg about Z.
local function set_camera_offset(player, back, up, side, front)
	return pcall(function()
		local cam = player:GetFPPCameraComponent()
		if front then
			cam:SetLocalPosition(Vector4.new(-side, back, up, 1.0))
			cam:SetLocalOrientation(Quaternion.new(0.0, 0.0, 1.0, 0.0))
		else
			cam:SetLocalPosition(Vector4.new(side, -back, up, 1.0))
			cam:SetLocalOrientation(Quaternion.new(0.0, 0.0, 0.0, 1.0))
		end
	end)
end

-- Applied every 30 ticks while on (equipment changes and cutscenes bring meshes back); undone once when off.
local function apply_look(player, on)
	if on then
		if MCPT.hideV ~= false then
			local n = set_v_visible(player, false)
			if not MCPT.loggedHide then
				MCPT.loggedHide = true
				log("hid V: " .. n .. " mesh components")
			end
		end
		if MCPT.hideHud ~= false and not MCPT.hudSaved then
			local ok, err = set_hud_visible(false)
			if not MCPT.loggedHud then
				MCPT.loggedHud = true
				local names = {}
				for k in pairs(MCPT.hudSaved or {}) do table.insert(names, k) end
				log("hide HUD: " .. (ok and ("ok, " .. #names .. " options: " .. table.concat(names, ",")) or tostring(err)))
			end
		end
		-- off unless asked for: clicks are captured for Minecraft, and enemies won't fight a no-combat V
		if MCPT.noCombat == true and not MCPT.noCombatOn then
			local ok, err = set_no_combat(player, true)
			MCPT.noCombatOn = ok
			log("no combat: " .. (ok and "on" or tostring(err)))
		elseif MCPT.noCombat ~= true and MCPT.noCombatOn then
			set_no_combat(player, false)
			MCPT.noCombatOn = false
			log("no combat: off")
		end
		if MCPT.thirdPerson then
			set_camera_offset(player, MCPT.tpBack or 4.0, MCPT.tpUp or 0.3, MCPT.tpSide or 0.0, MCPT.frontView)
		elseif MCPT.lookApplied and MCPT.lookApplied.thirdPerson then
			set_camera_offset(player, 0, 0, 0, false)
		end
		MCPT.lookApplied = { thirdPerson = MCPT.thirdPerson, frontView = MCPT.frontView }
	elseif MCPT.lookApplied then
		set_v_visible(player, true)
		set_hud_visible(true)
		set_camera_offset(player, 0, 0, 0, false)
		if MCPT.noCombatOn then
			set_no_combat(player, false)
			MCPT.noCombatOn = false
		end
		MCPT.lookApplied = nil
		MCPT.loggedHide, MCPT.loggedHud = false, false
		log("V, HUD and camera restored")
	end
end

-- Clicks, wheel and number keys go to Minecraft: left = attack (swing, break), right = use (pearl, place, shoot),
-- wheel / 1-9 = hotbar. Read by the plugin only while Cyberpunk has the focus; ignored while the CET overlay is open.
local function in_menu()
	local ok, v = pcall(function()
		local defs = GetAllBlackboardDefs().UI_System
		return Game.GetBlackboardSystem():Get(defs):GetBool(defs.IsInMenu)
	end)
	return ok and v == true
end

local function forward_input()
	-- capture (Cyberpunk doesn't see the clicks and wheel) only in gameplay: not in a menu or an overlay
	local menu = in_menu()
	local capture = MCPT.captureMouse ~= false and not MCPT.overlayOpen and not menu
	if capture ~= MCPT.capturing then
		MCPT.capturing = capture
		log(string.format("mouse capture %s (menu %s, overlay %s)", tostring(capture), tostring(menu), tostring(MCPT.overlayOpen)))
	end
	local ok, s = pcall(function() return Game.MCPT_Input(capture and "1" or "0") end)
	if not ok then -- an older plugin takes no argument
		ok, s = pcall(function() return Game.MCPT_Input() end)
	end
	if not ok or type(s) ~= "string" then return end
	local focused, lmb, rmb, wheel, keys = s:match("(%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+)")
	focused, lmb, rmb, wheel, keys = focused == "1", lmb == "1", rmb == "1", tonumber(wheel), tonumber(keys)
	-- raw mouse counts since the last tick (newer plugin): flight steering uses them
	local mdx = s:match("^%S+ %S+ %S+ %S+ %S+ (%-?%d+)")
	MCPT.mouseDx = tonumber(mdx) or 0
	if MCPT.overlayOpen or not focused then lmb, rmb, wheel, keys = false, false, 0, 0 end
	local prev = MCPT.input or { lmb = false, rmb = false, keys = 0 }
	if rmb ~= prev.rmb then log("right button " .. tostring(rmb) .. " (input " .. s .. ")") end
	if lmb ~= prev.lmb then send(string.format('{"t":"key","k":"attack","down":%s}', lmb and "true" or "false")) end
	if rmb ~= prev.rmb then send(string.format('{"t":"key","k":"use","down":%s}', rmb and "true" or "false")) end
	if wheel ~= 0 then
		-- wheel up = previous slot, as in Minecraft
		for _ = 1, math.abs(wheel) do send(string.format('{"t":"scroll","d":%d}', wheel > 0 and -1 or 1)) end
	end
	for i = 0, 8 do
		local bit = 2 ^ i
		local down = math.floor(keys / bit) % 2 == 1
		local was = math.floor(prev.keys / bit) % 2 == 1
		if down and not was then send(string.format('{"t":"slot","n":%d}', i)) end
	end
	MCPT.input = { lmb = lmb, rmb = rmb, keys = keys }
end

-- V crouching -> Steve sneaks. The locomotion state reads "crouch" (1) only for the moment V starts crouching, so it's
-- measured instead: V's eye height above his feet (camera height less the third-person lift) drops when crouched.
local function forward_crouch(player, feet, cam)
	local eye = cam.z - feet.z - (MCPT.thirdPerson and (MCPT.tpUp or 0.3) or 0)
	-- crouched eyes measured ~1.25 m, standing ~1.36-1.41: crouch below 1.31, stand again above 1.33 (no flicker)
	local crouch
	if MCPT.sneaking then crouch = eye < (MCPT.standEye or 1.33) else crouch = eye < (MCPT.crouchEye or 1.31) end
	if MCPT.frame % 30 == 0 and MCPT.logEye then log(string.format("eye height %.2f", eye)) end
	if crouch ~= (MCPT.sneaking or false) then
		log(string.format("crouch %s (eye height %.2f)", tostring(crouch), eye))
		MCPT.sneaking = crouch
		send(string.format('{"t":"key","k":"sneak","down":%s}', crouch and "true" or "false"))
	end
end

-- Night City's ground becomes Minecraft collision: the ground under block columns round V is found with downward
-- raycasts and sent as barrier columns (3 blocks thick, top at the street), nearest first, a few dozen per tick.
local GROUND_RADIUS, GROUND_PER_TICK = 20, 40
local ground_offsets = nil

local function ground_ring()
	if ground_offsets then return ground_offsets end
	ground_offsets = {}
	for dx = -GROUND_RADIUS, GROUND_RADIUS do
		for dz = -GROUND_RADIUS, GROUND_RADIUS do
			if dx * dx + dz * dz <= GROUND_RADIUS * GROUND_RADIUS then table.insert(ground_offsets, { dx, dz, dx * dx + dz * dz }) end
		end
	end
	table.sort(ground_offsets, function(a, b) return a[3] < b[3] end)
	return ground_offsets
end

-- Cyberpunk's ground height under (x, y), searching down from just above V's feet; nil if none.
local function ground_at(x, y, feetZ)
	local from = Vector4.new(x, y, feetZ + 2.5, 1)
	local to = Vector4.new(x, y, feetZ - 40.0, 1)
	local ok, hit, trace = pcall(function()
		return Game.GetSpatialQueriesSystem():SyncRaycastByCollisionGroup(from, to, MCPT.groundGroup or "Static", false, false)
	end)
	if not MCPT.loggedRay then
		MCPT.loggedRay = true
		log(string.format("ground raycast: ok=%s hit=%s trace=%s", tostring(ok), tostring(hit), tostring(trace and trace.position)))
	end
	if ok and hit and trace and trace.position then return trace.position.z end
	return nil
end

local function sample_ground(feet)
	if MCPT.groundOff then return end
	MCPT.groundDone = MCPT.groundDone or {}
	MCPT.groundMiss = MCPT.groundMiss or {}
	local bx, bz = math.floor(feet.x), math.floor(-feet.y)
	local cols, probes = {}, 0
	for _, o in ipairs(ground_ring()) do
		local x, z = bx + o[1], bz + o[2]
		local key = x .. ":" .. z
		-- columns with no ground in reach (V high up, gliding) are tried again later, not given up on
		if not MCPT.groundDone[key] and not (MCPT.groundMiss[key] and MCPT.frame - MCPT.groundMiss[key] < 45) then
			probes = probes + 1
			local gz = ground_at(x + 0.5, -(z + 0.5), feet.z)
			if gz then
				MCPT.groundDone[key] = true
				MCPT.groundMiss[key] = nil
				local top = math.floor(gz + MCPT.yoff + 0.5) - 1
				table.insert(cols, string.format("%d,%d,%d,%d", x, z, top - 2, top))
			else
				MCPT.groundMiss[key] = MCPT.frame
			end
			if probes >= GROUND_PER_TICK then break end
		end
	end
	if #cols > 0 then send('{"t":"ground","c":[' .. table.concat(cols, ",") .. ']}') end
end

-- Minecraft -> Cyberpunk. Minecraft coordinates (x, y, z) -> Cyberpunk (x, -z, y - yoff).
local function to_cp(x, y, z)
	return x, -z, y - MCPT.yoff
end

local function nums(s)
	local t = {}
	for v in s:gmatch("[-%d%.eE]+") do table.insert(t, tonumber(v)) end
	return t
end

-- Ender pearl: Minecraft teleported Steve -> V goes there.
local function on_pteleport(msg, player)
	local p = msg:match('"pos":%[([^%]]+)%]')
	if not p then return end
	local v = nums(p)
	local x, y, z = to_cp(v[1], v[2], v[3])
	-- Minecraft lands on barrier tops (whole blocks), which can be a little under the real street: stand V on
	-- Cyberpunk's own ground there (searched from 2 m above), or drop him from half a metre up if none is found
	local gz = ground_at(x, y, z)
	if gz and math.abs(gz - z) < 2.5 then z = gz + 0.05 else z = z + 0.5 end
	local ok, err = pcall(function()
		Game.GetTeleportationFacility():Teleport(player, Vector4.new(x, y, z, 1.0), EulerAngles.new(0, 0, player:GetWorldYaw()))
	end)
	MCPT.lastFeet = { x = x, y = y, z = z } -- not a "teleport detected" re-level: Minecraft already knows
	log(string.format("ender pearl: V -> (%.1f, %.1f, %.1f) %s", x, y, z, ok and "" or tostring(err)))
end

-- Minecraft-style hit feedback at a Cyberpunk position: the hit sound and particles, played in Minecraft there.
local function hit_feedback(pos, sound, particle)
	local mx, my, mz = pos.x, pos.z + MCPT.yoff, -pos.y
	send(string.format('{"t":"cmd","c":"playsound %s player @a %.2f %.2f %.2f 1 1"}', sound, mx, my + 1, mz))
	send(string.format('{"t":"cmd","c":"particle %s %.2f %.2f %.2f 0.3 0.5 0.3 0.15 18 force"}', particle, mx, my + 1.1, mz))
end

-- A real Cyberpunk explosion at a Cyberpunk position (the native explosion attack the game's exploding bullets use).
local function explode_at(player, x, y, z, big)
	local ok, err = pcall(function()
		local rec = TweakDB:GetRecord(big and (MCPT.bigBlast or "Attacks.LegendaryFragGrenade") or (MCPT.smallBlast or "Attacks.FragGrenade"))
		GetSingleton("gameAttack_GameEffect"):SpawnExplosionAttack(rec, nil, player, player, Vector4.new(x, y, z, 1.0), 1.0)
	end)
	log(string.format("explosion %s at (%.1f, %.1f, %.1f) %s", big and "big" or "small", x, y, z, ok and "" or tostring(err)))
end

-- Knock an NPC away from a point: ragdoll now, the push next frame (as CET jetpack mods do).
local function knock_npc(npc, from, force, up)
	pcall(function()
		if not (ScriptedPuppet.CanRagdoll(npc) and npc:CanEnableRagdollComponent()) then return end
		local p = npc:GetWorldPosition()
		local d = Vector4.Normalize(Vector4.new(p.x - from.x, p.y - from.y, 0, 0))
		npc:QueueEvent(CreateForceRagdollEvent(CName.new("MinecraftHit")))
		Game.GetDelaySystem():DelayEventNextFrame(npc,
			CreateRagdollApplyImpulseEvent(p, Vector4.new(d.x * force, d.y * force, up, 1), 5))
	end)
end

-- Minecraft explosion (TNT, creeper, firework): {"t":"explosion","pos":[x,y,z],"r":radius,...} -> Cyberpunk's.
local function on_explosion(msg, player)
	local p = msg:match('"pos":%[([^%]]+)%]')
	local r = tonumber(msg:match('"r":([-%d%.]+)')) or 3
	if not p then return end
	local v = nums(p)
	local x, y, z = to_cp(v[1], v[2], v[3])
	explode_at(player, x, y, z, r >= 3.5)
end

-- Damage an NPC by a share of its health (perc mode: the plain-amount call did nothing visible). The killing blow
-- launches them (ragdoll + push); hits before that only hurt (a forced ragdoll alone was lethal: "instakills").
local function npc_health(npc)
	local ok, hp = pcall(function()
		return Game.GetStatPoolsSystem():GetStatPoolValue(npc:GetEntityID(), gamedataStatPoolType.Health, true)
	end)
	return ok and hp or nil
end

local function damage_npc(npc, player, percent, from, force, lift)
	local before = npc_health(npc)
	pcall(function()
		Game.GetStatPoolsSystem():RequestChangingStatPoolValue(npc:GetEntityID(), gamedataStatPoolType.Health, -percent, player, false, true)
	end)
	local lethal = before ~= nil and before - percent <= 0.5
	if lethal and from then knock_npc(npc, from, force, lift) end
	return before, lethal
end

-- Sword swing: the NPC V looks at, within reach, takes damage and is knocked down.
local function on_melee(player)
	local ok, err = pcall(function()
		local target = Game.GetTargetingSystem():GetLookAtObject(player, false, false)
		if not target or not target:IsNPC() then return end
		local d = Vector4.Distance(player:GetWorldPosition(), target:GetWorldPosition())
		if d > (MCPT.swordReach or 4.0) then return end
		local before, lethal = damage_npc(target, player, MCPT.swordDamage or 34.0, player:GetWorldPosition(), MCPT.swordForce or 9.0,
			MCPT.swordLift or 3.0)
		hit_feedback(target:GetWorldPosition(), "minecraft:entity.player.attack.crit", "minecraft:crit")
		do -- and the damage hearts, as on arrow hits
			local tp = target:GetWorldPosition()
			send(string.format('{"t":"cmd","c":"particle minecraft:damage_indicator %.2f %.2f %.2f 0.3 0.4 0.3 0.1 8 force"}',
				tp.x, tp.z + MCPT.yoff + 1.3, -tp.y))
		end
		log(string.format("sword hit %s at %.1f m (health %s%%%s)", tostring(target:GetDisplayName()), d,
			before and string.format("%.0f", before) or "?", lethal and ", killing blow" or ""))
	end)
	if not ok then log("sword: " .. tostring(err)) end
end

-- Cyberpunk segment raycast against the world (buildings, ground): hit position (Vector4-like) or nil.
local function ray(from, to)
	local ok, hit, trace = pcall(function()
		return Game.GetSpatialQueriesSystem():SyncRaycastByCollisionGroup(Vector4.new(from.x, from.y, from.z, 1),
			Vector4.new(to.x, to.y, to.z, 1), MCPT.groundGroup or "Static", false, false)
	end)
	if ok and hit and trace and trace.position then return trace.position end
	return nil
end

local function mc_to_vec(x, y, z)
	local cx, cy, cz = to_cp(x, y, z)
	return { x = cx, y = cy, z = cz }
end

-- NPCs around V (refreshed twice a second) for arrow hits.
local function nearby_npcs(player)
	if MCPT.npcsAt and MCPT.frame - MCPT.npcsAt < 15 then return MCPT.npcs or {} end
	MCPT.npcsAt = MCPT.frame
	local list = {}
	local ok, err = pcall(function()
		-- (source, query) in 2.31; the parts come back as an extra result (CET returns out-params)
		local r1, r2 = Game.GetTargetingSystem():GetTargetParts(player, TSQ_NPC())
		local parts = type(r2) == "table" and r2 or (type(r1) == "table" and r1 or {})
		if not MCPT.loggedNpcCount then MCPT.loggedNpcCount = true; log("npc search: " .. #parts .. " target parts") end
		for _, part in ipairs(parts) do
			local e = TS_TargetPartInfo.GetComponent(part):GetEntity()
			if e and e:IsNPC() then list[tostring(e:GetEntityID().hash)] = e end
		end
	end)
	if not ok and not MCPT.loggedNpcErr then MCPT.loggedNpcErr = true; log("npc search: " .. tostring(err)) end
	MCPT.npcs = {}
	for _, e in pairs(list) do table.insert(MCPT.npcs, e) end
	return MCPT.npcs
end

-- the NPC whose body (a 0.5 m x 1.9 m capsule-ish column) the segment passes through, if any
local function npc_on_segment(player, a, b)
	local best, bestT = nil, 2
	for _, npc in ipairs(nearby_npcs(player)) do
		local ok, p = pcall(function() return npc:GetWorldPosition() end)
		if ok and p then
			local dx, dy = b.x - a.x, b.y - a.y
			local len2 = dx * dx + dy * dy
			local t = len2 > 1e-6 and math.max(0, math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) or 0
			local cx, cy, cz = a.x + dx * t, a.y + dy * t, a.z + (b.z - a.z) * t
			if (cx - p.x) ^ 2 + (cy - p.y) ^ 2 < 0.45 * 0.45 and cz > p.z - 0.1 and cz < p.z + 1.95 and t < bestT then
				best, bestT = npc, t
			end
		end
	end
	return best, bestT
end

-- Pearl hit a Cyberpunk surface: V stands just in front of it (on the ground below that point).
local function pearl_hit(player, hit, a)
	local dx, dy, dz = hit.x - a.x, hit.y - a.y, hit.z - a.z
	local len = math.max(math.sqrt(dx * dx + dy * dy + dz * dz), 1e-3)
	local x, y, z = hit.x - dx / len * 0.6, hit.y - dy / len * 0.6, hit.z - dz / len * 0.6
	local gz = ground_at(x, y, z)
	if gz and gz <= z + 0.5 then z = gz + 0.05 end
	pcall(function()
		Game.GetTeleportationFacility():Teleport(player, Vector4.new(x, y, z, 1.0), EulerAngles.new(0, 0, player:GetWorldYaw()))
	end)
	MCPT.lastFeet = { x = x, y = y, z = z }
	log(string.format("ender pearl hit Night City: V -> (%.1f, %.1f, %.1f)", x, y, z))
end

-- {"t":"proj","p":[[id,kind,x,y,z],...]} every Minecraft tick: trace each projectile's step through Night City.
local function on_proj(msg, player)
	MCPT.proj = MCPT.proj or {}
	local seen = {}
	for id, kind, x, y, z in msg:gmatch('%[(%-?%d+),"(%a+)",([-%d%.eE]+),([-%d%.eE]+),([-%d%.eE]+)%]') do
		id = tonumber(id)
		seen[id] = true
		local now = mc_to_vec(tonumber(x), tonumber(y), tonumber(z))
		local prev = MCPT.proj[id]
		MCPT.proj[id] = { pos = now, frame = MCPT.frame, kind = kind }
		if prev and not prev.done then
			local npc, t = nil, 2
			if kind == "arrow" then npc, t = npc_on_segment(player, prev.pos, now) end
			local hit = ray(prev.pos, now)
			local hitT = 2
			if hit then
				local seg = math.max(math.sqrt((now.x - prev.pos.x) ^ 2 + (now.y - prev.pos.y) ^ 2 + (now.z - prev.pos.z) ^ 2), 1e-3)
				hitT = math.sqrt((hit.x - prev.pos.x) ^ 2 + (hit.y - prev.pos.y) ^ 2 + (hit.z - prev.pos.z) ^ 2) / seg
			end
			if npc and t <= hitT then
				local before, lethal = damage_npc(npc, player, MCPT.arrowDamage or 40.0, prev.pos, 6.0, 2.0)
				log(string.format("arrow damage: health %s%%%s", before and string.format("%.0f", before) or "?", lethal and ", killed" or ""))
				send(string.format('{"t":"projhit","id":%d,"pos":[%.3f,%.3f,%.3f],"stick":false}', id, now.x, now.z + MCPT.yoff, -now.y))
				MCPT.proj[id].done = true
				pcall(hit_feedback, npc:GetWorldPosition(), "minecraft:entity.arrow.hit", "minecraft:damage_indicator")
				log("arrow hit " .. tostring(npc:GetDisplayName()))
			elseif hit then
				local mx, my, mz = hit.x, hit.z + MCPT.yoff, -hit.y
				if kind == "pearl" then pearl_hit(player, hit, prev.pos) end
				if kind == "firework" then explode_at(player, hit.x, hit.y, hit.z, false) end
				send(string.format('{"t":"projhit","id":%d,"pos":[%.3f,%.3f,%.3f],"stick":%s}', id, mx, my, mz, kind == "arrow" and "true" or "false"))
				MCPT.proj[id].done = true
				if kind ~= "pearl" then log(kind .. " hit Night City at " .. string.format("(%.1f, %.1f, %.1f)", hit.x, hit.y, hit.z)) end
			end
		end
	end
	for id, p in pairs(MCPT.proj) do
		if MCPT.frame - p.frame > 60 then MCPT.proj[id] = nil end
	end
end

-- The surface under the crosshair (within Minecraft's reach) gets an invisible Minecraft block just inside it, so
-- Minecraft can target it: blocks can be placed on walls, pillars and ledges, not only on the ground.
local function aim_surface(player, feet, fwd)
	fwd = MCPT.aimDir or fwd -- third person: Steve's aim at the crosshair, not the camera's parallel line
	local eye = { x = feet.x, y = feet.y, z = feet.z + 1.62 }
	local reach = MCPT.reach or 5.0
	local hit = ray(eye, { x = eye.x + fwd.x * reach, y = eye.y + fwd.y * reach, z = eye.z + fwd.z * reach })
	if not hit then return end
	local ix, iy, iz = hit.x + fwd.x * 0.05, hit.y + fwd.y * 0.05, hit.z + fwd.z * 0.05 -- just inside the surface
	local bx, by, bz = math.floor(ix), math.floor(iz + MCPT.yoff), math.floor(-iy)
	local key = bx .. ":" .. by .. ":" .. bz
	MCPT.wallDone = MCPT.wallDone or {}
	if MCPT.wallDone[key] then return end
	MCPT.wallDone[key] = true
	send(string.format('{"t":"ground","c":[%d,%d,%d,%d]}', bx, bz, by, by))
end

-- Minecraft blocks become solid for V: each one gets an invisible static entity with a 1 m box collider (World
-- Builder's empty entity + a collider added as it initialises, observed through our redscript hook).
local EMPTY_ENT = "base\\spawner\\empty_entity.ent"
local BLOCK_TAG = "MCPT_Block"
local MAX_BLOCKS = 400

local function add_collider(ent)
	local comp = entColliderComponent.new()
	comp.name = CName.new("mcpt_box")
	local box = physicsColliderBox.new()
	box.halfExtents = Vector3.new(0.5, 0.5, 0.5)
	box.material = CName.new("concrete.physmat")
	comp.colliders = { box }
	local f = physicsFilterData.new()
	local q = physicsQueryFilter.new(); q.mask1 = 0; q.mask2 = 70107400
	local s = physicsSimulationFilter.new(); s.mask1 = 114696; s.mask2 = 23627
	f.queryFilter = q
	f.simulationFilter = s
	if MCPT.colliderPreset then f.preset = CName.new(MCPT.colliderPreset) end
	comp.filterData = f
	ent:AddComponent(comp)
end

local function block_key(x, y, z) return x .. ":" .. y .. ":" .. z end

local function spawn_block(x, y, z)
	MCPT.blocks = MCPT.blocks or {}
	MCPT.blockPending = MCPT.blockPending or {}
	local key = block_key(x, y, z)
	if MCPT.blocks[key] then return end
	if (MCPT.blockCount or 0) >= MAX_BLOCKS then
		if not MCPT.loggedBlockCap then MCPT.loggedBlockCap = true; log("block collision: cap of " .. MAX_BLOCKS .. " reached") end
		return
	end
	local cx, cy, cz = to_cp(x + 0.5, y + 0.5, z + 0.5)
	local ok, id = pcall(function()
		local spec = StaticEntitySpec.new()
		spec.templatePath = EMPTY_ENT
		spec.position = Vector4.new(cx, cy, cz, 1.0)
		spec.orientation = EulerAngles.new(0, 0, 0):ToQuat()
		spec.attached = true
		spec.tags = { CName.new(BLOCK_TAG) }
		return Game.GetStaticEntitySystem():SpawnEntity(spec)
	end)
	if not ok or not id then
		if not MCPT.loggedSpawnErr then MCPT.loggedSpawnErr = true; log("block spawn failed: " .. tostring(id)) end
		return
	end
	MCPT.blocks[key] = id
	MCPT.blockPending[tostring(id.hash)] = true
	MCPT.blockCount = (MCPT.blockCount or 0) + 1
end

local function despawn_block(x, y, z)
	local key = block_key(x, y, z)
	local id = MCPT.blocks and MCPT.blocks[key]
	if not id then return end
	pcall(function() Game.GetStaticEntitySystem():DespawnEntity(id) end)
	MCPT.blocks[key] = nil
	MCPT.blockCount = math.max(0, (MCPT.blockCount or 1) - 1)
end

local function despawn_all_blocks()
	pcall(function() Game.GetStaticEntitySystem():DespawnTagged(CName.new(BLOCK_TAG)) end)
	MCPT.blocks, MCPT.blockPending, MCPT.blockCount, MCPT.loggedBlockCap = {}, {}, 0, false
end

-- {"t":"blocks","set":[x,y,z,...],"clear":[x,y,z,...]}
local function on_blocks(msg)
	local set = msg:match('"set":%[([^%]]*)%]') or ""
	local clear = msg:match('"clear":%[([^%]]*)%]') or ""
	local s, c = nums(set), nums(clear)
	for i = 1, #c - 2, 3 do despawn_block(c[i], c[i + 1], c[i + 2]) end
	for i = 1, #s - 2, 3 do spawn_block(s[i], s[i + 1], s[i + 2]) end
	if #s > 0 and not MCPT.loggedBlocks then
		MCPT.loggedBlocks = true
		log("block collision: spawning " .. math.floor(#s / 3) .. " (total " .. (MCPT.blockCount or 0) .. ")")
	end
end

-- Elytra. Take-off: V falling fast with a long drop below. Minecraft's elytra physics then fly Steve ("drive" mode),
-- each tick V is put where Steve is ({"t":"mcpos"}), the camera chases from behind and the mouse steers; fireworks
-- boost (Minecraft's own). When Steve stops gliding, Cyberpunk takes V back.
local function fly_start(player, feet)
	MCPT.fly = { since = MCPT.frame, view = { MCPT.thirdPerson, MCPT.frontView } }
	MCPT.flyYaw = player:GetWorldYaw() -- the flight heading (Cyberpunk yaw), turned by the mouse from here on
	MCPT.thirdPerson, MCPT.frontView = true, false
	send(string.format('{"t":"glide","on":true,"speed":%.2f}', MCPT.glideSpeed or 1.2))
	log(string.format("elytra: take-off at (%.1f, %.1f, %.1f)", feet.x, feet.y, feet.z))
end

local function fly_end(reason)
	if not MCPT.fly then return end
	MCPT.thirdPerson, MCPT.frontView = MCPT.fly.view[1], MCPT.fly.view[2]
	MCPT.fly = nil
	MCPT.flyPos = nil
	MCPT.flyEndedAt = MCPT.frame
	send('{"t":"glide","on":false}')
	-- landing swaps the elytra for an empty chest slot: Steve gets his diamond chestplate back
	send('{"t":"cmd","c":"item replace entity @a armor.chest with minecraft:diamond_chestplate"}')
	log("elytra: landed (" .. reason .. ")")
end

-- {"t":"mcpos","pos":[x,y,z],"vel":[...],"tn":...,"fly":bool}: where Minecraft flies Steve
local function on_mcpos(msg)
	if not MCPT.fly then return end
	local p = msg:match('"pos":%[([^%]]+)%]')
	if not p then return end
	local v = nums(p)
	MCPT.flyPos = { mc = v, fly = msg:find('"fly":true', 1, true) ~= nil, frame = MCPT.frame }
end

-- per tick: take-off check, or V follows Steve while flying
local function fly_tick(player, feet)
	if MCPT.elytra == false then return end
	if not MCPT.fly then
		local prev = MCPT.flyPrevZ
		MCPT.flyPrevZ = feet.z
		if not prev or (MCPT.flyEndedAt and MCPT.frame - MCPT.flyEndedAt < 60) then return end -- no re-launch loop
		local drop = prev - feet.z
		local fall = drop * 30 -- m/s at ~30 ticks/s (approximate)
		-- a falling V (not a teleport: those move metres in one tick)
		if fall > (MCPT.flyFallSpeed or 5.0) and drop < 3.0 then
			local gz = ground_at(feet.x, feet.y, feet.z - 2.5) -- searches from just below V's feet
			if not gz or feet.z - gz > (MCPT.flyMinHeight or 8.0) then fly_start(player, feet) end
		end
		return
	end
	local fp = MCPT.flyPos
	if fp then
		local x, y, z = to_cp(fp.mc[1], fp.mc[2], fp.mc[3])
		-- Night City's ground wins: where Minecraft has no ground (yet), Steve would sink and pull V through the
		-- street. Touching Cyberpunk's ground lands the flight there.
		local gz = ground_at(x, y, z + 0.5)
		if gz and z < gz + 0.3 then
			pcall(function()
				Game.GetTeleportationFacility():Teleport(player, Vector4.new(x, y, gz + 0.05, 1.0), EulerAngles.new(0, 0, player:GetWorldYaw()))
			end)
			MCPT.lastFeet = { x = x, y = y, z = gz + 0.05 }
			fly_end("touched Night City's ground")
			return
		end
		-- Cyberpunk's camera can't turn while V is teleported every tick (its yaw stays frozen), so the heading is
		-- turned by the raw mouse counts instead (mouse right = clockwise = lower Cyberpunk yaw)
		MCPT.flyYaw = (MCPT.flyYaw or player:GetWorldYaw()) - (MCPT.mouseDx or 0) * (MCPT.flySens or 0.06)
		MCPT.flyYaw = (MCPT.flyYaw + 180) % 360 - 180
		local heading = MCPT.flyYaw
		pcall(function()
			Game.GetTeleportationFacility():Teleport(player, Vector4.new(x, y, z, 1.0), EulerAngles.new(0, 0, heading))
		end)
		MCPT.lastFeet = { x = x, y = y, z = z }
		-- landed: Minecraft says Steve isn't gliding any more (after the first second of the flight)
		if not fp.fly and MCPT.frame - MCPT.fly.since > 30 then fly_end("on the ground") end
	elseif MCPT.frame - MCPT.fly.since > 90 then
		fly_end("no flight data from Minecraft")
	end
end

-- No fall damage for V while Steve is out (his landings are Minecraft's; Cyberpunk's damage is mirrored to him).
local function set_fall_immunity(player, on)
	pcall(function()
		local ss = Game.GetStatsSystem()
		if on and not MCPT.fallMod then
			MCPT.fallMod = RPGManager.CreateStatModifier(gamedataStatType.FallDamageReduction, gameStatModifierType.Additive, 1.0)
			ss:AddModifier(player:GetEntityID(), MCPT.fallMod)
		elseif not on and MCPT.fallMod then
			ss:RemoveModifier(player:GetEntityID(), MCPT.fallMod)
			MCPT.fallMod = nil
		end
	end)
end

-- Health is one value shown in both games: V's share of his health = Steve's share of his hearts. Whichever side
-- changed since the last sync wins (Cyberpunk damage -> Steve; TNT/creeper/Minecraft damage -> V); 0 kills either.
local function sync_health(player)
	local ok, hp = pcall(function()
		return Game.GetStatPoolsSystem():GetStatPoolValue(player:GetEntityID(), gamedataStatPoolType.Health, true)
	end)
	if not ok or type(hp) ~= "number" then return end
	local v = math.max(0, math.min(1, hp / 100))
	local sendV = function(f)
		MCPT.hpSync = f
		send(string.format('{"t":"health","f":%.4f}', f))
	end
	if MCPT.hpSync == nil then sendV(v) return end -- (re)connected: Steve takes V's health
	if v <= 0 then
		-- V is dead: Steve dies once; his respawn doesn't revive V (the game's own death/reload does that)
		if not MCPT.vDead then MCPT.vDead = true; sendV(0); log("health: V died -> Steve dies") end
		MCPT.mcHealth = nil
		return
	end
	if MCPT.vDead then MCPT.vDead = false; sendV(v) return end -- V is back (save reloaded)
	if math.abs(v - MCPT.hpSync) > 0.005 then sendV(v) return end -- Cyberpunk changed V's health
	local mc = MCPT.mcHealth
	MCPT.mcHealth = nil
	if mc and math.abs(mc - MCPT.hpSync) > 0.005 then -- Minecraft changed Steve's health
		MCPT.hpSync = mc
		pcall(function()
			Game.GetStatPoolsSystem():RequestSettingStatPoolValue(player:GetEntityID(), gamedataStatPoolType.Health, mc * 100, player, true)
		end)
		if mc <= 0 then log("health: Steve died -> V dies") end
	end
end

local function handle_event(msg, player)
	if msg:find('"t":"mcpos"', 1, true) then on_mcpos(msg) return end
	if msg:find('"t":"mchealth"', 1, true) then MCPT.mcHealth = tonumber(msg:match('"f":([-%d%.]+)')) return end
	if msg:find('"t":"proj"', 1, true) then on_proj(msg, player)
	elseif msg:find('"t":"blocks"', 1, true) then on_blocks(msg)
	elseif msg:find('"t":"explosion"', 1, true) then on_explosion(msg, player)
	elseif msg:find('"t":"pteleport"', 1, true) then on_pteleport(msg, player)
	elseif msg:find('"t":"melee"', 1, true) then on_melee(player)
	elseif msg:find('"t":"hello"', 1, true) then log("hello from Minecraft: " .. msg)
	end
end

local function tick()
	local okStatus, status = pcall(function() return Game.MCPT_Status() end)
	if not okStatus or type(status) ~= "string" then
		if MCPT.plugin then log("plugin not answering") end
		MCPT.plugin = false
		return
	end
	if not MCPT.plugin then
		MCPT.plugin = true
		log("plugin found")
	end
	local connected, gen, bw, bh = status:match("(%d+) (%d+) (%d+) (%d+)")
	connected, gen, bw, bh = connected == "1", tonumber(gen), tonumber(bw), tonumber(bh)

	local player = in_game()
	local gameState = player and "playing" or "paused/no player"
	if gameState ~= MCPT.gameStateWas then MCPT.gameStateWas = gameState; log("game state: " .. gameState) end
	if not player or not connected or not MCPT.active then
		if player and MCPT.lookApplied then apply_look(player, false) end
		pose(false, 0, 0, 0, 60, 0, 0, 0)
		return
	end

	-- a game menu (pause, map, inventory, journal): no Minecraft over it, but V stays hidden (no HUD/look flip-flop)
	local menuNow = in_menu()
	if menuNow ~= MCPT.menuWas then
		MCPT.menuWas = menuNow
		local okP, paused = pcall(function() return Game.GetTimeSystem():IsPausedState() end)
		log(string.format("menu state: in menu %s, paused %s", tostring(menuNow), tostring(okP and paused)))
	end
	if menuNow then
		pose(false, 0, 0, 0, 60, 0, 0, 0)
		return
	end

	local feet = player:GetWorldPosition()
	-- the main menu and loading screens have a stand-in player at the world origin: wait for a real position
	if math.abs(feet.x) < 1 and math.abs(feet.y) < 1 then
		pose(false, 0, 0, 0, 60, 0, 0, 0)
		return
	end
	if gen ~= MCPT.gen then
		MCPT.gen = gen
		MCPT.viewSent = ""
		MCPT.yoff = nil
		MCPT.sneaking, MCPT.input = nil, nil -- a new Minecraft: send held keys again
		MCPT.hpSync, MCPT.vDead = nil, false -- and give Steve V's health
		MCPT.armorAt = MCPT.frame + 60 -- after the mod's own join setup (hotbar)
		log("Minecraft link up (generation " .. gen .. ")")
	end
	-- a save load or fast travel moves V far in one tick: start over there
	if MCPT.lastFeet then
		local dx, dy, dz = feet.x - MCPT.lastFeet.x, feet.y - MCPT.lastFeet.y, feet.z - MCPT.lastFeet.z
		if dx * dx + dy * dy + dz * dz > 50 * 50 then
			log(string.format("teleport detected (%.0f m)", math.sqrt(dx * dx + dy * dy + dz * dz)))
			MCPT.yoff = nil
		end
	end
	MCPT.lastFeet = { x = feet.x, y = feet.y, z = feet.z }
	if MCPT.yoff == nil then
		-- Minecraft y = Cyberpunk z - 20 (whole blocks), plus the fraction that puts the ground under V on a block
		-- boundary: Night City's streets (~0-20 m) land near y 0 and its roofs (up to ~340 m) under y 320, all
		-- inside Minecraft's -64..320, and blocks don't jump by whole metres when V travels.
		MCPT.yoff = (MCPT.yBase or -20) + (math.floor(feet.z + 0.5) - feet.z)
		MCPT.groundDone, MCPT.wallDone = {}, {} -- a new level: Minecraft clears the old barriers, probe again
		-- the blocks' Cyberpunk positions moved with the level: rebuild their collision from Minecraft's list
		despawn_all_blocks()
		MCPT.blockSyncAt = MCPT.frame + 20
		send('{"t":"clear"}')
		log(string.format("levelled at V (%.1f, %.1f, %.1f), yoff %.3f", feet.x, feet.y, feet.z, MCPT.yoff))
	end

	-- Minecraft's window = Cyberpunk's picture, up to ~1080p worth of pixels
	if bw > 0 and bh > 0 then
		local scale = math.min(1, math.sqrt(MCPT.maxPixels / (bw * bh)))
		local view = string.format('{"t":"view","w":%d,"h":%d}', math.floor(bw * scale + 0.5), math.floor(bh * scale + 0.5))
		if view ~= MCPT.viewSent then
			MCPT.viewSent = view
			send(view)
		end
	end

	local pos, fwd, up, fov = camera()
	if not pos then return end
	if MCPT.frame % 60 == 0 then read_tune() end
	if MCPT.frame % 120 == 0 and (MCPT.calibrations or 0) < 2 then
		MCPT.calibrations = (MCPT.calibrations or 0) + 1
		calibrate(Game.GetCameraSystem(), pos, fwd, up, fov, bw, bh)
	end
	if MCPT.fovIsHorizontal and bw > 0 and bh > 0 then
		fov = math.deg(2 * math.atan(math.tan(math.rad(fov) / 2) * bh / bw))
	end
	fov = fov * (MCPT.fovScale or 1.0)
	if not MCPT.loggedFov then
		MCPT.loggedFov = true
		local okf, fpp = pcall(function() return player:GetFPPCameraComponent():GetFOV() end)
		log(string.format("camera fov %.2f (fpp component %s), backbuffer %dx%d", fov, okf and string.format("%.2f", fpp) or "?", bw, bh))
	end

	if MCPT.frame % 30 == 0 or (MCPT.lookApplied == nil) or (MCPT.lookApplied.thirdPerson ~= MCPT.thirdPerson)
		or (MCPT.lookApplied.frontView ~= MCPT.frontView) then
		apply_look(player, true)
	end

	local yaw, pitch = mc_angles(fwd)
	local roll = mc_roll(yaw, pitch, up)
	local x, y, z = pos.x, pos.z + MCPT.yoff, -pos.y
	local bodyYaw = mc_angles(player:GetWorldForward())
	MCPT.frame = MCPT.frame + 1

	-- where Steve looks: the camera's direction, except in front of him (the camera faces back at him)
	local front = MCPT.thirdPerson and MCPT.frontView
	local lookYaw, lookPitch = front and (yaw + 180) or yaw, front and -pitch or pitch
	if lookYaw > 180 then lookYaw = lookYaw - 360 end
	MCPT.aimDir = nil
	if MCPT.thirdPerson and not front and not MCPT.fly then
		-- third person: the camera sits behind and above Steve, so aiming parallel to it shoots under the crosshair.
		-- Aim from his eyes at whatever the crosshair is on (or 150 m out), as third-person shooters do.
		local far = { x = pos.x + fwd.x * 150, y = pos.y + fwd.y * 150, z = pos.z + fwd.z * 150 }
		local target = ray(pos, far) or far
		local eyeZ = feet.z + (MCPT.sneaking and 1.27 or 1.62)
		local d = { x = target.x - feet.x, y = target.y - feet.y, z = target.z - eyeZ }
		lookYaw, lookPitch = mc_angles(d)
		local len = math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
		if len > 1e-3 then MCPT.aimDir = { x = d.x / len, y = d.y / len, z = d.z / len } end
	end

	local steve = MCPT.thirdPerson and { feet.x, feet.z + MCPT.yoff + 0.9, -feet.y } or nil
	pose(true, yaw, pitch, roll, fov, x, y, z, steve)
	if MCPT.fly then
		-- flying: Minecraft moves Steve (drive); the mouse look steers; "pl" = where V was put (Steve's last position),
		-- so Minecraft keeps the camera's framing of him exactly
		local pl = MCPT.flyPos and MCPT.flyPos.mc or { feet.x, feet.z + MCPT.yoff, -feet.y }
		-- steer by the flight heading (Minecraft yaw = 180 - Cyberpunk yaw); pitch from the camera (that still moves)
		if MCPT.flyYaw then
			lookYaw = (180 - MCPT.flyYaw + 180) % 360 - 180
			lookPitch = front and -pitch or pitch
		end
		send(string.format('{"t":"cam","f":%d,"p":[%s,%s,%s],"r":[%.3f,%.3f,0],"fov":%.3f,"fp":false,"drive":true,"pl":[%s,%s,%s],"look":[%.3f,%.3f]}',
			MCPT.frame, json_num(x), json_num(y), json_num(z), yaw, pitch, fov, json_num(pl[1]), json_num(pl[2]), json_num(pl[3]), lookYaw, lookPitch))
		-- Cyberpunk heading (yaw 0 = +Y, counter-clockwise) of the steering direction, for the per-tick teleport
		local hx, hy = fwd.x, fwd.y
		if front then hx, hy = -hx, -hy end
		MCPT.flyHeading = math.deg(math.atan2(-hx, hy))
		if MCPT.frame % 15 == 0 then
			log(string.format("flight: camera yaw(mc) %.1f pitch %.1f | teleport heading %.1f | V yaw %.1f | look sent %.1f %.1f",
				yaw, pitch, MCPT.flyHeading, player:GetWorldYaw(), lookYaw, lookPitch))
		end
	else
	send(string.format('{"t":"cam","f":%d,"p":[%s,%s,%s],"r":[%.3f,%.3f,%.3f],"fov":%.3f,"fp":%s,"pl":[%s,%s,%s],"h":%.3f,"look":[%.3f,%.3f]}',
		MCPT.frame, json_num(x), json_num(y), json_num(z), yaw, pitch, roll, fov, MCPT.thirdPerson and "false" or "true",
		json_num(feet.x), json_num(feet.z + MCPT.yoff), json_num(-feet.y), bodyYaw, lookYaw, lookPitch))
	end

	if MCPT.frame % 60 == 0 then -- police heat, logged when it changes
		local okH, heat = pcall(function() return Game.GetScriptableSystemsContainer():Get("PreventionSystem"):GetHeatStageAsInt() end)
		if okH and heat ~= MCPT.heat then MCPT.heat = heat; log("police heat now " .. tostring(heat)) end
	end
	forward_input()
	maxtac_tick()
	fly_tick(player, feet)
	sync_health(player)
	set_fall_immunity(player, true)
	if not MCPT.fly then
		forward_crouch(player, feet, pos)
		aim_surface(player, feet, fwd)
	end
	sample_ground(feet)
	if MCPT.armorAt and MCPT.frame >= MCPT.armorAt then
		MCPT.armorAt = nil
		-- survival Steve (health and hunger; Cyberpunk's damage is mirrored to him), no Minecraft fall damage (V's
		-- falls already hurt V, and that is mirrored)
		send('{"t":"cmd","c":"gamemode survival @a"}')
		send('{"t":"cmd","c":"gamerule fall_damage false"}')
		-- Steve wears full diamond armour
		for _, a in ipairs({ { "head", "diamond_helmet" }, { "chest", "diamond_chestplate" }, { "legs", "diamond_leggings" },
			{ "feet", "diamond_boots" } }) do
			send(string.format('{"t":"cmd","c":"item replace entity @a armor.%s with minecraft:%s"}', a[1], a[2]))
		end
		log("Steve: diamond armour")
	end
	if MCPT.blockSyncAt and MCPT.frame >= MCPT.blockSyncAt then
		MCPT.blockSyncAt = nil
		send('{"t":"blocksync","r":48}')
	end

	if MCPT.wallPending and MCPT.frame >= (MCPT.wallAt or 0) then
		MCPT.wallPending = false
		place_wall(feet, fwd)
	end

	for _ = 1, 96 do -- flight sends Steve's position every Minecraft frame
		local msg = Game.MCPT_Poll()
		if msg == nil or msg == "" then break end
		handle_event(msg, player)
	end
end

registerForEvent("onInit", function()
	log("loaded")
	-- block colliders: added to our block entities as they initialise (MCPTColliderHook.reds relays the callback)
	local okObs, errObs = pcall(function()
		Observe("MCPTColliderHook", "OnInit", function(_, event)
			if not event or not MCPT.blockPending then return end
			local ent = event:GetEntity()
			if not ent then return end
			local key = tostring(ent:GetEntityID().hash)
			if not MCPT.blockPending[key] then return end
			MCPT.blockPending[key] = nil
			local ok, err = pcall(add_collider, ent)
			if not ok and not MCPT.loggedColliderErr then MCPT.loggedColliderErr = true; log("collider: " .. tostring(err)) end
		end)
	end)
	log("collider hook: " .. (okObs and "observing" or tostring(errObs)))
	-- no vaulting or mantling while Steve is out: blocks are climbed Minecraft-style, by jumping onto them. The game
	-- asks DefaultTransition.IsVaultingClimbingRestricted before every vault/climb (true when carrying a body etc.).
	local okOv, errOv = pcall(function()
		Override("DefaultTransition", "IsVaultingClimbingRestricted", function(this, scriptInterface, wrapped)
			if MCPT.lookApplied and MCPT.noVault ~= false then return true end
			return wrapped(scriptInterface)
		end)
	end)
	log("no-vault override: " .. (okOv and "on" or tostring(errOv)))
	-- a higher jump while Steve is out (pillaring: jump and place a block underneath). The jump state takes an extra
	-- upward 'impulse' parameter, as the vehicle cool-exit jump does; jumpBoost (m/s) is tunable in tune.txt.
	local okJ, errJ = pcall(function()
		Observe("JumpEvents", "OnEnter", function(this, stateContext, scriptInterface)
			if not (MCPT.lookApplied and (MCPT.jumpBoost or 1.2) > 0) then return end
			pcall(function()
				stateContext:SetTemporaryVectorParameter("impulse", Vector4.new(0, 0, MCPT.jumpBoost or 1.2, 0), true)
			end)
		end)
	end)
	log("jump boost: " .. (okJ and "on" or tostring(errJ)))
	pcall(despawn_all_blocks) -- leftovers from before a mod reload
	-- a HUD hidden when the game or the mods last stopped comes back first (hud_backup.txt)
	local f = io.open(HUD_BACKUP, "r")
	if f then
		f:close()
		local ok, err = set_hud_visible(true)
		log("restored HUD from backup: " .. (ok and "ok" or tostring(err)))
	end
end)

registerForEvent("onUpdate", function()
	local ok, err = pcall(tick)
	if not ok then
		log("error: " .. tostring(err))
		MCPT.active = false -- stop spamming; toggle back on with the hotkey after fixing
	end
end)

registerHotkey("mcpt_toggle", "Toggle Minecraft passthrough", function()
	MCPT.active = not MCPT.active
	log(MCPT.active and "on" or "off")
end)

-- Minecraft's F5 cycle: first person -> behind -> in front (facing Steve) -> first person
registerHotkey("mcpt_view", "Cycle view: first person / behind / in front (Minecraft's F5)", function()
	if not MCPT.thirdPerson then
		MCPT.thirdPerson, MCPT.frontView = true, false
	elseif not MCPT.frontView then
		MCPT.frontView = true
	else
		MCPT.thirdPerson, MCPT.frontView = false, false
	end
	log(not MCPT.thirdPerson and "first person" or (MCPT.frontView and "in front" or "behind"))
end)

registerForEvent("onOverlayOpen", function() MCPT.overlayOpen = true end)
registerForEvent("onOverlayClose", function() MCPT.overlayOpen = false end)

registerForEvent("onShutdown", function()
	local player = Game.GetPlayer()
	if player and MCPT.lookApplied then apply_look(player, false) end
end)

registerHotkey("mcpt_go1", "Teleport: Megabuilding H8 roof (glide spot)", function() go_spot(1) end)
registerHotkey("mcpt_go2", "Teleport: Jig-Jig Street", function() go_spot(2) end)
registerHotkey("mcpt_go3", "Teleport: Corpo Plaza", function() go_spot(3) end)

registerHotkey("mcpt_relevel", "Re-level Minecraft ground to V's feet", function()
	MCPT.yoff = nil
	log("re-level")
end)

registerHotkey("mcpt_wall", "Place the gold test wall ahead", function()
	MCPT.wallPending = true
end)

registerHotkey("mcpt_fov", "Switch FOV interpretation (vertical/horizontal)", function()
	MCPT.fovIsHorizontal = not MCPT.fovIsHorizontal
	MCPT.loggedFov = false
	log(MCPT.fovIsHorizontal and "fov treated as horizontal" or "fov treated as vertical")
end)

return MCPT

if SERVER then
	AddCSLuaFile()
	return
end

-- ============================================================================
-- ULTIMATE 11: НАСТОЯЩИЙ ВИД ОТ ПЕРВОГО ЛИЦА V3.5 PRO (ФИКС СПРИНТА + РЕАЛИЗМ)
-- ============================================================================

local cvEnabled    = CreateClientConVar("ult_rfp_enabled", "1", true, false, "Включить реалистичный вид от первого лица")
local cvFov        = CreateClientConVar("ult_rfp_fov", "0", true, false, "Доп. расширение угла обзора (0..25)")
local cvForward    = CreateClientConVar("ult_rfp_forward", "3.8", true, false, "Базовый сдвиг камеры вперёд от переносицы")
local cvSprintFwd  = CreateClientConVar("ult_rfp_sprint_fwd", "4.8", true, false, "Доп. вынос вперёд при спринте (защита от плащей и воротников)")
local cvUp         = CreateClientConVar("ult_rfp_up", "1.0", true, false, "Сдвиг камеры вверх от глаз")
local cvSmooth     = CreateClientConVar("ult_rfp_smooth", "28", true, false, "Плавность локального смещения головы (без лага при беге!)")
local cvHeadPitch  = CreateClientConVar("ult_rfp_pitch_Influence", "0.28", true, false, "Влияние наклона головы на ракурс (0..1)")
local cvCrosshair  = CreateClientConVar("ult_rfp_dot_crosshair", "1", true, false, "Тактический динамический прицел по реальному дулу оружия")
local cvCustomKey  = CreateClientConVar("ult_rfp_custom_key", "0", true, false, "Дополнительная клавиша переключения")
local cvBodyBob    = CreateClientConVar("ult_rfp_bodybob", "1", true, false, "Реалистичное дыхание, пружина приземления и динамический FOV бега")
local cvCornerLean = CreateClientConVar("ult_rfp_alt_lean", "1", true, false, "Тактический наклон из-за угла на [Alt + A / D]")

local isRenderingRealFP = false
local hiddenBones = {}
local smoothLocalOffset = nil
local wasToggleDown = false
local warnShown = false

-- Пружина мягкого сгибания коленей при приземлении + тактический наклон головы
local wasOnGround = true
local prevVelZ = 0
local landDipOffset = 0
local landDipVel = 0
local smoothLeanFrac = 0
local smoothSprintFov = 0
local smoothStrafeRoll = 0

local VEC_TINY = Vector(0.001, 0.001, 0.001)
local VEC_NECK = Vector(0.12, 0.12, 0.12)
local VEC_NORM = Vector(1, 1, 1)

local function RestorePlayerHeadBones(ply)
	if not IsValid(ply) then return end
	for boneId, _ in pairs(hiddenBones) do
		if boneId and boneId >= 0 then
			ply:ManipulateBoneScale(boneId, VEC_NORM)
		end
	end
	table.Empty(hiddenBones)
end

local function HidePlayerHeadAndCollarBones(ply)
	if not IsValid(ply) then return end
	local count = ply:GetBoneCount() or 0
	for i = 0, count - 1 do
		local name = string.lower(ply:GetBoneName(i) or "")
		if string.find(name, "head", 1, true)
			or string.find(name, "hair", 1, true)
			or string.find(name, "helmet", 1, true)
			or string.find(name, "hat", 1, true)
			or string.find(name, "mask", 1, true)
			or string.find(name, "jaw", 1, true)
			or string.find(name, "eye", 1, true)
			or string.find(name, "face", 1, true)
			or string.find(name, "hood", 1, true)
			or string.find(name, "collar", 1, true)
			or string.find(name, "scarf", 1, true)
		then
			ply:ManipulateBoneScale(i, VEC_TINY)
			hiddenBones[i] = true
		elseif string.find(name, "neck", 1, true) then
			ply:ManipulateBoneScale(i, VEC_NECK)
			hiddenBones[i] = true
		end
	end
end

local function ToggleRealFP()
	local nextVal = not cvEnabled:GetBool()
	RunConsoleCommand("ult_rfp_enabled", nextVal and "1" or "0")

	local ply = LocalPlayer()
	if not nextVal and IsValid(ply) then
		RestorePlayerHeadBones(ply)
		smoothLocalOffset = nil
	end

	surface.PlaySound(nextVal and "buttons/button14.wav" or "buttons/button15.wav")
	notification.AddLegacy(
		nextVal and "[Real First Person V3.5] ВКЛЮЧЕН — Настоящее 3D-тело, спринт-фикс и инерция ([/])"
		        or "[Real First Person V3.5] ВЫКЛЮЧЕН — Стандартные руки GMod ([/])",
		NOTIFY_GENERIC,
		3.2
	)
end

concommand.Add("ult_rfp_toggle", ToggleRealFP)

net.Receive("UltRealFP_ServerKeyToggle", function()
	ToggleRealFP()
end)

local function IsSlashKeyCode(code)
	if not code or code <= 0 then return false end
	if code == KEY_SLASH or code == KEY_PAD_DIVIDE or code == KEY_BACKSLASH then
		return true
	end
	local mapped = input.GetKeyCode("/")
	if mapped and mapped > 0 and code == mapped then
		return true
	end
	local custom = cvCustomKey:GetInt()
	if custom > 0 and code == custom then
		return true
	end
	return false
end

hook.Add("PlayerButtonDown", "UltRealFP_ButtonToggle", function(ply, button)
	if ply ~= LocalPlayer() or not IsFirstTimePredicted() then return end
	if gui.IsGameUIVisible() or gui.IsConsoleVisible() or vgui.GetKeyboardFocus() ~= nil then return end
	if IsSlashKeyCode(button) then
		wasToggleDown = true
		ToggleRealFP()
	end
end)

hook.Add("OnPlayerChat", "UltRealFP_ChatSlashToggle", function(ply, text)
	if ply ~= LocalPlayer() then return end
	local t = string.Trim(string.lower(text or ""))
	if t == "/" or t == "/fp" or t == "!fp" or t == ".fp" then
		ToggleRealFP()
		return true
	end
end)

hook.Add("Think", "UltRealFP_KeyPollAndCleanup", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	if not gui.IsGameUIVisible() and not gui.IsConsoleVisible() and vgui.GetKeyboardFocus() == nil then
		local mappedSlash = input.GetKeyCode("/")
		local customBtn = cvCustomKey:GetInt()
		local pressed = input.IsButtonDown(KEY_SLASH)
			or input.IsButtonDown(KEY_PAD_DIVIDE)
			or input.IsButtonDown(KEY_BACKSLASH)
			or (mappedSlash and mappedSlash > 0 and input.IsButtonDown(mappedSlash))
			or (customBtn > 0 and input.IsButtonDown(customBtn))

		if pressed and not wasToggleDown then
			ToggleRealFP()
		end
		wasToggleDown = pressed
	else
		wasToggleDown = false
	end

	-- Пружина приземления (реалистичное приседание в коленях после прыжка)
	local dt = math.min(FrameTime(), 0.05)
	local onGround = ply:OnGround()
	local curVelZ = ply:GetVelocity().z
	if onGround and not wasOnGround and prevVelZ < -180 and cvBodyBob:GetBool() then
		local impact = math.Clamp(math.abs(prevVelZ) / 650, 0.15, 1.0)
		landDipVel = landDipVel - impact * 52
	end
	wasOnGround = onGround
	prevVelZ = curVelZ

	-- Гармоническая затухающая пружина
	local springForce = -landDipOffset * 135 - landDipVel * 16
	landDipVel = landDipVel + springForce * dt
	landDipOffset = math.Clamp(landDipOffset + landDipVel * dt, -9.5, 4.0)

	if not cvEnabled:GetBool() or not ply:Alive() or ply:InVehicle() then
		if next(hiddenBones) ~= nil then
			RestorePlayerHeadBones(ply)
		end
		isRenderingRealFP = false
		smoothLocalOffset = nil
	end

	if cvEnabled:GetBool() and not warnShown then
		local calcHooks = hook.GetTable().CalcView
		if calcHooks then
			for k, _ in pairs(calcHooks) do
				local ks = string.lower(tostring(k))
				if ks ~= "ultrealfp_calcview" and ks ~= "ultsmarttp_calcview" and ks ~= "ultfpvdrone_camera" and (string.find(ks, "fpv", 1, true) or string.find(ks, "firstperson", 1, true)) then
					warnShown = true
					chat.AddText(Color(255, 200, 70), "[Real First Person] ", Color(235, 240, 250), "Обнаружен сторонний мод камеры (" .. tostring(k) .. ") — наш мод автоматически перехватил приоритет.")
					break
				end
			end
		end
	end
end)

local function ShouldUseRealFP(ply)
	if not cvEnabled:GetBool() then return false end
	if not IsValid(ply) or not ply:Alive() then return false end
	if ply:InVehicle() then return false end
	if ply:GetObserverMode() ~= OBS_MODE_NONE then return false end
	if GetConVar("ult_tp_enabled") and GetConVar("ult_tp_enabled"):GetBool() then return false end
	if IsValid(ply:GetNW2Entity("UltActiveDrone")) or IsValid(ply:GetNW2Entity("UltRagdollEnt")) then return false end
	local wep = ply:GetActiveWeapon()
	if IsValid(wep) and wep:GetClass() == "gmod_camera" then return false end
	if ply:GetFOV() < 55 then return false end
	return true
end

hook.Add("PreDrawViewModel", "UltRealFP_BlockDefaultVM", function(vm, ply, wep)
	if isRenderingRealFP and ShouldUseRealFP(ply) then
		return true
	end
end)

hook.Add("ShouldDrawLocalPlayer", "UltRealFP_DrawRealBody", function(ply)
	if isRenderingRealFP and ShouldUseRealFP(ply) then
		return true
	end
end)

hook.Add("PrePlayerDraw", "UltRealFP_HideHeadBeforeDraw", function(ply)
	if ply ~= LocalPlayer() then return end
	if isRenderingRealFP and ShouldUseRealFP(ply) then
		HidePlayerHeadAndCollarBones(ply)
	elseif next(hiddenBones) ~= nil then
		RestorePlayerHeadBones(ply)
	end
end)

-- Основной расчёт камеры V3.5 PRO (0 лага на бегу + пружина приземления + наклон из-за угла)
hook.Add("CalcView", "UltRealFP_CalcView", function(ply, origin, angles, fov)
	if not ShouldUseRealFP(ply) then
		if isRenderingRealFP then
			isRenderingRealFP = false
			RestorePlayerHeadBones(ply)
			smoothLocalOffset = nil
		end
		return
	end

	isRenderingRealFP = true
	ply:SetupBones()

	local eyeOrigin = ply:EyePos()
	local headAng = nil

	local eyeAttId = ply:LookupAttachment("eyes")
	if eyeAttId and eyeAttId > 0 then
		local att = ply:GetAttachment(eyeAttId)
		if att and att.Pos then
			eyeOrigin = att.Pos
			headAng = att.Ang
		end
	else
		local headBone = ply:LookupBone("ValveBiped.Bip01_Head1")
		if headBone and headBone >= 0 then
			local bPos, bAng = ply:GetBonePosition(headBone)
			if bPos and bPos ~= ply:GetPos() then
				eyeOrigin = bPos + Vector(0, 0, 3.5)
				headAng = bAng
			end
		end
	end

	local flatFwd = Angle(0, angles.y, 0):Forward()
	local rightDir = Angle(0, angles.y, 0):Right()
	local lookFwd = angles:Forward()

	local vel = ply:GetVelocity()
	local horizSpeed = Vector(vel.x, vel.y, 0):Length()
	local dt = math.min(FrameTime(), 0.05)

	-- Вынос вперёд при спринте (защита от воротников/плащей!)
	local moveFactor = math.Clamp((horizSpeed - 120) / 260, 0, 1)
	local sprintLead = moveFactor * cvSprintFwd:GetFloat()
	local lookDownFwd = math.Clamp(angles.p / 89, 0, 1) * 3.6

	-- Тактический наклон из-за угла на [Alt + A / D]
	local targetLean = 0
	if cvCornerLean:GetBool() and ply:KeyDown(IN_WALK) then
		if ply:KeyDown(IN_MOVELEFT) then targetLean = -1 end
		if ply:KeyDown(IN_MOVERIGHT) then targetLean = 1 end
	end
	smoothLeanFrac = Lerp(dt * 10, smoothLeanFrac, targetLean)

	local desiredPos = eyeOrigin
		+ flatFwd * (cvForward:GetFloat() + sprintLead + lookDownFwd)
		+ lookFwd * 1.1
		+ rightDir * (smoothLeanFrac * 15.0)
		+ Vector(0, 0, cvUp:GetFloat() + landDipOffset)

	-- Сглаживание СТРОГО в локальных координатах относительно ply:GetPos() (0 отставания при беге!)
	local playerBase = ply:GetPos()
	local targetLocalOffset = desiredPos - playerBase

	if not smoothLocalOffset or smoothLocalOffset:DistToSqr(targetLocalOffset) > 1600 then
		smoothLocalOffset = targetLocalOffset
	else
		local alpha = math.Clamp(dt * cvSmooth:GetFloat(), 0.15, 1)
		smoothLocalOffset = LerpVector(alpha, smoothLocalOffset, targetLocalOffset)
	end

	local camWorldPos = playerBase + smoothLocalOffset

	local wallCheck = util.TraceHull({
		start = eyeOrigin,
		endpos = camWorldPos,
		mins = Vector(-3.5, -3.5, -3.5),
		maxs = Vector(3.5, 3.5, 3.5),
		filter = ply,
		mask = MASK_PLAYERSOLID_BRUSHONLY
	})
	local safePos = wallCheck.Hit and wallCheck.HitPos or camWorldPos

	local finalAng = Angle(angles.p, angles.y, angles.r)
	if headAng and cvHeadPitch:GetFloat() > 0 then
		local inf = math.Clamp(cvHeadPitch:GetFloat(), 0, 1)
		local rollDiff = math.Clamp(math.AngleDifference(headAng.r, 0), -10, 10)
		finalAng.r = finalAng.r + rollDiff * inf * 0.45
	end

	if cvBodyBob:GetBool() then
		local t = CurTime()
		-- Дыхание в покое + упругий ритм шагов на бегу
		local breathP = math.sin(t * 1.8) * 0.18
		local stepBob = ply:OnGround() and (math.sin(t * 11.5) * 0.38 * moveFactor) or 0
		local strafeSpeed = vel:Dot(rightDir)
		smoothStrafeRoll = Lerp(dt * 8, smoothStrafeRoll, math.Clamp(-strafeSpeed * 0.006, -2.2, 2.2))
		smoothSprintFov = Lerp(dt * 6, smoothSprintFov, moveFactor * 5.5)

		finalAng.p = finalAng.p + breathP + math.abs(stepBob) * 0.5 - landDipOffset * 0.35
		finalAng.r = finalAng.r + stepBob + smoothStrafeRoll + smoothLeanFrac * 11.5
	else
		smoothSprintFov = 0
		finalAng.r = finalAng.r + smoothLeanFrac * 11.5
	end

	return {
		origin = safePos,
		angles = finalAng,
		fov = math.Clamp(fov + cvFov:GetFloat() + smoothSprintFov, 65, 122),
		znear = 2.4,
		drawviewer = true
	}
end)

hook.Add("HUDPaint", "UltRealFP_DynamicCrosshair", function()
	if not isRenderingRealFP or not cvCrosshair:GetBool() then return end
	local ply = LocalPlayer()
	if not ShouldUseRealFP(ply) then return end

	local tr = ply:GetEyeTrace()
	local scr = tr.HitPos:ToScreen()
	if not scr.visible then return end

	local x, y = math.Round(scr.x), math.Round(scr.y)
	local spread = math.Clamp(ply:GetVelocity():Length() * 0.02, 0, 8)
	local gap = math.Round(5 + spread)

	surface.SetDrawColor(0, 0, 0, 185)
	surface.DrawRect(x - 2, y - 2, 5, 5)
	surface.SetDrawColor(130, 245, 255, 235)
	surface.DrawRect(x - 1, y - 1, 3, 3)

	surface.SetDrawColor(255, 255, 255, 165)
	surface.DrawLine(x - gap - 4, y, x - gap, y)
	surface.DrawLine(x + gap, y, x + gap + 4, y)
	surface.DrawLine(x, y - gap - 4, x, y - gap)
	surface.DrawLine(x, y + gap, x, y + gap + 4)
end)

list.Set("DesktopWindows", "UltRealFirstPersonToggle", {
	title = "Вид 1-го Лица [/]",
	icon = "icon64/playermodel.png",
	init = function(icon, window)
		if IsValid(window) then window:Remove() end
		ToggleRealFP()
	end
})

hook.Add("PopulateToolMenu", "UltRealFP_Menu", function()
	spawnmenu.AddToolMenuOption("Utilities", "Ultimate Pack", "UltRealFirstPerson", "11. Реалистичный Вид 1-го Лица", "", "", function(panel)
		panel:ClearControls()
		panel:Help("Настоящий вид от первого лица V3.5 PRO: реальное 3D-тело, отсутствие залезания в плащ при спринте, пружина коленей при приземлении и тактический наклон [Alt + A/D]!")
		panel:Button("Переключить Вид 1-го Лица [/]", "ult_rfp_toggle")
		panel:CheckBox("Включить реалистичный вид 1-го лица", "ult_rfp_enabled")
		panel:CheckBox("Инерция тела, дыхание и пружина приземления", "ult_rfp_bodybob")
		panel:CheckBox("Тактический наклон из-за угла [Alt + A / D]", "ult_rfp_alt_lean")
		panel:CheckBox("Динамический прицел по линии огня", "ult_rfp_dot_crosshair")
		panel:NumSlider("Сдвиг вперёд (базовый)", "ult_rfp_forward", 1.5, 9.0, 1)
		panel:NumSlider("Доп. вынос при спринте (от плаща)", "ult_rfp_sprint_fwd", 0.0, 10.0, 1)
		panel:NumSlider("Сдвиг вверх от глаз", "ult_rfp_up", -3.0, 5.0, 1)
		panel:NumSlider("Дополнительный FOV", "ult_rfp_fov", 0, 25, 0)
		panel:NumSlider("Плавность камеры", "ult_rfp_smooth", 10, 45, 0)

		local lbl = vgui.Create("DLabel")
		lbl:SetText("Доп. клавиша переключения (кроме /):")
		lbl:SetDark(true)
		panel:AddItem(lbl)

		local binder = vgui.Create("DBinder")
		binder:SetValue(cvCustomKey:GetInt())
		binder.OnChange = function(_, num)
			RunConsoleCommand("ult_rfp_custom_key", tostring(num))
		end
		panel:AddItem(binder)
	end)
end)

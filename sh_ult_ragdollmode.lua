AddCSLuaFile()

if SERVER then
	local cvKnockdown = CreateConVar("ult_ragdoll_knockdown", "1", FCVAR_ARCHIVE, "Реалистичное сбивание с ног мощными взрывами и машинами")

	local function ReleaseHandConstraint(rag, key)
		if IsValid(rag[key]) then
			rag[key]:Remove()
		end
		rag[key] = nil
	end

	local function TryGrabWithRagdollHand(ply, rag, boneName, weldKey)
		if IsValid(rag[weldKey]) then return end
		local boneId = rag:LookupBone(boneName)
		if not boneId then return end
		local physNum = rag:TranslateBoneToPhysBone(boneId)
		local handPhys = rag:GetPhysicsObjectNum(physNum)
		if not IsValid(handPhys) then return end

		local handPos = handPhys:GetPos()
		local tr = util.TraceHull({
			start = handPos,
			endpos = handPos + ply:GetAimVector() * 28,
			mins = Vector(-12, -12, -12),
			maxs = Vector(12, 12, 12),
			filter = { ply, rag }
		})

		if tr.Hit then
			local targetEnt = IsValid(tr.Entity) and tr.Entity or game.GetWorld()
			local targetBone = tr.PhysicsBone or 0
			local w = constraint.Weld(rag, targetEnt, physNum, targetBone, 0, false, false)
			if IsValid(w) then
				rag[weldKey] = w
				rag:EmitSound("physics/body/body_medium_impact_soft2.wav", 68, 120)
			end
		end
	end

	local function ExitRagdollMode(ply)
		if not IsValid(ply) then return end
		local rag = ply.UltLiveRagdoll
		if not IsValid(rag) then return end

		ReleaseHandConstraint(rag, "LeftHandWeld")
		ReleaseHandConstraint(rag, "RightHandWeld")

		ply.UltLiveRagdoll = nil
		ply:SetNW2Entity("UltRagdollEnt", NULL)

		local standPos = rag:GetPos() + Vector(0, 0, 12)
		local savedHP = ply.UltSavedHP or 100
		local savedArmor = ply.UltSavedArmor or 0
		local savedWeps = ply.UltSavedWeps or {}
		local savedActive = ply.UltSavedActiveWep

		rag:Remove()

		ply:UnSpectate()
		ply:SetParent(NULL)
		ply:Spawn()
		ply:SetPos(standPos)
		ply:SetHealth(math.max(1, savedHP))
		ply:SetArmor(savedArmor)
		ply:SetNoTarget(false)

		ply:StripWeapons()
		for _, cls in ipairs(savedWeps) do
			ply:Give(cls)
		end
		if savedActive and ply:HasWeapon(savedActive) then
			ply:SelectWeapon(savedActive)
		end

		ply:EmitSound("physics/body/body_medium_impact_soft" .. math.random(1, 4) .. ".wav", 72, 105)
	end

	local function EnterRagdollMode(ply, boostVel)
		if not IsValid(ply) or not ply:Alive() or ply:InVehicle() then return end
		if IsValid(ply.UltLiveRagdoll) then
			ExitRagdollMode(ply)
			return
		end

		ply.UltSavedHP = ply:Health()
		ply.UltSavedArmor = ply:Armor()
		ply.UltSavedWeps = {}
		for _, w in ipairs(ply:GetWeapons()) do
			if IsValid(w) then table.insert(ply.UltSavedWeps, w:GetClass()) end
		end
		local actWep = ply:GetActiveWeapon()
		ply.UltSavedActiveWep = IsValid(actWep) and actWep:GetClass() or nil

		local vel = ply:GetVelocity() + (boostVel or Vector(0, 0, 0))
		local rag = ents.Create("prop_ragdoll")
		if not IsValid(rag) then return end

		rag:SetModel(ply:GetModel())
		rag:SetSkin(ply:GetSkin())
		rag:SetPos(ply:GetPos())
		rag:SetAngles(Angle(0, ply:EyeAngles().y, 0))
		rag:Spawn()
		rag:Activate()

		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			local bonePhys = rag:GetPhysicsObjectNum(i)
			if IsValid(bonePhys) then
				bonePhys:SetVelocity(vel)
			end
		end

		ply.UltLiveRagdoll = rag
		ply:SetNW2Entity("UltRagdollEnt", rag)
		ply:StripWeapons()
		ply:Spectate(OBS_MODE_CHASE)
		ply:SpectateEntity(rag)
		ply:SetNoTarget(true)
		ply:EmitSound("physics/body/body_medium_impact_hard" .. math.random(1, 4) .. ".wav", 75, 100)
	end

	-- Реалистичное сбивание с ног сильной взрывной волной или ударом машины (если игрок выживает!)
	hook.Add("PostEntityTakeDamage", "UltRagdoll_AutoBlastKnockdown", function(ent, dmg, took)
		if not took or not cvKnockdown:GetBool() then return end
		if not IsValid(ent) or not ent:IsPlayer() or not ent:Alive() or IsValid(ent.UltLiveRagdoll) then return end

		if (dmg:IsExplosionDamage() or dmg:IsDamageType(DMG_CRUSH) or dmg:IsDamageType(DMG_VEHICLE)) and dmg:GetDamage() >= 38 and ent:Health() > 5 then
			local push = dmg:GetDamageForce():GetNormalized() * 420 + Vector(0, 0, 220)
			EnterRagdollMode(ent, push)
			timer.Simple(2.4, function()
				if IsValid(ent) and IsValid(ent.UltLiveRagdoll) then
					ExitRagdollMode(ent)
				end
			end)
		end
	end)

	concommand.Add("ult_ragdoll_toggle", function(ply)
		if not IsValid(ply) then return end
		if (ply.UltNextRagToggle or 0) > CurTime() then return end
		ply.UltNextRagToggle = CurTime() + 0.45
		EnterRagdollMode(ply)
	end)

	hook.Add("PlayerTick", "UltRagdoll_RollAndHandGrab", function(ply, mv)
		local rag = ply.UltLiveRagdoll
		if not IsValid(rag) then return end

		if ply:KeyPressed(IN_JUMP) and (ply.UltNextRagToggle or 0) < CurTime() then
			ply.UltNextRagToggle = CurTime() + 0.45
			ExitRagdollMode(ply)
			return
		end

		-- Хватание руками рэгдолла за уступы, стены и машины: ЛКМ = левая рука, ПКМ = правая рука!
		if ply:KeyDown(IN_ATTACK) then
			TryGrabWithRagdollHand(ply, rag, "ValveBiped.Bip01_L_Hand", "LeftHandWeld")
		else
			ReleaseHandConstraint(rag, "LeftHandWeld")
		end

		if ply:KeyDown(IN_ATTACK2) then
			TryGrabWithRagdollHand(ply, rag, "ValveBiped.Bip01_R_Hand", "RightHandWeld")
		else
			ReleaseHandConstraint(rag, "RightHandWeld")
		end

		local phys = rag:GetPhysicsObject()
		if IsValid(phys) then
			local ang = Angle(0, ply:EyeAngles().y, 0)
			local push = Vector(0, 0, 0)
			if ply:KeyDown(IN_FORWARD) then push = push + ang:Forward() * 260 end
			if ply:KeyDown(IN_BACK) then push = push - ang:Forward() * 260 end
			if ply:KeyDown(IN_MOVERIGHT) then push = push + ang:Right() * 260 end
			if ply:KeyDown(IN_MOVELEFT) then push = push - ang:Right() * 260 end
			if push:LengthSqr() > 0 then
				phys:Wake()
				phys:ApplyForceCenter(push * phys:GetMass() * FrameTime() * 15)
			end
		end
	end)

	hook.Add("PlayerDisconnected", "UltRagdoll_CleanDisconnect", function(ply)
		if IsValid(ply.UltLiveRagdoll) then ply.UltLiveRagdoll:Remove() end
	end)
end

if CLIENT then
	local cvKey = CreateClientConVar("ult_ragdoll_key", tostring(KEY_J), true, false, "Клавиша живого рэгдолла (по умолчанию J)")
	local wasPressed = false

	hook.Add("Think", "UltRagdoll_KeyBind", function()
		if gui.IsGameUIVisible() or gui.IsConsoleVisible() or vgui.GetKeyboardFocus() ~= nil then
			wasPressed = false
			return
		end
		local down = input.IsButtonDown(cvKey:GetInt())
		if down and not wasPressed then
			RunConsoleCommand("ult_ragdoll_toggle")
		end
		wasPressed = down
	end)

	hook.Add("HUDPaint", "UltRagdoll_HintHUD", function()
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		local rag = ply:GetNW2Entity("UltRagdollEnt")
		if IsValid(rag) then
			draw.SimpleTextOutlined(
				"ЖИВОЙ РЭГДОЛЛ (ВРАГИ НЕ ВИДЯТ ВАС!) | [ЛКМ / ПКМ] Схватиться руками! | [WASD] Катиться | [J / Пробел] Встать",
				"DermaDefaultBold", ScrW() * 0.5, ScrH() - 92, Color(255, 225, 95), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, Color(0, 0, 0, 225)
			)
		end
	end)

	hook.Add("PopulateToolMenu", "UltRagdoll_Menu", function()
		spawnmenu.AddToolMenuOption("Utilities", "Ultimate Pack 2", "UltRagdollOpt", "30. Живой Рэгдолл PRO [J]", "", "", function(panel)
			panel:ClearControls()
			panel:Help("Нажмите [J] в любой момент! В режиме рэгдолла зажимайте [ЛКМ / ПКМ], чтобы хвататься руками за уступы и машины!")
			panel:Button("Упасть Рэгдоллом / Встать [J]", "ult_ragdoll_toggle")
			panel:CheckBox("Сбивание с ног взрывами и машинами", "ult_ragdoll_knockdown")

			local lbl = vgui.Create("DLabel")
			lbl:SetText("Своя клавиша Живого Рэгдолла:")
			lbl:SetDark(true)
			panel:AddItem(lbl)

			local binder = vgui.Create("DBinder")
			binder:SetValue(cvKey:GetInt())
			binder.OnChange = function(_, num)
				RunConsoleCommand("ult_ragdoll_key", tostring(num))
			end
			panel:AddItem(binder)
		end)
	end)
end

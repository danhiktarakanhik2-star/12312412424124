AddCSLuaFile()

if SERVER then
	util.AddNetworkString("UltRealFP_ServerKeyToggle")

	hook.Add("PlayerButtonDown", "UltRealFP_ServerSlashDetect", function(ply, button)
		if not IsValid(ply) then return end
		if button == KEY_SLASH or button == KEY_PAD_DIVIDE or button == KEY_BACKSLASH then
			net.Start("UltRealFP_ServerKeyToggle")
			net.Send(ply)
		end
	end)

	hook.Add("PlayerSay", "UltRealFP_ChatToggle", function(ply, text)
		local clean = string.Trim(string.lower(text or ""))
		if clean == "/" or clean == "/fp" or clean == "!fp" or clean == "/1p" then
			net.Start("UltRealFP_ServerKeyToggle")
			net.Send(ply)
			return ""
		end
	end)
end

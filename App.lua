-- App.lua changes for Free Cam + Spectate. Three small edits.

----------------------------------------------------------------------------------
-- EDIT 1: paste this block right after the "World" tab (before "SIDEBAR TAB: Info")
----------------------------------------------------------------------------------

-- SIDEBAR TAB: View (free cam + spectate) -------------------------------------
local view = ui:AddTab("View", "View")

local freePage = view:AddSubTab("Free Cam", "Free Cam")
local freeCam = freePage:AddToggle("Free Cam", false, function(on)
	mods:SetFreeCam(on)
	ui:Notify("Free Cam " .. onOff(on))
end)
freePage:AddLabel("Hold Right Mouse to look. WASD move, E/Space up, Q down.")
freePage:AddLabel("Shift = fast, Ctrl = slow. Your character is frozen meanwhile.")
freePage:AddSlider("Cam Speed", 5, 300, 50, function(v) mods:SetFreeCamSpeed(v) end)
freePage:AddSlider("Look Sensitivity %", 10, 100, 30, function(v) mods:SetFreeCamSensitivity(v / 100) end)
freePage:AddButton("Return To My Character", function() mods:StopCamera() end)

local specPage = view:AddSubTab("Spectate", "Spectate")
local specLabel = specPage:AddLabel("Camera: Normal")

specPage:AddButton("Previous Player", function()
	local p = mods:SpectatePrev()
	ui:Notify(p and ("Spectating " .. p.DisplayName) or "No other players")
end)
specPage:AddButton("Next Player", function()
	local p = mods:SpectateNext()
	ui:Notify(p and ("Spectating " .. p.DisplayName) or "No other players")
end)
specPage:AddTextBox("Spectate Player", "", function(text)
	if text == "" then return end
	local p = mods:FindPlayer(text)
	if p then mods:Spectate(p) else ui:Notify("Player not found") end
end)
specPage:AddToggle("First-Person View (POV)", false, function(on) mods:SetSpectatePOV(on) end)
specPage:AddButton("Free Cam Around This Player", function()
	local target = mods.SpectateTarget
	if target and mods:FocusFreeCam(target) then
		ui:Notify("Free Cam focused on " .. target.DisplayName)
	else
		ui:Notify("Spectate someone first")
	end
end)
specPage:AddButton("Stop (Back To Me)", function() mods:StopCamera() end)

-- keep the UI in sync when the camera changes (hotkeys, player leaving, Reset...)
mods.OnCameraChanged = function(mode)
	specLabel.Text = mods:GetCameraStatus()
	freeCam.Set(mode == "Free")
end

----------------------------------------------------------------------------------
-- EDIT 2: in the Keys page, add these keybinds after `local noclipKey = ...`
----------------------------------------------------------------------------------

local freeCamKey = keysPage:AddKeybind("Free Cam Key", Enum.KeyCode.G)
local specPrevKey = keysPage:AddKeybind("Spectate Previous", Enum.KeyCode.LeftBracket)
local specNextKey = keysPage:AddKeybind("Spectate Next", Enum.KeyCode.RightBracket)
local camStopKey = keysPage:AddKeybind("Stop Camera", Enum.KeyCode.End)

----------------------------------------------------------------------------------
-- EDIT 3: in the hotkeyConn handler, extend the if / elseif chain
-- (put these after the existing `elseif key == noclipKey.Get() then ... ` branch)
----------------------------------------------------------------------------------

	elseif key == freeCamKey.Get() then
		local on = mods.CamMode ~= "Free"
		mods:SetFreeCam(on)
		ui:Notify("Free Cam " .. onOff(on))

	elseif key == specNextKey.Get() then
		local p = mods:SpectateNext()
		ui:Notify(p and ("Spectating " .. p.DisplayName) or "No other players")

	elseif key == specPrevKey.Get() then
		local p = mods:SpectatePrev()
		ui:Notify(p and ("Spectating " .. p.DisplayName) or "No other players")

	elseif key == camStopKey.Get() then
		mods:StopCamera()
		ui:Notify("Camera reset")
	end   -- (this `end` replaces the chain's existing closing `end`)

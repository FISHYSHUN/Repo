-- modules/App.lua (formerly Main.client.lua)
-- Connects the UI module to the functionality module. Returns an object with :Destroy()
-- so the loader can replace a running menu when you execute it again.
--
-- LAYOUT: one side tab per topic, every page is a small grid of cards ("quad") instead of a long list.
--   Player  World  Visuals  Tracking  Guard  Vehicle  Games  Info  Settings
local import = ...

local UserInputService = game:GetService("UserInputService")

local GuiUI = import("Window")
local PlayerMods = import("PlayerMods")
local Visuals = import("Visuals")
local Config = import("Config")
local Guard = import("Guard")
local Vehicle = import("Vehicle")
local Games = import("Games")
local MM2 = import("MM2")
local Audio = import("Audio")

local ui = GuiUI.new({
	Title = "Player Menu",
	Subtitle = "v1.4",
	ToggleKey = Enum.KeyCode.RightShift, -- can be rebound with the button in the bottom bar
	Style = "GNOME", -- dark GNOME is the only style
	DockSide = "Left", -- Left | Right | Top : which screen edge the bar is glued to
	BarSize = 56, -- bar thickness in px (36 - 100)
	UserScale = 0.6, -- starts at 60% (the slider in Settings > Look goes 30% - 160%)
	AutoHide = true, -- shrink into the edge widget when not used
	IdleTime = 8, -- seconds of inactivity before that happens
	WidgetLength = 84, -- length of the edge widget (px)
	Entrance = true, -- cards rise into place when a page opens (Settings > Look > Motion)
	-- StartCollapsed = true, -- start as the widget instead of the open menu
	TitleRotation = "Auto", -- Auto | Up | Down (Left / Right docks only)
	-- SlideMode = "LeftToRight", -- uncomment to always slide pages in from the left
	-- Theme = "Midnight", -- Default | Dark | Midnight | Forest | Crimson | Light
	-- CornerRadius = 16, -- starts at the max (16); lower it here or in Settings > Look
})

local mods = PlayerMods.new()
local visuals = Visuals.new()
local guard = Guard.new()

-- wire the guard to your own tools
visuals.FlaggedFn = function(p) return guard:IsFlagged(p) end
guard.IsExempt = function() return mods.Flying or mods.CamMode ~= "Off" or mods._glide ~= nil end
guard.OnAlert = function(text) ui:Notify(text) end

-- your own teleports (slots, click, player, undo) must not trip Block Forced TP
local baseTeleport = mods.TeleportTo
mods.TeleportTo = function(self, cf)
	guard:Allow(2)
	return baseTeleport(self, cf)
end

local defaultGravity = math.round(mods.Defaults.Gravity)
local defaultFov = math.clamp(math.round(mods.Defaults.FOV), 40, 120)
local defaultClock = math.clamp(math.round(mods.Defaults.ClockTime), 0, 24)
local defaultZoom = math.clamp(math.round(mods.Defaults.MaxZoom), 10, 1000)

local function onOff(on) return on and "ON" or "OFF" end

-- Config registry ------------------------------------------------------------
-- Every control created through these helpers is remembered, so it can be saved to
-- and restored from a config. resetApply = also re-apply the default on "Reset All"
-- (for tuning values that live in the module, not on the character / world).
local registry = {}
local dirtyAt = nil -- os.clock() of the last change (autosave waits for it to go quiet)

local function touch() dirtyAt = os.clock() end

local function register(key, default, apply, resetApply)
	local entry = { value = default, default = default, apply = apply, resetApply = resetApply }
	registry[key] = entry
	return entry
end

local function slider(page, label, key, min, max, default, apply, resetApply)
	local entry = register(key, default, apply, resetApply)
	entry.control = page:AddSlider(label, min, max, default, function(v) entry.value = v; touch(); apply(v) end)
	return entry.control
end

local function toggle(page, label, key, default, apply, resetApply)
	local entry = register(key, default, apply, resetApply)
	entry.control = page:AddToggle(label, default, function(on) entry.value = on; touch(); apply(on) end)
	return entry.control
end

local function dropdown(page, label, key, list, default, apply, resetApply)
	local entry = register(key, default, apply, resetApply)
	entry.control = page:AddDropdown(label, list, default, function(v) entry.value = v; touch(); apply(v) end)
	return entry.control
end

local function color(page, label, key, default, apply, resetApply)
	local entry = register(key, default, apply, resetApply)
	entry.control = page:AddColorPicker(label, default, function(c) entry.value = c; touch(); apply(c) end)
	return entry.control
end

-- keybinds are saved by KeyCode name (false = unbound). apply receives a KeyCode or nil.
local function keybind(page, label, key, default, apply)
	local entry = register(key, default and default.Name or false, function(name)
		if apply then apply(name and Enum.KeyCode[name] or nil) end
	end, true)
	local ctl = page:AddKeybind(label, default, function(k)
		entry.value = k and k.Name or false
		touch()
		if apply then apply(k) end
	end)
	entry.control = {
		Set = function(name) ctl.Set(name and Enum.KeyCode[name] or nil) end,
		Get = ctl.Get,
	}
	return ctl
end

-- set a registered control from code (hotkeys, config load)
local function setEntry(key, value, quiet)
	local entry = registry[key]
	if not entry then return end
	entry.value = value
	pcall(entry.control.Set, value)
	pcall(entry.apply, value)
	if not quiet then touch() end
end

-- put a control back to its default WITHOUT calling its apply (the caller already reset the real value)
local function restore(key)
	local entry = registry[key]
	if not entry then return end
	entry.value = entry.default
	pcall(entry.control.Set, entry.default)
end

local function flip(key) setEntry(key, not registry[key].value) end

-- PLAYER: Movement + Flight + Camera in one tab -------------------------------
local playerTab = ui:AddTab("Player", "Player", "🏃")
local walkCell, jumpCell, sprintCell, bodyCell = playerTab:AddQuad("Speed", "Move", { "Walk", "Jump", "Sprint", "Body" })
local flyCell, feelCell, noclipCell, airCell = playerTab:AddQuad("Fly", "Fly", { "Fly", "Feel", "Noclip", "Air" })
local fovCell, zoomCell, freeCell, lookCell = playerTab:AddQuad("View", "View", { "FOV", "Zoom", "Free Cam", "Free Look" })
local targetCell, cycleCell, modeCell = playerTab:AddQuad("Spectate", "Spectate", { "Target", "Cycle", "Mode" })

-- move
slider(walkCell, "Walk Speed", "walkSpeed", 16, 150, 16, function(v) mods:SetWalkSpeed(v) end)
walkCell:AddButton("Reset", function() mods:ResetValue("WalkSpeed"); restore("walkSpeed") end)

slider(jumpCell, "Jump Power", "jumpPower", 50, 250, 50, function(v) mods:SetJumpPower(v) end)
toggle(jumpCell, "Infinite Jump", "infJump", false, function(on) mods:SetInfiniteJump(on) end)
jumpCell:AddButton("Reset", function() mods:ResetValue("JumpPower"); restore("jumpPower") end)

toggle(sprintCell, "Sprint", "sprint", false, function(on)
	mods:SetSprint(on)
	ui:Notify("Sprint " .. onOff(on))
end)
slider(sprintCell, "Sprint Speed %", "sprintSpeed", 110, 300, 160, function(v) mods:SetSprintMultiplier(v / 100) end, true)
sprintCell:AddLabel("Hold Left Shift")

slider(bodyCell, "Hip Height", "hipHeight", 0, 20, 2, function(v) mods:SetHipHeight(v) end)
toggle(bodyCell, "Keep Values", "keepValues", false, function(on) mods:SetPersist(on) end)
bodyCell:AddButton("Respawn", function() mods:Respawn() end)

-- fly
toggle(flyCell, "Fly", "fly", false, function(on)
	mods:SetFly(on)
	ui:Notify("Fly " .. onOff(on))
end)
slider(flyCell, "Fly Speed", "flySpeed", 20, 200, 60, function(v) mods:SetFlySpeed(v) end, true)
flyCell:AddLabel("WASD, Space up, Ctrl down")

slider(feelCell, "Smoothing %", "flySmooth", 0, 100, 60, function(v) mods:SetFlySmooth(v) end, true)
toggle(feelCell, "Shift Boost", "flyBoost", true, function(on) mods:SetFlyBoost(on) end, true)
feelCell:AddLabel("Shift = 2x speed")

toggle(noclipCell, "Noclip", "noclip", false, function(on)
	mods:SetNoclip(on)
	ui:Notify("Noclip " .. onOff(on))
end)
noclipCell:AddLabel("Walk through walls")

toggle(airCell, "Slow Fall", "slowFall", false, function(on) mods:SetSlowFall(on) end)
slider(airCell, "Max Fall Speed", "fallSpeed", 5, 100, 30, function(v) mods:SetFallSpeed(v) end, true)

-- view
slider(fovCell, "Field of View", "fov", 40, 120, defaultFov, function(v) mods:SetFOV(v) end)
fovCell:AddButton("Reset", function() mods:ResetValue("FOV"); restore("fov") end)

slider(zoomCell, "Max Zoom", "maxZoom", 10, 1000, defaultZoom, function(v) mods:SetMaxZoom(v) end)
zoomCell:AddButton("Reset", function() mods:ResetValue("MaxZoom"); restore("maxZoom") end)

-- free cam is a live camera mode, so it is not saved in configs
local freeCam = freeCell:AddToggle("Free Cam", false, function(on)
	mods:SetFreeCam(on)
	ui:Notify("Free Cam " .. onOff(on))
end)
slider(freeCell, "Cam Speed", "freeCamSpeed", 5, 300, 50, function(v) mods:SetFreeCamSpeed(v) end, true)
freeCell:AddLabel("Hold Right Mouse to look")

slider(lookCell, "Look Sens %", "freeCamSens", 10, 100, 30, function(v) mods:SetFreeCamSensitivity(v / 100) end, true)
slider(lookCell, "Smoothing %", "freeCamSmooth", 0, 100, 50, function(v) mods:SetFreeCamSmooth(v) end, true)
lookCell:AddLabel("WASD  E up  Q down")

-- spectate
local specLabel = targetCell:AddLabel("Camera: Normal")
targetCell:AddTextBox("Player", "Player name", function(text)
	if text == "" or text == "Player name" then return end
	local p = mods:FindPlayer(text)
	if p then mods:Spectate(p) else ui:Notify("Player not found") end
end)
targetCell:AddButton("Stop (Back To Me)", function() mods:StopCamera() end)

cycleCell:AddButton("Previous Player", function()
	local p = mods:SpectatePrev()
	ui:Notify(p and ("Spectating " .. p.DisplayName) or "No other players")
end)
cycleCell:AddButton("Next Player", function()
	local p = mods:SpectateNext()
	ui:Notify(p and ("Spectating " .. p.DisplayName) or "No other players")
end)

modeCell:AddToggle("First-Person (POV)", false, function(on) mods:SetSpectatePOV(on) end)
modeCell:AddButton("Free Cam Around Them", function()
	local target = mods.SpectateTarget
	if target and mods:FocusFreeCam(target) then
		ui:Notify("Free Cam focused on " .. target.DisplayName)
	else
		ui:Notify("Spectate someone first")
	end
end)

-- keep the UI in sync when the camera changes (hotkeys, player leaving, Reset...)
mods.OnCameraChanged = function(mode)
	specLabel.Text = mods:GetCameraStatus()
	freeCam.Set(mode == "Free")
end

-- WORLD: Teleport + World + Audio in one tab -----------------------------------
local worldTab = ui:AddTab("World", "World", "🌍")
local spotCells = { worldTab:AddQuad("Spots", "Spots", { "Spot 1", "Spot 2", "Spot 3", "Spot 4" }) }
local playerCell, clickCell, glideCell, backCell = worldTab:AddQuad("Travel", "Travel", { "Player", "Click", "Glide", "Back" })
local gravityCell, timeCell, lightCell = worldTab:AddQuad("Env", "Env", { "Gravity", "Time", "Light" })
local audioCell, audioNoteCell = worldTab:AddQuad("Audio", "Audio", { "Master", "Notes" })

-- four save slots: Save Here remembers where you stand, Go takes you back
for i, cell in spotCells do
	local status = cell:AddLabel("Empty")
	cell:AddButton("Save Here", function()
		if mods:SaveSlot(i) then
			local p = mods:GetSlot(i)
			status.Text = string.format("%d, %d, %d", math.round(p.X), math.round(p.Y), math.round(p.Z))
			ui:Notify("Spot " .. i .. " saved")
		else
			ui:Notify("No character to save")
		end
	end)
	cell:AddButton("Go", function()
		ui:Notify(mods:GoSlot(i) and ("Spot " .. i) or "Spot " .. i .. " is empty")
	end)
end

local tpName = ""
playerCell:AddTextBox("Player", "Player name", function(text)
	tpName = (text == "Player name") and "" or text
end)
playerCell:AddButton("Teleport", function()
	local p = mods:FindPlayer(tpName)
	if not p then ui:Notify("Player not found") return end
	ui:Notify(mods:TeleportToPlayer(p) and ("To " .. p.DisplayName) or "They have no character")
end)
playerCell:AddButton("Next Player", function()
	local p = mods:TeleportStep(1)
	ui:Notify(p and ("To " .. p.DisplayName) or "No other players")
end)

toggle(clickCell, "Click Teleport", "clickTp", false, function(on)
	mods:SetClickTeleport(on)
	ui:Notify("Click Teleport " .. onOff(on) .. (on and " (Ctrl + Click)" or ""))
end)
clickCell:AddLabel("Ctrl + Click the ground")

toggle(glideCell, "Smooth Glide", "glide", false, function(on) mods:SetGlide(on) end, true)
slider(glideCell, "Glide Time (ms)", "glideTime", 100, 1500, 450, function(v) mods:SetGlideTime(v / 1000) end, true)

backCell:AddButton("Undo Teleport", function()
	ui:Notify(mods:UndoTeleport() and "Went back" or "Nothing to undo")
end)
backCell:AddButton("Respawn", function() mods:Respawn() end)

slider(gravityCell, "Gravity", "gravity", 0, 400, defaultGravity, function(v) mods:SetGravity(v) end)
gravityCell:AddButton("Reset", function() mods:ResetValue("Gravity"); restore("gravity") end)

slider(timeCell, "Time of Day", "timeOfDay", 0, 24, defaultClock, function(v) mods:SetTimeOfDay(v) end)
toggle(timeCell, "Freeze Time", "freezeTime", false, function(on) mods:SetFreezeTime(on) end)
timeCell:AddButton("Reset", function() mods:ResetValue("ClockTime"); restore("timeOfDay") end)

toggle(lightCell, "Fullbright", "fullbright", false, function(on)
	mods:SetFullbright(on)
	ui:Notify("Fullbright " .. onOff(on))
end)
toggle(lightCell, "No Fog", "noFog", false, function(on) mods:SetNoFog(on) end)

-- audio: game volume to a percent, voice chat is never touched
local audio = Audio.new()
toggle(audioCell, "Volume Control", "audioOn", false, function(on)
	audio:SetEnabled(on)
	ui:Notify("Volume control " .. onOff(on))
end, true)
slider(audioCell, "Game Volume %", "audioPct", 0, 200, 100, function(v) audio:Set("Percent", v) end, true)
audioCell:AddButton("Mute Game (Voice Stays)", function()
	setEntry("audioOn", true)
	setEntry("audioPct", 0)
end)
audioCell:AddButton("Back To 100%", function() setEntry("audioPct", 100) end)

audioNoteCell:AddLabel("Scales game sounds only")
audioNoteCell:AddLabel("Voice chat is never touched")
audioNoteCell:AddLabel("100% = normal, 200% = louder")
audioNoteCell:AddLabel("Off = everything restored")

-- VISUALS ---------------------------------------------------------------------
local visualsTab = ui:AddTab("Visuals", "Visuals", "👀")
local showCell, tagCell, tracerCell, rangeCell = visualsTab:AddQuad("ESP", "ESP", { "Show", "Tags", "Tracers", "Range" })

toggle(showCell, "ESP", "espEnabled", false, function(on) visuals:SetEnabled(on) end, true)
toggle(showCell, "Chams", "espChams", true, function(on) visuals:Set("Chams", on) end, true)
toggle(showCell, "Team Check", "espTeamCheck", true, function(on) visuals:Set("TeamCheck", on) end, true)
toggle(showCell, "Team Colors", "espTeamColors", false, function(on) visuals:Set("TeamColors", on) end, true)

toggle(tagCell, "Names", "espNames", true, function(on) visuals:Set("Names", on) end, true)
toggle(tagCell, "Distance", "espDistance", true, function(on) visuals:Set("Distance", on) end, true)
toggle(tagCell, "Health", "espHealth", true, function(on) visuals:Set("Health", on) end, true)
toggle(tagCell, "Health Colors", "espHealthColors", false, function(on) visuals:Set("HealthColors", on) end, true)

toggle(tracerCell, "Tracers", "espTracers", false, function(on) visuals:Set("Tracers", on) end, true)
dropdown(tracerCell, "Origin", "espTracerOrigin", { "Bottom", "Center", "Mouse" }, "Bottom",
	function(v) visuals:Set("TracerOrigin", v) end, true)
slider(tracerCell, "Thickness", "espTracerThick", 1, 5, 1, function(v) visuals:Set("TracerThickness", v) end, true)
if not visuals:HasDrawing() then tracerCell:AddLabel("Needs Drawing support") end

slider(rangeCell, "Max Distance", "espMaxDist", 100, 5000, 2000, function(v) visuals:Set("MaxDistance", v) end, true)
slider(rangeCell, "Fill Transp %", "espFillTrans", 0, 100, 60, function(v) visuals:Set("FillTransparency", v / 100) end, true)
slider(rangeCell, "Text Size", "espTextSize", 10, 24, 14, function(v) visuals:Set("TextSize", v) end, true)

local fillCell, outlineCell = visualsTab:AddQuad("Colors", "Colors", { "Fill", "Outline" })
color(fillCell, "Fill Color", "espFillColor", Color3.fromRGB(255, 60, 60), function(c) visuals:Set("FillColor", c) end, true)
color(outlineCell, "Outline Color", "espOutlineColor", Color3.fromRGB(255, 255, 255), function(c) visuals:Set("OutlineColor", c) end, true)

-- TRACKING --------------------------------------------------------------------
local tracking = ui:AddTab("Tracking", "Tracking", "🎯")
local trackCell, pickCell, feelTrackCell, checkCell = tracking:AddQuad("Aim", "Aim", { "Track", "Target", "Feel", "Checks" })

toggle(trackCell, "Tracking", "trackEnabled", false, function(on) mods:SetTracking(on) end, true)
dropdown(trackCell, "Activate", "trackMode", { "Hold Right Mouse", "Hold Left Mouse", "Always" }, "Hold Right Mouse",
	function(v) mods:SetTrackOption("Mode", v) end, true)
trackCell:AddLabel("Turns toward your cursor")

dropdown(pickCell, "Part", "trackPart", { "Head", "HumanoidRootPart", "UpperTorso" }, "Head",
	function(v) mods:SetTrackOption("Part", v) end, true)
dropdown(pickCell, "Pick By", "trackPriority", { "Cursor", "Distance", "Health" }, "Cursor",
	function(v) mods:SetTrackOption("Priority", v) end, true)

slider(feelTrackCell, "Speed", "trackSpeed", 1, 40, 12, function(v) mods:SetTrackOption("Speed", v) end, true)
slider(feelTrackCell, "FOV (px)", "trackFov", 30, 800, 250, function(v) mods:SetTrackOption("FOV", v) end, true)

toggle(checkCell, "Show FOV Circle", "trackShowFov", false, function(on) mods:SetTrackOption("ShowFOV", on) end, true)
toggle(checkCell, "Team Check", "trackTeamCheck", true, function(on) mods:SetTrackOption("TeamCheck", on) end, true)
toggle(checkCell, "Wall Check", "trackWallCheck", false, function(on) mods:SetTrackOption("WallCheck", on) end, true)

-- GUARD -----------------------------------------------------------------------
local guardTab = ui:AddTab("Guard", "Guard", "🛡")
local watchCell, guardChecks, shieldCell, flagCell = guardTab:AddQuad("Guard", "Guard", { "Watch", "Checks", "Shield", "Flags" })

local flaggedLabel, lastLabel
local function refreshFlags()
	local list = guard:GetFlagged()
	flaggedLabel.Text = "Flagged: " .. #list
	local last = list[#list]
	local rec = last and guard:GetRecord(last)
	lastLabel.Text = rec and ("Last: " .. last.Name .. " (" .. rec.Last .. ")") or "Last: none"
end

toggle(watchCell, "Watch Players", "guardMonitor", false, function(on)
	guard:Set("Monitor", on)
	ui:Notify("Guard watch " .. onOff(on))
end, true)
toggle(watchCell, "Alerts", "guardAlerts", true, function(on) guard:Set("Alerts", on) end, true)
toggle(watchCell, "Highlight Flagged", "guardColor", true, function(on) visuals:Set("FlagColor", on) end, true)
slider(watchCell, "Strikes To Flag", "guardStrikes", 2, 10, 4, function(v) guard:Set("StrikesToFlag", v) end, true)

toggle(guardChecks, "Speed", "guardSpeed", true, function(on) guard:Set("Speed", on) end, true)
toggle(guardChecks, "Fly", "guardFly", true, function(on) guard:Set("Fly", on) end, true)
toggle(guardChecks, "Teleport", "guardTeleport", true, function(on) guard:Set("Teleport", on) end, true)
toggle(guardChecks, "Fling", "guardFling", true, function(on) guard:Set("Fling", on) end, true)
toggle(guardChecks, "Spin", "guardSpin", true, function(on) guard:Set("Spin", on) end, true)
slider(guardChecks, "Speed Tolerance %", "guardTolerance", 120, 400, 200, function(v) guard:Set("SpeedTolerance", v) end, true)
slider(guardChecks, "Spin Min rad/s", "guardSpinMin", 4, 40, 10, function(v) guard:Set("SpinMin", v) end, true)

toggle(shieldCell, "No Player Collision", "guardNoCollide", false, function(on)
	guard:Set("NoCollide", on)
	ui:Notify("Player collision " .. (on and "off" or "on"))
end, true)
toggle(shieldCell, "Anti-Fling", "guardAntiFling", false, function(on) guard:Set("AntiFling", on) end, true)
shieldCell:AddLabel("No pushing, spin or launch")
toggle(shieldCell, "Anti-Void", "guardAntiVoid", false, function(on) guard:Set("AntiVoid", on) end, true)
toggle(shieldCell, "Block Forced TP", "guardAntiSnap", false, function(on) guard:Set("AntiSnap", on) end, true)
slider(shieldCell, "Max Self Speed", "guardMaxSpeed", 100, 600, 250, function(v) guard:Set("MaxSelfSpeed", v) end, true)

flaggedLabel = flagCell:AddLabel("Flagged: 0")
lastLabel = flagCell:AddLabel("Last: none")
flagCell:AddButton("Spectate Last", function()
	local list = guard:GetFlagged()
	local p = list[#list]
	if p and mods:Spectate(p) then ui:Notify("Spectating " .. p.DisplayName) else ui:Notify("Nobody flagged") end
end)
flagCell:AddButton("Clear Flags", function()
	guard:ClearFlags()
	ui:Notify("Flags cleared")
end)

guard.OnChange = refreshFlags
-- shown once per player + cheat type
guard.OnFlag = function(p, kind) ui:Notify("Player " .. p.Name .. " Detected " .. kind, 4) end

-- VEHICLE ---------------------------------------------------------------------
-- Sit in any vehicle: it is classified (Car / Bike / Boat / Aircraft) and the mode you pick is read per type.
local vehicle = Vehicle.new()
vehicle.OnMove = function() guard:Allow(2) end -- Flip Upright / anti-flip must not trip Block Forced TP
do -- your own boost and speed assist must not trip the guard's fling / speed checks
	local baseExempt = guard.IsExempt
	guard.IsExempt = function() return baseExempt() or vehicle:IsActive() end
end

local VEH_KEYS = {
	Speed = "vehSpeed", Torque = "vehTorque", Turn = "vehTurn", Grip = "vehGrip", TopSpeed = "vehTop",
	Accel = "vehAccel", BoostCap = "vehBoostCap", LowGrav = "vehLowGrav", AntiFlip = "vehAntiFlip",
}
-- moves the sliders to the numbers a mode / vehicle type just produced (they are already applied)
local function syncVehicle(vals)
	for field, key in VEH_KEYS do
		local entry = registry[key]
		if entry and vals[field] ~= nil then
			entry.value = vals[field]
			pcall(entry.control.Set, vals[field])
		end
	end
end

local vehicleTab = ui:AddTab("Vehicle", "Vehicle", "🚗")
local vStatusCell, vModeCell, vTuneCell, vAssistCell = vehicleTab:AddQuad("Drive", "Drive", { "Vehicle", "Mode", "Tuning", "Assist" })

local vehStatus = vStatusCell:AddLabel("Not in a vehicle")
toggle(vStatusCell, "Vehicle Mods", "vehEnabled", false, function(on)
	vehicle:SetEnabled(on)
	ui:Notify("Vehicle mods " .. onOff(on))
end, true)
vStatusCell:AddDropdown("Type", Vehicle.TypeNames, "Auto", function(kind) syncVehicle(vehicle:SetTypeOverride(kind)) end)
vStatusCell:AddLabel("Auto = detected from the model")

vModeCell:AddDropdown("Mode", Vehicle.ModeNames, "Stock", function(name) syncVehicle(vehicle:SetMode(name)) end)
vModeCell:AddLabel("Stock Sport Drift Rugged Rocket")
vModeCell:AddLabel("Each one reads per vehicle type")
vModeCell:AddLabel("Custom = never auto-changes")

slider(vTuneCell, "Top Speed %", "vehSpeed", 25, 500, 100, function(v) vehicle:Set("Speed", v) end, true)
slider(vTuneCell, "Torque %", "vehTorque", 25, 500, 100, function(v) vehicle:Set("Torque", v) end, true)
slider(vTuneCell, "Turn %", "vehTurn", 25, 300, 100, function(v) vehicle:Set("Turn", v) end, true)
slider(vTuneCell, "Grip %", "vehGrip", 10, 300, 100, function(v) vehicle:Set("Grip", v) end, true)

slider(vAssistCell, "Assist Top Speed", "vehTop", 0, 500, 0, function(v) vehicle:Set("TopSpeed", v) end, true)
slider(vAssistCell, "Assist Accel", "vehAccel", 10, 400, 60, function(v) vehicle:Set("Accel", v) end, true)
slider(vAssistCell, "Low Gravity %", "vehLowGrav", 0, 100, 0, function(v) vehicle:Set("LowGrav", v) end, true)
toggle(vAssistCell, "Reverse Axis", "vehReverse", false, function(on) vehicle:Set("ReverseAxis", on) end, true)
vAssistCell:AddLabel("0 = assist off. Flip axis if it pushes backwards")

local vBoostCell, vSafeCell, vAttrCell = vehicleTab:AddQuad("Extras", "Extras", { "Boost", "Safety", "Attributes" })

toggle(vBoostCell, "Boost", "vehBoost", true, function(on) vehicle:Set("BoostOn", on) end, true)
slider(vBoostCell, "Boost Accel", "vehBoostAccel", 20, 400, 120, function(v) vehicle:Set("BoostAccel", v) end, true)
slider(vBoostCell, "Boost Cap", "vehBoostCap", 50, 800, 250, function(v) vehicle:Set("BoostCap", v) end, true)
keybind(vBoostCell, "Boost Key", "keyBoost", Enum.KeyCode.LeftShift, function(k) vehicle.BoostKey = k end)

toggle(vSafeCell, "Anti-Flip", "vehAntiFlip", false, function(on) vehicle:Set("AntiFlip", on) end, true)
toggle(vSafeCell, "Restore On Exit", "vehRestore", true, function(on) vehicle:Set("Restore", on) end, true)
vSafeCell:AddButton("Flip Upright", function()
	ui:Notify(vehicle:Upright() and "Flipped upright" or "Sit in a vehicle first")
end)
local uprightKey = keybind(vSafeCell, "Upright Key", "keyUpright", Enum.KeyCode.U)
keybind(vSafeCell, "Handbrake Key", "keyBrake", Enum.KeyCode.X, function(k) vehicle.BrakeKey = k end)

-- attribute editor: cycle through the numeric Attributes / Number values found on the vehicle
local attrNames, attrIdx = {}, 0
local attrLabel = vAttrCell:AddLabel("Press Scan / Next")
local attrBox = vAttrCell:AddTextBox("Value", "", function() end)
local function showAttr()
	local name = attrNames[attrIdx]
	if not name then
		attrLabel.Text = "Nothing found"
		attrBox.Set("")
		return
	end
	local v = vehicle:GetValue(name)
	attrLabel.Text = name
	attrBox.Set(v ~= nil and tostring(v) or "")
end
vAttrCell:AddButton("Scan / Next", function()
	if not vehicle:GetStatus() then ui:Notify("Turn Vehicle Mods on and sit in a vehicle") return end
	attrNames = vehicle:GetValueNames()
	attrIdx = #attrNames > 0 and (attrIdx % #attrNames + 1) or 0
	showAttr()
	if #attrNames > 0 then ui:Notify(#attrNames .. " values found") end
end)
local function setAttr(n)
	local name = attrNames[attrIdx]
	if not (name and n) then ui:Notify("Pick a value first") return end
	if vehicle:SetValue(name, n) then
		showAttr()
		ui:Notify(name .. " = " .. tostring(vehicle:GetValue(name)))
	else
		ui:Notify("Could not change it")
	end
end
vAttrCell:AddButton("Apply Value", function() setAttr(tonumber(attrBox.Get())) end)
vAttrCell:AddButton("x2", function() local v = tonumber(attrBox.Get()); setAttr(v and v * 2) end)
vAttrCell:AddButton("Half", function() local v = tonumber(attrBox.Get()); setAttr(v and v / 2) end)
vAttrCell:AddButton("Restore Values", function() vehicle:RestoreValues(); showAttr() end)

vehicle.OnChanged = function(info, vals)
	vehStatus.Text = info and (info.Name .. "  [" .. info.Type .. "]") or "Not in a vehicle"
	attrNames, attrIdx = {}, 0
	attrLabel.Text = "Press Scan / Next"
	syncVehicle(vals)
	if info then ui:Notify("Vehicle: " .. info.Name .. " (" .. info.Type .. ")") end
end

-- GAMES -----------------------------------------------------------------------------
-- Murder Mystery 2. (More games: add an entry to Games.List, a module like MM2.lua and a quad here.)
local mm2 = MM2.new()
mm2.Teleport = function(cf) return mods:TeleportTo(cf) end -- goes through the guard exemption + undo
local detected = Games.Detect()

local gamesTab = ui:AddTab("Games", "Games", "🎮")
local gStatusCell, gRoleCell, gGunCell, gCoinCell = gamesTab:AddQuad("MM2", "MM2", { "Status", "Roles", "Gun", "Coins" })

gStatusCell:AddLabel("Game: " .. (detected and detected.Name or "not recognised"))
local murdererLabel = gStatusCell:AddLabel("Murderer: ?")
local sheriffLabel = gStatusCell:AddLabel("Sheriff: ?")
gStatusCell:AddButton("Clear Roles", function()
	mm2:ClearRoles()
	murdererLabel.Text, sheriffLabel.Text = "Murderer: ?", "Sheriff: ?"
end)
if not detected or detected.Id ~= "MM2" then gStatusCell:AddLabel("Only works inside MM2") end

mm2.OnRole = function(p, role)
	local label = role == "Murderer" and murdererLabel or sheriffLabel
	label.Text = role .. ": " .. p.DisplayName
	if mm2.Settings.Alerts then
		ui:Notify((p == mm2.Player and "You are the " or (p.DisplayName .. " is the ")) .. role, 4)
	end
end
mm2.OnGun = function()
	if mm2.Settings.Alerts and mm2.Settings.GunESP then ui:Notify("The gun was dropped!", 4) end
end

toggle(gRoleCell, "Role ESP", "mm2Roles", false, function(on) mm2:Set("RoleESP", on) end, true)
toggle(gRoleCell, "Show Innocents", "mm2Innocents", false, function(on) mm2:Set("Innocents", on) end, true)
toggle(gRoleCell, "Name Tags", "mm2Tags", true, function(on) mm2:Set("Tags", on) end, true)
toggle(gRoleCell, "Role Alerts", "mm2Alerts", true, function(on) mm2:Set("Alerts", on) end, true)
gRoleCell:AddLabel("Learned from the Knife / Gun held")

toggle(gGunCell, "Gun Drop ESP", "mm2GunEsp", false, function(on) mm2:Set("GunESP", on) end, true)
toggle(gGunCell, "Return After Grab", "mm2Return", true, function(on) mm2:Set("ReturnAfterGun", on) end, true)
gGunCell:AddButton("Grab Gun", function()
	local ok, err = mm2:GrabGun()
	ui:Notify(ok and "Fetching the gun..." or err)
end)

toggle(gCoinCell, "Auto Coins", "mm2Coins", false, function(on)
	mm2:Set("AutoCoins", on)
	ui:Notify("Auto coins " .. onOff(on))
end, true)
slider(gCoinCell, "Delay (ms)", "mm2CoinDelay", 200, 1500, 700, function(v) mm2:Set("CoinDelay", v) end, true)
gCoinCell:AddLabel("Teleports to each coin in turn")

-- INFO ------------------------------------------------------------------------
local info = ui:AddTab("Info", "Info", "📊")
local perfCell, charCell, sessionCell = info:AddQuad("Stats", "Stats", { "Performance", "Character", "Session" })
local fpsLabel = perfCell:AddLabel("FPS: --")
local pingLabel = perfCell:AddLabel("Ping: --")
local memLabel = perfCell:AddLabel("Memory: --")
local posLabel = charCell:AddLabel("Pos: --")
local speedLabel = charCell:AddLabel("Speed: --")
local hpLabel = charCell:AddLabel("Health: --")
local playersLabel = sessionCell:AddLabel("Players: --")
local timeLabel = sessionCell:AddLabel("Time: --")

local idleCell, serverCell = info:AddQuad("Utility", "Utility", { "Idle", "Server" })
toggle(idleCell, "Anti-AFK", "antiAfk", false, function(on)
	mods:SetAntiAFK(on)
	ui:Notify("Anti-AFK " .. onOff(on))
end)
idleCell:AddLabel("No idle kick")
serverCell:AddButton("Rejoin Server", function()
	ui:Notify(mods:Rejoin() and "Rejoining..." or "Rejoin failed")
end)

-- refresh the live stats a few times per second (only while that page is visible)
task.spawn(function()
	while ui.Gui.Parent do
		task.wait(0.25)
		local shown = ui:IsTabFloating("Info") or (ui.IsOpen and not ui.Minimized and ui.CurrentTab == "Info")
		if shown and info.CurrentSub == "Stats" then
			local s = mods:GetStats()
			fpsLabel.Text = "FPS: " .. s.FPS
			pingLabel.Text = "Ping: " .. s.Ping .. " ms"
			memLabel.Text = "Memory: " .. s.Memory .. " MB"
			posLabel.Text = string.format("Pos: %d, %d, %d",
				math.round(s.Position.X), math.round(s.Position.Y), math.round(s.Position.Z))
			speedLabel.Text = "Speed: " .. s.Speed .. " studs/s"
			hpLabel.Text = "Health: " .. s.Health .. " / " .. s.MaxHealth
			playersLabel.Text = "Players: " .. s.Players .. " / " .. s.MaxPlayers
			timeLabel.Text = string.format("Time: %d:%02d", s.Session // 60, s.Session % 60)
		end
	end
end)

-- SETTINGS: everything about the menu itself ----------------------------------
local cfgName = "default"

-- every registered setting -> plain table (Color3 becomes {r,g,b,color=true})
local function collect()
	local values = {}
	for key, entry in registry do
		local v = entry.value
		if typeof(v) == "Color3" then
			v = {
				r = math.floor(v.R * 255 + 0.5),
				g = math.floor(v.G * 255 + 0.5),
				b = math.floor(v.B * 255 + 0.5),
				color = true,
			}
		end
		values[key] = v
	end
	return { version = 2, values = values }
end

-- applied in alphabetical key order so dependent settings (menuScheme before menuTint) stay stable
local function applyConfig(data)
	if type(data) ~= "table" or type(data.values) ~= "table" then return 0 end
	local keys = {}
	for key in data.values do
		if registry[key] then table.insert(keys, key) end
	end
	table.sort(keys)
	local count = 0
	for _, key in keys do
		local entry, v = registry[key], data.values[key]
		if type(v) == "table" and v.color then v = Color3.fromRGB(v.r, v.g, v.b) end
		-- skip no-op writes so untouched sliders don't override the game's own values
		if v ~= entry.default or entry.value ~= entry.default or entry.resetApply then
			setEntry(key, v, true)
		end
		count += 1
	end
	dirtyAt = nil
	return count
end

-- the menu toggle key is bound from the bottom bar, so it is registered by hand
registry.menuToggleKey = {
	value = ui.ToggleKey.Name, default = ui.ToggleKey.Name, resetApply = true,
	control = { Set = function() end },
	apply = function(name)
		local code = name and Enum.KeyCode[name]
		if code then ui:SetToggleKey(code) end
	end,
}

local settings = ui:AddTab("Settings", "Settings", "🔧")

-- MENU: look + dock ------------------------------------------------------------------------
local lookMenuCell, dockCell = settings:AddQuad("Menu", "Menu", { "Look", "Dock" })

local ACCENTS = {
	Blue = Color3.fromRGB(53, 132, 228), Green = Color3.fromRGB(46, 194, 126),
	Purple = Color3.fromRGB(176, 111, 222), Orange = Color3.fromRGB(255, 163, 72),
	Red = Color3.fromRGB(237, 51, 59), Pink = Color3.fromRGB(246, 116, 176),
}
local ACCENT_NAMES = { "Default", "Blue", "Green", "Purple", "Orange", "Red", "Pink" }
local scheme = "Default"

dropdown(lookMenuCell, "Color Scheme", "menuScheme", ui:GetThemeNames(), "Default", function(name)
	scheme = name
	ui:SetTheme(name)
	-- a scheme brings its own accent
	registry.menuTint.value = "Default"
	registry.menuTint.control.Set("Default")
end, true)
dropdown(lookMenuCell, "Accent", "menuTint", ACCENT_NAMES, "Default", function(name)
	if name == "Default" then ui:SetTheme(scheme) else ui:SetAccent(ACCENTS[name]) end
end, true)
slider(lookMenuCell, "UI Scale %", "menuScale", 30, 160, 60, function(v) ui:SetUserScale(v / 100) end, true)
slider(lookMenuCell, "Transparency %", "menuTransp", 0, 70, 0, function(v) ui:SetPanelTransparency(v / 100) end, true)

dropdown(dockCell, "Dock Side", "menuDock", ui:GetDockSides(), "Left", function(side) ui:SetDockSide(side) end, true)
toggle(dockCell, "Auto-hide", "menuAutoHide", true, function(on) ui:SetAutoHide(on) end, true)
slider(dockCell, "Hide After (s)", "menuHideAfter", 3, 60, 8, function(v) ui:SetIdleTime(v) end, true)
dockCell:AddButton("Reset Position", function() ui:ResetPosition() end)

-- COMFORT: tab labels, spacing, alerts, detached tabs ---------------------------------------
local confirmReset = true
local comfortTabs, comfortSpace, comfortToast, comfortFloat = settings:AddQuad("Comfort", "Comfort", { "Tabs", "Spacing", "Alerts", "Detach" })

dropdown(comfortTabs, "Tab Labels", "tabDisplay", ui:GetTabDisplayModes(), "Icons", function(v) ui:SetTabDisplay(v) end, true)
comfortTabs:AddLabel("Icons, Text or Both")
toggle(comfortTabs, "Confirm Reset", "confirmReset", true, function(on) confirmReset = on end, true)

slider(comfortSpace, "Tab Spacing", "tabGap", 0, 24, 8, function(v) ui:SetTabSpacing(v) end, true)
slider(comfortSpace, "Control Spacing", "controlGap", 0, 20, 6, function(v) ui:SetControlSpacing(v) end, true)

toggle(comfortToast, "Notifications", "notify", true, function(on) ui:SetNotifications(on) end, true)
dropdown(comfortToast, "Corner", "toastCorner", ui:GetToastCorners(), "Bottom Right", function(v) ui:SetToastCorner(v) end, true)
slider(comfortToast, "Duration %", "toastTime", 50, 300, 100, function(v) ui:SetToastTime(v / 100) end, true)

slider(comfortFloat, "Detached Size %", "floatScale", 50, 130, 100, function(v) ui:SetFloatScale(v / 100) end, true)
toggle(comfortFloat, "Lock Tabs", "lockTabs", false, function(on) ui:SetLockTabs(on) end, true)
comfortFloat:AddButton("Detach Current", function() ui:DetachCurrent() end)
comfortFloat:AddButton("Dock All", function() ui:DockAllTabs() end)
comfortFloat:AddLabel("Or drag a tab out")

-- KEYS: click a button, then press a key (Esc cancels, Backspace clears) ----------------
local keyMainCell, keyMoreCell = settings:AddQuad("Keys", "Keys", { "Actions", "Camera & Menu" })
local flyKey = keybind(keyMainCell, "Fly", "keyFly", Enum.KeyCode.F)
local noclipKey = keybind(keyMainCell, "Noclip", "keyNoclip", Enum.KeyCode.N)
local espKey = keybind(keyMainCell, "ESP", "keyEsp", Enum.KeyCode.Z)
local trackKey = keybind(keyMainCell, "Tracking", "keyTrack", Enum.KeyCode.T)
local freeCamKey = keybind(keyMainCell, "Free Cam", "keyFreeCam", Enum.KeyCode.G)

local specPrevKey = keybind(keyMoreCell, "Prev Player", "keyPrev", Enum.KeyCode.LeftBracket)
local specNextKey = keybind(keyMoreCell, "Next Player", "keyNext", Enum.KeyCode.RightBracket)
local camStopKey = keybind(keyMoreCell, "Stop Camera", "keyStopCam", Enum.KeyCode.End)
keybind(keyMoreCell, "Minimize Menu", "keyMinimize", nil, function(k) ui:SetMinimizeKey(k) end)
keyMoreCell:AddLabel("Esc cancels, Backspace clears")

local hotkeyConn = UserInputService.InputBegan:Connect(function(input, processed)
	if processed or ui:IsCapturing() or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local key = input.KeyCode
	if key == flyKey.Get() then
		flip("fly")
	elseif key == noclipKey.Get() then
		flip("noclip")
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
	elseif key == espKey.Get() then
		local on = not registry.espEnabled.value
		setEntry("espEnabled", on)
		ui:Notify("ESP " .. onOff(on))
	elseif key == uprightKey.Get() then
		if vehicle:Upright() then ui:Notify("Flipped upright") end
	elseif key == trackKey.Get() then
		local on = not registry.trackEnabled.value
		setEntry("trackEnabled", on)
		ui:Notify("Tracking " .. onOff(on))
	end
end)

-- CONFIG: save / load / share / reset --------------------------------------------------------
local fileCell, shareCell, resetCell = settings:AddQuad("Config", "Config", { "Save & Load", "Share", "Reset" })

local function saveNow(quiet)
	local ok, where = Config.Save(cfgName, collect())
	dirtyAt = nil
	if not quiet then
		ui:Notify(ok and ("Saved '" .. cfgName .. "' (" .. tostring(where) .. ")") or ("Save failed: " .. tostring(where)), 3.5)
	end
	return ok
end

local function loadNow()
	local data, err = Config.Load(cfgName)
	if data then
		ui:Notify("Loaded '" .. cfgName .. "' (" .. applyConfig(data) .. " settings)")
	else
		ui:Notify("Load failed: " .. tostring(err), 3.5)
	end
end

fileCell:AddTextBox("Name", cfgName, function(text)
	if text ~= "" then cfgName = text end
end)
fileCell:AddButton("Save", function() saveNow(false) end)
fileCell:AddButton("Load", loadNow)
fileCell:AddToggle("Auto-load on start", Config.GetAutoload() ~= nil, function(on)
	Config.SetAutoload(on and cfgName or nil)
	ui:Notify(on and ("Auto-load: " .. cfgName) or "Auto-load off")
end)

-- share: copy the whole config as text, or paste one in
local shareBox = shareCell:AddTextBox("Text", "", function() end)
shareCell:AddButton("Export (Copy)", function()
	local text, err = Config.Encode(collect())
	if not text then ui:Notify("Export failed: " .. tostring(err)) return end
	if Config.Copy(text) then
		ui:Notify("Config copied to the clipboard")
	else
		shareBox.Set(text)
		ui:Notify("No clipboard here: text placed in the box")
	end
end)
shareCell:AddButton("Import (From Box)", function()
	local data, err = Config.Decode(shareBox.Get())
	if data then
		ui:Notify("Imported " .. applyConfig(data) .. " settings")
	else
		ui:Notify("Import failed: " .. tostring(err))
	end
end)

toggle(resetCell, "Auto-save", "cfgAutosave", true, function() end, true)
resetCell:AddLabel(Config.Describe())

local resetArmed = false
local function resetAll()
	mods:Reset() -- turns every mod off and puts the character / world back
	for key, entry in registry do
		entry.value = entry.default
		pcall(entry.control.Set, entry.default)
		if entry.resetApply then pcall(entry.apply, entry.default) end -- tuning values live in the module
	end
	freeCam.Set(false)
	specLabel.Text = mods:GetCameraStatus()
	ui:Notify("Everything reset")
end

resetCell:AddButton("Reset Everything", function()
	if confirmReset and not resetArmed then
		resetArmed = true
		ui:Notify("Press again within 3s to reset everything", 3)
		task.delay(3, function() resetArmed = false end)
		return
	end
	resetArmed = false
	resetAll()
	touch()
end)

-- autosave: two quiet seconds after the last change, plus the toggle key (bound outside the registry)
task.spawn(function()
	while ui.Gui.Parent do
		task.wait(1)
		local tk = ui.ToggleKey and ui.ToggleKey.Name
		if tk and tk ~= registry.menuToggleKey.value then
			registry.menuToggleKey.value = tk
			touch()
		end
		if registry.cfgAutosave.value and dirtyAt and os.clock() - dirtyAt >= 2 then
			saveNow(true)
		end
	end
end)

-- apply the auto-load config once everything is built (falls back to a config named "default")
do
	local auto = Config.GetAutoload()
	if not auto and Config.Exists("default") then auto = "default" end
	if auto then
		local data = Config.Load(auto)
		if data then
			cfgName = auto
			applyConfig(data)
			ui:Notify("Auto-loaded '" .. auto .. "'")
		end
	end
end

-- handle returned to the loader: running the loader again calls this first
return {
	UI = ui,
	Mods = mods,
	Destroy = function()
		hotkeyConn:Disconnect()
		pcall(function() visuals:Destroy() end)
		pcall(function() guard:Destroy() end)
		pcall(function() vehicle:Destroy() end)
		pcall(function() mm2:Destroy() end)
		pcall(function() audio:Destroy() end)
		mods:Destroy()
		ui:Destroy()
	end,
}

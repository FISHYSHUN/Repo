-- modules/App.lua (formerly Main.client.lua)
-- Connects the UI module to the functionality module. Returns an object with :Destroy()
-- so the loader can replace a running menu when you execute it again.
--
-- LAYOUT: one side tab per topic, every page is a small grid of cards ("quad") instead of a long list.
--   Movement  Flight  Teleport  Camera  World  Visuals  Tracking  Info  Settings
local import = ...

local UserInputService = game:GetService("UserInputService")

local GuiUI = import("Window")
local PlayerMods = import("PlayerMods")
local Visuals = import("Visuals")
local Config = import("Config")

local ui = GuiUI.new({
	Title = "Player Menu",
	Subtitle = "v1.3",
	ToggleKey = Enum.KeyCode.RightShift, -- can be rebound with the button in the bottom bar
	Style = "Modern", -- Modern | WindowsXP | WindowsVista | Windows11 | Windows95 | KDEPlasma | GNOME | macOS
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
	-- CornerRadius = 16, -- every style starts at the max (16); lower it here or in Settings > Look
})

local mods = PlayerMods.new()
local visuals = Visuals.new()

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

local function register(key, default, apply, resetApply)
	local entry = { value = default, default = default, apply = apply, resetApply = resetApply }
	registry[key] = entry
	return entry
end

local function slider(page, label, key, min, max, default, apply, resetApply)
	local entry = register(key, default, apply, resetApply)
	entry.control = page:AddSlider(label, min, max, default, function(v) entry.value = v; apply(v) end)
	return entry.control
end

local function toggle(page, label, key, default, apply, resetApply)
	local entry = register(key, default, apply, resetApply)
	entry.control = page:AddToggle(label, default, function(on) entry.value = on; apply(on) end)
	return entry.control
end

local function dropdown(page, label, key, list, default, apply, resetApply)
	local entry = register(key, default, apply, resetApply)
	entry.control = page:AddDropdown(label, list, default, function(v) entry.value = v; apply(v) end)
	return entry.control
end

local function color(page, label, key, default, apply, resetApply)
	local entry = register(key, default, apply, resetApply)
	entry.control = page:AddColorPicker(label, default, function(c) entry.value = c; apply(c) end)
	return entry.control
end

-- set a registered control from code (hotkeys, config load)
local function setEntry(key, value)
	local entry = registry[key]
	if not entry then return end
	entry.value = value
	pcall(entry.control.Set, value)
	pcall(entry.apply, value)
end

-- put a control back to its default WITHOUT calling its apply (the caller already reset the real value)
local function restore(key)
	local entry = registry[key]
	if not entry then return end
	entry.value = entry.default
	pcall(entry.control.Set, entry.default)
end

local function flip(key) setEntry(key, not registry[key].value) end

-- MOVEMENT --------------------------------------------------------------------
local movement = ui:AddTab("Movement", "Movement")
local walkCell, jumpCell, sprintCell, bodyCell = movement:AddQuad("Speed", "Speed", { "Walk", "Jump", "Sprint", "Body" })

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

-- FLIGHT ----------------------------------------------------------------------
local flight = ui:AddTab("Flight", "Flight")
local flyCell, feelCell, noclipCell, airCell = flight:AddQuad("Fly", "Fly", { "Fly", "Feel", "Noclip", "Air" })

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

-- TELEPORT --------------------------------------------------------------------
local teleport = ui:AddTab("Teleport", "Teleport")

-- four save slots: Save Here remembers where you stand, Go takes you back
local spotCells = { teleport:AddQuad("Spots", "Spots", { "Spot 1", "Spot 2", "Spot 3", "Spot 4" }) }
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

local playerCell, clickCell, glideCell, backCell = teleport:AddQuad("Travel", "Travel", { "Player", "Click", "Glide", "Back" })

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

-- CAMERA ----------------------------------------------------------------------
local camera = ui:AddTab("Camera", "Camera")
local fovCell, zoomCell, freeCell, lookCell = camera:AddQuad("View", "View", { "FOV", "Zoom", "Free Cam", "Free Look" })

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

local targetCell, cycleCell, modeCell = camera:AddQuad("Spectate", "Spectate", { "Target", "Cycle", "Mode" })

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

-- WORLD -----------------------------------------------------------------------
local world = ui:AddTab("World", "World")
local gravityCell, timeCell, lightCell = world:AddQuad("World", "World", { "Gravity", "Time", "Light" })

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

-- VISUALS ---------------------------------------------------------------------
local visualsTab = ui:AddTab("Visuals", "Visuals")
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
local tracking = ui:AddTab("Tracking", "Tracking")
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

-- INFO ------------------------------------------------------------------------
local info = ui:AddTab("Info", "Info")
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
		if ui.IsOpen and not ui.Minimized and ui.CurrentTab == "Info" and info.CurrentSub == "Stats" then
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
-- save / load every registered setting to a file in your executor workspace
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
	return { version = 1, values = values }
end

local function applyConfig(data)
	if type(data) ~= "table" or type(data.values) ~= "table" then return 0 end
	local count = 0
	for key, v in data.values do
		local entry = registry[key]
		if entry then
			if type(v) == "table" and v.color then v = Color3.fromRGB(v.r, v.g, v.b) end
			-- skip no-op writes so untouched sliders don't override the game's own values
			if v ~= entry.default or entry.value ~= entry.default or entry.resetApply then
				setEntry(key, v)
			end
			count += 1
		end
	end
	return count
end

local settings = ui:AddTab("Settings", "Settings")

-- CONFIGS ---------------------------------------------------------------------
local nameCell, fileCell, manageCell, resetCell = settings:AddQuad("Configs", "Configs", { "Name", "File", "Manage", "Reset" })
local cfgName = "default"
nameCell:AddTextBox("Name", "default", function(text)
	if text ~= "" then cfgName = text end
end)
nameCell:AddToggle("Auto-load on start", false, function(on)
	Config.SetAutoload(on and cfgName or nil)
	ui:Notify(on and ("Auto-load: " .. cfgName) or "Auto-load off")
end)

fileCell:AddButton("Save Config", function()
	local ok, err = Config.Save(cfgName, collect())
	ui:Notify(ok and ("Saved '" .. cfgName .. "'") or ("Save failed: " .. tostring(err)))
end)
fileCell:AddButton("Load Config", function()
	local data, err = Config.Load(cfgName)
	if data then
		ui:Notify("Loaded '" .. cfgName .. "' (" .. applyConfig(data) .. " settings)")
	else
		ui:Notify("Load failed: " .. tostring(err))
	end
end)

manageCell:AddButton("Delete Config", function()
	ui:Notify(Config.Delete(cfgName) and ("Deleted '" .. cfgName .. "'") or "Nothing to delete")
end)
manageCell:AddButton("List Configs", function()
	local names = Config.List()
	ui:Notify(#names > 0 and ("Configs: " .. table.concat(names, ", ")) or "No saved configs")
end)
manageCell:AddLabel("PlayerMenu/configs")

resetCell:AddButton("Reset All Modifiers", function()
	mods:Reset() -- turns every mod off and puts the character / world back
	for key, entry in registry do
		entry.value = entry.default
		pcall(entry.control.Set, entry.default)
		if entry.resetApply then pcall(entry.apply, entry.default) end -- tuning values live in the module
	end
	freeCam.Set(false)
	specLabel.Text = mods:GetCameraStatus()
	ui:Notify("Everything reset")
end)
resetCell:AddLabel("Back to the defaults")

-- KEYS: click a button, then press a key (Esc cancels, Backspace clears) ----------------
local keyMoveCell, keyCamCell, keyVisCell, keyMenuCell = settings:AddQuad("Keys", "Keys", { "Movement", "Camera", "Visuals", "Menu" })
local flyKey = keyMoveCell:AddKeybind("Fly", Enum.KeyCode.F)
local noclipKey = keyMoveCell:AddKeybind("Noclip", Enum.KeyCode.N)

local freeCamKey = keyCamCell:AddKeybind("Free Cam", Enum.KeyCode.G)
local specPrevKey = keyCamCell:AddKeybind("Prev Player", Enum.KeyCode.LeftBracket)
local specNextKey = keyCamCell:AddKeybind("Next Player", Enum.KeyCode.RightBracket)
local camStopKey = keyCamCell:AddKeybind("Stop Camera", Enum.KeyCode.End)

local espKey = keyVisCell:AddKeybind("ESP", Enum.KeyCode.Z)
local trackKey = keyVisCell:AddKeybind("Tracking", Enum.KeyCode.T)

keyMenuCell:AddKeybind("Minimize", nil, function(key) ui:SetMinimizeKey(key) end)
keyMenuCell:AddLabel("Esc cancels")
keyMenuCell:AddLabel("Backspace clears")

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
	elseif key == trackKey.Get() then
		local on = not registry.trackEnabled.value
		setEntry("trackEnabled", on)
		ui:Notify("Tracking " .. onOff(on))
	end
end)

-- LOOK: style, colors, size, motion ----------------------------------------------------
local styleCell, accentCell, sizeCell, motionCell = settings:AddQuad("Look", "Look", { "Style", "Accent", "Size", "Motion" })
local accent, themeDrop, fontDrop, transSlider, cornerSlider

styleCell:AddDropdown("Style", ui:GetStyleNames(), ui:GetStyle(), function(name)
	local d = ui:SetStyle(name)
	if themeDrop then themeDrop.Set("Default") end
	if accent then accent.Set(d.Accent) end
	if fontDrop then fontDrop.Set(d.Font) end
	if transSlider then transSlider.Set(math.round(d.Transparency * 100)) end
	if cornerSlider then cornerSlider.Set(d.Corner) end
	ui:Notify("Style: " .. name)
end)
themeDrop = styleCell:AddDropdown("Color Scheme", ui:GetThemeNames(), "Default", function(name)
	accent.Set(ui:SetTheme(name)) -- the preset has its own accent, so sync the sliders
end)
fontDrop = styleCell:AddDropdown("Font", ui:GetFontNames(), "SourceSansBold", function(name) ui:SetFont(name) end)

accent = accentCell:AddColorPicker("Accent", ui:GetAccent(), function(c) ui:SetAccent(c) end)

sizeCell:AddSlider("UI Scale %", 30, 160, 60, function(v) ui:SetUserScale(v / 100) end)
transSlider = sizeCell:AddSlider("Transparency %", 0, 70, 20, function(v) ui:SetPanelTransparency(v / 100) end)
cornerSlider = sizeCell:AddSlider("Corner Radius", 0, 16, 16, function(v) ui:SetCornerRadius(v) end)

motionCell:AddSlider("Anim Speed %", 50, 200, 100, function(v) ui:SetAnimSpeed(v / 100) end)
motionCell:AddDropdown("Page Slide", { "Auto", "LeftToRight", "RightToLeft" }, "Auto", function(mode)
	ui:SetSlideMode(mode)
end)
motionCell:AddToggle("Card Entrance", true, function(on) ui:SetEntrance(on) end)

-- DOCK: where the bar sits, how thick it is, what it says -------------------------------
local posCell, barCell, widgetCell, textCell = settings:AddQuad("Dock", "Dock", { "Position", "Bar", "Widget", "Text" })
posCell:AddDropdown("Dock Side", ui:GetDockSides(), "Left", function(side) ui:SetDockSide(side) end)
posCell:AddToggle("Draggable", true, function(on) ui:SetDraggable(on) end)
posCell:AddButton("Reset Position", function() ui:ResetPosition() end)

barCell:AddSlider("Thickness", 36, 100, 56, function(v) ui:SetBarSize(v) end)
barCell:AddDropdown("Title Direction", ui:GetTitleRotations(), "Auto", function(mode) ui:SetTitleRotation(mode) end)

widgetCell:AddToggle("Auto-hide", true, function(on) ui:SetAutoHide(on) end)
widgetCell:AddSlider("Hide After (s)", 3, 60, 8, function(v) ui:SetIdleTime(v) end)
widgetCell:AddSlider("Widget Length", 50, 200, 84, function(v) ui:SetWidgetLength(v) end)

textCell:AddTextBox("Title", "Player Menu", function(text) if text ~= "" then ui:SetTitle(text) end end)
textCell:AddTextBox("Subtitle", "v1.3", function(text) ui:SetSubtitle(text) end)

-- apply the auto-load config (if one was set) once everything is built
do
	local auto = Config.GetAutoload()
	if auto then
		local data = Config.Load(auto)
		if data then
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
		mods:Destroy()
		ui:Destroy()
	end,
}

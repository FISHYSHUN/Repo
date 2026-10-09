-- modules/App.lua (formerly Main.client.lua)
-- Connects the UI module to the functionality module. Returns an object with :Destroy()
-- so the loader can replace a running menu when you execute it again.
local import = ...

local UserInputService = game:GetService("UserInputService")

local GuiUI = import("Window")
local PlayerMods = import("PlayerMods")
local Visuals = import("Visuals")
local Config = import("Config")

local ui = GuiUI.new({
	Title = "Player Menu",
	Subtitle = "v1.2",
	ToggleKey = Enum.KeyCode.RightShift, -- can be rebound with the button in the bottom bar
	Style = "Modern", -- Modern | WindowsXP | WindowsVista | Windows11 | Windows95 | KDEPlasma | GNOME | macOS
	DockSide = "Left", -- Left | Right | Top : which screen edge the bar is glued to
	BarSize = 56, -- bar thickness in px (36 - 100)
	UserScale = 0.6, -- starts at 60% (the slider in Settings > Size goes 30% - 160%)
	AutoHide = true, -- shrink into the edge widget when not used
	IdleTime = 8, -- seconds of inactivity before that happens
	WidgetLength = 84, -- length of the edge widget (px)
	-- StartCollapsed = true, -- start as the widget instead of the open menu
	TitleRotation = "Auto", -- Auto | Up | Down (Left / Right docks only)
	-- SlideMode = "LeftToRight", -- uncomment to always slide pages in from the left
	-- Theme = "Midnight", -- Default | Dark | Midnight | Forest | Crimson | Light
	-- CornerRadius = 16, -- every style starts at the max (16); lower it here or in Settings > Size
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
-- and restored from a config. resetApply = also re-apply the default on "Reset All".
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

-- SIDEBAR TAB: Movement ------------------------------------------------------
local movement = ui:AddTab("Movement", "Movement")

local speedPage = movement:AddSubTab("Speed", "Speed")
local walk = slider(speedPage, "Walk Speed", "walkSpeed", 16, 150, 16, function(v) mods:SetWalkSpeed(v) end)
local jump = slider(speedPage, "Jump Power", "jumpPower", 50, 250, 50, function(v) mods:SetJumpPower(v) end)
local hip = slider(speedPage, "Hip Height", "hipHeight", 0, 20, 2, function(v) mods:SetHipHeight(v) end)
speedPage:AddSection("Sprint (hold Left Shift)")
local sprint = speedPage:AddToggle("Sprint", false, function(on)
	mods:SetSprint(on)
	ui:Notify("Sprint " .. onOff(on))
end)
local sprintMul = slider(speedPage, "Sprint Speed %", "sprintSpeed", 110, 300, 160, function(v) mods:SetSprintMultiplier(v / 100) end)

local flightPage = movement:AddSubTab("Flight", "Flight")
local fly = flightPage:AddToggle("Fly", false, function(on)
	mods:SetFly(on)
	ui:Notify("Fly " .. onOff(on))
end)
flightPage:AddLabel("Fly: WASD to move, Space up, Ctrl down.")
local flySpeed = slider(flightPage, "Fly Speed", "flySpeed", 20, 200, 60, function(v) mods:SetFlySpeed(v) end)
local noclip = flightPage:AddToggle("Noclip", false, function(on)
	mods:SetNoclip(on)
	ui:Notify("Noclip " .. onOff(on))
end)

local extrasPage = movement:AddSubTab("Extras", "Extras")
local infJump = extrasPage:AddToggle("Infinite Jump", false, function(on) mods:SetInfiniteJump(on) end)
local clickTp = extrasPage:AddToggle("Click Teleport", false, function(on)
	mods:SetClickTeleport(on)
	ui:Notify("Click Teleport " .. onOff(on) .. (on and " (Ctrl + Click)" or ""))
end)
extrasPage:AddLabel("Click Teleport: hold Ctrl and click the ground.")
extrasPage:AddButton("Respawn Character", function() mods:Respawn() end)

-- SIDEBAR TAB: World ---------------------------------------------------------
local world = ui:AddTab("World", "World")

local physicsPage = world:AddSubTab("Physics", "Physics")
local gravity = slider(physicsPage, "Gravity", "gravity", 0, 400, defaultGravity, function(v) mods:SetGravity(v) end)

local cameraPage = world:AddSubTab("Camera", "Camera")
local fov = slider(cameraPage, "Field of View", "fov", 40, 120, defaultFov, function(v) mods:SetFOV(v) end)
local zoom = slider(cameraPage, "Max Zoom", "maxZoom", 10, 1000, defaultZoom, function(v) mods:SetMaxZoom(v) end)

local lightPage = world:AddSubTab("Lighting", "Lighting")
local fullbright = lightPage:AddToggle("Fullbright", false, function(on)
	mods:SetFullbright(on)
	ui:Notify("Fullbright " .. onOff(on))
end)
local clock = slider(lightPage, "Time of Day", "timeOfDay", 0, 24, defaultClock, function(v) mods:SetTimeOfDay(v) end)

-- Free cam + spectate: added to the existing World > Camera page (no new tabs,
-- so nothing here depends on icon names the Window module doesn't know about)
cameraPage:AddSection("Free Cam")
local freeCam = cameraPage:AddToggle("Free Cam", false, function(on)
	mods:SetFreeCam(on)
	ui:Notify("Free Cam " .. onOff(on))
end)
cameraPage:AddLabel("Hold Right Mouse to look. WASD move, E/Space up, Q down, Shift fast, Ctrl slow.")
local freeSpeed = slider(cameraPage, "Cam Speed", "freeCamSpeed", 5, 300, 50, function(v) mods:SetFreeCamSpeed(v) end)
local freeSens = slider(cameraPage, "Look Sensitivity %", "freeCamSens", 10, 100, 30, function(v) mods:SetFreeCamSensitivity(v / 100) end)

cameraPage:AddSection("Spectate")
local specLabel = cameraPage:AddLabel("Camera: Normal")
cameraPage:AddButton("Previous Player", function()
	local p = mods:SpectatePrev()
	ui:Notify(p and ("Spectating " .. p.DisplayName) or "No other players")
end)
cameraPage:AddButton("Next Player", function()
	local p = mods:SpectateNext()
	ui:Notify(p and ("Spectating " .. p.DisplayName) or "No other players")
end)
cameraPage:AddTextBox("Spectate Player", "Player name", function(text)
	if text == "" or text == "Player name" then return end
	local p = mods:FindPlayer(text)
	if p then mods:Spectate(p) else ui:Notify("Player not found") end
end)
cameraPage:AddToggle("First-Person View (POV)", false, function(on) mods:SetSpectatePOV(on) end)
cameraPage:AddButton("Free Cam Around This Player", function()
	local target = mods.SpectateTarget
	if target and mods:FocusFreeCam(target) then
		ui:Notify("Free Cam focused on " .. target.DisplayName)
	else
		ui:Notify("Spectate someone first")
	end
end)
cameraPage:AddButton("Stop (Back To Me)", function() mods:StopCamera() end)

-- keep the UI in sync when the camera changes (hotkeys, player leaving, Reset...)
mods.OnCameraChanged = function(mode)
	specLabel.Text = mods:GetCameraStatus()
	freeCam.Set(mode == "Free")
end

-- SIDEBAR TAB: Visuals (ESP + camera tracking) --------------------------------
-- If the Window module refuses a new tab / sub-tab name, these fall back to existing ones
-- instead of killing the whole menu.
local function safeTab(name)
	local ok, tab = pcall(function() return ui:AddTab(name, name) end)
	return ok and tab or world
end
local function safeSub(tab, name, fallback)
	local ok, page = pcall(function() return tab:AddSubTab(name, name) end)
	return ok and page or fallback
end

local visualsTab = safeTab("Visuals")

local espPage = safeSub(visualsTab, "ESP", cameraPage)
espPage:AddSection("Player ESP")
toggle(espPage, "ESP", "espEnabled", false, function(on) visuals:SetEnabled(on) end, true)
toggle(espPage, "Chams (highlight)", "espChams", true, function(on) visuals:Set("Chams", on) end, true)
toggle(espPage, "Name Tags", "espNames", true, function(on) visuals:Set("Names", on) end, true)
toggle(espPage, "Distance", "espDistance", true, function(on) visuals:Set("Distance", on) end, true)
toggle(espPage, "Health", "espHealth", true, function(on) visuals:Set("Health", on) end, true)
toggle(espPage, "Tracers", "espTracers", false, function(on) visuals:Set("Tracers", on) end, true)
toggle(espPage, "Team Check (hide teammates)", "espTeamCheck", true, function(on) visuals:Set("TeamCheck", on) end, true)
toggle(espPage, "Use Team Colors", "espTeamColors", false, function(on) visuals:Set("TeamColors", on) end, true)
slider(espPage, "Max Distance", "espMaxDist", 100, 5000, 2000, function(v) visuals:Set("MaxDistance", v) end, true)
slider(espPage, "Fill Transparency %", "espFillTrans", 0, 100, 60, function(v) visuals:Set("FillTransparency", v / 100) end, true)
slider(espPage, "Text Size", "espTextSize", 10, 24, 14, function(v) visuals:Set("TextSize", v) end, true)
espPage:AddSection("Colors")
color(espPage, "Fill Color", "espFillColor", Color3.fromRGB(255, 60, 60), function(c) visuals:Set("FillColor", c) end, true)
color(espPage, "Outline Color", "espOutlineColor", Color3.fromRGB(255, 255, 255), function(c) visuals:Set("OutlineColor", c) end, true)
espPage:AddLabel("Roblox draws at most 31 highlights at once. Tracers need an executor with Drawing support.")

local trackPage = safeSub(visualsTab, "Tracking", cameraPage)
trackPage:AddSection("Camera Tracking")
toggle(trackPage, "Camera Tracking", "trackEnabled", false, function(on) mods:SetTracking(on) end, true)
dropdown(trackPage, "Activate", "trackMode", { "Hold Right Mouse", "Hold Left Mouse", "Always" }, "Hold Right Mouse",
	function(v) mods:SetTrackOption("Mode", v) end, true)
dropdown(trackPage, "Target Part", "trackPart", { "Head", "HumanoidRootPart", "UpperTorso" }, "Head",
	function(v) mods:SetTrackOption("Part", v) end, true)
slider(trackPage, "Tracking Speed", "trackSpeed", 1, 40, 12, function(v) mods:SetTrackOption("Speed", v) end, true)
slider(trackPage, "Tracking FOV (px)", "trackFov", 30, 800, 250, function(v) mods:SetTrackOption("FOV", v) end, true)
toggle(trackPage, "Show FOV Circle", "trackShowFov", false, function(on) mods:SetTrackOption("ShowFOV", on) end, true)
toggle(trackPage, "Team Check", "trackTeamCheck", true, function(on) mods:SetTrackOption("TeamCheck", on) end, true)
toggle(trackPage, "Wall Check", "trackWallCheck", false, function(on) mods:SetTrackOption("WallCheck", on) end, true)
trackPage:AddLabel("Turns the camera toward the player closest to your cursor inside the circle.")
trackPage:AddLabel("Lower speed = smoother. Paused while free cam / spectate is on.")

-- SIDEBAR TAB: Info ----------------------------------------------------------
local info = ui:AddTab("Info", "Info")

local statsPage = info:AddSubTab("Stats", "Stats")
statsPage:AddSection("Live")
local fpsLabel = statsPage:AddLabel("FPS: --")
local pingLabel = statsPage:AddLabel("Ping: --")
local posLabel = statsPage:AddLabel("Position: --")
local speedLabel = statsPage:AddLabel("Speed: --")

local teleportPage = info:AddSubTab("Teleport", "Teleport")
teleportPage:AddLabel("Save your spot and come back to it.")
teleportPage:AddButton("Save Position", function()
	ui:Notify(mods:SavePosition() and "Position saved" or "No character to save")
end)
teleportPage:AddButton("Teleport To Saved", function()
	ui:Notify(mods:TeleportToSaved() and "Teleported" or "Nothing saved yet")
end)

-- refresh the live stats a few times per second (only while that page is visible)
task.spawn(function()
	while ui.Gui.Parent do
		task.wait(0.25)
		if ui.IsOpen and not ui.Minimized and ui.CurrentTab == "Info" then
			local s = mods:GetStats()
			fpsLabel.Text = "FPS: " .. s.FPS
			pingLabel.Text = "Ping: " .. s.Ping .. " ms"
			posLabel.Text = string.format("Position: %d, %d, %d",
				math.round(s.Position.X), math.round(s.Position.Y), math.round(s.Position.Z))
			speedLabel.Text = "Speed: " .. s.Speed .. " studs/s"
		end
	end
end)

-- BOTTOM-BAR TAB: Settings ---------------------------------------------------
-- Four short pages so nothing is crowded: Dock | Look | Size | Keys
local settings = ui:AddBottomTab("Settings", "Settings")

-- DOCK: where the bar sits, how thick it is, what it says
local dockPage = settings:AddSubTab("Dock", "Dock")
dockPage:AddSection("Position (click to change)")
dockPage:AddDropdown("Dock Side", ui:GetDockSides(), "Left", function(side) ui:SetDockSide(side) end)
dockPage:AddToggle("Draggable (along the edge)", true, function(on) ui:SetDraggable(on) end)
dockPage:AddButton("Reset Position", function() ui:ResetPosition() end)
dockPage:AddSection("Bar")
dockPage:AddSlider("Bar Thickness", 36, 100, 56, function(v) ui:SetBarSize(v) end)
dockPage:AddDropdown("Title Direction", ui:GetTitleRotations(), "Auto", function(mode) ui:SetTitleRotation(mode) end)
dockPage:AddSection("Edge widget (shown while the menu is tucked away)")
dockPage:AddToggle("Auto-hide when idle", true, function(on) ui:SetAutoHide(on) end)
dockPage:AddSlider("Auto-hide after (sec)", 3, 60, 8, function(v) ui:SetIdleTime(v) end)
dockPage:AddSlider("Widget Length", 50, 200, 84, function(v) ui:SetWidgetLength(v) end)
dockPage:AddSection("Bar text")
dockPage:AddTextBox("Title", "Player Menu", function(text) if text ~= "" then ui:SetTitle(text) end end)
dockPage:AddTextBox("Subtitle", "v1.2", function(text) ui:SetSubtitle(text) end)

-- LOOK: style, colors, font
local lookPage = settings:AddSubTab("Look", "Look")
local accent, themeDrop, fontDrop, transSlider, cornerSlider

lookPage:AddSection("Window style (click to change)")
lookPage:AddDropdown("Style", ui:GetStyleNames(), ui:GetStyle(), function(name)
	local d = ui:SetStyle(name)
	if themeDrop then themeDrop.Set("Default") end
	if accent then accent.Set(d.Accent) end
	if fontDrop then fontDrop.Set(d.Font) end
	if transSlider then transSlider.Set(math.round(d.Transparency * 100)) end
	if cornerSlider then cornerSlider.Set(d.Corner) end
	ui:Notify("Style: " .. name)
end)
themeDrop = lookPage:AddDropdown("Color Scheme", ui:GetThemeNames(), "Default", function(name)
	accent.Set(ui:SetTheme(name)) -- the preset has its own accent, so sync the sliders
end)
fontDrop = lookPage:AddDropdown("Font", ui:GetFontNames(), "SourceSansBold", function(name) ui:SetFont(name) end)
lookPage:AddSection("Accent color")
accent = lookPage:AddColorPicker("Accent", ui:GetAccent(), function(c) ui:SetAccent(c) end)

-- SIZE: scale, transparency, corners, animation
local sizePage = settings:AddSubTab("Size", "Size")
sizePage:AddSection("Window")
sizePage:AddSlider("UI Scale %", 30, 160, 60, function(v) ui:SetUserScale(v / 100) end)
transSlider = sizePage:AddSlider("Transparency %", 0, 70, 20, function(v) ui:SetPanelTransparency(v / 100) end)
cornerSlider = sizePage:AddSlider("Corner Radius", 0, 16, 16, function(v) ui:SetCornerRadius(v) end)
sizePage:AddSection("Animation")
sizePage:AddSlider("Animation Speed %", 50, 200, 100, function(v) ui:SetAnimSpeed(v / 100) end)
sizePage:AddDropdown("Page Slide", { "Auto", "LeftToRight", "RightToLeft" }, "Auto", function(mode)
	ui:SetSlideMode(mode)
end)

-- CONFIGS: save / load every registered setting to a file in your executor workspace
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

local cfgPage = safeSub(settings, "Configs", dockPage)
local cfgName = "default"
cfgPage:AddSection("Save and load your settings")
cfgPage:AddTextBox("Config Name", "default", function(text)
	if text ~= "" then cfgName = text end
end)
cfgPage:AddButton("Save Config", function()
	local ok, err = Config.Save(cfgName, collect())
	ui:Notify(ok and ("Saved '" .. cfgName .. "'") or ("Save failed: " .. tostring(err)))
end)
cfgPage:AddButton("Load Config", function()
	local data, err = Config.Load(cfgName)
	if data then
		ui:Notify("Loaded '" .. cfgName .. "' (" .. applyConfig(data) .. " settings)")
	else
		ui:Notify("Load failed: " .. tostring(err))
	end
end)
cfgPage:AddButton("Delete Config", function()
	ui:Notify(Config.Delete(cfgName) and ("Deleted '" .. cfgName .. "'") or "Nothing to delete")
end)
cfgPage:AddButton("List Configs", function()
	local names = Config.List()
	ui:Notify(#names > 0 and ("Configs: " .. table.concat(names, ", ")) or "No saved configs")
end)
cfgPage:AddToggle("Auto-load this config on start", false, function(on)
	Config.SetAutoload(on and cfgName or nil)
	ui:Notify(on and ("Auto-load: " .. cfgName) or "Auto-load off")
end)
cfgPage:AddLabel("Files: workspace/PlayerMenu/configs/<name>.json")

-- KEYS: hotkeys (click a button, then press a key; Esc cancels, Backspace clears)
local keysPage = settings:AddSubTab("Keys", "Keys")
keysPage:AddSection("Click a button, then press a key")
local flyKey = keysPage:AddKeybind("Fly Key", Enum.KeyCode.F)
local noclipKey = keysPage:AddKeybind("Noclip Key", Enum.KeyCode.N)
local freeCamKey = keysPage:AddKeybind("Free Cam Key", Enum.KeyCode.G)
local specPrevKey = keysPage:AddKeybind("Spectate Previous", Enum.KeyCode.LeftBracket)
local specNextKey = keysPage:AddKeybind("Spectate Next", Enum.KeyCode.RightBracket)
local camStopKey = keysPage:AddKeybind("Stop Camera", Enum.KeyCode.End)
local espKey = keysPage:AddKeybind("ESP Key", Enum.KeyCode.Z)
local trackKey = keysPage:AddKeybind("Tracking Key", Enum.KeyCode.T)
keysPage:AddKeybind("Minimize Key", nil, function(key) ui:SetMinimizeKey(key) end)
keysPage:AddLabel("Esc cancels, Backspace clears the bind.")

local hotkeyConn = UserInputService.InputBegan:Connect(function(input, processed)
	if processed or ui:IsCapturing() or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local key = input.KeyCode
	if key == flyKey.Get() then
		local on = not fly.Get()
		fly.Set(on)
		mods:SetFly(on)
		ui:Notify("Fly " .. onOff(on))
	elseif key == noclipKey.Get() then
		local on = not noclip.Get()
		noclip.Set(on)
		mods:SetNoclip(on)
		ui:Notify("Noclip " .. onOff(on))
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

-- Reset everything (button lives on the Extras page)
extrasPage:AddButton("Reset All Modifiers", function()
	mods:Reset()
	mods:SetSprintMultiplier(1.6)
	walk.Set(16); jump.Set(50); hip.Set(2)
	sprint.Set(false); sprintMul.Set(160)
	fly.Set(false); noclip.Set(false); infJump.Set(false); clickTp.Set(false)
	gravity.Set(defaultGravity); fov.Set(defaultFov); zoom.Set(defaultZoom)
	fullbright.Set(false); clock.Set(defaultClock)
	freeCam.Set(false); specLabel.Text = mods:GetCameraStatus()
	for _, entry in registry do
		if entry.resetApply then
			entry.value = entry.default
			pcall(entry.control.Set, entry.default)
			pcall(entry.apply, entry.default)
		end
	end
	ui:Notify("Everything reset")
end)

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

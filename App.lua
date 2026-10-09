-- modules/App.lua  (formerly Main.client.lua)
-- Connects the UI module to the functionality module. Returns an object with :Destroy()
-- so the loader can replace a running menu when you execute it again.
local import = ...

local UserInputService = game:GetService("UserInputService")

local GuiUI = import("Window")
local PlayerMods = import("PlayerMods")

local ui = GuiUI.new({
	Title = "Player Menu",
	Subtitle = "v1.1",
	ToggleKey = Enum.KeyCode.RightShift, -- can be rebound with the button in the bottom bar
	Style = "Modern",                    -- Modern | WindowsXP | WindowsVista | Windows11 | Windows95 | KDEPlasma | GNOME | macOS
	DockSide = "Left",                   -- Left | Right | Top : which screen edge the bar is glued to
	BarSize = 56,                        -- bar thickness in px (36 - 100)
	UserScale = 0.6,                     -- starts at 60% (the slider in Settings > Size goes 30% - 160%)
	AutoHide = true,                     -- shrink into the edge widget when not used
	IdleTime = 8,                        -- seconds of inactivity before that happens
	WidgetLength = 84,                   -- length of the edge widget (px)
	-- StartCollapsed = true,            -- start as the widget instead of the open menu
	TitleRotation = "Auto",              -- Auto | Up | Down (Left / Right docks only)
	-- SlideMode = "LeftToRight",        -- uncomment to always slide pages in from the left
	-- Theme = "Midnight",               -- Default | Dark | Midnight | Forest | Crimson | Light
	-- CornerRadius = 16,                -- every style starts at the max (16); lower it here or in Settings > Size
})
local mods = PlayerMods.new()

local defaultGravity = math.round(mods.Defaults.Gravity)
local defaultFov = math.clamp(math.round(mods.Defaults.FOV), 40, 120)
local defaultClock = math.clamp(math.round(mods.Defaults.ClockTime), 0, 24)
local defaultZoom = math.clamp(math.round(mods.Defaults.MaxZoom), 10, 1000)

local function onOff(on) return on and "ON" or "OFF" end

-- SIDEBAR TAB: Movement ------------------------------------------------------
local movement = ui:AddTab("Movement", "Movement")

local speedPage = movement:AddSubTab("Speed", "Speed")
local walk = speedPage:AddSlider("Walk Speed", 16, 150, 16, function(v) mods:SetWalkSpeed(v) end)
local jump = speedPage:AddSlider("Jump Power", 50, 250, 50, function(v) mods:SetJumpPower(v) end)
local hip = speedPage:AddSlider("Hip Height", 0, 20, 2, function(v) mods:SetHipHeight(v) end)
speedPage:AddSection("Sprint (hold Left Shift)")
local sprint = speedPage:AddToggle("Sprint", false, function(on)
	mods:SetSprint(on)
	ui:Notify("Sprint " .. onOff(on))
end)
local sprintMul = speedPage:AddSlider("Sprint Speed %", 110, 300, 160, function(v) mods:SetSprintMultiplier(v / 100) end)

local flightPage = movement:AddSubTab("Flight", "Flight")
local fly = flightPage:AddToggle("Fly", false, function(on)
	mods:SetFly(on)
	ui:Notify("Fly " .. onOff(on))
end)
flightPage:AddLabel("Fly: WASD to move, Space up, Ctrl down.")
local flySpeed = flightPage:AddSlider("Fly Speed", 20, 200, 60, function(v) mods:SetFlySpeed(v) end)
local noclip = flightPage:AddToggle("Noclip", false, function(on)
	mods:SetNoclip(on)
	ui:Notify("Noclip " .. onOff(on))
end)

local extrasPage = movement:AddSubTab("Extras", "Extras")
local infJump = extrasPage:AddToggle("Infinite Jump", false, function(on) mods:SetInfiniteJump(on) end)
local clickTp = extrasPage:AddToggle("Click Teleport", false, function(on)
	mods:SetClickTeleport(on)
	ui:Notify("Click Teleport " .. onOff(on) .. (on and "  (Ctrl + Click)" or ""))
end)
extrasPage:AddLabel("Click Teleport: hold Ctrl and click the ground.")
extrasPage:AddButton("Respawn Character", function() mods:Respawn() end)

-- SIDEBAR TAB: World ---------------------------------------------------------
local world = ui:AddTab("World", "World")

local physicsPage = world:AddSubTab("Physics", "Physics")
local gravity = physicsPage:AddSlider("Gravity", 0, 400, defaultGravity, function(v) mods:SetGravity(v) end)

local cameraPage = world:AddSubTab("Camera", "Camera")
local fov = cameraPage:AddSlider("Field of View", 40, 120, defaultFov, function(v) mods:SetFOV(v) end)
local zoom = cameraPage:AddSlider("Max Zoom", 10, 1000, defaultZoom, function(v) mods:SetMaxZoom(v) end)

local lightPage = world:AddSubTab("Lighting", "Lighting")
local fullbright = lightPage:AddToggle("Fullbright", false, function(on)
	mods:SetFullbright(on)
	ui:Notify("Fullbright " .. onOff(on))
end)
local clock = lightPage:AddSlider("Time of Day", 0, 24, defaultClock, function(v) mods:SetTimeOfDay(v) end)

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
-- Four short pages so nothing is crowded:  Dock | Look | Size | Keys
local settings = ui:AddBottomTab("Settings", "Settings")

-- DOCK: where the bar sits, how thick it is, what it says
local dockPage = settings:AddSubTab("Dock", "Dock")
dockPage:AddSection("Position  (click to change)")
dockPage:AddDropdown("Dock Side", ui:GetDockSides(), "Left", function(side) ui:SetDockSide(side) end)
dockPage:AddToggle("Draggable (along the edge)", true, function(on) ui:SetDraggable(on) end)
dockPage:AddButton("Reset Position", function() ui:ResetPosition() end)
dockPage:AddSection("Bar")
dockPage:AddSlider("Bar Thickness", 36, 100, 56, function(v) ui:SetBarSize(v) end)
dockPage:AddDropdown("Title Direction", ui:GetTitleRotations(), "Auto", function(mode) ui:SetTitleRotation(mode) end)
dockPage:AddSection("Edge widget  (shown while the menu is tucked away)")
dockPage:AddToggle("Auto-hide when idle", true, function(on) ui:SetAutoHide(on) end)
dockPage:AddSlider("Auto-hide after (sec)", 3, 60, 8, function(v) ui:SetIdleTime(v) end)
dockPage:AddSlider("Widget Length", 50, 200, 84, function(v) ui:SetWidgetLength(v) end)
dockPage:AddSection("Bar text")
dockPage:AddTextBox("Title", "Player Menu", function(text) if text ~= "" then ui:SetTitle(text) end end)
dockPage:AddTextBox("Subtitle", "v1.1", function(text) ui:SetSubtitle(text) end)

-- LOOK: style, colors, font
local lookPage = settings:AddSubTab("Look", "Look")
local accent, themeDrop, fontDrop, transSlider, cornerSlider

lookPage:AddSection("Window style  (click to change)")
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

-- KEYS: hotkeys (click a button, then press a key; Esc cancels, Backspace clears)
local keysPage = settings:AddSubTab("Keys", "Keys")
keysPage:AddSection("Click a button, then press a key")
local flyKey = keysPage:AddKeybind("Fly Key", Enum.KeyCode.F)
local noclipKey = keysPage:AddKeybind("Noclip Key", Enum.KeyCode.N)
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
	ui:Notify("Everything reset")
end)

-- handle returned to the loader: running the loader again calls this first
return {
	UI = ui,
	Mods = mods,
	Destroy = function()
		hotkeyConn:Disconnect()
		mods:Destroy()
		ui:Destroy()
	end,
}

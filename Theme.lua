-- modules/Theme.lua
-- Constants, the live Theme table, palettes, and the shared State (active Skin + Layout).
-- Because Skin / Layout are reassigned when the style changes, they live in State so every
-- module sees the current one:  State.Skin, State.Layout
local import = ...

local SkinData = import("Skins")

local function rgb(r, g, b) return Color3.fromRGB(r, g, b) end
local WHITE, BLACK = Color3.new(1, 1, 1), Color3.new(0, 0, 0)

-------------------------------------------------------------------------------
-- DOCK SETTINGS
-------------------------------------------------------------------------------
local Const = {
	BAR_SIZE = 56,         -- default bar thickness (px): width on Left/Right, height on Top
	BAR_MIN = 36, BAR_MAX = 100,
	BAR_GAP = 6,           -- gap between the bar and the panel (px)
	CLIP_PAD = 4,          -- extra room around the panel inside the clip, so borders are not cut in half
	SLIDE_TIME = 0.6,      -- panel slide in / out of the bar
	BAR_GROW_TIME = 0.5,   -- bar extends from its center outwards (opening)
	BAR_SHRINK_TIME = 0.4, -- bar contracts back to its center (closing)
	BAR_MIN_LEN = 14,      -- length of the bar when it is fully contracted (px)

	-- widget (the little tab on the screen edge)
	WIDGET_T = 30,         -- how far it sticks out when fully shown (px)
	WIDGET_PEEK = 6,       -- how much of it is visible while idle (px)
	WIDGET_HOVER = 26,     -- how much is visible while hovered (px)
	WIDGET_LEN = 84,       -- default length along the edge (px)

	CORNER_MAX = 16,       -- every style loads with this radius (the Settings slider goes 0 - 16)
}

-------------------------------------------------------------------------------
-- THEME + PALETTES
-------------------------------------------------------------------------------
local Theme = {
	Font = Enum.Font.SourceSansBold,
	Depth = 4,
	PanelTransparency = 0.2,
	Corner = 0,
	AnimSpeed = 1,
	Size = {
		Tab = 38, Control = 38, SliderH = 50, LabelH = 28,
		SmallW = 104, SmallH = 26, BindW = 236, Item = 38, Gap = 8,
	},
	FontSize = { Title = 22, Header = 18, Button = 18, Small = 16, Label = 18 },
}

local Presets = {
	Dark = {
		Window = rgb(22, 22, 26), WindowShadow = rgb(6, 6, 8),
		Field = rgb(40, 40, 47), FieldHover = rgb(58, 58, 68), FieldPress = rgb(30, 30, 35),
		Content = rgb(28, 28, 34),
		Tab = rgb(48, 48, 56), TabHover = rgb(66, 66, 77), TabPress = rgb(36, 36, 42),
		Active = rgb(245, 245, 248), Text = rgb(235, 235, 240), Close = rgb(255, 80, 80),
	},
	Midnight = {
		Window = rgb(14, 18, 32), WindowShadow = rgb(4, 6, 14),
		Field = rgb(26, 32, 54), FieldHover = rgb(40, 50, 80), FieldPress = rgb(18, 22, 40),
		Content = rgb(18, 23, 40),
		Tab = rgb(30, 38, 64), TabHover = rgb(46, 58, 92), TabPress = rgb(22, 28, 48),
		Active = rgb(110, 170, 255), Text = rgb(228, 234, 250), Close = rgb(255, 90, 100),
	},
	Forest = {
		Window = rgb(16, 26, 20), WindowShadow = rgb(4, 10, 6),
		Field = rgb(30, 46, 36), FieldHover = rgb(44, 66, 52), FieldPress = rgb(22, 34, 26),
		Content = rgb(20, 32, 25),
		Tab = rgb(36, 54, 42), TabHover = rgb(52, 76, 60), TabPress = rgb(26, 40, 31),
		Active = rgb(120, 230, 150), Text = rgb(230, 244, 234), Close = rgb(255, 100, 90),
	},
	Crimson = {
		Window = rgb(28, 16, 18), WindowShadow = rgb(10, 4, 5),
		Field = rgb(52, 30, 34), FieldHover = rgb(76, 44, 50), FieldPress = rgb(38, 22, 25),
		Content = rgb(34, 20, 23),
		Tab = rgb(60, 34, 39), TabHover = rgb(86, 50, 57), TabPress = rgb(44, 25, 29),
		Active = rgb(255, 95, 110), Text = rgb(248, 232, 234), Close = rgb(255, 200, 80),
	},
	Light = {
		Window = rgb(225, 225, 232), WindowShadow = rgb(150, 150, 165),
		Field = rgb(240, 240, 245), FieldHover = rgb(255, 255, 255), FieldPress = rgb(210, 210, 220),
		Content = rgb(235, 235, 240),
		Tab = rgb(215, 215, 225), TabHover = rgb(235, 235, 242), TabPress = rgb(195, 195, 208),
		Active = rgb(40, 40, 48), Text = rgb(30, 30, 36), Close = rgb(220, 50, 50),
	},
}

local PresetOrder = { "Default", "Dark", "Midnight", "Forest", "Crimson", "Light" }
local FontNames = {
	"SourceSansBold", "SourceSansSemibold", "GothamBold", "Gotham", "Ubuntu",
	"Roboto", "RobotoMono", "Arial", "ArialBold", "Arcade",
}
local DockSides = { "Left", "Right", "Top" }
local TitleRotations = { "Auto", "Up", "Down" } -- side docks only. Auto: up on the left, down on the right

-- the active style + its layout (swapped by loadSkin)
local State = { Skin = nil, Layout = nil }

local function luminance(c) return 0.299 * c.R + 0.587 * c.G + 0.114 * c.B end

local function setAccent(c)
	Theme.Active = c
	Theme.TextOnActive = luminance(c) > 0.55 and rgb(18, 18, 22) or rgb(250, 250, 252)
end

-- bar button colors (+ hover / press variants) come from the active style
local function syncSys()
	local sys = State.Skin.Sys
	Theme.SysGlyph = sys.Glyph or Theme.Text
	Theme.SysGlyphClose = sys.GlyphClose or Theme.Close
	local function tint(key, col, hover)
		if col then
			Theme[key] = col
			Theme[key .. "H"] = col:Lerp(WHITE, 0.25)
			Theme[key .. "P"] = col:Lerp(BLACK, 0.25)
		else
			Theme[key], Theme[key .. "H"], Theme[key .. "P"] = hover[1], hover[2], hover[3]
		end
	end
	local plain = { Theme.Field, Theme.FieldHover, Theme.FieldPress }
	tint("SysMin", sys.Min, plain)
	tint("SysMax", sys.Max, plain)
	tint("SysClose", sys.Close, plain)
end

local function loadPalette(p)
	for k, v in p do Theme[k] = v end
	Theme.Side = p.Side or p.Field
	Theme.SideTab, Theme.SideTabH, Theme.SideTabP = p.SideTab or p.Tab, p.SideTabH or p.TabHover, p.SideTabP or p.TabPress
	Theme.Track = p.Track or p.WindowShadow
	Theme.Border = p.Border or p.WindowShadow
	Theme.Edge = p.Edge or Theme.Border
	Theme.Knob = p.Knob or p.Text
	Theme.TitleA = p.TitleA or p.Window
	Theme.TitleB = p.TitleB or Theme.TitleA
	Theme.TitleText = p.TitleText or p.Text
	setAccent(p.Active)
	if p.TextOnActive then Theme.TextOnActive = p.TextOnActive end
	syncSys()
end

local function shadowTransparency() return math.min(1, Theme.PanelTransparency + 0.1) end

local function applyPreset(name)
	if name ~= "Default" and Presets[name] then
		loadPalette(Presets[name])
	else
		loadPalette(State.Skin.Palette or Presets.Dark)
	end
end

local function loadSkin(name)
	local skin = SkinData.Skins[name]
	State.Skin = skin
	State.Layout = skin.Layout
	Theme.Corner = Const.CORNER_MAX
	Theme.PanelTransparency = skin.Defaults.Transparency
	Theme.Font = Enum.Font[skin.Defaults.Font]
	applyPreset("Default")
end

return {
	Const = Const,
	Theme = Theme,
	State = State,
	Presets = Presets,
	PresetOrder = PresetOrder,
	FontNames = FontNames,
	DockSides = DockSides,
	TitleRotations = TitleRotations,
	Skins = SkinData.Skins,
	StyleOrder = SkinData.Order,
	setAccent = setAccent,
	applyPreset = applyPreset,
	loadSkin = loadSkin,
	shadowTransparency = shadowTransparency,
}

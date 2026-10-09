-- modules/Skins.lua
-- Pure data: every window style (palette + layout + shapes + control looks). No dependencies.
local import = ...

local function rgb(r, g, b) return Color3.fromRGB(r, g, b) end
local WHITE, BLACK = Color3.new(1, 1, 1), Color3.new(0, 0, 0)

-- Layout rectangles are written in the old 769x866 design space. Everything is made RELATIVE to the
-- Body rectangle, so the panel is just the body (the title bar lives in the side bar).
local PX = 700 / 769

local function mkLayout(t)
	local b = t.Body
	local bw, bh = b[3] - b[1], b[4] - b[2]
	local out = {}
	for k, v in t do
		out[k] = {
			Position = UDim2.fromScale((v[1] - b[1]) / bw, (v[2] - b[2]) / bh),
			Size = UDim2.fromScale((v[3] - v[1]) / bw, (v[4] - v[2]) / bh),
		}
	end
	out.PanelPx = Vector2.new(math.round(bw * PX), math.round(bh * PX))
	return out
end

-- Kind options: Mul (corner = Theme.Corner * Mul) | Radius (fixed px) | Depth (3D strip, 0 = flat)
--               Stroke + StrokeKey (border) | Grad {topKey, bottomKey} | Sheen / Gloss (button shine) | Clear
-- "title" is the look of the side bar, "sys" the look of the bar buttons.
local Skins = {}

Skins.Modern = {
	Layout = mkLayout {
		Body = { 14, 85, 754, 853 }, TabName = { 32, 99, 165, 139 },
		HeaderBar = { 184, 99, 739, 139 }, Sidebar = { 32, 148, 166, 777 },
		Content = { 184, 148, 738, 777 }, Footer = { 32, 786, 738, 828 },
	},
	Defaults = { Corner = 0, Transparency = 0.2, Font = "SourceSansBold" },
	Title = { Size = 20 },
	Sys = { Order = { "Minimize", "Maximize", "Close" }, Size = 38, Gap = 8, Glyphs = true },
	Toggle = "Fill",
	Slider = { H = 14 },
	Kinds = { window = { Mul = 1 }, title = { Mul = 1 }, panel = { Mul = 0.8 }, btn = { Mul = 0.6 }, field = { Mul = 0.6 } },
}

Skins.WindowsXP = {
	Palette = {
		Window = rgb(236, 233, 216), WindowShadow = rgb(172, 168, 153),
		Field = rgb(226, 223, 206), FieldHover = rgb(255, 243, 205), FieldPress = rgb(205, 201, 185),
		Content = rgb(255, 255, 255), Side = rgb(214, 223, 247),
		Tab = rgb(238, 237, 230), TabHover = rgb(255, 242, 200), TabPress = rgb(212, 208, 196),
		Active = rgb(49, 106, 197), TextOnActive = WHITE, Text = rgb(16, 16, 16), Close = rgb(214, 72, 40),
		TitleA = rgb(40, 118, 246), TitleB = rgb(0, 70, 214), TitleText = WHITE,
		Border = rgb(127, 157, 185), Edge = rgb(0, 60, 116), Track = WHITE, Knob = rgb(236, 235, 229),
	},
	Layout = mkLayout {
		Body = { 10, 56, 759, 858 }, TabName = { 24, 74, 192, 112 },
		Sidebar = { 24, 118, 192, 806 }, HeaderBar = { 204, 74, 745, 112 },
		Content = { 204, 118, 745, 806 }, Footer = { 24, 814, 745, 850 },
	},
	Defaults = { Corner = 8, Transparency = 0, Font = "SourceSansSemibold" },
	Title = { Size = 19 },
	Sys = {
		Order = { "Minimize", "Maximize", "Close" }, Size = 26, Gap = 6, Glyphs = true,
		Min = rgb(50, 110, 230), Max = rgb(50, 110, 230), Close = rgb(214, 72, 40), Glyph = WHITE, GlyphClose = WHITE,
	},
	Toggle = "Check",
	Slider = { H = 6, Stroke = true, KW = 10, KH = 20 },
	Kinds = {
		window = { Mul = 0.9, Depth = 0, Stroke = 3, StrokeKey = "TitleB" },
		title = { Mul = 0.9, Depth = 0, Grad = { "TitleA", "TitleB" }, Stroke = 1, StrokeKey = "TitleB" },
		panel = { Mul = 0.3, Depth = 0, Stroke = 1, StrokeKey = "Border" },
		btn = { Mul = 0.4, Depth = 0, Stroke = 1, StrokeKey = "Edge", Sheen = 0.08 },
		sys = { Mul = 0.4, Depth = 0, Stroke = 1, StrokeKey = "TitleText", Gloss = 0.2 },
		tfield = { Clear = true },
		field = { Mul = 0.3, Depth = 0, Stroke = 1, StrokeKey = "Edge" },
	},
}

Skins.WindowsVista = {
	Palette = {
		Window = rgb(176, 208, 236), WindowShadow = rgb(70, 100, 140),
		Field = rgb(214, 229, 246), FieldHover = rgb(234, 245, 255), FieldPress = rgb(168, 198, 232),
		Content = rgb(245, 248, 253), Side = rgb(200, 221, 243),
		Tab = rgb(232, 241, 252), TabHover = rgb(212, 235, 255), TabPress = rgb(166, 200, 236),
		Active = rgb(120, 184, 244), Text = rgb(14, 24, 40), Close = rgb(200, 60, 50),
		TitleA = rgb(168, 206, 238), TitleB = rgb(112, 160, 214), TitleText = rgb(8, 18, 34),
		Border = rgb(90, 120, 160), Edge = rgb(70, 100, 140), Track = rgb(205, 218, 232), Knob = rgb(240, 247, 255),
	},
	Layout = mkLayout {
		Body = { 8, 58, 761, 860 }, Sidebar = { 24, 76, 745, 122 },
		TabName = { 24, 132, 192, 170 }, HeaderBar = { 204, 132, 745, 170 },
		Content = { 24, 178, 745, 806 }, Footer = { 24, 814, 745, 850 },
	},
	Horizontal = true,
	Defaults = { Corner = 9, Transparency = 0.1, Font = "Ubuntu" },
	Title = { Size = 19 },
	Sys = {
		Order = { "Minimize", "Maximize", "Close" }, Size = 26, Gap = 6, Glyphs = true,
		Min = rgb(190, 214, 240), Max = rgb(190, 214, 240), Close = rgb(206, 72, 58),
		Glyph = rgb(14, 24, 40), GlyphClose = WHITE,
	},
	Toggle = "Check",
	Slider = { H = 8, Pill = true, Stroke = true, KW = 12, KH = 18 },
	Kinds = {
		window = { Mul = 1, Depth = 0, Stroke = 2, StrokeKey = "Edge" },
		title = { Mul = 1, Depth = 0, Grad = { "TitleA", "TitleB" }, Stroke = 2, StrokeKey = "Edge" },
		panel = { Mul = 0.6, Depth = 0, Stroke = 1, StrokeKey = "Border" },
		btn = { Mul = 0.5, Depth = 0, Stroke = 1, StrokeKey = "Edge", Gloss = 0.14 },
		sys = { Mul = 0.4, Depth = 0, Stroke = 1, StrokeKey = "Edge", Gloss = 0.22 },
		tfield = { Clear = true },
		field = { Mul = 0.4, Depth = 0, Stroke = 1, StrokeKey = "Border" },
	},
}

Skins.Windows11 = {
	Palette = {
		Window = rgb(243, 243, 243), WindowShadow = rgb(170, 170, 176),
		Field = rgb(249, 249, 249), FieldHover = WHITE, FieldPress = rgb(230, 230, 234),
		Content = WHITE, Side = rgb(243, 243, 243),
		Tab = rgb(243, 243, 243), TabHover = rgb(232, 232, 236), TabPress = rgb(220, 220, 226),
		SideTab = rgb(243, 243, 243), SideTabH = rgb(232, 232, 236), SideTabP = rgb(220, 220, 226),
		Active = rgb(0, 103, 192), TextOnActive = WHITE, Text = rgb(28, 28, 30), Close = rgb(196, 43, 28),
		TitleA = rgb(243, 243, 243), TitleB = rgb(243, 243, 243), TitleText = rgb(28, 28, 30),
		Border = rgb(229, 229, 229), Edge = rgb(200, 200, 204), Track = rgb(200, 200, 206), Knob = WHITE,
	},
	Layout = mkLayout {
		Body = { 10, 44, 759, 858 }, TabName = { 22, 60, 200, 98 },
		Sidebar = { 22, 106, 200, 808 }, HeaderBar = { 212, 60, 747, 98 },
		Content = { 212, 106, 747, 808 }, Footer = { 22, 816, 747, 850 },
	},
	Defaults = { Corner = 8, Transparency = 0.04, Font = "Gotham" },
	Title = { Size = 16 },
	Sys = {
		Order = { "Minimize", "Maximize", "Close" }, Size = 34, Gap = 4, Glyphs = true,
		Min = rgb(243, 243, 243), Max = rgb(243, 243, 243), Close = rgb(243, 243, 243),
		Glyph = rgb(28, 28, 30), GlyphClose = rgb(28, 28, 30),
	},
	Toggle = "Switch",
	Slider = { H = 4, Pill = true, KW = 20, KH = 20, KRound = true },
	Kinds = {
		window = { Mul = 1, Depth = 0, Stroke = 1, StrokeKey = "Border" },
		title = { Mul = 1, Depth = 0, Stroke = 1, StrokeKey = "Border" },
		panel = { Mul = 0.7, Depth = 0 },
		btn = { Mul = 0.6, Depth = 0, Stroke = 1, StrokeKey = "Edge" },
		tab = { Mul = 0.7, Depth = 0 },
		sys = { Mul = 0.6, Depth = 0 },
		tfield = { Clear = true },
		field = { Mul = 0.6, Depth = 0, Stroke = 1, StrokeKey = "Border" },
	},
}

Skins.KDEPlasma = {
	Palette = {
		Window = rgb(49, 54, 59), WindowShadow = rgb(26, 28, 31),
		Field = rgb(59, 66, 72), FieldHover = rgb(72, 80, 87), FieldPress = rgb(41, 45, 49),
		Content = rgb(42, 46, 50), Side = rgb(35, 38, 41),
		Tab = rgb(59, 66, 72), TabHover = rgb(72, 80, 87), TabPress = rgb(41, 45, 49),
		SideTab = rgb(35, 38, 41), SideTabH = rgb(54, 60, 66), SideTabP = rgb(28, 31, 34),
		Active = rgb(61, 174, 233), TextOnActive = WHITE, Text = rgb(239, 240, 241), Close = rgb(218, 68, 83),
		TitleA = rgb(35, 38, 41), TitleB = rgb(35, 38, 41), TitleText = rgb(239, 240, 241),
		Border = rgb(77, 82, 87), Edge = rgb(88, 95, 102), Track = rgb(26, 28, 31), Knob = rgb(239, 240, 241),
	},
	Layout = mkLayout {
		Body = { 8, 48, 761, 860 }, TabName = { 20, 62, 214, 100 },
		Sidebar = { 20, 106, 214, 806 }, HeaderBar = { 226, 62, 749, 100 },
		Content = { 226, 106, 749, 806 }, Footer = { 20, 814, 749, 850 },
	},
	Defaults = { Corner = 5, Transparency = 0, Font = "Roboto" },
	Title = { Size = 18 },
	Sys = {
		Order = { "Minimize", "Maximize", "Close" }, Size = 28, Gap = 6, Glyphs = true,
		Min = rgb(35, 38, 41), Max = rgb(35, 38, 41), Close = rgb(35, 38, 41),
		Glyph = rgb(239, 240, 241), GlyphClose = rgb(218, 68, 83),
	},
	Toggle = "Switch",
	Slider = { H = 6, Pill = true, KW = 16, KH = 16, KRound = true },
	Kinds = {
		window = { Mul = 1, Depth = 0, Stroke = 1, StrokeKey = "Border" },
		title = { Mul = 1, Depth = 0, Grad = { "TitleA", "TitleB" }, Stroke = 1, StrokeKey = "Border" },
		panel = { Mul = 0.6, Depth = 0, Stroke = 1, StrokeKey = "Border" },
		btn = { Mul = 0.5, Depth = 0, Stroke = 1, StrokeKey = "Edge" },
		tab = { Mul = 0.5, Depth = 0 },
		sys = { Mul = 0.5, Depth = 0 },
		tfield = { Clear = true },
		field = { Mul = 0.5, Depth = 0, Stroke = 1, StrokeKey = "Edge" },
	},
}

Skins.Windows95 = {
	Palette = {
		Window = rgb(192, 192, 192), WindowShadow = rgb(64, 64, 64),
		Field = rgb(192, 192, 192), FieldHover = rgb(210, 210, 210), FieldPress = rgb(160, 160, 160),
		Content = WHITE, Side = rgb(192, 192, 192),
		Tab = rgb(192, 192, 192), TabHover = rgb(210, 210, 210), TabPress = rgb(150, 150, 150),
		Active = rgb(0, 0, 128), TextOnActive = WHITE, Text = BLACK, Close = BLACK,
		TitleA = rgb(0, 0, 128), TitleB = rgb(16, 132, 208), TitleText = WHITE,
		Border = rgb(128, 128, 128), Edge = BLACK, Track = rgb(128, 128, 128), Knob = rgb(192, 192, 192),
	},
	Layout = mkLayout {
		Body = { 10, 48, 759, 858 }, Sidebar = { 22, 64, 747, 104 },
		HeaderBar = { 22, 112, 579, 150 }, TabName = { 587, 112, 747, 150 },
		Content = { 22, 158, 747, 806 }, Footer = { 22, 814, 747, 850 },
	},
	Horizontal = true,
	Defaults = { Corner = 0, Transparency = 0, Font = "Arial" },
	Title = { Size = 18 },
	Sys = {
		Order = { "Minimize", "Maximize", "Close" }, Size = 26, Gap = 6, Glyphs = true,
		Glyph = BLACK, GlyphClose = BLACK,
	},
	Toggle = "Check",
	Slider = { H = 6, Stroke = true, KW = 10, KH = 20 },
	Kinds = {
		window = { Mul = 1, Depth = 0, Stroke = 2, StrokeKey = "Edge" },
		title = { Mul = 1, Depth = 0, Grad = { "TitleA", "TitleB" } },
		panel = { Mul = 0.6, Depth = 0, Stroke = 2, StrokeKey = "Border" },
		btn = { Mul = 0.5, Depth = 2, Stroke = 1, StrokeKey = "TitleText" },
		sys = { Mul = 0.5, Depth = 2, Stroke = 1, StrokeKey = "TitleText" },
		tfield = { Clear = true },
		field = { Mul = 0.5, Depth = 0, Stroke = 2, StrokeKey = "Border" },
	},
}

Skins.GNOME = {
	Palette = {
		Window = rgb(246, 245, 244), WindowShadow = rgb(160, 158, 156),
		Field = rgb(255, 255, 255), FieldHover = rgb(237, 236, 235), FieldPress = rgb(220, 218, 216),
		Content = WHITE, Side = rgb(246, 245, 244),
		Tab = rgb(255, 255, 255), TabHover = rgb(237, 236, 235), TabPress = rgb(220, 218, 216),
		Active = rgb(53, 132, 228), TextOnActive = WHITE, Text = rgb(36, 31, 49), Close = rgb(192, 28, 40),
		TitleA = rgb(235, 235, 234), TitleB = rgb(222, 221, 220), TitleText = rgb(36, 31, 49),
		Border = rgb(205, 203, 201), Edge = rgb(180, 178, 176), Track = rgb(205, 203, 201), Knob = WHITE,
	},
	Layout = mkLayout {
		Body = { 8, 50, 761, 858 }, Sidebar = { 20, 66, 749, 114 },
		TabName = { 20, 126, 220, 164 }, HeaderBar = { 232, 126, 749, 164 },
		Content = { 20, 176, 749, 808 }, Footer = { 20, 816, 749, 850 },
	},
	Horizontal = true,
	Defaults = { Corner = 12, Transparency = 0, Font = "Ubuntu" },
	Title = { Size = 17 },
	Sys = {
		Order = { "Close", "Maximize", "Minimize" }, Size = 28, Gap = 6, Glyphs = true,
		Min = rgb(235, 235, 234), Max = rgb(235, 235, 234), Close = rgb(235, 235, 234),
		Glyph = rgb(36, 31, 49), GlyphClose = rgb(192, 28, 40),
	},
	Toggle = "Switch",
	Slider = { H = 6, Pill = true, KW = 18, KH = 18, KRound = true },
	Kinds = {
		window = { Mul = 1, Depth = 0, Stroke = 1, StrokeKey = "Border" },
		title = { Mul = 1, Depth = 0, Grad = { "TitleA", "TitleB" }, Stroke = 1, StrokeKey = "Border" },
		panel = { Mul = 0.8, Depth = 0, Stroke = 1, StrokeKey = "Border" },
		btn = { Mul = 0.7, Depth = 0, Stroke = 1, StrokeKey = "Edge" },
		tab = { Radius = 99, Depth = 0 },
		sys = { Radius = 99, Depth = 0 },
		tfield = { Clear = true },
		field = { Mul = 0.7, Depth = 0, Stroke = 1, StrokeKey = "Border" },
	},
}

Skins.macOS = {
	Palette = {
		Window = rgb(236, 236, 238), WindowShadow = rgb(190, 190, 194),
		Field = rgb(246, 246, 248), FieldHover = WHITE, FieldPress = rgb(222, 222, 226),
		Content = WHITE, Side = rgb(228, 228, 232),
		Tab = rgb(250, 250, 252), TabHover = WHITE, TabPress = rgb(226, 226, 230),
		SideTab = rgb(228, 228, 232), SideTabH = rgb(214, 214, 220), SideTabP = rgb(200, 200, 206),
		Active = rgb(10, 132, 255), TextOnActive = WHITE, Text = rgb(30, 30, 34), Close = rgb(255, 95, 86),
		TitleA = rgb(238, 238, 240), TitleB = rgb(214, 214, 218), TitleText = rgb(60, 60, 66),
		Border = rgb(206, 206, 210), Edge = rgb(200, 200, 205), Track = rgb(222, 222, 226), Knob = WHITE,
	},
	Layout = mkLayout {
		Body = { 14, 54, 754, 856 }, TabName = { 28, 68, 196, 104 },
		Sidebar = { 28, 110, 196, 806 }, HeaderBar = { 208, 68, 741, 104 },
		Content = { 208, 110, 741, 806 }, Footer = { 28, 814, 741, 850 },
	},
	Defaults = { Corner = 10, Transparency = 0.05, Font = "Gotham" },
	Title = { Size = 17 },
	Sys = {
		Order = { "Close", "Minimize", "Maximize" }, Size = 24, Gap = 10, Glyphs = false,
		Min = rgb(255, 189, 46), Max = rgb(39, 201, 63), Close = rgb(255, 95, 86),
	},
	Toggle = "Switch",
	Slider = { H = 4, Pill = true, Stroke = false, KW = 18, KH = 18, KRound = true },
	Kinds = {
		window = { Mul = 1, Depth = 0, Stroke = 1, StrokeKey = "Border" },
		title = { Mul = 1, Depth = 0, Grad = { "TitleA", "TitleB" }, Stroke = 1, StrokeKey = "Border" },
		panel = { Mul = 0.6, Depth = 0 },
		btn = { Mul = 0.5, Depth = 0, Stroke = 1, StrokeKey = "Edge" },
		tab = { Mul = 0.6, Depth = 0 },
		sys = { Radius = 99, Depth = 0, Stroke = 1, StrokeKey = "Edge" },
		tfield = { Clear = true },
		field = { Mul = 0.5, Depth = 0, Stroke = 1, StrokeKey = "Edge" },
	},
}

return {
	Skins = Skins,
	Order = { "Modern", "WindowsXP", "WindowsVista", "Windows11", "Windows95", "KDEPlasma", "GNOME", "macOS" },
}

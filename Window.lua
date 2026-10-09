-- modules/Window.lua
-- The GUI class. Builds the window parts, owns the constructor and the tab system, then installs
-- the other modules onto the class:  Dock (layout)  Controls (page widgets)  Behavior (open/close/API).
-- It knows nothing about the player; controls just fire callbacks.
--
--   ui:AddTab(id, name) / ui:AddBottomTab(id, name) / tab:AddSubTab(id, name)
--   page:AddSection / AddLabel / AddButton / AddToggle / AddSlider
--   page:AddDropdown / AddColorPicker / AddTextBox / AddKeybind
--
-- config: Name, Title, Subtitle, Transparency (0-1), ToggleKey, MinimizeKey (Enum.KeyCode),
--         Style: "Modern" | "WindowsXP" | "WindowsVista" | "Windows11" | "Windows95" | "KDEPlasma" | "GNOME" | "macOS"
--         AutoHide (true), IdleTime (seconds, default 8), WidgetLength (px), StartCollapsed (false)
--         DockSide: "Left" | "Right" | "Top",  BarSize (36-100 px),  UserScale (0.3-1.6, 1 = auto fit)
--         TitleRotation: "Auto" | "Up" | "Down" (Left/Right docks only)
--         SlideMode: "Auto" | "LeftToRight" | "RightToLeft",
--         Theme (preset name), Accent (Color3), CornerRadius (px), Font (name), AnimSpeed
local import = ...

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local T = import("Theme")
local Kit = import("Toolkit")
local Theme, State, C = T.Theme, T.State, T.Const
local ApplyAll, Anim = Kit.ApplyAll, Kit.Anim
local New, Bind, Label, Button, Shadowed = Kit.New, Kit.Bind, Kit.Label, Kit.Button, Kit.Shadowed
local NewHost, MakeDrag, fieldOpts, Texts, Insets = Kit.NewHost, Kit.MakeDrag, Kit.fieldOpts, Kit.Texts, Kit.Insets

local BAR_SIZE, BAR_MIN, BAR_MAX = C.BAR_SIZE, C.BAR_MIN, C.BAR_MAX
local WIDGET_T, WIDGET_LEN, BAR_MIN_LEN = C.WIDGET_T, C.WIDGET_LEN, C.BAR_MIN_LEN

local GuiUI = {}
GuiUI.__index = GuiUI
local Tab = {}
Tab.__index = Tab
local Page = {}
Page.__index = Page

-------------------------------------------------------------------------------
-- COMPONENT BUILDERS
-------------------------------------------------------------------------------
-- the side bar: window buttons, rotated name, version
local function buildBar(self, root)
	local S = Theme.Size
	local holder, face, surf = Shadowed(root, "SideBar", "Frame", UDim2.new(), UDim2.fromOffset(BAR_SIZE, 100), "Window", Theme.Depth + 3, nil, "title")
	self.BarHolder, self.BarFace, self.BarSurface = holder, face, surf

	-- everything on the bar lives in a full-length frame centered on the bar. The bar itself grows /
	-- shrinks around it (face clips), so the buttons are simply revealed from the center outwards.
	face.ClipsDescendants = true
	local content = New("Frame", {
		Name = "Content", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Parent = face,
	})
	self.BarContent = content

	local title = New("TextButton", {
		Name = "Title", BackgroundTransparency = 1, AutoButtonColor = false, Text = "", Font = Theme.Font,
		TextSize = 18, TextTruncate = Enum.TextTruncate.AtEnd, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(200, 28), Parent = content,
	})
	Bind(title, "TextColor3", "TitleText")
	table.insert(Texts, title)
	self.TitleButton = title

	self.SubtitleLabel = Label(content, "", {
		TextSize = 14, ColorKey = "TitleText", PadX = 0,
		Position = UDim2.new(0, 2, 1, -30), Size = UDim2.new(1, -4, 0, 22),
	})

	self.Sys = {}
	local function sys(name, themeKey, glyph, glyphKey, onClick)
		self.Sys[name] = Button(content, name, UDim2.new(), UDim2.fromOffset(S.Item, S.Item), "", {
			Color = themeKey, HoverColor = themeKey .. "H", PressColor = themeKey .. "P",
			Depth = 3, Kind = "sys", Glyph = glyph, GlyphColor = glyphKey,
		}, onClick)
	end
	sys("Close", "SysClose", "cross", "SysGlyphClose", function() self:Close() end)
	sys("Maximize", "SysMax", "plus", "SysGlyph", function() self:ToggleMaximize() end)
	sys("Minimize", "SysMin", "minus", "SysGlyph", function() self:ToggleMinimize() end)
end

local function buildHeader(self, parent)
	local L = State.Layout
	local nH, nameFace = Shadowed(parent, "TabNameField", "Frame", L.TabName.Position, L.TabName.Size, "Field", nil, nil, "tabname")
	self.Parts.TabName = nH
	self.TabLabel = Label(nameFace, "", { TextSize = Theme.FontSize.Header })

	local bH, barFace = Shadowed(parent, "HeaderBar", "Frame", L.HeaderBar.Position, L.HeaderBar.Size, "Field", nil, nil, "header")
	self.Parts.HeaderBar = bH
	self.HeaderHost = NewHost(barFace)
end

local function buildSidebar(self, parent)
	local L = State.Layout
	local holder, face = Shadowed(parent, "Sidebar", "Frame", L.Sidebar.Position, L.Sidebar.Size, "Side", Theme.Depth + 3, nil, "side")
	self.Parts.Sidebar = holder
	local list = New("ScrollingFrame", {
		Name = "TabList", BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 3, Parent = face,
	})
	self.TabListPad = New("UIPadding", {
		PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = list,
	})
	self.TabListLayout = New("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = list })
	self.TabList = list
end

local function buildContent(self, parent)
	local L = State.Layout
	local holder, face = Shadowed(parent, "ContentArea", "Frame", L.Content.Position, L.Content.Size, "Content", Theme.Depth + 3, nil, "content")
	self.Parts.Content = holder
	self.MainHost = NewHost(face)
end

local function buildFooter(self, parent)
	local L = State.Layout
	local S = Theme.Size
	local holder, face = Shadowed(parent, "Footer", "Frame", L.Footer.Position, L.Footer.Size, "Field", nil, nil, "footer")
	self.Parts.Footer = holder

	local row = New("Frame", {
		Name = "TabButtons", BackgroundTransparency = 1,
		Size = UDim2.new(1, -(S.BindW + S.Gap * 3), 1, 0), Parent = face,
	})
	New("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center, Parent = row,
	})
	New("UIPadding", { PaddingLeft = UDim.new(0, S.Gap), Parent = row })
	self.FooterButtons = row

	self.BindButton = Button(face, "BindToggleUI", UDim2.new(1, -S.Gap, 0.5, 0), UDim2.fromOffset(S.BindW, S.SmallH), "",
		fieldOpts({ Anchor = Vector2.new(1, 0.5), Depth = 3, TextSize = Theme.FontSize.Small, Kind = "bottom" }),
		function() self:_toggleBinding() end)
	self:_refreshBind()
end

-- Toast notifications live in the ScreenGui (bottom-right), so they still show while the menu is closed
local function buildToasts(self, gui)
	local area = New("Frame", {
		Name = "Toasts", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -16), Size = UDim2.fromOffset(280, 320), Parent = gui,
	})
	New("UIListLayout", {
		Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Bottom, Parent = area,
	})
	self.ToastArea = area
	self._toastCount = 0
end

-- The widget: a small tab peeking in from the screen edge. Hover = slides out, click = opens the menu.
local function buildWidget(self, gui)
	local holder, face, surf = Shadowed(gui, "Widget", "Frame", UDim2.new(), UDim2.fromOffset(WIDGET_T, WIDGET_LEN), "Window", 3, nil, "title")
	holder.Visible = false
	self.WidgetHolder, self.WidgetFace, self.WidgetSurface = holder, face, surf

	self.WidgetDots = {}
	for i = 1, 3 do
		local d = New("Frame", {
			BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(4, 4), Parent = face,
		})
		New("UICorner", { CornerRadius = UDim.new(1, 0), Parent = d })
		Bind(d, "BackgroundColor3", "TitleText")
		self.WidgetDots[i] = d
	end

	-- invisible, slightly bigger click / hover area on the very edge of the screen
	local hit = New("TextButton", {
		Name = "WidgetHit", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Visible = false, Parent = gui,
	})
	self.WidgetHit = hit
	hit.MouseEnter:Connect(function() self:_hoverWidget(true) end)
	hit.MouseLeave:Connect(function() self:_hoverWidget(false) end)
	local drag = MakeDrag(hit, self) -- can be slid along the edge like the bar
	hit.MouseButton1Click:Connect(function()
		if not drag.Moved then self:Open() end
	end)
end

-------------------------------------------------------------------------------
-- WINDOW
-------------------------------------------------------------------------------
function GuiUI.new(config)
	config = config or {}
	local self = setmetatable({}, GuiUI)
	self.Tabs = {}
	self.Parts = {}
	self._conns = {}
	self.CurrentTab = nil
	self.IsOpen, self.Minimized, self.Maximized = true, false, false
	self.UserScale = config.UserScale or 1
	self.Draggable = true
	self.Offset = 0
	self.AutoHide = config.AutoHide ~= false
	self.IdleTime = math.clamp(config.IdleTime or 8, 2, 120)
	self.WidgetLen = math.clamp(config.WidgetLength or WIDGET_LEN, 50, 200)
	self._lastActive = os.clock()
	self._wVis = 0
	self.BarSize = math.clamp(config.BarSize or BAR_SIZE, BAR_MIN, BAR_MAX)
	self.SlideMode = config.SlideMode or "Auto"
	self.ToggleKey = config.ToggleKey or Enum.KeyCode.RightShift
	self.MinimizeKey = config.MinimizeKey
	self.DockSide = table.find(T.DockSides, config.DockSide) and config.DockSide or "Left"
	self.TitleRot = table.find(T.TitleRotations, config.TitleRotation) and config.TitleRotation or "Auto"
	self.Style = T.Skins[config.Style] and config.Style or "Modern"
	self._binding, self._capturing, self._swallow = false, false, false
	self._token = 0
	self._slideToken = 0
	self._panelOpen = true
	self._sideCount, self._bottomCount = 0, 0
	self._title, self._subtitle = config.Title or "Window Title", config.Subtitle or ""

	T.loadSkin(self.Style)
	if config.Theme then T.applyPreset(config.Theme) end
	if config.Accent then T.setAccent(config.Accent) end
	if config.Transparency then Theme.PanelTransparency = config.Transparency end
	if config.CornerRadius then Theme.Corner = config.CornerRadius end
	if config.AnimSpeed then Theme.AnimSpeed = config.AnimSpeed end
	if config.Font and table.find(T.FontNames, config.Font) then Theme.Font = Enum.Font[config.Font] end

	local gui = New("ScreenGui", {
		Name = config.Name or "ModularGui", ResetOnSpawn = false, IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	})
	local root = New("Frame", {
		Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromOffset(300, 300), Parent = gui,
	})
	local scale = New("UIScale", { Scale = 1, Parent = root })
	-- the clip hides the panel while it is "inside" the bar, so it appears to slide out of / into it
	local clip = New("Frame", {
		Name = "Clip", BackgroundTransparency = 1, ClipsDescendants = true, Size = UDim2.fromOffset(300, 300), Parent = root,
	})
	local panel = New("Frame", {
		Name = "Panel", BackgroundTransparency = 1, Size = UDim2.fromOffset(300, 300), Parent = clip,
	})
	self.Gui, self.Root, self.UIScale, self.Clip, self.Panel = gui, root, scale, clip, panel

	local L = State.Layout
	self.Parts.Body = Shadowed(panel, "Body", "Frame", L.Body.Position, L.Body.Size, "Window", Theme.Depth + 5, nil, "window")
	buildBar(self, root)
	buildHeader(self, panel)
	buildSidebar(self, panel)
	buildContent(self, panel)
	buildFooter(self, panel)
	buildToasts(self, gui)
	buildWidget(self, gui)

	for key, holder in self.Parts do
		local r = L[key]
		holder.Position, holder.Size = r.Position, r.Size
	end
	self:_layoutDock()
	self:_layoutBar()
	self:_layoutSidebar()
	ApplyAll()

	-- dragging: along the docked edge only, from the bar or the title. A click on the title (no movement) folds / unfolds the panel
	MakeDrag(self.BarFace, self)
	local titleDrag = MakeDrag(self.TitleButton, self)
	self.TitleButton.MouseButton1Click:Connect(function()
		if not titleDrag.Moved then self:ToggleMinimize() end
	end)

	-- toggle / minimize keys + key binding
	table.insert(self._conns, UserInputService.InputBegan:Connect(function(input, processed)
		if self._binding then
			if input.UserInputType == Enum.UserInputType.Keyboard then
				self._binding = false
				self._swallow = true
				task.defer(function() self._swallow = false end)
				if input.KeyCode ~= Enum.KeyCode.Escape then
					self.ToggleKey = input.KeyCode
					if config.OnToggleKeyChanged then config.OnToggleKeyChanged(input.KeyCode) end
				end
				self:_refreshBind()
			end
			return
		end
		if self._capturing or self._swallow or processed then return end
		if input.KeyCode == self.ToggleKey then
			self:Toggle()
		elseif self.MinimizeKey and input.KeyCode == self.MinimizeKey then
			self:ToggleMinimize()
		end
	end))

	-- keep the dock inside the screen when the scale or the viewport changes
	table.insert(self._conns, scale:GetPropertyChangedSignal("Scale"):Connect(function()
		if self.IsOpen then self:_setOffset(self.Offset) end
	end))
	local camera = workspace.CurrentCamera
	if camera then
		table.insert(self._conns, camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if self.IsOpen then Anim.SetScale(self.UIScale, self:_target()) end
		end))
	end
	-- touch / click inside the dock counts as "in use"
	table.insert(self._conns, UserInputService.InputBegan:Connect(function(input)
		if not self.IsOpen then return end
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
			local p = Vector2.new(input.Position.X, input.Position.Y) + GuiService:GetGuiInset()
			if self:_inside(p, 8) then self._lastActive = os.clock() end
		end
	end))

	if config.StartCollapsed then
		self.IsOpen = false
		self.Root.Visible = false
		self.Minimized, self._panelOpen = true, false
		self.Panel.Position = self:_collapsedPos()
		self.Panel.Visible = false
		self:_setBarLen(BAR_MIN_LEN)
		self:_enterWidget(false)
	end

	task.spawn(function()
		while self.Gui.Parent do
			task.wait(0.25)
			self:_idleTick()
		end
	end)
	return self
end

-------------------------------------------------------------------------------
-- TABS
-------------------------------------------------------------------------------
function GuiUI:_dir(oldOrder, newOrder)
	if self.SlideMode == "LeftToRight" then return -1 end
	if self.SlideMode == "RightToLeft" then return 1 end
	return newOrder >= oldOrder and 1 or -1
end

local function newTab(self, id, name, isBottom)
	local S = Theme.Size
	local order
	if isBottom then
		self._bottomCount += 1
		order = 1000 + self._bottomCount
	else
		self._sideCount += 1
		order = self._sideCount
	end

	local btn
	if isBottom then
		btn = Button(self.FooterButtons, id, UDim2.new(), UDim2.fromOffset(S.SmallW, S.SmallH), name,
			fieldOpts({ Depth = 3, TextSize = Theme.FontSize.Small, Kind = "bottom" }), function() self:SelectTab(id) end)
	else
		local size = State.Skin.Horizontal and UDim2.new(0, 120, 1, 0) or UDim2.new(1, 0, 0, S.Tab)
		btn = Button(self.TabList, id, UDim2.new(), size, name,
			{ Color = "SideTab", HoverColor = "SideTabH", PressColor = "SideTabP", Kind = "tab" },
			function() self:SelectTab(id) end)
	end
	btn.Holder.LayoutOrder = order

	local contentPage = self.MainHost:Add(id)
	local subHost = NewHost(contentPage)
	local barPage = self.HeaderHost:Add(id)
	New("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center, Parent = barPage,
	})
	New("UIPadding", { PaddingLeft = UDim.new(0, S.Gap), Parent = barPage })

	local tab = setmetatable({
		UI = self, Id = id, Name = name, Order = order, Button = btn, IsBottom = isBottom,
		SubHost = subHost, Bar = barPage, Subs = {}, SubCount = 0, CurrentSub = nil,
	}, Tab)
	self.Tabs[id] = tab
	if not self.CurrentTab then self:SelectTab(id) end
	return tab
end

function GuiUI:AddTab(id, name) return newTab(self, id, name, false) end
function GuiUI:AddBottomTab(id, name) return newTab(self, id, name, true) end

function GuiUI:SelectTab(id)
	local tab = self.Tabs[id]
	if not tab or id == self.CurrentTab then return end
	local old = self.Tabs[self.CurrentTab]
	if old then old.Button.SetActive(false) end

	self.CurrentTab = id
	tab.Button.SetActive(true)

	local dir = self:_dir(old and old.Order or 0, tab.Order)
	self.MainHost:Show(id, dir)
	self.HeaderHost:Show(id, dir)
	self.TabLabel.Text = tab.Name
end

function Tab:AddSubTab(id, name)
	local S = Theme.Size
	self.SubCount += 1
	local btn = Button(self.Bar, "Sub_" .. id, UDim2.new(), UDim2.fromOffset(S.SmallW, S.SmallH), name,
		fieldOpts({ Depth = 3, TextSize = Theme.FontSize.Small, Kind = "sub" }), function() self:SelectSub(id) end)
	btn.Holder.LayoutOrder = self.SubCount

	local frame = self.SubHost:Add(id)
	local container = New("ScrollingFrame", {
		Name = "Container", BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4, Parent = frame,
	})
	New("UIPadding", { PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 14), Parent = container })
	New("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = container })

	local sub = setmetatable({
		UI = self.UI, Id = id, Name = name, Order = self.SubCount, Button = btn, Container = container, Count = 0,
	}, Page)
	self.Subs[id] = sub
	if not self.CurrentSub then self:SelectSub(id) end
	return sub
end

function Tab:SelectSub(id)
	local new = self.Subs[id]
	if not new or id == self.CurrentSub then return end
	local old = self.Subs[self.CurrentSub]
	if old then old.Button.SetActive(false) end
	self.CurrentSub = id
	new.Button.SetActive(true)
	self.SubHost:Show(id, self.UI:_dir(old and old.Order or 0, new.Order))
end

-------------------------------------------------------------------------------
-- INSTALL THE OTHER MODULES ONTO THE CLASSES
-------------------------------------------------------------------------------
import("Dock")(GuiUI)
import("Controls")(Page)
import("Behavior")(GuiUI)

return GuiUI

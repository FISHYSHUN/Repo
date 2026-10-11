-- modules/Dock.lua  (merged: Dock + Behavior + Comfort + Float)
-- One installer:  import("Dock")(GuiUI)  adds, in this order:
--   Dock (layout)  Behavior (open / close / API)  Comfort (tab labels, spacing, toasts)  Float (drag-out tabs)
local import = ...

-- ======== Dock (merged) ========
local installDock = (function(...)
-- modules/Dock.lua
-- Layout methods for the docked window: bar, panel, edge widget, scaling, idle auto-hide.
-- Returns an installer:  require("Dock")(GuiUI)  adds the methods to the GuiUI class.
local import = ...

local UserInputService = game:GetService("UserInputService")

local T = import("Theme")
local Kit = import("Toolkit")
local Theme, State, C = T.Theme, T.State, T.Const
local Anim, ApplyAll = Kit.Anim, Kit.ApplyAll

local BAR_GAP, CLIP_PAD, BAR_MIN_LEN = C.BAR_GAP, C.CLIP_PAD, C.BAR_MIN_LEN
local WIDGET_T, WIDGET_PEEK, WIDGET_HOVER = C.WIDGET_T, C.WIDGET_PEEK, C.WIDGET_HOVER

return function(GuiUI)

	function GuiUI:_refreshTitle()
		self.TitleButton.Text = self._title
		self.SubtitleLabel.Text = self._subtitle
	end

	function GuiUI:_titleAngle()
		if self.DockSide == "Top" then return 0 end
		if self.TitleRot == "Up" then return -90 end
		if self.TitleRot == "Down" then return 90 end
		return self.DockSide == "Right" and 90 or -90
	end

	-- Left/Right: buttons stacked at the top, title rotated in the center, version at the bottom.
	-- Top: buttons on the left, title centered, version on the right.
	function GuiUI:_layoutBar()
		local skin = State.Skin
		local sys = skin.Sys
		local horizontal = self.DockSide == "Top"
		local size = self.BarSize
		local full = horizontal and self._panelW or self._panelH
		self.BarContent.Size = horizontal and UDim2.new(0, full, 1, 0) or UDim2.new(1, 0, 0, full)
		-- buttons follow the bar thickness; the style decides how big they are relative to it
		local factor = math.clamp(sys.Size / 38, 0.6, 1)
		local bs = math.clamp(math.round(size * 0.68 * factor), 18, 60)
		local gap = math.max(sys.Gap, 6)
		local p = 10
		for _, name in sys.Order do
			local b = self.Sys[name]
			b.Holder.Size = UDim2.fromOffset(bs, bs)
			if horizontal then
				b.Holder.AnchorPoint = Vector2.new(0, 0.5)
				b.Holder.Position = UDim2.new(0, p, 0.5, 0)
			else
				b.Holder.AnchorPoint = Vector2.new(0.5, 0)
				b.Holder.Position = UDim2.new(0.5, 0, 0, p)
			end
			for _, g in b.Glyphs do g.Visible = sys.Glyphs ~= false end
			p += bs + gap
		end

		local sub = self.SubtitleLabel
		if horizontal then
			sub.Position, sub.Size = UDim2.new(1, -78, 0.5, -11), UDim2.fromOffset(72, 22)
		else
			sub.Position, sub.Size = UDim2.new(0, 2, 1, -30), UDim2.new(1, -4, 0, 22)
		end
		sub.TextSize = size < 48 and 12 or 14

		-- the title is centered, so keep the same free space on both sides of it
		local space = horizontal and self._panelW or self._panelH
		local t = self.TitleButton
		t.Size = UDim2.fromOffset(math.max(40, space - 2 * (p + 10)), 28)
		t.Position = UDim2.fromScale(0.5, 0.5)
		t.Rotation = self:_titleAngle()
		t.TextSize = math.clamp(math.round((skin.Title.Size or 18) * size / 56), 12, 26)
		self:_refreshTitle()
	end

	function GuiUI:_layoutSidebar()
		local hz = State.Skin.Horizontal == true
		local S = Theme.Size
		self.TabListLayout.FillDirection = hz and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
		self.TabList.CanvasSize = UDim2.new()
		self.TabList.AutomaticCanvasSize = hz and Enum.AutomaticSize.X or Enum.AutomaticSize.Y
		self.TabList.ScrollingDirection = hz and Enum.ScrollingDirection.X or Enum.ScrollingDirection.Y
		self.TabList.ScrollBarThickness = 3 -- also on the top row, so you can see there is more to scroll to
		local p = UDim.new(0, hz and 5 or 8)
		local pad = self.TabListPad
		pad.PaddingTop, pad.PaddingBottom, pad.PaddingLeft, pad.PaddingRight = p, p, UDim.new(0, 8), UDim.new(0, 8)
		self.TabListLayout.Padding = UDim.new(0, self.TabGap)
		self:_refreshTabLabels()
	end

	function GuiUI:_openPos()
		return UDim2.fromOffset(CLIP_PAD, CLIP_PAD)
	end

	-- where the panel hides: fully inside the bar's side of the clip
	function GuiUI:_collapsedPos()
		if self.DockSide == "Top" then return UDim2.new(0, CLIP_PAD, -1, 0) end
		if self.DockSide == "Right" then return UDim2.new(1, 0, 0, CLIP_PAD) end
		return UDim2.new(-1, 0, 0, CLIP_PAD)
	end

	-- screen position of the dock: glued to its edge, free only along that edge (Offset).
	-- The anchor point sits on the edge, so scaling the dock down shrinks it right into the widget.
	function GuiUI:_dockPos()
		if self.DockSide == "Top" then
			return UDim2.new(0.5, self.Offset, 0, 0)
		elseif self.DockSide == "Right" then
			return UDim2.new(1, 0, 0.5, self.Offset)
		end
		return UDim2.new(0, 0, 0.5, self.Offset)
	end

	function GuiUI:_clampOffset(off)
		local horizontal = self.DockSide == "Top"
		local vp = horizontal and self.Gui.AbsoluteSize.X or self.Gui.AbsoluteSize.Y
		if vp <= 0 then return off end
		local len = (horizontal and self._rootW or self._rootH) * self:_target()
		local range = math.max(0, (vp - len) / 2)
		return math.clamp(off, -range, range)
	end

	function GuiUI:_setOffset(off)
		self.Offset = self:_clampOffset(off)
		self.Root.Position = self:_dockPos()
		if self._wVis > 0 then self:_placeWidget() end -- (a hidden widget is placed when it comes back)
	end

	-- BAR LENGTH --------------------------------------------------------------
	-- The bar is always centered on its edge; `len` is its length along that edge. Animating it
	-- makes the bar extend from the center outwards (up + down, or left + right on Top).
	function GuiUI:_barFull()
		return self.DockSide == "Top" and self._panelW or self._panelH
	end

	function GuiUI:_barRect(len)
		if self.DockSide == "Top" then
			return UDim2.fromOffset((self._panelW - len) / 2, 0), UDim2.fromOffset(len, self.BarSize)
		end
		local x = self.DockSide == "Right" and (self._panelW + BAR_GAP) or 0
		return UDim2.fromOffset(x, (self._panelH - len) / 2), UDim2.fromOffset(self.BarSize, len)
	end

	function GuiUI:_setBarLen(len)
		self.BarHolder.Position, self.BarHolder.Size = self:_barRect(len)
	end

	function GuiUI:_tweenBarLen(len, time, style, direction, onDone)
		local pos, size = self:_barRect(len)
		local tween = Anim.Tween(self.BarHolder, time, { Position = pos, Size = size }, style, direction)
		tween.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed and onDone then onDone() end
		end)
	end

	-- WIDGET ------------------------------------------------------------------
	-- `visible` = how many px of the widget are on screen (0 = fully hidden)
	function GuiUI:_widgetPos(visible)
		local hide = WIDGET_T - visible
		if self.DockSide == "Top" then
			return UDim2.new(0.5, self.Offset, 0, -hide)
		elseif self.DockSide == "Right" then
			return UDim2.new(1, hide, 0.5, self.Offset)
		end
		return UDim2.new(0, -hide, 0.5, self.Offset)
	end

	function GuiUI:_cancelWidgetTween()
		if self._wTween then self._wTween:Cancel(); self._wTween = nil end
	end

	-- puts widget + hit area at the current Offset (instantly)
	function GuiUI:_placeWidget()
		self:_cancelWidgetTween()
		self.WidgetHolder.Position = self:_widgetPos(self._wVis)
		if self.DockSide == "Top" then
			self.WidgetHit.Position = UDim2.new(0.5, self.Offset, 0, 0)
		elseif self.DockSide == "Right" then
			self.WidgetHit.Position = UDim2.new(1, 0, 0.5, self.Offset)
		else
			self.WidgetHit.Position = UDim2.new(0, 0, 0.5, self.Offset)
		end
	end

	function GuiUI:_showWidget(visible, time)
		self._wVis = visible
		self:_cancelWidgetTween()
		if time and time > 0 then
			self._wTween = Anim.Tween(self.WidgetHolder, time, { Position = self:_widgetPos(visible) }, Enum.EasingStyle.Quint)
		else
			self.WidgetHolder.Position = self:_widgetPos(visible)
		end
	end

	function GuiUI:_hoverWidget(on)
		if self.IsOpen then return end
		self:_showWidget(on and WIDGET_HOVER or WIDGET_PEEK, 0.2)
	end

	-- shape / side / style of the widget
	function GuiUI:_layoutWidget()
		local side, L = self.DockSide, self.WidgetLen
		local horizontal = side == "Top"
		local anchor = horizontal and Vector2.new(0.5, 0) or Vector2.new(side == "Right" and 1 or 0, 0.5)
		local holder, hit = self.WidgetHolder, self.WidgetHit
		holder.AnchorPoint, hit.AnchorPoint = anchor, anchor
		holder.Size = horizontal and UDim2.fromOffset(L, WIDGET_T) or UDim2.fromOffset(WIDGET_T, L)
		hit.Size = horizontal and UDim2.fromOffset(L + 16, WIDGET_T) or UDim2.fromOffset(WIDGET_T, L + 16)

		-- grip dots sit on the inner side of the tab
		for i, d in self.WidgetDots do
			local k = (i - 2) * 9
			if horizontal then
				d.Position = UDim2.new(0.5, k, 1, -10)
			elseif side == "Right" then
				d.Position = UDim2.new(0, 10, 0.5, k)
			else
				d.Position = UDim2.new(1, -10, 0.5, k)
			end
		end
		self:_placeWidget()
	end

	-- is a screen point over the dock? (only the bar counts while the menu is folded)
	function GuiUI:_inside(p, margin)
		local obj = self.Minimized and self.BarHolder or self.Root
		local pos, size = obj.AbsolutePosition, obj.AbsoluteSize
		return p.X >= pos.X - margin and p.X <= pos.X + size.X + margin
			and p.Y >= pos.Y - margin and p.Y <= pos.Y + size.Y + margin
	end

	-- called a few times per second: tucks the dock into the widget when it has been left alone
	function GuiUI:_idleTick()
		if not self.IsOpen or not self.AutoHide then return end
		if self._binding or self._capturing then self._lastActive = os.clock() return end
		if self:_inside(UserInputService:GetMouseLocation(), 6) then
			self._lastActive = os.clock()
		elseif os.clock() - self._lastActive >= self.IdleTime then
			self:Close()
		end
	end

	-- sizes + side placement of bar / panel (called on creation, style change, side / thickness change)
	function GuiUI:_layoutDock()
		local px = State.Layout.PanelPx
		local side, bar, P = self.DockSide, self.BarSize, CLIP_PAD
		self._panelW, self._panelH = px.X, px.Y

		if side == "Top" then
			self._rootW, self._rootH = px.X, bar + BAR_GAP + px.Y
			self.Root.AnchorPoint = Vector2.new(0.5, 0)
			self.Clip.Position = UDim2.fromOffset(-P, bar + BAR_GAP - P)
		else
			self._rootW, self._rootH = bar + BAR_GAP + px.X, px.Y
			self.Root.AnchorPoint = Vector2.new(side == "Right" and 1 or 0, 0.5)
			if side == "Right" then
				self.Clip.Position = UDim2.fromOffset(-P, -P)
			else
				self.Clip.Position = UDim2.fromOffset(bar + BAR_GAP - P, -P)
			end
		end

		self.Root.Size = UDim2.fromOffset(self._rootW, self._rootH)
		self.Clip.Size = UDim2.fromOffset(px.X + 2 * P, px.Y + 2 * P)
		self.Panel.Size = UDim2.fromOffset(px.X, px.Y)
		self.Panel.Position = self._panelOpen and self:_openPos() or self:_collapsedPos()

		self:_setBarLen(self.IsOpen and self:_barFull() or BAR_MIN_LEN)
		self.UIScale.Scale = self:_target()
		self.Offset = self:_clampOffset(self.Offset)
		self.Root.Position = self:_dockPos()
		self:_layoutWidget()
	end

	function GuiUI:_applyStyle()
		for key, holder in self.Parts do
			local r = State.Layout[key]
			holder.Position, holder.Size = r.Position, r.Size
		end
		self:_layoutDock()
		self:_layoutBar()
		self:_layoutSidebar()
		ApplyAll()
	end

	-- Fits the dock to ~80% of the screen height, then applies the user multiplier
	function GuiUI:_target()
		local camera = workspace.CurrentCamera
		local vp = camera and camera.ViewportSize or Vector2.new(1920, 1080)
		local w, h = self._rootW, self._rootH
		local fit = math.clamp(math.min(vp.Y * 0.8 / h, vp.X * 0.92 / w), 0.4, 1.6)
		local want = fit * self.UserScale * (self.Maximized and 1.2 or 1)
		local cap = math.min(vp.Y * 0.97 / h, vp.X * 0.97 / w)
		return math.min(want, cap)
	end

end
end)(import)

-- ======== Behavior (merged) ========
local installBehavior = (function(...)
-- modules/Behavior.lua
-- Window behavior: toggle-key binding, open / close / minimize, notifications, customization API.
-- (merged into Dock.lua) installer for the GuiUI class
--
--   minimize = the panel slides smoothly into the bar (click the title / (-) to slide it out again)
--   close    = same, then the bar contracts to its center and the edge widget appears
local import = ...

local T = import("Theme")
local Kit = import("Toolkit")
local Theme, State, C = T.Theme, T.State, T.Const
local Anim, ApplyAll = Kit.Anim, Kit.ApplyAll
local New, Bind, Label, Shadowed = Kit.New, Kit.Bind, Kit.Label, Kit.Shadowed

local SLIDE_TIME, BAR_GROW_TIME, BAR_SHRINK_TIME = C.SLIDE_TIME, C.BAR_GROW_TIME, C.BAR_SHRINK_TIME
local BAR_MIN_LEN, BAR_MIN, BAR_MAX, WIDGET_PEEK, CORNER_MAX = C.BAR_MIN_LEN, C.BAR_MIN, C.BAR_MAX, C.WIDGET_PEEK, C.CORNER_MAX

return function(GuiUI)

	-- true while a key is being captured (bind buttons) - hotkey handlers should skip that press
	function GuiUI:IsCapturing()
		return self._binding or self._capturing or self._swallow
	end

	---------------------------------------------------------------------------
	-- TOGGLE-KEY BINDING
	---------------------------------------------------------------------------
	function GuiUI:_refreshBind()
		local keyText = self._binding and "press a key..." or self.ToggleKey.Name
		self.BindButton.SetText("Bind [Toggle UI]: " .. keyText)
		self.BindButton.SetActive(self._binding)
	end

	function GuiUI:_toggleBinding()
		self._binding = not self._binding
		self:_refreshBind()
	end

	function GuiUI:SetToggleKey(keyCode)
		self.ToggleKey = keyCode
		self:_refreshBind()
	end

	function GuiUI:SetMinimizeKey(keyCode) self.MinimizeKey = keyCode end

	---------------------------------------------------------------------------
	-- OPEN / CLOSE / MINIMIZE
	---------------------------------------------------------------------------
	function GuiUI:_bump()
		self._token += 1
		return self._token
	end

	-- slides the panel out of (open = true) or into (open = false) the bar
	function GuiUI:_slidePanel(open, onDone)
		self._slideToken += 1
		local tk = self._slideToken
		if open then self.Panel.Visible = true end
		local target = open and self:_openPos() or self:_collapsedPos()
		local tween = Anim.Tween(self.Panel, SLIDE_TIME, { Position = target },
			Enum.EasingStyle.Quart, Enum.EasingDirection.InOut)
		tween.Completed:Once(function(state)
			if state ~= Enum.PlaybackState.Completed then return end -- replaced by a newer slide
			if tk == self._slideToken and not open then self.Panel.Visible = false end
			if onDone then onDone() end
		end)
	end

	function GuiUI:Collapse(onDone)
		self.Minimized = true
		if not self._panelOpen then
			if onDone then task.defer(onDone) end
			return
		end
		self._panelOpen = false
		self:_slidePanel(false, onDone)
		if not self._hinted and self.IsOpen then
			self._hinted = true
			self:Notify("Click the bar title to slide the menu back out", 3.5)
		end
	end

	function GuiUI:Expand()
		self.Minimized = false
		if self._panelOpen then return end
		self._panelOpen = true
		self:_slidePanel(true, function() self:_playEntrance() end)
	end

	function GuiUI:ToggleMinimize()
		if not self.IsOpen then return end
		if self.Minimized then self:Expand() else self:Collapse() end
	end

	-- widget slides in from off-screen to its resting peek
	function GuiUI:_enterWidget(animate)
		self:_placeWidget()
		self.WidgetHolder.Visible = true
		self.WidgetHit.Visible = true
		self:_showWidget(0)
		self:_showWidget(WIDGET_PEEK, animate and 0.4 or 0)
	end

	-- the bar extends from its center outwards, then the menu slides out of it
	function GuiUI:Open()
		if self.IsOpen then return end
		self.IsOpen = true
		local token = self:_bump()
		self._lastActive = os.clock()

		self.WidgetHit.Visible = false
		self:_showWidget(0, 0.2)
		task.delay(0.25, function()
			if token == self._token then self.WidgetHolder.Visible = false end
		end)

		-- the menu starts hidden inside the bar
		self.Minimized, self._panelOpen = true, false
		self._slideToken += 1
		self.Panel.Position = self:_collapsedPos()
		self.Panel.Visible = false

		self:_setBarLen(BAR_MIN_LEN)
		self.Root.Visible = true
		self:_setOffset(self.Offset)
		self:_tweenBarLen(self:_barFull(), BAR_GROW_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, function()
			if token == self._token then self:Expand() end
		end)
	end

	-- the menu slides into the bar, then the bar contracts to its center and the widget appears
	function GuiUI:Close()
		if not self.IsOpen then return end
		self.IsOpen = false
		local token = self:_bump()
		self:Collapse(function()
			if token ~= self._token then return end
			self:_tweenBarLen(BAR_MIN_LEN, BAR_SHRINK_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.In, function()
				if token ~= self._token then return end
				self.Root.Visible = false
				self:_enterWidget(true)
			end)
		end)
		if not self._widgetHinted then
			self._widgetHinted = true
			self:Notify("Menu tucked into the edge widget. Hover it and click to reopen.", 4)
		end
	end

	function GuiUI:Toggle()
		if self.IsOpen then self:Close() else self:Open() end
	end

	---------------------------------------------------------------------------
	-- NOTIFICATIONS
	---------------------------------------------------------------------------
	function GuiUI:Notify(text, duration)
		if self.Notifications == false then return end
		duration = (duration or 2.5) * (self.ToastScale or 1)
		local dir = self.ToastDir or 320
		self._toastCount += 1
		self._toasts = self._toasts or {}
		local holder = New("Frame", {
			Name = "Toast", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36),
			LayoutOrder = self._toastCount, Parent = self.ToastArea,
		})
		local slide = New("Frame", {
			BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Position = UDim2.fromOffset(dir, 0), Parent = holder,
		})
		local _, face = Shadowed(slide, "ToastBody", "Frame", UDim2.new(), UDim2.fromScale(1, 1), "Window", 3, nil, "toast")
		-- accent bar is inset from the edges so it never pokes out of rounded corners
		local bar = New("Frame", {
			BorderSizePixel = 0, Position = UDim2.fromOffset(6, 6), Size = UDim2.new(0, 4, 1, -12), Parent = face,
		})
		New("UICorner", { CornerRadius = UDim.new(0, 2), Parent = bar })
		Bind(bar, "BackgroundColor3", "Active")
		Label(face, text, { Align = Enum.TextXAlignment.Left, TextSize = Theme.FontSize.Small, PadX = 18 })

		-- leaving: slide out to the screen edge it came from, then the space it used folds shut so the others glide down
		local toast = {}
		function toast.Dismiss()
			if toast.Done then return end
			toast.Done = true
			local i = table.find(self._toasts, toast)
			if i then table.remove(self._toasts, i) end
			if holder.Parent == nil then return end
			local out = Anim.Tween(slide, 0.25, { Position = UDim2.fromOffset(dir, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			out.Completed:Once(function()
				if holder.Parent == nil then return end
				local fold = Anim.Tween(holder, 0.2, { Size = UDim2.new(1, 0, 0, 0) }, Enum.EasingStyle.Quad)
				fold.Completed:Once(function() holder:Destroy() end)
			end)
		end

		table.insert(self._toasts, toast)
		if #self._toasts > 4 then self._toasts[1].Dismiss() end -- never more than 4 at once

		Anim.Tween(slide, 0.3, { Position = UDim2.new() }, Enum.EasingStyle.Back)
		task.delay(duration, toast.Dismiss)
	end

	---------------------------------------------------------------------------
	-- CUSTOMIZATION API
	---------------------------------------------------------------------------
	function GuiUI:SetTitle(text) self._title = text; self:_refreshTitle() end
	function GuiUI:SetSubtitle(text) self._subtitle = text; self:_refreshTitle() end

	function GuiUI:GetThemeNames() return table.clone(T.PresetOrder) end
	function GuiUI:GetFontNames() return table.clone(T.FontNames) end
	function GuiUI:GetStyleNames() return table.clone(T.StyleOrder) end
	function GuiUI:GetDockSides() return table.clone(T.DockSides) end
	function GuiUI:GetTitleRotations() return table.clone(T.TitleRotations) end
	function GuiUI:GetStyle() return self.Style end
	function GuiUI:GetAccent() return Theme.Active end

	-- switches the whole UI: layout, shapes, palette, fonts, controls. Returns the style's defaults
	-- so a settings page can sync its sliders: { Transparency, Corner, Font, Accent }
	function GuiUI:SetStyle(name)
		if T.Skins[name] and name ~= self.Style then
			self.Style = name
			T.loadSkin(name)
			self:_applyStyle()
		end
		return {
			Transparency = Theme.PanelTransparency, Corner = Theme.Corner,
			Font = State.Skin.Defaults.Font, Accent = Theme.Active,
		}
	end

	-- recolors the current style: "Default" = the style's own palette, or Dark / Midnight / Forest / Crimson / Light
	function GuiUI:SetTheme(name)
		if name ~= "Default" and not T.Presets[name] then return Theme.Active end
		T.applyPreset(name)
		ApplyAll()
		return Theme.Active
	end

	function GuiUI:SetAccent(color)
		T.setAccent(color)
		ApplyAll()
	end

	function GuiUI:SetFont(name)
		if not table.find(T.FontNames, name) then return end
		Theme.Font = Enum.Font[name]
		ApplyAll()
	end

	function GuiUI:SetCornerRadius(px)
		Theme.Corner = math.clamp(px, 0, CORNER_MAX)
		ApplyAll()
	end

	function GuiUI:SetAnimSpeed(multiplier) Theme.AnimSpeed = math.clamp(multiplier, 0.25, 4) end
	function GuiUI:SetSlideMode(mode) self.SlideMode = mode end
	function GuiUI:SetDraggable(enabled) self.Draggable = enabled end
	-- cards rising into place when a page opens (turn off for a perfectly still menu)
	function GuiUI:SetEntrance(enabled) self.Entrance = enabled end

	-- "Left" | "Right" | "Top": which screen edge the bar is glued to
	function GuiUI:SetDockSide(side)
		if not table.find(T.DockSides, side) or side == self.DockSide then return end
		local wasTop = self.DockSide == "Top"
		self.DockSide = side
		if wasTop ~= (side == "Top") then self.Offset = 0 end -- different axis: recenter
		self:_layoutDock()
		self:_layoutBar()
	end

	-- widget behavior ---------------------------------------------------------
	function GuiUI:SetAutoHide(enabled)
		self.AutoHide = enabled
		self._lastActive = os.clock()
	end

	-- seconds without using the menu before it shrinks into the widget
	function GuiUI:SetIdleTime(seconds)
		self.IdleTime = math.clamp(seconds, 2, 120)
		self._lastActive = os.clock()
	end

	-- length of the widget along the screen edge (px)
	function GuiUI:SetWidgetLength(px)
		self.WidgetLen = math.clamp(math.round(px), 50, 200)
		self:_layoutWidget()
	end

	-- bar thickness in px (width on Left/Right, height on Top)
	function GuiUI:SetBarSize(px)
		self.BarSize = math.clamp(math.round(px), BAR_MIN, BAR_MAX)
		self:_layoutDock()
		self:_layoutBar()
	end

	-- "Auto" | "Up" | "Down": direction the name is written in the bar
	function GuiUI:SetTitleRotation(mode)
		if not table.find(T.TitleRotations, mode) then return end
		self.TitleRot = mode
		self.TitleButton.Rotation = self:_titleAngle()
	end

	-- back to the center of the edge
	function GuiUI:ResetPosition()
		self.Offset = 0
		if self.IsOpen then
			Anim.Tween(self.Root, 0.3, { Position = self:_dockPos() }, Enum.EasingStyle.Quint)
		end
		self:_placeWidget()
	end

	-- 0 = solid, 1 = invisible. Updates every existing panel and all future ones.
	function GuiUI:SetPanelTransparency(t)
		Theme.PanelTransparency = math.clamp(t, 0, 0.95)
		ApplyAll()
	end

	function GuiUI:SetUserScale(multiplier)
		self.UserScale = multiplier
		if self.IsOpen then Anim.SetScale(self.UIScale, self:_target()) end
	end

	function GuiUI:ToggleMaximize()
		if not self.IsOpen then return end
		if self.Minimized then self:Expand() end
		self.Maximized = not self.Maximized
		Anim.SetScale(self.UIScale, self:_target())
	end

	function GuiUI:Destroy()
		self:_bump()
		for _, conn in self._conns do conn:Disconnect() end
		table.clear(self._conns)
		self.Gui:Destroy()
	end

end
end)(import)

-- ======== Comfort (merged) ========
local installComfort = (function(...)
-- modules/Comfort.lua
-- Quality-of-life settings: tab labels (icons / text / both), spacing, notification placement.
local import = ...

local TextService = game:GetService("TextService")

local T = import("Theme")
local Theme, State = T.Theme, T.State

local MODES = { "Icons", "Text", "Both" }
local MIN_TAB_W, MIN_TAB_H = 36, 30 -- a tab is squeezed down to this before the list has to scroll
local CORNERS = { "Bottom Right", "Bottom Left", "Top Right", "Top Left" }

return function(GuiUI)

	function GuiUI:GetTabDisplayModes() return table.clone(MODES) end
	function GuiUI:GetToastCorners() return table.clone(CORNERS) end

	-- text / size of every sidebar tab button for the current display mode
	function GuiUI:_refreshTabLabels()
		local hz = State.Skin.Horizontal == true
		local S = Theme.Size
		local mode = self.TabDisplay
		local both = mode == "Both"
		for _, tab in self.Tabs do
			if not tab.IsBottom then
				local btn = tab.Button
				local face = btn.Face
				local img = face:FindFirstChildOfClass("ImageLabel")

				local text
				if tab.IsImage then
					text = mode == "Icons" and "" or tab.Name
				else
					local glyph = tab.Icon or tab.Name:sub(1, 1)
					if mode == "Icons" then text = glyph
					elseif mode == "Text" then text = tab.Name
					else text = glyph .. "  " .. tab.Name end
				end

				local imageBeside = both and img ~= nil
				if img then
					img.Visible = mode ~= "Text"
					img.AnchorPoint = both and Vector2.new(0, 0.5) or Vector2.new(0.5, 0.5)
					img.Position = both and UDim2.new(0, 10, 0.5, 0) or UDim2.fromScale(0.5, 0.5)
				end
				btn.Pad.PaddingLeft = imageBeside and UDim.new(0, 40) or UDim.new(0, 4)
				face.TextXAlignment = imageBeside and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center
				face.TextSize = mode == "Icons" and 24 or Theme.FontSize.Small
				btn.SetText(text)

				if hz then
					local w = S.TabIcon
					if mode ~= "Icons" then
						local bounds = TextService:GetTextSize(text, face.TextSize, Theme.Font, Vector2.new(1000, 100))
						w = math.max(S.TabIcon, math.ceil(bounds.X) + (imageBeside and 52 or 24))
					end
					btn.Holder.Size = UDim2.new(0, w, 1, 0)
				else
					btn.Holder.Size = UDim2.new(1, 0, 0, S.Tab)
				end
			end
		end
	end

	function GuiUI:SetTabDisplay(mode)
		if not table.find(MODES, mode) then return end
		self.TabDisplay = mode
		self:_refreshTabLabels()
		local tab = self.Tabs[self.CurrentTab]
		if tab and not tab.IsBottom then self:_revealTab(tab) end
	end

	function GuiUI:SetTabSpacing(px)
		self.TabGap = math.clamp(math.round(px), 0, 24)
		self.TabListLayout.Padding = UDim.new(0, self.TabGap)
		self:_fitTabs()
	end

	function GuiUI:SetControlSpacing(px)
		self.ControlGap = math.clamp(math.round(px), 0, 20)
		for i = #self._spacers, 1, -1 do
			local s = self._spacers[i]
			if s[1].Parent == nil then
				table.remove(self._spacers, i)
			else
				s[1].Padding = UDim.new(0, self.ControlGap + s[2])
			end
		end
	end

	function GuiUI:SetNotifications(enabled) self.Notifications = enabled end
	function GuiUI:SetToastTime(multiplier) self.ToastScale = math.clamp(multiplier, 0.5, 3) end

	function GuiUI:SetToastCorner(name)
		if not table.find(CORNERS, name) then return end
		local right = name:find("Right") ~= nil
		local bottom = name:find("Bottom") ~= nil
		local area = self.ToastArea
		area.AnchorPoint = Vector2.new(right and 1 or 0, bottom and 1 or 0)
		area.Position = UDim2.new(right and 1 or 0, right and -16 or 16, bottom and 1 or 0, bottom and -16 or 16)
		local layout = area:FindFirstChildOfClass("UIListLayout")
		if layout then
			layout.VerticalAlignment = bottom and Enum.VerticalAlignment.Bottom or Enum.VerticalAlignment.Top
		end
		self.ToastDir = right and 320 or -320
	end

	-- the font changes text widths, so re-measure the tab buttons
	local baseSetFont = GuiUI.SetFont
	function GuiUI:SetFont(name)
		baseSetFont(self, name)
		self:_refreshTabLabels()
	end

	-- tabs that are currently in the sidebar, in order
	local function visibleTabs(self)
		local list = {}
		for _, tab in self.Tabs do
			if not tab.IsBottom and not self._floats[tab.Id] then table.insert(list, tab) end
		end
		table.sort(list, function(a, b) return a.Order < b.Order end)
		return list
	end

	-- stretches the sidebar tabs so they fill the whole sidebar (works from layout numbers, so it is
	-- correct even while the menu is hidden or scaled)
	function GuiUI:_fitTabs()
		local list = visibleTabs(self)
		local n = #list
		if n == 0 then return end
		local hz = State.Skin.Horizontal == true
		local S = Theme.Size
		local L = State.Layout
		local gap = self.TabGap
		local rect = L.Sidebar.Size
		local pad = self.TabListPad

		if hz then
			local avail = L.PanelPx.X * rect.X.Scale - 16 - gap * (n - 1)
			local minTotal = 0
			for _, tab in list do minTotal += tab.MinW or S.TabIcon end
			if minTotal <= avail then
				local extra = avail - minTotal
				local each = math.floor(extra / n)
				for i, tab in list do
					local w = (tab.MinW or S.TabIcon) + each
					if i == n and extra > 0 then w = (tab.MinW or S.TabIcon) + (extra - each * (n - 1)) end
					tab.Button.Holder.Size = UDim2.new(0, math.floor(w), 1, 0)
				end
			else
				-- not enough room: every tab gets the same, smaller width (long labels truncate).
				-- Only when even that does not fit does the row scroll.
				local w = math.max(MIN_TAB_W, math.floor(avail / n))
				for _, tab in list do tab.Button.Holder.Size = UDim2.new(0, w, 1, 0) end
			end
			self.TabList.ScrollingDirection = Enum.ScrollingDirection.X
			self.TabList.CanvasSize = UDim2.new()
			-- full-height buttons: keep the glyph inside the strip so nothing is clipped
			local h = L.PanelPx.Y * rect.Y.Scale - (pad.PaddingTop.Offset + pad.PaddingBottom.Offset)
			for _, tab in list do
				local face = tab.Button.Face
				if self.TabDisplay == "Icons" then face.TextSize = math.clamp(math.floor(h - 14), 14, 24) end
			end
		else
			local availH = L.PanelPx.Y * rect.Y.Scale - (pad.PaddingTop.Offset + pad.PaddingBottom.Offset) - gap * (n - 1)
			local h = math.max(MIN_TAB_H, math.floor(availH / n))
			for _, tab in list do
				tab.Button.Holder.Size = UDim2.new(1, 0, 0, h)
			end
		end
	end

	-- every label refresh ends with a fit; the minimum width is read straight after the base pass
	local baseRefreshLabels = GuiUI._refreshTabLabels
	function GuiUI:_refreshTabLabels()
		baseRefreshLabels(self)
		local hz = State.Skin.Horizontal == true
		for _, tab in self.Tabs do
			if not tab.IsBottom and hz then
				tab.MinW = tab.Button.Holder.Size.X.Offset
			end
		end
		self:_fitTabs()
	end

end
end)(import)

-- ======== Float (merged) ========
local installFloat = (function(...)
-- modules/Float.lua
-- Drag a sidebar tab out of the menu: it becomes its own window with a top bar.
-- Click the top bar (no drag) to put the tab back. The top bar also hosts that tab's sub-page buttons.
local import = ...

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local T = import("Theme")
local Kit = import("Toolkit")
local Theme, State = T.Theme, T.State
local New, Label, Shadowed = Kit.New, Kit.Label, Kit.Shadowed
local Insets, applyInset = Kit.Insets, Kit.applyInset

local DETACH_DISTANCE = 36 -- screen px a tab button must be dragged before it pops out
local CLICK_SLOP = 4       -- movement under this on the top bar counts as a click
local BAR_H, EDGE, TITLE_W = 38, 8, 136

local function isPress(kind)
	return kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch
end

local function isMove(kind)
	return kind == Enum.UserInputType.MouseMovement or kind == Enum.UserInputType.Touch
end

-- keeps the window on screen (its anchor is top-center)
local function place(ui, f, pos)
	local vp = ui.Gui.AbsoluteSize
	local halfW = f.W * f.Scale.Scale / 2
	local x = math.clamp(pos.X, halfW, math.max(halfW, vp.X - halfW))
	local y = math.clamp(pos.Y, 0, math.max(0, vp.Y - 40))
	f.Pos = Vector2.new(x, y)
	f.Holder.Position = UDim2.fromOffset(x, y)
end

return function(GuiUI)

	function GuiUI:IsTabFloating(id) return self._floats[id] ~= nil end
	function GuiUI:SetLockTabs(enabled) self.LockTabs = enabled end

	function GuiUI:_floatScale()
		return math.max(0.2, self.UIScale.Scale * self.FloatScale)
	end

	function GuiUI:_rescaleFloats()
		local s = self:_floatScale()
		for _, f in self._floats do
			f.Scale.Scale = s
			place(self, f, f.Pos)
		end
	end

	function GuiUI:SetFloatScale(multiplier)
		self.FloatScale = math.clamp(multiplier, 0.4, 1.4)
		self:_rescaleFloats()
	end

	function GuiUI:_startFloatDrag(f, inputPos, fromMouse, alreadyMoved)
		f.Dragging, f.Moved, f.FromMouse = true, alreadyMoved == true, fromMouse
		f.StartInput = Vector2.new(inputPos.X, inputPos.Y)
		f.StartPos = f.Pos
		self._floatZ += 1
		f.Holder.ZIndex = self._floatZ
	end

	function GuiUI:DetachTab(id, at)
		local tab = self.Tabs[id]
		if not tab or tab.IsBottom or self._floats[id] then return nil end

		local docked, count = 0, 0
		for _, t in self.Tabs do
			if not t.IsBottom then
				if self._floats[t.Id] then count += 1 else docked += 1 end
			end
		end
		if docked <= 1 then
			self:Notify("Keep at least one tab in the menu")
			return nil
		end

		local page = self.MainHost:Remove(id)
		local bar = self.HeaderHost:Remove(id)
		if not (page and bar) then
			if page then self.MainHost:Restore(id, page) end
			if bar then self.HeaderHost:Restore(id, bar) end
			return nil
		end

		if not self._floatScaleConn then
			self._floatScaleConn = self.UIScale:GetPropertyChangedSignal("Scale"):Connect(function()
				self:_rescaleFloats()
			end)
			table.insert(self._conns, self._floatScaleConn)
		end
		self._floatZ = self._floatZ or 10
		self._floatZ += 1
		self.ToastArea.ZIndex = 1000 -- toasts stay above every detached window

		-- window = the content area's size + a top bar
		local L = State.Layout
		local cw = math.round(L.PanelPx.X * L.Content.Size.X.Scale)
		local ch = math.round(L.PanelPx.Y * L.Content.Size.Y.Scale)
		local winW, winH = cw + EDGE * 2, BAR_H + ch + EDGE * 3

		local holder, face = Shadowed(self.Gui, "Float_" .. id, "Frame", UDim2.new(), UDim2.fromOffset(winW, winH),
			"Window", Theme.Depth + 3, Vector2.new(0.5, 0), "window")
		holder.ZIndex = self._floatZ
		local uiScale = New("UIScale", { Scale = self:_floatScale(), Parent = holder })

		-- top bar: the whole bar is the grip; the tab's sub-page buttons sit on top of it
		local _, barFace = Shadowed(face, "FloatBar", "Frame", UDim2.fromOffset(EDGE, EDGE),
			UDim2.new(1, -EDGE * 2, 0, BAR_H), "Field", 3, nil, "header")
		local grip = New("TextButton", {
			Name = "Grip", BackgroundTransparency = 1, AutoButtonColor = false, Text = "",
			Size = UDim2.fromScale(1, 1), Parent = barFace,
		})
		Label(barFace, tab.Name, {
			Size = UDim2.new(0, TITLE_W, 1, 0), Align = Enum.TextXAlignment.Left,
			TextSize = Theme.FontSize.Header, ColorKey = "Active", PadX = 12,
		})
		bar.Parent = barFace
		bar.Position = UDim2.fromOffset(TITLE_W, 0)
		bar.Size = UDim2.new(1, -(TITLE_W + 4), 1, 0)
		bar.Visible = true

		-- body: the tab's own content page, moved here as it is
		local _, bodyFace = Shadowed(face, "FloatBody", "Frame", UDim2.fromOffset(EDGE, BAR_H + EDGE * 2),
			UDim2.new(1, -EDGE * 2, 1, -(BAR_H + EDGE * 3)), "Content", 3, nil, "content")
		local inner = New("Frame", {
			Name = "Host", BackgroundTransparency = 1, ClipsDescendants = true,
			Size = UDim2.fromScale(1, 1), Parent = bodyFace,
		})
		table.insert(Insets, inner)
		applyInset(inner)
		page.Parent = inner
		page.Position = UDim2.new()
		page.Size = UDim2.fromScale(1, 1)
		page.Visible = true

		local f = {
			Id = id, Holder = holder, Page = page, Bar = bar, Scale = uiScale, W = winW, H = winH,
			Pos = Vector2.zero, Conns = {}, Alive = true, Dragging = false, Moved = false,
			FromMouse = false, StartInput = Vector2.zero, StartPos = Vector2.zero,
		}
		self._floats[id] = f
		tab.Floating = f

		local vp = self.Gui.AbsoluteSize
		place(self, f, at and Vector2.new(at.X, at.Y - 24) or Vector2.new(vp.X * 0.5 + 40 * count, 70 + 36 * count))

		grip.InputBegan:Connect(function(input)
			if isPress(input.UserInputType) then
				self:_startFloatDrag(f, input.Position, input.UserInputType == Enum.UserInputType.MouseButton1, false)
			end
		end)
		table.insert(f.Conns, UserInputService.InputChanged:Connect(function(input)
			if not f.Dragging or not isMove(input.UserInputType) then return end
			if f.FromMouse and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
				f.Dragging = false
				return
			end
			local d = Vector2.new(input.Position.X, input.Position.Y) - f.StartInput
			if d.Magnitude > CLICK_SLOP then f.Moved = true end
			if f.Moved then place(self, f, f.StartPos + d) end
		end))
		table.insert(f.Conns, UserInputService.InputEnded:Connect(function(input)
			if f.Dragging and isPress(input.UserInputType) then
				f.Dragging = false
				if not f.Moved then self:DockTab(id) end -- a plain click on the bar puts the tab back
			end
		end))

		-- a slide tween left running on the old page must not hide or shove it away
		task.delay(0.5, function()
			if not f.Alive then return end
			page.Visible, page.Position = true, UDim2.new()
			bar.Visible, bar.Position = true, UDim2.fromOffset(TITLE_W, 0)
		end)

		-- the sidebar forgets the tab; if it was the open one, another takes over
		tab.Button.SetActive(false)
		tab.Button.Holder.Visible = false
		self:_fitTabs()
		if self.CurrentTab == id then
			self.CurrentTab = nil
			local pick
			for _, t in self.Tabs do
				if not t.IsBottom and not self._floats[t.Id] and (not pick or t.Order < pick.Order) then pick = t end
			end
			if pick then self:SelectTab(pick.Id) end
		end

		if not self._floatHinted then
			self._floatHinted = true
			self:Notify("Click a detached tab's top bar to put it back", 4)
		end
		return f
	end

	function GuiUI:DockTab(id)
		local f, tab = self._floats[id], self.Tabs[id]
		if not (f and tab) then return end
		self._floats[id] = nil
		f.Alive = false
		for _, c in f.Conns do c:Disconnect() end
		self.HeaderHost:Restore(id, f.Bar)
		self.MainHost:Restore(id, f.Page)
		f.Holder:Destroy()
		tab.Floating = nil
		tab.Button.Holder.Visible = true
		tab.Button.Face.Position = UDim2.new()
		self:_fitTabs()
		self:SelectTab(id)
	end

	function GuiUI:DockAllTabs()
		for id in table.clone(self._floats) do self:DockTab(id) end
	end

	function GuiUI:DetachCurrent()
		if self.CurrentTab then return self:DetachTab(self.CurrentTab) end
	end

	-- press a sidebar tab and pull it away from the sidebar to detach it
	function GuiUI:_armDetach(tab)
		local id = tab.Id
		local pressing, fromMouse, start = false, false, Vector2.zero

		tab.Button.Face.InputBegan:Connect(function(input)
			local kind = input.UserInputType
			if isPress(kind) then
				pressing, fromMouse = true, kind == Enum.UserInputType.MouseButton1
				start = Vector2.new(input.Position.X, input.Position.Y)
			end
		end)
		table.insert(self._conns, UserInputService.InputChanged:Connect(function(input)
			if not pressing or not isMove(input.UserInputType) then return end
			if fromMouse and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
				pressing = false
				return
			end
			local p = Vector2.new(input.Position.X, input.Position.Y)
			if (p - start).Magnitude < DETACH_DISTANCE then return end
			pressing = false
			if self.LockTabs then return end
			local f = self:DetachTab(id, p + GuiService:GetGuiInset())
			if f then self:_startFloatDrag(f, p, fromMouse, true) end -- keep dragging the new window
		end))
		table.insert(self._conns, UserInputService.InputEnded:Connect(function(input)
			if isPress(input.UserInputType) then pressing = false end
		end))
	end

	local baseDestroy = GuiUI.Destroy
	function GuiUI:Destroy()
		for _, f in self._floats do
			for _, c in f.Conns do c:Disconnect() end
		end
		table.clear(self._floats)
		baseDestroy(self)
	end

end
end)(import)

return function(GuiUI)
	installDock(GuiUI)
	installBehavior(GuiUI)
	installComfort(GuiUI)
	installFloat(GuiUI)
end

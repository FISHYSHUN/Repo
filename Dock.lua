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
		self.TabList.ScrollBarThickness = hz and 0 or 3
		local p = UDim.new(0, hz and 5 or 8)
		local pad = self.TabListPad
		pad.PaddingTop, pad.PaddingBottom, pad.PaddingLeft, pad.PaddingRight = p, p, UDim.new(0, 8), UDim.new(0, 8)
		for _, tab in self.Tabs do
			if not tab.IsBottom then
				tab.Button.Holder.Size = hz and UDim2.new(0, S.TabIcon, 1, 0) or UDim2.new(1, 0, 0, S.Tab)
			end
		end
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

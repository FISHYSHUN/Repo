-- modules/Behavior.lua
-- Window behavior: toggle-key binding, open / close / minimize, notifications, customization API.
-- Returns an installer:  import("Behavior")(GuiUI)
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
		self:_slidePanel(true)
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
		duration = duration or 2.5
		self._toastCount += 1
		local holder = New("Frame", {
			Name = "Toast", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36),
			LayoutOrder = self._toastCount, Parent = self.ToastArea,
		})
		local slide = New("Frame", {
			BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Position = UDim2.fromOffset(320, 0), Parent = holder,
		})
		local _, face = Shadowed(slide, "ToastBody", "Frame", UDim2.new(), UDim2.fromScale(1, 1), "Window", 3, nil, "toast")
		-- accent bar is inset from the edges so it never pokes out of rounded corners
		local bar = New("Frame", {
			BorderSizePixel = 0, Position = UDim2.fromOffset(6, 6), Size = UDim2.new(0, 4, 1, -12), Parent = face,
		})
		New("UICorner", { CornerRadius = UDim.new(0, 2), Parent = bar })
		Bind(bar, "BackgroundColor3", "Active")
		Label(face, text, { Align = Enum.TextXAlignment.Left, TextSize = Theme.FontSize.Small, PadX = 18 })

		Anim.Tween(slide, 0.3, { Position = UDim2.new() }, Enum.EasingStyle.Back)
		task.delay(duration, function()
			if holder.Parent == nil then return end
			local out = Anim.Tween(slide, 0.25, { Position = UDim2.fromOffset(320, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			out.Completed:Once(function() holder:Destroy() end)
		end)
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

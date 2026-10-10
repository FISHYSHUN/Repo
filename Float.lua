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

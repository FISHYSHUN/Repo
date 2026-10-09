-- modules/Controls.lua
-- Control builders on a sub-tab page:
--   AddSection / AddLabel / AddButton / AddToggle / AddSlider / AddDropdown /
--   AddColorPicker / AddTextBox / AddKeybind
-- Returns an installer:  import("Controls")(Page)
local import = ...

local UserInputService = game:GetService("UserInputService")

local T = import("Theme")
local Kit = import("Toolkit")
local Theme, State = T.Theme, T.State

local New, Bind, AddCorner = Kit.New, Kit.Bind, Kit.AddCorner
local Label, Button, Shadowed, Pad = Kit.Label, Kit.Button, Kit.Shadowed, Kit.Pad
local Anim, Texts = Kit.Anim, Kit.Texts
local Sliders, Toggles = Kit.Sliders, Kit.Toggles

return function(Page)

	function Page:_order()
		self.Count += 1
		return self.Count
	end

	function Page:AddSection(text)
		local lbl = Label(self.Container, string.upper(text), {
			Size = UDim2.new(1, 0, 0, 22), Align = Enum.TextXAlignment.Left,
			TextSize = Theme.FontSize.Small, ColorKey = "Active", PadX = 4,
		})
		lbl.LayoutOrder = self:_order()
		return lbl
	end

	-- returns the TextLabel, so you can change .Text later (live stats etc.)
	function Page:AddLabel(text)
		local lbl = Label(self.Container, text, {
			Size = UDim2.new(1, 0, 0, Theme.Size.LabelH), Align = Enum.TextXAlignment.Left,
		})
		lbl.LayoutOrder = self:_order()
		return lbl
	end

	function Page:AddButton(text, callback)
		local btn = Button(self.Container, text, UDim2.new(), UDim2.new(1, 0, 0, Theme.Size.Control), text, nil, callback)
		btn.Holder.LayoutOrder = self:_order()
		return btn
	end

	-- Looks change with the style: Fill (ON/OFF button) | Check (checkbox) | Switch (pill)
	function Page:AddToggle(text, default, callback)
		local state = default or false
		local api = {}
		local btn = Button(self.Container, text, UDim2.new(), UDim2.new(1, 0, 0, Theme.Size.Control), "", nil, function()
			state = not state
			api.Refresh()
			if callback then callback(state) end
		end)
		btn.Holder.LayoutOrder = self:_order()
		local face = btn.Face
		local ind = New("Frame", { Name = "Ind", BorderSizePixel = 0, Parent = face })
		local indCorner = New("UICorner", { Parent = ind })
		local indStroke = New("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = ind })
		local dot = New("Frame", { Name = "Dot", AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, Parent = ind })
		local dotCorner = New("UICorner", { Parent = dot })

		function api.Refresh()
			local mode = State.Skin.Toggle
			if mode == "Fill" then
				btn.SetText(text .. ": " .. (state and "ON" or "OFF"))
				btn.SetActive(state)
				ind.Visible = false
				face.TextXAlignment = Enum.TextXAlignment.Center
				btn.Pad.PaddingLeft, btn.Pad.PaddingRight = UDim.new(0, 4), UDim.new(0, 4)
				return
			end
			btn.SetText(text)
			btn.SetActive(false)
			face.TextXAlignment = Enum.TextXAlignment.Left
			ind.Visible = true
			indStroke.Color = Theme.Edge
			if mode == "Check" then
				ind.AnchorPoint = Vector2.new(0, 0.5)
				ind.Position = UDim2.new(0, 10, 0.5, 0)
				ind.Size = UDim2.fromOffset(16, 16)
				ind.BackgroundColor3 = Theme.Content
				indCorner.CornerRadius = UDim.new(0, math.floor(Theme.Corner * 0.3 + 0.5))
				dot.Size = UDim2.fromOffset(8, 8)
				dot.Position = UDim2.fromScale(0.5, 0.5)
				dot.BackgroundColor3 = Theme.Active
				dot.BackgroundTransparency = state and 0 or 1
				dotCorner.CornerRadius = UDim.new(0, math.floor(Theme.Corner * 0.15 + 0.5))
				btn.Pad.PaddingLeft, btn.Pad.PaddingRight = UDim.new(0, 34), UDim.new(0, 4)
			else -- Switch
				ind.AnchorPoint = Vector2.new(1, 0.5)
				ind.Position = UDim2.new(1, -10, 0.5, 0)
				ind.Size = UDim2.fromOffset(38, 20)
				ind.BackgroundColor3 = state and Theme.Active or Theme.Track
				indCorner.CornerRadius = UDim.new(0, 10)
				dot.Size = UDim2.fromOffset(14, 14)
				dot.BackgroundColor3 = Theme.Knob
				dot.BackgroundTransparency = 0
				dotCorner.CornerRadius = UDim.new(0, 7)
				Anim.Tween(dot, 0.12, { Position = UDim2.new(state and 1 or 0, state and -10 or 10, 0.5, 0) })
				btn.Pad.PaddingLeft, btn.Pad.PaddingRight = UDim.new(0, 10), UDim.new(0, 56)
			end
		end
		api.Face = face
		function api.Set(v) state = v; api.Refresh() end
		function api.Get() return state end
		table.insert(Toggles, api)
		api.Refresh()
		return api
	end

	function Page:AddSlider(text, min, max, default, callback)
		local holder = New("Frame", {
			Name = text, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, Theme.Size.SliderH),
			LayoutOrder = self:_order(), Parent = self.Container,
		})
		local label = Label(holder, "", { Size = UDim2.new(1, 0, 0, 24), Align = Enum.TextXAlignment.Left, PadX = 4 })
		local track = New("Frame", { BackgroundTransparency = 0.2, BorderSizePixel = 0, Parent = holder })
		Bind(track, "BackgroundColor3", "Track")
		local trackCorner = New("UICorner", { Parent = track })
		local trackStroke = New("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = track })
		local fill = New("Frame", { BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = track })
		Bind(fill, "BackgroundColor3", "Active")
		local fillCorner = New("UICorner", { Parent = fill })
		local knob = New("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, ZIndex = 2, Parent = track })
		Bind(knob, "BackgroundColor3", "Knob")
		local knobCorner = New("UICorner", { Parent = knob })
		local knobStroke = New("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = knob })

		local function restyle()
			local sl = State.Skin.Slider
			local h = sl.H
			track.Position = UDim2.new(0, 4, 0, 37 - h // 2)
			track.Size = UDim2.new(1, -8, 0, h)
			local r = sl.Pill and h or math.min(math.floor(Theme.Corner * 0.5 + 0.5), h // 2)
			trackCorner.CornerRadius = UDim.new(0, r)
			fillCorner.CornerRadius = UDim.new(0, r)
			trackStroke.Enabled = sl.Stroke == true
			trackStroke.Color = Theme.Edge
			knob.Visible = sl.KW ~= nil
			if sl.KW then
				knob.Size = UDim2.fromOffset(sl.KW, sl.KH)
				knobCorner.CornerRadius = UDim.new(0, sl.KRound and 99 or math.min(math.floor(Theme.Corner * 0.4 + 0.5), 4))
				knobStroke.Color = Theme.Edge
			end
		end
		table.insert(Sliders, { Track = track, Restyle = restyle })
		restyle()

		local value = default
		local function set(v, fire)
			v = math.clamp(math.round(v), min, max)
			value = v
			label.Text = text .. ": " .. v
			local frac = (v - min) / (max - min)
			Anim.Tween(fill, 0.05, { Size = UDim2.fromScale(frac, 1) })
			Anim.Tween(knob, 0.05, { Position = UDim2.new(frac, 0, 0.5, 0) })
			if fire and callback then callback(v) end
		end
		local function fromX(x)
			local t = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
			set(min + (max - min) * t, true)
		end

		local dragging = false
		local function down(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				fromX(input.Position.X)
			end
		end
		track.InputBegan:Connect(down)
		knob.InputBegan:Connect(down)
		UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				fromX(input.Position.X)
			end
		end)
		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)

		set(default, false)
		local api = {}
		function api.Set(v) set(v, false) end
		function api.Get() return value end
		return api
	end

	-- Click to cycle through the options
	function Page:AddDropdown(text, options, default, callback)
		local index = table.find(options, default) or 1
		local btn
		local function refresh() btn.SetText(text .. ": " .. tostring(options[index])) end
		btn = Button(self.Container, text, UDim2.new(), UDim2.new(1, 0, 0, Theme.Size.Control), "", nil, function()
			index = index % #options + 1
			refresh()
			if callback then callback(options[index]) end
		end)
		btn.Holder.LayoutOrder = self:_order()
		refresh()
		local api = {}
		function api.Set(v) index = table.find(options, v) or index; refresh() end
		function api.Get() return options[index] end
		return api
	end

	-- Three RGB sliders + a live preview swatch
	function Page:AddColorPicker(text, default, callback)
		local r, g, b = math.round(default.R * 255), math.round(default.G * 255), math.round(default.B * 255)
		local color = default

		local row = New("Frame", {
			Name = text, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, Theme.Size.LabelH),
			LayoutOrder = self:_order(), Parent = self.Container,
		})
		Label(row, text, { Size = UDim2.new(1, -56, 1, 0), Align = Enum.TextXAlignment.Left, PadX = 4 })
		local swatch = New("Frame", {
			BorderSizePixel = 0, BackgroundColor3 = default, AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -4, 0.5, 0), Size = UDim2.fromOffset(44, 20), Parent = row,
		})
		AddCorner(swatch, 0.4, 10)

		local function changed()
			color = Color3.fromRGB(r, g, b)
			swatch.BackgroundColor3 = color
			if callback then callback(color) end
		end
		local sr = self:AddSlider("Red", 0, 255, r, function(v) r = v; changed() end)
		local sg = self:AddSlider("Green", 0, 255, g, function(v) g = v; changed() end)
		local sb = self:AddSlider("Blue", 0, 255, b, function(v) b = v; changed() end)

		local api = {}
		function api.Set(c)
			r, g, b = math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255)
			color = c
			swatch.BackgroundColor3 = c
			sr.Set(r); sg.Set(g); sb.Set(b)
		end
		function api.Get() return color end
		return api
	end

	-- Label on the left, editable text on the right; the callback fires when the box loses focus
	function Page:AddTextBox(text, default, callback)
		local holder, face = Shadowed(self.Container, text, "Frame", UDim2.new(), UDim2.new(1, 0, 0, Theme.Size.Control), "Field", 3, nil, "field")
		holder.LayoutOrder = self:_order()
		Label(face, text, { Size = UDim2.fromScale(0.4, 1), Align = Enum.TextXAlignment.Left })
		local box = New("TextBox", {
			BackgroundTransparency = 1, ClearTextOnFocus = false, Text = default or "", Font = Theme.Font,
			TextSize = Theme.FontSize.Small, TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Right, PlaceholderText = "type here...",
			Position = UDim2.fromScale(0.4, 0), Size = UDim2.fromScale(0.6, 1), Parent = face,
		})
		Bind(box, "TextColor3", "Text")
		table.insert(Texts, box)
		Pad(box, 8)
		box.FocusLost:Connect(function()
			if callback then callback(box.Text) end
		end)
		local api = {}
		function api.Set(v) box.Text = v end
		function api.Get() return box.Text end
		return api
	end

	-- Click the button, then press a key. Escape cancels, Backspace clears the bind.
	function Page:AddKeybind(text, default, callback)
		local ui = self.UI
		local key = default
		local listening = false
		local btn

		local function refresh()
			local shown = listening and "press a key..." or (key and key.Name or "None")
			btn.SetText(text .. ": " .. shown)
			btn.SetActive(listening)
		end
		btn = Button(self.Container, text, UDim2.new(), UDim2.new(1, 0, 0, Theme.Size.Control), "", nil, function()
			listening = not listening
			ui._capturing = listening
			refresh()
		end)
		btn.Holder.LayoutOrder = self:_order()

		UserInputService.InputBegan:Connect(function(input)
			if not listening or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
			listening = false
			ui._capturing = false
			ui._swallow = true
			task.defer(function() ui._swallow = false end)
			if input.KeyCode == Enum.KeyCode.Backspace then
				key = nil
			elseif input.KeyCode ~= Enum.KeyCode.Escape then
				key = input.KeyCode
			end
			refresh()
			if callback then callback(key) end
		end)

		refresh()
		local api = {}
		function api.Get() return key end
		function api.Set(k) key = k; refresh() end
		return api
	end

end

-- modules/Toolkit.lua
-- Low-level GUI helpers: instance factory, theme registries (ApplyAll), animations,
-- and the reusable building blocks (Shadowed panel, Label, Button, drag handle, page host).
local import = ...

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local T = import("Theme")
local Theme, State = T.Theme, T.State
local WHITE = Color3.new(1, 1, 1)

-------------------------------------------------------------------------------
-- HELPERS + REGISTRIES
-------------------------------------------------------------------------------
local function New(class, props)
	local inst = Instance.new(class)
	local parent = props.Parent
	for k, v in props do
		if k ~= "Parent" then inst[k] = v end
	end
	inst.Parent = parent
	return inst
end

local Bound, Buttons, Corners, Texts = {}, {}, {}, {}
local Surfaces, Insets, Sliders, Toggles = {}, {}, {}, {}

local function Bind(inst, prop, key)
	inst[prop] = Theme[key]
	table.insert(Bound, { inst, prop, key })
end

-- small free-standing rounded things (swatch ...): radius = Theme.Corner * mul, capped
local function AddCorner(inst, mul, cap)
	local c = New("UICorner", { Parent = inst })
	table.insert(Corners, { c, mul or 1, cap })
	c.CornerRadius = UDim.new(0, math.min(math.floor(Theme.Corner * (mul or 1) + 0.5), cap or 99))
	return c
end

-- children of a rounded panel are inset a little so their square corners never poke out
local function applyInset(f)
	local m = math.ceil(Theme.Corner * 0.35)
	f.Position = UDim2.fromOffset(m, m)
	f.Size = UDim2.new(1, -2 * m, 1, -2 * m)
end

local Fallback = {
	side = "panel", content = "panel", header = "panel", footer = "panel", tabname = "panel", toast = "panel",
	tab = "btn", sub = "btn", bottom = "btn", sys = "btn", tfield = "field",
}
local EMPTY = {}
local function kindDef(kind)
	local K = State.Skin.Kinds
	return K[kind] or K[Fallback[kind] or "panel"] or EMPTY
end

-- (re)applies the active style to one panel: depth strip, corners, border, gradient, transparency
local function skinSurface(s)
	local kd = kindDef(s.Kind)
	local face, shadow = s.Face, s.Shadow

	if kd.Clear then
		s.Cur = 0
		shadow.Visible = false
		face.Size = UDim2.fromScale(1, 1)
		face.BackgroundTransparency = 1
	else
		local depth = kd.Depth or s.Depth
		s.Cur = depth
		if depth > 0 then
			-- the strip is the shadow shifted DOWN, so its top corners can never show through the face's corners
			shadow.Visible = true
			shadow.Position = UDim2.fromOffset(0, depth)
			shadow.Size = UDim2.new(1, 0, 1, -depth)
			face.Size = UDim2.new(1, 0, 1, -depth)
		else
			shadow.Visible = false
			face.Size = UDim2.fromScale(1, 1)
		end
		face.BackgroundTransparency = Theme.PanelTransparency
		shadow.BackgroundTransparency = T.shadowTransparency()
	end

	local r = kd.Radius or math.floor(Theme.Corner * (kd.Mul or 1) + 0.5)
	s.FaceCorner.CornerRadius = UDim.new(0, r)
	s.ShadowCorner.CornerRadius = UDim.new(0, r)

	if not kd.Clear and (kd.Stroke or 0) > 0 then
		if not s.StrokeObj then
			s.StrokeObj = New("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = face })
		end
		s.StrokeObj.Enabled = true
		s.StrokeObj.Thickness = kd.Stroke
		s.StrokeObj.Color = Theme[kd.StrokeKey or "Border"]
	elseif s.StrokeObj then
		s.StrokeObj.Enabled = false
	end

	local grad = (not kd.Clear) and kd.Grad
	if not kd.Clear and (grad or kd.Sheen or kd.Gloss) then
		if not s.Gradient then s.Gradient = New("UIGradient", { Rotation = 90, Parent = face }) end
		local g = s.Gradient
		g.Enabled = true
		if grad then
			g.Color = ColorSequence.new(Theme[grad[1]], Theme[grad[2]])
		elseif kd.Gloss then
			local k = 1 - kd.Gloss
			local dark = Color3.new(k, k, k)
			g.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, WHITE), ColorSequenceKeypoint.new(0.5, WHITE),
				ColorSequenceKeypoint.new(0.51, dark), ColorSequenceKeypoint.new(1, dark),
			})
		else
			local k = 1 - kd.Sheen
			g.Color = ColorSequence.new(WHITE, Color3.new(k, k, k))
		end
	elseif s.Gradient then
		s.Gradient.Enabled = false
	end

	if not s.Button then face.BackgroundColor3 = grad and WHITE or Theme[s.Key] end
end

local function ApplyAll()
	for i = #Surfaces, 1, -1 do
		local s = Surfaces[i]
		if s.Holder.Parent == nil then table.remove(Surfaces, i) else skinSurface(s) end
	end
	for i = #Bound, 1, -1 do
		local b = Bound[i]
		if b[1].Parent == nil then table.remove(Bound, i) else b[1][b[2]] = Theme[b[3]] end
	end
	for i = #Buttons, 1, -1 do
		local api = Buttons[i]
		if api.Face.Parent == nil then table.remove(Buttons, i) else api.Retheme() end
	end
	for i = #Corners, 1, -1 do
		local c = Corners[i]
		if c[1].Parent == nil then table.remove(Corners, i)
		else c[1].CornerRadius = UDim.new(0, math.min(math.floor(Theme.Corner * c[2] + 0.5), c[3] or 99)) end
	end
	for i = #Texts, 1, -1 do
		local t = Texts[i]
		if t.Parent == nil then table.remove(Texts, i) else t.Font = Theme.Font end
	end
	for i = #Insets, 1, -1 do
		local f = Insets[i]
		if f.Parent == nil then table.remove(Insets, i) else applyInset(f) end
	end
	for i = #Sliders, 1, -1 do
		local s = Sliders[i]
		if s.Track.Parent == nil then table.remove(Sliders, i) else s.Restyle() end
	end
	for i = #Toggles, 1, -1 do
		local t = Toggles[i]
		if t.Face.Parent == nil then table.remove(Toggles, i) else t.Refresh() end
	end
end

-------------------------------------------------------------------------------
-- ANIMATIONS
-------------------------------------------------------------------------------
local Anim = {}

function Anim.Tween(inst, duration, props, style, direction)
	local tween = TweenService:Create(inst,
		TweenInfo.new(duration / Theme.AnimSpeed, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	tween:Play()
	return tween
end

function Anim.ToColor(inst, color) return Anim.Tween(inst, 0.12, { BackgroundColor3 = color }) end
function Anim.Press(face, color, off)
	Anim.Tween(face, 0.06, { Position = UDim2.fromOffset(0, off or 2), BackgroundColor3 = color })
end
function Anim.Release(face)
	Anim.Tween(face, 0.12, { Position = UDim2.new() }, Enum.EasingStyle.Back)
end

function Anim.Slide(page, position, onDone)
	local tween = Anim.Tween(page, 0.38, { Position = position }, Enum.EasingStyle.Quint)
	tween.Completed:Once(function(state)
		if state == Enum.PlaybackState.Completed and onDone then onDone() end
	end)
end

function Anim.SetScale(scale, value)
	return Anim.Tween(scale, 0.25, { Scale = value }, Enum.EasingStyle.Quint)
end

-------------------------------------------------------------------------------
-- BUILDING BLOCKS
-------------------------------------------------------------------------------
-- panel with an optional 3D strip underneath; returns holder, face, surface
local function Shadowed(parent, name, class, position, size, colorKey, depth, anchor, kind)
	depth = depth or Theme.Depth
	local holder = New("Frame", {
		Name = name, BackgroundTransparency = 1, AnchorPoint = anchor or Vector2.zero,
		Position = position, Size = size, Parent = parent,
	})
	local shadow = New("Frame", { Name = "Shadow", BorderSizePixel = 0, Parent = holder })
	local face = New(class or "Frame", { Name = "Face", BorderSizePixel = 0, Parent = holder })
	local s = {
		Holder = holder, Shadow = shadow, Face = face, Kind = kind or "panel", Key = colorKey,
		Depth = depth, Cur = depth,
		FaceCorner = New("UICorner", { Parent = face }), ShadowCorner = New("UICorner", { Parent = shadow }),
	}
	Bind(shadow, "BackgroundColor3", "WindowShadow")
	table.insert(Surfaces, s)
	skinSurface(s)
	return holder, face, s
end

local function Pad(obj, x)
	return New("UIPadding", { PaddingLeft = UDim.new(0, x or 6), PaddingRight = UDim.new(0, x or 6), Parent = obj })
end

-- Fixed-size text. opts: TextSize, Position, Size, ColorKey, Align, PadX
local function Label(parent, text, opts)
	opts = opts or {}
	local label = New("TextLabel", {
		Name = "Label", BackgroundTransparency = 1, Text = text, Font = Theme.Font,
		TextSize = opts.TextSize or Theme.FontSize.Label,
		Position = opts.Position or UDim2.new(), Size = opts.Size or UDim2.fromScale(1, 1),
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = opts.Align or Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center, Parent = parent,
	})
	Bind(label, "TextColor3", opts.ColorKey or "Text")
	table.insert(Texts, label)
	Pad(label, opts.PadX or 8)
	return label
end

local function Bar(parent, w, h, rotation, key)
	local f = New("Frame", {
		BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(w, h),
		Rotation = rotation or 0, Parent = parent,
	})
	Bind(f, "BackgroundColor3", key)
	return f
end

local function Icon(parent, kind, key)
	if kind == "minus" then
		return { Bar(parent, 12, 2, 0, key) }
	elseif kind == "plus" then
		return { Bar(parent, 12, 2, 0, key), Bar(parent, 2, 12, 0, key) }
	elseif kind == "cross" then
		return { Bar(parent, 15, 2, 45, key), Bar(parent, 15, 2, -45, key) }
	end
	return {}
end

-- Button with hover / press / active states.
-- opts: Color / HoverColor / PressColor (THEME KEYS), Depth, TextSize, Anchor, Kind,
--       Glyph ("minus" | "plus" | "cross"), GlyphColor (theme key)
local function Button(parent, name, position, size, text, opts, onClick)
	opts = opts or {}
	local keys = {
		Base = opts.Color or "Tab", Hover = opts.HoverColor or "TabHover", Press = opts.PressColor or "TabPress",
	}
	local state = { Active = false, Hovering = false }

	local holder, face, surf = Shadowed(parent, name, "TextButton", position, size, keys.Base, opts.Depth, opts.Anchor, opts.Kind or "btn")
	surf.Button = true
	face.AutoButtonColor = false
	face.Text = text or ""
	face.Font = Theme.Font
	face.TextSize = opts.TextSize or Theme.FontSize.Button
	face.TextTruncate = Enum.TextTruncate.AtEnd
	table.insert(Texts, face)
	local pad = Pad(face, 4)
	local glyphs = opts.Glyph and Icon(face, opts.Glyph, opts.GlyphColor or "Text") or {}

	local function rest() return state.Active and Theme.Active or Theme[keys.Base] end
	local function textRest() return state.Active and Theme.TextOnActive or Theme.Text end
	local function off() return surf.Cur > 0 and 2 or 0 end
	face.BackgroundColor3 = rest()
	face.TextColor3 = textRest()

	face.MouseEnter:Connect(function()
		state.Hovering = true
		Anim.ToColor(face, state.Active and Theme.Active or Theme[keys.Hover])
	end)
	face.MouseLeave:Connect(function()
		state.Hovering = false
		Anim.Release(face)
		Anim.ToColor(face, rest())
	end)
	face.MouseButton1Down:Connect(function() Anim.Press(face, Theme[keys.Press], off()) end)
	face.MouseButton1Up:Connect(function()
		Anim.Release(face)
		Anim.ToColor(face, (state.Hovering and not state.Active) and Theme[keys.Hover] or rest())
	end)
	face.MouseButton1Click:Connect(function() if onClick then onClick() end end)

	local api = { Holder = holder, Face = face, Pad = pad, Glyphs = glyphs }
	function api.SetActive(v)
		state.Active = v
		Anim.ToColor(face, rest())
		Anim.Tween(face, 0.12, { TextColor3 = textRest() })
	end
	function api.SetText(t) face.Text = t end
	function api.Retheme()
		face.BackgroundColor3 = rest()
		face.TextColor3 = textRest()
	end
	table.insert(Buttons, api)
	return api
end

-- Drags the dock along its edge only: up/down on Left/Right, left/right on Top.
-- state.Moved becomes true once the pointer travelled > 4px
local function MakeDrag(handle, ui)
	local state = { Moved = false }
	local dragging, fromMouse, startPos, startOff = false, false, 0, 0
	local function axis(input)
		return ui.DockSide == "Top" and input.Position.X or input.Position.Y
	end
	local function stop() dragging = false end

	handle.InputBegan:Connect(function(input)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
			state.Moved = false
			if not ui.Draggable then return end
			dragging, fromMouse, startPos, startOff = true, kind == Enum.UserInputType.MouseButton1, axis(input), ui.Offset
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then stop() end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseMovement or kind == Enum.UserInputType.Touch then
			-- a release outside the window is never reported: if the button is already up, the drag is over
			if fromMouse and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
				stop()
				return
			end
			local d = axis(input) - startPos
			if math.abs(d) > 4 then state.Moved = true end
			ui:_setOffset(startOff + d)
		end
	end)
	-- belt and braces: any release anywhere ends the drag
	UserInputService.InputEnded:Connect(function(input)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then stop() end
	end)
	return state
end

-- PageHost: clipped area that holds several pages and slides between them.
local function NewHost(parent)
	local host = { Pages = {}, Current = nil }
	host.Frame = New("Frame", {
		Name = "Host", BackgroundTransparency = 1, ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1), Parent = parent,
	})
	table.insert(Insets, host.Frame)
	applyInset(host.Frame)

	function host:Add(key)
		local page = New("Frame", {
			Name = key, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
			Visible = false, Parent = self.Frame,
		})
		self.Pages[key] = page
		return page
	end

	function host:Show(key, dir)
		local new = self.Pages[key]
		if not new or new == self.Current then return end
		local old = self.Current
		self.Current = new

		for _, p in self.Pages do
			if p ~= new and p ~= old then p.Visible = false end
		end
		if not old then
			new.Position = UDim2.new()
			new.Visible = true
			return
		end

		dir = dir or 1
		if not new.Visible then
			new.Position = UDim2.fromScale(dir, 0)
			new.Visible = true
		end
		Anim.Slide(new, UDim2.new())
		Anim.Slide(old, UDim2.fromScale(-dir, 0), function()
			if self.Current ~= old then old.Visible = false end
		end)
	end

	-- takes a page out of the host (for a detached window) and hands it back later
	function host:Remove(key)
		local page = self.Pages[key]
		if not page then return nil end
		self.Pages[key] = nil
		if self.Current == page then self.Current = nil end
		return page
	end

	function host:Restore(key, page)
		page.Parent = self.Frame
		page.Position = UDim2.new()
		page.Size = UDim2.fromScale(1, 1)
		page.Visible = false
		self.Pages[key] = page
	end

	return host
end

local function fieldOpts(extra)
	local o = { Color = "Field", HoverColor = "FieldHover", PressColor = "FieldPress" }
	for k, v in extra or {} do o[k] = v end
	return o
end

return {
	New = New, Bind = Bind, AddCorner = AddCorner, applyInset = applyInset,
	ApplyAll = ApplyAll, Anim = Anim, Shadowed = Shadowed, Pad = Pad, Label = Label,
	Button = Button, MakeDrag = MakeDrag, NewHost = NewHost, fieldOpts = fieldOpts,
	Texts = Texts, Insets = Insets, Sliders = Sliders, Toggles = Toggles,
}

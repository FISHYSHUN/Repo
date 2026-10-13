-- modules/PlayerSelect.lua
-- Hover a player      -> soft outline on their character.
-- Click them twice    -> a billboard menu pops out to the RIGHT of their head. The buttons spring in one
--                        after the other (Back easing = a slight bounce).
-- Buttons             -> Fling, Spectate, Teleport To, Head Sit, Orbit, Shadow.
-- Click empty space (or the x) closes it. Jumping stops Head Sit / Orbit / Shadow.
--
-- Client side only: other players see your character move, the server may still override it.
-- PlayerSelect.new(mods)  -- mods (PlayerMods) is optional, it is used for Spectate + Teleport so they go
--                            through your existing camera handling and teleport undo.
local import = ...

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")

local Theme = import("Theme").Theme
local LocalPlayer = Players.LocalPlayer

-- layout (px, the billboard keeps a constant on-screen size)
local WIDTH, ROW_H, GAP, HEADER_H, TAIL = 176, 34, 6, 44, 22
local CLICK_SLOP = 10 -- a press that moves more than this is a camera drag, not a click

-- fling tuning (a huge spin + velocity while sitting inside the target)
local FLING_LIN, FLING_ANG = 3e4, 6e4

local BACK = Enum.EasingStyle.Back
local QUAD = Enum.EasingStyle.Quad

local ACTIONS = {
	{ Id = "Fling", Label = "Fling", Stop = "Stop Fling" },
	{ Id = "Spectate", Label = "Spectate", Stop = "Stop Spectating" },
	{ Id = "Teleport", Label = "Teleport To", Stop = "Teleport To" },
	{ Id = "Headsit", Label = "Head Sit", Stop = "Stop Head Sit" },
	{ Id = "Orbit", Label = "Orbit", Stop = "Stop Orbit" },
	{ Id = "Shadow", Label = "Shadow", Stop = "Stop Shadow" },
}

-- helpers ------------------------------------------------------------------------------------
local function New(class, props, parent)
	local inst = Instance.new(class)
	for k, v in props do inst[k] = v end
	inst.Parent = parent
	return inst
end

local function tween(inst, time, props, style, dir)
	local t = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local function palette()
	return {
		Panel = Theme.Window or Color3.fromRGB(22, 22, 26),
		Field = Theme.Field or Color3.fromRGB(40, 40, 47),
		Hover = Theme.FieldHover or Color3.fromRGB(58, 58, 68),
		Text = Theme.Text or Color3.fromRGB(235, 235, 240),
		Accent = Theme.Active or Color3.fromRGB(53, 132, 228),
		OnAccent = Theme.TextOnActive or Color3.new(1, 1, 1),
		Border = Theme.Border or Color3.fromRGB(80, 80, 90),
		Close = Theme.Close or Color3.fromRGB(255, 80, 80),
		Font = Theme.Font or Enum.Font.GothamBold,
		Edge = Theme.Edge or Theme.Border or Color3.fromRGB(88, 95, 102),
		Shadow = Theme.WindowShadow or Color3.fromRGB(6, 6, 8),
		Alpha = math.clamp(Theme.PanelTransparency or 0, 0, 0.7),
		HeadRadius = UDim.new(0, math.floor((Theme.Corner or 8) * 0.8 + 0.5)),
		Radius = UDim.new(0, math.floor((Theme.Corner or 8) * 0.7 + 0.5)),
	}
end

-- humanoid, root, character of a player (any of them can be nil)
local function parts(player)
	local char = player and player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and (char:FindFirstChild("HumanoidRootPart") or (hum and hum.RootPart))
	return hum, root, char
end

-- walk-through-everything while an action runs; returns a function that puts collisions back
local function ghost(char)
	local changed = {}
	local conn = RunService.Stepped:Connect(function()
		for _, part in char:GetDescendants() do
			if part:IsA("BasePart") and part.CanCollide then
				changed[part] = true
				part.CanCollide = false
			end
		end
	end)
	return function()
		conn:Disconnect()
		for part in changed do
			if part.Parent then part.CanCollide = true end
		end
	end
end

-- zero our momentum for a few frames (optionally back to a CFrame) so an action never launches us
local function settle(cf)
	task.spawn(function()
		for _ = 1, 12 do
			local _, root = parts(LocalPlayer)
			if root then
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
				if cf then root.CFrame = cf end
			end
			RunService.Heartbeat:Wait()
		end
	end)
end

local PlayerSelect = {}
PlayerSelect.__index = PlayerSelect

function PlayerSelect.new(mods)
	local self = setmetatable({}, PlayerSelect)
	self.Mods = mods
	self.Enabled = false
	self.Settings = {
		Hover = true,
		ClickWindow = 0.6, -- seconds between the two clicks
		FlingTime = 2.5,
		OrbitRadius = 8,
		OrbitSpeed = 3, -- radians per second
		ShadowDistance = 3.5,
	}
	self.Notify = function() end -- function(text)
	self.OnMove = nil -- function() called before we move the character (guard exemption)

	self._conns = {}
	self._down = {}
	self._armed = nil -- { Player, Time } after the first click
	self._popup = nil
	self._hoverP = nil
	self._task = nil
	self._over = 0 -- how many menu buttons the cursor is over
	self._acc = 0
	self._specFallback = nil

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	self._holder = New("Folder", { Name = "PlayerSelect" }, playerGui)

	local function highlight()
		return New("Highlight", {
			DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
			FillTransparency = 1, OutlineTransparency = 1,
		}, self._holder)
	end
	self._hoverHL, self._selHL = highlight(), highlight()

	self._params = RaycastParams.new()
	self._params.FilterType = Enum.RaycastFilterType.Exclude
	return self
end

-- picking ------------------------------------------------------------------------------------
-- viewport point -> the other player under it (nil = none). Walls block the pick on purpose.
function PlayerSelect:_pick(point)
	local cam = Workspace.CurrentCamera
	if not cam then return nil end
	point = point or UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(point.X, point.Y)

	local ignore = { self._holder }
	if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
	self._params.FilterDescendantsInstances = ignore

	local hit = Workspace:Raycast(ray.Origin, ray.Direction * 2000, self._params)
	local inst = hit and hit.Instance
	while inst and inst ~= Workspace do
		local p = Players:GetPlayerFromCharacter(inst)
		if p and p ~= LocalPlayer then return p end
		inst = inst.Parent
	end
	return nil
end

-- outlines -----------------------------------------------------------------------------------
function PlayerSelect:_paintHover(fast)
	local hl, p = self._hoverHL, self._hoverP
	local sel = self._popup and self._popup.Player
	local char = p and p.Character
	if char and p ~= sel then
		local c = palette()
		local armed = self._armed ~= nil and self._armed.Player == p
		local col = armed and c.Accent or c.Text
		hl.Adornee = char
		hl.FillColor, hl.OutlineColor = col, col
		tween(hl, fast and 0.08 or 0.15, { FillTransparency = armed and 0.6 or 0.85, OutlineTransparency = armed and 0 or 0.25 })
	else
		tween(hl, 0.15, { FillTransparency = 1, OutlineTransparency = 1 })
	end
end

function PlayerSelect:_paintSelected(fast)
	local hl, popup = self._selHL, self._popup
	local char = popup and popup.Player.Character
	if char then
		local c = palette()
		hl.Adornee = char
		hl.FillColor, hl.OutlineColor = c.Accent, c.Accent
		tween(hl, 0.25, { FillTransparency = 0.7, OutlineTransparency = 0 })
	else
		tween(hl, fast and 0.08 or 0.2, { FillTransparency = 1, OutlineTransparency = 1 })
	end
	self:_paintHover(fast)
end

function PlayerSelect:_setHover(p)
	if p == self._hoverP then return end
	self._hoverP = p
	self:_paintHover()
end

-- clicks ---------------------------------------------------------------------------------------
function PlayerSelect:_onClick(point)
	local p = self:_pick(point)
	local now = os.clock()
	if p then
		local armed = self._armed
		if armed and armed.Player == p and now - armed.Time <= self.Settings.ClickWindow then
			self._armed = nil
			self:Open(p)
		else
			local mark = { Player = p, Time = now }
			self._armed = mark
			self._hoverP = p
			self:_paintHover()
			-- the "one more click" tint fades if the second click never comes
			task.delay(self.Settings.ClickWindow + 0.02, function()
				if self._armed == mark then
					self._armed = nil
					self:_paintHover()
				end
			end)
		end
	else
		self._armed = nil
		if self._popup then self:Close() else self:_paintHover() end
	end
end

-- the menu --------------------------------------------------------------------------------------
function PlayerSelect:Open(player)
	if not self.Enabled then return end
	self:Close(true)

	local char = player and player.Character
	local anchor = char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
	if not anchor then
		self.Notify("They have no character")
		return
	end

	local c = palette()
	local n = #ACTIONS
	local panelH = HEADER_H + GAP + n * (ROW_H + GAP) - GAP

	-- the billboard is centered on the head; the panel starts TAIL px to the right of that centre
	local gui = New("BillboardGui", {
		Name = "PlayerSelectMenu", Adornee = anchor, AlwaysOnTop = true, Active = true, LightInfluence = 0,
		Size = UDim2.fromOffset(2 * (WIDTH + TAIL + 16), panelH + 24),
		StudsOffset = Vector3.new(1.3, 0.2, 0),
	}, self._holder)

	local panel = New("Frame", {
		Name = "Panel", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0.5, TAIL, 0.5, 0), Size = UDim2.fromOffset(WIDTH, panelH),
	}, gui)

	local popup = { Gui = gui, Player = player, Adornee = anchor, Rows = {} }
	self._popup = popup

	-- connector from the head to the panel: dot + line that grow first
	local headY = HEADER_H / 2 - panelH / 2
	local line = New("Frame", {
		Name = "Line", BackgroundColor3 = c.Accent, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, headY), Size = UDim2.fromOffset(0, 2),
	}, gui)
	local dot = New("Frame", {
		Name = "Dot", BackgroundColor3 = c.Accent, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, headY), Size = UDim2.fromOffset(0, 0),
	}, gui)
	New("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
	popup.Line, popup.Dot = line, dot

	-- header --------------------------------------------------------------------------------
	local header = New("CanvasGroup", {
		Name = "Header", BackgroundColor3 = c.Panel, BackgroundTransparency = c.Alpha, BorderSizePixel = 0, GroupTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(0, HEADER_H / 2),
		Size = UDim2.new(1, 0, 0, HEADER_H),
	}, panel)
	New("UICorner", { CornerRadius = c.HeadRadius }, header)
	New("UIStroke", { Color = c.Edge, Transparency = 0.2, Thickness = 1 }, header)
	local headScale = New("UIScale", { Scale = 0.6 }, header)
	New("Frame", { -- accent bar along the bottom edge
		Name = "Bar", BackgroundColor3 = c.Accent, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 3),
	}, header)
	New("TextLabel", {
		Name = "Name", BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 5), Size = UDim2.new(1, -50, 0, 20),
		Text = player.DisplayName, TextColor3 = c.Text, Font = c.Font, TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
	}, header)
	New("TextLabel", {
		Name = "User", BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 23), Size = UDim2.new(1, -50, 0, 16),
		Text = "@" .. player.Name, TextColor3 = c.Text, TextTransparency = 0.45, Font = c.Font, TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
	}, header)
	local closeBtn = New("TextButton", {
		Name = "Close", BackgroundTransparency = 1, AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, -1), Size = UDim2.fromOffset(26, 26),
		Text = "X", TextColor3 = c.Text, TextTransparency = 0.3, Font = c.Font, TextSize = 15,
	}, header)
	closeBtn.MouseEnter:Connect(function()
		self._over += 1
		tween(closeBtn, 0.15, { TextColor3 = c.Close, TextTransparency = 0 })
	end)
	closeBtn.MouseLeave:Connect(function()
		self._over = math.max(0, self._over - 1)
		tween(closeBtn, 0.15, { TextColor3 = c.Text, TextTransparency = 0.3 })
	end)
	closeBtn.Activated:Connect(function() self:Close() end)
	popup.Header, popup.HeadScale = header, headScale

	-- rows ------------------------------------------------------------------------------------
	for i, action in ACTIONS do
		local centerY = HEADER_H + GAP + (i - 1) * (ROW_H + GAP) + ROW_H / 2
		local rest = UDim2.fromOffset(0, centerY)

		local row = New("CanvasGroup", {
			Name = action.Id, BackgroundColor3 = c.Field, BackgroundTransparency = c.Alpha, BorderSizePixel = 0, GroupTransparency = 1,
			AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(-24, centerY), -- starts slid toward the head
			Size = UDim2.new(1, 0, 0, ROW_H),
		}, panel)
		New("UICorner", { CornerRadius = c.Radius }, row)
		New("UIStroke", { Color = c.Border, Transparency = 0.2, Thickness = 1 }, row)
		local scale = New("UIScale", { Scale = 0.65 }, row)

		local label = New("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -20, 1, 0),
			Text = action.Label, TextColor3 = c.Text, Font = c.Font, TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd,
		}, row)
		local button = New("TextButton", {
			BackgroundTransparency = 1, AutoButtonColor = false, Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 5,
		}, row)

		local entry = {
			Action = action, Row = row, Scale = scale, Label = label,
			Rest = rest, Color = c.Field, TextColor = c.Text, Hovering = false,
		}
		table.insert(popup.Rows, entry)

		button.MouseEnter:Connect(function()
			entry.Hovering = true
			self._over += 1
			tween(row, 0.15, { BackgroundColor3 = entry.Color == c.Field and c.Hover or entry.Color })
			tween(scale, 0.25, { Scale = 1.04 }, BACK)
		end)
		button.MouseLeave:Connect(function()
			entry.Hovering = false
			self._over = math.max(0, self._over - 1)
			tween(row, 0.2, { BackgroundColor3 = entry.Color })
			tween(scale, 0.25, { Scale = 1 }, BACK)
		end)
		button.Activated:Connect(function()
			-- little squish, then spring back
			tween(scale, 0.07, { Scale = 0.94 }, QUAD)
			task.delay(0.07, function()
				tween(scale, 0.35, { Scale = entry.Hovering and 1.04 or 1 }, BACK)
			end)
			local ok, msg = self:Perform(action.Id, player)
			if msg then self.Notify(msg) end
			self:_refresh()
		end)
	end

	self:_refresh(true)
	self:_paintSelected()

	-- intro: connector -> header -> rows one after the other, each overshooting a little (Back easing)
	tween(line, 0.3, { Size = UDim2.fromOffset(TAIL, 2) })
	tween(dot, 0.45, { Size = UDim2.fromOffset(9, 9) }, BACK)
	task.delay(0.08, function()
		if not header.Parent then return end
		tween(header, 0.2, { GroupTransparency = 0 }, QUAD)
		tween(headScale, 0.5, { Scale = 1 }, BACK)
	end)
	for i, entry in popup.Rows do
		task.delay(0.18 + (i - 1) * 0.06, function()
			if not entry.Row.Parent then return end
			tween(entry.Row, 0.2, { GroupTransparency = 0 }, QUAD)
			tween(entry.Row, 0.5, { Position = entry.Rest }, BACK)
			tween(entry.Scale, 0.5, { Scale = 1 }, BACK)
		end)
	end
end

-- closes everything together and fast, so nothing lingers on screen
local CLOSE_T = 0.12
function PlayerSelect:Close(instant)
	local popup = self._popup
	if not popup then return end
	self._popup = nil
	self._over = 0

	if instant then
		popup.Gui:Destroy()
		self:_paintSelected(true)
		return
	end
	self:_paintSelected(true)

	local function out(inst, props) tween(inst, CLOSE_T, props, QUAD, Enum.EasingDirection.In) end
	for _, entry in popup.Rows do
		out(entry.Row, { GroupTransparency = 1, Position = UDim2.fromOffset(-14, entry.Rest.Y.Offset) })
		out(entry.Scale, { Scale = 0.8 })
	end
	out(popup.Header, { GroupTransparency = 1 })
	out(popup.HeadScale, { Scale = 0.8 })
	out(popup.Line, { Size = UDim2.fromOffset(0, 2) })
	out(popup.Dot, { Size = UDim2.fromOffset(0, 0) })
	task.delay(CLOSE_T + 0.02, function()
		if popup.Gui.Parent then popup.Gui:Destroy() end
	end)
end

-- rebuild the open menu so it picks up a new colour scheme / accent / transparency
function PlayerSelect:Retheme()
	local popup = self._popup
	if not popup then return end
	local player = popup.Player
	self:Close(true)
	self:Open(player)
end

function PlayerSelect:IsOpen() return self._popup ~= nil end

-- active buttons turn accent-coloured and read "Stop ..."
function PlayerSelect:_refresh(quiet)
	local popup = self._popup
	if not popup then return end
	local c = palette()
	for _, entry in popup.Rows do
		local on = self:IsActive(entry.Action.Id, popup.Player)
		entry.Label.Text = on and entry.Action.Stop or entry.Action.Label
		entry.Color = on and c.Accent or c.Field
		entry.TextColor = on and c.OnAccent or c.Text
		entry.Label.TextColor3 = entry.TextColor
		if quiet then
			entry.Row.BackgroundColor3 = entry.Color
		else
			tween(entry.Row, 0.2, { BackgroundColor3 = (entry.Hovering and not on) and c.Hover or entry.Color })
		end
	end
end

-- actions -----------------------------------------------------------------------------------------
function PlayerSelect:IsActive(id, player)
	if id == "Spectate" then
		local mods = self.Mods
		if mods then return mods.CamMode == "Spectate" and mods.SpectateTarget == player end
		return self._specFallback == player
	end
	local t = self._task
	return t ~= nil and t.Kind == id and t.Target == player
end

function PlayerSelect:IsBusy() return self._task ~= nil end

function PlayerSelect:_stopTask()
	local t = self._task
	if not t then return end
	self._task = nil
	if t.Step then t.Step:Disconnect() end
	if t.Jump then t.Jump:Disconnect() end
	if t.Cleanup then pcall(t.Cleanup) end
	self:_refresh()
end

-- step(dt) runs every Heartbeat; returning false ends the task. cleanup() runs once at the end.
function PlayerSelect:_startTask(kind, target, step, cleanup)
	self:_stopTask()
	local t = { Kind = kind, Target = target, Cleanup = cleanup }
	t.Step = RunService.Heartbeat:Connect(function(dt)
		if self._task ~= t then return end
		local ok, keep = pcall(step, dt)
		if not ok or keep == false then self:_stopTask() end
	end)
	if kind ~= "Fling" then
		t.Jump = UserInputService.JumpRequest:Connect(function()
			if self._task == t then self:_stopTask() end
		end)
	end
	self._task = t
	self:_refresh()
end

-- returns ok, message
function PlayerSelect:Perform(id, player)
	if not (player and player.Parent) then return false, "Player left the game" end
	local active = self:IsActive(id, player)

	if id == "Spectate" then
		local mods = self.Mods
		if mods then
			if active then
				mods:StopCamera()
				return true, "Camera back to you"
			end
			if mods:Spectate(player) then return true, "Spectating " .. player.DisplayName end
			return false, "Could not spectate them"
		end
		local cam = Workspace.CurrentCamera
		if active then
			self._specFallback = nil
			local hum = parts(LocalPlayer)
			if cam and hum then cam.CameraSubject = hum end
			return true, "Camera back to you"
		end
		local hum = parts(player)
		if not (cam and hum) then return false, "They have no character" end
		cam.CameraSubject = hum
		self._specFallback = player
		return true, "Spectating " .. player.DisplayName
	end

	if id == "Teleport" then
		local _, tRoot = parts(player)
		if not tRoot then return false, "They have no character" end
		if self.Mods then
			return self.Mods:TeleportToPlayer(player) and true or false, "To " .. player.DisplayName
		end
		local _, root = parts(LocalPlayer)
		if not root then return false, "You have no character" end
		if self.OnMove then pcall(self.OnMove) end
		root.CFrame = tRoot.CFrame * CFrame.new(0, 0, 3)
		return true, "To " .. player.DisplayName
	end

	-- everything below drives our own character toward the target
	if active then
		self:_stopTask()
		return true, id == "Fling" and "Fling stopped" or "Stopped"
	end
	local hum, root, char = parts(LocalPlayer)
	local _, tRoot = parts(player)
	if not (hum and root) then return false, "You have no character" end
	if not tRoot then return false, "They have no character" end
	if self.OnMove then pcall(self.OnMove) end

	if id == "Fling" then
		local origin = root.CFrame
		local started, hitAt = os.clock(), nil
		self:_startTask("Fling", player, function()
			local _, mRoot = parts(LocalPlayer)
			local _, tr = parts(player)
			if not (mRoot and tr and player.Parent) then return false end
			local now = os.clock()
			if now - started > self.Settings.FlingTime then return false end
			-- they got launched: give it a beat, then stop
			if tr.AssemblyLinearVelocity.Magnitude > 400 then hitAt = hitAt or now end
			if hitAt and now - hitAt > 0.25 then return false end
			mRoot.CFrame = CFrame.new(tr.Position + tr.AssemblyLinearVelocity * 0.1)
			mRoot.AssemblyLinearVelocity = Vector3.new(FLING_LIN, FLING_LIN, FLING_LIN)
			mRoot.AssemblyAngularVelocity = Vector3.new(FLING_ANG, FLING_ANG, FLING_ANG)
		end, function()
			settle(origin) -- back where we started, with no momentum
		end)
		return true, "Flinging " .. player.DisplayName

	elseif id == "Headsit" then
		local restore = ghost(char)
		self:_startTask("Headsit", player, function()
			local h, mRoot = parts(LocalPlayer)
			local _, tr, tChar = parts(player)
			if not (h and mRoot and tr and player.Parent) then return false end
			local head = tChar:FindFirstChild("Head") or tr
			h.Sit = true
			mRoot.CFrame = head.CFrame * CFrame.new(0, 1.6, 0)
			mRoot.AssemblyLinearVelocity = Vector3.zero
			mRoot.AssemblyAngularVelocity = Vector3.zero
		end, function()
			restore()
			local h = parts(LocalPlayer)
			if h then h.Sit = false end
			settle()
		end)
		return true, "Sitting on " .. player.DisplayName .. " (jump to stop)"

	elseif id == "Orbit" then
		local restore, angle = ghost(char), 0
		self:_startTask("Orbit", player, function(dt)
			local _, mRoot = parts(LocalPlayer)
			local _, tr = parts(player)
			if not (mRoot and tr and player.Parent) then return false end
			angle += dt * self.Settings.OrbitSpeed
			local r = self.Settings.OrbitRadius
			local pos = tr.Position + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r)
			mRoot.CFrame = CFrame.lookAt(pos, Vector3.new(tr.Position.X, pos.Y, tr.Position.Z))
			mRoot.AssemblyLinearVelocity = Vector3.zero
			mRoot.AssemblyAngularVelocity = Vector3.zero
		end, function()
			restore()
			settle()
		end)
		return true, "Orbiting " .. player.DisplayName .. " (jump to stop)"

	elseif id == "Shadow" then
		local restore = ghost(char)
		self:_startTask("Shadow", player, function(dt)
			local _, mRoot = parts(LocalPlayer)
			local _, tr = parts(player)
			if not (mRoot and tr and player.Parent) then return false end
			local goal = tr.CFrame * CFrame.new(0, 0, self.Settings.ShadowDistance)
			if (mRoot.Position - goal.Position).Magnitude > 30 then
				mRoot.CFrame = goal
			else
				mRoot.CFrame = mRoot.CFrame:Lerp(goal, math.clamp(dt * 12, 0, 1))
			end
			mRoot.AssemblyLinearVelocity = Vector3.zero
			mRoot.AssemblyAngularVelocity = Vector3.zero
		end, function()
			restore()
			settle()
		end)
		return true, "Shadowing " .. player.DisplayName .. " (jump to stop)"
	end

	return false, "Unknown action"
end

function PlayerSelect:StopActions()
	self:_stopTask()
	return true
end

-- lifecycle ----------------------------------------------------------------------------------------
function PlayerSelect:_step(dt)
	-- the menu follows its player: close it if they leave or respawn
	local popup = self._popup
	if popup then
		local p = popup.Player
		local char = p.Character
		if not (p.Parent and char and popup.Adornee.Parent and popup.Adornee:IsDescendantOf(char)) then
			self:Close()
		end
	end

	-- hover (30 Hz is plenty), skipped while the cursor is on the menu and on touch-only devices
	self._acc += dt
	if self._acc < 1 / 30 then return end
	self._acc = 0
	if self.Settings.Hover and self._over == 0 and UserInputService.MouseEnabled then
		self:_setHover(self:_pick())
	elseif not self.Settings.Hover then
		self:_setHover(nil)
	end
end

function PlayerSelect:SetEnabled(on)
	on = on and true or false
	if on == self.Enabled then return end
	self.Enabled = on

	if on then
		table.insert(self._conns, UserInputService.InputBegan:Connect(function(input, processed)
			if processed then return end -- the menu's own buttons land here
			local t = input.UserInputType
			if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end
			local key = (t == Enum.UserInputType.MouseButton1) and "mouse" or input
			self._down[key] = { Pos = Vector2.new(input.Position.X, input.Position.Y), Time = os.clock(), Touch = t == Enum.UserInputType.Touch }
		end))
		table.insert(self._conns, UserInputService.InputEnded:Connect(function(input)
			local t = input.UserInputType
			local key = (t == Enum.UserInputType.MouseButton1) and "mouse" or input
			local d = self._down[key]
			if not d then return end
			self._down[key] = nil
			local now = Vector2.new(input.Position.X, input.Position.Y)
			if (now - d.Pos).Magnitude > CLICK_SLOP or os.clock() - d.Time > 0.5 then return end -- drag / long press
			-- touch positions need the top-bar inset added to become viewport points
			self:_onClick(d.Touch and (d.Pos + GuiService:GetGuiInset()) or nil)
		end))
		table.insert(self._conns, RunService.Heartbeat:Connect(function(dt) self:_step(dt) end))
	else
		for _, conn in self._conns do conn:Disconnect() end
		table.clear(self._conns)
		table.clear(self._down)
		self._armed, self._hoverP, self._over = nil, nil, 0
		self:Close(true)
		self:_stopTask()
		self:_paintHover()
		self:_paintSelected()
	end
end

function PlayerSelect:Set(key, value)
	if self.Settings[key] ~= nil then self.Settings[key] = value end
	if key == "Hover" and not value then self:_setHover(nil) end
end

function PlayerSelect:Destroy()
	self:SetEnabled(false)
	if self._holder then self._holder:Destroy() end
end

return PlayerSelect

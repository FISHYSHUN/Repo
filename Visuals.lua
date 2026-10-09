-- modules/Visuals.lua
-- Player ESP: chams (Highlight), name / distance / health tags, tracers.
-- Knows nothing about the GUI. Client-side only.
local import = ...

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CoreGui = game:GetService("CoreGui")

local STEP = "PlayerMenuVisuals"
local HAS_DRAWING = Drawing ~= nil and Drawing.new ~= nil -- tracers need an executor with Drawing support

local Visuals = {}
Visuals.__index = Visuals

local function guiParent()
	local ok, ui = pcall(function() return gethui and gethui() end)
	if ok and ui then return ui end
	return CoreGui
end

function Visuals.new()
	local self = setmetatable({}, Visuals)
	self.Player = Players.LocalPlayer
	self.Settings = {
		Enabled = false,
		Chams = true,
		Names = true,
		Distance = true,
		Health = true,
		Tracers = false,
		TeamCheck = true,
		TeamColors = false,
		MaxDistance = 2000,
		FillTransparency = 0.6,
		TextSize = 14,
		FillColor = Color3.fromRGB(255, 60, 60),
		OutlineColor = Color3.fromRGB(255, 255, 255),
	}
	self._entries = {}
	self._conns = {}
	self._folder = nil
	return self
end

function Visuals:Set(key, value)
	self.Settings[key] = value
end

function Visuals:HasDrawing()
	return HAS_DRAWING
end

function Visuals:_allowed(player)
	if self.Settings.TeamCheck and player.Team ~= nil and player.Team == self.Player.Team then
		return false
	end
	return true
end

function Visuals:_color(player)
	if self.Settings.TeamColors and player.Team then
		return player.TeamColor.Color
	end
	return self.Settings.FillColor
end

function Visuals:_makeEntry(player)
	if self._entries[player] then return end
	local e = {}

	local hl = Instance.new("Highlight")
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Enabled = false
	hl.Parent = self._folder
	e.Highlight = hl

	local bb = Instance.new("BillboardGui")
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(220, 60)
	bb.StudsOffset = Vector3.new(0, 3, 0)
	bb.Enabled = false
	bb.Parent = self._folder

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextStrokeTransparency = 0.4
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = bb
	e.Billboard, e.Label = bb, label

	if HAS_DRAWING then
		local line = Drawing.new("Line")
		line.Thickness = 1
		line.Visible = false
		e.Tracer = line
	end

	self._entries[player] = e
end

function Visuals:_destroyEntry(player)
	local e = self._entries[player]
	if not e then return end
	e.Highlight:Destroy()
	e.Billboard:Destroy()
	if e.Tracer then pcall(function() e.Tracer:Remove() end) end
	self._entries[player] = nil
end

local function hide(e)
	e.Highlight.Enabled = false
	e.Billboard.Enabled = false
	if e.Tracer then e.Tracer.Visible = false end
end

function Visuals:_step()
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local s = self.Settings
	local myChar = self.Player.Character
	local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
	local from = myRoot and myRoot.Position or cam.CFrame.Position

	for player, e in self._entries do
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local head = char and char:FindFirstChild("Head") or root
		local dist = root and (root.Position - from).Magnitude or math.huge

		if hum and root and head and hum.Health > 0 and dist <= s.MaxDistance and self:_allowed(player) then
			local color = self:_color(player)

			-- chams
			e.Highlight.Enabled = s.Chams
			if e.Highlight.Adornee ~= char then e.Highlight.Adornee = char end
			e.Highlight.FillColor = color
			e.Highlight.OutlineColor = s.OutlineColor
			e.Highlight.FillTransparency = s.FillTransparency

			-- text tag
			local showText = s.Names or s.Distance or s.Health
			e.Billboard.Enabled = showText
			if e.Billboard.Adornee ~= head then e.Billboard.Adornee = head end
			if showText then
				local lines = {}
				if s.Names then table.insert(lines, player.DisplayName) end
				if s.Distance then table.insert(lines, string.format("[%d studs]", math.floor(dist + 0.5))) end
				if s.Health then
					table.insert(lines, string.format("HP %d/%d", math.floor(hum.Health), math.floor(hum.MaxHealth)))
				end
				e.Label.Text = table.concat(lines, "\n")
				e.Label.TextSize = s.TextSize
				e.Label.TextColor3 = color
			end

			-- tracer
			if e.Tracer then
				if s.Tracers then
					local v, onScreen = cam:WorldToViewportPoint(root.Position)
					if onScreen then
						local size = cam.ViewportSize
						e.Tracer.From = Vector2.new(size.X / 2, size.Y)
						e.Tracer.To = Vector2.new(v.X, v.Y)
						e.Tracer.Color = color
						e.Tracer.Visible = true
					else
						e.Tracer.Visible = false
					end
				else
					e.Tracer.Visible = false
				end
			end
		else
			hide(e)
		end
	end
end

function Visuals:SetEnabled(on)
	if on == self.Settings.Enabled then return end
	self.Settings.Enabled = on

	if on then
		self._folder = Instance.new("Folder")
		self._folder.Name = "PlayerMenuVisuals"
		self._folder.Parent = guiParent()

		for _, p in Players:GetPlayers() do
			if p ~= self.Player then self:_makeEntry(p) end
		end
		self._conns.Added = Players.PlayerAdded:Connect(function(p)
			if p ~= self.Player then self:_makeEntry(p) end
		end)
		self._conns.Removing = Players.PlayerRemoving:Connect(function(p)
			self:_destroyEntry(p)
		end)
		RunService:BindToRenderStep(STEP, Enum.RenderPriority.Last.Value, function()
			self:_step()
		end)
	else
		pcall(RunService.UnbindFromRenderStep, RunService, STEP)
		for _, conn in self._conns do conn:Disconnect() end
		table.clear(self._conns)
		for player in self._entries do self:_destroyEntry(player) end
		if self._folder then
			self._folder:Destroy()
			self._folder = nil
		end
	end
end

function Visuals:Destroy()
	self:SetEnabled(false)
end

return Visuals

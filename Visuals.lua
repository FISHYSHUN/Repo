-- modules/Visuals.lua
-- Player ESP: chams (Highlight), name / distance / health tags, tracers.
-- Knows nothing about the GUI. Client-side only.
local import = ...

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
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
		HealthColors = false, -- text turns from green to red as health drops
		TracerOrigin = "Bottom", -- "Bottom" | "Center" | "Mouse"
		TracerThickness = 1,
		FlagColor = true, -- players flagged by the Guard are drawn orange
		FillColor = Color3.fromRGB(255, 60, 60),
		OutlineColor = Color3.fromRGB(255, 255, 255),
	}
	self._entries = {}
	self._conns = {}
	self._folder = nil
	self.FlaggedFn = nil -- function(player) -> true when the Guard flagged them
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
	if self.Settings.FlagColor and self.FlaggedFn and self.FlaggedFn(player) then
		return Color3.fromRGB(255, 170, 0)
	end
	if self.Settings.TeamColors and player.Team then
		return player.TeamColor.Color
	end
	return self.Settings.FillColor
end

function Visuals:_makeEntry(player)
	if self._entries[player] then return end
	local e = { Alpha = 0 }

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
	e.Alpha = 0
	e.Highlight.Enabled = false
	e.Billboard.Enabled = false
	if e.Tracer then e.Tracer.Visible = false end
end

local function lerp(a, b, t) return a + (b - a) * t end

-- Everything fades in when a player comes into range and fades out when they leave
function Visuals:_step(dt)
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local s = self.Settings
	local myChar = self.Player.Character
	local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
	local from = myRoot and myRoot.Position or cam.CFrame.Position
	local fade = 1 - math.exp(-(dt or 0.016) * 12)

	for player, e in self._entries do
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local head = char and char:FindFirstChild("Head") or root
		local dist = root and (root.Position - from).Magnitude or math.huge

		local show = hum and root and head and hum.Health > 0 and dist <= s.MaxDistance and self:_allowed(player)
		e.Alpha += ((show and 1 or 0) - e.Alpha) * fade

		if not show and e.Alpha < 0.02 then
			hide(e)
		else
			local a = e.Alpha
			local color = show and self:_color(player) or e.LastColor or s.FillColor
			e.LastColor = color

			-- chams
			e.Highlight.Enabled = s.Chams
			if show and e.Highlight.Adornee ~= char then e.Highlight.Adornee = char end
			e.Highlight.FillColor = color
			e.Highlight.OutlineColor = s.OutlineColor
			e.Highlight.FillTransparency = lerp(1, s.FillTransparency, a)
			e.Highlight.OutlineTransparency = 1 - a

			-- text tag
			local showText = s.Names or s.Distance or s.Health
			e.Billboard.Enabled = showText
			if show and e.Billboard.Adornee ~= head then e.Billboard.Adornee = head end
			if showText then
				if show then
					local lines = {}
					if s.Names then table.insert(lines, player.DisplayName) end
					if s.Distance then table.insert(lines, string.format("[%d studs]", math.floor(dist + 0.5))) end
					if s.Health then
						table.insert(lines, string.format("HP %d/%d", math.floor(hum.Health), math.floor(hum.MaxHealth)))
					end
					e.Label.Text = table.concat(lines, "\n")
					e.Label.TextSize = s.TextSize
					if s.HealthColors then
						local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
						e.Label.TextColor3 = Color3.fromRGB(255, 70, 70):Lerp(Color3.fromRGB(90, 255, 120), frac)
					else
						e.Label.TextColor3 = color
					end
				end
				e.Label.TextTransparency = 1 - a
				e.Label.TextStrokeTransparency = lerp(1, 0.4, a)
			end

			-- tracer (hidden at once when the player is gone: its end point would be stale)
			if e.Tracer then
				if s.Tracers and show then
					local v, onScreen = cam:WorldToViewportPoint(root.Position)
					if onScreen then
						local size = cam.ViewportSize
						local origin
						if s.TracerOrigin == "Center" then
							origin = size / 2
						elseif s.TracerOrigin == "Mouse" then
							origin = UserInputService:GetMouseLocation()
						else
							origin = Vector2.new(size.X / 2, size.Y)
						end
						e.Tracer.From = origin
						e.Tracer.To = Vector2.new(v.X, v.Y)
						e.Tracer.Color = color
						e.Tracer.Thickness = s.TracerThickness
						e.Tracer.Transparency = a
						e.Tracer.Visible = true
					else
						e.Tracer.Visible = false
					end
				else
					e.Tracer.Visible = false
				end
			end
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
		RunService:BindToRenderStep(STEP, Enum.RenderPriority.Last.Value, function(dt)
			self:_step(dt)
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

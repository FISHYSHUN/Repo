-- modules/Extras.lua  (merged: Visuals + Effects + Graphics + Audio)
-- Client-side feature modules that know nothing about the GUI.
-- local Extras = import("Extras");  Extras.Visuals / Extras.Effects / Extras.Graphics / Extras.Audio
local import = ...

-- ======== Visuals (merged) ========
local Visuals = (function(...)
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
end)(import)

-- ======== Effects (merged) ========
local Effects = (function(...)
-- modules/Effects.lua
-- Visual effects. Knows nothing about the GUI. Client-side only.
--   Jump rings : expanding neon rings under your feet on every air jump (Infinite Jump / double jump)
--   Speed FX   : while Shift speeds you up (sprint, fly boost, free cam): FOV punch, radial speed
--                lines on screen, and a trail behind your character. Fades in and out smoothly.
local import = ...

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local CoreGui = game:GetService("CoreGui")

local STEP = "PlayerMenuEffects"
local LINES = 18

local Effects = {}
Effects.__index = Effects

Effects.Palette = {
	Ice = Color3.fromRGB(120, 200, 255), White = Color3.fromRGB(255, 255, 255),
	Green = Color3.fromRGB(110, 255, 150), Purple = Color3.fromRGB(190, 120, 255),
	Orange = Color3.fromRGB(255, 170, 70), Red = Color3.fromRGB(255, 85, 95),
}
Effects.PaletteNames = { "Ice", "White", "Green", "Purple", "Orange", "Red" }

local function guiParent()
	local ok, ui = pcall(function() return gethui and gethui() end)
	if ok and ui then return ui end
	return CoreGui
end

function Effects.new(mods)
	local self = setmetatable({}, Effects)
	self.Mods = mods
	self.Player = Players.LocalPlayer
	self.Settings = {
		JumpFX = false, JumpColor = Effects.Palette.Ice, RingSize = 14,
		SpeedFX = false, SpeedColor = Effects.Palette.White,
		Intensity = 100,   -- % (scales FOV punch, line opacity, trail)
		FovPunch = true, Lines = true, Trail = true,
	}
	self._conns = {}
	self._level = 0       -- 0..1 smoothed "going fast"
	self._punch = 0       -- FOV degrees currently added by us
	self._lines = {}
	self._clock = 0
	return self
end

-- JUMP RINGS ---------------------------------------------------------------------------------
function Effects:_ring(pos, size, delay)
	task.delay(delay or 0, function()
		local s = self.Settings
		local part = Instance.new("Part")
		part.Name = "PM_JumpRing"
		part.Shape = Enum.PartType.Cylinder
		part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch = true, false, false, false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = s.JumpColor
		part.Transparency = 0.25
		part.Size = Vector3.new(0.15, 1, 1)
		part.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
		part.Parent = Workspace.CurrentCamera or Workspace
		local info = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local t = TweenService:Create(part, info, { Size = Vector3.new(0.15, size, size), Transparency = 1 })
		t.Completed:Once(function() part:Destroy() end)
		t:Play()
	end)
end

function Effects:_onJump()
	if not self.Settings.JumpFX then return end
	local char = self.Player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or hum.Health <= 0 then return end
	if hum.FloorMaterial ~= Enum.Material.Air then return end -- only air jumps (the "double jump")
	local feet = root.Position - Vector3.new(0, hum.HipHeight + root.Size.Y / 2 - 0.1, 0)
	local size = self.Settings.RingSize
	self:_ring(feet, size, 0)
	self:_ring(feet, size * 0.6, 0.07)
end

-- SPEED FX -----------------------------------------------------------------------------------
function Effects:_makeLines()
	if self._gui then return end
	local gui = Instance.new("ScreenGui")
	gui.Name = "PlayerMenuEffects"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = guiParent()
	self._gui = gui
	for i = 1, LINES do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BackgroundTransparency = 1
		f.Active = false
		f.Parent = gui
		local angle = (i / LINES) * math.pi * 2 + math.random() * 0.15
		self._lines[i] = {
			Frame = f, Angle = angle, Phase = math.random(), Speed = 1.4 + math.random() * 1.2,
			Len = 70 + math.random(0, 90),
		}
	end
end

function Effects:_clearLines()
	if self._gui then self._gui:Destroy() end
	self._gui = nil
	table.clear(self._lines)
end

function Effects:_trail(char)
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return nil end
	if self._trailRoot ~= root or not (self._trailObj and self._trailObj.Parent) then
		self:_clearTrail()
		local a0 = Instance.new("Attachment")
		a0.Name = "PM_TrailTop"
		a0.Position = Vector3.new(0, 1.2, 0)
		a0.Parent = root
		local a1 = Instance.new("Attachment")
		a1.Name = "PM_TrailBottom"
		a1.Position = Vector3.new(0, -1.4, 0)
		a1.Parent = root
		local tr = Instance.new("Trail")
		tr.Name = "PM_SpeedTrail"
		tr.Attachment0, tr.Attachment1 = a0, a1
		tr.Lifetime = 0.35
		tr.MinLength = 0.05
		tr.LightEmission = 1
		tr.FaceCamera = true
		tr.Enabled = false
		tr.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
		tr.Parent = root
		self._trailRoot, self._trailObj, self._trailAtt = root, tr, { a0, a1 }
	end
	return self._trailObj
end

function Effects:_clearTrail()
	if self._trailObj then self._trailObj:Destroy() end
	if self._trailAtt then
		for _, a in self._trailAtt do a:Destroy() end
	end
	self._trailObj, self._trailAtt, self._trailRoot = nil, nil, nil
end

-- is Shift currently speeding something up?
function Effects:_boosting()
	local m = self.Mods
	if UserInputService:GetFocusedTextBox() ~= nil then return false end
	local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
	if m._sprinting and m.CamMode == "Off" then return true end
	if m.Flying and m.Settings.FlyBoost and shift and m.CamMode == "Off" then return true end
	if m.CamMode == "Free" and shift then return true end
	return false
end

function Effects:_step(dt)
	local s = self.Settings
	local cam = Workspace.CurrentCamera
	if not cam then return end

	local want = (s.SpeedFX and self:_boosting()) and 1 or 0
	self._level += (want - self._level) * (1 - math.exp(-dt * (want == 1 and 7 or 5)))
	if self._level < 0.01 and want == 0 then self._level = 0 end
	local level = self._level
	local k = s.Intensity / 100
	self._clock += dt

	-- FOV punch: we only ever add / remove our own delta, so the game's and the menu's FOV still apply
	local punch = (s.FovPunch and s.SpeedFX) and level * 14 * k or 0
	if math.abs(punch - self._punch) > 0.001 then
		cam.FieldOfView = math.clamp(cam.FieldOfView - self._punch + punch, 1, 120)
		self._punch = punch
	end

	-- speed lines
	if s.Lines and s.SpeedFX and level > 0.02 then
		self:_makeLines()
		local color = s.SpeedColor
		for _, l in self._lines do
			local t = (self._clock * l.Speed * 0.55 + l.Phase) % 1
			local r = 0.34 + 0.42 * t
			local f = l.Frame
			f.Position = UDim2.fromScale(0.5 + math.cos(l.Angle) * r * 0.8, 0.5 + math.sin(l.Angle) * r * 0.8)
			f.Rotation = math.deg(l.Angle)
			f.Size = UDim2.fromOffset(l.Len * (0.6 + t), 2)
			f.BackgroundColor3 = color
			f.BackgroundTransparency = 1 - level * 0.6 * k * math.sin(math.pi * t)
		end
	elseif self._gui then
		self:_clearLines()
	end

	-- trail
	local char = self.Player.Character
	if s.Trail and s.SpeedFX and level > 0.15 then
		local tr = self:_trail(char)
		if tr then
			tr.Color = ColorSequence.new(s.SpeedColor)
			tr.Enabled = true
		end
	elseif self._trailObj then
		self._trailObj.Enabled = false
		if level == 0 then self:_clearTrail() end
	end
end

-- SETTINGS -----------------------------------------------------------------------------------
function Effects:Set(key, value)
	self.Settings[key] = value
	self:_sync()
end

function Effects:_sync()
	local s = self.Settings
	if s.JumpFX and not self._conns.Jump then
		self._conns.Jump = UserInputService.JumpRequest:Connect(function() self:_onJump() end)
	elseif not s.JumpFX and self._conns.Jump then
		self._conns.Jump:Disconnect()
		self._conns.Jump = nil
	end

	if s.SpeedFX and not self._conns.Step then
		self._conns.Step = true
		RunService:BindToRenderStep(STEP, Enum.RenderPriority.Last.Value, function(dt) self:_step(dt) end)
	elseif not s.SpeedFX and self._conns.Step then
		self._conns.Step = nil
		pcall(RunService.UnbindFromRenderStep, RunService, STEP)
		self:_release()
	end
end

-- takes away everything speed FX added
function Effects:_release()
	local cam = Workspace.CurrentCamera
	if cam and self._punch ~= 0 then cam.FieldOfView = math.clamp(cam.FieldOfView - self._punch, 1, 120) end
	self._punch, self._level = 0, 0
	self:_clearLines()
	self:_clearTrail()
end

function Effects:Destroy()
	self.Settings.JumpFX, self.Settings.SpeedFX = false, false
	if self._conns.Jump then self._conns.Jump:Disconnect() end
	if self._conns.Step then pcall(RunService.UnbindFromRenderStep, RunService, STEP) end
	table.clear(self._conns)
	self:_release()
end

return Effects
end)(import)

-- ======== Graphics (merged) ========
local Graphics = (function(...)
-- modules/Graphics.lua
-- Performance + clarity. Knows nothing about the GUI. Client-side only.
--   Performance : post effects, particles, lights, shadows, materials, textures, water,
--                 lowest quality level, pause 3D rendering, FPS cap.
--   Clarity     : own ColorCorrection / Bloom / SunRays + exposure, clear haze / fog,
--                 remove blur, max quality level.
-- Every property it changes is remembered once and put back when the last feature using it is turned off.
-- Instances named "PM_*" are ours and are never touched by the performance rules.
local import = ...

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local RESCAN = 5        -- seconds between rescans for things the game spawned or re-enabled
local YIELD_EVERY = 400 -- instances processed before a scan yields a frame

local Graphics = {}
Graphics.__index = Graphics

local function isOwn(inst) return inst.Name:sub(1, 3) == "PM_" end

-- player characters and NPCs keep their look (faces, skins, materials)
local function isCharacter(inst)
	local cur = inst.Parent
	while cur and cur ~= Workspace do
		if cur:IsA("Model") and (Players:GetPlayerFromCharacter(cur) or cur:FindFirstChildOfClass("Humanoid")) then
			return true
		end
		cur = cur.Parent
	end
	return false
end

-- Settings key -> { Prop, Value, Match(inst) }. A rule is "on" while Settings[key] is true.
local RULES = {
	PostFX = {
		Prop = "Enabled", Value = false,
		Match = function(i) return i:IsA("PostEffect") and not isOwn(i) end,
	},
	RemoveBlur = {
		Prop = "Enabled", Value = false,
		Match = function(i) return (i:IsA("BlurEffect") or i:IsA("DepthOfFieldEffect")) and not isOwn(i) end,
	},
	Particles = {
		Prop = "Enabled", Value = false,
		Match = function(i)
			return i:IsA("ParticleEmitter") or i:IsA("Trail") or i:IsA("Beam")
				or i:IsA("Fire") or i:IsA("Smoke") or i:IsA("Sparkles")
		end,
	},
	Lights = {
		Prop = "Enabled", Value = false,
		Match = function(i) return i:IsA("Light") end,
	},
	Shadows = {
		Prop = "CastShadow", Value = false,
		Match = function(i) return i:IsA("BasePart") and i.CastShadow end,
	},
	Materials = {
		Prop = "Material", Value = Enum.Material.SmoothPlastic,
		Match = function(i)
			return i:IsA("BasePart") and not i:IsA("Terrain")
				and i.Material ~= Enum.Material.SmoothPlastic and not isCharacter(i)
		end,
	},
	Textures = {
		Prop = "Transparency", Value = 1,
		Match = function(i) return i:IsA("Decal") and i.Transparency < 1 and not isCharacter(i) end,
	},
}

local function rendering()
	local ok, r = pcall(function() return settings().Rendering end)
	return ok and r or nil
end

function Graphics.new()
	local self = setmetatable({}, Graphics)
	self.Settings = {
		-- performance
		PostFX = false, Particles = false, Lights = false, Shadows = false,
		Materials = false, Textures = false, Water = false,
		Lowest = false, NoRender = false, FpsCap = false, FpsValue = 144,
		-- clarity
		Clarity = false, Contrast = 10, Saturation = 10, Brightness = 0,
		Bloom = 20, SunRays = 25, Exposure = 0,
		ClearHaze = false, RemoveBlur = false, MaxQuality = false,
	}
	self._held = setmetatable({}, { __mode = "k" }) -- [inst] = { [prop] = { Orig, Owners } }
	self._fx = {}                                   -- our own post effects
	self._conns = {}
	self._scanTok = {}
	self._acc = 0
	self._qOrig = nil
	return self
end

function Graphics:HasFpsCap() return type(setfpscap) == "function" end

-- HOLD / RELEASE ----------------------------------------------------------------------------
function Graphics:_hold(inst, prop, value, feature)
	local rec = self._held[inst]
	if not rec then
		rec = {}
		self._held[inst] = rec
	end
	local p = rec[prop]
	if not p then
		local ok, orig = pcall(function() return inst[prop] end)
		if not ok then return end
		p = { Orig = orig, Owners = {} }
		rec[prop] = p
	end
	p.Owners[feature] = true
	pcall(function() inst[prop] = value end)
end

function Graphics:_release(feature)
	for inst, rec in self._held do
		for prop, p in rec do
			if p.Owners[feature] then
				p.Owners[feature] = nil
				if next(p.Owners) == nil then
					pcall(function() inst[prop] = p.Orig end)
					rec[prop] = nil
				end
			end
		end
		if next(rec) == nil then self._held[inst] = nil end
	end
end

-- RULE SCANNING -----------------------------------------------------------------------------
function Graphics:_scan(key)
	local rule = RULES[key]
	self._scanTok[key] = (self._scanTok[key] or 0) + 1
	local tok = self._scanTok[key]
	task.spawn(function()
		local n = 0
		for _, root in { Lighting, Workspace } do
			for _, d in root:GetDescendants() do
				if self._scanTok[key] ~= tok or not self.Settings[key] then return end
				if rule.Match(d) then self:_hold(d, rule.Prop, rule.Value, key) end
				n += 1
				if n % YIELD_EVERY == 0 then task.wait() end
			end
		end
	end)
end

function Graphics:_consider(d)
	for key, rule in RULES do
		if self.Settings[key] and rule.Match(d) then
			self:_hold(d, rule.Prop, rule.Value, key)
		end
	end
end

function Graphics:_anyRule()
	for key in RULES do
		if self.Settings[key] then return true end
	end
	return false
end

-- connections exist only while at least one rule is on
function Graphics:_sync()
	local need = self:_anyRule()
	if need and not self._conns.Beat then
		self._conns.AddedL = Lighting.DescendantAdded:Connect(function(d) self:_consider(d) end)
		self._conns.AddedW = Workspace.DescendantAdded:Connect(function(d) self:_consider(d) end)
		self._conns.Beat = RunService.Heartbeat:Connect(function(dt)
			self._acc += dt
			if self._acc < RESCAN then return end
			self._acc = 0
			for key in RULES do
				if self.Settings[key] then self:_scan(key) end
			end
		end)
	elseif not need and self._conns.Beat then
		for name, conn in self._conns do
			conn:Disconnect()
			self._conns[name] = nil
		end
	end
end

-- SINGLE FEATURES ----------------------------------------------------------------------------
function Graphics:_water()
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if self.Settings.Water and terrain then
		self:_hold(terrain, "WaterWaveSize", 0, "Water")
		self:_hold(terrain, "WaterWaveSpeed", 0, "Water")
		self:_hold(terrain, "WaterReflectance", 0, "Water")
	else
		self:_release("Water")
	end
end

function Graphics:_haze()
	if self.Settings.ClearHaze then
		local atmos = Lighting:FindFirstChildOfClass("Atmosphere")
		if atmos then
			self:_hold(atmos, "Density", 0, "Haze")
			self:_hold(atmos, "Haze", 0, "Haze")
		end
		self:_hold(Lighting, "FogEnd", 100000, "Haze")
	else
		self:_release("Haze")
	end
end

-- Lowest wins if both are somehow on; neither = the level the game had
function Graphics:_quality()
	local r = rendering()
	if not r then return end
	local s = self.Settings
	if (s.Lowest or s.MaxQuality) and not self._qOrig then
		local ok, level = pcall(function() return r.QualityLevel end)
		if ok then self._qOrig = level end
	end
	local want
	if s.Lowest then
		want = Enum.QualityLevel.Level01
	elseif s.MaxQuality then
		want = Enum.QualityLevel.Level21
	else
		want = self._qOrig
		self._qOrig = nil
	end
	if want then pcall(function() r.QualityLevel = want end) end
end

function Graphics:_render()
	pcall(RunService.Set3dRenderingEnabled, RunService, not self.Settings.NoRender)
end

function Graphics:_cap()
	if not self:HasFpsCap() then return end
	pcall(setfpscap, self.Settings.FpsCap and self.Settings.FpsValue or 0)
end

function Graphics:_clarity()
	local s = self.Settings
	if not s.Clarity then
		for name, e in self._fx do
			e:Destroy()
			self._fx[name] = nil
		end
		self:_release("Clarity")
		return
	end
	local function fx(class, name)
		local e = self._fx[name]
		if not e or e.Parent ~= Lighting then
			e = Instance.new(class)
			e.Name = "PM_" .. name
			e.Parent = Lighting
			self._fx[name] = e
		end
		return e
	end
	local cc = fx("ColorCorrectionEffect", "Color")
	cc.Brightness = s.Brightness / 100
	cc.Contrast = s.Contrast / 100
	cc.Saturation = s.Saturation / 100

	local bloom = fx("BloomEffect", "Bloom")
	bloom.Intensity = s.Bloom / 100
	bloom.Size = 24
	bloom.Threshold = 1
	bloom.Enabled = s.Bloom > 0

	local rays = fx("SunRaysEffect", "Rays")
	rays.Intensity = s.SunRays / 100
	rays.Spread = 0.6
	rays.Enabled = s.SunRays > 0

	self:_hold(Lighting, "ExposureCompensation", s.Exposure / 10, "Clarity")
end

-- ENTRY POINT ---------------------------------------------------------------------------------
function Graphics:Set(key, value)
	self.Settings[key] = value
	if RULES[key] then
		if value then
			self:_scan(key)
		else
			self._scanTok[key] = (self._scanTok[key] or 0) + 1
			self:_release(key)
		end
		self:_sync()
	elseif key == "Water" then
		self:_water()
	elseif key == "Lowest" or key == "MaxQuality" then
		self:_quality()
	elseif key == "NoRender" then
		self:_render()
	elseif key == "FpsCap" or key == "FpsValue" then
		self:_cap()
	elseif key == "ClearHaze" then
		self:_haze()
	else
		self:_clarity() -- Clarity, Contrast, Saturation, Brightness, Bloom, SunRays, Exposure
	end
end

function Graphics:Destroy()
	local s = self.Settings
	for key in RULES do
		s[key] = false
		self._scanTok[key] = (self._scanTok[key] or 0) + 1
	end
	s.Water, s.Lowest, s.MaxQuality, s.NoRender = false, false, false, false
	s.FpsCap, s.Clarity, s.ClearHaze = false, false, false
	self:_sync()
	for inst, rec in self._held do
		for prop, p in rec do
			pcall(function() inst[prop] = p.Orig end)
		end
	end
	table.clear(self._held)
	for name, e in self._fx do
		e:Destroy()
		self._fx[name] = nil
	end
	self:_quality()
	self:_render()
	self:_cap()
end

return Graphics
end)(import)

-- ======== Audio (merged) ========
local Audio = (function(...)
-- modules/Audio.lua
-- Master volume for game audio. Knows nothing about the GUI. Client-side only.
--   Sound       : routed through one SoundGroup (the game's own volume tweens keep working).
--                 A sound that already has a group gets its top-level group parented under ours,
--                 and everything is put back when you turn it off.
--   AudioPlayer : Volume scaled; if the game changes it, the new value becomes the base.
--   Voice chat  : never touched. Voice is not a Sound / AudioPlayer, and anything with "voice" in
--                 its name or ancestry, or under an AudioDeviceInput / AudioDeviceOutput, is skipped.
local import = ...

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Audio = {}
Audio.__index = Audio

local function skip(inst)
	local cur = inst
	while cur and cur ~= game do
		if cur.Name:lower():find("voice", 1, true)
			or cur:IsA("AudioDeviceInput") or cur:IsA("AudioDeviceOutput") then
			return true
		end
		cur = cur.Parent
	end
	return false
end

function Audio.new()
	local self = setmetatable({}, Audio)
	self.Player = Players.LocalPlayer
	self.Settings = { Enabled = false, Percent = 100 }
	self._sounds = setmetatable({}, { __mode = "k" }) -- [sound] = false (was ungrouped) | its original group
	self._tops = {}                                   -- [group] = original parent
	self._players = setmetatable({}, { __mode = "k" }) -- [AudioPlayer] = { Orig, Applied }
	self._conns = {}
	self._group = nil
	self._acc, self._scanT = 0, 0
	return self
end

function Audio:_factor()
	return math.clamp(self.Settings.Percent / 100, 0, 10)
end

function Audio:Set(key, value)
	self.Settings[key] = value
	if key == "Enabled" then
		self:SetEnabled(value)
	elseif key == "Percent" and self._group then
		self._group.Volume = self:_factor()
	end
end

function Audio:_attachSound(sound)
	local group = self._group
	if not group or skip(sound) then return end
	local rec = self._sounds[sound]
	local current = sound.SoundGroup
	if rec == false and current ~= group then
		self._sounds[sound] = nil -- the game moved it to another group: look at it again
		rec = nil
	end
	if rec ~= nil or current == group then return end

	if current == nil then
		self._sounds[sound] = false
		sound.SoundGroup = group
		return
	end

	-- already in a group: put the top of that group's chain under ours
	local top = current
	local guard = 0
	while top.Parent and top.Parent:IsA("SoundGroup") and top.Parent ~= group and guard < 32 do
		top = top.Parent
		guard += 1
	end
	if top ~= group and top.Parent ~= group and self._tops[top] == nil then
		self._tops[top] = top.Parent or false
		top.Parent = group
	end
	self._sounds[sound] = current
end

function Audio:_attachPlayer(ap)
	if self._players[ap] then return end
	self._players[ap] = { Orig = ap.Volume, Applied = ap.Volume }
end

function Audio:_consider(inst)
	if inst:IsA("Sound") then
		self:_attachSound(inst)
	elseif inst:IsA("AudioPlayer") then
		self:_attachPlayer(inst)
	end
end

function Audio:_roots()
	local roots = { Workspace, SoundService }
	local gui = self.Player and self.Player:FindFirstChildOfClass("PlayerGui")
	if gui then table.insert(roots, gui) end
	return roots
end

function Audio:_scan()
	for _, root in self:_roots() do
		for _, d in root:GetDescendants() do self:_consider(d) end
	end
end

function Audio:_step()
	local factor = self:_factor()
	for ap, rec in self._players do
		if ap.Parent then
			if ap.Volume ~= rec.Applied then rec.Orig = ap.Volume end
			local target = rec.Orig * factor
			if ap.Volume ~= target then ap.Volume = target end
			rec.Applied = ap.Volume
		else
			self._players[ap] = nil
		end
	end
end

function Audio:_sync()
	if self.Settings.Enabled then
		if self._group then return end
		local group = Instance.new("SoundGroup")
		group.Name = "PlayerMenuMaster"
		group.Volume = self:_factor()
		group.Parent = SoundService
		self._group = group

		for _, root in self:_roots() do
			table.insert(self._conns, root.DescendantAdded:Connect(function(d) self:_consider(d) end))
		end
		self:_scan()
		self._conns.Beat = RunService.Heartbeat:Connect(function(dt)
			self._acc += dt
			self._scanT += dt
			if self._acc >= 0.25 then
				self._acc = 0
				self:_step()
			end
			if self._scanT >= 4 then
				self._scanT = 0
				self:_scan()
			end
		end)
	else
		self:_restore()
	end
end

function Audio:_restore()
	for key, conn in self._conns do
		conn:Disconnect()
		self._conns[key] = nil
	end
	local group = self._group
	for sound, rec in self._sounds do
		if rec == false and sound.Parent and sound.SoundGroup == group then sound.SoundGroup = nil end
	end
	table.clear(self._sounds)
	for top, parent in self._tops do
		if top.Parent == group then top.Parent = parent or nil end
	end
	table.clear(self._tops)
	for ap, rec in self._players do
		if ap.Parent then ap.Volume = rec.Orig end
	end
	table.clear(self._players)
	if group then
		group:Destroy()
		self._group = nil
	end
end

function Audio:SetEnabled(on)
	self.Settings.Enabled = on
	self:_sync()
end

function Audio:IsActive() return self._group ~= nil end

function Audio:Destroy()
	self.Settings.Enabled = false
	self:_restore()
end

return Audio
end)(import)

return {
	Visuals = Visuals,
	Effects = Effects,
	Graphics = Graphics,
	Audio = Audio,
}

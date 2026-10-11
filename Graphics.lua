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

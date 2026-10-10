-- modules/PlayerMods.lua
-- All functionality -> player modifiers. It knows nothing about the GUI.
-- NOTE: this runs on the client, so changes are local (the server can override them).
local import = ...

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local StatsService = game:GetService("Stats")
local TweenService = game:GetService("TweenService")

local PlayerMods = {}
PlayerMods.__index = PlayerMods

local DEFAULT_WALKSPEED = 16
local DEFAULT_JUMPPOWER = 50
local FREECAM_STEP = "PlayerModsFreeCam"
local SPECTATE_STEP = "PlayerModsSpectate"
local CAMERA_PRIORITY = Enum.RenderPriority.Camera.Value + 1

local function camera()
	return Workspace.CurrentCamera
end

-- 0 - 100 "smoothing" slider -> how fast things catch up (higher rate = snappier)
local function smoothRate(pct)
	return 24 - 0.21 * math.clamp(pct, 0, 100)
end

local function unbind(name)
	pcall(RunService.UnbindFromRenderStep, RunService, name)
end

function PlayerMods.new()
	local self = setmetatable({}, PlayerMods)
	self.Player = Players.LocalPlayer
	self.Settings = {
		FlySpeed = 60,
		SprintMultiplier = 1.6,
		FreeCamSpeed = 50,
		FreeCamSensitivity = 0.3, -- degrees per mouse pixel
		FreeCamSmooth = 50, -- 0 = instant, 100 = very floaty
		FlySmooth = 60,
		FlyBoost = true, -- hold Left Shift while flying for 2x speed
		Glide = false, -- teleports slide to the target instead of snapping
		GlideTime = 0.45, -- seconds for a long glide
		FallSpeed = 30, -- slow fall: max downward speed (studs/s)
	} -- tuning values (kept on Reset)
	self.Values = {} -- user-chosen values (re-applied on respawn)
	self.Defaults = {
		Gravity = Workspace.Gravity,
		FOV = camera().FieldOfView,
		ClockTime = Lighting.ClockTime,
		MaxZoom = self.Player.CameraMaxZoomDistance,
	}
	self.Flying, self.Noclip, self.InfiniteJump = false, false, false
	self.Fullbright, self.ClickTeleport, self.SprintEnabled = false, false, false
	self.SlowFall, self.FreezeTime, self.NoFog = false, false, false
	self.Persist, self.AntiAFK = false, false
	self._slots = {} -- saved spots: [1..4] = CFrame
	self._started = os.clock()
	self._eases = setmetatable({}, { __mode = "k" })

	-- camera state: "Off" | "Free" | "Spectate"
	self.CamMode = "Off"
	self.SpectateTarget = nil
	self.SpectatePOV = false
	self.OnCameraChanged = nil -- optional callback(mode, target, pov) for the UI

	-- camera tracking: smoothly turns the camera toward the player nearest your cursor
	self.Track = {
		Enabled = false,
		Mode = "Hold Right Mouse", -- "Hold Right Mouse" | "Hold Left Mouse" | "Always"
		Part = "Head",
		Speed = 12, -- higher = snappier, lower = smoother
		FOV = 250, -- pixel radius around the cursor that can pick a target
		ShowFOV = false,
		TeamCheck = true,
		WallCheck = false,
		Priority = "Cursor", -- "Cursor" | "Distance" | "Health"
	}
	self._trackTarget = nil
	self._fovCircle = nil

	self._sprinting = false
	self._fps = 60
	self._conns = {}
	self._targetConns = {}
	self._noclipParts = {} -- [part] = original CanCollide
	self._flyObjects = {}
	self._camSaved = nil
	self._controlsDisabled = false

	local hum = self:_humanoid()
	if hum then self:_captureCharDefaults(hum) end

	self._conns.CharacterAdded = self.Player.CharacterAdded:Connect(function(char)
		self:_onCharacter(char)
	end)

	self._conns.JumpRequest = UserInputService.JumpRequest:Connect(function()
		if self.InfiniteJump and self.CamMode == "Off" then
			local h = self:_humanoid()
			if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
		end
	end)

	self._conns.InputBegan = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.LeftShift and self.SprintEnabled and self.CamMode == "Off" then
			self:_beginSprint()
		elseif input.UserInputType == Enum.UserInputType.MouseButton1
			and self.ClickTeleport and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
			self:_teleportToMouse()
		end
	end)

	self._conns.InputEnded = UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.LeftShift and self._sprinting then
			self:_endSprint()
		end
	end)

	self._conns.FPS = RunService.Heartbeat:Connect(function(dt)
		if dt > 0 then self._fps = self._fps * 0.9 + (1 / dt) * 0.1 end -- smoothed
	end)

	return self
end

function PlayerMods:_humanoid()
	local char = self.Player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

function PlayerMods:_root()
	local char = self.Player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- true while the player is typing in a TextBox (so keys don't also move the character / camera)
function PlayerMods:_typing()
	return UserInputService:GetFocusedTextBox() ~= nil
end

-- Remember what the game gave this character, so Reset restores *its* values (not hard-coded 16 / 50)
function PlayerMods:_captureCharDefaults(hum)
	self._charDefaults = {
		WalkSpeed = hum.WalkSpeed,
		JumpPower = hum.JumpPower,
		UseJumpPower = hum.UseJumpPower,
		HipHeight = hum.HipHeight,
	}
end

function PlayerMods:_onCharacter(char)
	local hum = char:WaitForChild("Humanoid")
	char:WaitForChild("HumanoidRootPart")
	self:_captureCharDefaults(hum)
	self._sprinting = false
	self:Apply()
	if self.Flying then -- old fly objects died with the old character
		self.Flying = false
		self:SetFly(true)
	end
	if self.Noclip then -- the old part list belongs to the old character
		self.Noclip = false
		self:SetNoclip(true)
	end
end

-- Re-applies every *user-set* value to the current character / world.
-- Anything the user never touched is left alone, so the game's own scripts keep working.
function PlayerMods:Apply()
	local hum = self:_humanoid()
	if hum then
		local speed = self.Values.WalkSpeed
		if self._sprinting then
			speed = (speed or self._preSprint or DEFAULT_WALKSPEED) * self.Settings.SprintMultiplier
		end
		if speed then hum.WalkSpeed = speed end
		if self.Values.JumpPower then
			hum.UseJumpPower = true
			hum.JumpPower = self.Values.JumpPower
		end
		if self.Values.HipHeight then hum.HipHeight = self.Values.HipHeight end
	end
	if self.Values.Gravity then Workspace.Gravity = self.Values.Gravity end
	if self.Values.FOV then camera().FieldOfView = self.Values.FOV end
	if self.Values.ClockTime then Lighting.ClockTime = self.Values.ClockTime end
	if self.Values.MaxZoom then self.Player.CameraMaxZoomDistance = self.Values.MaxZoom end
end

-- Smoothly tweens one property (a newer tween on the same property replaces the old one)
function PlayerMods:_ease(inst, prop, value, time)
	if not inst then return end
	local bucket = self._eases[inst]
	if not bucket then
		bucket = {}
		self._eases[inst] = bucket
	end
	if bucket[prop] then bucket[prop]:Cancel() end
	local tween = TweenService:Create(inst, TweenInfo.new(time or 0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { [prop] = value })
	bucket[prop] = tween
	tween:Play()
end

function PlayerMods:_cancelEase(inst, prop)
	local bucket = self._eases[inst]
	if bucket and bucket[prop] then
		bucket[prop]:Cancel()
		bucket[prop] = nil
	end
end

-- Simple value modifiers -------------------------------------------------------
function PlayerMods:SetWalkSpeed(v) self.Values.WalkSpeed = v; self:Apply() end
function PlayerMods:SetJumpPower(v) self.Values.JumpPower = v; self:Apply() end
function PlayerMods:SetGravity(v) self.Values.Gravity = v; self:Apply() end
function PlayerMods:SetFOV(v) self.Values.FOV = v; self:_ease(camera(), "FieldOfView", v, 0.18) end
function PlayerMods:SetHipHeight(v) self.Values.HipHeight = v; self:Apply() end
function PlayerMods:SetMaxZoom(v) self.Values.MaxZoom = v; self:Apply() end
function PlayerMods:SetTimeOfDay(v)
	self.Values.ClockTime = v
	if self.FreezeTime then
		self._frozenClock = v
		Lighting.ClockTime = v
	else
		self:_ease(Lighting, "ClockTime", v, 0.25)
	end
end
function PlayerMods:SetFlySpeed(v) self.Settings.FlySpeed = v end
function PlayerMods:SetFlySmooth(v) self.Settings.FlySmooth = v end
function PlayerMods:SetFlyBoost(on) self.Settings.FlyBoost = on end
function PlayerMods:SetFallSpeed(v) self.Settings.FallSpeed = v end
function PlayerMods:SetGlide(on) self.Settings.Glide = on end
function PlayerMods:SetGlideTime(seconds) self.Settings.GlideTime = seconds end

-- Puts one value back to what the game gave this character / world (and eases it there)
function PlayerMods:ResetValue(key)
	self.Values[key] = nil
	local hum, d = self:_humanoid(), self._charDefaults
	if key == "WalkSpeed" and hum then
		hum.WalkSpeed = d and d.WalkSpeed or DEFAULT_WALKSPEED
	elseif key == "JumpPower" and hum then
		hum.UseJumpPower = d and d.UseJumpPower or true
		hum.JumpPower = d and d.JumpPower or DEFAULT_JUMPPOWER
	elseif key == "HipHeight" and hum and d then
		hum.HipHeight = d.HipHeight
	elseif key == "Gravity" then
		Workspace.Gravity = self.Defaults.Gravity
	elseif key == "FOV" then
		self:_ease(camera(), "FieldOfView", self.Defaults.FOV, 0.25)
	elseif key == "ClockTime" then
		if self.FreezeTime then self._frozenClock = self.Defaults.ClockTime end
		self:_ease(Lighting, "ClockTime", self.Defaults.ClockTime, 0.3)
	elseif key == "MaxZoom" then
		self.Player.CameraMaxZoomDistance = self.Defaults.MaxZoom
	end
end

function PlayerMods:SetInfiniteJump(enabled)
	self.InfiniteJump = enabled
end

-- Sprint: hold LeftShift to run faster ------------------------------------------
function PlayerMods:SetSprint(enabled)
	self.SprintEnabled = enabled
	if not enabled and self._sprinting then self:_endSprint() end
end

function PlayerMods:SetSprintMultiplier(v)
	self.Settings.SprintMultiplier = v
	if self._sprinting then self:Apply() end
end

function PlayerMods:_beginSprint()
	local hum = self:_humanoid()
	if not hum or self._sprinting then return end
	self._preSprint = hum.WalkSpeed
	self._sprinting = true
	self:Apply()
end

function PlayerMods:_endSprint()
	self._sprinting = false
	local hum = self:_humanoid()
	if hum then
		hum.WalkSpeed = self.Values.WalkSpeed or self._preSprint
			or (self._charDefaults and self._charDefaults.WalkSpeed) or DEFAULT_WALKSPEED
	end
end

-- Click teleport: Ctrl + Click ----------------------------------------------------
function PlayerMods:SetClickTeleport(enabled)
	self.ClickTeleport = enabled
end

function PlayerMods:_teleportToMouse()
	local hrp = self:_root()
	local hum = self:_humanoid()
	local cam = camera()
	if not (hrp and cam) then return end
	local mouse = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(mouse.X, mouse.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Player.Character }
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	if result then
		-- stand ON the surface (hip height + half the root) instead of a flat +3 that can clip into floors
		local lift = (hum and hum.HipHeight or 2) + hrp.Size.Y / 2 + 0.5
		local rotation = hrp.CFrame - hrp.CFrame.Position -- keep facing direction
		self:TeleportTo(CFrame.new(result.Position + Vector3.new(0, lift, 0)) * rotation)
	end
end

-- Teleporting ---------------------------------------------------------------------
-- Every teleport goes through here: instant, or a smooth glide when Settings.Glide is on.
-- The spot you left is remembered so UndoTeleport can take you back.
function PlayerMods:TeleportTo(cf)
	local hrp = self:_root()
	if not hrp then return false end
	self._undoCFrame = hrp.CFrame

	if not self._glide then self._glideAnchored = hrp.Anchored end
	if self._glide then self._glide:Cancel() end

	if not self.Settings.Glide then
		self._glide = nil
		hrp.Anchored = self._glideAnchored or false
		hrp.CFrame = cf
		hrp.AssemblyLinearVelocity = Vector3.zero
		return true
	end

	local dist = (cf.Position - hrp.Position).Magnitude
	local time = math.max(0.12, self.Settings.GlideTime * math.clamp(dist / 150, 0.35, 1))
	local tween = TweenService:Create(hrp, TweenInfo.new(time, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { CFrame = cf })
	self._glide = tween
	hrp.Anchored = true
	tween.Completed:Once(function()
		if self._glide == tween then self._glide = nil end
		if hrp.Parent and not self._glide then
			hrp.Anchored = self._glideAnchored or false
			hrp.AssemblyLinearVelocity = Vector3.zero
		end
	end)
	tween:Play()
	return true
end

function PlayerMods:UndoTeleport()
	if not self._undoCFrame then return false end
	return self:TeleportTo(self._undoCFrame) -- the spot you leave becomes the new undo target
end

-- Saved spots (slots 1 - 4) ----------------------------------------------------------
function PlayerMods:SaveSlot(i)
	local hrp = self:_root()
	if not hrp then return false end
	self._slots[i] = hrp.CFrame
	return true
end

function PlayerMods:GoSlot(i)
	local cf = self._slots[i]
	if not cf then return false end
	return self:TeleportTo(cf)
end

function PlayerMods:GetSlot(i)
	local cf = self._slots[i]
	return cf and cf.Position or nil
end

-- (kept for older code: slot 1)
function PlayerMods:SavePosition() return self:SaveSlot(1) end
function PlayerMods:TeleportToSaved() return self:GoSlot(1) end

-- Teleport next to a player (a few studs behind them, facing them)
function PlayerMods:TeleportToPlayer(player)
	local char = player and player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	local pos = (root.CFrame * CFrame.new(0, 0, 4)).Position
	return self:TeleportTo(CFrame.lookAt(pos, root.Position))
end

-- dir = 1 / -1: hop through everyone else, alphabetical
function PlayerMods:TeleportStep(dir)
	local list = self:_otherPlayers()
	if #list == 0 then return nil end
	local index = table.find(list, self._tpTarget)
	index = index and (((index - 1 + dir) % #list) + 1) or (dir > 0 and 1 or #list)
	local target = list[index]
	self._tpTarget = target
	if self:TeleportToPlayer(target) then return target end
	return nil
end

function PlayerMods:Respawn()
	local hum = self:_humanoid()
	if hum then hum.Health = 0 end
end

-- Fullbright (fades in / out) ---------------------------------------------------
local BRIGHT = Color3.fromRGB(178, 178, 178)

function PlayerMods:SetFullbright(enabled)
	if enabled == self.Fullbright then return end
	self.Fullbright = enabled
	if enabled then
		self._lighting = {
			Brightness = Lighting.Brightness, GlobalShadows = Lighting.GlobalShadows,
			Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
		}
		Lighting.GlobalShadows = false
		self:_ease(Lighting, "Brightness", 2, 0.4)
		self:_ease(Lighting, "Ambient", BRIGHT, 0.4)
		self:_ease(Lighting, "OutdoorAmbient", BRIGHT, 0.4)
	elseif self._lighting then
		local saved = self._lighting
		self._lighting = nil
		Lighting.GlobalShadows = saved.GlobalShadows
		self:_ease(Lighting, "Brightness", saved.Brightness, 0.4)
		self:_ease(Lighting, "Ambient", saved.Ambient, 0.4)
		self:_ease(Lighting, "OutdoorAmbient", saved.OutdoorAmbient, 0.4)
	end
end

-- No fog: pushes the fog away and clears the Atmosphere haze --------------------------
function PlayerMods:SetNoFog(enabled)
	if enabled == self.NoFog then return end
	self.NoFog = enabled
	if enabled then
		self._fog = { FogStart = Lighting.FogStart, FogEnd = Lighting.FogEnd }
		Lighting.FogEnd = 100000
		local atmos = Lighting:FindFirstChildOfClass("Atmosphere")
		if atmos then
			self._fog.Atmosphere, self._fog.Density, self._fog.Haze = atmos, atmos.Density, atmos.Haze
			atmos.Density, atmos.Haze = 0, 0
		end
	elseif self._fog then
		local f = self._fog
		self._fog = nil
		Lighting.FogStart, Lighting.FogEnd = f.FogStart, f.FogEnd
		if f.Atmosphere and f.Atmosphere.Parent then
			f.Atmosphere.Density, f.Atmosphere.Haze = f.Density, f.Haze
		end
	end
end

local function dropConn(self, name)
	if self._conns[name] then
		self._conns[name]:Disconnect()
		self._conns[name] = nil
	end
end

-- Freeze time: holds the clock where it is (the game's day / night cycle stops) ------------
function PlayerMods:SetFreezeTime(enabled)
	self.FreezeTime = enabled
	dropConn(self, "FreezeTime")
	if not enabled then return end
	self:_cancelEase(Lighting, "ClockTime")
	self._frozenClock = self.Values.ClockTime or Lighting.ClockTime
	Lighting.ClockTime = self._frozenClock
	self._conns.FreezeTime = RunService.Heartbeat:Connect(function()
		Lighting.ClockTime = self._frozenClock
	end)
end

-- Slow fall: caps how fast you can fall -------------------------------------------------------
function PlayerMods:SetSlowFall(enabled)
	self.SlowFall = enabled
	dropConn(self, "SlowFall")
	if not enabled then return end
	self._conns.SlowFall = RunService.Heartbeat:Connect(function()
		local hrp = self:_root()
		if not hrp or self.Flying then return end
		local v = hrp.AssemblyLinearVelocity
		local limit = -self.Settings.FallSpeed
		if v.Y < limit then hrp.AssemblyLinearVelocity = Vector3.new(v.X, limit, v.Z) end
	end)
end

-- Keep values: some games keep resetting WalkSpeed / Gravity ... this puts your values back -
function PlayerMods:_enforce()
	local v = self.Values
	local hum = self:_humanoid()
	if hum then
		local speed = v.WalkSpeed
		if self._sprinting then
			speed = (speed or self._preSprint or DEFAULT_WALKSPEED) * self.Settings.SprintMultiplier
		end
		if speed and math.abs(hum.WalkSpeed - speed) > 0.01 then hum.WalkSpeed = speed end
		if v.JumpPower and (not hum.UseJumpPower or math.abs(hum.JumpPower - v.JumpPower) > 0.01) then
			hum.UseJumpPower = true
			hum.JumpPower = v.JumpPower
		end
		if v.HipHeight and math.abs(hum.HipHeight - v.HipHeight) > 0.01 then hum.HipHeight = v.HipHeight end
	end
	if v.Gravity and math.abs(Workspace.Gravity - v.Gravity) > 0.01 then Workspace.Gravity = v.Gravity end
	if v.MaxZoom and self.Player.CameraMaxZoomDistance ~= v.MaxZoom then self.Player.CameraMaxZoomDistance = v.MaxZoom end
end

function PlayerMods:SetPersist(enabled)
	self.Persist = enabled
	dropConn(self, "Persist")
	if not enabled then return end
	local clock = 0
	self._conns.Persist = RunService.Heartbeat:Connect(function(dt)
		clock += dt
		if clock < 0.25 then return end
		clock = 0
		self:_enforce()
	end)
end

-- Anti-AFK: answers Roblox's idle check so you are not kicked after 20 minutes ----------------
function PlayerMods:SetAntiAFK(enabled)
	self.AntiAFK = enabled
	dropConn(self, "AntiAFK")
	if not enabled then return end
	self._conns.AntiAFK = self.Player.Idled:Connect(function()
		pcall(function()
			local vu = game:GetService("VirtualUser")
			vu:CaptureController()
			vu:ClickButton2(Vector2.zero)
		end)
	end)
end

function PlayerMods:Rejoin()
	return (pcall(function()
		game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, game.JobId, self.Player)
	end))
end

-- Live stats (for a HUD / info page) -------------------------------------------
function PlayerMods:GetStats()
	local ping = 0
	pcall(function()
		ping = StatsService.Network.ServerStatsItem["Data Ping"]:GetValue()
	end)
	local memory = 0
	pcall(function() memory = StatsService:GetTotalMemoryUsageMb() end)
	local hrp, hum = self:_root(), self:_humanoid()
	return {
		FPS = math.round(self._fps),
		Ping = math.round(ping),
		Memory = math.round(memory),
		Position = hrp and hrp.Position or Vector3.zero,
		Speed = hrp and math.round(hrp.AssemblyLinearVelocity.Magnitude) or 0,
		Health = hum and math.round(hum.Health) or 0,
		MaxHealth = hum and math.round(hum.MaxHealth) or 0,
		Players = #Players:GetPlayers(),
		MaxPlayers = Players.MaxPlayers,
		Session = math.floor(os.clock() - self._started),
	}
end

-- Noclip -----------------------------------------------------------------------
-- The part list is cached (and kept current via DescendantAdded) instead of
-- walking GetDescendants() on the whole character every single frame.
function PlayerMods:_trackNoclipPart(part)
	if part:IsA("BasePart") and self._noclipParts[part] == nil then
		self._noclipParts[part] = part.CanCollide
	end
end

function PlayerMods:SetNoclip(enabled)
	if enabled == self.Noclip then return end
	self.Noclip = enabled

	for _, name in { "Noclip", "NoclipAdded" } do
		if self._conns[name] then
			self._conns[name]:Disconnect()
			self._conns[name] = nil
		end
	end

	if enabled then
		table.clear(self._noclipParts)
		local char = self.Player.Character
		if char then
			for _, d in char:GetDescendants() do self:_trackNoclipPart(d) end
			self._conns.NoclipAdded = char.DescendantAdded:Connect(function(d)
				self:_trackNoclipPart(d)
			end)
		end
		self._conns.Noclip = RunService.Stepped:Connect(function()
			for part in self._noclipParts do
				if part.Parent then
					part.CanCollide = false
				else
					self._noclipParts[part] = nil
				end
			end
		end)
	else
		for part, original in self._noclipParts do
			if part.Parent then part.CanCollide = original end
		end
		table.clear(self._noclipParts)
	end
end

-- Fly (WASD + Space / LeftCtrl, relative to camera) ----------------------------
-- Smoothed acceleration, faces the camera direction, ignores keys while you type
-- in a TextBox and while the free cam / spectate camera is active.
function PlayerMods:SetFly(enabled)
	if enabled == self.Flying then return end
	self.Flying = enabled

	if self._conns.Fly then
		self._conns.Fly:Disconnect()
		self._conns.Fly = nil
	end
	for _, obj in self._flyObjects do obj:Destroy() end
	table.clear(self._flyObjects)

	local hum = self:_humanoid()
	if not enabled then
		if hum then hum.PlatformStand = false end
		return
	end

	local hrp = self:_root()
	if not (hum and hrp) then return end -- re-enabled after respawn by _onCharacter

	local attachment = Instance.new("Attachment")
	attachment.Parent = hrp

	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.MaxForce = math.huge
	velocity.VectorVelocity = Vector3.zero
	velocity.Parent = hrp

	local align = Instance.new("AlignOrientation") -- keeps the character upright, facing the camera
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = false
	align.MaxTorque = math.huge
	align.Responsiveness = 25
	align.CFrame = hrp.CFrame - hrp.CFrame.Position
	align.Parent = hrp

	self._flyObjects = { attachment, velocity, align }
	hum.PlatformStand = true

	local current = Vector3.zero
	self._conns.Fly = RunService.RenderStepped:Connect(function(dt)
		local cam = camera()
		local dir = Vector3.zero
		local active = self.CamMode == "Off" and not self:_typing()
		if active then
			local key = UserInputService.IsKeyDown
			if key(UserInputService, Enum.KeyCode.W) then dir += cam.CFrame.LookVector end
			if key(UserInputService, Enum.KeyCode.S) then dir -= cam.CFrame.LookVector end
			if key(UserInputService, Enum.KeyCode.D) then dir += cam.CFrame.RightVector end
			if key(UserInputService, Enum.KeyCode.A) then dir -= cam.CFrame.RightVector end
			if key(UserInputService, Enum.KeyCode.Space) then dir += Vector3.yAxis end
			if key(UserInputService, Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
		end
		local speed = self.Settings.FlySpeed
		if active and self.Settings.FlyBoost and UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
			speed *= 2
		end
		local goal = dir.Magnitude > 0 and dir.Unit * speed or Vector3.zero
		current = current:Lerp(goal, 1 - math.exp(-dt * smoothRate(self.Settings.FlySmooth)))
		velocity.VectorVelocity = current

		if active then
			local look = cam.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude > 0.01 then
				align.CFrame = CFrame.lookAt(Vector3.zero, flat)
			end
		end
	end)
end

-- Camera: shared plumbing -------------------------------------------------------
function PlayerMods:_notifyCamera()
	if self.OnCameraChanged then
		task.spawn(self.OnCameraChanged, self.CamMode, self.SpectateTarget, self.SpectatePOV)
	end
end

-- Roblox's own PlayerModule controls; disabled while the camera is detached so
-- WASD doesn't also walk your real character around.
function PlayerMods:_controls()
	if self._controlsModule == nil then
		local ok, result = pcall(function()
			local scripts = self.Player:WaitForChild("PlayerScripts", 5)
			local module = scripts:WaitForChild("PlayerModule", 5)
			return require(module):GetControls()
		end)
		self._controlsModule = ok and result or false
	end
	return self._controlsModule or nil
end

function PlayerMods:_saveCamera()
	if self._camSaved then return end
	local cam = camera()
	self._camSaved = {
		Type = cam.CameraType,
		Subject = cam.CameraSubject,
		CFrame = cam.CFrame,
		MouseBehavior = UserInputService.MouseBehavior,
	}
end

function PlayerMods:_clearTargetConns()
	for _, conn in self._targetConns do conn:Disconnect() end
	table.clear(self._targetConns)
end

function PlayerMods:_enterCamMode(mode)
	self:_saveCamera()
	unbind(FREECAM_STEP)
	unbind(SPECTATE_STEP)
	self:_clearTargetConns()
	if not self._controlsDisabled then
		local controls = self:_controls()
		if controls then
			controls:Disable()
			self._controlsDisabled = true
		end
	end
	self.CamMode = mode
	if mode ~= "Spectate" then self.SpectateTarget = nil end
end

-- Back to your own character and the game's normal camera.
function PlayerMods:StopCamera()
	unbind(FREECAM_STEP)
	unbind(SPECTATE_STEP)
	self:_clearTargetConns()

	local was = self.CamMode
	local saved = self._camSaved
	self._camSaved = nil
	self.CamMode = "Off"
	self.SpectateTarget = nil
	self._free = nil

	if saved then
		local cam = camera()
		if cam then
			cam.CameraSubject = self:_humanoid() or saved.Subject
			cam.CameraType = saved.Type
			if saved.Type == Enum.CameraType.Scriptable then cam.CFrame = saved.CFrame end
		end
		UserInputService.MouseBehavior = saved.MouseBehavior
	end

	if self._controlsDisabled then
		local controls = self:_controls()
		if controls then controls:Enable() end
		self._controlsDisabled = false
	end

	if was ~= "Off" then self:_notifyCamera() end
end

function PlayerMods:GetCameraStatus()
	if self.CamMode == "Free" then return "Camera: Free Cam" end
	if self.CamMode == "Spectate" and self.SpectateTarget then
		return "Camera: " .. self.SpectateTarget.DisplayName .. (self.SpectatePOV and " (POV)" or "")
	end
	return "Camera: Normal"
end

-- Free cam: hold Right Mouse to look, WASD move, E / Space up, Q down,
-- Shift = fast, Ctrl = slow --------------------------------------------------------
function PlayerMods:SetFreeCamSpeed(v) self.Settings.FreeCamSpeed = v end
function PlayerMods:SetFreeCamSensitivity(v) self.Settings.FreeCamSensitivity = v end
function PlayerMods:SetFreeCamSmooth(v) self.Settings.FreeCamSmooth = v end

function PlayerMods:SetFreeCam(enabled)
	if not enabled then
		if self.CamMode == "Free" then self:StopCamera() end
		return
	end
	if self.CamMode == "Free" then return end

	self:_enterCamMode("Free")
	local cam = camera()
	local pitch, yaw = cam.CFrame:ToOrientation()
	self._free = { Pos = cam.CFrame.Position, Pitch = pitch, Yaw = yaw, TPitch = pitch, TYaw = yaw, Vel = Vector3.zero }
	cam.CameraType = Enum.CameraType.Scriptable
	RunService:BindToRenderStep(FREECAM_STEP, CAMERA_PRIORITY, function(dt)
		self:_stepFreeCam(dt)
	end)
	self:_notifyCamera()
end

function PlayerMods:_stepFreeCam(dt)
	local cam, f = camera(), self._free
	if not (cam and f) then return end
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable -- some games keep resetting this
	end

	local typing = self:_typing()

	-- look (only while Right Mouse is held, so the cursor stays usable for the menu)
	if not typing and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		local delta = UserInputService:GetMouseDelta()
		local sens = math.rad(self.Settings.FreeCamSensitivity)
		f.TYaw -= delta.X * sens
		f.TPitch = math.clamp(f.TPitch - delta.Y * sens, math.rad(-89), math.rad(89))
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end

	-- the view eases toward where the mouse pointed (Smoothing = 0 follows instantly)
	local lookAlpha = 1 - math.exp(-dt * (40 - 0.35 * self.Settings.FreeCamSmooth))
	f.Yaw += (f.TYaw - f.Yaw) * lookAlpha
	f.Pitch += (f.TPitch - f.Pitch) * lookAlpha

	local rot = CFrame.fromOrientation(f.Pitch, f.Yaw, 0)

	-- move
	local move = Vector3.zero
	if not typing then
		local held = function(code) return UserInputService:IsKeyDown(code) end
		if held(Enum.KeyCode.W) then move += rot.LookVector end
		if held(Enum.KeyCode.S) then move -= rot.LookVector end
		if held(Enum.KeyCode.D) then move += rot.RightVector end
		if held(Enum.KeyCode.A) then move -= rot.RightVector end
		if held(Enum.KeyCode.E) or held(Enum.KeyCode.Space) then move += Vector3.yAxis end
		if held(Enum.KeyCode.Q) then move -= Vector3.yAxis end
	end

	local speed = self.Settings.FreeCamSpeed
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
		speed *= 3
	elseif UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		speed *= 0.25
	end

	local goal = move.Magnitude > 0 and move.Unit * speed or Vector3.zero
	f.Vel = f.Vel:Lerp(goal, 1 - math.exp(-dt * smoothRate(self.Settings.FreeCamSmooth))) -- smooth start / stop
	f.Pos += f.Vel * dt

	cam.CFrame = CFrame.new(f.Pos) * rot
end

-- Jump the free cam to a spot behind a player (turns Free Cam on if needed)
function PlayerMods:FocusFreeCam(player)
	local char = player and player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	if self.CamMode ~= "Free" then self:SetFreeCam(true) end
	local f = self._free
	if not f then return false end

	local from = root.CFrame * CFrame.new(0, 3, 12)
	local cf = CFrame.lookAt(from.Position, root.Position + Vector3.new(0, 1.5, 0))
	local pitch, yaw = cf:ToOrientation()
	f.Pos, f.Pitch, f.Yaw, f.Vel = cf.Position, pitch, yaw, Vector3.zero
	f.TPitch, f.TYaw = pitch, yaw
	return true
end

-- Spectate: view another player ----------------------------------------------------
-- Follow mode  = Roblox's normal orbit camera pivoting around them (right-drag / scroll).
-- POV mode     = first-person from their head. Other players' real camera angle isn't
--                replicated to you, so this uses the direction their head is facing.
function PlayerMods:_otherPlayers()
	local list = {}
	for _, p in Players:GetPlayers() do
		if p ~= self.Player then table.insert(list, p) end
	end
	table.sort(list, function(a, b) return a.Name:lower() < b.Name:lower() end)
	return list
end

function PlayerMods:GetPlayerNames()
	local names = {}
	for _, p in self:_otherPlayers() do table.insert(names, p.Name) end
	return names
end

function PlayerMods:FindPlayer(query)
	query = string.lower(query)
	if query == "" then return nil end
	local partial
	for _, p in self:_otherPlayers() do
		local name, display = p.Name:lower(), p.DisplayName:lower()
		if name == query or display == query then return p end
		if not partial and (name:sub(1, #query) == query or display:sub(1, #query) == query) then
			partial = p
		end
	end
	return partial
end

function PlayerMods:Spectate(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player")
		or player == self.Player or player.Parent ~= Players then
		return false
	end

	self:_enterCamMode("Spectate")
	self.SpectateTarget = player

	-- if they leave, hop to someone else (or go back to normal)
	self._targetConns = {
		Players.PlayerRemoving:Connect(function(leaving)
			if leaving ~= self.SpectateTarget then return end
			for _, other in self:_otherPlayers() do
				if other ~= leaving then
					self:Spectate(other)
					return
				end
			end
			self:StopCamera()
		end),
	}

	RunService:BindToRenderStep(SPECTATE_STEP, CAMERA_PRIORITY, function()
		self:_stepSpectate()
	end)
	self:_notifyCamera()
	return true
end

function PlayerMods:_stepSpectate()
	local cam, target = camera(), self.SpectateTarget
	if not (cam and target) then return end
	local char = target.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return end -- target is respawning; keep the last view until they're back

	if self.SpectatePOV then
		local head = char:FindFirstChild("Head")
		if head then
			if cam.CameraType ~= Enum.CameraType.Scriptable then
				cam.CameraType = Enum.CameraType.Scriptable
			end
			cam.CFrame = head.CFrame * CFrame.new(0, 0.2, -0.6)
		end
	else
		if cam.CameraType == Enum.CameraType.Scriptable then
			cam.CameraType = Enum.CameraType.Custom
		end
		if cam.CameraSubject ~= hum then -- also survives their respawn / the game resetting it
			cam.CameraSubject = hum
		end
	end
end

function PlayerMods:SetSpectatePOV(enabled)
	self.SpectatePOV = enabled
	if self.CamMode == "Spectate" then self:_notifyCamera() end
end

-- dir = 1 (next) or -1 (previous), cycling through everyone else in alphabetical order
function PlayerMods:SpectateStep(dir)
	local list = self:_otherPlayers()
	if #list == 0 then return nil end
	local index = table.find(list, self.SpectateTarget)
	if index then
		index = ((index - 1 + dir) % #list) + 1
	else
		index = dir > 0 and 1 or #list
	end
	local nextPlayer = list[index]
	self:Spectate(nextPlayer)
	return nextPlayer
end

function PlayerMods:SpectateNext() return self:SpectateStep(1) end
function PlayerMods:SpectatePrev() return self:SpectateStep(-1) end

-- Camera tracking -------------------------------------------------------------------
-- While active, the camera smoothly turns toward the player closest to your cursor
-- (inside the FOV circle). The target stays locked until you release the key.
-- Paused automatically while free cam / spectate is on.
local TRACK_STEP = "PlayerModsTrack"
local HAS_DRAWING = Drawing ~= nil and Drawing.new ~= nil

function PlayerMods:SetTrackOption(key, value)
	self.Track[key] = value
	if key == "ShowFOV" and not value then self:_hideFovCircle() end
	if key == "Part" then self._trackTarget = nil end
end

function PlayerMods:SetTracking(enabled)
	self.Track.Enabled = enabled
	unbind(TRACK_STEP)
	self._trackTarget = nil
	if enabled then
		RunService:BindToRenderStep(TRACK_STEP, CAMERA_PRIORITY + 1, function(dt)
			self:_stepTrack(dt)
		end)
	else
		self:_hideFovCircle()
	end
end

function PlayerMods:GetTrackTarget()
	return self._trackTarget
end

function PlayerMods:_trackPart(player)
	local char = player.Character
	if not char then return nil end
	return char:FindFirstChild(self.Track.Part) or char:FindFirstChild("HumanoidRootPart")
end

function PlayerMods:_trackable(player)
	if player == self.Player then return false end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return false end
	if self.Track.TeamCheck and player.Team ~= nil and player.Team == self.Player.Team then
		return false
	end
	return true
end

function PlayerMods:_lineClear(cam, part)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Player.Character, part.Parent }
	local origin = cam.CFrame.Position
	return Workspace:Raycast(origin, part.Position - origin, params) == nil
end

function PlayerMods:_pickTrackTarget(cam, mouse)
	local best, bestScore
	for _, p in Players:GetPlayers() do
		if self:_trackable(p) then
			local part = self:_trackPart(p)
			if part then
				local v, onScreen = cam:WorldToViewportPoint(part.Position)
				if onScreen then
					local d = (Vector2.new(v.X, v.Y) - mouse).Magnitude
					if d <= self.Track.FOV and (not self.Track.WallCheck or self:_lineClear(cam, part)) then
						-- lower score wins
						local score = d
						if self.Track.Priority == "Distance" then
							score = (part.Position - cam.CFrame.Position).Magnitude
						elseif self.Track.Priority == "Health" then
							local hum = p.Character:FindFirstChildOfClass("Humanoid")
							score = hum and hum.Health or math.huge
						end
						if not bestScore or score < bestScore then best, bestScore = p, score end
					end
				end
			end
		end
	end
	return best
end

function PlayerMods:_hideFovCircle()
	if self._fovCircle then self._fovCircle.Visible = false end
end

function PlayerMods:_drawFovCircle(mouse, dt)
	if not (self.Track.ShowFOV and HAS_DRAWING) then
		self:_hideFovCircle()
		return
	end
	if not self._fovCircle then
		local c = Drawing.new("Circle")
		c.Thickness = 1
		c.NumSides = 64
		c.Filled = false
		c.Color = Color3.new(1, 1, 1)
		self._fovCircle = c
	end
	-- the ring warms up while a target is locked and relaxes when it is released
	local goal = self._trackTarget and 1 or 0
	local lock = self._lock or 0
	lock += (goal - lock) * (1 - math.exp(-(dt or 0.016) * 14))
	self._lock = lock
	self._fovCircle.Color = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(90, 255, 130), lock)
	self._fovCircle.Thickness = 1 + lock
	self._fovCircle.Position = mouse
	self._fovCircle.Radius = self.Track.FOV
	self._fovCircle.Visible = true
end

function PlayerMods:_stepTrack(dt)
	local t = self.Track
	local cam = camera()
	if not (t.Enabled and cam) or self.CamMode ~= "Off" then
		self._trackTarget = nil
		self:_hideFovCircle()
		return
	end

	local mouse = UserInputService:GetMouseLocation()
	self:_drawFovCircle(mouse, dt)

	local active = t.Mode == "Always"
		or (t.Mode == "Hold Right Mouse" and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2))
		or (t.Mode == "Hold Left Mouse" and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1))
	if not active or self:_typing() then
		self._trackTarget = nil -- released: next press picks a fresh target
		return
	end

	local target = self._trackTarget
	if not (target and self:_trackable(target) and self:_trackPart(target)) then
		target = self:_pickTrackTarget(cam, mouse)
		self._trackTarget = target
	end
	if not target then return end

	local part = self:_trackPart(target)
	local goal = CFrame.lookAt(cam.CFrame.Position, part.Position)
	local alpha = 1 - math.exp(-dt * t.Speed) -- frame-rate independent smoothing
	cam.CFrame = cam.CFrame:Lerp(goal, alpha)
end

-- Reset everything back to normal ------------------------------------------------
function PlayerMods:Reset()
	self:StopCamera()
	self:SetTracking(false)
	self:SetFly(false)
	self:SetNoclip(false)
	self:SetFullbright(false)
	self:SetNoFog(false)
	self:SetFreezeTime(false)
	self:SetSlowFall(false)
	self:SetPersist(false)
	self:SetAntiAFK(false)
	self.InfiniteJump = false
	self.ClickTeleport = false
	self:SetSprint(false)

	local had = self.Values
	self.Values = {}

	local hum = self:_humanoid()
	local d = self._charDefaults
	if hum then
		hum.WalkSpeed = d and d.WalkSpeed or DEFAULT_WALKSPEED
		hum.UseJumpPower = d and d.UseJumpPower or true
		hum.JumpPower = d and d.JumpPower or DEFAULT_JUMPPOWER
		if d then hum.HipHeight = d.HipHeight end
	end
	if had.Gravity then Workspace.Gravity = self.Defaults.Gravity end
	if had.FOV then self:_ease(camera(), "FieldOfView", self.Defaults.FOV, 0.3) end
	if had.ClockTime then self:_ease(Lighting, "ClockTime", self.Defaults.ClockTime, 0.3) end
	if had.MaxZoom then self.Player.CameraMaxZoomDistance = self.Defaults.MaxZoom end
end

function PlayerMods:Destroy()
	self:Reset()
	if self._fovCircle then
		pcall(function() self._fovCircle:Remove() end)
		self._fovCircle = nil
	end
	for _, conn in self._conns do conn:Disconnect() end
	table.clear(self._conns)
end

return PlayerMods

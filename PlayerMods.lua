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

local PlayerMods = {}
PlayerMods.__index = PlayerMods

local DEFAULT_WALKSPEED = 16
local DEFAULT_JUMPPOWER = 50

function PlayerMods.new()
	local self = setmetatable({}, PlayerMods)
	self.Player = Players.LocalPlayer
	self.Settings = { FlySpeed = 60, SprintMultiplier = 1.6 } -- tuning values (kept on Reset)
	self.Values = {}                                          -- user-chosen values (re-applied on respawn)
	self.Defaults = {
		Gravity = Workspace.Gravity,
		FOV = Workspace.CurrentCamera.FieldOfView,
		ClockTime = Lighting.ClockTime,
		MaxZoom = self.Player.CameraMaxZoomDistance,
	}
	self.Flying, self.Noclip, self.InfiniteJump = false, false, false
	self.Fullbright, self.ClickTeleport, self.SprintEnabled = false, false, false
	self._sprinting = false
	self._fps = 60
	self._conns = {}
	self._noclipParts = {}
	self._flyObjects = {}

	local hum = self:_humanoid()
	if hum then self._defaultHip = hum.HipHeight end

	self._conns.CharacterAdded = self.Player.CharacterAdded:Connect(function(char)
		self:_onCharacter(char)
	end)

	self._conns.JumpRequest = UserInputService.JumpRequest:Connect(function()
		if self.InfiniteJump then
			local h = self:_humanoid()
			if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
		end
	end)

	self._conns.InputBegan = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.LeftShift and self.SprintEnabled then
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

function PlayerMods:_onCharacter(char)
	local hum = char:WaitForChild("Humanoid")
	char:WaitForChild("HumanoidRootPart")
	self._defaultHip = hum.HipHeight
	self._sprinting = false
	self:Apply()
	if self.Flying then -- old fly objects died with the old character
		self.Flying = false
		self:SetFly(true)
	end
end

-- Re-applies every stored value to the current character / world
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
	Workspace.Gravity = self.Values.Gravity or self.Defaults.Gravity
	Workspace.CurrentCamera.FieldOfView = self.Values.FOV or self.Defaults.FOV
	if self.Values.ClockTime then Lighting.ClockTime = self.Values.ClockTime end
	self.Player.CameraMaxZoomDistance = self.Values.MaxZoom or self.Defaults.MaxZoom
end

-- Simple value modifiers -------------------------------------------------------
function PlayerMods:SetWalkSpeed(v) self.Values.WalkSpeed = v; self:Apply() end
function PlayerMods:SetJumpPower(v) self.Values.JumpPower = v; self:Apply() end
function PlayerMods:SetGravity(v)   self.Values.Gravity = v;   self:Apply() end
function PlayerMods:SetFOV(v)       self.Values.FOV = v;       self:Apply() end
function PlayerMods:SetHipHeight(v) self.Values.HipHeight = v; self:Apply() end
function PlayerMods:SetMaxZoom(v)   self.Values.MaxZoom = v;   self:Apply() end
function PlayerMods:SetTimeOfDay(v) self.Values.ClockTime = v; self:Apply() end
function PlayerMods:SetFlySpeed(v)  self.Settings.FlySpeed = v end

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
	if hum then hum.WalkSpeed = self.Values.WalkSpeed or self._preSprint or DEFAULT_WALKSPEED end
end

-- Click teleport: Ctrl + Click ----------------------------------------------------
function PlayerMods:SetClickTeleport(enabled)
	self.ClickTeleport = enabled
end

function PlayerMods:_teleportToMouse()
	local hrp = self:_root()
	local cam = Workspace.CurrentCamera
	if not (hrp and cam) then return end
	local mouse = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(mouse.X, mouse.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Player.Character }
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	if result then
		hrp.CFrame = CFrame.new(result.Position + Vector3.new(0, 3, 0))
	end
end

-- Saved position ------------------------------------------------------------------
function PlayerMods:SavePosition()
	local hrp = self:_root()
	if not hrp then return false end
	self._saved = hrp.CFrame
	return true
end

function PlayerMods:TeleportToSaved()
	local hrp = self:_root()
	if not (hrp and self._saved) then return false end
	hrp.CFrame = self._saved
	return true
end

function PlayerMods:Respawn()
	local hum = self:_humanoid()
	if hum then hum.Health = 0 end
end

-- Fullbright --------------------------------------------------------------------
function PlayerMods:SetFullbright(enabled)
	if enabled == self.Fullbright then return end
	self.Fullbright = enabled
	if enabled then
		self._lighting = {
			Brightness = Lighting.Brightness, GlobalShadows = Lighting.GlobalShadows,
			Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient, FogEnd = Lighting.FogEnd,
		}
		Lighting.Brightness = 2
		Lighting.GlobalShadows = false
		Lighting.Ambient = Color3.fromRGB(178, 178, 178)
		Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
		Lighting.FogEnd = 100000
	elseif self._lighting then
		for prop, value in self._lighting do Lighting[prop] = value end
		self._lighting = nil
	end
end

-- Live stats (for a HUD / info page) -------------------------------------------
function PlayerMods:GetStats()
	local ping = 0
	pcall(function()
		ping = StatsService.Network.ServerStatsItem["Data Ping"]:GetValue()
	end)
	local hrp = self:_root()
	return {
		FPS = math.round(self._fps),
		Ping = math.round(ping),
		Position = hrp and hrp.Position or Vector3.zero,
		Speed = hrp and math.round(hrp.AssemblyLinearVelocity.Magnitude) or 0,
	}
end

-- Noclip -----------------------------------------------------------------------
function PlayerMods:SetNoclip(enabled)
	if enabled == self.Noclip then return end
	self.Noclip = enabled
	if self._conns.Noclip then
		self._conns.Noclip:Disconnect()
		self._conns.Noclip = nil
	end
	if enabled then
		self._conns.Noclip = RunService.Stepped:Connect(function()
			local char = self.Player.Character
			if not char then return end
			for _, part in char:GetDescendants() do
				if part:IsA("BasePart") and part.CanCollide then
					part.CanCollide = false
					self._noclipParts[part] = true
				end
			end
		end)
	else
		for part in self._noclipParts do
			if part.Parent then part.CanCollide = true end
		end
		table.clear(self._noclipParts)
	end
end

-- Fly (WASD + Space / LeftCtrl, relative to camera) ----------------------------
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
	self._flyObjects = { attachment, velocity }
	hum.PlatformStand = true

	self._conns.Fly = RunService.RenderStepped:Connect(function()
		local cam = Workspace.CurrentCamera
		local dir = Vector3.zero
		local key = UserInputService.IsKeyDown
		if key(UserInputService, Enum.KeyCode.W) then dir += cam.CFrame.LookVector end
		if key(UserInputService, Enum.KeyCode.S) then dir -= cam.CFrame.LookVector end
		if key(UserInputService, Enum.KeyCode.D) then dir += cam.CFrame.RightVector end
		if key(UserInputService, Enum.KeyCode.A) then dir -= cam.CFrame.RightVector end
		if key(UserInputService, Enum.KeyCode.Space) then dir += Vector3.yAxis end
		if key(UserInputService, Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
		velocity.VectorVelocity = dir.Magnitude > 0 and dir.Unit * self.Settings.FlySpeed or Vector3.zero
	end)
end

-- Reset everything back to normal ------------------------------------------------
function PlayerMods:Reset()
	self:SetFly(false)
	self:SetNoclip(false)
	self:SetFullbright(false)
	self.InfiniteJump = false
	self.ClickTeleport = false
	self:SetSprint(false)
	self.Values = {}

	local hum = self:_humanoid()
	if hum then
		hum.WalkSpeed = DEFAULT_WALKSPEED
		hum.UseJumpPower = true
		hum.JumpPower = DEFAULT_JUMPPOWER
		if self._defaultHip then hum.HipHeight = self._defaultHip end
	end
	Workspace.Gravity = self.Defaults.Gravity
	Workspace.CurrentCamera.FieldOfView = self.Defaults.FOV
	Lighting.ClockTime = self.Defaults.ClockTime
	self.Player.CameraMaxZoomDistance = self.Defaults.MaxZoom
end

function PlayerMods:Destroy()
	self:Reset()
	for _, conn in self._conns do conn:Disconnect() end
	table.clear(self._conns)
end

return PlayerMods

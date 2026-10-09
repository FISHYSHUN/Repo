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
local FREECAM_STEP = "PlayerModsFreeCam"
local SPECTATE_STEP = "PlayerModsSpectate"
local CAMERA_PRIORITY = Enum.RenderPriority.Camera.Value + 1

local function camera()
	return Workspace.CurrentCamera
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

-- Simple value modifiers -------------------------------------------------------
function PlayerMods:SetWalkSpeed(v) self.Values.WalkSpeed = v; self:Apply() end
function PlayerMods:SetJumpPower(v) self.Values.JumpPower = v; self:Apply() end
function PlayerMods:SetGravity(v) self.Values.Gravity = v; self:Apply() end
function PlayerMods:SetFOV(v) self.Values.FOV = v; self:Apply() end
function PlayerMods:SetHipHeight(v) self.Values.HipHeight = v; self:Apply() end
function PlayerMods:SetMaxZoom(v) self.Values.MaxZoom = v; self:Apply() end
function PlayerMods:SetTimeOfDay(v) self.Values.ClockTime = v; self:Apply() end
function PlayerMods:SetFlySpeed(v) self.Settings.FlySpeed = v end

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
		hrp.CFrame = CFrame.new(result.Position + Vector3.new(0, lift, 0)) * rotation
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
		local goal = dir.Magnitude > 0 and dir.Unit * self.Settings.FlySpeed or Vector3.zero
		current = current:Lerp(goal, math.clamp(dt * 12, 0, 1))
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

function PlayerMods:SetFreeCam(enabled)
	if not enabled then
		if self.CamMode == "Free" then self:StopCamera() end
		return
	end
	if self.CamMode == "Free" then return end

	self:_enterCamMode("Free")
	local cam = camera()
	local pitch, yaw = cam.CFrame:ToOrientation()
	self._free = { Pos = cam.CFrame.Position, Pitch = pitch, Yaw = yaw, Vel = Vector3.zero }
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
		f.Yaw -= delta.X * sens
		f.Pitch = math.clamp(f.Pitch - delta.Y * sens, math.rad(-89), math.rad(89))
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end

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
	f.Vel = f.Vel:Lerp(goal, math.clamp(dt * 12, 0, 1)) -- smooth start / stop
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
	local best, bestDist
	for _, p in Players:GetPlayers() do
		if self:_trackable(p) then
			local part = self:_trackPart(p)
			if part then
				local v, onScreen = cam:WorldToViewportPoint(part.Position)
				if onScreen then
					local d = (Vector2.new(v.X, v.Y) - mouse).Magnitude
					if d <= self.Track.FOV and (not bestDist or d < bestDist)
						and (not self.Track.WallCheck or self:_lineClear(cam, part)) then
						best, bestDist = p, d
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

function PlayerMods:_drawFovCircle(mouse)
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
	self:_drawFovCircle(mouse)

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
	if had.FOV then camera().FieldOfView = self.Defaults.FOV end
	if had.ClockTime then Lighting.ClockTime = self.Defaults.ClockTime end
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

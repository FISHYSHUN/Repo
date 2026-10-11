-- modules/Guard.lua
-- Client-side watch + shield. Knows nothing about the GUI.
--   Watch  : scores other players for speed / fly / teleport / fling / constant spin.
--            Repeat offenders get flagged, and each player + cheat type is announced ONCE.
--   Shield : player collision off (no pushing / flinging), anti-fling (spin / launch clamp),
--            anti-void, blocks forced teleports.
-- It only sees what replicates to this client. It cannot stop an exploiter from touching the server.
local import = ...

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SAMPLE = 0.2           -- seconds between checks of other players
local GRACE = 3              -- seconds ignored after a player (re)spawns
local STRIKE_GAP = 0.9       -- one strike per kind per this many seconds
local STRIKE_DECAY = 15      -- strikes reset after this long without a new one
local TELEPORT_DISTANCE = 90 -- studs in one sample
local FLY_TIME = 2.5         -- seconds airborne without falling
local FLING_SPIN = 100       -- rad/s
local FLING_SPEED = 300      -- studs/s
local SNAP_DISTANCE = 60     -- studs in one frame (own character)
local SELF_SPIN = 60         -- rad/s (own character)
local SPIN_SAMPLES = 6       -- samples kept for the spin check (6 x 0.2s = 1.2s window)
local SPIN_STEADY = 0.25     -- max spread (std dev / mean) that still counts as "constant"
local LOG_MAX = 50

-- settings that start / stop a connection when they change
local SYNC_KEYS = { Monitor = true, AntiFling = true, AntiVoid = true, AntiSnap = true, NoCollide = true }

local Guard = {}
Guard.__index = Guard

function Guard.new()
	local self = setmetatable({}, Guard)
	self.Player = Players.LocalPlayer
	self.Settings = {
		Monitor = false, Alerts = true,
		Speed = true, Fly = true, Teleport = true, Fling = true, Spin = true,
		SpeedTolerance = 200, -- % of the player's WalkSpeed
		SpinMin = 10,         -- rad/s average needed to count as spinning
		StrikesToFlag = 4,
		NoCollide = false,    -- other players' parts stop colliding with you
		AntiFling = false, AntiVoid = false, AntiSnap = false,
		MaxSelfSpeed = 250,
	}
	self.OnFlag = nil    -- callback(player, kind, detail), once per player + kind, respects Alerts
	self.OnChange = nil  -- callback(), any time the flag list changes
	self.OnAlert = nil   -- callback(text), shield events
	self.IsExempt = nil  -- function() -> true while your own tools move the character
	self._tracks, self._flagged, self._order, self._log, self._conns = {}, {}, {}, {}, {}
	self._allowUntil, self._acc, self._lastAlert = 0, 0, 0
	self._lastPos, self._lastChar, self._safe, self._safeClock = nil, nil, nil, 0
	self._announced = setmetatable({}, { __mode = "k" }) -- [player] = { [kind] = true }
	self._disabled = setmetatable({}, { __mode = "k" })  -- parts whose CanCollide we turned off
	return self
end

function Guard:Set(key, value)
	self.Settings[key] = value
	if SYNC_KEYS[key] then self:_sync() end
end

function Guard:_sync()
	local s = self.Settings

	local needBeat = s.Monitor or s.AntiFling or s.AntiVoid or s.AntiSnap
	if needBeat and not self._conns.Beat then
		self._conns.Beat = RunService.Heartbeat:Connect(function(dt) self:_beat(dt) end)
	elseif not needBeat and self._conns.Beat then
		self._conns.Beat:Disconnect()
		self._conns.Beat = nil
	end

	-- collisions: its own switch, and Anti-Fling turns it on too
	local needCollide = s.NoCollide or s.AntiFling
	if needCollide and not self._conns.Stepped then
		self._conns.Stepped = RunService.Stepped:Connect(function() self:_noCollide() end)
	elseif not needCollide and self._conns.Stepped then
		self._conns.Stepped:Disconnect()
		self._conns.Stepped = nil
		self:_restoreCollide()
	end

	if not s.Monitor then table.clear(self._tracks) end
end

-- tell the guard a teleport / move is yours (seconds of immunity)
function Guard:Allow(seconds)
	self._allowUntil = math.max(self._allowUntil, os.clock() + (seconds or 1.5))
end

function Guard:_exempt()
	if os.clock() < self._allowUntil then return true end
	return self.IsExempt ~= nil and self.IsExempt() == true
end

function Guard:_alert(text)
	if os.clock() - self._lastAlert < 3 then return end
	self._lastAlert = os.clock()
	if self.Settings.Alerts and self.OnAlert then self.OnAlert(text) end
end

function Guard:_beat(dt)
	local s = self.Settings
	if s.Monitor then self:_watch(dt) end
	if s.AntiFling or s.AntiVoid or s.AntiSnap then self:_self() end
end

-- SHIELD ------------------------------------------------------------------------
local function disable(self, part)
	if part:IsA("BasePart") and part.CanCollide then
		part.CanCollide = false
		self._disabled[part] = true
	end
end

-- Other players' body parts (and the handles of tools they hold) stop colliding with you, so they
-- cannot push or fling you. It runs every Stepped, before physics, because the Humanoid turns
-- collision back on every frame. Only parts that were colliding are touched, so accessories keep
-- their own CanCollide = false.
function Guard:_noCollide()
	for _, p in Players:GetPlayers() do
		local char = p ~= self.Player and p.Character
		if char then
			for _, child in char:GetChildren() do
				if child:IsA("BasePart") then
					disable(self, child)
				elseif child:IsA("Tool") then
					local handle = child:FindFirstChild("Handle")
					if handle then disable(self, handle) end
				end
			end
		end
	end
end

function Guard:_restoreCollide()
	for part in self._disabled do
		if part.Parent then part.CanCollide = true end
	end
	table.clear(self._disabled)
end

function Guard:_self()
	local s = self.Settings
	local char = self.Player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or hum.Health <= 0 then
		self._lastPos, self._lastChar = nil, nil
		return
	end
	if char ~= self._lastChar then -- new character: start over
		self._lastChar, self._lastPos = char, root.Position
		self._safe, self._safeClock = nil, os.clock() + 1
		return
	end

	local exempt = self:_exempt()
	local pos = root.Position

	if s.AntiSnap and not exempt and self._lastPos and (pos - self._lastPos).Magnitude > SNAP_DISTANCE then
		root.CFrame = root.CFrame - pos + self._lastPos
		root.AssemblyLinearVelocity = Vector3.zero
		pos = self._lastPos
		self:_alert("Blocked a forced teleport")
	end

	if s.AntiFling and not exempt then
		if root.AssemblyLinearVelocity.Magnitude > s.MaxSelfSpeed or root.AssemblyAngularVelocity.Magnitude > SELF_SPIN then
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			self:_alert("Stopped a fling")
		end
	end

	if s.AntiVoid then
		if hum.FloorMaterial ~= Enum.Material.Air and os.clock() >= self._safeClock then
			self._safe, self._safeClock = root.CFrame, os.clock() + 0.5
		end
		if pos.Y < Workspace.FallenPartsDestroyHeight + 60 and self._safe then
			root.CFrame = self._safe + Vector3.new(0, 4, 0)
			root.AssemblyLinearVelocity = Vector3.zero
			pos = root.Position
			self:_alert("Pulled out of the void")
		end
	end

	self._lastPos = pos
end

-- WATCH -------------------------------------------------------------------------
function Guard:_watch(dt)
	self._acc += dt
	if self._acc < SAMPLE then return end
	local elapsed = self._acc
	self._acc = 0
	local now = os.clock()
	for _, p in Players:GetPlayers() do
		if p ~= self.Player then self:_check(p, elapsed, now) end
	end
	for p in self._tracks do
		if p.Parent ~= Players then self._tracks[p] = nil end
	end
end

local function yawOf(root)
	local look = root.CFrame.LookVector
	return math.atan2(look.X, look.Z)
end

function Guard:_check(p, dt, now)
	local s = self.Settings
	local char = p.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or hum.Health <= 0 then
		self._tracks[p] = nil
		return
	end

	local yaw = yawOf(root)
	local t = self._tracks[p]
	if not t or t.Char ~= char then -- new character: grace period, fresh counters
		self._tracks[p] = {
			Char = char, Pos = root.Position, Since = now + GRACE, Air = 0, Strikes = {}, Last = {},
			Yaw = yaw, Spin = {},
		}
		return
	end

	local pos = root.Position
	local delta = pos - t.Pos
	t.Pos = pos
	-- turn since the last sample, wrapped to -pi..pi (always updated, so it never goes stale)
	local dyaw = (yaw - t.Yaw + math.pi) % (2 * math.pi) - math.pi
	t.Yaw = yaw

	if now < t.Since then return end
	if hum.SeatPart ~= nil or hum.Sit then
		t.Air = 0
		table.clear(t.Spin) -- vehicles and seats can spin on their own
		return
	end

	if delta.Magnitude > TELEPORT_DISTANCE then
		if s.Teleport then
			self:_strike(p, t, "Teleport", ("%.0f studs in %.1fs"):format(delta.Magnitude, dt), now)
		end
		table.clear(t.Spin)
		return
	end

	local flat = Vector3.new(delta.X, 0, delta.Z).Magnitude / dt
	local allowed = math.max(hum.WalkSpeed, 16) * s.SpeedTolerance / 100 + 6
	if s.Speed and flat > allowed then
		self:_strike(p, t, "Speed", ("%.0f studs/s (allowed %.0f)"):format(flat, allowed), now)
	end

	local vel = root.AssemblyLinearVelocity
	if hum.FloorMaterial == Enum.Material.Air and vel.Y > -8 and hum:GetState() ~= Enum.HumanoidStateType.Climbing then
		t.Air += dt
	else
		t.Air = 0
	end
	if s.Fly and t.Air > FLY_TIME then
		t.Air = 0
		self:_strike(p, t, "Fly", ("airborne %.1fs without falling"):format(FLY_TIME), now)
	end

	-- spin rate: the larger of the physics value and the measured turn between samples.
	-- The measured turn is only reliable below ~15 rad/s at a 0.2s sample; above that the physics value covers it.
	local angular = root.AssemblyAngularVelocity.Magnitude
	local spinRate = math.max(math.abs(dyaw) / dt, angular)

	if s.Fling and (angular > FLING_SPIN or vel.Magnitude > FLING_SPEED) then
		self:_strike(p, t, "Fling", ("spin %.0f / speed %.0f"):format(angular, vel.Magnitude), now)
		table.clear(t.Spin) -- a fling is reported as a fling, not also as a spin
	elseif s.Spin then
		local h = t.Spin
		table.insert(h, spinRate)
		if #h > SPIN_SAMPLES then table.remove(h, 1) end
		if #h == SPIN_SAMPLES then
			local sum = 0
			for _, v in h do sum += v end
			local mean = sum / #h
			if mean >= s.SpinMin then
				local var = 0
				for _, v in h do var += (v - mean) ^ 2 end
				-- the same rate the whole window = not a player turning
				if math.sqrt(var / #h) / mean <= SPIN_STEADY then
					self:_strike(p, t, "Spin", ("constant spin %.0f rad/s"):format(mean), now)
				end
			end
		end
	else
		table.clear(t.Spin)
	end
end

function Guard:_strike(p, t, kind, detail, now)
	local last = t.Last[kind] or 0
	if now - last < STRIKE_GAP then return end
	if now - last > STRIKE_DECAY then t.Strikes[kind] = 0 end
	t.Last[kind] = now
	t.Strikes[kind] = (t.Strikes[kind] or 0) + 1
	if t.Strikes[kind] >= self.Settings.StrikesToFlag then
		t.Strikes[kind] = 0
		self:_flag(p, kind, detail, now)
	end
end

function Guard:_flag(p, kind, detail, now)
	local rec = self._flagged[p]
	if not rec then
		rec = { Player = p, Kinds = {}, Count = 0 }
		self._flagged[p] = rec
		table.insert(self._order, p)
	end
	rec.Kinds[kind] = now
	rec.Count += 1
	rec.Last, rec.Detail = kind, detail

	table.insert(self._log, { Name = p.Name, Kind = kind, Detail = detail, Time = os.time() })
	if #self._log > LOG_MAX then table.remove(self._log, 1) end

	if self.OnChange then self.OnChange() end

	-- one message per player + cheat type (until Clear Flags).
	-- If Alerts is off the pair is not marked, so it is announced once Alerts is back on and they trip it again.
	local seen = self._announced[p]
	if not seen then
		seen = {}
		self._announced[p] = seen
	end
	if not seen[kind] and self.Settings.Alerts and self.OnFlag then
		seen[kind] = true
		self.OnFlag(p, kind, detail)
	end
end

-- results -------------------------------------------------------------------------
function Guard:GetFlagged()
	local list = {}
	for _, p in self._order do
		if p.Parent == Players then
			table.insert(list, p)
		else
			self._flagged[p] = nil
		end
	end
	self._order = list
	return table.clone(list)
end

function Guard:IsFlagged(p) return self._flagged[p] ~= nil end
function Guard:GetRecord(p) return self._flagged[p] end
function Guard:GetLog() return table.clone(self._log) end

function Guard:ClearFlags()
	table.clear(self._flagged)
	table.clear(self._order)
	table.clear(self._log)
	table.clear(self._announced)
	if self.OnChange then self.OnChange() end
end

function Guard:Destroy()
	for _, conn in self._conns do conn:Disconnect() end
	table.clear(self._conns)
	table.clear(self._tracks)
	self:_restoreCollide()
end

return Guard

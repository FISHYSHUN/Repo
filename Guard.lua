-- modules/Guard.lua
-- Client-side watch + shield. Knows nothing about the GUI.
--   Watch  : scores other players for speed / fly / teleport / fling / constant spin / noclip.
--            Repeat offenders get flagged (red outline highlight), and each player + cheat type is
--            announced ONCE. Many filters keep ordinary players from being flagged (see FALSE POSITIVES).
--   Shield : player collision off (all players, or only flagged ones), anti-fling, anti-void,
--            blocks forced teleports, removes forces other scripts attach to your character.
-- It only sees what replicates to this client. It cannot stop an exploiter from touching the server.
local import = ...

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CoreGui = game:GetService("CoreGui")

local SAMPLE = 0.2           -- seconds between checks of other players
local GRACE = 3              -- seconds ignored after a player (re)spawns
local STRIKE_GAP = 0.9       -- one strike per kind per this many seconds
local STRIKE_DECAY = 15      -- strikes reset after this long without a new one
local TELEPORT_DISTANCE = 90 -- studs in one sample
local FLY_TIME = 2.5         -- seconds airborne without falling (scaled up in low gravity)
local FLING_SPIN = 100       -- rad/s
local FLING_SPEED = 300      -- studs/s
local SNAP_DISTANCE = 60     -- studs in one frame (own character)
local SELF_SPIN = 60         -- rad/s (own character)
local SPIN_SAMPLES = 6       -- samples kept for the spin check (6 x 0.2s = 1.2s window)
local SPIN_STEADY = 0.25     -- max spread (std dev / mean) that still counts as "constant"
local LOG_MAX = 50

-- FALSE POSITIVES ----------------------------------------------------------------
local MAX_PING = 0.4         -- s: while YOUR ping is above this, nobody is judged (replication bunches up)
local HITCH = 0.5            -- s: a frame this long on your side pauses the watch
local RESUME = 1             -- s: extra pause after a hitch / ping spike
local MASS_TP = 0.4          -- if this share of players "teleports" in one sample it is a game event
local SEAT_GRACE = 2         -- s: jumps right after leaving a seat / vehicle are ignored
local WALK_MEMORY = 3        -- s: the highest recent WalkSpeed counts (sprint scripts, speed boosts)
local VICTIM_RADIUS = 25     -- studs: a fast, spinning player next to a faster spinner is a fling victim
local PROX_DISTANCE = 35     -- studs: flagged player this close to you raises an alert
local PROX_COOLDOWN = 20     -- s between proximity alerts per player

-- extra strikes a kind needs on top of StrikesToFlag (weaker evidence = more proof)
local EXTRA = { Fly = 1, Spin = 1, Noclip = 2 }

-- states where a player's motion is not under their own control
local UNSTABLE = {
	[Enum.HumanoidStateType.Ragdoll] = true,
	[Enum.HumanoidStateType.FallingDown] = true,
	[Enum.HumanoidStateType.PlatformStanding] = true,
	[Enum.HumanoidStateType.Physics] = true,
	[Enum.HumanoidStateType.GettingUp] = true,
}

-- forces other scripts can attach to your character to drag / launch you
local FORCE_CLASSES = {
	"BodyMover", "RocketPropulsion", "AlignPosition", "AlignOrientation",
	"LinearVelocity", "AngularVelocity", "VectorForce", "LineForce", "Torque",
}

-- settings that start / stop a connection when they change
local SYNC_KEYS = {
	Monitor = true, AntiFling = true, AntiVoid = true, AntiSnap = true, AntiAttach = true,
	NoCollide = true, IsolateFlagged = true,
}

local function guiParent()
	local ok, ui = pcall(function() return gethui and gethui() end)
	if ok and typeof(ui) == "Instance" then return ui end
	return CoreGui
end

local Guard = {}
Guard.__index = Guard

function Guard.new()
	local self = setmetatable({}, Guard)
	self.Player = Players.LocalPlayer
	self.Settings = {
		Monitor = false, Alerts = true,
		Speed = true, Fly = true, Teleport = true, Fling = true, Spin = true,
		Noclip = false,       -- experimental: walking through thick solid walls
		SpeedTolerance = 200, -- % of the player's WalkSpeed
		SpinMin = 10,         -- rad/s average needed to count as spinning
		StrikesToFlag = 4,
		-- fewer mistakes
		SmartFilter = true,   -- pause on lag, ignore mass teleports, spare fling victims
		IgnoreFriends = true, -- never judge your Roblox friends
		AutoUnflag = 120,     -- seconds without a new strike before a flag expires (0 = never)
		-- flagged players
		Highlight = true,     -- red outline on flagged players
		HighlightColor = Color3.fromRGB(255, 40, 40),
		HighlightFill = 1,    -- fill transparency (1 = see-through, only the outline shows)
		ProximityAlert = true,
		-- shield
		NoCollide = false,    -- other players' parts stop colliding with you
		IsolateFlagged = false, -- same, but ONLY for flagged players (regular players stay solid)
		AntiFling = false, AntiVoid = false, AntiSnap = false,
		AntiAttach = false,   -- remove body movers / constraints other scripts add to your root
		MaxSelfSpeed = 250,
	}
	self.OnFlag = nil    -- callback(player, kind, detail), once per player + kind, respects Alerts
	self.OnChange = nil  -- callback(), any time the flag list changes
	self.OnAlert = nil   -- callback(text), shield events
	self.IsExempt = nil  -- function() -> true while your own tools move the character
	self._tracks, self._flagged, self._order, self._log, self._conns = {}, {}, {}, {}, {}
	self._hl = {}        -- [player] = { Hl = Highlight, Conn = CharacterAdded connection }
	self._folder = nil
	self._allowUntil, self._acc, self._lastAlert, self._pauseUntil = 0, 0, 0, 0
	self._lastPos, self._lastChar, self._safe, self._safeClock = nil, nil, nil, 0
	self._rayParams = RaycastParams.new()
	self._rayParams.FilterType = Enum.RaycastFilterType.Exclude
	self._announced = setmetatable({}, { __mode = "k" }) -- [player] = { [kind] = true }
	self._disabled = setmetatable({}, { __mode = "k" })  -- parts whose CanCollide we turned off
	self._trusted = setmetatable({}, { __mode = "k" })   -- [player] = true (never judged)
	self._friends = setmetatable({}, { __mode = "k" })   -- [player] = true / false (cached)
	self._near = setmetatable({}, { __mode = "k" })      -- [player] = last proximity alert time
	self._conns.Leave = Players.PlayerRemoving:Connect(function(p) self:_forget(p) end)
	return self
end

function Guard:Set(key, value)
	self.Settings[key] = value
	if SYNC_KEYS[key] then self:_sync() end
	if key == "Highlight" or key == "HighlightColor" or key == "HighlightFill" then
		self:_applyHighlights()
	end
end

function Guard:_sync()
	local s = self.Settings

	local needBeat = s.Monitor or s.AntiFling or s.AntiVoid or s.AntiSnap or s.AntiAttach
	if needBeat and not self._conns.Beat then
		self._conns.Beat = RunService.Heartbeat:Connect(function(dt) self:_beat(dt) end)
	elseif not needBeat and self._conns.Beat then
		self._conns.Beat:Disconnect()
		self._conns.Beat = nil
	end

	-- collisions: its own switch, Anti-Fling turns it on too, Isolate Flagged is the gentle version
	local needCollide = s.NoCollide or s.AntiFling or s.IsolateFlagged
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

-- returns true when the alert was actually sent
function Guard:_alert(text)
	if os.clock() - self._lastAlert < 3 then return false end
	if not (self.Settings.Alerts and self.OnAlert) then return false end
	self._lastAlert = os.clock()
	self.OnAlert(text)
	return true
end

function Guard:_beat(dt)
	local s = self.Settings
	if s.Monitor then self:_watch(dt) end
	if s.AntiFling or s.AntiVoid or s.AntiSnap or s.AntiAttach then self:_self() end
end

-- TRUST -------------------------------------------------------------------------
-- Trust = "this is a regular player": never judged again, flag removed.
function Guard:Trust(p)
	self._trusted[p] = true
	self._tracks[p] = nil
	self:Unflag(p)
end

function Guard:Untrust(p) self._trusted[p] = nil end
function Guard:IsTrusted(p) return self._trusted[p] == true end

function Guard:_isTrusted(p)
	if self._trusted[p] then return true end
	if self.Settings.IgnoreFriends then
		local f = self._friends[p]
		if f == nil then
			self._friends[p] = false -- pending; IsFriendsWith yields, so it is looked up on the side
			task.spawn(function()
				local ok, res = pcall(function() return self.Player:IsFriendsWith(p.UserId) end)
				self._friends[p] = ok and res == true
			end)
			return false
		end
		return f
	end
	return false
end

-- HIGHLIGHT ---------------------------------------------------------------------
-- Red outline, see-through fill. Independent from the ESP, so it works with ESP off.
function Guard:_unhighlight(p)
	local e = self._hl[p]
	if not e then return end
	self._hl[p] = nil
	if e.Conn then e.Conn:Disconnect() end
	if e.Hl then e.Hl:Destroy() end
end

function Guard:_highlight(p)
	local s = self.Settings
	if not (s.Highlight and self._flagged[p] and p.Parent == Players) then
		self:_unhighlight(p)
		return
	end
	local e = self._hl[p]
	if not e then
		if not (self._folder and self._folder.Parent) then
			self._folder = Instance.new("Folder")
			self._folder.Name = "PlayerMenuGuard"
			self._folder.Parent = guiParent()
		end
		local hl = Instance.new("Highlight")
		hl.Name = "Flagged_" .. p.Name
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.OutlineTransparency = 0
		hl.Parent = self._folder
		e = { Hl = hl }
		e.Conn = p.CharacterAdded:Connect(function(char) hl.Adornee = char end)
		self._hl[p] = e
	end
	e.Hl.FillColor = s.HighlightColor
	e.Hl.OutlineColor = s.HighlightColor
	e.Hl.FillTransparency = s.HighlightFill
	e.Hl.Adornee = p.Character
end

function Guard:_applyHighlights()
	for p in self._hl do
		if not self._flagged[p] or not self.Settings.Highlight then self:_unhighlight(p) end
	end
	for p in self._flagged do self:_highlight(p) end
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
-- NoCollide / Anti-Fling affect everyone; Isolate Flagged only affects flagged players.
function Guard:_noCollide()
	local s = self.Settings
	local everyone = s.NoCollide or s.AntiFling
	for _, p in Players:GetPlayers() do
		local char = p ~= self.Player and (everyone or self._flagged[p]) and p.Character
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

-- give one player's parts their collision back (they stopped being flagged)
function Guard:_restorePlayer(p)
	local char = p.Character
	if not char then return end
	for part in self._disabled do
		if part.Parent and part:IsDescendantOf(char) then
			part.CanCollide = true
			self._disabled[part] = nil
		end
	end
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

	-- forces someone else attached to your root (grab / drag / launch tools). Seats and your own tools are exempt.
	if s.AntiAttach and not exempt and hum.SeatPart == nil then
		for _, child in root:GetChildren() do
			for _, class in FORCE_CLASSES do
				if child:IsA(class) then
					child:Destroy()
					self:_alert("Removed a foreign force from your character")
					break
				end
			end
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
	local s = self.Settings
	if dt > HITCH then self._pauseUntil = os.clock() + RESUME end
	self._acc += dt
	if self._acc < SAMPLE then return end
	local elapsed = self._acc
	self._acc = 0
	local now = os.clock()

	-- your own lag makes everyone look like they teleport / speed: judge nobody, start fresh afterwards
	if s.SmartFilter then
		local ok, ping = pcall(function() return self.Player:GetNetworkPing() end)
		if now < self._pauseUntil or (ok and ping > MAX_PING) then
			table.clear(self._tracks)
			return
		end
	end

	if s.Noclip then
		local chars = {}
		for _, p in Players:GetPlayers() do
			if p.Character then table.insert(chars, p.Character) end
		end
		self._rayParams.FilterDescendantsInstances = chars
	end

	local ctx = { count = 0, jumps = {} }
	for _, p in Players:GetPlayers() do
		if p ~= self.Player then self:_check(p, elapsed, now, ctx) end
	end

	-- teleports are judged together: a round start / map change moves many players at once
	if #ctx.jumps > 0 then
		local mass = s.SmartFilter and #ctx.jumps >= 3 and #ctx.jumps >= ctx.count * MASS_TP
		if not mass then
			for _, j in ctx.jumps do self:_strike(j.p, j.t, "Teleport", j.detail, now) end
		end
	end

	for p in self._tracks do
		if p.Parent ~= Players then self._tracks[p] = nil end
	end

	-- flags expire when the player stays clean
	if s.AutoUnflag > 0 then
		local expired = {}
		for p, rec in self._flagged do
			if now - rec.At > s.AutoUnflag then table.insert(expired, p) end
		end
		for _, p in expired do self:Unflag(p) end
	end

	-- a flagged player close to you
	if s.ProximityAlert and next(self._flagged) then
		local mine = self.Player.Character and self.Player.Character:FindFirstChild("HumanoidRootPart")
		if mine then
			for p in self._flagged do
				local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
				if r and (r.Position - mine.Position).Magnitude < PROX_DISTANCE
					and now - (self._near[p] or -math.huge) > PROX_COOLDOWN then
					if self:_alert(p.DisplayName .. " (flagged) is close") then self._near[p] = now end
				end
			end
		end
	end
end

local function yawOf(root)
	local look = root.CFrame.LookVector
	return math.atan2(look.X, look.Z)
end

-- true when a thick, solid, anchored wall lies between two positions
function Guard:_throughWall(a, b)
	local r = Workspace:Raycast(a, b - a, self._rayParams)
	if not r then return false end
	local part = r.Instance
	if part:IsA("Terrain") or not part.CanCollide or not part.Anchored or part.Transparency >= 0.9 then
		return false
	end
	local sz = part.Size
	if math.min(sz.X, sz.Y, sz.Z) < 2 then return false end -- thin parts / fences / doors in motion
	if (b - r.Position).Magnitude < 2 then return false end -- just pressed against it
	return true
end

-- a fast / spinning player right next to someone spinning even harder is most likely the one being flung
function Guard:_isVictim(p, root, myAngular)
	for _, other in Players:GetPlayers() do
		if other ~= p and other ~= self.Player then
			local oroot = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
			if oroot and (oroot.Position - root.Position).Magnitude < VICTIM_RADIUS then
				local oang = oroot.AssemblyAngularVelocity.Magnitude
				if oang > FLING_SPIN * 0.6 and oang > myAngular then return true end
			end
		end
	end
	return false
end

function Guard:_check(p, dt, now, ctx)
	local s = self.Settings
	local char = p.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or hum.Health <= 0 or self:_isTrusted(p) then
		self._tracks[p] = nil
		return
	end

	local yaw = yawOf(root)
	local t = self._tracks[p]
	-- new character, or the player was missing for a while (streaming): grace period, fresh counters
	if not t or t.Char ~= char or now - t.Time > SAMPLE * 5 then
		self._tracks[p] = {
			Char = char, Pos = root.Position, Time = now, Since = now + GRACE, Air = 0, Strikes = {}, Last = {},
			Yaw = yaw, Spin = {}, Walk = hum.WalkSpeed, WalkAt = now, SeatAt = -math.huge, StateAt = -math.huge,
		}
		return
	end

	local prev = t.Pos
	local pos = root.Position
	local delta = pos - prev
	t.Pos, t.Time = pos, now
	-- turn since the last sample, wrapped to -pi..pi (always updated, so it never goes stale)
	local dyaw = (yaw - t.Yaw + math.pi) % (2 * math.pi) - math.pi
	t.Yaw = yaw

	-- the highest WalkSpeed seen lately counts, so sprint / boost scripts do not look like speeding
	if hum.WalkSpeed >= t.Walk or now - t.WalkAt > WALK_MEMORY then
		t.Walk, t.WalkAt = hum.WalkSpeed, now
	end

	local state = hum:GetState()
	local seated = hum.SeatPart ~= nil or hum.Sit
	if seated then t.SeatAt = now end
	if UNSTABLE[state] then t.StateAt = now end
	local unstable = now - t.StateAt < 1.5 -- ragdoll / knocked down / getting up: not their own movement

	if now < t.Since then return end
	if seated then
		t.Air = 0
		table.clear(t.Spin) -- vehicles and seats can spin on their own
		return
	end

	ctx.count += 1

	if delta.Magnitude > TELEPORT_DISTANCE then
		-- not judged here: check() collects jumps so a mass teleport can be recognised
		if s.Teleport and now - t.SeatAt > SEAT_GRACE then
			table.insert(ctx.jumps, {
				p = p, t = t, detail = ("%.0f studs in %.1fs"):format(delta.Magnitude, dt),
			})
		end
		table.clear(t.Spin)
		return
	end

	if s.Noclip and not unstable and delta.Magnitude > 3 and self:_throughWall(prev, pos) then
		self:_strike(p, t, "Noclip", "passed through a solid wall", now)
	end

	local flat = Vector3.new(delta.X, 0, delta.Z).Magnitude / dt
	local allowed = math.max(t.Walk, 16) * s.SpeedTolerance / 100 + 6
	if s.Speed and not unstable and flat > allowed then
		self:_strike(p, t, "Speed", ("%.0f studs/s (allowed %.0f)"):format(flat, allowed), now)
	end

	-- swimming and climbing look like "airborne without falling", so they are skipped.
	-- Low-gravity maps fall slower, so the limit grows with weaker gravity.
	local vel = root.AssemblyLinearVelocity
	local gravityScale = math.clamp(math.sqrt(196.2 / math.max(Workspace.Gravity, 1)), 1, 5)
	local floating = state == Enum.HumanoidStateType.Swimming or state == Enum.HumanoidStateType.Climbing
	if hum.FloorMaterial == Enum.Material.Air and vel.Y > -8 and not floating and not unstable then
		t.Air += dt
	else
		t.Air = 0
	end
	if s.Fly and t.Air > FLY_TIME * gravityScale then
		t.Air = 0
		self:_strike(p, t, "Fly", ("airborne %.1fs without falling"):format(FLY_TIME * gravityScale), now)
	end

	-- spin rate: the larger of the physics value and the measured turn between samples.
	-- The measured turn is only reliable below ~15 rad/s at a 0.2s sample; above that the physics value covers it.
	local angular = root.AssemblyAngularVelocity.Magnitude
	local spinRate = math.max(math.abs(dyaw) / dt, angular)

	if s.Fling and (angular > FLING_SPIN or vel.Magnitude > FLING_SPEED) then
		table.clear(t.Spin) -- a fling is reported as a fling, not also as a spin
		if not (s.SmartFilter and self:_isVictim(p, root, angular)) then
			self:_strike(p, t, "Fling", ("spin %.0f / speed %.0f"):format(angular, vel.Magnitude), now)
		end
	elseif s.Spin and not unstable then
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
	-- weaker evidence (fly, spin, noclip) needs more strikes than speed / teleport / fling
	if t.Strikes[kind] >= self.Settings.StrikesToFlag + (EXTRA[kind] or 0) then
		t.Strikes[kind] = 0
		self:_flag(p, kind, detail, now)
	end
end

function Guard:_flag(p, kind, detail, now)
	if self._trusted[p] then return end
	local rec = self._flagged[p]
	if not rec then
		rec = { Player = p, Kinds = {}, Count = 0, At = now }
		self._flagged[p] = rec
		table.insert(self._order, p)
	end
	rec.Kinds[kind] = now
	rec.Count += 1
	rec.At = now
	rec.Last, rec.Detail = kind, detail

	table.insert(self._log, { Name = p.Name, Kind = kind, Detail = detail, Time = os.time() })
	if #self._log > LOG_MAX then table.remove(self._log, 1) end

	self:_highlight(p)
	if self.OnChange then self.OnChange() end

	-- one message per player + cheat type (until Clear Flags / Unflag).
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

-- removes one player's flag (highlight, collision isolation, announcements) and returns true if there was one
function Guard:Unflag(p)
	if not self._flagged[p] then return false end
	self._flagged[p] = nil
	local i = table.find(self._order, p)
	if i then table.remove(self._order, i) end
	self._announced[p] = nil
	self._near[p] = nil
	self._tracks[p] = nil
	self:_unhighlight(p)
	local s = self.Settings
	if not (s.NoCollide or s.AntiFling) then self:_restorePlayer(p) end
	if self.OnChange then self.OnChange() end
	return true
end

function Guard:_forget(p)
	self._tracks[p] = nil
	self._trusted[p] = nil
	self._friends[p] = nil
	if self._flagged[p] then
		self._flagged[p] = nil
		local i = table.find(self._order, p)
		if i then table.remove(self._order, i) end
		self._announced[p] = nil
		if self.OnChange then self.OnChange() end
	end
	self:_unhighlight(p)
end

-- results -------------------------------------------------------------------------
function Guard:GetFlagged()
	local list = {}
	for _, p in self._order do
		if p.Parent == Players then
			table.insert(list, p)
		else
			self._flagged[p] = nil
			self:_unhighlight(p)
		end
	end
	self._order = list
	return table.clone(list)
end

function Guard:IsFlagged(p) return self._flagged[p] ~= nil end
function Guard:GetRecord(p) return self._flagged[p] end
function Guard:GetLog() return table.clone(self._log) end

-- "Speed, Fly" style summary of what a player was flagged for
function Guard:Describe(p)
	local rec = self._flagged[p]
	if not rec then return "" end
	local kinds = {}
	for kind in rec.Kinds do table.insert(kinds, kind) end
	table.sort(kinds)
	return table.concat(kinds, ", ")
end

function Guard:ClearFlags()
	for p in self._hl do self:_unhighlight(p) end
	table.clear(self._flagged)
	table.clear(self._order)
	table.clear(self._log)
	table.clear(self._announced)
	table.clear(self._near)
	local s = self.Settings
	if not (s.NoCollide or s.AntiFling) then self:_restoreCollide() end
	if self.OnChange then self.OnChange() end
end

function Guard:Destroy()
	for _, conn in self._conns do conn:Disconnect() end
	table.clear(self._conns)
	table.clear(self._tracks)
	for p in self._hl do self:_unhighlight(p) end
	if self._folder then
		self._folder:Destroy()
		self._folder = nil
	end
	self:_restoreCollide()
end

return Guard

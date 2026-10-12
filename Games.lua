-- modules/Games.lua  (merged: MM2 + NDS + Games)
-- local Games = import("Games");  Games.Detect(), Games.Is(id), Games.List, Games.MM2 / Games.NDS (the helper classes)
local import = ...

-- ======== MM2 (merged) ========
local MM2 = (function(...)
-- modules/MM2.lua
-- Murder Mystery 2 helpers. Knows nothing about the GUI. Client-side only.
--   Role ESP     : Murderer / Sheriff (and optionally innocents) highlighted. A role is learned from the tool
--                  a player holds (Knife / Gun), which is all the client can see, and remembered until that
--                  player respawns. Someone who never equips their tool stays unknown.
--   Tracers      : lines from the bottom of the screen to known Murderer / Sheriff (needs the Drawing API).
--   Proximity    : callback + cooldown when the Murderer comes within a set distance of you.
--   Gun drop     : highlights the dropped gun, announces it, can fetch it (manually or automatically).
--   Auto coins   : walks through the coins of the round, one at a time (Teleport or Walk mode).
--   Coin ESP     : highlights the coins that are still on the map.
--   No delay     : coins are taken back to back and ProximityPrompts (hold-to-interact) become instant.
--   Movement     : walk speed, jump power, noclip, infinite jump, anti-AFK.
--   Navigation   : teleport to a player / role, save a safe spot and jump to it, spectate a player / role.
--   No shoot delay: re-equips the Gun right after each shot to reset the tool's own client-side cooldown.
--   Knife hitbox : while you hold the Knife, its Handle is scaled to a cube of HitboxSize studs (Massless, no
--                  collision) so stabs connect from further away. Original size is restored on unequip / off.
--   Trap ESP     : highlights the Murderer's traps lying on the map.
--   Safe farm    : AutoCoins skips coins that sit close to the Murderer.
-- Instance names (Knife, Gun, GunDrop, CoinContainer, Coin_Server, Trap) are from memory of the game and can
-- change in an update: if something stops working, check the names in the Explorer and edit the constants.
local import = ...

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")

local KNIFE, GUN = "Knife", "Gun"
local GUN_DROP = "GunDrop"
local COIN_CONTAINER, COIN = "CoinContainer", "Coin_Server"
local TRAP = "Trap"
-- Highlight instances are capped by the engine (31 at a time): ~12 players + gun + traps + coins must fit
local MAX_COIN_HL = 14
local MAX_TRAP_HL = 4

local COLORS = {
	Murderer = Color3.fromRGB(255, 60, 60),
	Sheriff = Color3.fromRGB(70, 140, 255),
	Innocent = Color3.fromRGB(90, 220, 120),
	Gun = Color3.fromRGB(255, 210, 60),
	Coin = Color3.fromRGB(255, 200, 40),
	Trap = Color3.fromRGB(255, 120, 40),
}

local hasDrawing = pcall(function() return Drawing.new end) and Drawing ~= nil

local MM2 = {}
MM2.__index = MM2

local function myRoot(self)
	local char = self.Player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function guiParent()
	local ok, ui = pcall(function() return gethui and gethui() end)
	if ok and ui then return ui end
	return CoreGui
end

local function toolRole(container)
	if not container then return nil end
	if container:FindFirstChild(KNIFE) then return "Murderer" end
	if container:FindFirstChild(GUN) then return "Sheriff" end
	return nil
end

local function partOf(inst)
	if inst:IsA("BasePart") then return inst end
	if inst:IsA("Model") then return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true) end
	return nil
end

function MM2.new()
	local self = setmetatable({}, MM2)
	self.Player = Players.LocalPlayer
	self.Settings = {
		RoleESP = false, Innocents = false, Tags = true,
		Tracers = false, TrapESP = false,
		Proximity = false, ProximityDistance = 35,          -- studs
		GunESP = false, Alerts = true, ReturnAfterGun = true,
		AutoGrabGun = false,
		CoinESP = false,
		AutoCoins = false, CoinDelay = 700,                 -- ms between coins
		SafeFarm = false, SafeDistance = 40,                -- AutoCoins skips coins this close to the Murderer
		Hitbox = false, HitboxSize = 12, HitboxShow = false, -- Knife handle cube (studs); Show = visible instead of invisible
		CoinMode = "Teleport",                              -- "Teleport" | "Walk"
		NoShootDelay = false,                               -- see _syncUtil; client-side only
		NoDelay = false,                                    -- no wait between coins + instant prompts
		SpeedOn = false, Speed = 24,
		JumpOn = false, Jump = 60,
		Noclip = false, InfJump = false, AntiAFK = false,
	}
	self.Safe = nil     -- saved CFrame, see SetSafeSpot
	self.Roles = {}                                    -- [player] = "Murderer" | "Sheriff"
	self.Stats = { Coins = 0 }                         -- coins attempted by AutoCoins
	self._chars = setmetatable({}, { __mode = "k" })   -- last character seen per player (a new one clears the role)
	self._hl = {}                                      -- [player] = { Highlight, Billboard, Label }
	self._coinHl = {}                                  -- [coin part] = Highlight
	self._trapHl = {}                                  -- [trap] = Highlight
	self._hb = {}                                      -- [knife Handle] = original properties (Hitbox)
	self._tracers = {}                                 -- [player] = Drawing line
	self._visited = setmetatable({}, { __mode = "k" }) -- coins already tried
	self._proxT = 0
	self._prompts = setmetatable({}, { __mode = "k" }) -- [prompt] = original HoldDuration
	self._conns = {}                                   -- named connections of the movement / no-delay features
	self.Teleport = nil -- function(cf) -> bool  (set this so your own teleport + guard exemption is used)
	self.OnRole = nil   -- callback(player, role)
	self.OnGun = nil    -- callback(part)
	self.OnProximity = nil -- callback(player, distance)  (the Murderer got close)
	self.OnCoin = nil      -- callback(total)  (AutoCoins went for another coin)
	self._acc, self._gunT = 0, 0
	return self
end

local UTIL_KEYS = {
	NoShootDelay = true, NoDelay = true, SpeedOn = true, JumpOn = true, Noclip = true, InfJump = true, AntiAFK = true,
	Speed = true, Jump = true, Hitbox = true, HitboxSize = true, HitboxShow = true,
}

function MM2:Set(key, value)
	self.Settings[key] = value
	if UTIL_KEYS[key] then self:_syncUtil() end
	if key == "RoleESP" or key == "GunESP" or key == "AutoCoins" or key == "CoinESP"
		or key == "Tracers" or key == "Proximity" or key == "AutoGrabGun" or key == "TrapESP" then
		self:_sync()
	end
end

function MM2:_sync()
	local s = self.Settings
	local need = s.RoleESP or s.GunESP or s.CoinESP or s.Proximity or s.AutoGrabGun or s.TrapESP
	if need and not self._beatConn then
		if not self._folder then
			self._folder = Instance.new("Folder")
			self._folder.Name = "PlayerMenuMM2"
			self._folder.Parent = guiParent()
		end
		self._beatConn = RunService.Heartbeat:Connect(function(dt) self:_beat(dt) end)
	elseif not need and self._beatConn then
		self._beatConn:Disconnect()
		self._beatConn = nil
		self:_clearVisuals()
	end

	-- tracers run every frame, and roles are still scanned by the beat, so keep it alive for them too
	if s.Tracers and hasDrawing then
		if not self._beatConn then
			self._beatConn = RunService.Heartbeat:Connect(function(dt) self:_beat(dt) end)
		end
		if not self._tracerConn then
			self._tracerConn = RunService.RenderStepped:Connect(function() self:_renderTracers() end)
		end
	elseif self._tracerConn then
		self._tracerConn:Disconnect()
		self._tracerConn = nil
		self:_clearTracers()
		if not need and self._beatConn then
			self._beatConn:Disconnect()
			self._beatConn = nil
		end
	end

	if s.AutoCoins and not self._coinRun then task.spawn(function() self:_coinLoop() end) end
end

function MM2:_clearTracers()
	for p, line in self._tracers do
		pcall(function() line:Remove() end)
		self._tracers[p] = nil
	end
end

function MM2:_clearVisuals()
	for p, e in self._hl do
		e.Highlight:Destroy()
		e.Billboard:Destroy()
		self._hl[p] = nil
	end
	for c, hl in self._coinHl do
		hl:Destroy()
		self._coinHl[c] = nil
	end
	for t, hl in self._trapHl do
		hl:Destroy()
		self._trapHl[t] = nil
	end
	if self._gunHl then self._gunHl:Destroy(); self._gunHl = nil end
	self._gun = nil
	if self._folder then self._folder:Destroy(); self._folder = nil end
end

-- ROLES --------------------------------------------------------------------------------
function MM2:_scanRoles()
	for _, p in Players:GetPlayers() do
		local char = p.Character
		if self._chars[p] ~= char then
			self._chars[p] = char
			self.Roles[p] = nil -- respawned: a new round hands out new roles
		end
		local role = toolRole(char) or toolRole(p:FindFirstChild("Backpack"))
		if role and self.Roles[p] ~= role and self.Roles[p] ~= "Murderer" then
			self.Roles[p] = role
			if self.OnRole then task.spawn(self.OnRole, p, role) end
		end
	end
	for p in self.Roles do
		if p.Parent ~= Players then self.Roles[p] = nil end
	end
end

function MM2:_entry(p)
	local e = self._hl[p]
	if e then return e end
	local hl = Instance.new("Highlight")
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.FillTransparency = 0.55
	hl.OutlineColor = Color3.new(1, 1, 1)
	hl.Enabled = false
	hl.Parent = self._folder
	local bb = Instance.new("BillboardGui")
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(160, 32)
	bb.StudsOffset = Vector3.new(0, 3, 0)
	bb.Enabled = false
	bb.Parent = self._folder
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextStrokeTransparency = 0.4
	label.Parent = bb
	e = { Highlight = hl, Billboard = bb, Label = label }
	self._hl[p] = e
	return e
end

function MM2:_updateRoleVisuals()
	local s = self.Settings
	for _, p in Players:GetPlayers() do
		if p ~= self.Player then
			local char = p.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			local head = char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
			local role = self.Roles[p]
			local show = s.RoleESP and hum and head and hum.Health > 0 and (role ~= nil or s.Innocents)
			if show then
				local e = self:_entry(p)
				local color = COLORS[role or "Innocent"]
				if e.Highlight.Adornee ~= char then e.Highlight.Adornee = char end
				if e.Billboard.Adornee ~= head then e.Billboard.Adornee = head end
				e.Highlight.FillColor = color
				e.Highlight.Enabled = true
				e.Billboard.Enabled = s.Tags
				e.Label.TextColor3 = color
				e.Label.Text = p.DisplayName .. (role and (" [" .. role .. "]") or "")
			elseif self._hl[p] then
				self._hl[p].Highlight.Enabled = false
				self._hl[p].Billboard.Enabled = false
			end
		end
	end
	for p, e in self._hl do
		if p.Parent ~= Players then
			e.Highlight:Destroy()
			e.Billboard:Destroy()
			self._hl[p] = nil
		end
	end
end

-- TRACERS ------------------------------------------------------------------------------
function MM2:_renderTracers()
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local vp = cam.ViewportSize
	local origin = Vector2.new(vp.X / 2, vp.Y)
	local used = {}
	for p, role in self.Roles do
		if p ~= self.Player and p.Parent == Players then
			local char = p.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root and hum and hum.Health > 0 then
				local pos, onScreen = cam:WorldToViewportPoint(root.Position)
				local line = self._tracers[p]
				if not line then
					line = Drawing.new("Line")
					line.Thickness = 1.5
					self._tracers[p] = line
				end
				line.Color = COLORS[role]
				line.From = origin
				line.To = Vector2.new(pos.X, pos.Y)
				line.Visible = onScreen and pos.Z > 0
				used[p] = true
			end
		end
	end
	for p, line in self._tracers do
		if not used[p] then
			if p.Parent ~= Players then
				pcall(function() line:Remove() end)
				self._tracers[p] = nil
			else
				line.Visible = false
			end
		end
	end
end

-- PROXIMITY ----------------------------------------------------------------------------
function MM2:_checkProximity(dt)
	self._proxT = math.max(0, self._proxT - dt)
	if self._proxT > 0 then return end
	local me = myRoot(self)
	if not me or self.Roles[self.Player] == "Murderer" then return end
	local murderer = self:GetByRole("Murderer")
	local root = murderer and murderer.Character and murderer.Character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local d = (root.Position - me.Position).Magnitude
	if d <= self.Settings.ProximityDistance then
		self._proxT = 4 -- seconds before it can fire again
		if self.OnProximity then task.spawn(self.OnProximity, murderer, d) end
	end
end

-- GUN DROP -----------------------------------------------------------------------------
function MM2:_scanGun()
	local gun = self._gun
	if gun and gun.Parent then return end
	self._gun = nil
	if self._gunHl then self._gunHl:Destroy(); self._gunHl = nil end
	local found = Workspace:FindFirstChild(GUN_DROP, true)
	local part = found and partOf(found)
	if not part then return end
	self._gun = part
	if self.OnGun then task.spawn(self.OnGun, part) end
	if self.Settings.AutoGrabGun and self.Roles[self.Player] ~= "Murderer" then
		self:GrabGun()
	end
end

function MM2:_updateGunVisual()
	local part = self._gun
	if part and self.Settings.GunESP and self._folder then
		if not self._gunHl then
			local hl = Instance.new("Highlight")
			hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			hl.FillColor, hl.OutlineColor = COLORS.Gun, Color3.new(1, 1, 1)
			hl.FillTransparency = 0.3
			hl.Parent = self._folder
			self._gunHl = hl
		end
		self._gunHl.Adornee = part
	elseif self._gunHl then
		self._gunHl:Destroy()
		self._gunHl = nil
	end
end

-- TRAP ESP -----------------------------------------------------------------------------
function MM2:_updateTrapVisuals()
	if not (self.Settings.TrapESP and self._folder) then
		for t, hl in self._trapHl do hl:Destroy(); self._trapHl[t] = nil end
		return
	end
	local count = 0
	for t, hl in self._trapHl do
		if t.Parent then count += 1 else hl:Destroy(); self._trapHl[t] = nil end
	end
	for _, c in Workspace:GetChildren() do
		if count >= MAX_TRAP_HL then break end
		if c.Name == TRAP and not self._trapHl[c] and (c:IsA("BasePart") or c:IsA("Model")) then
			local hl = Instance.new("Highlight")
			hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			hl.FillColor, hl.OutlineColor = COLORS.Trap, Color3.new(1, 1, 1)
			hl.FillTransparency = 0.35
			hl.Adornee = c
			hl.Parent = self._folder
			self._trapHl[c] = hl
			count += 1
		end
	end
end

function MM2:HasDrawing() return hasDrawing end

function MM2:HasGun() return self._gun ~= nil and self._gun.Parent ~= nil end

function MM2:_goto(cf)
	if self.Teleport then return self.Teleport(cf) end
	local hrp = myRoot(self)
	if not hrp then return false end
	hrp.CFrame = cf
	return true
end

-- fetches the dropped gun (touching it picks it up), then brings you back where you were
function MM2:GrabGun()
	if self._grabbing then return false, "Already grabbing" end
	local part, hrp = self._gun, myRoot(self)
	if not (part and part.Parent) then return false, "No gun on the ground" end
	if not hrp then return false, "No character" end
	local back = hrp.CFrame
	self._grabbing = true
	task.spawn(function()
		self:_goto(CFrame.new(part.Position + Vector3.new(0, 3, 0)))
		task.wait(0.45)
		if self.Settings.ReturnAfterGun then self:_goto(back) end
		task.wait(1) -- don't retrigger on the same drop
		self._grabbing = false
	end)
	return true
end

-- COINS --------------------------------------------------------------------------------
function MM2:_container()
	if not (self._cont and self._cont.Parent) then
		self._cont = Workspace:FindFirstChild(COIN_CONTAINER, true)
	end
	return self._cont
end

function MM2:_nearestCoin(from)
	local container = self:_container()
	if not container then return nil end
	-- Safe Farm: coins close to the Murderer are left for later
	local avoid
	if self.Settings.SafeFarm and self.Roles[self.Player] ~= "Murderer" then
		local m = self:GetByRole("Murderer")
		local r = m and m.Character and m.Character:FindFirstChild("HumanoidRootPart")
		avoid = r and r.Position
	end
	local safeD = self.Settings.SafeDistance
	local best, bestD
	for _, c in container:GetDescendants() do
		if c.Name == COIN and c:IsA("BasePart") and not self._visited[c]
			and not (avoid and (c.Position - avoid).Magnitude < safeD) then
			local d = (c.Position - from).Magnitude
			if not bestD or d < bestD then best, bestD = c, d end
		end
	end
	return best
end

function MM2:CoinCount()
	local container = self:_container()
	if not container then return 0 end
	local n = 0
	for _, c in container:GetDescendants() do
		if c.Name == COIN and c:IsA("BasePart") then n += 1 end
	end
	return n
end

function MM2:_updateCoinVisuals(from)
	local container = self:_container()
	if not (self.Settings.CoinESP and container and self._folder) then
		for c, hl in self._coinHl do hl:Destroy(); self._coinHl[c] = nil end
		return
	end
	-- drop highlights of coins that were collected
	local count = 0
	for c, hl in self._coinHl do
		if not c.Parent then hl:Destroy(); self._coinHl[c] = nil else count += 1 end
	end
	local origin = from or Vector3.zero
	local fresh = {}
	for _, c in container:GetDescendants() do
		if c.Name == COIN and c:IsA("BasePart") and not self._coinHl[c] then
			table.insert(fresh, c)
		end
	end
	table.sort(fresh, function(a, b)
		return (a.Position - origin).Magnitude < (b.Position - origin).Magnitude
	end)
	for _, c in fresh do
		if count >= MAX_COIN_HL then break end
		local hl = Instance.new("Highlight")
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.FillColor, hl.OutlineColor = COLORS.Coin, Color3.new(1, 1, 1)
		hl.FillTransparency = 0.4
		hl.Adornee = c
		hl.Parent = self._folder
		self._coinHl[c] = hl
		count += 1
	end
end

function MM2:_coinLoop()
	self._coinRun = true
	while self.Settings.AutoCoins do
		local hrp = myRoot(self)
		local hum = self.Player.Character and self.Player.Character:FindFirstChildOfClass("Humanoid")
		local coin = hrp and hum and hum.Health > 0 and self:_nearestCoin(hrp.Position)
		if coin then
			self._visited[coin] = true
			self.Stats.Coins += 1
			if self.OnCoin then task.spawn(self.OnCoin, self.Stats.Coins) end
			if self.Settings.CoinMode == "Walk" and hum then
				hum:MoveTo(coin.Position)
				local t = 0
				while t < 4 and coin.Parent and self.Settings.AutoCoins
					and myRoot(self) and (myRoot(self).Position - coin.Position).Magnitude > 4 do
					t += task.wait(0.1)
				end
			else
				self:_goto(CFrame.new(coin.Position))
			end
			task.wait(self.Settings.NoDelay and 0.03 or self.Settings.CoinDelay / 1000)
		else
			task.wait(self.Settings.NoDelay and 0.1 or 0.5)
		end
	end
	self._coinRun = false
end

-- NAVIGATION ---------------------------------------------------------------------------
function MM2:TeleportToPlayer(p)
	local root = p and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
	if not root then return false, "Player has no character" end
	return self:_goto(root.CFrame * CFrame.new(0, 0, 4))
end

function MM2:TeleportToRole(role)
	local p = self:GetByRole(role)
	if not p then return false, role .. " not known yet" end
	return self:TeleportToPlayer(p)
end

function MM2:SetSafeSpot()
	local hrp = myRoot(self)
	if not hrp then return false, "No character" end
	self.Safe = hrp.CFrame
	return true
end

function MM2:GoSafe()
	if not self.Safe then return false, "No safe spot saved" end
	return self:_goto(self.Safe)
end

function MM2:Spectate(target)
	local p = target
	if type(target) == "string" then p = self:GetByRole(target) end
	local hum = p and p.Character and p.Character:FindFirstChildOfClass("Humanoid")
	local cam = Workspace.CurrentCamera
	if not (hum and cam) then return false, "Nothing to spectate" end
	cam.CameraSubject = hum
	self._spectating = true
	return true
end

function MM2:Unspectate()
	local cam = Workspace.CurrentCamera
	local hum = self.Player.Character and self.Player.Character:FindFirstChildOfClass("Humanoid")
	if cam and hum then cam.CameraSubject = hum end
	self._spectating = false
end

-- UTILITIES (no delay / movement) --------------------------------------------------------
function MM2:_conn(name, signal, fn)
	if self._conns[name] then return end
	self._conns[name] = signal:Connect(fn)
end

function MM2:_unconn(name)
	local c = self._conns[name]
	if c then c:Disconnect(); self._conns[name] = nil end
end

local function myHum(self)
	local char = self.Player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

function MM2:_instantPrompt(p)
	if not p:IsA("ProximityPrompt") then return end
	if self._prompts[p] == nil then self._prompts[p] = p.HoldDuration end
	p.HoldDuration = 0
end

function MM2:_restorePrompts()
	for p, d in self._prompts do
		if p.Parent then p.HoldDuration = d end
		self._prompts[p] = nil
	end
end

-- KNIFE HITBOX ---------------------------------------------------------------------------
-- Runs every Stepped while Hitbox is on. Only the Handle of the Knife you are holding is touched.
-- The server still decides whether a stab counts: if it checks distance itself, a bigger Handle will not help.
-- Your character owns the Handle, so size / transparency replicate: keep Show off (invisible) to look normal.
function MM2:_restoreHitbox()
	for handle, rec in self._hb do
		if handle.Parent then
			handle.Size = rec.Size
			handle.Massless = rec.Massless
			handle.CanCollide = rec.CanCollide
			handle.Transparency = rec.Transparency
		end
		self._hb[handle] = nil
	end
end

function MM2:_applyHitbox()
	local char = self.Player.Character
	local tool = char and char:FindFirstChild(KNIFE)
	local handle = tool and tool:IsA("Tool") and tool:FindFirstChild("Handle")
	if not (handle and handle:IsA("BasePart")) then
		if next(self._hb) then self:_restoreHitbox() end -- knife unequipped
		return
	end
	local s = self.Settings
	if not self._hb[handle] then
		self._hb[handle] = {
			Size = handle.Size, Massless = handle.Massless,
			CanCollide = handle.CanCollide, Transparency = handle.Transparency,
		}
	end
	local size = Vector3.new(s.HitboxSize, s.HitboxSize, s.HitboxSize)
	if handle.Size ~= size then handle.Size = size end
	if not handle.Massless then handle.Massless = true end
	if handle.CanCollide then handle.CanCollide = false end
	local tr = s.HitboxShow and 0.7 or 1
	if handle.Transparency ~= tr then handle.Transparency = tr end
end

function MM2:_syncUtil()
	local s = self.Settings

	-- instant prompts
	if s.NoDelay then
		if not self._conns.Prompts then
			for _, d in Workspace:GetDescendants() do self:_instantPrompt(d) end
			self._conns.Prompts = Workspace.DescendantAdded:Connect(function(d) self:_instantPrompt(d) end)
		end
	elseif self._conns.Prompts then
		self:_unconn("Prompts")
		self:_restorePrompts()
	end

	-- no shoot delay: the Gun's cooldown lives in its own client script, and re-equipping the tool resets it.
	-- A cooldown enforced by the server cannot be removed from here.
	if s.NoShootDelay then
		self:_conn("GunWatch", RunService.Heartbeat, function()
			local char = self.Player.Character
			local tool = char and char:FindFirstChild(GUN)
			if tool == self._hooked then return end
			self._hooked = tool
			self:_unconn("GunHook")
			if not (tool and tool:IsA("Tool")) then return end
			self._conns.GunHook = tool.Activated:Connect(function()
				if self._resetting then return end
				self._resetting = true
				task.wait(0.05) -- let the shot go out first
				local hum = myHum(self)
				if hum and tool.Parent then
					hum:UnequipTools()
					task.wait(0.03)
					if tool.Parent == self.Player:FindFirstChild("Backpack") then hum:EquipTool(tool) end
				end
				self._resetting = false
			end)
		end)
	else
		self:_unconn("GunWatch")
		self:_unconn("GunHook")
		self._hooked = nil
		self._resetting = false
	end

	-- speed / jump: re-applied each frame because the game resets them on respawn
	if s.SpeedOn or s.JumpOn then
		self:_conn("Move", RunService.Heartbeat, function()
			local hum = myHum(self)
			if not hum then return end
			local st = self.Settings
			if st.SpeedOn and hum.WalkSpeed ~= st.Speed then hum.WalkSpeed = st.Speed end
			if st.JumpOn then
				if hum.UseJumpPower == false then hum.UseJumpPower = true end
				if hum.JumpPower ~= st.Jump then hum.JumpPower = st.Jump end
			end
		end)
	else
		self:_unconn("Move")
	end

	-- knife hitbox
	if s.Hitbox then
		self:_conn("Hitbox", RunService.Stepped, function() self:_applyHitbox() end)
	elseif self._conns.Hitbox or next(self._hb) then
		self:_unconn("Hitbox")
		self:_restoreHitbox()
	end

	-- noclip
	if s.Noclip then
		self:_conn("Noclip", RunService.Stepped, function()
			local char = self.Player.Character
			if not char then return end
			for _, part in char:GetDescendants() do
				if part:IsA("BasePart") and part.CanCollide then part.CanCollide = false end
			end
		end)
	else
		self:_unconn("Noclip")
	end

	-- infinite jump
	if s.InfJump then
		self:_conn("InfJump", UserInputService.JumpRequest, function()
			local hum = myHum(self)
			if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
		end)
	else
		self:_unconn("InfJump")
	end

	-- anti-AFK
	if s.AntiAFK then
		self:_conn("AntiAFK", self.Player.Idled, function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	else
		self:_unconn("AntiAFK")
	end
end

-- puts walk speed / jump power back to the usual values (call after turning SpeedOn / JumpOn off)
function MM2:ResetMovement()
	local hum = myHum(self)
	if not hum then return end
	hum.WalkSpeed = 16
	hum.JumpPower = 50
end

-- LOOP ---------------------------------------------------------------------------------
function MM2:_beat(dt)
	self._acc += dt
	self._gunT += dt
	if self.Settings.Proximity then self:_checkProximity(dt) end
	if self._acc < 0.25 then return end
	self._acc = 0
	self:_scanRoles()
	self:_updateRoleVisuals()
	if self._gunT >= 1 then
		self._gunT = 0
		self:_scanGun()
		local hrp = myRoot(self)
		self:_updateCoinVisuals(hrp and hrp.Position)
		self:_updateTrapVisuals()
	end
	self:_updateGunVisual()
end

function MM2:GetRole(p) return self.Roles[p] end

function MM2:GetByRole(role)
	for p, r in self.Roles do
		if r == role then return p end
	end
	return nil
end

function MM2:ClearRoles()
	table.clear(self.Roles)
	table.clear(self._visited)
	self.Stats.Coins = 0
end

function MM2:Destroy()
	self.Settings.AutoCoins = false
	if self._spectating then self:Unspectate() end
	if self._beatConn then self._beatConn:Disconnect(); self._beatConn = nil end
	if self._tracerConn then self._tracerConn:Disconnect(); self._tracerConn = nil end
	for name in self._conns do self:_unconn(name) end
	self:_restoreHitbox()
	self:_restorePrompts()
	self:_clearTracers()
	self:_clearVisuals()
end

return MM2
end)(import)

-- ======== NDS (merged) ========
local NDS = (function(...)
-- modules/NDS.lua
-- Natural Disaster Survival helpers. Knows nothing about the GUI. Client-side only.
--   Disaster detect : reads the current disaster from Values / Attributes, falling back to the on-screen
--                     text (PlayerGui labels). Fires OnDisaster(name | nil) when it changes.
--   Auto High Ground: on Flood / Tsunami, teleports once to the highest standable part near you.
--   Go High         : manual version of Auto High Ground (any time).
--   Water Walk      : a local, invisible pad under your feet whenever the ground below you is water.
--   No Fall Damage  : softens the landing speed just before you touch the ground.
--   Hazard ESP      : highlights tornadoes / meteors / fireballs / lava while a disaster is running.
--   Safe spot       : save a position, jump back to it later.
-- Everything is gated by Settings.Enabled, and the App only lets you enable it inside NDS.
-- The disaster list, the hazard names and the PlaceId are from memory: if detection misses, set Debug = true
-- and compare the printed source with what the game really shows, then hard-code the path in _readDisaster.
local import = ...

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")

local POLL = 0.5           -- seconds between disaster checks
local CLEAR_AFTER = 4      -- consecutive empty polls before a disaster counts as over
local FALL_TRIGGER = -35   -- studs/s downward speed that arms the fall check
local FALL_SAFE = -22      -- speed you are slowed to near the ground
local FALL_RAY = 14        -- studs below you that count as "near the ground"
local WATER_RAY = 12       -- studs below you that are checked for water
local PAD_SIZE = 14        -- width of the water pad
local MAX_PART = 2000      -- ignore parts bigger than this (baseplates, oceans)
local HIGH_RADIUS = 600    -- only parts this close (horizontally) count for "highest spot"
local HIGH_CACHE = 45      -- seconds a found high spot is reused
local MAX_HAZARD_HL = 6    -- Highlight instances are capped by the engine; keep it small
local YIELD_EVERY = 400
local HAZARDS = { "tornado", "meteor", "fireball", "lava", "lightning", "hail" } -- name fragments (lowercase)

local NDS = {}
NDS.__index = NDS

NDS.Disasters = {
	"Tornado", "Flood", "Tsunami", "Earthquake", "Fire", "Meteor Shower", "Volcanic Eruption",
	"Blizzard", "Sandstorm", "Acid Rain", "Thunderstorm", "Deadly Virus", "Wildfire",
}
-- disasters where height is the answer
NDS.HighGround = { Flood = true, Tsunami = true }

local function guiParent()
	local ok, ui = pcall(function() return gethui and gethui() end)
	if ok and ui then return ui end
	return CoreGui
end

local function matchName(text)
	if type(text) ~= "string" or text == "" then return nil end
	text = text:lower()
	for _, name in NDS.Disasters do
		if text:find("%f[%a]" .. name:lower() .. "%f[%A]") then return name end
	end
	return nil
end

local function hazardName(name)
	name = name:lower()
	for _, frag in HAZARDS do
		if name:find(frag, 1, true) then return true end
	end
	return false
end

local function isWaterName(inst)
	local n = inst.Name:lower()
	return n:find("water", 1, true) ~= nil or n:find("flood", 1, true) ~= nil
end

local function isCharacterPart(inst)
	local model = inst:FindFirstAncestorOfClass("Model")
	return model ~= nil and Players:GetPlayerFromCharacter(model) ~= nil
end

local function myRoot(self)
	local char = self.Player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

function NDS.new()
	local self = setmetatable({}, NDS)
	self.Player = Players.LocalPlayer
	self.Settings = {
		Enabled = false, Alerts = true,
		AutoHigh = true, NoFallDamage = true, WaterWalk = true, HazardESP = true,
		Debug = false,
	}
	self.Active = false     -- set by the App: true only inside NDS
	self.Current = nil      -- name of the running disaster
	self.Source = "none"    -- where the name was read from (for Debug)
	self.Spot = nil         -- saved CFrame, see SetSpot
	self.OnDisaster = nil   -- callback(name | nil)
	self.OnHigh = nil       -- callback(position)  (a high spot was found)
	self.Teleport = nil     -- function(cf) -> bool (use your own teleport + guard exemption)
	self._miss, self._acc = 0, 0
	self._high, self._highAt, self._finding, self._sentHigh = nil, 0, false, false
	self._conn = nil
	self._pad, self._folder = nil, nil
	self._hz = {}           -- [hazard instance] = Highlight
	self._rayParams = RaycastParams.new()
	self._rayParams.FilterType = Enum.RaycastFilterType.Exclude
	self._waterParams = RaycastParams.new()
	self._waterParams.FilterType = Enum.RaycastFilterType.Exclude
	self._waterParams.IgnoreWater = false -- terrain water has to be hit to be seen
	return self
end

function NDS:_log(...)
	if self.Settings.Debug then print("[NDS]", ...) end
end

function NDS:Set(key, value)
	self.Settings[key] = value
	if key == "Enabled" then
		self:_sync()
	elseif key == "WaterWalk" and not value then
		self:_dropPad()
	elseif key == "HazardESP" and not value then
		self:_clearHazards()
	end
end

function NDS:SetEnabled(on)
	self:Set("Enabled", on)
	if not on then self:_reset() end
end

function NDS:_reset()
	self.Current, self.Source = nil, "none"
	self._miss, self._high, self._sentHigh = 0, nil, false
	self:_dropPad()
	self:_clearHazards()
end

function NDS:_sync()
	if self.Settings.Enabled and not self._conn then
		self._conn = RunService.Heartbeat:Connect(function(dt) self:_beat(dt) end)
	elseif not self.Settings.Enabled and self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
end

-- DISASTER DETECTION ---------------------------------------------------------------
-- 1) Values / Attributes named like "disaster" on Workspace / ReplicatedStorage
-- 2) visible text on screen that contains a known disaster name
function NDS:_readDisaster()
	for _, root in { Workspace, ReplicatedStorage } do
		for k, v in root:GetAttributes() do
			if type(v) == "string" and k:lower():find("disaster", 1, true) then
				local n = matchName(v)
				if n then return n, "attribute " .. root.Name .. "." .. k end
			end
		end
		for _, child in root:GetChildren() do
			if child:IsA("StringValue") and child.Name:lower():find("disaster", 1, true) then
				local n = matchName(child.Value)
				if n then return n, "value " .. child:GetFullName() end
			end
		end
	end

	local gui = self.Player and self.Player:FindFirstChildOfClass("PlayerGui")
	if gui then
		for _, d in gui:GetDescendants() do
			if d:IsA("TextLabel") and d.Visible and d.Text ~= "" and d.TextTransparency < 1 then
				local n = matchName(d.Text)
				if n then return n, "gui " .. d:GetFullName() end
			end
		end
	end
	return nil, "none"
end

function NDS:_poll()
	local name, source = self:_readDisaster()
	if name then
		self._miss = 0
		if name ~= self.Current then
			self.Current, self.Source = name, source
			self._high, self._sentHigh = nil, false
			self:_log("disaster:", name, "via", source)
			if self.OnDisaster then task.spawn(self.OnDisaster, name) end
		end
	else
		self._miss += 1
		if self.Current and self._miss >= CLEAR_AFTER then
			self:_log("disaster over:", self.Current)
			self:_reset()
			if self.OnDisaster then task.spawn(self.OnDisaster, nil) end
		end
	end

	local s = self.Settings
	if s.AutoHigh and self.Current and NDS.HighGround[self.Current] and not self._sentHigh then
		self._sentHigh = true
		self:GoHigh()
	end
	self:_updateHazards()
end

-- HIGH GROUND ---------------------------------------------------------------------------
-- highest standable, anchored, collidable part near you that is not water / terrain / a character
function NDS:_findHigh()
	local me = myRoot(self)
	if not me then return nil end
	local origin = me.Position
	local best, bestTop
	local n = 0
	for _, d in Workspace:GetDescendants() do
		if d:IsA("BasePart") and not d:IsA("Terrain") and d.Anchored and d.CanCollide
			and d.Transparency < 1 and d.Size.X >= 4 and d.Size.Z >= 4
			and d.Size.X < MAX_PART and d.Size.Z < MAX_PART then
			local dx, dz = d.Position.X - origin.X, d.Position.Z - origin.Z
			if dx * dx + dz * dz <= HIGH_RADIUS * HIGH_RADIUS then
				local lname = d.Name:lower()
				if not (lname:find("water", 1, true) or lname:find("flood", 1, true) or lname:find("lava", 1, true))
					and not isCharacterPart(d) then
					local top = d.Position.Y + d.Size.Y / 2
					if not bestTop or top > bestTop then best, bestTop = d, top end
				end
			end
		end
		n += 1
		if n % YIELD_EVERY == 0 then task.wait() end
	end
	if not best then return nil end
	return Vector3.new(best.Position.X, bestTop + 4, best.Position.Z)
end

function NDS:_goto(cf)
	if self.Teleport then return self.Teleport(cf) end
	local hrp = myRoot(self)
	if not hrp then return false end
	hrp.CFrame = cf
	return true
end

-- returns ok, err. Runs in the background (the scan yields), so ok = "started".
function NDS:GoHigh()
	if not self.Active then return false, "Not in Natural Disaster Survival" end
	if self._finding then return false, "Already searching" end
	if not myRoot(self) then return false, "No character" end
	self._finding = true
	task.spawn(function()
		local pos = self._high
		if not (pos and os.clock() - self._highAt < HIGH_CACHE) then pos = self:_findHigh() end
		self._finding = false
		if not pos then
			self:_log("no high spot found")
			return
		end
		self._high, self._highAt = pos, os.clock()
		self:_log("high spot", pos)
		if self.OnHigh then task.spawn(self.OnHigh, pos) end
		self:_goto(CFrame.new(pos))
	end)
	return true
end

-- SAFE SPOT -----------------------------------------------------------------------------
function NDS:SetSpot()
	local hrp = myRoot(self)
	if not hrp then return false, "No character" end
	self.Spot = hrp.CFrame
	return true
end

function NDS:GoSpot()
	if not self.Spot then return false, "No spot saved" end
	if not myRoot(self) then return false, "No character" end
	return self:_goto(self.Spot)
end

-- NO FALL DAMAGE ---------------------------------------------------------------------
function NDS:_softLand()
	local char = self.Player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or hum.Health <= 0 then return end
	local v = root.AssemblyLinearVelocity
	if v.Y > FALL_TRIGGER then return end
	self._rayParams.FilterDescendantsInstances = { char }
	local hit = Workspace:Raycast(root.Position, Vector3.new(0, -FALL_RAY, 0), self._rayParams)
	if hit then
		root.AssemblyLinearVelocity = Vector3.new(v.X, FALL_SAFE, v.Z)
	end
end

-- WATER WALK ----------------------------------------------------------------------------
-- The pad only exists on this client (your own character is simulated here, so you do stand on it).
function NDS:_dropPad()
	if self._pad then
		self._pad:Destroy()
		self._pad = nil
	end
end

function NDS:_waterWalk()
	local char = self.Player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not (root and hum) or hum.Health <= 0 then
		self:_dropPad()
		return
	end
	local filter = { char }
	if self._pad then table.insert(filter, self._pad) end
	self._waterParams.FilterDescendantsInstances = filter
	local hit = Workspace:Raycast(root.Position, Vector3.new(0, -WATER_RAY, 0), self._waterParams)
	if not (hit and (hit.Material == Enum.Material.Water or isWaterName(hit.Instance))) then
		self:_dropPad()
		return
	end
	if not self._pad then
		local pad = Instance.new("Part")
		pad.Name = "PM_WaterPad"
		pad.Anchored, pad.CanCollide, pad.CanQuery, pad.CanTouch = true, true, false, false
		pad.Transparency = 1
		pad.Size = Vector3.new(PAD_SIZE, 1, PAD_SIZE)
		pad.Parent = Workspace
		self._pad = pad
	end
	self._pad.CFrame = CFrame.new(root.Position.X, hit.Position.Y - 0.5, root.Position.Z)
end

-- HAZARD ESP ----------------------------------------------------------------------------
function NDS:_clearHazards()
	for inst, hl in self._hz do
		hl:Destroy()
		self._hz[inst] = nil
	end
	if self._folder then
		self._folder:Destroy()
		self._folder = nil
	end
end

function NDS:_updateHazards()
	if not (self.Settings.HazardESP and self.Current) then
		if next(self._hz) then self:_clearHazards() end
		return
	end
	if not self._folder then
		self._folder = Instance.new("Folder")
		self._folder.Name = "PlayerMenuNDS"
		self._folder.Parent = guiParent()
	end
	local count = 0
	for inst, hl in self._hz do
		if inst.Parent then
			count += 1
		else
			hl:Destroy()
			self._hz[inst] = nil
		end
	end
	for _, c in Workspace:GetChildren() do
		if count >= MAX_HAZARD_HL then break end
		if not self._hz[c] and (c:IsA("Model") or c:IsA("BasePart")) and not c:IsA("Terrain")
			and hazardName(c.Name) and not (c:IsA("Model") and Players:GetPlayerFromCharacter(c)) then
			local hl = Instance.new("Highlight")
			hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			hl.FillColor, hl.OutlineColor = Color3.fromRGB(255, 90, 40), Color3.new(1, 1, 1)
			hl.FillTransparency = 0.5
			hl.Adornee = c
			hl.Parent = self._folder
			self._hz[c] = hl
			count += 1
		end
	end
end

-- LOOP ----------------------------------------------------------------------------------
function NDS:_beat(dt)
	if not self.Active then return end
	local s = self.Settings
	if s.NoFallDamage then self:_softLand() end
	if s.WaterWalk then self:_waterWalk() end
	self._acc += dt
	if self._acc < POLL then return end
	self._acc = 0
	self:_poll()
end

function NDS:GetStatus()
	return self.Current or "None"
end

function NDS:Destroy()
	self.Settings.Enabled = false
	self:_sync()
	self:_reset()
end

return NDS
end)(import)

-- modules/Games.lua
-- Which game are we in? Add an entry to List to support another one.
-- The IDs are from memory: if a game is not recognised, check game.PlaceId / game.GameId and fix the entry.

local MarketplaceService = game:GetService("MarketplaceService")

local Games = {}

Games.List = {
	{ Id = "MM2", Name = "Murder Mystery 2", PlaceIds = { 142823291 }, UniverseIds = { 66654135 }, NameHint = "murder mystery" },
	-- NDS ids are from memory; the title match below covers a wrong one
	{ Id = "NDS", Name = "Natural Disaster Survival", PlaceIds = { 189707 }, UniverseIds = { 65241 }, NameHint = "natural disaster survival" },
}

function Games.Detect()
	for _, g in Games.List do
		if table.find(g.PlaceIds, game.PlaceId) or table.find(g.UniverseIds, game.GameId) then return g end
	end
	-- fallback: match on the place's title
	local ok, info = pcall(function() return MarketplaceService:GetProductInfo(game.PlaceId) end)
	if ok and info and info.Name then
		local title = info.Name:lower()
		for _, g in Games.List do
			if g.NameHint and title:find(g.NameHint, 1, true) then return g end
		end
	end
	return nil
end

-- true when the detected game is the one with this Id ("MM2" | "NDS")
function Games.Is(id)
	local g = Games.Detect()
	return g ~= nil and g.Id == id
end

Games.MM2 = MM2 -- the Murder Mystery 2 helper class
Games.NDS = NDS -- the Natural Disaster Survival helper class

return Games

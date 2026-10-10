-- modules/MM2.lua
-- Murder Mystery 2 helpers. Knows nothing about the GUI. Client-side only.
--   Role ESP   : Murderer / Sheriff (and optionally innocents) highlighted. A role is learned from the tool
--                a player holds (Knife / Gun), which is all the client can see, and remembered until that
--                player respawns. Someone who never equips their tool stays unknown.
--   Gun drop   : highlights the dropped gun, announces it, and can fetch it and bring you back.
--   Auto coins : walks through the coins of the round, one at a time.
-- Instance names (Knife, Gun, GunDrop, CoinContainer, Coin_Server) are from memory of the game and can
-- change in an update: if something stops working, check the names in the Explorer and edit the constants.
local import = ...

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CoreGui = game:GetService("CoreGui")

local KNIFE, GUN = "Knife", "Gun"
local GUN_DROP = "GunDrop"
local COIN_CONTAINER, COIN = "CoinContainer", "Coin_Server"

local COLORS = {
	Murderer = Color3.fromRGB(255, 60, 60),
	Sheriff = Color3.fromRGB(70, 140, 255),
	Innocent = Color3.fromRGB(90, 220, 120),
	Gun = Color3.fromRGB(255, 210, 60),
}

local MM2 = {}
MM2.__index = MM2

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
		GunESP = false, Alerts = true, ReturnAfterGun = true,
		AutoCoins = false, CoinDelay = 700, -- ms between coins
	}
	self.Roles = {}                                    -- [player] = "Murderer" | "Sheriff"
	self._chars = setmetatable({}, { __mode = "k" })   -- last character seen per player (a new one clears the role)
	self._hl = {}                                      -- [player] = { Highlight, Billboard, Label }
	self._visited = setmetatable({}, { __mode = "k" }) -- coins already tried
	self.Teleport = nil -- function(cf) -> bool  (set this so your own teleport + guard exemption is used)
	self.OnRole = nil   -- callback(player, role)
	self.OnGun = nil    -- callback(part)
	self._acc, self._gunT = 0, 0
	return self
end

function MM2:Set(key, value)
	self.Settings[key] = value
	if key == "RoleESP" or key == "GunESP" or key == "AutoCoins" then self:_sync() end
end

function MM2:_sync()
	local s = self.Settings
	local need = s.RoleESP or s.GunESP
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
	if s.AutoCoins and not self._coinRun then task.spawn(function() self:_coinLoop() end) end
end

function MM2:_clearVisuals()
	for p, e in self._hl do
		e.Highlight:Destroy()
		e.Billboard:Destroy()
		self._hl[p] = nil
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

function MM2:HasGun() return self._gun ~= nil and self._gun.Parent ~= nil end

local function myRoot(self)
	local char = self.Player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

function MM2:_goto(cf)
	if self.Teleport then return self.Teleport(cf) end
	local hrp = myRoot(self)
	if not hrp then return false end
	hrp.CFrame = cf
	return true
end

-- fetches the dropped gun (touching it picks it up), then brings you back where you were
function MM2:GrabGun()
	local part, hrp = self._gun, myRoot(self)
	if not (part and part.Parent) then return false, "No gun on the ground" end
	if not hrp then return false, "No character" end
	local back = hrp.CFrame
	task.spawn(function()
		self:_goto(CFrame.new(part.Position + Vector3.new(0, 3, 0)))
		task.wait(0.45)
		if self.Settings.ReturnAfterGun then self:_goto(back) end
	end)
	return true
end

-- COINS --------------------------------------------------------------------------------
function MM2:_nearestCoin(from)
	if not (self._container and self._container.Parent) then
		self._container = Workspace:FindFirstChild(COIN_CONTAINER, true)
	end
	local container = self._container
	if not container then return nil end
	local best, bestD
	for _, c in container:GetDescendants() do
		if c.Name == COIN and c:IsA("BasePart") and not self._visited[c] then
			local d = (c.Position - from).Magnitude
			if not bestD or d < bestD then best, bestD = c, d end
		end
	end
	return best
end

function MM2:_coinLoop()
	self._coinRun = true
	while self.Settings.AutoCoins do
		local hrp = myRoot(self)
		local hum = self.Player.Character and self.Player.Character:FindFirstChildOfClass("Humanoid")
		local coin = hrp and hum and hum.Health > 0 and self:_nearestCoin(hrp.Position)
		if coin then
			self._visited[coin] = true
			self:_goto(CFrame.new(coin.Position))
			task.wait(self.Settings.CoinDelay / 1000)
		else
			task.wait(0.5)
		end
	end
	self._coinRun = false
end

-- LOOP ---------------------------------------------------------------------------------
function MM2:_beat(dt)
	self._acc += dt
	self._gunT += dt
	if self._acc < 0.25 then return end
	self._acc = 0
	self:_scanRoles()
	self:_updateRoleVisuals()
	if self._gunT >= 1 then
		self._gunT = 0
		self:_scanGun()
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
end

function MM2:Destroy()
	self.Settings.AutoCoins = false
	if self._beatConn then self._beatConn:Disconnect(); self._beatConn = nil end
	self:_clearVisuals()
end

return MM2

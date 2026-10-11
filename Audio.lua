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

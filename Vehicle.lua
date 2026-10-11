-- modules/Vehicle.lua
-- Universal vehicle tuner. Knows nothing about the GUI. Client-side only.
--   * finds whatever vehicle you are seated in (VehicleSeat or plain Seat) and works out its model
--   * classifies it: Car / Bike / Boat / Aircraft / Generic (name + structure), or you force a type
--   * MODES (Stock / Sport / Drift / Rugged / Rocket) mean something different per vehicle type
--   * tuning: seat speed / torque / turn, wheel grip, top-speed assist, boost, low gravity, anti-flip
--   * attribute editor: any numeric Attribute or Number/IntValue found on the vehicle
-- Everything it touches is remembered and put back when you leave the vehicle.
-- NOTE: physics of the car you drive is owned by your client, so most of this replicates to others,
-- but games that validate speed on the server can still correct or kick you.
local import = ...

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Vehicle = {}
Vehicle.__index = Vehicle

Vehicle.TypeNames = { "Auto", "Car", "Bike", "Boat", "Aircraft", "Generic" }
Vehicle.ModeNames = { "Custom", "Stock", "Sport", "Drift", "Rugged", "Rocket" }

-- every mode starts from these, then overlays its own numbers (percent values: 100 = unchanged)
local BASE = {
	Speed = 100, Torque = 100, Turn = 100, Grip = 100, -- VehicleSeat / motor / wheel multipliers (%)
	TopSpeed = 0,                                      -- studs/s the assist pushes toward (0 = assist off)
	Accel = 60,                                        -- studs/s^2 of the assist
	BoostCap = 250,                                    -- studs/s the boost key pushes toward
	LowGrav = 0,                                       -- % of gravity cancelled
	AntiFlip = false,
}

-- Same five names for every type, but each type reads them its own way.
-- (Aircraft: Sport = cruiser, Drift = agile, Rugged = floaty, Rocket = fighter.)
local MODES = {
	Car = {
		Stock = {},
		Sport = { Speed = 140, Torque = 160, Turn = 110, Grip = 120, TopSpeed = 110, Accel = 55 },
		Drift = { Speed = 130, Torque = 150, Turn = 140, Grip = 40, TopSpeed = 100, Accel = 60 },
		Rugged = { Speed = 110, Torque = 230, Turn = 100, Grip = 160, TopSpeed = 70, Accel = 45, AntiFlip = true },
		Rocket = { Speed = 200, Torque = 300, Turn = 80, Grip = 110, TopSpeed = 350, Accel = 200, BoostCap = 500 },
	},
	Bike = {
		Stock = {},
		Sport = { Speed = 135, Torque = 150, Turn = 115, Grip = 115, TopSpeed = 120, Accel = 60 },
		Drift = { Speed = 125, Torque = 140, Turn = 150, Grip = 45, TopSpeed = 95, Accel = 60 },
		Rugged = { Speed = 105, Torque = 220, Turn = 110, Grip = 150, TopSpeed = 65, Accel = 45, AntiFlip = true },
		Rocket = { Speed = 190, Torque = 280, Turn = 90, Grip = 110, TopSpeed = 320, Accel = 190, BoostCap = 450, AntiFlip = true },
	},
	Boat = {
		Stock = {},
		Sport = { Speed = 140, Torque = 150, Turn = 110, TopSpeed = 100, Accel = 45 },
		Drift = { Speed = 130, Torque = 140, Turn = 150, TopSpeed = 90, Accel = 50 },
		Rugged = { Speed = 110, Torque = 220, Turn = 100, TopSpeed = 60, Accel = 35, AntiFlip = true },
		Rocket = { Speed = 200, Torque = 300, Turn = 90, TopSpeed = 260, Accel = 140, BoostCap = 400 },
	},
	Aircraft = {
		Stock = {},
		Sport = { Speed = 130, Torque = 130, Turn = 110, TopSpeed = 160, Accel = 60 },
		Drift = { Speed = 120, Torque = 120, Turn = 160, TopSpeed = 140, Accel = 70 },
		Rugged = { Speed = 100, Torque = 120, Turn = 100, TopSpeed = 90, Accel = 40, LowGrav = 60 },
		Rocket = { Speed = 180, Torque = 200, Turn = 120, TopSpeed = 400, Accel = 180, BoostCap = 600 },
	},
	Generic = {
		Stock = {},
		Sport = { Speed = 140, Torque = 150, Turn = 110, Grip = 110, TopSpeed = 100, Accel = 50 },
		Drift = { Speed = 130, Torque = 140, Turn = 140, Grip = 45, TopSpeed = 90, Accel = 55 },
		Rugged = { Speed = 110, Torque = 220, Turn = 100, Grip = 150, TopSpeed = 60, Accel = 40, AntiFlip = true },
		Rocket = { Speed = 200, Torque = 280, Turn = 90, Grip = 110, TopSpeed = 300, Accel = 170, BoostCap = 450 },
	},
}

-- classification ---------------------------------------------------------------------
local function nameHas(name, words)
	name = name:lower()
	for _, w in words do
		if name:find(w, 1, true) then return true end
	end
	return false
end

local function looksLikeWheel(d)
	if not d:IsA("BasePart") then return false end
	if nameHas(d.Name, { "wheel", "tire", "tyre" }) then return true end
	return d:IsA("Part") and d.Shape == Enum.PartType.Cylinder and d.Size.Y < 6 and d.Size.Z < 6 and d.Size.X < 3
end

local function classify(model, seat, wheelCount)
	local n = model.Name
	if nameHas(n, { "boat", "ship", "yacht", "jetski", "jet ski", "kayak", "canoe", "hovercraft" }) then return "Boat" end
	if nameHas(n, { "heli", "plane", "jet", "aircraft", "airplane", "chopper", "glider", "drone" }) then return "Aircraft" end
	if nameHas(n, { "bike", "motor", "moto", "scooter", "atv", "quad", "cycle" }) then return "Bike" end
	if seat:IsA("VehicleSeat") or wheelCount >= 2 then return "Car" end
	return "Generic"
end

-- the vehicle = the biggest model around the seat that still looks like one vehicle (not the whole map)
local function findModel(seat)
	local best, cur = nil, seat.Parent
	while cur and cur ~= Workspace do
		if cur:IsA("Model") then
			if best and #cur:GetDescendants() > 2500 then break end
			best = cur
		end
		cur = cur.Parent
	end
	return best or seat
end

local function flatten(v)
	return Vector3.new(v.X, 0, v.Z)
end

-- ---------------------------------------------------------------------------------------
function Vehicle.new()
	local self = setmetatable({}, Vehicle)
	self.Player = Players.LocalPlayer
	self.Enabled = false
	self.S = table.clone(BASE)
	self.S.BoostOn, self.S.BoostAccel = true, 120
	self.S.ReverseAxis = false -- flip the push direction if a car's seat faces backwards
	self.S.Restore = true      -- put everything back when you leave the vehicle
	self.Mode = "Stock"
	self.TypeOverride = "Auto"
	self.BoostKey = Enum.KeyCode.LeftShift
	self.BrakeKey = Enum.KeyCode.X
	self.OnChanged = nil -- callback(info | nil, settingsClone)  -- vehicle entered / left / retyped
	self.OnMove = nil    -- callback() right before this module repositions you (so a guard can allow it)
	self._info, self._seat, self._conn, self._tick = nil, nil, nil, 0
	return self
end

function Vehicle:_humanoid()
	local char = self.Player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

function Vehicle:GetStatus() return self._info end
function Vehicle:IsActive() return self.Enabled and self._info ~= nil end

function Vehicle:_fire()
	if self.OnChanged then task.spawn(self.OnChanged, self._info, table.clone(self.S)) end
end

-- SETTINGS / MODES ---------------------------------------------------------------------
function Vehicle:Set(key, value)
	self.S[key] = value
	if self._info then
		self:_apply()
		if key == "Grip" then self:_applyGrip() end
	end
end

function Vehicle:_applyMode()
	if self.Mode == "Custom" then return end
	local kind = self._info and self._info.Type or (self.TypeOverride ~= "Auto" and self.TypeOverride or "Car")
	local def = (MODES[kind] and MODES[kind][self.Mode]) or {}
	for k, v in BASE do self.S[k] = v end
	for k, v in def do self.S[k] = v end
end

-- returns the resulting numbers so the UI can move its sliders
function Vehicle:SetMode(name)
	if not table.find(Vehicle.ModeNames, name) then return table.clone(self.S) end
	self.Mode = name
	self:_applyMode()
	if self._info then self:_apply(); self:_applyGrip() end
	return table.clone(self.S)
end

function Vehicle:SetTypeOverride(kind)
	if not table.find(Vehicle.TypeNames, kind) then return table.clone(self.S) end
	self.TypeOverride = kind
	local info = self._info
	if info then
		info.Type = kind ~= "Auto" and kind or info.AutoType
		self:_applyMode()
		self:_apply(); self:_applyGrip()
		self:_fire()
	end
	return table.clone(self.S)
end

function Vehicle:SetEnabled(on)
	if on == self.Enabled then return end
	self.Enabled = on
	if on then
		self._conn = RunService.Heartbeat:Connect(function(dt) self:_beat(dt) end)
	else
		if self._conn then self._conn:Disconnect(); self._conn = nil end
		self:_leave()
	end
end

-- ENTER / LEAVE -----------------------------------------------------------------------
function Vehicle:_enter(seat)
	local model = findModel(seat)
	local info = {
		Seat = seat, Model = model, Name = model.Name,
		Seats = {}, Motors = {}, Wheels = {}, AttrOrig = {}, FlipT = 0,
	}
	for _, d in model:GetDescendants() do
		if d:IsA("VehicleSeat") then
			table.insert(info.Seats, { Inst = d, MaxSpeed = d.MaxSpeed, Torque = d.Torque, TurnSpeed = d.TurnSpeed })
		elseif d:IsA("HingeConstraint") and d.ActuatorType == Enum.ActuatorType.Motor then
			table.insert(info.Motors, { Inst = d, Torque = d.MotorMaxTorque })
		elseif #info.Wheels < 24 and looksLikeWheel(d) then
			table.insert(info.Wheels, { Inst = d, Orig = d.CustomPhysicalProperties, Base = d.CurrentPhysicalProperties })
		end
	end
	if seat:IsA("VehicleSeat") and #info.Seats == 0 then -- (no model around it: the seat is the whole vehicle)
		table.insert(info.Seats, { Inst = seat, MaxSpeed = seat.MaxSpeed, Torque = seat.Torque, TurnSpeed = seat.TurnSpeed })
	end

	info.AutoType = classify(model, seat, #info.Wheels)
	info.Type = self.TypeOverride ~= "Auto" and self.TypeOverride or info.AutoType

	self._info, self._seat = info, seat
	self:_applyMode()
	self:_apply(); self:_applyGrip()
	self:_fire()
end

function Vehicle:_leave()
	local info = self._info
	if not info then return end
	if self.S.Restore then
		for _, r in info.Seats do
			if r.Inst.Parent then r.Inst.MaxSpeed, r.Inst.Torque, r.Inst.TurnSpeed = r.MaxSpeed, r.Torque, r.TurnSpeed end
		end
		for _, m in info.Motors do
			if m.Inst.Parent then m.Inst.MotorMaxTorque = m.Torque end
		end
		for _, w in info.Wheels do
			if w.Inst.Parent then w.Inst.CustomPhysicalProperties = w.Orig end
		end
		self:RestoreValues()
	end
	if info.Force then info.Force:Destroy() end
	if info.ForceAtt then info.ForceAtt:Destroy() end
	self._info, self._seat = nil, nil
	self:_fire()
end

-- seat / motor values (cheap, re-applied a few times per second in case the game resets them)
function Vehicle:_apply()
	local info, s = self._info, self.S
	if not info then return end
	for _, r in info.Seats do
		local v = r.Inst
		if v.Parent then
			local ms, tq, ts = r.MaxSpeed * s.Speed / 100, r.Torque * s.Torque / 100, r.TurnSpeed * s.Turn / 100
			if v.MaxSpeed ~= ms then v.MaxSpeed = ms end
			if v.Torque ~= tq then v.Torque = tq end
			if v.TurnSpeed ~= ts then v.TurnSpeed = ts end
		end
	end
	for _, m in info.Motors do
		if m.Inst.Parent then
			local tq = m.Torque * s.Torque / 100
			if m.Inst.MotorMaxTorque ~= tq then m.Inst.MotorMaxTorque = tq end
		end
	end
end

function Vehicle:_applyGrip()
	local info, g = self._info, self.S.Grip
	if not info then return end
	for _, w in info.Wheels do
		local part = w.Inst
		if part.Parent then
			if g == 100 then
				part.CustomPhysicalProperties = w.Orig
			else
				local b = w.Base
				part.CustomPhysicalProperties = PhysicalProperties.new(
					b.Density, math.clamp(b.Friction * g / 100, 0, 2), b.Elasticity, 100, b.ElasticityWeight)
			end
		end
	end
end

-- LIVE DRIVING -------------------------------------------------------------------------
function Vehicle:_force(info, root)
	if info.Force and info.Force.Parent == root then return info.Force end
	if info.Force then info.Force:Destroy() end
	if info.ForceAtt then info.ForceAtt:Destroy() end
	local att = Instance.new("Attachment")
	att.Parent = root
	local vf = Instance.new("VectorForce")
	vf.Attachment0 = att
	vf.RelativeTo = Enum.ActuatorRelativeTo.World
	vf.ApplyAtCenterOfMass = true
	vf.Force = Vector3.zero
	vf.Parent = root
	info.Force, info.ForceAtt = vf, att
	return vf
end

-- stand the vehicle back on its wheels where it is
function Vehicle:Upright()
	local info = self._info
	if not info or not info.Seat.Parent then return false end
	local seat = info.Seat
	local cf = seat.CFrame
	local look = flatten(cf.LookVector)
	if look.Magnitude < 0.05 then look = flatten(cf.UpVector) end
	if look.Magnitude < 0.05 then look = Vector3.zAxis end
	local pos = cf.Position + Vector3.new(0, 5, 0)
	local target = CFrame.lookAt(pos, pos + look.Unit)
	if self.OnMove then self.OnMove() end
	info.Model:PivotTo(target * cf:Inverse() * info.Model:GetPivot())
	local root = seat.AssemblyRootPart or seat
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	return true
end

function Vehicle:_beat(dt)
	local hum = self:_humanoid()
	local seat = hum and hum.SeatPart
	if seat ~= self._seat then
		self:_leave()
		if seat then self:_enter(seat) end
	end
	local info = self._info
	if not info then return end

	self._tick += dt
	if self._tick >= 0.25 then
		self._tick = 0
		self:_apply()
	end
	self:_drive(info, dt)
end

function Vehicle:_drive(info, dt)
	local s = self.S
	local seat = info.Seat
	if not seat.Parent then return end
	local root = seat.AssemblyRootPart or seat

	-- low gravity: a constant upward force that cancels part of gravity
	if s.LowGrav > 0 then
		self:_force(info, root).Force = Vector3.new(0, root.AssemblyMass * Workspace.Gravity * s.LowGrav / 100, 0)
	elseif info.Force then
		info.Force.Force = Vector3.zero
	end

	local typing = UserInputService:GetFocusedTextBox() ~= nil
	local throttle = 0
	if not typing then
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then throttle += 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then throttle -= 1 end
		if throttle == 0 and seat:IsA("VehicleSeat") then throttle = math.sign(seat.ThrottleFloat) end
	end

	-- direction the assist pushes in: the seat's facing (ground vehicles stay level)
	local look = seat.CFrame.LookVector
	if info.Type ~= "Aircraft" then
		look = flatten(look)
		if look.Magnitude < 0.01 then return end
		look = look.Unit
	end
	if s.ReverseAxis then look = -look end

	local boosting = s.BoostOn and self.BoostKey ~= nil and not typing and UserInputService:IsKeyDown(self.BoostKey)
	if throttle ~= 0 then
		local v = root.AssemblyLinearVelocity
		local along = v:Dot(look) * throttle
		local accel, cap
		if boosting then
			accel, cap = s.BoostAccel, math.max(s.BoostCap, s.TopSpeed)
		elseif s.TopSpeed > 0 then
			accel, cap = s.Accel, s.TopSpeed
		end
		if accel and along < cap then
			root.AssemblyLinearVelocity = v + look * throttle * accel * dt
		end
	end

	-- handbrake: bleeds speed quickly while the key is held
	if self.BrakeKey and not typing and UserInputService:IsKeyDown(self.BrakeKey) then
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = v * (1 - math.min(1, dt * 5))
	end

	-- anti-flip: upside down and slow for a second -> set the vehicle back on its wheels
	if s.AntiFlip then
		if seat.CFrame.UpVector.Y < 0.2 then info.FlipT += dt else info.FlipT = 0 end
		if info.FlipT > 1 and root.AssemblyLinearVelocity.Magnitude < 40 then
			info.FlipT = 0
			self:Upright()
		end
	end
end

-- ATTRIBUTE EDITOR ---------------------------------------------------------------------
-- Lists numeric Attributes (on the vehicle model and seat) and Number / Int values inside the model.
-- Many games keep their car stats there; a game that only reads them on the server will ignore changes.
function Vehicle:_entries()
	local info = self._info
	local entries, order = {}, {}
	if not info then return entries, order end
	local function add(name, entry)
		local n, i = name, 2
		while entries[n] do n = name .. "#" .. i; i += 1 end
		entries[n] = entry
		table.insert(order, n)
	end
	for _, inst in { info.Model, info.Seat } do
		for k, v in inst:GetAttributes() do
			if type(v) == "number" then add(k, { Inst = inst, Attr = k }) end
		end
	end
	local count = 0
	for _, d in info.Model:GetDescendants() do
		if d:IsA("NumberValue") or d:IsA("IntValue") then
			add(d.Name, { Inst = d })
			count += 1
			if count >= 60 then break end
		end
	end
	table.sort(order)
	return entries, order
end

local function readEntry(e)
	if e.Attr then return e.Inst:GetAttribute(e.Attr) end
	return e.Inst.Value
end

function Vehicle:GetValueNames()
	local _, order = self:_entries()
	return order
end

function Vehicle:GetValue(name)
	local entries = self:_entries()
	local e = entries[name]
	return e and readEntry(e) or nil
end

function Vehicle:SetValue(name, value)
	local info = self._info
	local entries = self:_entries()
	local e = entries[name]
	if not (info and e) or type(value) ~= "number" then return false end
	local keep = info.AttrOrig[e.Inst]
	if not keep then keep = {}; info.AttrOrig[e.Inst] = keep end
	local slot = e.Attr or "\0Value"
	if keep[slot] == nil then keep[slot] = readEntry(e) end
	if e.Attr then e.Inst:SetAttribute(e.Attr, value) else e.Inst.Value = value end
	return true
end

function Vehicle:RestoreValues()
	local info = self._info
	if not info then return end
	for inst, slots in info.AttrOrig do
		if inst.Parent then
			for slot, orig in slots do
				if slot == "\0Value" then inst.Value = orig else inst:SetAttribute(slot, orig) end
			end
		end
	end
	table.clear(info.AttrOrig)
end

function Vehicle:Destroy()
	self:SetEnabled(false)
end

return Vehicle

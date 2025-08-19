# Extra 400 line advanced scripting example
-- ══════════════════════════════════════════════════════════════════════════════════════
-- SERVICES & REFERENCES
-- ══════════════════════════════════════════════════════════════════════════════════════

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local workspace = game:GetService("Workspace")

local PlacedTowersFolder = workspace:WaitForChild("PlacedTowers")
local EnemiesFolder = workspace:WaitForChild("SpawnedMobs")

-- NEW: Reference to tower templates
local TowersFolder = ReplicatedStorage:WaitForChild("Towers")

-- Events
local Events = ReplicatedStorage:WaitForChild("Events")
local AnimTowerEvent = Events:WaitForChild("AnimTower")
local SendRangeEvent = Events:WaitForChild("SendRange")
local UpdateCashGuiEvent = Events:WaitForChild("UpdateCashGui")
local SellTowerEvent = Events:WaitForChild("SellTower")
local AnimFinishedEvent = Events:WaitForChild("AnimFinished")

-- NEW: Event for targeting mode changes
local ChangeTowerTargetEvent = Events:FindFirstChild("ChangeTowerTarget")
if not ChangeTowerTargetEvent then
	ChangeTowerTargetEvent = Instance.new("RemoteEvent")
	ChangeTowerTargetEvent.Name = "ChangeTowerTarget"
	ChangeTowerTargetEvent.Parent = Events
end

-- NEW: Event for tower upgrading
local UpgradeTowerEvent = Events:FindFirstChild("UpgradeTower")
if not UpgradeTowerEvent then
	UpgradeTowerEvent = Instance.new("RemoteEvent")
	UpgradeTowerEvent.Name = "UpgradeTower"
	UpgradeTowerEvent.Parent = Events
end

-- ══════════════════════════════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ══════════════════════════════════════════════════════════════════════════════════════

-- Targeting modes
local TARGET_MODES = {
	FIRST = "first",
	LAST = "last", 
	STRONG = "strong",
	WEAK = "weak"
}

-- Level scaling (NOW ONLY USED FOR UPGRADE COSTS; stats come from model config)
local LEVEL_SCALING = {
	[0] = {upgradeCost = 100},
	[1] = {upgradeCost = 250},
	[2] = {upgradeCost = 500},
	[3] = {upgradeCost = 1000},
	[4] = {upgradeCost = 0} -- Max level
}

-- ══════════════════════════════════════════════════════════════════════════════════════
-- BEHAVIOR HANDLERS (MODULAR)
-- ══════════════════════════════════════════════════════════════════════════════════════

local Behaviors = {
	single = {
		canAttack = function(self)
			local currentTime = tick()
			return currentTime - self.LastAttack >= self.Stats.fireRate
		end,
		attack = function(self, target)
			self:RotateToTarget(target)
			AnimTowerEvent:FireAllClients(self.Model, "Attack")
			target.Humanoid:TakeDamage(self.Stats.damage)
			self.LastAttack = tick()
			return true
		end
	},
	rapid = {
		canAttack = function(self)
			local currentTime = tick()
			return currentTime - self.LastAttack >= self.Stats.fireRate
		end,
		attack = function(self, target)
			self:RotateToTarget(target)
			AnimTowerEvent:FireAllClients(self.Model, "Attack")
			target.Humanoid:TakeDamage(self.Stats.damage)
			self.LastAttack = tick()
			return true
		end
	},
	burst = {
		canAttack = function(self)
			if self.IsReloading then return false end
			local currentTime = tick()
			if currentTime - self.LastAttack < self.Stats.fireRate then return false end
			if self.BurstShots >= self.MaxBurstShots then return false end
			return true
		end,
		attack = function(self, target)
			self:RotateToTarget(target)
			AnimTowerEvent:FireAllClients(self.Model, "Attack")
			target.Humanoid:TakeDamage(self.Stats.damage)
			self.LastAttack = tick()
			self.BurstShots = self.BurstShots + 1
			if self.BurstShots >= self.MaxBurstShots then
				self:StartReload()
			end
			return true
		end,
		startReload = function(self)
			self.IsReloading = true
			print("Reload started for", self.TowerType, "IsReloading:", self.IsReloading)
			self.ReloadStartPosition = self.Model.PrimaryPart.CFrame
			AnimTowerEvent:FireAllClients(self.Model, "Reload")

			-- Single coroutine for reload logic
			coroutine.resume(coroutine.create(function()
				local startTime = tick()
				while self.IsReloading and (tick() - startTime) < self.ReloadTime do
					if self.Model.PrimaryPart and self.ReloadStartPosition then
						self.Model:SetPrimaryPartCFrame(self.ReloadStartPosition)
					end
					task.wait(0.5)
				end
				self.IsReloading = false
				self.BurstShots = 0
				print("🔄", self.TowerType, "reload complete! IsReloading:", self.IsReloading)
			end))
		end
	}
	-- Add more behaviors here as needed
}

-- Tower behaviors mapping (ADD MORE TYPES HERE)
local TOWER_BEHAVIORS = {
	Soldier = "single",
	Striker = "rapid", 
	Burst = "burst",
	Sniper = "single",
	-- ADD NEW TOWER TYPES:
	-- Cannon = "burst",
	-- Rocket = "single", 
	-- Laser = "rapid",
	-- Freezer = "single"
}

-- ══════════════════════════════════════════════════════════════════════════════════════
-- TOWER MANAGEMENT
-- ══════════════════════════════════════════════════════════════════════════════════════

local ActiveTowers = {}

-- ══════════════════════════════════════════════════════════════════════════════════════
-- TOWER CLASS
-- ══════════════════════════════════════════════════════════════════════════════════════

local Tower = {}
Tower.__index = Tower

function Tower.new(model)
	local self = setmetatable({}, Tower)

	self.Model = model
	self.Config = model:WaitForChild("Configuration")
	self.IsActive = true
	self.LastAttack = 0
	self.TargetMode = TARGET_MODES.FIRST
	self.IsReloading = false
	self.BurstShots = 0
	self.MaxBurstShots = 0
	self.ReloadStartPosition = nil

	-- Get stats
	self:LoadStats()
	self:SetupModel()

	-- Set behavior handlers
	self.BehaviorHandlers = Behaviors[self.Behavior] or Behaviors.single

	return self
end

function Tower:GetValue(name, fallback)
	local obj = self.Config:FindFirstChild(name)
	if obj and (obj:IsA("NumberValue") or obj:IsA("StringValue") or obj:IsA("IntValue")) then
		return obj.Value
	end
	return fallback
end

function Tower:LoadStats()
	self.Stats = {
		damage = self:GetValue("Damage", 10),
		fireRate = self:GetValue("Firerate", 1),
		range = self:GetValue("Range", 20),
		level = self:GetValue("Level", 0),
		price = self:GetValue("Price", 100),
		upgradeCost = LEVEL_SCALING[self:GetValue("Level", 0)].upgradeCost
	}

	self.TowerType = self:GetValue("Type", "Soldier")
	self.Behavior = TOWER_BEHAVIORS[self.TowerType] or "single"

	-- Behavior-specific stats
	if self.Behavior == "burst" then
		self.MaxBurstShots = self:GetValue("BurstCount", 3)
		self.ReloadTime = self:GetValue("ReloadTime", 4)  -- CHANGED: Increased to 4 seconds
	end

	print("Tower loaded:", self.TowerType, "Behavior:", self.Behavior, "Level:", self.Stats.level)
end

function Tower:SetupModel()
	local parts = {"Torso", "HumanoidRootPart", "Base", "Main"}
	for _, partName in ipairs(parts) do
		local part = self.Model:FindFirstChild(partName)
		if part and part:IsA("BasePart") then
			self.Model.PrimaryPart = part
			break
		end
	end

	if not self.Model.PrimaryPart then
		local firstPart = self.Model:FindFirstChildWhichIsA("BasePart")
		if firstPart then
			self.Model.PrimaryPart = firstPart
		end
	end
end

-- ══════════════════════════════════════════════════════════════════════════════════════
-- TARGETING SYSTEM
-- ══════════════════════════════════════════════════════════════════════════════════════

function Tower:IsValidTarget(enemy)
	if not enemy or not enemy:IsA("Model") then return false end

	local torso = enemy:FindFirstChild("Torso")
	local humanoid = enemy:FindFirstChild("Humanoid")

	if not torso or not humanoid or humanoid.Health <= 0 then return false end
	if not self.Model.PrimaryPart then return false end

	local distance = (self.Model.PrimaryPart.Position - torso.Position).Magnitude
	return distance <= self.Stats.range
end

function Tower:GetBestTarget()
	local targets = {}

	for _, enemy in ipairs(EnemiesFolder:GetChildren()) do
		if self:IsValidTarget(enemy) then
			table.insert(targets, enemy)
		end
	end

	if #targets == 0 then return nil end

	-- Sort based on target mode
	if self.TargetMode == TARGET_MODES.FIRST then
		table.sort(targets, function(a, b)
			local progA = a:FindFirstChild("Progress")
			local progB = b:FindFirstChild("Progress")
			local valA = progA and progA:IsA("NumberValue") and progA.Value or 0
			local valB = progB and progB:IsA("NumberValue") and progB.Value or 0
			return valA > valB
		end)
	elseif self.TargetMode == TARGET_MODES.STRONG then
		table.sort(targets, function(a, b)
			return a.Humanoid.Health > b.Humanoid.Health
		end)
	elseif self.TargetMode == TARGET_MODES.WEAK then
		table.sort(targets, function(a, b)
			return a.Humanoid.Health < b.Humanoid.Health
		end)
	end

	return targets[1]
end

-- ══════════════════════════════════════════════════════════════════════════════════════
-- COMBAT SYSTEM
-- ══════════════════════════════════════════════════════════════════════════════════════

function Tower:RotateToTarget(target)
	if not target or not target:FindFirstChild("Torso") or not self.Model.PrimaryPart then
		return
	end

	local currentPos = self.Model.PrimaryPart.Position
	local targetPos = target.Torso.Position
	local lookDirection = Vector3.new(targetPos.X, currentPos.Y, targetPos.Z)

	self.Model:SetPrimaryPartCFrame(CFrame.lookAt(currentPos, lookDirection))
end

function Tower:CanAttack()
	return self.BehaviorHandlers.canAttack(self)
end

function Tower:Attack(target)
	if not self:IsValidTarget(target) or not self:CanAttack() then
		return false
	end
	return self.BehaviorHandlers.attack(self, target)
end

function Tower:StartReload()
	if self.BehaviorHandlers.startReload then
		self.BehaviorHandlers.startReload(self)
	end
end

-- ══════════════════════════════════════════════════════════════════════════════════════
-- MAIN BEHAVIOR LOOP
-- ══════════════════════════════════════════════════════════════════════════════════════

function Tower:StartLoop()
	local co = coroutine.create(function()
		print(" Starting loop for:", self.TowerType)

		while self.Model and self.Model.Parent and self.IsActive do
			local target = self:GetBestTarget()

			if target then
				self:Attack(target)
			end

			-- Yield based on fire rate to prevent excessive looping
			local waitTime = self.Stats.fireRate > 0 and self.Stats.fireRate or 0.1
			task.wait(waitTime)
		end

		print("Loop ended for:", self.TowerType)
	end)
	coroutine.resume(co)
end

function Tower:SetTargetMode(mode)
	if TARGET_MODES[mode] then
		self.TargetMode = TARGET_MODES[mode]
		print(self.TowerType, "targeting changed to:", mode)
	end
end

function Tower:Destroy()
	self.IsActive = false
end

-- ══════════════════════════════════════════════════════════════════════════════════════
-- TOWER MANAGEMENT FUNCTIONS
-- ══════════════════════════════════════════════════════════════════════════════════════

local function RegisterTower(towerModel)
	if ActiveTowers[towerModel] then return end

	print("📡 Registering:", towerModel.Name)

	local tower = Tower.new(towerModel)
	if tower then
		ActiveTowers[towerModel] = tower
		tower:StartLoop()
		print(" Registered:", tower.TowerType)
	end
end

local function UnregisterTower(towerModel)
	local tower = ActiveTowers[towerModel]
	if tower then
		print("📤 Unregistering:", tower.TowerType)
		tower:Destroy()
		ActiveTowers[towerModel] = nil
	end
end

local function ScanTowers()
	for _, typeFolder in ipairs(PlacedTowersFolder:GetChildren()) do
		if typeFolder:IsA("Folder") then
			for _, towerModel in ipairs(typeFolder:GetChildren()) do
				if towerModel:IsA("Model") and towerModel:FindFirstChild("Configuration") then
					if not ActiveTowers[towerModel] then
						RegisterTower(towerModel)
					end
				end
			end
		end
	end
end

-- ══════════════════════════════════════════════════════════════════════════════════════
-- EVENT HANDLERS
-- ══════════════════════════════════════════════════════════════════════════════════════

-- Handle targeting mode changes from client
ChangeTowerTargetEvent.OnServerEvent:Connect(function(player, towerModel, targetMode)
	local tower = ActiveTowers[towerModel]
	if tower then
		tower:SetTargetMode(targetMode)
	end
end)

-- Handle tower selling
SellTowerEvent.OnServerEvent:Connect(function(player, towerModel)
	local tower = ActiveTowers[towerModel]
	if not tower then return end
	print(player,towerModel)
	local sellPrice = math.floor(tower.Stats.price * 0.66)

	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats and leaderstats:FindFirstChild("Cash") then
		leaderstats.Cash.Value = leaderstats.Cash.Value + sellPrice
		UpdateCashGuiEvent:FireClient(player,leaderstats.Cash.Value)

		print(" Tower sold for", sellPrice)
		UnregisterTower(towerModel)
		towerModel:Destroy()
	end
end)

-- Handle tower upgrading
UpgradeTowerEvent.OnServerEvent:Connect(function(player, towerModel)
	local tower = ActiveTowers[towerModel]
	if not tower then return end
	print(player,towerModel)
	local currentLevel = tower.Stats.level
	if currentLevel >= 4 then return end

	local upgradeCost = tower.Stats.upgradeCost
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats or not leaderstats:FindFirstChild("Cash") or leaderstats.Cash.Value < upgradeCost then
		return
	end

	leaderstats.Cash.Value = leaderstats.Cash.Value - upgradeCost
	UpdateCashGuiEvent:FireClient(player,leaderstats.Cash.Value)

	local typeFolder = TowersFolder:FindFirstChild(tower.TowerType)
	if not typeFolder then return end
	local nextLevel = currentLevel + 1
	local newModelTemplate = typeFolder:FindFirstChild(tostring(nextLevel))
	if not newModelTemplate then return end

	local newModel = newModelTemplate:Clone()
	newModel.Name = towerModel.Name
	local oldCFrame = towerModel.PrimaryPart.CFrame
	newModel.Parent = towerModel.Parent

	UnregisterTower(towerModel)
	towerModel:Destroy()

	newModel:SetPrimaryPartCFrame(oldCFrame)

	RegisterTower(newModel)

	print("⬆️ Tower upgraded to level", nextLevel)
end)

-- Monitor for new/removed towers
local function SetupMonitoring()
	ScanTowers()

	PlacedTowersFolder.DescendantAdded:Connect(function(obj)
		if obj:IsA("Model") and obj:FindFirstChild("Configuration") then
			task.wait(0.1)
			RegisterTower(obj)
		end
	end)

	PlacedTowersFolder.DescendantRemoving:Connect(function(obj)
		if ActiveTowers[obj] then
			UnregisterTower(obj)
		end
	end)
end

-- ══════════════════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ══════════════════════════════════════════════════════════════════════════════════════

task.wait(1)
SetupMonitoring()

-- Byte | VhieS Kaitun - King Legacy Progression Controller Architecture (Delta ready)
-- Check for table that is shared between executions.
if not shared then
	return warn("No shared, no script.")
end

-- Detach any previous kaitun instance on re-execution.
if shared.KingLegacyKaitun then
	pcall(function() shared.KingLegacyKaitun:stop() end)
end

-- Services.
local playersService = game:GetService("Players")
local replicatedStorage = game:GetService("ReplicatedStorage")
local userInputService = game:GetService("UserInputService")
local virtualUserService = game:GetService("VirtualUser")

local localPlayer = playersService.LocalPlayer

-- Constants.
local CONFIG = {
	ATTACK_DELAY = 0.15,
	HOVER_HEIGHT = 10,
	RESPAWN_WAIT = 2,
	ANALYZE_INTERVAL = 3,
	STUCK_TIMEOUT = 45,
	BOSS_SESSION = 120,
	BOSS_COOLDOWN = 600,
	DEFER_TIME = 300,
	MASTERY_TOOL = "Katana",
	BOSS_PATTERN = "Boss",

	-- Approximate level requirements; tune to the current patch.
	STYLES = {
		{ name = "Black Leg", reqLevel = 50 },
		{ name = "Fishman Karate", reqLevel = 110 },
		{ name = "Rokushiki", reqLevel = 250 },
		{ name = "Electro", reqLevel = 340 },
	},
	SWORDS = {
		{ name = "Cutlass", reqLevel = 10 },
		{ name = "Pipa", reqLevel = 60 },
		{ name = "Shusui", reqLevel = 250 },
		{ name = "Wado Ichimonji", reqLevel = 320 },
	},

	-- Stat names tried in order; the server rejects invalid ones.
	STAT_PRIORITY = { "Melee", "Sword", "Health", "Defense", "Fruit" },
}

-- User preferences; UI toggles flip these at runtime.
local PREFERENCES = {
	autoStats = true,
	autoBuy = true,
	autoBoss = true,
	autoMastery = false,
}

-- Module table.
local Kaitun = {
	running = false,
	status = "IDLE",
	task = nil,
	account = { level = 0, beli = 0, statPoints = 0 },
	log = {},
	ui = nil,
}

-- State.
local remoteCache = {}
local deferredUntil = {}
local bossAvailableAt = 0

---Return a fresh camera reference (survives respawns; Delta safe).
local function getCurrentCamera()
	return workspace.CurrentCamera
end

---Append a message to the kaitun log.
local function log(message)
	local timestamp = tostring(math.floor(os.clock()))
	pcall(function() timestamp = os.date("%H:%M:%S") end)
	table.insert(Kaitun.log, timestamp .. "  " .. message)
	if #Kaitun.log > 8 then
		table.remove(Kaitun.log, 1)
	end
end

---Find and cache the first remote whose name matches any pattern.
---@param kind string
---@param patterns table
---@return Instance?
local function getRemote(kind, patterns)
	if remoteCache[kind] == nil then
		remoteCache[kind] = false
		for _, descendant in ipairs(replicatedStorage:GetDescendants()) do
			if descendant:IsA("RemoteEvent") or descendant:IsA("RemoteFunction") then
				for _, pattern in ipairs(patterns) do
					if descendant.Name:lower():find(pattern:lower(), 1, true) then
						remoteCache[kind] = descendant
						break
					end
				end
			end
			if remoteCache[kind] then break end
		end
	end
	return remoteCache[kind] or nil
end

---Fire any remote safely with variadic args.
local function safeFire(remote, ...)
	if not remote then return end
	if remote:IsA("RemoteEvent") then
		pcall(function() remote:FireServer(...) end)
	else
		pcall(function() remote:InvokeServer(...) end)
	end
end

---Read account state from leaderstats / attributes / player children.
local function readAccount()
	local account = Kaitun.account
	account.level, account.beli, account.statPoints = 0, 0, 0

	-- Check leaderstats, then player children; ipairs would stop at a nil leaderstats.
	local function scanValues(source)
		if not source then return end
		for _, child in ipairs(source:GetChildren()) do
			if child:IsA("IntValue") or child:IsA("NumberValue") then
				local name = child.Name:lower()
				if name:find("level") then
					account.level = child.Value
				elseif name:find("beli") or name:find("money") then
					account.beli = child.Value
				elseif name:find("stat") and name:find("point") then
					account.statPoints = child.Value
				end
			end
		end
	end

	scanValues(localPlayer:FindFirstChild("leaderstats"))
	scanValues(localPlayer)
	if account.level == 0 then
		account.level = localPlayer:GetAttribute("Level") or 0
	end
	return account
end

---Whether the player owns an item (held or backpack, partial name match).
local function ownsItem(itemName)
	local character = localPlayer.Character
	local held = character and character:FindFirstChildOfClass("Tool")
	if held and held.Name:find(itemName, 1, true) then return true end
	for _, tool in ipairs(localPlayer.Backpack:GetChildren()) do
		if tool:IsA("Tool") and tool.Name:find(itemName, 1, true) then return true end
	end
	return false
end

---First unowned shop item in priority order, skipping deferred entries.
local function findNextMissingItem()
	for _, list in ipairs({ CONFIG.STYLES, CONFIG.SWORDS }) do
		for _, entry in ipairs(list) do
			local deferUntil = deferredUntil[entry.name]
			if (not deferUntil or os.clock() > deferUntil) and not ownsItem(entry.name) then
				return entry
			end
		end
	end
end

---Score a tool against both priority lists; lower is better.
local function getToolScore(tool)
	for priority, entry in ipairs(CONFIG.SWORDS) do
		if tool.Name:find(entry.name, 1, true) then return priority end
	end
	for priority, entry in ipairs(CONFIG.STYLES) do
		if tool.Name:find(entry.name, 1, true) then return priority + #CONFIG.SWORDS end
	end
	return math.huge
end

---Equip the best owned tool, honoring mastery preference.
local function equipBestTool(forceMastery)
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local best, bestScore = nil, math.huge
	for _, tool in ipairs(localPlayer.Backpack:GetChildren()) do
		if tool:IsA("Tool") then
			local score = getToolScore(tool)
			if forceMastery and tool.Name:find(CONFIG.MASTERY_TOOL, 1, true) then
				score = 0
			end
			if score < bestScore then
				best, bestScore = tool, score
			end
		end
	end
	if not best then
		best = localPlayer.Backpack:FindFirstChildOfClass("Tool")
	end
	if best and character:FindFirstChildOfClass("Tool") ~= best then
		humanoid:EquipTool(best)
	end
end

---Extract a level from a model name if present.
local function getModelLevel(model)
	local num = model.Name:match("(%d+)")
	return num and tonumber(num) or 0
end

---Pick a mob: prefer the player's level bracket, fall back to nearest.
local function pickMob(characterRoot, wantLevel)
	local nearest, nearestDist = nil, math.huge
	local bracket, bracketScore = nil, math.huge

	for _, model in ipairs(workspace:GetChildren()) do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and not playersService:GetPlayerFromCharacter(model) then
			local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
			if root then
				local dist = (root.Position - characterRoot.Position).Magnitude
				if dist < nearestDist then
					nearest, nearestDist = model, dist
				end

				local mobLevel = getModelLevel(model)
				if wantLevel and mobLevel > 0 then
					local score = math.abs(mobLevel - wantLevel)
					if score < bracketScore then
						bracket, bracketScore = model, score
					end
				end
			end
		end
	end

	return bracket or nearest
end

---Pick the nearest living boss.
local function pickBoss(characterRoot)
	local nearest, nearestDist = nil, math.huge
	for _, model in ipairs(workspace:GetChildren()) do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0
			and model.Name:find(CONFIG.BOSS_PATTERN, 1, true)
			and not playersService:GetPlayerFromCharacter(model) then
			local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
			if root then
				local dist = (root.Position - characterRoot.Position).Magnitude
				if dist < nearestDist then
					nearest, nearestDist = model, dist
				end
			end
		end
	end
	return nearest
end

---Position above a target and face it.
local function hoverTarget(rootPart, targetRoot)
	rootPart.CFrame = targetRoot.CFrame * CFrame.new(0, CONFIG.HOVER_HEIGHT, 0)
	getCurrentCamera().CFrame = CFrame.new(getCurrentCamera().CFrame.Position, targetRoot.Position)
end

---Attack via tool activation with VirtualUser fallback (Delta / mobile safe).
local function attack()
	local character = localPlayer.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	if tool then
		pcall(function() tool:Activate() end)
		return
	end
	pcall(function()
		virtualUserService:CaptureController()
		virtualUserService:ClickButton1(Vector2.new(), getCurrentCamera().CFrame)
	end)
end

-- Ordered analyzers; the first task returned wins and becomes the assigned job.
local ANALYZERS = {
	-- Spend unallocated stat points first.
	function(account)
		if not PREFERENCES.autoStats or account.statPoints <= 0 then return end
		return { module = "Stats", label = "Spend " .. account.statPoints .. " stat points" }
	end,
	-- Buy the next missing style / sword, grinding its level gate first.
	function(account)
		if not PREFERENCES.autoBuy then return end
		local entry = findNextMissingItem()
		if not entry then return end
		if account.level < entry.reqLevel then
			return { module = "Farm", label = "Grind to Lv" .. entry.reqLevel .. " for " .. entry.name }
		end
		return { module = "Buy", item = entry.name, label = "Buy " .. entry.name }
	end,
	-- Time-boxed boss sessions for materials and drops.
	function()
		if not PREFERENCES.autoBoss or os.clock() < bossAvailableAt then return end
		return { module = "Boss", label = "Boss session - materials & drops" }
	end,
	-- Dedicated mastery grinding on the configured tool.
	function()
		if not PREFERENCES.autoMastery then return end
		return { module = "Mastery", label = "Grind " .. CONFIG.MASTERY_TOOL .. " mastery" }
	end,
	-- Default progression: plain leveling farm.
	function(account)
		if findNextMissingItem() then
			Kaitun.status = "PROGRESSION"
			return { module = "Farm", label = "Level grind (Lv" .. account.level .. ")" }
		end
		Kaitun.status = "ENDGAME"
		return { module = "Farm", label = "Endgame grind (Lv" .. account.level .. ")" }
	end,
}

---Run one analysis pass and assign the next task.
local function analyze()
	local account = readAccount()

	-- Expire timed boss sessions and start their cooldown.
	local currentTask = Kaitun.task
	if currentTask and currentTask.expiresAt and os.clock() > currentTask.expiresAt then
		bossAvailableAt = os.clock() + CONFIG.BOSS_COOLDOWN
		log("Boss session ended - cooldown started.")
		Kaitun.task = nil
	end

	-- Stuck detection: defer failed buys, disable dead stat remote.
	currentTask = Kaitun.task
	if currentTask and currentTask.startedAt and os.clock() - currentTask.startedAt > CONFIG.STUCK_TIMEOUT then
		if currentTask.module == "Buy" and currentTask.item then
			deferredUntil[currentTask.item] = os.clock() + CONFIG.DEFER_TIME
			log("Buy stuck, deferring: " .. currentTask.item)
		elseif currentTask.module == "Stats" then
			PREFERENCES.autoStats = false
			warn("Stat remote not responding - autoStats disabled.")
		end
		Kaitun.task = nil
	end

	if Kaitun.task then return end

	for _, analyzer in ipairs(ANALYZERS) do
		local ok, assignedTask = pcall(analyzer, account)
		if ok and assignedTask then
			assignedTask.startedAt = os.clock()
			if assignedTask.module == "Boss" then
				assignedTask.expiresAt = os.clock() + CONFIG.BOSS_SESSION
			end
			Kaitun.task = assignedTask
			log("Task assigned: " .. assignedTask.label)
			return
		end
	end
end

-- Subordinate module: Farm / Mastery grind loop.
task.spawn(function()
	while true do
		if not Kaitun.running then task.wait(0.5) continue end

		local currentTask = Kaitun.task
		local character = localPlayer.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")

		if not (currentTask and (currentTask.module == "Farm" or currentTask.module == "Mastery")
			and rootPart and humanoid and humanoid.Health > 0) then
			task.wait(0.5)
			continue
		end

		local mob = pickMob(rootPart, Kaitun.account.level)
		if not mob then
			task.wait(1)
			continue
		end

		local mobRoot = mob:FindFirstChild("HumanoidRootPart") or mob.PrimaryPart
		if mobRoot then
			hoverTarget(rootPart, mobRoot)
			equipBestTool(currentTask.module == "Mastery")
			attack()
		end

		task.wait(CONFIG.ATTACK_DELAY)
	end
end)

-- Subordinate module: Boss farm loop.
task.spawn(function()
	while true do
		if not Kaitun.running then task.wait(0.5) continue end

		local currentTask = Kaitun.task
		local character = localPlayer.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")

		if not (currentTask and currentTask.module == "Boss"
			and rootPart and humanoid and humanoid.Health > 0) then
			task.wait(0.5)
			continue
		end

		local boss = pickBoss(rootPart)
		if not boss then
			task.wait(CONFIG.RESPAWN_WAIT)
			continue
		end

		local bossRoot = boss:FindFirstChild("HumanoidRootPart") or boss.PrimaryPart
		if bossRoot then
			hoverTarget(rootPart, bossRoot)
			equipBestTool(false)
			attack()
		end

		task.wait(CONFIG.ATTACK_DELAY)
	end
end)

-- Subordinate module: Buy loop, fires the purchase remote for the assigned item.
task.spawn(function()
	while true do
		if not Kaitun.running then task.wait(0.5) continue end

		local currentTask = Kaitun.task
		if not (currentTask and currentTask.module == "Buy" and currentTask.item) then
			task.wait(0.5)
			continue
		end

		safeFire(getRemote("buy", { "Buy", "Purchase", "Shop" }), currentTask.item)
		task.wait(1)
	end
end)

-- Subordinate module: Stats loop, dumps points down the priority list.
task.spawn(function()
	while true do
		if not Kaitun.running then task.wait(0.5) continue end

		local currentTask = Kaitun.task
		if not (currentTask and currentTask.module == "Stats") then
			task.wait(0.5)
			continue
		end

		for _, statName in ipairs(CONFIG.STAT_PRIORITY) do
			safeFire(getRemote("stats", { "Stat", "Upgrade", "Point" }), statName, 1)
		end
		task.wait(1)
	end
end)

-- Controller heartbeat: analyze -> assign -> monitor -> recover.
task.spawn(function()
	while true do
		if Kaitun.running then
			pcall(analyze)
		end
		task.wait(CONFIG.ANALYZE_INTERVAL)
	end
end)

-- Anti-AFK (Delta safe).
localPlayer.Idled:Connect(function()
	pcall(function()
		virtualUserService:CaptureController()
		virtualUserService:ClickButton2(Vector2.new())
	end)
end)

-- Loading screen gate: fire every connection on a matching button.
local PLAY_PATTERNS = { "play", "enter", "start", "spawn" }

---Fire all connections of a button across common press signals.
local function tapButton(button)
	local fired = false
	for _, signalName in ipairs({ "Activated", "MouseButton1Click", "MouseButton1Down" }) do
		local ok, connections = pcall(getconnections, button[signalName])
		if ok and connections then
			for _, connection in ipairs(connections) do
				pcall(function() connection:Fire() end)
				fired = true
			end
		end
	end
	return fired
end

---Scan the PlayerGui for a loading screen Play button and tap it.
local function autoTapPlay()
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	if not playerGui then return end

	for _, descendant in ipairs(playerGui:GetDescendants()) do
		local isButton = descendant:IsA("TextButton") or descendant:IsA("ImageButton")
		if isButton and descendant.Visible then
			local text = (descendant:IsA("TextButton") and descendant.Text or descendant.Name):lower()
			for _, pattern in ipairs(PLAY_PATTERNS) do
				-- Word-boundary match so "Player list" is not tapped.
				if text:find("%f[%a]" .. pattern .. "%f[%A]") then
					if tapButton(descendant) then
						log("Tapped loading button: " .. descendant.Text)
					end
					break
				end
			end
		end
	end
end

-- Keep tapping Play until a character actually spawns.
task.spawn(function()
	while true do
		local character = localPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			pcall(autoTapPlay)
		end
		task.wait(2)
	end
end)

---Pick a safe GUI parent (hidden UI container when available).
local function getGuiParent()
	local ok, hui = pcall(function() return gethui() end)
	if ok and hui then return hui end
	local okCore, coreGui = pcall(function() return game:GetService("CoreGui") end)
	if okCore and coreGui then return coreGui end
	return localPlayer:WaitForChild("PlayerGui")
end

---Create a text button with rounded corners and a click callback.
local function makeButton(parent, text, position, size, callback)
	local button = Instance.new("TextButton")
	button.Text = text
	button.TextScaled = true
	button.Font = Enum.Font.GothamBold
	button.TextColor3 = Color3.fromRGB(240, 240, 240)
	button.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
	button.Size = size
	button.Position = position
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Parent = parent
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 6)
	button.MouseButton1Click:Connect(callback)
	return button
end

---Build the control and monitoring interface (mobile friendly).
local function createUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "VhieSKaitun"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 999
	screenGui.Parent = getGuiParent()

	local main = Instance.new("Frame")
	main.Size = UDim2.fromOffset(270, 340)
	main.Position = UDim2.new(0, 12, 0.5, -170)
	main.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
	main.BorderSizePixel = 0
	main.Active = true
	main.Parent = screenGui
	Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)

	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, 32)
	header.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
	header.BorderSizePixel = 0
	header.Active = true
	header.Parent = main
	Instance.new("UICorner", header).CornerRadius = UDim.new(0, 8)

	local title = Instance.new("TextLabel")
	title.Text = "Byte | VhieS Kaitun"
	title.TextScaled = true
	title.Font = Enum.Font.GothamBold
	title.TextColor3 = Color3.fromRGB(240, 240, 240)
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -10, 1, 0)
	title.Position = UDim2.new(0, 5, 0, 0)
	title.Parent = header

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Text = "Status: IDLE"
	statusLabel.TextScaled = true
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextColor3 = Color3.fromRGB(120, 200, 255)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Size = UDim2.new(1, -10, 0, 20)
	statusLabel.Position = UDim2.new(0, 5, 0, 36)
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.Parent = main

	local taskLabel = Instance.new("TextLabel")
	taskLabel.Text = "Task: none"
	taskLabel.TextScaled = true
	taskLabel.Font = Enum.Font.Gotham
	taskLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
	taskLabel.BackgroundTransparency = 1
	taskLabel.Size = UDim2.new(1, -10, 0, 20)
	taskLabel.Position = UDim2.new(0, 5, 0, 56)
	taskLabel.TextXAlignment = Enum.TextXAlignment.Left
	taskLabel.Parent = main

	local accountLabel = Instance.new("TextLabel")
	accountLabel.Text = "Lv 0 | Beli 0 | SP 0"
	accountLabel.TextScaled = true
	accountLabel.Font = Enum.Font.Gotham
	accountLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	accountLabel.BackgroundTransparency = 1
	accountLabel.Size = UDim2.new(1, -10, 0, 18)
	accountLabel.Position = UDim2.new(0, 5, 0, 76)
	accountLabel.TextXAlignment = Enum.TextXAlignment.Left
	accountLabel.Parent = main

	-- Progress bar toward the next unlock's level gate.
	local barBack = Instance.new("Frame")
	barBack.Size = UDim2.new(1, -10, 0, 14)
	barBack.Position = UDim2.new(0, 5, 0, 98)
	barBack.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
	barBack.BorderSizePixel = 0
	barBack.Parent = main
	Instance.new("UICorner", barBack).CornerRadius = UDim.new(0, 6)

	local barFill = Instance.new("Frame")
	barFill.Size = UDim2.new(0, 0, 1, 0)
	barFill.BackgroundColor3 = Color3.fromRGB(80, 170, 255)
	barFill.BorderSizePixel = 0
	barFill.Parent = barBack
	Instance.new("UICorner", barFill).CornerRadius = UDim.new(0, 6)

	local barText = Instance.new("TextLabel")
	barText.Text = "0%"
	barText.TextScaled = true
	barText.Font = Enum.Font.GothamBold
	barText.TextColor3 = Color3.fromRGB(240, 240, 240)
	barText.BackgroundTransparency = 1
	barText.Size = UDim2.new(1, 0, 1, 0)
	barText.ZIndex = 2
	barText.Parent = barBack

	-- Log window (last 8 lines).
	local logLabel = Instance.new("TextLabel")
	logLabel.Text = ""
	logLabel.TextWrapped = true
	logLabel.Font = Enum.Font.Code
	logLabel.TextSize = 12
	logLabel.TextColor3 = Color3.fromRGB(160, 160, 160)
	logLabel.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
	logLabel.BorderSizePixel = 0
	logLabel.TextXAlignment = Enum.TextXAlignment.Left
	logLabel.TextYAlignment = Enum.TextYAlignment.Bottom
	logLabel.Size = UDim2.new(1, -10, 0, 84)
	logLabel.Position = UDim2.new(0, 5, 0, 116)
	logLabel.ClipsDescendants = true
	logLabel.Parent = main
	Instance.new("UICorner", logLabel).CornerRadius = UDim.new(0, 6)

	-- Preference toggles (2x2 grid).
	local toggleButtons = {}
	toggleButtons.autoStats = makeButton(main, "Stats: ON", UDim2.new(0, 5, 0, 206), UDim2.new(0.5, -8, 0, 26), function()
		PREFERENCES.autoStats = not PREFERENCES.autoStats
	end)
	toggleButtons.autoBuy = makeButton(main, "Buy: ON", UDim2.new(0.5, 3, 0, 206), UDim2.new(0.5, -8, 0, 26), function()
		PREFERENCES.autoBuy = not PREFERENCES.autoBuy
	end)
	toggleButtons.autoBoss = makeButton(main, "Boss: ON", UDim2.new(0, 5, 0, 236), UDim2.new(0.5, -8, 0, 26), function()
		PREFERENCES.autoBoss = not PREFERENCES.autoBoss
	end)
	toggleButtons.autoMastery = makeButton(main, "Mastery: OFF", UDim2.new(0.5, 3, 0, 236), UDim2.new(0.5, -8, 0, 26), function()
		PREFERENCES.autoMastery = not PREFERENCES.autoMastery
	end)

	-- Start / stop control.
	local startButton = makeButton(main, "STOP", UDim2.new(0, 5, 0, 270), UDim2.new(1, -10, 0, 30), function()
		Kaitun.running = not Kaitun.running
		if not Kaitun.running then
			Kaitun.task = nil
			Kaitun.status = "IDLE"
			log("Kaitun stopped by user.")
		else
			log("Kaitun started by user.")
		end
	end)

	-- Drag support for mouse and touch.
	local dragging, dragStart, startPos = false, nil, nil
	header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = main.Position
		end
	end)
	userInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
	userInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	-- UI refresh loop: mirrors controller state every half second.
	task.spawn(function()
		while screenGui.Parent do
			local account = readAccount()
			statusLabel.Text = "Status: " .. Kaitun.status
			taskLabel.Text = "Task: " .. (Kaitun.task and Kaitun.task.label or "none")
			accountLabel.Text = ("Lv %d | Beli %d | SP %d"):format(account.level, account.beli, account.statPoints)

			-- Progress toward the next unlock's level gate.
			local nextEntry = findNextMissingItem()
			local targetLevel = nextEntry and nextEntry.reqLevel or math.max(account.level, 1)
			local pct = math.clamp(account.level / targetLevel, 0, 1)
			barFill.Size = UDim2.new(pct, 0, 1, 0)
			barText.Text = ("Lv %d / %d (%d%%)"):format(account.level, targetLevel, math.floor(pct * 100))

			-- Mirror toggle states.
			toggleButtons.autoStats.Text = "Stats: " .. (PREFERENCES.autoStats and "ON" or "OFF")
			toggleButtons.autoBuy.Text = "Buy: " .. (PREFERENCES.autoBuy and "ON" or "OFF")
			toggleButtons.autoBoss.Text = "Boss: " .. (PREFERENCES.autoBoss and "ON" or "OFF")
			toggleButtons.autoMastery.Text = "Mastery: " .. (PREFERENCES.autoMastery and "ON" or "OFF")
			for key, button in pairs(toggleButtons) do
				button.BackgroundColor3 = PREFERENCES[key] and Color3.fromRGB(60, 160, 90) or Color3.fromRGB(45, 45, 55)
			end
			startButton.Text = Kaitun.running and "STOP" or "START"
			startButton.BackgroundColor3 = Kaitun.running and Color3.fromRGB(170, 60, 60) or Color3.fromRGB(60, 160, 90)

			logLabel.Text = table.concat(Kaitun.log, "\n")
			task.wait(0.5)
		end
	end)

	Kaitun.ui = screenGui
end

---Stop the kaitun and clean up the UI.
function Kaitun:stop()
	self.running = false
	self.task = nil
	self.status = "STOPPED"
	if self.ui then
		self.ui:Destroy()
		self.ui = nil
	end
end

---Initialize the kaitun: UI first, then hand control to the controller.
local function initialize()
	-- Build the UI immediately so the user always sees feedback.
	createUI()
	Kaitun.running = true
	Kaitun.status = "PROGRESSION"
	log("Kaitun initialized - analyzing account.")

	-- Log executor identity without risking initialization.
	pcall(function()
		log("Executor: " .. tostring(identifyexecutor and (identifyexecutor()) or "unknown"))
	end)

	-- Non-blocking loaded wait; UI and auto-tap already run.
	task.spawn(function()
		if not game:IsLoaded() then
			game.Loaded:Wait()
		end
		log("Game loaded.")
	end)
end

---This is called when initialization errors.
---@param err string
local function onInitializeError(err)
	warn("Failed to initialize kaitun.")
	warn(err)
	warn(debug.traceback())
end

-- Safely initialize and handle errors.
xpcall(initialize, onInitializeError)

-- Expose the singleton for re-execution handling.
shared.KingLegacyKaitun = Kaitun

return Kaitun

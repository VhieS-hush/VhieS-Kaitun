-- Byte | VhieS Kaitun v4 - King Legacy Progression Controller (Delta ready)
-- Mechanics mapped from the game's real remotes (EtcFunction / Quest / SkillAction).
-- Check for table that is shared between executions.
if not shared then
	return warn("No shared, no script.")
end

-- Detach any previous kaitun instance on re-execution.
if shared.VhieSKaitun then
	pcall(function() shared.VhieSKaitun:stop() end)
end

-- Services.
local playersService = game:GetService("Players")
local replicatedStorage = game:GetService("ReplicatedStorage")
local userInputService = game:GetService("UserInputService")
local virtualUserService = game:GetService("VirtualUser")

local localPlayer = playersService.LocalPlayer

-- Constants.
local CONFIG = {
	ATTACK_DELAY = 0.1,
	HOVER_HEIGHT = 15,
	AREA_LOAD_HEIGHT = 20,
	RESPAWN_WAIT = 2,
	ANALYZE_INTERVAL = 3,
	STUCK_TIMEOUT = 45,
	BOSS_SESSION = 150,
	BOSS_COOLDOWN = 420,
	MASTERY_TOOL = "",

	-- Stat dump order; points go down the list until empty.
	STAT_PRIORITY = { "Melee", "Defense", "Sword", "Fruit" },

	-- ToolTip based weapon preference; lower wins.
	TOOLTIP_SCORE = {
		["Sword"] = 1,
		["Combat"] = 2,
		["Fruit Power"] = 3,
	},
}

-- User preferences; UI toggles flip these at runtime.
local PREFERENCES = {
	autoStats = true,
	autoBoss = true,
	autoMastery = false,
}

-- Module table.
local Kaitun = {
	running = false,
	status = "IDLE",
	task = nil,
	account = { level = 0, beli = 0, points = 0 },
	log = {},
	ui = nil,
}

-- State.
local deferredUntil = {}
local bossAvailableAt = 0
local maxQuestLevel = 0
local targetPart = nil

---Append a message to the kaitun log.
local function log(message)
	local timestamp = tostring(math.floor(os.clock()))
	pcall(function() timestamp = os.date("%H:%M:%S") end)
	table.insert(Kaitun.log, timestamp .. "  " .. message)
	if #Kaitun.log > 8 then
		table.remove(Kaitun.log, 1)
	end
end

---Return a fresh camera reference (survives respawns; Delta safe).
local function getCurrentCamera()
	return workspace.CurrentCamera
end

---Resolve the game's Functions remote container.
local function getFunctions()
	local chest = replicatedStorage:FindFirstChild("Chest")
	if not chest then return end
	local remotes = chest:FindFirstChild("Remotes")
	if not remotes then return end
	return remotes:FindFirstChild("Functions")
end

---Fire a remote function safely with variadic args.
local function safeInvoke(remote, ...)
	if not remote then return end
	pcall(function() remote:InvokeServer(...) end)
end

---Read account state from PlayerStats.
local function readAccount()
	local account = Kaitun.account
	account.level, account.beli, account.points = 0, 0, 0

	local ok = pcall(function()
		local stats = localPlayer.PlayerStats
		account.level = stats.lvl.Value
		account.beli = stats.beli.Value
		account.points = stats.Points.Value
	end)
	return account
end

---Whether the quest matching this title is currently active.
local function isQuestActive(title)
	local currentQuest = localPlayer:FindFirstChild("CurrentQuest")
	return currentQuest ~= nil and currentQuest.Value == title
end

---Load quest entries from the game's QuestManager module.
local function getQuestEntries()
	local chest = replicatedStorage:FindFirstChild("Chest")
	local modules = chest and chest:FindFirstChild("Modules")
	local questManager = modules and modules:FindFirstChild("QuestManager")
	if not questManager then return {} end

	local ok, data = pcall(function()
		if setthreadidentity then setthreadidentity(2) end
		local result = require(questManager)
		if setthreadidentity then setthreadidentity(8) end
		return result
	end)
	if not ok or typeof(data) ~= "table" then return {} end

	local entries = {}
	for questTitle, info in pairs(data) do
		if typeof(info) == "table" and not info.DailyQuest and typeof(info.Mob) == "string" then
			local level = tonumber(info.Mob:match("Lv%.%s*(%d+)")) or tonumber(info.Level) or 0
			table.insert(entries, { title = questTitle, mob = info.Mob, level = level })
		end
	end
	return entries
end

---Pick the highest quest the player qualifies for; refreshes maxQuestLevel.
local function pickQuest(level)
	local entries = getQuestEntries()
	local best, bestLevel = nil, -1

	maxQuestLevel = 0
	for _, entry in ipairs(entries) do
		if entry.level > maxQuestLevel then
			maxQuestLevel = entry.level
		end
		if entry.level <= level and entry.level > bestLevel then
			best, bestLevel = entry, entry.level
		end
	end
	return best
end

---Pick the quest NPC with the highest LevelMin the player qualifies for.
local function pickQuestNPC(level)
	local npcFolder = workspace:FindFirstChild("AllNPC")
	if not npcFolder then return end

	local best, bestMin = nil, -1
	for _, npc in ipairs(npcFolder:GetChildren()) do
		local levelMin = npc:GetAttribute("LevelMin")
		if levelMin and levelMin <= level and levelMin > bestMin then
			best, bestMin = npc, levelMin
		end
	end
	return best
end

---Score a tool by its ToolTip; lower is better.
local function getToolScore(tool)
	local tip = tool.ToolTip
	if CONFIG.MASTERY_TOOL ~= "" and tool.Name:find(CONFIG.MASTERY_TOOL, 1, true) then
		return 0
	end
	return CONFIG.TOOLTIP_SCORE[tip] or math.huge
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
			if not forceMastery and score == 0 then
				score = 1
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

---Find a loaded mob model by name across monster containers.
local function findMob(mobName)
	for _, folderName in ipairs({ "Monster", "SeaMonster" }) do
		local root = workspace:FindFirstChild(folderName)
		if root then
			for _, sub in ipairs(root:GetChildren()) do
				local mob = sub:FindFirstChild(mobName)
				if mob then return mob end
			end
		end
	end
end

---Find the spawn CFrame of a mob from the server MOB list (loads the area).
local function findMobSpawn(mobName)
	local mobFolder = replicatedStorage:FindFirstChild("MOB")
	if not mobFolder then return end
	local serverMob = mobFolder:FindFirstChild(mobName)
	if serverMob then
		return serverMob:GetModelCFrame() or serverMob:GetPivot()
	end
end

---Keep a BodyClip on the root while farming so teleports don't fling us.
local function setBodyClip(enabled)
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local clip = root:FindFirstChild("BodyClip")
	if enabled then
		if not clip then
			clip = Instance.new("BodyVelocity")
			clip.Name = "BodyClip"
			clip.MaxForce = Vector3.new(5, math.huge, 5)
			clip.Velocity = Vector3.new(0, 0, 0)
			clip.Parent = root
		end
	elseif clip then
		clip:Destroy()
	end
end

---Position above a target and face it.
local function hoverTarget(rootPart, targetRoot)
	rootPart.CFrame = targetRoot.CFrame * CFrame.new(0, CONFIG.HOVER_HEIGHT, 0)
	getCurrentCamera().CFrame = CFrame.new(getCurrentCamera().CFrame.Position, targetRoot.Position)
end

---Attack via the real SkillAction remote with tool fallback.
local function attack()
	local character = localPlayer.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	if not (tool and targetPart) then return end

	-- Map ToolTip to the game's skill prefix (SW / FS / FP).
	local prefix = CONFIG.TOOLTIP_SCORE[tool.ToolTip] == 1 and "SW_"
		or CONFIG.TOOLTIP_SCORE[tool.ToolTip] == 2 and "FS_"
		or "FP_"

	local functions = getFunctions()
	if functions and functions:FindFirstChild("SkillAction") then
		safeInvoke(functions.SkillAction, prefix .. tool.Name .. "_M1")
		return
	end
	pcall(function() tool:Activate() end)
end

-- Namecall hook: redirect skill MouseHit to the current farm target.
local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
	local method = getnamecallmethod()
	if method == "InvokeServer" and tostring(self) == "SkillAction" then
		local args = { ... }
		local payload = args[3]
		if typeof(payload) == "table" and (payload.Type == "Down" or payload.Type == "Up") and targetPart then
			payload.MouseHit = targetPart
			return oldNamecall(self, unpack(args))
		end
	end
	return oldNamecall(self, ...)
end))

-- Ordered analyzers; the first task returned wins and becomes the assigned job.
local ANALYZERS = {
	-- Spend unallocated stat points first.
	function(account)
		if not PREFERENCES.autoStats or account.points <= 0 then return end
		return { module = "Stats", label = "Spend " .. account.points .. " stat points" }
	end,
	-- Time-boxed boss sessions for drops.
	function()
		if not PREFERENCES.autoBoss or os.clock() < bossAvailableAt then return end
		return { module = "Boss", label = "Boss session - drops" }
	end,
	-- Dedicated mastery grinding on the configured tool.
	function()
		if not PREFERENCES.autoMastery or CONFIG.MASTERY_TOOL == "" then return end
		return { module = "Mastery", label = "Grind " .. CONFIG.MASTERY_TOOL .. " mastery" }
	end,
	-- Default progression: quest-based leveling farm.
	function(account)
		local quest = pickQuest(account.level)
		if not quest then
			Kaitun.status = "ENDGAME"
			return { module = "Farm", label = "Endgame grind (Lv" .. account.level .. ")", quest = nil }
		end
		if account.level >= maxQuestLevel then
			Kaitun.status = "ENDGAME"
		else
			Kaitun.status = "PROGRESSION"
		end
		return { module = "Farm", label = quest.mob .. " (Lv" .. account.level .. ")", quest = quest }
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

	-- Stuck detection for actionable tasks.
	currentTask = Kaitun.task
	if currentTask and currentTask.startedAt and os.clock() - currentTask.startedAt > CONFIG.STUCK_TIMEOUT then
		if currentTask.module == "Stats" then
			PREFERENCES.autoStats = false
			warn("Stats remote not responding - autoStats disabled.")
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

-- Subordinate module: Farm / Mastery quest loop.
task.spawn(function()
	while true do
		if not Kaitun.running then
			targetPart = nil
			setBodyClip(false)
			task.wait(0.5)
			continue
		end

		local currentTask = Kaitun.task
		local character = localPlayer.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")

		if not (currentTask and (currentTask.module == "Farm" or currentTask.module == "Mastery")
			and rootPart and humanoid and humanoid.Health > 0) then
			targetPart = nil
			setBodyClip(false)
			task.wait(0.5)
			continue
		end

		local mobName = currentTask.quest and currentTask.quest.mob

		-- Accept the quest when it is not already active.
		if mobName and not isQuestActive(currentTask.quest.title) then
			local npc = pickQuestNPC(Kaitun.account.level)
			if npc then
				hoverTarget(rootPart, npc)
			end
			local functions = getFunctions()
			if functions then
				safeInvoke(functions:FindFirstChild("Quest"), "take", currentTask.quest.title)
			end
			task.wait(0.5)
		end

		-- Locate the target; teleport to its spawn point if not loaded yet.
		local mob = mobName and findMob(mobName)
		if not (mob and mob:FindFirstChild("HumanoidRootPart") and mob.Humanoid.Health > 0) then
			local spawnCFrame = mobName and findMobSpawn(mobName)
			if spawnCFrame then
				rootPart.CFrame = spawnCFrame * CFrame.new(0, CONFIG.AREA_LOAD_HEIGHT, 0)
			end
			targetPart = nil
			task.wait(1)
			continue
		end

		-- Engage: hover above, keep the no-clip body, attack through the remote.
		local mobRoot = mob.HumanoidRootPart
		targetPart = mobRoot
		setBodyClip(true)
		hoverTarget(rootPart, mobRoot)
		equipBestTool(currentTask.module == "Mastery")
		attack()

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
			targetPart = nil
			setBodyClip(false)
			task.wait(0.5)
			continue
		end

		-- Bosses live in Monster.Boss; fall back to a spawn point teleport.
		local bossRoot = nil
		local bossFolder = workspace:FindFirstChild("Monster")
		bossFolder = bossFolder and bossFolder:FindFirstChild("Boss")
		if bossFolder then
			local nearest, nearestDist = nil, math.huge
			for _, boss in ipairs(bossFolder:GetChildren()) do
				local hrp = boss:FindFirstChild("HumanoidRootPart")
				local bh = boss:FindFirstChild("Humanoid")
				if hrp and bh and bh.Health > 0 then
					local dist = (hrp.Position - rootPart.Position).Magnitude
					if dist < nearestDist then
						bossRoot, nearestDist = hrp, dist
					end
				end
			end
		end

		if bossRoot then
			targetPart = bossRoot
			setBodyClip(true)
			hoverTarget(rootPart, bossRoot)
			equipBestTool(false)
			attack()
		else
			targetPart = nil
			setBodyClip(false)
			task.wait(CONFIG.RESPAWN_WAIT)
		end

		task.wait(CONFIG.ATTACK_DELAY)
	end
end)

-- Subordinate module: Stats loop, dumps points one by one via the stats GUI remote.
task.spawn(function()
	while true do
		if not Kaitun.running then task.wait(0.5) continue end

		local currentTask = Kaitun.task
		if not (currentTask and currentTask.module == "Stats") then
			task.wait(0.5)
			continue
		end

		local ok = pcall(function()
			local statsFrame = localPlayer.PlayerGui.MainGui.StarterFrame.StatsFrame
			local statIndex = 1
			for _ = 1, 10 do
				local account = readAccount()
				if account.points <= 0 then break end
				statIndex = statIndex > #CONFIG.STAT_PRIORITY and 1 or statIndex
				statsFrame.RemoteEvent:FireServer(CONFIG.STAT_PRIORITY[statIndex], 1)
				statIndex = statIndex + 1
				task.wait(0.1)
			end
		end)
		if not ok then
			task.wait(2)
		end
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

-- Anti-AFK (matches the game's proven pattern).
localPlayer.Idled:Connect(function()
	pcall(function()
		virtualUserService:Button2Down(Vector2.new(0, 0), getCurrentCamera().CFrame)
		task.wait(1)
		virtualUserService:Button2Up(Vector2.new(0, 0), getCurrentCamera().CFrame)
	end)
end)

-- Loading screen gate: real remote first, UI tap fallback.
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

-- Keep accepting the game until a character actually spawns.
task.spawn(function()
	while true do
		local character = localPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			local functions = getFunctions()
			if functions then
				safeInvoke(functions:FindFirstChild("EtcFunction"), "EnterTheGame", {})
			end
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
	title.Text = "Byte | VhieS Kaitun v4"
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

	-- Progress bar toward the sea's max quest level.
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
	toggleButtons.autoBoss = makeButton(main, "Boss: ON", UDim2.new(0.5, 3, 0, 206), UDim2.new(0.5, -8, 0, 26), function()
		PREFERENCES.autoBoss = not PREFERENCES.autoBoss
	end)
	toggleButtons.autoMastery = makeButton(main, "Mastery: OFF", UDim2.new(0, 5, 0, 236), UDim2.new(0.5, -8, 0, 26), function()
		PREFERENCES.autoMastery = not PREFERENCES.autoMastery
	end)
	local questButton = makeButton(main, "Reanalyze", UDim2.new(0.5, 3, 0, 236), UDim2.new(0.5, -8, 0, 26), function()
		Kaitun.task = nil
		log("Forced reanalyze.")
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
			accountLabel.Text = ("Lv %d | Beli %d | SP %d"):format(account.level, account.beli, account.points)

			-- Progress toward the sea's max quest level.
			local targetLevel = maxQuestLevel > 0 and maxQuestLevel or math.max(account.level, 1)
			local pct = math.clamp(account.level / targetLevel, 0, 1)
			barFill.Size = UDim2.new(pct, 0, 1, 0)
			barText.Text = ("Lv %d / %d (%d%%)"):format(account.level, targetLevel, math.floor(pct * 100))

			-- Mirror toggle states.
			toggleButtons.autoStats.Text = "Stats: " .. (PREFERENCES.autoStats and "ON" or "OFF")
			toggleButtons.autoBoss.Text = "Boss: " .. (PREFERENCES.autoBoss and "ON" or "OFF")
			toggleButtons.autoMastery.Text = "Mastery: " .. (PREFERENCES.autoMastery and "ON" or "OFF")
			toggleButtons.autoStats.BackgroundColor3 = PREFERENCES.autoStats and Color3.fromRGB(60, 160, 90) or Color3.fromRGB(45, 45, 55)
			toggleButtons.autoBoss.BackgroundColor3 = PREFERENCES.autoBoss and Color3.fromRGB(60, 160, 90) or Color3.fromRGB(45, 45, 55)
			toggleButtons.autoMastery.BackgroundColor3 = PREFERENCES.autoMastery and Color3.fromRGB(60, 160, 90) or Color3.fromRGB(45, 45, 55)
			questButton.BackgroundColor3 = Color3.fromRGB(80, 80, 140)

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
	log("Kaitun v4 initialized.")

	-- Log executor identity without risking initialization.
	pcall(function()
		log("Executor: " .. tostring(identifyexecutor and (identifyexecutor()) or "unknown"))
	end)

	-- Non-blocking loaded wait; UI and auto-accept already run.
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
shared.VhieSKaitun = Kaitun

return Kaitun

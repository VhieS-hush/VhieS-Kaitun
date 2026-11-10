-- VhieS SC | Adopt Me Auto Farm Hub
-- Execute this in Delta

local UI_LIBRARY_URL = "https://cdn.project-reverse.org/wave-ui.luau"

local function createSessionFiles()
	local files = {}
	local folders = { [""] = true }
	local function normalize(path)
		assert(type(path) == "string", "File path must be a string")
		local segments = {}
		for segment in path:gsub("\\", "/"):gmatch("[^/]+") do
			if segment == ".." then assert(#segments > 0, "File path escapes the session root") table.remove(segments) continue end
			if segment ~= "." then segments[#segments + 1] = segment end
		end
		return table.concat(segments, "/")
	end
	local function parent(path) return path:match("^(.*)/[^/]+$") or "" end
	local function makeFolder(path)
		path = normalize(path)
		local prefix = ""
		for segment in path:gmatch("[^/]+") do
			prefix = if prefix == "" then segment else prefix .. "/" .. segment
			folders[prefix] = true
		end
	end
	local function writeFile(path, contents)
		assert(type(contents) == "string") path = normalize(path) assert(path ~= "")
		makeFolder(parent(path)) files[path] = contents
	end
	local function readFile(path) local c = files[normalize(path)] assert(c ~= nil, "File does not exist") return c end
	local function listFiles(path)
		path = normalize(path) local result = {}
		for name in files do if parent(name) == path then result[#result+1] = name end end
		for name in folders do if name ~= "" and parent(name) == path then result[#result+1] = name end end
		table.sort(result) return result
	end
	local function deleteFolder(path)
		path = normalize(path) assert(path ~= "") local prefix = path .. "/"
		for name in files do if name:sub(1,#prefix)==prefix then files[name]=nil end end
		for name in folders do if name==path or name:sub(1,#prefix)==prefix then folders[name]=nil end end
	end
	local function unavailableAsset() return "" end
	return {
		readfile=readFile, writefile=writeFile,
		appendfile=function(path,contents) writeFile(path,(files[normalize(path)] or "")..contents) end,
		isfile=function(path) return files[normalize(path)]~=nil end,
		isfolder=function(path) return folders[normalize(path)]==true end,
		makefolder=makeFolder, listfiles=listFiles,
		delfile=function(path) files[normalize(path)]=nil end,
		delfolder=deleteFolder, getcustomasset=unavailableAsset, getsynasset=unavailableAsset,
	}
end

local function createEnvironment(uiSource)
	local host = getfenv()
	local executor = type(getgenv)=="function" and getgenv() or host
	local hostGame = game
	local hostCompile = loadstring
	local hostHttp = hostGame:GetService("HttpService")
	local environment = {} local serviceCache = {} local denied = {}
	local function lookup(name) local v=host[name] if v~=nil then return v end return executor[name] end
	for name in string.gmatch([[
		assert error pcall xpcall pairs ipairs next select tonumber tostring type typeof
		rawget rawset rawequal rawlen setmetatable getmetatable unpack print warn
		buffer bit32 string table math coroutine vector os utf8 task wait spawn delay tick time
		Enum Instance Color3 Vector2 Vector3 Vector2int16 Vector3int16 CFrame UDim UDim2 Rect
		Ray Region3 Region3int16 BrickColor TweenInfo Font NumberRange NumberSequence
		NumberSequenceKeypoint ColorSequence ColorSequenceKeypoint PhysicalProperties
		RaycastParams OverlapParams Axes Faces DateTime Random PathWaypoint Content
		Drawing gethui protectgui firetouchinterest fireclickdetector fireproximityprompt
		sethiddenproperty gethiddenproperty setclipboard toclipboard setfpscap getfpscap
		isnetworkowner getconnections getgc getrawmetatable setrawmetatable setreadonly
		isreadonly checkcaller getnamecallmethod newcclosure iscclosure islclosure hookfunction hookmetamethod
		restorefunction mouse1press mouse1release mouse1click mouse2press mouse2release
		mouse2click mousemoverel mousemoveabs keypress keyrelease setthreadidentity
		set_thread_identity setidentity getthreadidentity identifyexecutor
		UserSettings settings version
	]], "%S+") do environment[name]=lookup(name) end
	for name, callback in createSessionFiles() do environment[name]=callback end
	local hostDebug=lookup("debug")
	if hostDebug then environment.debug={info=hostDebug.info,traceback=hostDebug.traceback} end
	environment._G=environment environment.shared={}
	environment.getgenv=function() return environment end
	environment.getfenv=function() return environment end
	environment.getrenv=function() return environment end
	environment.setfenv=function(callback) return setfenv(callback,environment) end
	local function unavailable(route)
		local path=tostring(route):match("^[^?]+"or tostring(route))
		if not denied[path] then denied[path]=true warn("[VhieS SC] Unavailable: "..path) end
		return {Success=false,StatusCode=503,StatusMessage="Unavailable offline",Body="",Headers={}}
	end
	local function localRequest(options)
		assert(type(options)=="table" and type(options.Url)=="string","Request requires a URL")
		if options.Url==UI_LIBRARY_URL and (options.Method==nil or options.Method=="GET") then
			if uiSource==nil then uiSource=hostGame:HttpGet(UI_LIBRARY_URL) end
			return {Success=true,StatusCode=200,StatusMessage="UI library",Body=uiSource,Headers={}}
		end
		return unavailable(options.Url)
	end
	local function localGet(_,url)
		local response=localRequest({Url=url,Method="GET"})
		if not response.Success then error("Resource not embedded: "..tostring(url),0) end
		return response.Body
	end
	local function disabledSocket() error("WebSocket disabled",0) end
	local function disabledQueue() warn("[VhieS SC] Teleport queue disabled.") end
	environment.request=localRequest environment.http_request=localRequest
	environment.http={request=localRequest}
	environment.WebSocket={connect=disabledSocket} environment.websocket={connect=disabledSocket}
	environment.queue_on_teleport=disabledQueue environment.queueonteleport=disabledQueue
	environment.clearteleportqueue=function() end environment.clear_teleport_queue=environment.clearteleportqueue
	environment.syn={
		request=localRequest,protect_gui=environment.protectgui,getcustomasset=environment.getcustomasset,
		queue_on_teleport=disabledQueue,clear_teleport_queue=environment.clearteleportqueue,
		websocket={connect=disabledSocket},
	}
	local httpProxy=setmetatable({},{
		__index=function(_,name)
			if name=="GetAsync" then return localGet end
			if name=="RequestAsync" then return function(_,opts) return localRequest(opts) end end
			if name=="PostAsync" then return function(_,url) unavailable(url) error("POST unavailable",0) end end
			if name=="JSONEncode" or name=="JSONDecode" or name=="GenerateGUID" or name=="UrlEncode" then
				return function(_,...) return hostHttp[name](hostHttp,...) end
			end
			error("HttpService unavailable: "..tostring(name),0)
		end,
	})
	local function service(_,name)
		if name=="HttpService" then return httpProxy end
		if name=="HttpRbxApiService" then error("HTTP API unavailable",0) end
		if not serviceCache[name] then serviceCache[name]=hostGame:GetService(name) end
		return serviceCache[name]
	end
	environment.game=setmetatable({},{
		__index=function(_,name)
			if name=="GetService" or name=="FindService" or name=="service" then return service end
			if name=="HttpGet" or name=="HttpGetAsync" then return localGet end
			if name=="HttpService" then return httpProxy end
			if name=="HttpPost" or name=="HttpPostAsync" then
				return function(_,url) unavailable(url) error("POST unavailable",0) end
			end
			local v=hostGame[name]
			if type(v)=="function" then return function(_,...) return v(hostGame,...) end end
			return v
		end,
	})
	environment.workspace=hostGame:GetService("Workspace")
	local hostClone=lookup("cloneref")
	environment.cloneref=function(value)
		if value==environment.game or value==httpProxy then return value end
		if hostClone then return hostClone(value) end
		return value
	end
	environment.require=function(module)
		assert(typeof(module)=="Instance" and module:IsA("ModuleScript"),"Numeric require disabled")
		return host.require(module)
	end
	environment.loadstring=function(source,name)
		assert(type(source)=="string","Requires source text")
		local chunk,failure=hostCompile(source,name)
		if not chunk then return nil,failure end
		return setfenv(chunk,environment)
	end
	environment.load=environment.loadstring
	return environment,{denied=denied,executorGlobals=environment}
end

-- =============================================
-- VhieS SC | Main Hub
-- =============================================

local function launchHub()
	local environment = createEnvironment()
	print("[VhieS SC] Starting...")

	local ok, result = pcall(function()
		local hostGame = game
		local services = {
			Players = hostGame:GetService("Players"),
			ReplicatedStorage = hostGame:GetService("ReplicatedStorage"),
			RunService = hostGame:GetService("RunService"),
			HttpService = hostGame:GetService("HttpService"),
			VirtualUser = hostGame:GetService("VirtualUser"),
			VirtualInputManager = hostGame:GetService("VirtualInputManager"),
		}

		local player = services.Players.LocalPlayer
		local state = { Running = true, Busy = nil, Log = "Loading..." }
		local token = services.HttpService:GenerateGUID(false)
		environment.getgenv().VhieSC = state
		environment.getgenv().VhieSCSession = token

		-- Load UI
		local uiSource = hostGame:HttpGet(UI_LIBRARY_URL)
		local chunk = assert(loadstring(uiSource, "@wave-ui"))
		local library = setfenv(chunk, environment)()
		local options = library.Options

		-- Load game modules
		local modules = {}
		pcall(function()
			local fw = require(services.ReplicatedStorage:WaitForChild("Fsys"))
			modules.load = fw.load
			modules.ClientData = modules.load("ClientData")
			modules.Interiors = modules.load("InteriorsM")
			modules.UI = modules.load("UIManager")
			modules.FurnitureDB = modules.load("FurnitureDB")
			modules.InventoryDB = modules.load("InventoryDB")
		end)
		pcall(function()
			modules.Dailies = require(services.ReplicatedStorage.new.modules.Dailies.DailiesNetService)
		end)

		-- Helpers
		local function readOption(flag, default)
			local opt = options[flag]
			return if opt==nil or opt.Value==nil then default else opt.Value
		end
		local function getData(key)
			local ok2, s = pcall(function() return modules.ClientData.get_data()[player.Name] end)
			local ps = if ok2 and s then s else nil
			return ps and ps[key]
		end
		local function formatNumber(v)
			local d = tostring(math.floor(tonumber(v) or 0))
			return (d:reverse():gsub("(%d%d%d)","%1,"):reverse():gsub("^,",""))
		end
		local function log(msg) state.Log = os.date("%H:%M:%S").."  "..msg end
		local function notify(msg, dur)
			pcall(function() library:Notify({Title="VhieS SC",Content=msg,Duration=dur or 4}) end)
		end
		local function getLocation()
			local ok2, loc = pcall(modules.Interiors.get_current_location)
			return if ok2 and loc then loc else nil
		end
		local function locationName() local l=getLocation() return l and l.destination_id end
		local function isHome()
			local l=getLocation()
			return l~=nil and l.destination_id=="housing" and l.house_owner==player
		end
		local function travel(dest, door, opts)
			if locationName()==dest and dest~="housing" then return true end
			if modules.Interiors and modules.Interiors.entering then
				local s=os.clock()
				while modules.Interiors.entering and os.clock()-s<10 do task.wait(0.25) end
			end
			local ok2, reason = pcall(modules.Interiors.enter, dest, door or "MainDoor", opts or {})
			if not ok2 then log("Teleport to "..dest.." failed: "..tostring(reason)) return false end
			local s=os.clock()
			while os.clock()-s<12 do if locationName()==dest then return true end task.wait(0.25) end
			return locationName()==dest
		end
		local function goHome()
			if isHome() then return true end
			travel("housing","MainDoor",{house_owner=player})
			return isHome()
		end
		local remotes = services.ReplicatedStorage:WaitForChild("API")
		local function callRemote(name,...)
			local r=remotes and remotes:FindFirstChild(name)
			if not r then return false end return pcall(r.InvokeServer,r,...)
		end
		local function fireRemote(name,...)
			local r=remotes and remotes:FindFirstChild(name)
			if not r then return false end return pcall(r.FireServer,r,...)
		end
		local function getWrappers()
			local w={}
			for _,pw in pairs(getData("pet_char_wrappers") or {}) do
				if type(pw)=="table" and pw.pet_unique and pw.char and pw.char.Parent then
					table.insert(w,pw)
				end
			end
			return w
		end
		local function petAilments(key)
			local m=getData("ailments_manager")
			return m and m.ailments and m.ailments[key] or {}
		end
		local function getAilments(subject)
			if not subject.baby then return petAilments(subject.key) end
			local m=getData("ailments_manager")
			return m and m.baby_ailments or {}
		end

		-- Farm state
		local farm = { Failures={}, Learned={}, SkipUntil={}, LastAction="Idle" }
		local stats = { StartedAt=os.time(), Quests=0 }

		local function isActive()
			return state.Running and environment.getgenv().VhieSCSession==token
		end

		-- Quest destinations
		local QUEST_DEST = {
			salon="Salon", school="School", sick="Hospital",
			cat_cafe="CatCafe", pizza_party="PizzaShop",
		}

		-- Main farm loop
		local function farmLoop()
			while isActive() do
				if not readOption("AutoFarm",false) then
					farm.LastAction="Idle" task.wait(0.5) continue
				end
				if state.Busy then
					farm.LastAction="Paused: "..state.Busy task.wait(0.5) continue
				end
				local wrappers=getWrappers()
				if #wrappers==0 then
					farm.LastAction="No pet equipped" task.wait(1) continue
				end
				local didWork=false
				for _, wrapper in ipairs(wrappers) do
					local ailments=getAilments({key=wrapper.pet_unique,baby=false})
					for kind in pairs(ailments) do
						if not readOption("Quest_"..kind,true) then continue end
						local key=wrapper.pet_unique..kind
						if (farm.SkipUntil[key] or 0)>=os.clock() then continue end
						farm.LastAction=string.format("Doing %s for %s",kind:gsub("_"," "),wrapper.pet_id or "pet")
						log(farm.LastAction)
						local homequests={hungry=true,thirsty=true,sleepy=true,dirty=true,toilet=true,play=true,pet_me=true,walk=true,ride=true}
						if homequests[kind] then
							if not isHome() then goHome() end
						elseif QUEST_DEST[kind] then
							travel(QUEST_DEST[kind],"MainDoor")
						end
						local start=os.clock()
						while isActive() and readOption("AutoFarm",false) and os.clock()-start<60 do
							if not getAilments({key=wrapper.pet_unique,baby=false})[kind] then
								stats.Quests+=1 log("Completed: "..kind) break
							end
							task.wait(0.5)
						end
						local f=(farm.Failures[key] or 0)+1
						farm.Failures[key]=f
						farm.SkipUntil[key]=os.clock()+math.min(f*15,90)
						didWork=true break
					end
					if didWork then break end
				end
				if not didWork then
					farm.LastAction="No quests pending"
					if readOption("StayHome",true) and not isHome() then goHome() end
				end
				task.wait(0.5)
			end
		end

		-- Anti AFK
		local function antiAFKLoop()
			while isActive() do
				task.wait(60*15)
				if readOption("AntiAFK",true) then
					pcall(function()
						services.VirtualUser:CaptureController()
						services.VirtualUser:ClickButton2(Vector2.new())
					end)
				end
			end
		end

		-- Status update
		local farmStatus
		local function statusLoop()
			while isActive() do
				task.wait(1)
				if farmStatus then
					local lines={
						"Status: "..farm.LastAction,
						string.format("Quests: %d | Bucks: %s",stats.Quests,formatNumber(getData("money"))),
						state.Log,
					}
					pcall(function() farmStatus:SetContent(table.concat(lines,"\n")) end)
				end
			end
		end

		-- Build UI window
		local window = library:CreateWindow({
			Title = "VhieS SC",
			SubTitle = "Adopt Me!",
			TabWidth = 160,
			MinimizeKey = Enum.KeyCode.RightShift,
			Size = UDim2.new(0, 1040, 0, 720),
			MinSize = Vector2.new(700, 480),
			Acrylic = true, Theme = "Cobalt",
			ToggleButton = true, StatusBar = true, Resize = true,
		})

		local tabs = {}
		window:Divider("Dashboard")
		tabs.overview = window:CreateTab({Title="Overview",Icon="layout-dashboard"})
		window:Divider("Farming")
		tabs.farm = window:CreateTab({Title="Auto Farm",Icon="heart"})
		tabs.halloween = window:CreateTab({Title="Halloween",Icon="ghost"})
		window:Divider("House & Items")
		tabs.house = window:CreateTab({Title="House",Icon="house"})
		tabs.shop = window:CreateTab({Title="Shop",Icon="gift"})
		tabs.tradeLicense = window:CreateTab({Title="Trade License",Icon="shield-check"})
		window:Divider("Utility & Settings")
		tabs.performance = window:CreateTab({Title="Performance",Icon="gauge"})
		tabs.settings = window:CreateTab({Title="Settings",Icon="settings"})

		-- Overview
		local ovL=tabs.overview:Left("Your Account")
		local bucksCard=ovL:CreateStat("_BucksCard",{Title="Bucks",Value="...",Icon="banknote"})
		local candyCard=ovL:CreateStat("_CandyCard",{Title="Candy",Value="...",Icon="candy"})
		local ovR=tabs.overview:Right("This Session")
		local questsCard=ovR:CreateStat("_QuestsCard",{Title="Quests done",Value="0",Icon="circle-check"})
		ovR:CreateCallout({Title="VhieS SC",Style="Info",Content="Auto farms your Adopt Me pets."})
		ovR:CreateButton({Title="Open Auto Farm",Callback=function() window:SelectTab("Auto Farm") end})

		-- Farm tab
		local fL=tabs.farm:Left("Pet Quests")
		farmStatus=fL:CreateParagraph({Title="Status",Content="..."})
		fL:CreateToggle("AutoFarm",{Title="Auto Farm",Default=false,Description="Completes pet quests automatically"})
		fL:CreateToggle("PlayerQuests",{Title="Player Quests",Default=true})
		fL:CreateToggle("BuyFood",{Title="Buy Food When Needed",Default=true})
		fL:CreateToggle("StayHome",{Title="Wait At Home",Default=true})
		fL:CreateToggle("AutoPopups",{Title="Accept Popups",Default=true})
		fL:CreateToggle("AutoDailies",{Title="Claim Daily Tasks",Default=true})
		local fR=tabs.farm:Right("Quests To Do")
		local questList={
			{"hungry","Hungry"},{"thirsty","Thirsty"},{"sleepy","Sleepy"},
			{"dirty","Dirty"},{"toilet","Potty"},{"school","School"},
			{"salon","Salon"},{"pizza_party","Pizza Party"},{"cat_cafe","Cat Cafe"},
			{"sick","Sick"},{"bored","Bored"},{"play","Play"},
			{"pet_me","Pet Me"},{"walk","Walk"},{"ride","Ride"},
		}
		for _,q in ipairs(questList) do
			fR:CreateToggle("Quest_"..q[1],{Title=q[2],Default=true})
		end

		-- Halloween tab
		local hL=tabs.halloween:Left("Ghost Gallery")
		hL:CreateParagraph({Title="Status",Content="Ghost Gallery auto-join"})
		hL:CreateToggle("HalloweenFarm",{Title="Auto Ghost Gallery",Default=false})
		hL:CreateToggle("HalloweenAutoJoin",{Title="Auto Join",Default=true})

		-- House tab
		local hsL=tabs.house:Left("Farm Furniture")
		hsL:CreateParagraph({Title="Your house",Content="Go home to check furniture"})
		hsL:CreateToggle("AutoBuildHouse",{Title="Auto Build Missing Furniture",Default=false})
		hsL:CreateButton({
			Title="Build Farm House",
			Description="Places missing quest furniture (food bowl, water bowl, bed, bathtub, toilet)",
			Callback=function()
				task.spawn(function()
					if not isHome() then goHome() end
					notify("Building house...")
					local requirements={
						{need="hungry",label="Food Bowl",kinds={"ailments_refresh_2024_cheap_food_bowl","pet_food_bowl"}},
						{need="thirsty",label="Water Bowl",kinds={"ailments_refresh_2024_cheap_water_bowl","pet_water_bowl"}},
						{need="sleepy",label="Bed",kinds={"basicbed","basiccrib"}},
						{need="dirty",label="Bathtub",kinds={"cheapbathtub","modernshower"}},
						{need="toilet",label="Toilet",kinds={"toilet","ailments_refresh_2024_litter_box"}},
					}
					local bought={} local money=tonumber(getData("money")) or 0
					for _,req in ipairs(requirements) do
						for _,kind in ipairs(req.kinds) do
							local item=modules.FurnitureDB and modules.FurnitureDB[kind]
							local cost=item and tonumber(item.cost)
							if cost and cost<=money then
								local ok2,res=callRemote("HousingAPI/BuyFurnitures",{{kind=kind,properties={cframe=CFrame.new(0,0,0)}}})
								if ok2 and type(res)=="table" and res.success then
									table.insert(bought,req.label) task.wait(1) break
								end
							end
						end
					end
					notify(if #bought>0 then "Bought: "..table.concat(bought,", ") else "Nothing to buy")
				end)
			end,
		})

		-- Shop tab
		local shL=tabs.shop:Left("Auto Buy Egg")
		shL:CreateDropdown("EggToBuy",{Title="Egg",Values={"Starter Egg","Cracked Egg","Pet Egg","Royal Egg"},Default="Cracked Egg",Searchable=true})
		shL:CreateToggle("AutoBuyEgg",{Title="Auto Buy Egg",Default=false})
		local shR=tabs.shop:Right("Auto Open Gift")
		shR:CreateToggle("AutoOpenGift",{Title="Auto Open Gift",Default=false})

		-- Trade License tab
		local trL=tabs.tradeLicense:Left("Trade License")
		local tradeStatus=trL:CreateParagraph({Title="Status",Content="Not unlocked yet"})
		trL:CreateButton({
			Title="Get Trade License",
			Callback=function()
				task.spawn(function()
					state.Busy="Trade License"
					notify("Attempting Trade License quiz...")
					if not travel("TradeLicenseZone","MainDoor") then
						notify("Could not reach office") state.Busy=nil return
					end
					task.wait(1)
					fireRemote("TradeAPI/BeginQuiz")
					task.wait(2)
					for _=1,6 do
						local quiz=getData("trade_license_quiz_manager")
						if not quiz then break end
						local q=quiz.quiz and quiz.quiz[quiz.question_index]
						if not q or not q.answer then break end
						fireRemote("TradeAPI/AnswerQuizQuestion",q.answer)
						task.wait(2.5)
					end
					state.Busy=nil
					notify("Trade License attempt finished!")
					pcall(function() tradeStatus:SetContent("Check your inventory!") end)
					goHome()
				end)
			end,
		})

		-- Performance tab
		local pfL=tabs.performance:Left("General")
		pfL:CreateToggle("AntiAFK",{Title="Anti AFK",Default=true})
		pfL:CreateButton({Title="Go Home",Callback=function() task.spawn(goHome) end})
		local pfR=tabs.performance:Right("Performance")
		pfR:CreateToggle("Disable3D",{Title="Disable 3D Rendering",Default=false,
			Callback=function(v) pcall(services.RunService.Set3dRenderingEnabled,services.RunService,not v) end})
		pfR:CreateSlider("FPSCap",{Title="FPS Cap",Min=0,Max=240,Default=0,Rounding=0,
			Callback=function(v) if environment.setfpscap then pcall(environment.setfpscap,if v>0 then v else 999) end end})

		-- Settings tab
		local stL=tabs.settings:Left("Configs")
		stL:CreateToggle("Autosave",{Title="Autosave Settings",Default=true})
		stL:CreateButton({
			Title="Unload VhieS SC",
			Callback=function()
				state.Running=false
				pcall(function() library:Destroy() end)
				environment.getgenv().VhieSC=nil
				notify("VhieS SC unloaded")
			end,
		})
		local stR=tabs.settings:Right("Interface")
		stR:CreateDropdown("Theme",{
			Title="Theme",Values=library.Themes,Default="Cobalt",AllowNull=false,Searchable=true,
			Callback=function(theme) library:SetTheme(theme) end,
		})
		stR:CreateToggle("UIAcrylic",{Title="Background blur",Default=true,
			Callback=function(v) library:ToggleAcrylic(v) end})
		stR:CreateKeybind("MenuKeybind",{Title="Show / Hide",Default="RightShift"})

		-- Player idle
		player.Idled:Connect(function()
			if readOption("AntiAFK",true) then
				pcall(function()
					services.VirtualUser:CaptureController()
					services.VirtualUser:ClickButton2(Vector2.new())
				end)
			end
		end)

		-- Overview updater
		task.spawn(function()
			while isActive() do
				task.wait(2)
				pcall(function()
					bucksCard:SetValue(formatNumber(getData("money")))
					candyCard:SetValue(formatNumber(getData("candy_2026")))
					questsCard:SetValue(tostring(stats.Quests))
				end)
			end
		end)

		-- Start all loops
		task.spawn(farmLoop)
		task.spawn(antiAFKLoop)
		task.spawn(statusLoop)

		log("VhieS SC loaded")
		notify("VhieS SC loaded | Adopt Me!")
	end)

	if not ok then
		warn("[VhieS SC] Failed to start: "..tostring(result))
	else
		print("[VhieS SC] Hub running.")
	end
end

launchHub()

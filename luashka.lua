local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local localPlayer = Players.LocalPlayer

-- ══════════════════════════════════════════════════════
--  CONFIG SAVE / LOAD  (writefile/readfile, per PlaceId)
-- ══════════════════════════════════════════════════════
local CONFIG_FOLDER = "AntiloseCfg"
local CONFIG_FILE   = CONFIG_FOLDER .. "/" .. tostring(game.PlaceId) .. ".json"

local function cfgWriteAvailable()
	return type(writefile) == "function" and type(readfile) == "function"
end

local function cfgEnsureFolder()
	if type(isfolder) == "function" and not isfolder(CONFIG_FOLDER) then
		if type(makefolder) == "function" then
			pcall(makefolder, CONFIG_FOLDER)
		end
	end
end

-- Цвет → {r,g,b} для JSON
local function colorToTbl(c)
	return { r = math.floor(c.R * 255 + 0.5), g = math.floor(c.G * 255 + 0.5), b = math.floor(c.B * 255 + 0.5) }
end
local function tblToColor(t)
	if type(t) ~= "table" then return nil end
	return Color3.fromRGB(t.r or 255, t.g or 255, t.b or 255)
end

-- EnumItem → строка
local function enumToStr(e)
	return tostring(e)
end
local function strToAimKey(s)
	-- "Enum.UserInputType.MouseButton2" или "Enum.KeyCode.E"
	local uit = s:match("UserInputType%.(.+)")
	if uit then
		local ok, v = pcall(function() return Enum.UserInputType[uit] end)
		if ok and v then return v end
	end
	local kc = s:match("KeyCode%.(.+)")
	if kc then
		local ok, v = pcall(function() return Enum.KeyCode[kc] end)
		if ok and v then return v end
	end
	return Enum.UserInputType.MouseButton2
end

-- Глобальные ссылки на состояния которые нужно сохранять
-- (заполняются после createGui, используются save/load)
local SAVE_STATE = {}  -- заполняется в createGui через registerSave()

local function saveConfig()
	if not cfgWriteAvailable() then return false end
	cfgEnsureFolder()
	local ok, err = pcall(function()
		local t = {}
		for k, getter in pairs(SAVE_STATE) do
			pcall(function() t[k] = getter() end)
		end
		writefile(CONFIG_FILE, HttpService:JSONEncode(t))
	end)
	return ok
end

local function loadConfig()
	if not cfgWriteAvailable() then return false end
	if type(isfile) == "function" and not isfile(CONFIG_FILE) then return false end
	local ok, err = pcall(function()
		local raw = readfile(CONFIG_FILE)
		local t = HttpService:JSONDecode(raw)
		for k, setter in pairs(SAVE_STATE) do
			if t[k] ~= nil then
				pcall(setter, t[k])
			end
		end
	end)
	return ok
end

local TOGGLE_KEY = Enum.KeyCode.Delete
local isOpen = false
local screenGui = nil
local conns = {}
local isUnloaded = false
local _globalStopSprint = nil  -- заполняется в createGui() для вызова из unload()

-- ══════════════════════════════════════════════════════
--  AIMBOT SYSTEM  (pasta.txt aimlock 1:1 + tool raycast)
-- ══════════════════════════════════════════════════════

local Camera = workspace.CurrentCamera

-- Настройки (1:1 из pasta.txt Settings)
local AB = {
	enabled      = false,
	AimKey       = Enum.UserInputType.MouseButton2,
	FOV          = 150,
	Smoothness   = 1.0,
	YOffset      = 0,
	VisCheck     = false,
	TeamCheck    = false,
	AutoSwitch   = true,
	AutoFire          = false,  -- авто ЛКМ при наличии цели с видимостью
	BackCamera        = false,  -- возврат камеры после выстрела
	BackCameraDelay   = 50,     -- задержка возврата камеры в мс (0–1000)
	FOVCheck          = true,   -- если false — аим работает 360°

	targetParts  = { Head = true },
}

-- R16 части тела
local R16_PARTS = {
	"Head",
	"Torso",
	"HumanoidRootPart",
	"Right Arm",
	"Left Arm",
	"Right Leg",
	"Left Leg",
}

local HoldingAim   = false
local CurrentTarget = nil

-- ── Dead player tracking (через кастомные RemoteEvent внутри Humanoid) ──────
local deadPlayers = {}  -- set: Player -> true если мёртв

local function watchPlayerDeath(plr)
	local char = plr.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	local diedEvent = hum:FindFirstChild("Died")
	if diedEvent and diedEvent:IsA("RemoteEvent") then
		diedEvent.OnClientEvent:Connect(function()
			deadPlayers[plr] = true
			if CurrentTarget and CurrentTarget.Player == plr then
				CurrentTarget = nil
			end
		end)
	end

	local revivedEvent = hum:FindFirstChild("Revived")
	if revivedEvent and revivedEvent:IsA("RemoteEvent") then
		revivedEvent.OnClientEvent:Connect(function()
			deadPlayers[plr] = nil
		end)
	end
end

-- Следим за всеми игроками при старте
for _, plr in ipairs(Players:GetPlayers()) do
	if plr ~= localPlayer then
		watchPlayerDeath(plr)
		plr.CharacterAdded:Connect(function()
			task.wait(0.1)
			watchPlayerDeath(plr)
		end)
	end
end

-- Следим за новыми игроками
Players.PlayerAdded:Connect(function(plr)
	if plr == localPlayer then return end
	plr.CharacterAdded:Connect(function()
		task.wait(0.1)
		watchPlayerDeath(plr)
	end)
end)

Players.PlayerRemoving:Connect(function(plr)
	deadPlayers[plr] = nil
end)

-- ── FOV Circle (Drawing API) ──────────────────────────────────────────────────
local fovCircle = nil
local AB_ShowFOV = true  -- можно переключить через toggle в GUI

local function createFovCircle()
	if not Drawing then return end
	if fovCircle then pcall(function() fovCircle:Remove() end) end
	fovCircle = Drawing.new("Circle")
	fovCircle.Visible    = false
	fovCircle.Color      = Color3.fromRGB(255, 255, 255)
	fovCircle.Thickness  = 1
	fovCircle.Filled     = false
	fovCircle.NumSides   = 64
	fovCircle.Radius     = AB.FOV
	fovCircle.Position   = Vector2.new(0, 0)
	fovCircle.Transparency = 1
end

local function updateFovCircle()
	if not fovCircle then return end
	local vp = Camera.ViewportSize
	local center = Vector2.new(vp.X / 2, vp.Y / 2)
	fovCircle.Position = center
	fovCircle.Radius   = AB.FOV
	fovCircle.Visible  = AB.enabled and AB_ShowFOV
end

local function destroyFovCircle()
	if fovCircle then
		pcall(function() fovCircle:Remove() end)
		fovCircle = nil
	end
end

pcall(createFovCircle)

-- Получить origin для raycast — от tool (Muzzle/Face/Handle) или HRP
local function getToolOrigin(char)
	local tool = char:FindFirstChildOfClass("Tool")
	if tool then
		local muzzle = tool:FindFirstChild("Muzzle")
		if muzzle and muzzle:IsA("BasePart") then return muzzle.Position end
		local face = tool:FindFirstChild("Face")
		if face and face:IsA("BasePart") then return face.Position end
		local handle = tool:FindFirstChild("Handle")
		if handle and handle:IsA("BasePart") then return handle.Position end
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp then return hrp.Position end
	return Camera.CFrame.Position
end

-- Raycast видимости от tool origin до worldPos (если VisCheck включён)
local function IsVisible(character, worldPos)
	if not AB.VisCheck then return true end
	local myChar = localPlayer.Character
	local tool = myChar and myChar:FindFirstChildOfClass("Tool")
	local origin = myChar and getToolOrigin(myChar) or Camera.CFrame.Position

	local ignoreList = {}
	if myChar then table.insert(ignoreList, myChar) end
	if tool then table.insert(ignoreList, tool) end
	if character then table.insert(ignoreList, character) end

	local rp = RaycastParams.new()
	rp.FilterDescendantsInstances = ignoreList
	rp.FilterType = Enum.RaycastFilterType.Exclude

	local dir = worldPos - origin
	local result = workspace:Raycast(origin, dir, rp)
	if result and result.Instance then
		return result.Instance:IsDescendantOf(character)
	end
	return true
end

-- Raycast ВСЕГДА (для AutoFire и аима — независимо от AB.VisCheck)
local function IsVisibleHard(character, worldPos)
	local myChar = localPlayer.Character
	local tool = myChar and myChar:FindFirstChildOfClass("Tool")
	local origin = myChar and getToolOrigin(myChar) or Camera.CFrame.Position

	local ignoreList = {}
	if myChar then table.insert(ignoreList, myChar) end
	if tool then table.insert(ignoreList, tool) end
	if character then table.insert(ignoreList, character) end

	local rp = RaycastParams.new()
	rp.FilterDescendantsInstances = ignoreList
	rp.FilterType = Enum.RaycastFilterType.Exclude

	local dir = worldPos - origin
	local result = workspace:Raycast(origin, dir, rp)
	if result and result.Instance then
		return result.Instance:IsDescendantOf(character)
	end
	return true
end

-- Получить нужную часть тела — первая выбранная которую видно, иначе первая выбранная, иначе fallback
local function getAimPart(pchar)
	local myChar = localPlayer.Character
	local tool   = myChar and myChar:FindFirstChildOfClass("Tool")
	local origin = myChar and getToolOrigin(myChar) or Camera.CFrame.Position

	local rp = RaycastParams.new()
	rp.FilterDescendantsInstances = (function()
		local t = {}
		if myChar    then table.insert(t, myChar) end
		if tool      then table.insert(t, tool) end
		if pchar     then table.insert(t, pchar) end
		return t
	end)()
	rp.FilterType = Enum.RaycastFilterType.Exclude

	local firstSelected = nil  -- первая выбранная (даже если за стеной)

	for _, pname in ipairs(R16_PARTS) do
		if AB.targetParts[pname] then
			local p = pchar:FindFirstChild(pname)
			if p and p:IsA("BasePart") then
				if not firstSelected then firstSelected = p end
				-- проверяем видимость этой части
				local dir = p.Position - origin
				local res = workspace:Raycast(origin, dir, rp)
				local visible = (not res) or (res.Instance and res.Instance:IsDescendantOf(pchar))
				if visible then return p end
			end
		end
	end

	-- нет видимой выбранной — вернуть первую выбранную (за стеной)
	if firstSelected then return firstSelected end

	-- fallback — первая доступная часть
	for _, pname in ipairs(R16_PARTS) do
		local p = pchar:FindFirstChild(pname)
		if p and p:IsA("BasePart") then return p end
	end
	return pchar.PrimaryPart
end

local function getAimPosition(part)
	return part.Position + Vector3.new(0, AB.YOffset, 0)
end

local function IsAlive(char)
	if not char then return false end
	local player = Players:GetPlayerFromCharacter(char)
	if player and deadPlayers[player] == true then return false end
	return true
end

local function IsTargetValid(player)
	if player == localPlayer then return false end
	if AB.TeamCheck and player.Team == localPlayer.Team then return false end
	return true
end

-- Найти ближайшего игрока
local function GetClosestPlayer()
	local screenCenter = Camera.ViewportSize / 2
	local closest = nil
	local closestDist = math.huge

	for _, player in ipairs(Players:GetPlayers()) do
		if not IsTargetValid(player) then continue end
		local char = player.Character
		local part = char and getAimPart(char)
		if not part or not IsAlive(char) then continue end

		local aimPos = getAimPosition(part)

		if AB.FOVCheck then
			-- только видимые на экране + в радиусе FOV
			local pos, onScreen = Camera:WorldToViewportPoint(aimPos)
			if not onScreen then continue end
			local screenDist = (Vector2.new(pos.X, pos.Y) - screenCenter).Magnitude
			if screenDist > AB.FOV then continue end
			if not IsVisibleHard(char, aimPos) then continue end
			local dist3D = (part.Position - Camera.CFrame.Position).Magnitude
			if dist3D < closestDist then
				closestDist = dist3D
				closest = {
					Player   = player,
					Part     = part,
					Position = pos,
					Distance = dist3D,
				}
			end
		else
			-- 360°: любой игрок в мире, сортируем по 3D дистанции
			if not IsVisibleHard(char, aimPos) then continue end
			local dist3D = (part.Position - Camera.CFrame.Position).Magnitude
			if dist3D < closestDist then
				closestDist = dist3D
				local pos = Camera:WorldToViewportPoint(aimPos)
				closest = {
					Player   = player,
					Part     = part,
					Position = pos,
					Distance = dist3D,
				}
			end
		end
	end
	return closest
end

-- Главный луп — RenderStepped
local aimbotConn = nil
local function startAimbotLoop()
	if aimbotConn then aimbotConn:Disconnect() end
	aimbotConn = RunService.RenderStepped:Connect(function()
		if not AB.enabled or not HoldingAim then
			CurrentTarget = nil
			return
		end

		local valid = false
		if CurrentTarget then
			local char = CurrentTarget.Player.Character
			local part = char and getAimPart(char)
			if part and IsAlive(char) and IsTargetValid(CurrentTarget.Player) then
				local aimPos = getAimPosition(part)
				if AB.FOVCheck then
					-- с FOV check — нужен onScreen + радиус
					local pos, onScreen = Camera:WorldToViewportPoint(aimPos)
					if onScreen then
						local sd = (Vector2.new(pos.X, pos.Y) - Camera.ViewportSize / 2).Magnitude
						if sd <= AB.FOV and IsVisibleHard(char, aimPos) then
							valid = true
							CurrentTarget.Part     = part
							CurrentTarget.Position = pos
							CurrentTarget.Distance = (part.Position - Camera.CFrame.Position).Magnitude
						end
					end
				else
					-- 360°: onScreen не нужен, только живой + видимый
					if IsVisibleHard(char, aimPos) then
						valid = true
						local pos = Camera:WorldToViewportPoint(aimPos)
						CurrentTarget.Part     = part
						CurrentTarget.Position = pos
						CurrentTarget.Distance = (part.Position - Camera.CFrame.Position).Magnitude
					end
				end
			end
		end

		if not valid then
			CurrentTarget = AB.AutoSwitch and GetClosestPlayer() or nil
		end

		if CurrentTarget then
			local part   = CurrentTarget.Part
			local aimPos = getAimPosition(part)
			local targetCF = CFrame.new(Camera.CFrame.Position, aimPos)
			if AB.Smoothness <= 0 then
				Camera.CFrame = targetCF
			else
				-- AB.Smoothness 0→1 = мгновенно→плавно
				-- превращаем в lerpAlpha: 1=мгновенно, ~0=очень плавно
				local lerpAlpha = 1 - AB.Smoothness
				Camera.CFrame = Camera.CFrame:Lerp(targetCF, lerpAlpha)
			end
		end
	end)
end

-- Input: держим AimKey — HoldingAim = true
-- (хранится в conns через track чтобы отключился при unload)
local _aimHoldConn = RunService.Heartbeat:Connect(function()
	if isUnloaded then return end
	if AB.AimKey.EnumType == Enum.UserInputType then
		HoldingAim = AB.enabled and UserInputService:IsMouseButtonPressed(AB.AimKey)
	end
end)
table.insert(conns, _aimHoldConn)

startAimbotLoop()

-- ── AutoFire + BackCamera ─────────────────────────────────────────────────────
local autoFireCooldown = false
local preShotCameraRef = nil   -- камера ДО нажатия AimKey (сохраняется при нажатии)
local wasHoldingAim    = false -- предыдущее состояние для edge-trigger

-- simulateLMB через VirtualInputManager или fallback
local function simulateLMB()
	local ok, vim = pcall(function() return game:GetService("VirtualInputManager") end)
	if ok and vim and vim.SendMouseButtonEvent then
		pcall(function()
			local m = UserInputService:GetMouseLocation()
			vim:SendMouseButtonEvent(m.X, m.Y, 0, true,  game, 1)
			task.wait()
			vim:SendMouseButtonEvent(m.X, m.Y, 0, false, game, 1)
		end)
	else
		local mouse = localPlayer:GetMouse()
		pcall(function() mouse:Button1Down() end)
		task.defer(function() pcall(function() mouse:Button1Up() end) end)
	end
end

-- сохраняем позицию камеры в момент нажатия AimKey (до любого аима)
local _backCamConn = RunService.Heartbeat:Connect(function()
	if isUnloaded then return end
	local holding = AB.enabled and HoldingAim
	if holding and not wasHoldingAim then
		if AB.BackCamera then
			preShotCameraRef = Camera.CFrame
		end
	end
	if not holding and wasHoldingAim then
		preShotCameraRef = nil
		autoFireCooldown = false
	end
	wasHoldingAim = holding
end)
table.insert(conns, _backCamConn)

local _autoFireConn = RunService.RenderStepped:Connect(function()
	if isUnloaded then return end
	if not AB.enabled or not AB.AutoFire then return end
	if not HoldingAim then return end   -- стрелять только пока зажат бинд прицела
	if autoFireCooldown then return end
	local target = CurrentTarget
	if not target then
		target = GetClosestPlayer()
	end
	if not target then return end

	local char = target.Player and target.Player.Character
	if not char or not IsAlive(char) then return end
	local part = getAimPart(char)
	if not part then return end
	local aimPos = getAimPosition(part)

	if not IsVisibleHard(char, aimPos) then return end

	autoFireCooldown = true
	simulateLMB()

	task.delay(AB.BackCameraDelay / 1000, function()
		if isUnloaded then return end
		if AB.BackCamera and preShotCameraRef then
			local origin = preShotCameraRef
			local t = 0
			local conn
			conn = RunService.RenderStepped:Connect(function(dt)
				if isUnloaded then conn:Disconnect(); return end
				t = t + dt * 12
				Camera.CFrame = Camera.CFrame:Lerp(origin, math.min(t, 1))
				if t >= 1 then
					Camera.CFrame = origin
					conn:Disconnect()
				end
			end)
		end
		task.wait(0.1)
		if not isUnloaded then
			autoFireCooldown = false
		end
	end)
end)
table.insert(conns, _autoFireConn)

-- FOV circle update loop
local _fovCircleConn = RunService.RenderStepped:Connect(function()
	if isUnloaded then return end
	pcall(updateFovCircle)
end)
table.insert(conns, _fovCircleConn)

-- Highlight state
local highlightEnabled = false
local highlightColor = Color3.fromRGB(255, 0, 0)
local highlightAlpha = 0.5
local highlightHue, highlightSat, highlightVal = highlightColor:ToHSV()
local activeHighlights = {} -- player -> Highlight instance

local function track(conn)
	table.insert(conns, conn)
	return conn
end

local toggleState = setmetatable({}, {__mode = "k"})

local function getToggleState(frame)
	local st = toggleState[frame]
	return st and st.enabled or false
end

local function setToggleState(frame, v, fireCallback)
	local st = toggleState[frame]
	if not st then return end
	st.enabled = v
	local onColor  = Color3.fromRGB(80, 80, 80)
	local offColor = Color3.fromRGB(40, 40, 40)
	local onStroke  = Color3.fromRGB(100, 100, 100)
	local offStroke = Color3.fromRGB(50, 50, 50)
	local knobOn  = Color3.fromRGB(255, 255, 255)
	local knobOff = Color3.fromRGB(120, 120, 120)
	TweenService:Create(st.bg,   TweenInfo.new(0.15), {BackgroundColor3 = v and onColor or offColor}):Play()
	TweenService:Create(st.knob, TweenInfo.new(0.15), {
		Position = v and UDim2.new(1, -6, 0.5, 0) or UDim2.new(0, 6, 0.5, 0),
		BackgroundColor3 = v and knobOn or knobOff,
	}):Play()
	st.stroke.Color = v and onStroke or offStroke
	if fireCallback and st.callback then
		pcall(st.callback, v)
	end
end

-- ── Highlight logic ──────────────────────────────────────────────────────────

local function removeHighlightForPlayer(plr)
	local h = activeHighlights[plr]
	if h then
		pcall(function() h:Destroy() end)
		activeHighlights[plr] = nil
	end
end

local function addHighlightForPlayer(plr)
	if plr == localPlayer then return end
	if activeHighlights[plr] then return end
	local char = plr.Character
	if not char then return end
	local h = Instance.new("Highlight")
	h.FillColor = highlightColor
	h.OutlineColor = highlightColor
	h.FillTransparency = highlightAlpha
	h.OutlineTransparency = 0
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	h.Adornee = char
	h.Enabled = true
	pcall(function() h.Parent = char end)
	activeHighlights[plr] = h
end

local function refreshHighlightColors()
	for plr, h in pairs(activeHighlights) do
		pcall(function()
			h.FillColor = highlightColor
			h.OutlineColor = highlightColor
			h.FillTransparency = highlightAlpha
		end)
	end
end

local function clearAllHighlights()
	for plr in pairs(activeHighlights) do
		removeHighlightForPlayer(plr)
	end
	activeHighlights = {}
end

local function setHighlightEnabled(v)
	highlightEnabled = v
	if not v then
		clearAllHighlights()
		return
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		addHighlightForPlayer(plr)
	end
end

-- Watch players join/leave/respawn
track(Players.PlayerAdded:Connect(function(plr)
	if not highlightEnabled then return end
	-- wait for character
	plr.CharacterAdded:Connect(function()
		if highlightEnabled then
			task.wait(0.1)
			addHighlightForPlayer(plr)
		end
	end)
end))

track(Players.PlayerRemoving:Connect(function(plr)
	removeHighlightForPlayer(plr)
end))

-- Re-add highlight on respawn for existing players
for _, plr in ipairs(Players:GetPlayers()) do
	if plr ~= localPlayer then
		track(plr.CharacterAdded:Connect(function()
			if highlightEnabled then
				task.wait(0.1)
				addHighlightForPlayer(plr)
			end
		end))
	end
end

-- ── Unload ───────────────────────────────────────────────────────────────────

local function unload()
	if isUnloaded then return end
	isUnloaded = true

	-- ── 1. Остановить aimbot ──────────────────────────────────────────────────
	AB.enabled  = false
	HoldingAim  = false
	CurrentTarget = nil
	if aimbotConn then
		pcall(function() aimbotConn:Disconnect() end)
		aimbotConn = nil
	end

	-- ── 2. Остановить YAW rotator и вернуть AutoRotate ───────────────────────
	pcall(function() RunService:UnbindFromRenderStep("_AntiLoseYawRotator") end)
	pcall(function()
		local char = localPlayer.Character
		local hum  = char and char:FindFirstChildOfClass("Humanoid")
		if hum then hum.AutoRotate = true end
	end)

	-- ── 3. Остановить Sprint (отпустить Shift) ───────────────────────────────
	if _globalStopSprint then pcall(_globalStopSprint) end
	pcall(function() RunService:UnbindFromRenderStep("FovChanger") end)
	pcall(function()
		local cam = workspace.CurrentCamera
		if cam then cam.FieldOfView = 70 end
	end)
	fovEnabled = false

	-- ── 4. Убрать highlights ──────────────────────────────────────────────────
	clearAllHighlights()
	highlightEnabled = false

	-- ── 5. Убрать FOV circle ─────────────────────────────────────────────────
	destroyFovCircle()

	-- ── 6. Отключить все трекнутые коннекшны ─────────────────────────────────
	for _, c in ipairs(conns) do
		pcall(function() c:Disconnect() end)
	end
	conns = {}

	-- ── 7. Уничтожить GUI ────────────────────────────────────────────────────
	if screenGui then
		pcall(function() screenGui:Destroy() end)
		screenGui = nil
	end
end

-- ── GUI helpers ──────────────────────────────────────────────────────────────

local function getGuiParent()
	local ok, coreGui = pcall(function() return game:GetService("CoreGui") end)
	if ok and coreGui then return coreGui end
	if localPlayer then
		local pg = localPlayer:FindFirstChildOfClass("PlayerGui")
		if pg then return pg end
	end
	return nil
end

local function destroyGui()
	if screenGui then
		pcall(function() screenGui:Destroy() end)
		screenGui = nil
	end
end

local function getMouseUiPos()
	local m = UserInputService:GetMouseLocation()
	return Vector2.new(m.X, m.Y)
end

local function clamp01(x)
	if x < 0 then return 0 end
	if x > 1 then return 1 end
	return x
end

-- ── Color picker factory ─────────────────────────────────────────────────────
-- Returns { swatch, popup, overlay }
-- getColor/setColor/getAlpha/setAlpha are state accessors provided by caller.
-- onChanged() is called whenever color/alpha changes.

local function createColorPicker(sg, parentToggle, getColor, setColor, getAlpha, setAlpha, onChanged)
	local pickerW = 260
	local pickerH = 206
	local svSize  = 170
	local barW    = 14
	local gap     = 6

	-- Swatch button (shown in the toggle row)
	local swatch = Instance.new("TextButton")
	swatch.Name = "ColorSwatch"
	swatch.AnchorPoint = Vector2.new(1, 0.5)
	swatch.Position = UDim2.new(1, -77, 0.5, -1)
	swatch.Size = UDim2.fromOffset(12, 12)
	swatch.BackgroundColor3 = getColor()
	swatch.BackgroundTransparency = 1 - getAlpha()
	swatch.BorderSizePixel = 0
	swatch.Text = ""
	swatch.AutoButtonColor = false
	swatch.ZIndex = parentToggle.ZIndex + 2
	swatch.Parent = parentToggle
	local swatchCorner = Instance.new("UICorner")
	swatchCorner.CornerRadius = UDim.new(0, 3)
	swatchCorner.Parent = swatch

	-- Modal overlay (closes picker on outside click)
	local overlay = Instance.new("TextButton")
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.Position = UDim2.fromOffset(0, 0)
	overlay.Text = ""
	overlay.AutoButtonColor = false
	overlay.Visible = false
	overlay.ZIndex = 249
	overlay.Parent = sg

	-- Popup frame
	local popup = Instance.new("Frame")
	popup.Size = UDim2.fromOffset(pickerW, pickerH)
	popup.Position = UDim2.fromOffset(0, 0)
	popup.BackgroundTransparency = 1
	popup.BorderSizePixel = 0
	popup.Visible = false
	popup.ZIndex = 250
	popup.Parent = sg

	local pOB = Instance.new("Frame")
	pOB.Position = UDim2.fromOffset(0, 0)
	pOB.Size = UDim2.new(1, 0, 1, 0)
	pOB.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	pOB.BorderSizePixel = 0
	pOB.ZIndex = popup.ZIndex
	pOB.Parent = popup

	local pOG = Instance.new("Frame")
	pOG.Position = UDim2.fromOffset(1, 1)
	pOG.Size = UDim2.new(1, -2, 1, -2)
	pOG.BackgroundColor3 = Color3.fromRGB(85, 85, 85)
	pOG.BorderSizePixel = 0
	pOG.ZIndex = popup.ZIndex
	pOG.Parent = pOB

	local pFA = Instance.new("Frame")
	pFA.Position = UDim2.fromOffset(1, 1)
	pFA.Size = UDim2.new(1, -2, 1, -2)
	pFA.BackgroundColor3 = Color3.fromRGB(32, 32, 32)
	pFA.BorderSizePixel = 0
	pFA.ZIndex = popup.ZIndex
	pFA.Parent = pOG

	local pC = Instance.new("Frame")
	pC.Position = UDim2.fromOffset(6, 6)
	pC.Size = UDim2.new(1, -12, 1, -12)
	pC.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
	pC.BorderSizePixel = 0
	pC.ZIndex = popup.ZIndex
	pC.Parent = pFA
	local pCS = Instance.new("UIStroke")
	pCS.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	pCS.Thickness = 1
	pCS.Color = Color3.fromRGB(45, 45, 45)
	pCS.Parent = pC

	-- Drag area (behind everything so whole popup drags)
	local dragArea = Instance.new("TextButton")
	dragArea.BackgroundTransparency = 1
	dragArea.BorderSizePixel = 0
	dragArea.Position = UDim2.fromOffset(0, 0)
	dragArea.Size = UDim2.new(1, 0, 1, 0)
	dragArea.Text = ""
	dragArea.AutoButtonColor = false
	dragArea.ZIndex = popup.ZIndex
	dragArea.Parent = pC

	-- SV (saturation/value) square
	local svFrame = Instance.new("Frame")
	svFrame.Name = "SV"
	svFrame.Position = UDim2.fromOffset(10, 10)
	svFrame.Size = UDim2.fromOffset(svSize, svSize)
	svFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	svFrame.BorderSizePixel = 0
	svFrame.ZIndex = popup.ZIndex + 2
	svFrame.Parent = pC

	local svBase = Instance.new("Frame")
	svBase.Position = UDim2.fromOffset(0, 0)
	svBase.Size = UDim2.new(1, 0, 1, 0)
	svBase.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	svBase.BorderSizePixel = 0
	svBase.ZIndex = svFrame.ZIndex
	svBase.Parent = svFrame
	local svBaseGrad = Instance.new("UIGradient")
	svBaseGrad.Rotation = 0
	svBaseGrad.Parent = svBase

	local svValOverlay = Instance.new("Frame")
	svValOverlay.Position = UDim2.fromOffset(0, 0)
	svValOverlay.Size = UDim2.new(1, 0, 1, 0)
	svValOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	svValOverlay.BorderSizePixel = 0
	svValOverlay.ZIndex = svFrame.ZIndex + 1
	svValOverlay.Parent = svFrame
	local svValGrad = Instance.new("UIGradient")
	svValGrad.Rotation = 90
	svValGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	svValGrad.Parent = svValOverlay

	local svStroke = Instance.new("UIStroke")
	svStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	svStroke.Thickness = 1
	svStroke.Color = Color3.fromRGB(0, 0, 0)
	svStroke.Transparency = 0.2
	svStroke.Parent = svFrame

	local svHit = Instance.new("TextButton")
	svHit.BackgroundTransparency = 1
	svHit.BorderSizePixel = 0
	svHit.Size = UDim2.new(1, 0, 1, 0)
	svHit.Position = UDim2.fromOffset(0, 0)
	svHit.Text = ""
	svHit.AutoButtonColor = false
	svHit.ZIndex = svFrame.ZIndex + 10
	svHit.Parent = svFrame

	local svCursor = Instance.new("Frame")
	svCursor.Name = "SVCursor"
	svCursor.AnchorPoint = Vector2.new(0.5, 0.5)
	svCursor.Position = UDim2.fromOffset(0, 0)
	svCursor.Size = UDim2.fromOffset(10, 10)
	svCursor.BackgroundTransparency = 1
	svCursor.BorderSizePixel = 0
	svCursor.ZIndex = svFrame.ZIndex + 20
	svCursor.Parent = svFrame
	local svCursorCorner = Instance.new("UICorner")
	svCursorCorner.CornerRadius = UDim.new(1, 0)
	svCursorCorner.Parent = svCursor
	local svCursorStroke = Instance.new("UIStroke")
	svCursorStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	svCursorStroke.Thickness = 2
	svCursorStroke.Color = Color3.fromRGB(255, 255, 255)
	svCursorStroke.Parent = svCursor

	-- Hue bar
	local hueFrame = Instance.new("Frame")
	hueFrame.Name = "Hue"
	hueFrame.Position = UDim2.fromOffset(10 + svSize + gap, 10)
	hueFrame.Size = UDim2.fromOffset(barW, svSize)
	hueFrame.BackgroundTransparency = 1
	hueFrame.BorderSizePixel = 0
	hueFrame.ClipsDescendants = true
	hueFrame.ZIndex = popup.ZIndex + 2
	hueFrame.Parent = pC

	local hueSegs = {}
	for i = 0, 127 do
		local seg = Instance.new("Frame")
		seg.BorderSizePixel = 0
		seg.Position = UDim2.fromOffset(0, 0)
		seg.Size = UDim2.new(1, 0, 0, 1)
		seg.BackgroundColor3 = Color3.fromHSV(1 - (i / 127), 1, 1)
		seg.ZIndex = hueFrame.ZIndex
		seg.Parent = hueFrame
		hueSegs[i + 1] = seg
	end

	local hueStroke = Instance.new("UIStroke")
	hueStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	hueStroke.Thickness = 1
	hueStroke.Color = Color3.fromRGB(0, 0, 0)
	hueStroke.Transparency = 0.2
	hueStroke.Parent = hueFrame

	local hueHit = Instance.new("TextButton")
	hueHit.BackgroundTransparency = 1
	hueHit.BorderSizePixel = 0
	hueHit.Size = UDim2.new(1, 0, 1, 0)
	hueHit.Position = UDim2.fromOffset(0, 0)
	hueHit.Text = ""
	hueHit.AutoButtonColor = false
	hueHit.ZIndex = hueFrame.ZIndex + 10
	hueHit.Parent = hueFrame

	local hueMark = Instance.new("Frame")
	hueMark.AnchorPoint = Vector2.new(0.5, 0.5)
	hueMark.Position = UDim2.fromScale(0.5, 0)
	hueMark.Size = UDim2.new(1, 6, 0, 2)
	hueMark.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	hueMark.BorderSizePixel = 0
	hueMark.ZIndex = hueFrame.ZIndex + 20
	hueMark.Parent = hueFrame

	-- Alpha bar
	local alphaFrame = Instance.new("Frame")
	alphaFrame.Name = "Alpha"
	alphaFrame.Position = UDim2.fromOffset(10 + svSize + gap + barW + gap, 10)
	alphaFrame.Size = UDim2.fromOffset(barW, svSize)
	alphaFrame.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
	alphaFrame.BorderSizePixel = 0
	alphaFrame.ZIndex = popup.ZIndex + 2
	alphaFrame.Parent = pC

	local alphaStroke = Instance.new("UIStroke")
	alphaStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	alphaStroke.Thickness = 1
	alphaStroke.Color = Color3.fromRGB(0, 0, 0)
	alphaStroke.Transparency = 0.2
	alphaStroke.Parent = alphaFrame

	local alphaChecker = Instance.new("ImageLabel")
	alphaChecker.Position = UDim2.fromOffset(0, 0)
	alphaChecker.Size = UDim2.new(1, 0, 1, 0)
	alphaChecker.BackgroundTransparency = 1
	alphaChecker.BorderSizePixel = 0
	alphaChecker.ZIndex = alphaFrame.ZIndex
	alphaChecker.Image = "rbxassetid://9738374438"
	alphaChecker.ScaleType = Enum.ScaleType.Tile
	alphaChecker.TileSize = UDim2.fromOffset(8, 8)
	alphaChecker.ImageTransparency = 0.5
	alphaChecker.Parent = alphaFrame

	local alphaFill = Instance.new("Frame")
	alphaFill.Position = UDim2.fromOffset(0, 0)
	alphaFill.Size = UDim2.new(1, 0, 1, 0)
	alphaFill.BackgroundColor3 = getColor()
	alphaFill.BorderSizePixel = 0
	alphaFill.ZIndex = alphaFrame.ZIndex + 1
	alphaFill.Parent = alphaFrame
	local alphaGrad = Instance.new("UIGradient")
	alphaGrad.Rotation = 90
	alphaGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	alphaGrad.Parent = alphaFill

	local alphaHit = Instance.new("TextButton")
	alphaHit.BackgroundTransparency = 1
	alphaHit.BorderSizePixel = 0
	alphaHit.Size = UDim2.new(1, 0, 1, 0)
	alphaHit.Position = UDim2.fromOffset(0, 0)
	alphaHit.Text = ""
	alphaHit.AutoButtonColor = false
	alphaHit.ZIndex = alphaFrame.ZIndex + 10
	alphaHit.Parent = alphaFrame

	local alphaMark = Instance.new("Frame")
	alphaMark.AnchorPoint = Vector2.new(0.5, 0.5)
	alphaMark.Position = UDim2.fromScale(0.5, 0)
	alphaMark.Size = UDim2.new(1, 6, 0, 2)
	alphaMark.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	alphaMark.BorderSizePixel = 0
	alphaMark.ZIndex = alphaFrame.ZIndex + 20
	alphaMark.Parent = alphaFrame

	-- Local HSV state (synced when picker opens)
	local localHue, localSat, localVal = getColor():ToHSV()
	local localAlpha = getAlpha()

	local function refreshUI()
		local col = Color3.fromHSV(localHue, localSat, localVal)
		setColor(col)
		setAlpha(localAlpha)
		-- update swatch
		swatch.BackgroundColor3 = col
		swatch.BackgroundTransparency = 1 - localAlpha
		-- sv gradient
		svBaseGrad.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromHSV(localHue, 1, 1))
		alphaFill.BackgroundColor3 = col
		-- cursor positions
		local svW = svFrame.AbsoluteSize.X
		local svH = svFrame.AbsoluteSize.Y
		if svW > 0 and svH > 0 then
			svCursor.Position = UDim2.fromOffset(
				math.floor(clamp01(localSat) * (svW - 1)),
				math.floor(clamp01(1 - localVal) * (svH - 1))
			)
		end
		local hH = hueFrame.AbsoluteSize.Y
		if hH > 0 then
			for i = 0, 127 do
				local y0 = math.floor((i / 128) * hH)
				local y1 = math.floor(((i + 1) / 128) * hH)
				local hh = math.max(1, y1 - y0)
				local seg = hueSegs[i + 1]
				if seg then
					seg.Position = UDim2.fromOffset(0, y0)
					seg.Size = UDim2.new(1, 0, 0, hh)
				end
			end
			hueMark.Position = UDim2.fromOffset(
				math.floor(hueFrame.AbsoluteSize.X / 2),
				math.floor(clamp01(1 - localHue) * (hH - 1))
			)
		end
		local aH = alphaFrame.AbsoluteSize.Y
		if aH > 0 then
			alphaMark.Position = UDim2.fromOffset(
				math.floor(alphaFrame.AbsoluteSize.X / 2),
				math.floor(clamp01(1 - localAlpha) * (aH - 1))
			)
		end
		if onChanged then pcall(onChanged) end
	end

	local function setSVFromPos(absX, absY)
		local x0 = svFrame.AbsolutePosition.X
		local y0 = svFrame.AbsolutePosition.Y
		local w = svFrame.AbsoluteSize.X
		local h = svFrame.AbsoluteSize.Y
		if w <= 0 or h <= 0 then return end
		localSat = clamp01((absX - x0) / w)
		localVal = 1 - clamp01((absY - y0) / h)
		refreshUI()
	end

	local function setHueFromY(absY)
		local y0 = hueFrame.AbsolutePosition.Y
		local h = hueFrame.AbsoluteSize.Y
		if h <= 0 then return end
		localHue = 1 - clamp01((absY - y0) / h)
		refreshUI()
	end

	local function setAlphaFromY(absY)
		local y0 = alphaFrame.AbsolutePosition.Y
		local h = alphaFrame.AbsoluteSize.Y
		if h <= 0 then return end
		localAlpha = 1 - clamp01((absY - y0) / h)
		refreshUI()
	end

	-- Drag state
	local draggingSV    = false
	local draggingHue   = false
	local draggingAlpha = false
	local popupDragging = false
	local popupDragStartMouse = nil
	local popupDragStartPos   = nil

	local function closePicker()
		popup.Visible = false
		overlay.Visible = false
		draggingSV = false
		draggingHue = false
		draggingAlpha = false
		popupDragging = false
	end

	track(svHit.MouseButton1Down:Connect(function()
		draggingSV = true
		local ml = getMouseUiPos()
		setSVFromPos(ml.X, ml.Y)
	end))
	track(hueHit.MouseButton1Down:Connect(function()
		draggingHue = true
		local ml = getMouseUiPos()
		setHueFromY(ml.Y)
	end))
	track(alphaHit.MouseButton1Down:Connect(function()
		draggingAlpha = true
		local ml = getMouseUiPos()
		setAlphaFromY(ml.Y)
	end))
	track(dragArea.MouseButton1Down:Connect(function()
		popupDragging = true
		popupDragStartMouse = getMouseUiPos()
		popupDragStartPos = popup.Position
	end))

	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			draggingSV = false
			draggingHue = false
			draggingAlpha = false
			popupDragging = false
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		local ml = getMouseUiPos()
		if draggingSV    then setSVFromPos(ml.X, ml.Y) end
		if draggingHue   then setHueFromY(ml.Y) end
		if draggingAlpha then setAlphaFromY(ml.Y) end
		if popupDragging and popupDragStartMouse and popupDragStartPos then
			local dx = ml.X - popupDragStartMouse.X
			local dy = ml.Y - popupDragStartMouse.Y
			popup.Position = UDim2.fromOffset(
				math.floor(popupDragStartPos.X.Offset + dx),
				math.floor(popupDragStartPos.Y.Offset + dy)
			)
		end
	end))

	track(overlay.MouseButton1Click:Connect(function()
		closePicker()
	end))

	track(swatch.MouseButton1Click:Connect(function()
		popup.Visible = not popup.Visible
		overlay.Visible = popup.Visible
		if popup.Visible then
			localHue, localSat, localVal = getColor():ToHSV()
			localAlpha = getAlpha()
			local p  = swatch.AbsolutePosition
			local sz = swatch.AbsoluteSize
			popup.Position = UDim2.fromOffset(
				math.floor(p.X - pickerW + sz.X + 24),
				math.floor(p.Y + sz.Y + 6)
			)
			refreshUI()
		end
	end))

	track(RunService.RenderStepped:Connect(function()
		if popup.Visible then refreshUI() end
	end))

	return swatch
end

-- ── Main GUI ─────────────────────────────────────────────────────────────────

local function createGui()
	if screenGui and screenGui.Parent then return screenGui end

	local parent = getGuiParent()
	if not parent then return nil end

	local sg = Instance.new("ScreenGui")
	sg.Name = "BlackDoubleBorderGui"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.Enabled = true
	pcall(function() sg.Parent = parent end)
	if not sg.Parent then
		pcall(function() sg.Parent = localPlayer:WaitForChild("PlayerGui", 2) end)
	end
	if not sg.Parent then return nil end

	-- Root window
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.AnchorPoint = Vector2.new(0, 0)
	root.Size = UDim2.fromOffset(420, 320)
	pcall(function()
		local cam = workspace.CurrentCamera
		if cam then
			local vp = cam.ViewportSize
			root.Position = UDim2.fromOffset(math.floor((vp.X - 420) / 2), math.floor((vp.Y - 320) / 2))
		else
			root.Position = UDim2.fromOffset(100, 100)
		end
	end)
	if root.Position == UDim2.new() then root.Position = UDim2.fromOffset(100, 100) end
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Active = true
	root.Parent = sg

	local dragActive = false
	local dragInput = nil
	local dragStartMouse = nil
	local dragStartPos = nil

	-- Border layers
	local outerBlack = Instance.new("Frame")
	outerBlack.Name = "OuterBlack"
	outerBlack.Position = UDim2.fromOffset(0, 0)
	outerBlack.Size = UDim2.new(1, 0, 1, 0)
	outerBlack.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	outerBlack.BorderSizePixel = 0
	outerBlack.Active = true
	outerBlack.Parent = root

	local outerGray = Instance.new("Frame")
	outerGray.Position = UDim2.fromOffset(1, 1)
	outerGray.Size = UDim2.new(1, -2, 1, -2)
	outerGray.BackgroundColor3 = Color3.fromRGB(85, 85, 85)
	outerGray.BorderSizePixel = 0
	outerGray.Parent = outerBlack

	local frameArea = Instance.new("Frame")
	frameArea.Position = UDim2.fromOffset(1, 1)
	frameArea.Size = UDim2.new(1, -2, 1, -2)
	frameArea.BackgroundColor3 = Color3.fromRGB(32, 32, 32)
	frameArea.BorderSizePixel = 0
	frameArea.Parent = outerGray

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Position = UDim2.fromOffset(7, 7)
	content.Size = UDim2.new(1, -14, 1, -14)
	content.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
	content.BorderSizePixel = 0
	content.Parent = frameArea

	-- RGB bar
	local rgbBar = Instance.new("Frame")
	rgbBar.Position = UDim2.fromOffset(1, 1)
	rgbBar.Size = UDim2.new(1, -2, 0, 1)
	rgbBar.BackgroundTransparency = 1
	rgbBar.BorderSizePixel = 0
	rgbBar.ZIndex = 20
	rgbBar.ClipsDescendants = true
	rgbBar.Parent = content

	local function mute(c) return c:Lerp(Color3.fromRGB(128, 128, 128), 0.6) end
	local function makeRainbow(p)
		local g = Instance.new("UIGradient")
		g.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0.00, mute(Color3.fromRGB(255, 0, 0))),
			ColorSequenceKeypoint.new(0.17, mute(Color3.fromRGB(255, 255, 0))),
			ColorSequenceKeypoint.new(0.33, mute(Color3.fromRGB(0, 255, 0))),
			ColorSequenceKeypoint.new(0.50, mute(Color3.fromRGB(0, 255, 255))),
			ColorSequenceKeypoint.new(0.67, mute(Color3.fromRGB(0, 0, 255))),
			ColorSequenceKeypoint.new(0.83, mute(Color3.fromRGB(255, 0, 255))),
			ColorSequenceKeypoint.new(1.00, mute(Color3.fromRGB(255, 0, 0))),
		})
		g.Rotation = 0
		g.Parent = p
		return g
	end
	local rgbA = Instance.new("Frame")
	rgbA.Size = UDim2.fromOffset(0, 1); rgbA.BackgroundColor3 = Color3.new(1,1,1)
	rgbA.BorderSizePixel = 0; rgbA.ZIndex = 20; rgbA.Parent = rgbBar
	makeRainbow(rgbA)
	local rgbB = Instance.new("Frame")
	rgbB.Size = UDim2.fromOffset(0, 1); rgbB.BackgroundColor3 = Color3.new(1,1,1)
	rgbB.BorderSizePixel = 0; rgbB.ZIndex = 20; rgbB.Parent = rgbBar
	makeRainbow(rgbB)
	local rgbPhase, rgbLastW = 0, 0
	track(RunService.RenderStepped:Connect(function(dt)
		pcall(function()
			local w = rgbBar.AbsoluteSize.X
			if w <= 0 then return end
			if rgbLastW <= 0 then rgbLastW = w end
			rgbPhase = (rgbPhase + (dt * 60) / rgbLastW) % 1
			rgbLastW = w
			local shift = rgbPhase * w
			rgbA.Size = UDim2.fromOffset(w, 1); rgbB.Size = UDim2.fromOffset(w, 1)
			rgbA.Position = UDim2.fromOffset(-shift, 0)
			rgbB.Position = UDim2.fromOffset(-shift + w, 0)
		end)
	end))

	-- Sidebar
	local sidebarW = 132
	local sidebar = Instance.new("Frame")
	sidebar.Position = UDim2.fromOffset(0, 0)
	sidebar.Size = UDim2.new(0, sidebarW, 1, 0)
	sidebar.BackgroundTransparency = 1
	sidebar.BorderSizePixel = 0
	sidebar.Parent = content

	local sep = Instance.new("Frame")
	sep.AnchorPoint = Vector2.new(1, 0)
	sep.Position = UDim2.new(1, 0, 0, 1)
	sep.Size = UDim2.new(0, 2, 1, -1)
	sep.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
	sep.BorderSizePixel = 0; sep.ZIndex = 5; sep.Parent = sidebar

	local header = Instance.new("TextLabel")
	header.Text = "ANTILOSE"
	header.Size = UDim2.new(1, -10, 0, 40)
	header.Position = UDim2.fromOffset(10, 5)
	header.BackgroundTransparency = 1
	header.TextColor3 = Color3.fromRGB(255, 255, 255)
	header.TextSize = 24; header.Font = Enum.Font.GothamBlack
	header.TextStrokeTransparency = 0.8
	header.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Parent = sidebar

	local tabContainer = Instance.new("Frame")
	tabContainer.Position = UDim2.fromOffset(10, 45)
	tabContainer.Size = UDim2.new(1, -10, 1, -45)
	tabContainer.BackgroundTransparency = 1
	tabContainer.BorderSizePixel = 0
	tabContainer.Parent = sidebar

	-- Content panel
	local cpPad, cpTop = 12, 18
	local cpBorder = Instance.new("Frame")
	cpBorder.Position = UDim2.fromOffset(sidebarW + cpPad, cpTop)
	cpBorder.Size = UDim2.new(1, -(sidebarW + cpPad + 14), 1, -(cpTop * 2))
	cpBorder.BackgroundTransparency = 1; cpBorder.BorderSizePixel = 0
	cpBorder.ZIndex = 3; cpBorder.Parent = content
	local cpStroke = Instance.new("UIStroke")
	cpStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	cpStroke.Thickness = 1; cpStroke.Color = Color3.fromRGB(45, 45, 45)
	cpStroke.Parent = cpBorder

	local contentPanel = Instance.new("Frame")
	contentPanel.Position = UDim2.fromOffset(0, 0)
	contentPanel.Size = UDim2.new(1, 0, 1, 0)
	contentPanel.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
	contentPanel.BorderSizePixel = 0
	contentPanel.ZIndex = cpBorder.ZIndex
	contentPanel.Parent = cpBorder

	local contentTitle = Instance.new("TextLabel")
	contentTitle.BackgroundTransparency = 1; contentTitle.BorderSizePixel = 0
	contentTitle.Position = UDim2.fromOffset(sidebarW + cpPad + 8, cpTop - 14)
	contentTitle.Size = UDim2.fromOffset(0, 0)
	contentTitle.AutomaticSize = Enum.AutomaticSize.XY
	contentTitle.Text = ""; contentTitle.TextColor3 = Color3.fromRGB(220, 220, 220)
	contentTitle.TextSize = 18; contentTitle.Font = Enum.Font.SourceSans
	contentTitle.TextXAlignment = Enum.TextXAlignment.Left
	contentTitle.ZIndex = cpBorder.ZIndex + 10; contentTitle.Parent = content
	local cpTP = Instance.new("UIPadding")
	cpTP.PaddingLeft = UDim.new(0,6); cpTP.PaddingRight = UDim.new(0,6)
	cpTP.PaddingTop = UDim.new(0,2); cpTP.PaddingBottom = UDim.new(0,2)
	cpTP.Parent = contentTitle

	-- Tabs
	local tabs = {"aimbot", "visual", "skins", "misc", "exploits", "stats", "config"}
	local tabButtons = {}
	local pages = {}
	local currentTab = nil

	for _, tabName in ipairs(tabs) do
		local page = Instance.new("Frame")
		page.Name = tabName .. "Page"
		page.BackgroundTransparency = 1; page.BorderSizePixel = 0
		page.Position = UDim2.fromOffset(0, 0); page.Size = UDim2.new(1, 0, 1, 0)
		page.Visible = false; page.ZIndex = 100; page.ClipsDescendants = true
		page.Parent = contentPanel
		pages[tabName] = page
	end

	local function switchTab(tabName)
		if currentTab == tabName then return end
		for name, btn in pairs(tabButtons) do
			local tc = (name == tabName) and Color3.fromRGB(255,255,255) or Color3.fromRGB(180,180,180)
			TweenService:Create(btn, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {TextColor3 = tc}):Play()
		end
		for name, page in pairs(pages) do page.Visible = (name == tabName) end
		contentTitle.Text = tabName
		currentTab = tabName
	end

	for i, tabName in ipairs(tabs) do
		local btn = Instance.new("TextButton")
		btn.Text = tabName; btn.Size = UDim2.new(1, 0, 0, 20)
		btn.Position = UDim2.fromOffset(0, (i-1)*22)
		btn.BackgroundTransparency = 1; btn.BorderSizePixel = 0
		btn.TextColor3 = Color3.fromRGB(180, 180, 180)
		btn.TextSize = 19; btn.Font = Enum.Font.SourceSans
		btn.TextXAlignment = Enum.TextXAlignment.Left; btn.Parent = tabContainer
		track(btn.MouseButton1Click:Connect(function() switchTab(tabName) end))
		tabButtons[tabName] = btn
	end

	-- Toggle builder
	local function addToggle(parent, text, defaultState, callback)
		local container = Instance.new("Frame")
		container.Name = text .. "Toggle"
		container.Size = UDim2.new(1, -20, 0, 32)
		container.BackgroundTransparency = 1
		container.ZIndex = parent.ZIndex + 1
		container.Parent = parent

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -50, 1, -2); label.Position = UDim2.fromOffset(16, 0)
		label.BackgroundTransparency = 1; label.Text = text
		label.TextColor3 = Color3.fromRGB(200, 200, 200)
		label.TextSize = 16; label.Font = Enum.Font.SourceSans
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.ZIndex = container.ZIndex + 1; label.Parent = container

		local bg = Instance.new("TextButton")
		bg.Name = "ToggleBg"; bg.AnchorPoint = Vector2.new(1, 0.5)
		bg.Position = UDim2.new(1, -12, 0.5, -1); bg.Size = UDim2.fromOffset(31, 9)
		bg.BackgroundColor3 = defaultState and Color3.fromRGB(80,80,80) or Color3.fromRGB(40,40,40)
		bg.BorderSizePixel = 0; bg.Text = ""; bg.AutoButtonColor = false
		bg.ZIndex = container.ZIndex + 1; bg.Parent = container

		local bgStroke = Instance.new("UIStroke")
		bgStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; bgStroke.Thickness = 1
		bgStroke.Color = defaultState and Color3.fromRGB(100,100,100) or Color3.fromRGB(50,50,50)
		bgStroke.Parent = bg

		local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(1,0); corner.Parent = bg

		local knob = Instance.new("Frame"); knob.Name = "Knob"
		knob.Size = UDim2.fromOffset(16, 16)
		knob.Position = defaultState and UDim2.new(1,-6,0.5,0) or UDim2.new(0,6,0.5,0)
		knob.AnchorPoint = Vector2.new(0.5, 0.5)
		knob.BackgroundColor3 = defaultState and Color3.fromRGB(255,255,255) or Color3.fromRGB(120,120,120)
		knob.BorderSizePixel = 0; knob.ZIndex = bg.ZIndex + 2; knob.Parent = bg
		local kc = Instance.new("UICorner"); kc.CornerRadius = UDim.new(1,0); kc.Parent = knob

		local line = Instance.new("Frame")
		line.Size = UDim2.new(1,-24,0,1); line.Position = UDim2.new(0,12,1,-1)
		line.BackgroundColor3 = Color3.fromRGB(45,45,45); line.BorderSizePixel = 0
		line.ZIndex = container.ZIndex + 1; line.Parent = container

		toggleState[container] = {enabled = defaultState, bg = bg, knob = knob, stroke = bgStroke, callback = callback}
		setToggleState(container, defaultState, false)
		track(bg.MouseButton1Click:Connect(function()
			setToggleState(container, not getToggleState(container), true)
		end))
		return container
	end

	-- ── aimbot page ──
	local aimbotContent = Instance.new("ScrollingFrame")
	aimbotContent.BackgroundTransparency = 1; aimbotContent.Position = UDim2.fromOffset(0,15)
	aimbotContent.Size = UDim2.new(1,0,1,-15); aimbotContent.Parent = pages["aimbot"]
	aimbotContent.ScrollBarThickness = 3
	aimbotContent.ScrollBarImageColor3 = Color3.fromRGB(80,80,80)
	aimbotContent.BorderSizePixel = 0
	aimbotContent.AutomaticCanvasSize = Enum.AutomaticSize.Y
	aimbotContent.CanvasSize = UDim2.new(0,0,0,0)
	aimbotContent.ClipsDescendants = true
	aimbotContent.ScrollingEnabled = true
	aimbotContent.ElasticBehavior = Enum.ElasticBehavior.Never
	local al = Instance.new("UIListLayout"); al.Padding = UDim.new(0,4); al.Parent = aimbotContent

	-- Aimbot toggle
	addToggle(aimbotContent, "Aimbot", false, function(v)
		AB.enabled = v
	end)

	-- Wall Check toggle (VisCheck)
	addToggle(aimbotContent, "Wall Check", false, function(v)
		AB.VisCheck = v
	end)

	-- Team Check toggle
	addToggle(aimbotContent, "Team Check", false, function(v)
		AB.TeamCheck = v
	end)

	-- Auto Switch toggle
	addToggle(aimbotContent, "Auto Switch", true, function(v)
		AB.AutoSwitch = v
	end)

	-- Show FOV Circle toggle
	addToggle(aimbotContent, "Show FOV", true, function(v)
		AB_ShowFOV = v
		if not v and fovCircle then fovCircle.Visible = false end
	end)

	-- FOV Check toggle (если выключен — аим 360°)
	addToggle(aimbotContent, "FOV Check", true, function(v)
		AB.FOVCheck = v
		if fovCircle then fovCircle.Visible = v and AB.enabled and AB_ShowFOV end
	end)

	-- Auto Fire toggle
	addToggle(aimbotContent, "Auto Fire", false, function(v)
		AB.AutoFire = v
		autoFireCooldown = false
	end)

	-- Back Camera toggle
	addToggle(aimbotContent, "Back Camera", false, function(v)
		AB.BackCamera = v
		if not v then preShotCameraRef = nil end
	end)

	-- ── Keybind row (Aim Key) ──
	do
		local bindListening = false
		local bindDotAnim   = nil

		local function keyOrButtonName(inp)
			if inp.UserInputType == Enum.UserInputType.Keyboard then
				return tostring(inp.KeyCode):gsub("Enum%.KeyCode%.", "")
			elseif inp.UserInputType == Enum.UserInputType.MouseButton1 then
				return "Mouse1"
			elseif inp.UserInputType == Enum.UserInputType.MouseButton2 then
				return "Mouse2"
			elseif inp.UserInputType == Enum.UserInputType.MouseButton3 then
				return "Mouse3"
			end
			return nil
		end

		local function currentBindLabel()
			local v = AB.AimKey
			if typeof(v) == "EnumItem" then
				if v.EnumType == Enum.UserInputType then
					local s = tostring(v):gsub("Enum%.UserInputType%.", "")
					if s == "MouseButton1" then return "Mouse1" end
					if s == "MouseButton2" then return "Mouse2" end
					if s == "MouseButton3" then return "Mouse3" end
					return s
				elseif v.EnumType == Enum.KeyCode then
					return tostring(v):gsub("Enum%.KeyCode%.", "")
				end
			end
			return "???"
		end

		local bindRow = Instance.new("Frame")
		bindRow.Name = "AimKeyBind"
		bindRow.Size = UDim2.new(1, -20, 0, 32)
		bindRow.BackgroundTransparency = 1
		bindRow.ZIndex = aimbotContent.ZIndex + 1
		bindRow.Parent = aimbotContent

		local bindLabel = Instance.new("TextLabel")
		bindLabel.Size = UDim2.new(1, -120, 1, 0)
		bindLabel.Position = UDim2.fromOffset(16, 0)
		bindLabel.BackgroundTransparency = 1
		bindLabel.Text = "Aim Key"
		bindLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
		bindLabel.TextSize = 16
		bindLabel.Font = Enum.Font.SourceSans
		bindLabel.TextXAlignment = Enum.TextXAlignment.Left
		bindLabel.ZIndex = bindRow.ZIndex + 1
		bindLabel.Parent = bindRow

		local bindBtn = Instance.new("TextButton")
		bindBtn.AnchorPoint = Vector2.new(1, 0.5)
		bindBtn.Position = UDim2.new(1, -12, 0.5, -1)
		bindBtn.Size = UDim2.fromOffset(96, 20)
		bindBtn.BackgroundColor3 = Color3.fromRGB(28, 28, 28)
		bindBtn.BorderSizePixel = 0
		bindBtn.AutoButtonColor = false
		bindBtn.TextColor3 = Color3.fromRGB(200, 200, 200)
		bindBtn.TextSize = 13
		bindBtn.Font = Enum.Font.SourceSans
		bindBtn.Text = currentBindLabel()
		bindBtn.ZIndex = bindRow.ZIndex + 2
		bindBtn.Parent = bindRow
		local bbCorner = Instance.new("UICorner"); bbCorner.CornerRadius = UDim.new(0, 3); bbCorner.Parent = bindBtn
		local bbStroke = Instance.new("UIStroke"); bbStroke.Thickness = 1; bbStroke.Color = Color3.fromRGB(55, 55, 55); bbStroke.Parent = bindBtn

		local bindSepLine = Instance.new("Frame")
		bindSepLine.Size = UDim2.new(1, -24, 0, 1)
		bindSepLine.Position = UDim2.new(0, 12, 1, -1)
		bindSepLine.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
		bindSepLine.BorderSizePixel = 0
		bindSepLine.ZIndex = bindRow.ZIndex + 1
		bindSepLine.Parent = bindRow

		-- анимация трёх точек пока слушаем бинд
		local function startDotAnim()
			if bindDotAnim then return end
			local dots = 0
			bindDotAnim = RunService.RenderStepped:Connect(function()
				dots = (dots + 1) % 4
				bindBtn.Text = string.rep(".", dots == 0 and 3 or dots)
				bindBtn.TextColor3 = Color3.fromRGB(255, 255, 120)
				bbStroke.Color = Color3.fromRGB(180, 180, 60)
			end)
		end

		local function stopDotAnim()
			if bindDotAnim then bindDotAnim:Disconnect(); bindDotAnim = nil end
			bindBtn.Text = currentBindLabel()
			bindBtn.TextColor3 = Color3.fromRGB(200, 200, 200)
			bbStroke.Color = Color3.fromRGB(55, 55, 55)
		end

		local bindInputConn = nil
		local function stopListening()
			bindListening = false
			stopDotAnim()
			if bindInputConn then bindInputConn:Disconnect(); bindInputConn = nil end
		end

		local function startListening()
			if bindListening then stopListening(); return end
			bindListening = true
			startDotAnim()

			bindInputConn = UserInputService.InputBegan:Connect(function(input, gp)
				-- игнорируем ЛКМ только на кнопке самого меню
				if not bindListening then return end

				local name = keyOrButtonName(input)
				if not name then return end

				-- Escape — отмена
				if input.KeyCode == Enum.KeyCode.Escape then
					stopListening()
					return
				end

				-- применяем бинд
				if input.UserInputType == Enum.UserInputType.Keyboard then
					AB.AimKey = input.KeyCode
				else
					AB.AimKey = input.UserInputType
				end

				stopListening()
			end)
		end

		track(bindBtn.MouseButton1Click:Connect(function()
			startListening()
		end))
	end

	-- ── addSlider helper (local, только для aimbot page) ──
	local function addSlider(parent, labelText, getVal, setVal, minV, maxV, inc)
		local rowH = 38
		local container = Instance.new("Frame")
		container.Size = UDim2.new(1, -20, 0, rowH)
		container.BackgroundTransparency = 1
		container.ZIndex = parent.ZIndex + 1
		container.Parent = parent

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1, -16, 0, 16)
		lbl.Position = UDim2.fromOffset(16, 2)
		lbl.BackgroundTransparency = 1
		lbl.TextColor3 = Color3.fromRGB(200,200,200)
		lbl.TextSize = 15; lbl.Font = Enum.Font.SourceSans
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.ZIndex = container.ZIndex + 1; lbl.Parent = container

		local function fmtVal(v)
			if inc and inc < 1 then
				return string.format("%.2f", v)
			end
			return tostring(math.floor(v))
		end
		lbl.Text = labelText .. ": " .. fmtVal(getVal())

		-- trackHit — невидимая TextButton поверх всего для клика
		local trackHit = Instance.new("TextButton")
		trackHit.Size = UDim2.new(1, -28, 0, 20)
		trackHit.Position = UDim2.fromOffset(16, 15)
		trackHit.BackgroundTransparency = 1
		trackHit.BorderSizePixel = 0; trackHit.Text = ""; trackHit.AutoButtonColor = false
		trackHit.ZIndex = container.ZIndex + 6; trackHit.Parent = container

		-- trackBg — видимая полоска (Frame, не кликабельная)
		local trackBg = Instance.new("Frame")
		trackBg.Size = UDim2.new(1, -28, 0, 6)
		trackBg.Position = UDim2.fromOffset(16, 22)
		trackBg.BackgroundColor3 = Color3.fromRGB(35,35,35)
		trackBg.BorderSizePixel = 0
		trackBg.ZIndex = container.ZIndex + 1; trackBg.Parent = container
		local tbCorner = Instance.new("UICorner"); tbCorner.CornerRadius = UDim.new(1,0); tbCorner.Parent = trackBg
		local tbStroke = Instance.new("UIStroke"); tbStroke.Thickness = 1; tbStroke.Color = Color3.fromRGB(50,50,50); tbStroke.Parent = trackBg

		local fill = Instance.new("Frame")
		fill.BackgroundColor3 = Color3.fromRGB(80,80,80)
		fill.BorderSizePixel = 0
		fill.ZIndex = container.ZIndex + 2; fill.Parent = trackBg
		local fillCorner = Instance.new("UICorner"); fillCorner.CornerRadius = UDim.new(1,0); fillCorner.Parent = fill

		local knobBtn = Instance.new("Frame")
		knobBtn.Size = UDim2.fromOffset(14,14)
		knobBtn.AnchorPoint = Vector2.new(0.5,0.5)
		knobBtn.BackgroundColor3 = Color3.fromRGB(200,200,200)
		knobBtn.BorderSizePixel = 0
		knobBtn.ZIndex = container.ZIndex + 5; knobBtn.Parent = trackBg
		local kCorner = Instance.new("UICorner"); kCorner.CornerRadius = UDim.new(1,0); kCorner.Parent = knobBtn

		local sepLine = Instance.new("Frame")
		sepLine.Size = UDim2.new(1,-24,0,1); sepLine.Position = UDim2.new(0,12,1,-1)
		sepLine.BackgroundColor3 = Color3.fromRGB(45,45,45); sepLine.BorderSizePixel = 0
		sepLine.ZIndex = container.ZIndex + 1; sepLine.Parent = container

		local function updateVisual()
			local v = getVal()
			local pct = math.clamp((v - minV) / (maxV - minV), 0, 1)
			fill.Size = UDim2.new(pct, 0, 1, 0)
			knobBtn.Position = UDim2.new(pct, 0, 0.5, 0)
			lbl.Text = labelText .. ": " .. fmtVal(v)
		end
		updateVisual()

		local dragging = false
		local function applyX(absX)
			local x0 = trackHit.AbsolutePosition.X
			local w  = trackHit.AbsoluteSize.X
			if w <= 0 then return end
			local pct = math.clamp((absX - x0) / w, 0, 1)
			local raw = minV + (maxV - minV) * pct
			if inc then raw = math.floor(raw / inc + 0.5) * inc end
			raw = math.clamp(raw, minV, maxV)
			setVal(raw)
			updateVisual()
		end

		track(trackHit.MouseButton1Down:Connect(function()
			dragging = true
			applyX(getMouseUiPos().X)
		end))
		track(UserInputService.InputEnded:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
		end))
		track(UserInputService.InputChanged:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseWheel then return end
			if dragging and inp.UserInputType == Enum.UserInputType.MouseMovement then
				applyX(getMouseUiPos().X)
			end
		end))
		-- Forward mouse wheel to the parent ScrollingFrame
		track(trackHit.MouseWheelForward:Connect(function()
			if parent:IsA("ScrollingFrame") then
				parent.CanvasPosition = Vector2.new(
					parent.CanvasPosition.X,
					math.max(0, parent.CanvasPosition.Y - 40)
				)
			end
		end))
		track(trackHit.MouseWheelBackward:Connect(function()
			if parent:IsA("ScrollingFrame") then
				parent.CanvasPosition = Vector2.new(
					parent.CanvasPosition.X,
					parent.CanvasPosition.Y + 40
				)
			end
		end))

		return container
	end

	-- FOV слайдер
	addSlider(aimbotContent, "FOV", function() return AB.FOV end, function(v)
		AB.FOV = v
		if fovCircle then fovCircle.Radius = v end
	end, 10, 800, 1)

	-- Smoothness слайдер
	addSlider(aimbotContent, "Smoothness", function() return AB.Smoothness end, function(v) AB.Smoothness = v end, 0, 1.0, 0.01)

	-- BC Delay слайдер (задержка возврата камеры, мс)
	addSlider(aimbotContent, "BC Delay",
		function() return AB.BackCameraDelay end,
		function(v) AB.BackCameraDelay = v end,
		0, 1000, 10
	)

	-- ── Комбобокс: Target Parts (multi-select) ──
	local comboRowH = 32
	local comboContainer = Instance.new("Frame")
	comboContainer.Name = "TargetPartCombo"
	comboContainer.Size = UDim2.new(1, -20, 0, comboRowH)
	comboContainer.BackgroundTransparency = 1
	comboContainer.ZIndex = aimbotContent.ZIndex + 1
	comboContainer.Parent = aimbotContent

	local comboLabel = Instance.new("TextLabel")
	comboLabel.Size = UDim2.new(1, -120, 1, 0)
	comboLabel.Position = UDim2.fromOffset(16, 0)
	comboLabel.BackgroundTransparency = 1
	comboLabel.Text = "Target Part"
	comboLabel.TextColor3 = Color3.fromRGB(200,200,200)
	comboLabel.TextSize = 16; comboLabel.Font = Enum.Font.SourceSans
	comboLabel.TextXAlignment = Enum.TextXAlignment.Left
	comboLabel.ZIndex = comboContainer.ZIndex + 1; comboLabel.Parent = comboContainer

	-- Кнопка-дропдаун
	local comboBtn = Instance.new("TextButton")
	comboBtn.AnchorPoint = Vector2.new(1, 0.5)
	comboBtn.Position = UDim2.new(1, -12, 0.5, -1)
	comboBtn.Size = UDim2.fromOffset(96, 20)
	comboBtn.BackgroundColor3 = Color3.fromRGB(30,30,30)
	comboBtn.BorderSizePixel = 0; comboBtn.AutoButtonColor = false
	comboBtn.TextColor3 = Color3.fromRGB(200,200,200)
	comboBtn.TextSize = 13; comboBtn.Font = Enum.Font.SourceSans
	comboBtn.Text = "Head ▾"
	comboBtn.ZIndex = comboContainer.ZIndex + 2; comboBtn.Parent = comboContainer
	local cbCorner = Instance.new("UICorner"); cbCorner.CornerRadius = UDim.new(0,3); cbCorner.Parent = comboBtn
	local cbStroke = Instance.new("UIStroke"); cbStroke.Thickness = 1; cbStroke.Color = Color3.fromRGB(55,55,55); cbStroke.Parent = comboBtn

	local comboSepLine = Instance.new("Frame")
	comboSepLine.Size = UDim2.new(1,-24,0,1); comboSepLine.Position = UDim2.new(0,12,1,-1)
	comboSepLine.BackgroundColor3 = Color3.fromRGB(45,45,45); comboSepLine.BorderSizePixel = 0
	comboSepLine.ZIndex = comboContainer.ZIndex + 1; comboSepLine.Parent = comboContainer

	-- Dropdown popup (рисуется поверх всего в sg)
	local dropOpen = false
	local dropFrame = nil
	local dropOverlay = nil

	local function getSelectedLabel()
		local sel = {}
		for _, pname in ipairs(R16_PARTS) do
			if AB.targetParts[pname] then table.insert(sel, pname) end
		end
		if #sel == 0 then return "None ▾" end
		if #sel == 1 then return sel[1] .. " ▾" end
		return sel[1] .. " +" .. (#sel-1) .. " ▾"
	end

	local function refreshComboLabel()
		comboBtn.Text = getSelectedLabel()
	end

	local function closeDropdown()
		dropOpen = false
		if dropFrame then pcall(function() dropFrame:Destroy() end); dropFrame = nil end
		if dropOverlay then pcall(function() dropOverlay:Destroy() end); dropOverlay = nil end
	end

	local function openDropdown()
		if dropOpen then closeDropdown(); return end
		dropOpen = true

		local itemH = 22
		local dropH = #R16_PARTS * itemH + 6

		-- overlay для закрытия по клику мимо
		dropOverlay = Instance.new("TextButton")
		dropOverlay.BackgroundTransparency = 1; dropOverlay.BorderSizePixel = 0
		dropOverlay.Size = UDim2.new(1,0,1,0); dropOverlay.Text = ""
		dropOverlay.AutoButtonColor = false; dropOverlay.ZIndex = 198
		dropOverlay.Parent = sg
		track(dropOverlay.MouseButton1Click:Connect(function() closeDropdown() end))

		-- popup frame
		dropFrame = Instance.new("Frame")
		dropFrame.ZIndex = 199; dropFrame.BorderSizePixel = 0
		dropFrame.Size = UDim2.fromOffset(comboBtn.AbsoluteSize.X + 20, dropH)
		local absPos = comboBtn.AbsolutePosition
		local absSz  = comboBtn.AbsoluteSize
		dropFrame.Position = UDim2.fromOffset(absPos.X - 10, absPos.Y + absSz.Y + 2)

		-- outer black border
		local dfOB = Instance.new("Frame"); dfOB.Size = UDim2.new(1,0,1,0)
		dfOB.BackgroundColor3 = Color3.fromRGB(0,0,0); dfOB.BorderSizePixel = 0; dfOB.ZIndex = dropFrame.ZIndex; dfOB.Parent = dropFrame
		local dfOG = Instance.new("Frame"); dfOG.Position = UDim2.fromOffset(1,1); dfOG.Size = UDim2.new(1,-2,1,-2)
		dfOG.BackgroundColor3 = Color3.fromRGB(60,60,60); dfOG.BorderSizePixel = 0; dfOG.ZIndex = dropFrame.ZIndex; dfOG.Parent = dfOB
		local dfIn = Instance.new("Frame"); dfIn.Position = UDim2.fromOffset(1,1); dfIn.Size = UDim2.new(1,-2,1,-2)
		dfIn.BackgroundColor3 = Color3.fromRGB(22,22,22); dfIn.BorderSizePixel = 0; dfIn.ZIndex = dropFrame.ZIndex; dfIn.Parent = dfOG
		dropFrame.BackgroundTransparency = 1
		dropFrame.Parent = sg

		local itemButtons = {}
		for i, pname in ipairs(R16_PARTS) do
			local isOn = AB.targetParts[pname] == true
			local item = Instance.new("TextButton")
			item.Size = UDim2.new(1,-6,0,itemH-2)
			item.Position = UDim2.fromOffset(3, 3 + (i-1)*itemH)
			item.BackgroundColor3 = isOn and Color3.fromRGB(60,60,60) or Color3.fromRGB(28,28,28)
			item.BorderSizePixel = 0; item.AutoButtonColor = false
			item.Text = (isOn and "✓  " or "    ") .. pname
			item.TextColor3 = isOn and Color3.fromRGB(230,230,230) or Color3.fromRGB(160,160,160)
			item.TextSize = 13; item.Font = Enum.Font.SourceSans
			item.TextXAlignment = Enum.TextXAlignment.Left
			item.ZIndex = dropFrame.ZIndex + 5; item.Parent = dfIn
			local iCorner = Instance.new("UICorner"); iCorner.CornerRadius = UDim.new(0,3); iCorner.Parent = item
			local iPad = Instance.new("UIPadding"); iPad.PaddingLeft = UDim.new(0,8); iPad.Parent = item
			itemButtons[pname] = item

			track(item.MouseButton1Click:Connect(function()
				AB.targetParts[pname] = not AB.targetParts[pname]
				local nowOn = AB.targetParts[pname]
				item.BackgroundColor3 = nowOn and Color3.fromRGB(60,60,60) or Color3.fromRGB(28,28,28)
				item.Text = (nowOn and "✓  " or "    ") .. pname
				item.TextColor3 = nowOn and Color3.fromRGB(230,230,230) or Color3.fromRGB(160,160,160)
				refreshComboLabel()
			end))
		end
	end

	track(comboBtn.MouseButton1Click:Connect(function()
		openDropdown()
	end))

	refreshComboLabel()

	-- ── visual page ──
	local visualContent = Instance.new("Frame")
	visualContent.BackgroundTransparency = 1; visualContent.Position = UDim2.fromOffset(0,15)
	visualContent.Size = UDim2.new(1,0,1,-15); visualContent.Parent = pages["visual"]
	local vl = Instance.new("UIListLayout"); vl.Padding = UDim.new(0,5); vl.Parent = visualContent

	-- Highlight toggle + color picker
	local highlightToggle = addToggle(visualContent, "Highlight", false, function(v)
		setHighlightEnabled(v)
	end)

	-- Color picker swatch attached to highlightToggle
	createColorPicker(
		sg,
		highlightToggle,
		function() return highlightColor end,
		function(c) highlightColor = c end,
		function() return highlightAlpha end,
		function(a) highlightAlpha = a end,
		function() refreshHighlightColors() end
	)

	-- ── skins page ──
	local skinsContent = Instance.new("Frame")
	skinsContent.BackgroundTransparency = 1; skinsContent.Position = UDim2.fromOffset(0,15)
	skinsContent.Size = UDim2.new(1,0,1,-15); skinsContent.Parent = pages["skins"]
	local sl2 = Instance.new("UIListLayout"); sl2.Padding = UDim.new(0,5); sl2.Parent = skinsContent
	addToggle(skinsContent, "Skins", false, function(v) print("test") end)

	-- ── misc page ──
	local miscContent = Instance.new("ScrollingFrame")
	miscContent.BackgroundTransparency = 1; miscContent.Position = UDim2.fromOffset(0,15)
	miscContent.Size = UDim2.new(1,0,1,-15); miscContent.Parent = pages["misc"]
	miscContent.ScrollBarThickness = 3
	miscContent.ScrollBarImageColor3 = Color3.fromRGB(80,80,80)
	miscContent.BorderSizePixel = 0
	miscContent.AutomaticCanvasSize = Enum.AutomaticSize.Y
	miscContent.CanvasSize = UDim2.new(0,0,0,0)
	miscContent.ClipsDescendants = true
	miscContent.ScrollingEnabled = true
	miscContent.ElasticBehavior = Enum.ElasticBehavior.Never
	local ml2 = Instance.new("UIListLayout"); ml2.Padding = UDim.new(0,0); ml2.SortOrder = Enum.SortOrder.LayoutOrder; ml2.Parent = miscContent

	-- helper: секционный заголовок-разделитель (только верхняя линия)
	local function addSectionDivider(parent, title)
		local div = Instance.new("Frame")
		div.Size = UDim2.new(1, -20, 0, 10)
		div.BackgroundTransparency = 1
		div.ZIndex = parent.ZIndex + 1
		div.Parent = parent

		-- верхняя полоска
		local lineTop = Instance.new("Frame")
		lineTop.Size = UDim2.new(1, -24, 0, 1)
		lineTop.Position = UDim2.fromOffset(12, 5)
		lineTop.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
		lineTop.BorderSizePixel = 0
		lineTop.ZIndex = div.ZIndex + 1; lineTop.Parent = div

		return div
	end

	-- ── Hitsound system ──
	local hsEnabled   = false
	local hsVolume    = 100
	local hsCustomId  = "5159073368"
	local hsPresets   = {
		{ name = "nya",       id = "128315748935399" },
		{ name = "neverlose", id = "139452805868562" },
		{ name = "chomp",     id = "91209592691035"  },
		{ name = "bell",      id = "124010691633262" },
		{ name = "osu",       id = "123941247147792" },
		{ name = "custom",    id = nil               },
	}
	local hsPresetIdx = 1
	local hsSound     = nil

	local function getCurrentId()
		local p = hsPresets[hsPresetIdx]
		if p.name == "custom" then return hsCustomId end
		return p.id
	end

	local function createHsSound()
		if hsSound then pcall(function() hsSound:Destroy() end) end
		hsSound = Instance.new("Sound")
		hsSound.SoundId = "rbxassetid://" .. getCurrentId()
		hsSound.Volume  = hsVolume / 100
		hsSound.RollOffMaxDistance = 0
		hsSound.Parent  = game:GetService("SoundService")
	end
	createHsSound()

	local function playHitsound()
		if not hsEnabled or not hsSound then return end
		pcall(function()
			local clone = hsSound:Clone()
			clone.Parent = game:GetService("SoundService")
			clone:Play()
			clone.Ended:Connect(function() pcall(function() clone:Destroy() end) end)
		end)
	end

	local hitMarkerRE = game:GetService("ReplicatedStorage"):FindFirstChild("HitMarkerEvento")
	if hitMarkerRE then
		track(hitMarkerRE.OnClientEvent:Connect(function(arg1)
			playHitsound()
		end))
	end

	-- ══ helper: создать строку комбобокса ══
	local function makeSoundComboRow(parent, presets, getIdx, setIdx, onCreate, lo)
		local row = Instance.new("Frame")
		row.Name = "SoundComboRow"
		row.Size = UDim2.new(1, 0, 0, 32)
		row.BackgroundTransparency = 1
		row.LayoutOrder = lo
		row.ZIndex = parent.ZIndex + 1
		row.Parent = parent

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1,-120,1,0); lbl.Position = UDim2.fromOffset(16,0)
		lbl.BackgroundTransparency = 1; lbl.Text = "Sound"
		lbl.TextColor3 = Color3.fromRGB(200,200,200)
		lbl.TextSize = 16; lbl.Font = Enum.Font.SourceSans
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.ZIndex = row.ZIndex+1; lbl.Parent = row

		local btn = Instance.new("TextButton")
		btn.AnchorPoint = Vector2.new(1,0.5); btn.Position = UDim2.new(1,-12,0.5,-1)
		btn.Size = UDim2.fromOffset(96,20)
		btn.BackgroundColor3 = Color3.fromRGB(30,30,30)
		btn.BorderSizePixel = 0; btn.AutoButtonColor = false
		btn.TextColor3 = Color3.fromRGB(200,200,200)
		btn.TextSize = 13; btn.Font = Enum.Font.SourceSans
		btn.Text = presets[getIdx()].name .. " ▾"
		btn.ZIndex = row.ZIndex+2; btn.Parent = row
		local bC = Instance.new("UICorner"); bC.CornerRadius = UDim.new(0,3); bC.Parent = btn
		local bS = Instance.new("UIStroke"); bS.Thickness = 1; bS.Color = Color3.fromRGB(55,55,55); bS.Parent = btn

		local dropOpen = false; local dropFrame = nil; local dropOverlay = nil
		local function closeDrop()
			dropOpen = false
			if dropFrame   then pcall(function() dropFrame:Destroy()   end); dropFrame   = nil end
			if dropOverlay then pcall(function() dropOverlay:Destroy() end); dropOverlay = nil end
		end
		local function openDrop()
			if dropOpen then closeDrop(); return end
			dropOpen = true
			local itemH = 22; local dropH = #presets * itemH + 6
			dropOverlay = Instance.new("TextButton")
			dropOverlay.BackgroundTransparency = 1; dropOverlay.BorderSizePixel = 0
			dropOverlay.Size = UDim2.new(1,0,1,0); dropOverlay.Text = ""
			dropOverlay.AutoButtonColor = false; dropOverlay.ZIndex = 198; dropOverlay.Parent = sg
			track(dropOverlay.MouseButton1Click:Connect(closeDrop))
			dropFrame = Instance.new("Frame")
			dropFrame.ZIndex = 199; dropFrame.BorderSizePixel = 0
			dropFrame.Size = UDim2.fromOffset(btn.AbsoluteSize.X + 20, dropH)
			local absP = btn.AbsolutePosition
			dropFrame.Position = UDim2.fromOffset(absP.X - 10, absP.Y + btn.AbsoluteSize.Y + 2)
			local dfOB = Instance.new("Frame"); dfOB.Size = UDim2.new(1,0,1,0)
			dfOB.BackgroundColor3 = Color3.fromRGB(0,0,0); dfOB.BorderSizePixel = 0; dfOB.ZIndex = 199; dfOB.Parent = dropFrame
			local dfOG = Instance.new("Frame"); dfOG.Position = UDim2.fromOffset(1,1); dfOG.Size = UDim2.new(1,-2,1,-2)
			dfOG.BackgroundColor3 = Color3.fromRGB(60,60,60); dfOG.BorderSizePixel = 0; dfOG.ZIndex = 199; dfOG.Parent = dfOB
			local dfIn = Instance.new("Frame"); dfIn.Position = UDim2.fromOffset(1,1); dfIn.Size = UDim2.new(1,-2,1,-2)
			dfIn.BackgroundColor3 = Color3.fromRGB(22,22,22); dfIn.BorderSizePixel = 0; dfIn.ZIndex = 199; dfIn.Parent = dfOG
			dropFrame.BackgroundTransparency = 1; dropFrame.Parent = sg
			for i, preset in ipairs(presets) do
				local isOn = (i == getIdx())
				local item = Instance.new("TextButton")
				item.Size = UDim2.new(1,-6,0,itemH-2); item.Position = UDim2.fromOffset(3, 3+(i-1)*itemH)
				item.BackgroundColor3 = isOn and Color3.fromRGB(60,60,60) or Color3.fromRGB(28,28,28)
				item.BorderSizePixel = 0; item.AutoButtonColor = false
				item.Text = (isOn and "✓  " or "    ") .. preset.name
				item.TextColor3 = isOn and Color3.fromRGB(230,230,230) or Color3.fromRGB(160,160,160)
				item.TextSize = 13; item.Font = Enum.Font.SourceSans
				item.TextXAlignment = Enum.TextXAlignment.Left
				item.ZIndex = 204; item.Parent = dfIn
				local iC = Instance.new("UICorner"); iC.CornerRadius = UDim.new(0,3); iC.Parent = item
				local iP = Instance.new("UIPadding"); iP.PaddingLeft = UDim.new(0,8); iP.Parent = item
				track(item.MouseButton1Click:Connect(function()
					setIdx(i)
					btn.Text = preset.name .. " ▾"
					onCreate()
					closeDrop()
				end))
			end
		end
		track(btn.MouseButton1Click:Connect(openDrop))
		return btn
	end

	-- ══ helper: создать строку Sound ID ══
	local function makeSoundIdRow(parent, getCustomId, setCustomId, getPresets, getIdx, onCreate, lo)
		local row = Instance.new("Frame")
		row.Name = "SoundIdRow"; row.Size = UDim2.new(1, 0, 0, 32)
		row.BackgroundTransparency = 1; row.LayoutOrder = lo
		row.ZIndex = parent.ZIndex + 1; row.Parent = parent

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(0,80,1,0); lbl.Position = UDim2.fromOffset(16,0)
		lbl.BackgroundTransparency = 1; lbl.Text = "Sound ID"
		lbl.TextColor3 = Color3.fromRGB(200,200,200)
		lbl.TextSize = 16; lbl.Font = Enum.Font.SourceSans
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.ZIndex = row.ZIndex+1; lbl.Parent = row

		local box = Instance.new("TextBox")
		box.AnchorPoint = Vector2.new(1,0.5); box.Position = UDim2.new(1,-12,0.5,-1)
		box.Size = UDim2.fromOffset(110,20)
		box.BackgroundColor3 = Color3.fromRGB(22,22,22); box.BorderSizePixel = 0
		box.Text = getCustomId(); box.PlaceholderText = "Asset ID..."
		box.TextColor3 = Color3.fromRGB(210,210,210)
		box.PlaceholderColor3 = Color3.fromRGB(100,100,100)
		box.TextSize = 13; box.Font = Enum.Font.SourceSans
		box.ClearTextOnFocus = false; box.TextEditable = true
		box.ZIndex = row.ZIndex+2; box.Parent = row
		local bC = Instance.new("UICorner"); bC.CornerRadius = UDim.new(0,4); bC.Parent = box
		local bS = Instance.new("UIStroke"); bS.Thickness = 1; bS.Color = Color3.fromRGB(55,55,55); bS.Parent = box
		local bP = Instance.new("UIPadding"); bP.PaddingLeft = UDim.new(0,6); bP.PaddingRight = UDim.new(0,6); bP.Parent = box

		local function refreshState()
			local isCustom = getPresets()[getIdx()].name == "custom"
			box.TextEditable = isCustom
			box.TextColor3 = isCustom and Color3.fromRGB(210,210,210) or Color3.fromRGB(90,90,90)
			bS.Color = isCustom and Color3.fromRGB(55,55,55) or Color3.fromRGB(35,35,35)
		end
		refreshState()

		track(box:GetPropertyChangedSignal("Text"):Connect(function()
			if getPresets()[getIdx()].name ~= "custom" then return end
			local raw = box.Text:match("%d+")
			if raw and raw ~= getCustomId() then
				setCustomId(raw)
				onCreate()
			end
		end))

		return refreshState
	end

	-- ══ helper: создать слайдер громкости ══
	local function makeVolSlider(parent, getVol, setVol, getSound, lo)
		local cont = Instance.new("Frame")
		cont.Size = UDim2.new(1, 0, 0, 38)
		cont.BackgroundTransparency = 1
		cont.LayoutOrder = lo
		cont.ZIndex = parent.ZIndex + 1
		cont.Parent = parent

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1,-16,0,16); lbl.Position = UDim2.fromOffset(16,2)
		lbl.BackgroundTransparency = 1; lbl.Text = "Volume: " .. tostring(getVol())
		lbl.TextColor3 = Color3.fromRGB(200,200,200)
		lbl.TextSize = 15; lbl.Font = Enum.Font.SourceSans
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.ZIndex = cont.ZIndex+1; lbl.Parent = cont

		local trackHit = Instance.new("TextButton")
		trackHit.Size = UDim2.new(1,-28,0,20); trackHit.Position = UDim2.fromOffset(16,15)
		trackHit.BackgroundTransparency = 1; trackHit.BorderSizePixel = 0
		trackHit.Text = ""; trackHit.AutoButtonColor = false
		trackHit.ZIndex = cont.ZIndex+6; trackHit.Parent = cont

		local trackBg = Instance.new("Frame")
		trackBg.Size = UDim2.new(1,-28,0,6); trackBg.Position = UDim2.fromOffset(16,22)
		trackBg.BackgroundColor3 = Color3.fromRGB(35,35,35); trackBg.BorderSizePixel = 0
		trackBg.ZIndex = cont.ZIndex+1; trackBg.Parent = cont
		local tbC = Instance.new("UICorner"); tbC.CornerRadius = UDim.new(1,0); tbC.Parent = trackBg
		local tbS = Instance.new("UIStroke"); tbS.Thickness = 1; tbS.Color = Color3.fromRGB(50,50,50); tbS.Parent = trackBg

		local fill = Instance.new("Frame")
		fill.BackgroundColor3 = Color3.fromRGB(80,80,80); fill.BorderSizePixel = 0
		fill.ZIndex = cont.ZIndex+2; fill.Parent = trackBg
		local fC = Instance.new("UICorner"); fC.CornerRadius = UDim.new(1,0); fC.Parent = fill

		local knob = Instance.new("Frame")
		knob.Size = UDim2.fromOffset(14,14); knob.AnchorPoint = Vector2.new(0.5,0.5)
		knob.BackgroundColor3 = Color3.fromRGB(200,200,200); knob.BorderSizePixel = 0
		knob.ZIndex = cont.ZIndex+5; knob.Parent = trackBg
		local kC = Instance.new("UICorner"); kC.CornerRadius = UDim.new(1,0); kC.Parent = knob

		local function updateVis()
			local pct = getVol() / 200
			fill.Size = UDim2.new(pct,0,1,0); knob.Position = UDim2.new(pct,0,0.5,0)
			lbl.Text = "Volume: " .. tostring(getVol())
			local s = getSound()
			if s then pcall(function() s.Volume = getVol() / 100 end) end
		end
		updateVis()

		local dragging = false
		local function applyX(absX)
			local x0 = trackHit.AbsolutePosition.X; local w = trackHit.AbsoluteSize.X
			if w <= 0 then return end
			setVol(math.clamp(math.floor(math.clamp((absX-x0)/w,0,1)*200+0.5),0,200))
			updateVis()
		end
		track(trackHit.MouseButton1Down:Connect(function() dragging=true; applyX(getMouseUiPos().X) end))
		track(UserInputService.InputEnded:Connect(function(inp)
			if inp.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end
		end))
		track(UserInputService.InputChanged:Connect(function(inp)
			if inp.UserInputType==Enum.UserInputType.MouseWheel then return end
			if dragging and inp.UserInputType==Enum.UserInputType.MouseMovement then applyX(getMouseUiPos().X) end
		end))
		track(trackHit.MouseWheelForward:Connect(function()
			miscContent.CanvasPosition=Vector2.new(miscContent.CanvasPosition.X,math.max(0,miscContent.CanvasPosition.Y-40))
		end))
		track(trackHit.MouseWheelBackward:Connect(function()
			miscContent.CanvasPosition=Vector2.new(miscContent.CanvasPosition.X,miscContent.CanvasPosition.Y+40)
		end))
	end

	-- ══ helper: нижняя линия секции ══
	local function addSectionEndLine(parent, lo)
		local div = Instance.new("Frame")
		div.Size = UDim2.new(1,0,0,16); div.BackgroundTransparency=1
		div.LayoutOrder = lo; div.ZIndex = parent.ZIndex+1; div.Parent = parent
		local line = Instance.new("Frame")
		line.Size = UDim2.new(1,-24,0,1); line.Position = UDim2.fromOffset(12,15)
		line.BackgroundColor3 = Color3.fromRGB(55,55,55); line.BorderSizePixel=0
		line.ZIndex = div.ZIndex+1; line.Parent = div
	end

	-- ══════════════════════════════════════════════
	-- HITSOUND секция (LayoutOrder 10-19)
	-- ══════════════════════════════════════════════
	do
		local div = addSectionDivider(miscContent, "HITSOUND")
		div.LayoutOrder = 10

		local tog = addToggle(miscContent, "Hitsound", false, function(v) hsEnabled = v end)
		tog.LayoutOrder = 11

		local hsComboBtn = makeSoundComboRow(
			miscContent,
			hsPresets,
			function() return hsPresetIdx end,
			function(i) hsPresetIdx = i end,
			createHsSound,
			12
		)

		local refreshHsId = makeSoundIdRow(
			miscContent,
			function() return hsCustomId end,
			function(v) hsCustomId = v end,
			function() return hsPresets end,
			function() return hsPresetIdx end,
			createHsSound,
			13
		)

		makeVolSlider(
			miscContent,
			function() return hsVolume end,
			function(v) hsVolume = v end,
			function() return hsSound end,
			14
		)

		addSectionEndLine(miscContent, 15)
	end

	-- ══════════════════════════════════════════════
	-- THIRD PERSON секция (LayoutOrder 30-39)
	-- ══════════════════════════════════════════════
	tpEnabled  = false
	tpDistance = 12
	do
		local Camera3 = workspace.CurrentCamera
		local tpConn  = nil

		local function applyThirdPerson()
			if not tpEnabled then
				if tpConn then tpConn:Disconnect(); tpConn = nil end
				-- вернуть стандартное расстояние камеры
				local playerModule = require(Players.LocalPlayer.PlayerScripts:WaitForChild("PlayerModule"))
				pcall(function()
					local controls = playerModule:GetControls()
				end)
				-- просто сбрасываем через CameraMode
				pcall(function()
					Players.LocalPlayer.CameraMode = Enum.CameraMode.Classic
				end)
				return
			end
			if tpConn then tpConn:Disconnect(); tpConn = nil end
			tpConn = RunService.RenderStepped:Connect(function()
				if not tpEnabled then return end
				local char = Players.LocalPlayer.Character
				if not char then return end
				local hrp = char:FindFirstChild("HumanoidRootPart")
				if not hrp then return end
				local cf = Camera3.CFrame
				local dir = (cf.Position - hrp.Position)
				if dir.Magnitude < 0.01 then return end
				local newPos = hrp.Position + dir.Unit * tpDistance
				Camera3.CFrame = CFrame.new(newPos, hrp.Position + Vector3.new(0, 1.5, 0))
			end)
		end

		local div3 = addSectionDivider(miscContent, "THIRD PERSON")
		div3.LayoutOrder = 30

		local tpToggle = addToggle(miscContent, "Third Person Distance", false, function(v)
			tpEnabled = v
			applyThirdPerson()
		end)
		tpToggle.LayoutOrder = 31

		-- Слайдер дальности (большой, от 4 до 60)
		local tpSliderCont = Instance.new("Frame")
		tpSliderCont.Size = UDim2.new(1, 0, 0, 48)
		tpSliderCont.BackgroundTransparency = 1
		tpSliderCont.LayoutOrder = 32
		tpSliderCont.ZIndex = miscContent.ZIndex + 1
		tpSliderCont.Parent = miscContent

		local tpLbl = Instance.new("TextLabel")
		tpLbl.Size = UDim2.new(1, -16, 0, 16); tpLbl.Position = UDim2.fromOffset(16, 2)
		tpLbl.BackgroundTransparency = 1; tpLbl.Text = "Distance: " .. tostring(tpDistance)
		tpLbl.TextColor3 = Color3.fromRGB(200, 200, 200)
		tpLbl.TextSize = 15; tpLbl.Font = Enum.Font.SourceSans
		tpLbl.TextXAlignment = Enum.TextXAlignment.Left
		tpLbl.ZIndex = tpSliderCont.ZIndex + 1; tpLbl.Parent = tpSliderCont

		local tpTrackHit = Instance.new("TextButton")
		tpTrackHit.Size = UDim2.new(1, -28, 0, 28); tpTrackHit.Position = UDim2.fromOffset(16, 16)
		tpTrackHit.BackgroundTransparency = 1; tpTrackHit.BorderSizePixel = 0
		tpTrackHit.Text = ""; tpTrackHit.AutoButtonColor = false
		tpTrackHit.ZIndex = tpSliderCont.ZIndex + 6; tpTrackHit.Parent = tpSliderCont

		local tpTrackBg = Instance.new("Frame")
		tpTrackBg.Size = UDim2.new(1, -28, 0, 10); tpTrackBg.Position = UDim2.fromOffset(16, 28)
		tpTrackBg.BackgroundColor3 = Color3.fromRGB(35, 35, 35); tpTrackBg.BorderSizePixel = 0
		tpTrackBg.ZIndex = tpSliderCont.ZIndex + 1; tpTrackBg.Parent = tpSliderCont
		local tpTbC = Instance.new("UICorner"); tpTbC.CornerRadius = UDim.new(1, 0); tpTbC.Parent = tpTrackBg
		local tpTbS = Instance.new("UIStroke"); tpTbS.Thickness = 1; tpTbS.Color = Color3.fromRGB(50, 50, 50); tpTbS.Parent = tpTrackBg

		local tpFill = Instance.new("Frame")
		tpFill.BackgroundColor3 = Color3.fromRGB(80, 80, 80); tpFill.BorderSizePixel = 0
		tpFill.ZIndex = tpSliderCont.ZIndex + 2; tpFill.Parent = tpTrackBg
		local tpFillC = Instance.new("UICorner"); tpFillC.CornerRadius = UDim.new(1, 0); tpFillC.Parent = tpFill

		local tpKnob = Instance.new("Frame")
		tpKnob.Size = UDim2.fromOffset(20, 20); tpKnob.AnchorPoint = Vector2.new(0.5, 0.5)
		tpKnob.BackgroundColor3 = Color3.fromRGB(200, 200, 200); tpKnob.BorderSizePixel = 0
		tpKnob.ZIndex = tpSliderCont.ZIndex + 5; tpKnob.Parent = tpTrackBg
		local tpKC = Instance.new("UICorner"); tpKC.CornerRadius = UDim.new(1, 0); tpKC.Parent = tpKnob

		local tpMinV, tpMaxV = 4, 60
		local function tpUpdateVis()
			local pct = (tpDistance - tpMinV) / (tpMaxV - tpMinV)
			tpFill.Size = UDim2.new(pct, 0, 1, 0)
			tpKnob.Position = UDim2.new(pct, 0, 0.5, 0)
			tpLbl.Text = "Distance: " .. tostring(tpDistance)
		end
		tpUpdateVis()

		local tpDragging = false
		local function tpApplyX(absX)
			local x0 = tpTrackHit.AbsolutePosition.X; local w = tpTrackHit.AbsoluteSize.X
			if w <= 0 then return end
			local pct = math.clamp((absX - x0) / w, 0, 1)
			tpDistance = math.floor(tpMinV + (tpMaxV - tpMinV) * pct + 0.5)
			tpUpdateVis()
		end
		track(tpTrackHit.MouseButton1Down:Connect(function() tpDragging = true; tpApplyX(getMouseUiPos().X) end))
		track(UserInputService.InputEnded:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseButton1 then tpDragging = false end
		end))
		track(UserInputService.InputChanged:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseWheel then return end
			if tpDragging and inp.UserInputType == Enum.UserInputType.MouseMovement then tpApplyX(getMouseUiPos().X) end
		end))
		track(tpTrackHit.MouseWheelForward:Connect(function()
			miscContent.CanvasPosition = Vector2.new(miscContent.CanvasPosition.X, math.max(0, miscContent.CanvasPosition.Y - 40))
		end))
		track(tpTrackHit.MouseWheelBackward:Connect(function()
			miscContent.CanvasPosition = Vector2.new(miscContent.CanvasPosition.X, miscContent.CanvasPosition.Y + 40)
		end))

		addSectionEndLine(miscContent, 35)
	end

	-- ══════════════════════════════════════════════
	-- FIELD OF VIEW секция (LayoutOrder 40-49)
	-- ══════════════════════════════════════════════
	fovEnabled = false
	camFov     = 70
	do
		local function applyFov()
			local cam = workspace.CurrentCamera
			if not cam then return end
			if fovEnabled then
				cam.FieldOfView = camFov
			else
				cam.FieldOfView = 70
			end
		end

		-- Используем RenderStepped с приоритетом Camera — выполняется ПОСЛЕ
		-- того как игра обновила камеру, но ДО рендера. Это предотвращает
		-- дёргание, которое возникает когда игра перезаписывает FieldOfView.
		-- BindToRenderStep не возвращает коннекшн — отписка в unload() через UnbindFromRenderStep
		RunService:BindToRenderStep("FovChanger", Enum.RenderPriority.Camera.Value + 1, function()
			if fovEnabled then
				local cam = workspace.CurrentCamera
				if cam and cam.FieldOfView ~= camFov then
					cam.FieldOfView = camFov
				end
			end
		end)

		local div4 = addSectionDivider(miscContent, "FIELD OF VIEW")
		div4.LayoutOrder = 40

		local fovToggle = addToggle(miscContent, "Field Of View", false, function(v)
			fovEnabled = v
			applyFov()
		end)
		fovToggle.LayoutOrder = 41

		-- Слайдер FOV (большой, от 30 до 120)
		local fovSliderCont = Instance.new("Frame")
		fovSliderCont.Size = UDim2.new(1, 0, 0, 48)
		fovSliderCont.BackgroundTransparency = 1
		fovSliderCont.LayoutOrder = 42
		fovSliderCont.ZIndex = miscContent.ZIndex + 1
		fovSliderCont.Parent = miscContent

		local fovLbl = Instance.new("TextLabel")
		fovLbl.Size = UDim2.new(1, -16, 0, 16); fovLbl.Position = UDim2.fromOffset(16, 2)
		fovLbl.BackgroundTransparency = 1; fovLbl.Text = "FOV: " .. tostring(camFov)
		fovLbl.TextColor3 = Color3.fromRGB(200, 200, 200)
		fovLbl.TextSize = 15; fovLbl.Font = Enum.Font.SourceSans
		fovLbl.TextXAlignment = Enum.TextXAlignment.Left
		fovLbl.ZIndex = fovSliderCont.ZIndex + 1; fovLbl.Parent = fovSliderCont

		local fovTrackHit = Instance.new("TextButton")
		fovTrackHit.Size = UDim2.new(1, -28, 0, 28); fovTrackHit.Position = UDim2.fromOffset(16, 16)
		fovTrackHit.BackgroundTransparency = 1; fovTrackHit.BorderSizePixel = 0
		fovTrackHit.Text = ""; fovTrackHit.AutoButtonColor = false
		fovTrackHit.ZIndex = fovSliderCont.ZIndex + 6; fovTrackHit.Parent = fovSliderCont

		local fovTrackBg = Instance.new("Frame")
		fovTrackBg.Size = UDim2.new(1, -28, 0, 10); fovTrackBg.Position = UDim2.fromOffset(16, 28)
		fovTrackBg.BackgroundColor3 = Color3.fromRGB(35, 35, 35); fovTrackBg.BorderSizePixel = 0
		fovTrackBg.ZIndex = fovSliderCont.ZIndex + 1; fovTrackBg.Parent = fovSliderCont
		local fovTbC = Instance.new("UICorner"); fovTbC.CornerRadius = UDim.new(1, 0); fovTbC.Parent = fovTrackBg
		local fovTbS = Instance.new("UIStroke"); fovTbS.Thickness = 1; fovTbS.Color = Color3.fromRGB(50, 50, 50); fovTbS.Parent = fovTrackBg

		local fovFill = Instance.new("Frame")
		fovFill.BackgroundColor3 = Color3.fromRGB(80, 80, 80); fovFill.BorderSizePixel = 0
		fovFill.ZIndex = fovSliderCont.ZIndex + 2; fovFill.Parent = fovTrackBg
		local fovFillC = Instance.new("UICorner"); fovFillC.CornerRadius = UDim.new(1, 0); fovFillC.Parent = fovFill

		local fovKnob = Instance.new("Frame")
		fovKnob.Size = UDim2.fromOffset(20, 20); fovKnob.AnchorPoint = Vector2.new(0.5, 0.5)
		fovKnob.BackgroundColor3 = Color3.fromRGB(200, 200, 200); fovKnob.BorderSizePixel = 0
		fovKnob.ZIndex = fovSliderCont.ZIndex + 5; fovKnob.Parent = fovTrackBg
		local fovKC = Instance.new("UICorner"); fovKC.CornerRadius = UDim.new(1, 0); fovKC.Parent = fovKnob

		local fovMinV, fovMaxV = 30, 120
		local function fovUpdateVis()
			local pct = (camFov - fovMinV) / (fovMaxV - fovMinV)
			fovFill.Size = UDim2.new(pct, 0, 1, 0)
			fovKnob.Position = UDim2.new(pct, 0, 0.5, 0)
			fovLbl.Text = "FOV: " .. tostring(camFov)
			-- fov обновляется через Heartbeat автоматически
		end
		fovUpdateVis()

		local fovDragging = false
		local function fovApplyX(absX)
			local x0 = fovTrackHit.AbsolutePosition.X; local w = fovTrackHit.AbsoluteSize.X
			if w <= 0 then return end
			local pct = math.clamp((absX - x0) / w, 0, 1)
			camFov = math.floor(fovMinV + (fovMaxV - fovMinV) * pct + 0.5)
			fovUpdateVis()
		end
		track(fovTrackHit.MouseButton1Down:Connect(function() fovDragging = true; fovApplyX(getMouseUiPos().X) end))
		track(UserInputService.InputEnded:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseButton1 then fovDragging = false end
		end))
		track(UserInputService.InputChanged:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseWheel then return end
			if fovDragging and inp.UserInputType == Enum.UserInputType.MouseMovement then fovApplyX(getMouseUiPos().X) end
		end))
		track(fovTrackHit.MouseWheelForward:Connect(function()
			miscContent.CanvasPosition = Vector2.new(miscContent.CanvasPosition.X, math.max(0, miscContent.CanvasPosition.Y - 40))
		end))
		track(fovTrackHit.MouseWheelBackward:Connect(function()
			miscContent.CanvasPosition = Vector2.new(miscContent.CanvasPosition.X, miscContent.CanvasPosition.Y + 40)
		end))

		addSectionEndLine(miscContent, 45)
	end

	-- ── exploits page ──
	local exploitsContent = Instance.new("ScrollingFrame")
	exploitsContent.BackgroundTransparency = 1; exploitsContent.Position = UDim2.fromOffset(0,15)
	exploitsContent.Size = UDim2.new(1,0,1,-15); exploitsContent.Parent = pages["exploits"]
	exploitsContent.ScrollBarThickness = 3
	exploitsContent.ScrollBarImageColor3 = Color3.fromRGB(80,80,80)
	exploitsContent.BorderSizePixel = 0
	exploitsContent.AutomaticCanvasSize = Enum.AutomaticSize.Y
	exploitsContent.CanvasSize = UDim2.new(0,0,0,0)
	exploitsContent.ClipsDescendants = true
	exploitsContent.ScrollingEnabled = true
	exploitsContent.ElasticBehavior = Enum.ElasticBehavior.Never
	local el2 = Instance.new("UIListLayout"); el2.Padding = UDim.new(0,0); el2.SortOrder = Enum.SortOrder.LayoutOrder; el2.Parent = exploitsContent

	-- ── Sprint State ───────────────────────────────────────────────────────────
	local sprintEnabled = false
	local _sprintShiftConn = nil

	local WASD_KEYS = {
		[Enum.KeyCode.W] = true,
		[Enum.KeyCode.A] = true,
		[Enum.KeyCode.S] = true,
		[Enum.KeyCode.D] = true,
	}

	local function isMoving()
		for key in pairs(WASD_KEYS) do
			if UserInputService:IsKeyDown(key) then return true end
		end
		return false
	end

	local _sprintVim = nil
	pcall(function() _sprintVim = game:GetService("VirtualInputManager") end)

	local _shiftHeld = false

	local function setShift(hold)
		if hold == _shiftHeld then return end
		_shiftHeld = hold
		if _sprintVim and _sprintVim.SendKeyEvent then
			pcall(function()
				_sprintVim:SendKeyEvent(hold, Enum.KeyCode.LeftShift, false, game)
			end)
		end
	end

	local function startSprint()
		if _sprintShiftConn then return end
		_sprintShiftConn = RunService.Heartbeat:Connect(function()
			if not sprintEnabled then return end
			local moving = isMoving()
			setShift(moving)
		end)
		table.insert(conns, _sprintShiftConn)
	end

	local function stopSprint()
		setShift(false)
		if _sprintShiftConn then
			pcall(function() _sprintShiftConn:Disconnect() end)
			_sprintShiftConn = nil
		end
	end
	_globalStopSprint = stopSprint

	-- ── Sprint UI ──────────────────────────────────────────────────────────────

	-- Header
	local sprintTitleRow = Instance.new("Frame")
	sprintTitleRow.Size = UDim2.new(1,-20,0,22); sprintTitleRow.BackgroundTransparency=1
	sprintTitleRow.LayoutOrder=1; sprintTitleRow.ZIndex=exploitsContent.ZIndex+1; sprintTitleRow.Parent=exploitsContent
	local sprintTitleLbl = Instance.new("TextLabel")
	sprintTitleLbl.Size=UDim2.new(1,0,1,0); sprintTitleLbl.Position=UDim2.fromOffset(16,0)
	sprintTitleLbl.BackgroundTransparency=1; sprintTitleLbl.Text="SPRINT"
	sprintTitleLbl.TextColor3=Color3.fromRGB(130,130,130)
	sprintTitleLbl.TextSize=12; sprintTitleLbl.Font=Enum.Font.GothamBold
	sprintTitleLbl.TextXAlignment=Enum.TextXAlignment.Left
	sprintTitleLbl.ZIndex=sprintTitleRow.ZIndex+1; sprintTitleLbl.Parent=sprintTitleRow

	local sprintToggle = addToggle(exploitsContent, "Auto Sprint", false, function(v)
		sprintEnabled = v
		if v then startSprint() else stopSprint() end
	end)
	sprintToggle.LayoutOrder = 2

	-- divider before YAW
	local sprintDiv = Instance.new("Frame")
	sprintDiv.Size=UDim2.new(1,-20,0,10); sprintDiv.BackgroundTransparency=1
	sprintDiv.LayoutOrder=3; sprintDiv.ZIndex=exploitsContent.ZIndex+1; sprintDiv.Parent=exploitsContent
	local sprintDivLine = Instance.new("Frame")
	sprintDivLine.Size=UDim2.new(1,-24,0,1); sprintDivLine.Position=UDim2.fromOffset(12,5)
	sprintDivLine.BackgroundColor3=Color3.fromRGB(55,55,55); sprintDivLine.BorderSizePixel=0
	sprintDivLine.ZIndex=sprintDiv.ZIndex+1; sprintDivLine.Parent=sprintDiv

	-- ── Yaw Rotator State ──────────────────────────────────────────────────
	local YAW = {
		enabled        = false,
		atTargets      = false,
		activeProfile  = "Standing",
		profiles = {
			Standing = { pitch="Back", pitchCustom=180, mode="Jitter", jitter=false, jitterSpeed=10, spinSpeed=5 },
			Moving   = { pitch="Back", pitchCustom=180, mode="Jitter", jitter=false, jitterSpeed=10, spinSpeed=5 },
			Jumping  = { pitch="Back", pitchCustom=180, mode="Jitter", jitter=false, jitterSpeed=10, spinSpeed=5 },
		},
		-- Manual
		manualEnabled  = false,
		manualActive   = false,
		manualLeftKey  = Enum.KeyCode.Z,
		manualRightKey = Enum.KeyCode.C,
		manualMode     = "toggle",  -- "toggle"|"hold"|"always"
	}

	local _yrConn      = nil
	local _jitterSign  = 1
	local _spinAngle   = 0
	local _lastJitter  = 0

	local function yrGetProfile(name)
		local p = YAW.profiles[name]
		if type(p) ~= "table" then
			YAW.profiles[name] = { pitch="Back", pitchCustom=180, mode="Jitter", jitter=false, jitterSpeed=10, spinSpeed=5 }
			p = YAW.profiles[name]
		end
		return p
	end
	local function yrActiveProfile()
		return yrGetProfile(YAW.activeProfile or "Standing")
	end

	local function yrGetPitchAngle(prof)
		local p = prof.pitch
		if p == "Forward" then return math.rad(0)   end
		if p == "Back"    then return math.rad(180) end
		if p == "Right"   then return math.rad(-90) end
		if p == "Left"    then return math.rad(90)  end
		return math.rad(prof.pitchCustom or 180)
	end

	local function yrApplyHRP(hrp, yawAngle)
		local pos     = hrp.Position
		local lookDir = Vector3.new(math.sin(yawAngle), 0, math.cos(yawAngle))
		hrp.CFrame    = CFrame.new(pos) * CFrame.lookAt(Vector3.zero, lookDir)
	end

	local function yrGetPlayerState(hum)
		if not hum then return "Standing" end
		local st = hum:GetState()
		if st == Enum.HumanoidStateType.Jumping
		or st == Enum.HumanoidStateType.Freefall
		or st == Enum.HumanoidStateType.Flying then return "Jumping" end
		if hum.MoveDirection.Magnitude > 0.1 then return "Moving" end
		return "Standing"
	end

	local YAW_RENDER_NAME = "_AntiLoseYawRotator"
	local YAW_PRIORITY    = Enum.RenderPriority.Last.Value

	local _yrClimbRP = RaycastParams.new()
	_yrClimbRP.FilterType = Enum.RaycastFilterType.Exclude
	local PROBE_DIRS = {
		Vector3.new(1,0,0), Vector3.new(-1,0,0),
		Vector3.new(0,0,1), Vector3.new(0,0,-1),
		Vector3.new(0,1,0), Vector3.new(0,-1,0),
	}
	local function yrIsClimbing(hrp, hum, char)
		if hum:GetState() == Enum.HumanoidStateType.Climbing then return true end
		_yrClimbRP.FilterDescendantsInstances = { char }
		for _, dir in ipairs(PROBE_DIRS) do
			local hit = workspace:Raycast(hrp.Position, dir * 2.8, _yrClimbRP)
			if hit and hit.Instance and hit.Instance:IsA("TrussPart") then return true end
		end
		return false
	end

	local function startYawRotator()
		if _yrConn then return end
		_yrConn = true
		RunService:BindToRenderStep(YAW_RENDER_NAME, YAW_PRIORITY, function(dt)
			if not YAW.enabled then return end
			local char = localPlayer.Character
			local hrp  = char and char:FindFirstChild("HumanoidRootPart")
			local hum  = char and char:FindFirstChildOfClass("Humanoid")
			if not hrp or not hum then return end
			if yrIsClimbing(hrp, hum, char) then
				if not hum.AutoRotate then hum.AutoRotate = true end
				return
			end
			if hum.AutoRotate then hum.AutoRotate = false end

			local pStateName = yrGetPlayerState(hum)
			local prof       = yrGetProfile(pStateName)
			local baseAngle  = yrGetPitchAngle(prof)
			local mode       = prof.mode or "Jitter"

			if mode == "Spin" then
				_spinAngle = _spinAngle + dt * math.rad((prof.spinSpeed or 5) * 60)
				yrApplyHRP(hrp, _spinAngle)
				return
			end

			local lv     = Camera.CFrame.LookVector
			local camYaw = math.atan2(lv.X, lv.Z)

			if mode == "Jitter" and prof.jitter then
				local rate = 1 / math.max(prof.jitterSpeed or 10, 1)
				local now  = tick()
				if now - _lastJitter >= rate then
					_jitterSign = -_jitterSign
					_lastJitter = now
				end
				yrApplyHRP(hrp, camYaw + baseAngle + math.rad(20) * _jitterSign)
			else
				yrApplyHRP(hrp, camYaw + baseAngle)
			end
		end)
	end

	local function stopYawRotator()
		if _yrConn then
			pcall(function() RunService:UnbindFromRenderStep(YAW_RENDER_NAME) end)
			_yrConn = nil
		end
		local char = localPlayer.Character
		local hum  = char and char:FindFirstChildOfClass("Humanoid")
		if hum then hum.AutoRotate = true end
		_spinAngle = 0
	end

	-- watch enable/disable
	local _prevYawEnabled = false
	track(RunService.Heartbeat:Connect(function()
		if YAW.enabled ~= _prevYawEnabled then
			_prevYawEnabled = YAW.enabled
			if YAW.enabled then startYawRotator() else stopYawRotator() end
		end
	end))

	track(Players.LocalPlayer.CharacterAdded:Connect(function()
		_spinAngle = 0; _jitterSign = 1
		if YAW.enabled then
			task.wait(0.1)
			stopYawRotator()
			startYawRotator()
		end
	end))

	-- ── Manual key handling ────────────────────────────────────────────────
	local function yrShiftAllProfiles(delta)
		-- delta > 0 = Right, delta < 0 = Left
		local target = delta > 0 and "Right" or "Left"
		for _, name in ipairs({"Standing","Moving","Jumping"}) do
			local prof = YAW.profiles[name]
			if prof and prof.pitch ~= "Custom" then
				prof.pitch = (prof.pitch == target) and "Back" or target
			end
		end
	end

	track(UserInputService.InputBegan:Connect(function(input, gp)
		if gp then return end
		if not YAW.manualEnabled then return end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		if input.KeyCode == YAW.manualLeftKey then
			yrShiftAllProfiles(-1)   -- Left key → pitch Left
		elseif input.KeyCode == YAW.manualRightKey then
			yrShiftAllProfiles(1)    -- Right key → pitch Right
		end
	end))

	-- ── addExploitSlider helper ────────────────────────────────────────────
	local function addExploitSlider(parent, labelText, getVal, setVal, minV, maxV, inc, lo)
		local rowH = 38
		local container = Instance.new("Frame")
		container.Size = UDim2.new(1, -20, 0, rowH)
		container.BackgroundTransparency = 1
		container.ZIndex = parent.ZIndex + 1
		container.LayoutOrder = lo or 0
		container.Parent = parent

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1,-16,0,16); lbl.Position = UDim2.fromOffset(16,2)
		lbl.BackgroundTransparency = 1
		lbl.TextColor3 = Color3.fromRGB(200,200,200)
		lbl.TextSize = 15; lbl.Font = Enum.Font.SourceSans
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.ZIndex = container.ZIndex+1; lbl.Parent = container

		local function fmtVal(v)
			if inc and inc < 1 then return string.format("%.2f", v) end
			return tostring(math.floor(v))
		end
		lbl.Text = labelText .. ": " .. fmtVal(getVal())

		local trackHit = Instance.new("TextButton")
		trackHit.Size = UDim2.new(1,-28,0,20); trackHit.Position = UDim2.fromOffset(16,15)
		trackHit.BackgroundTransparency = 1; trackHit.BorderSizePixel = 0
		trackHit.Text = ""; trackHit.AutoButtonColor = false
		trackHit.ZIndex = container.ZIndex+6; trackHit.Parent = container

		local trackBg = Instance.new("Frame")
		trackBg.Size = UDim2.new(1,-28,0,6); trackBg.Position = UDim2.fromOffset(16,22)
		trackBg.BackgroundColor3 = Color3.fromRGB(35,35,35); trackBg.BorderSizePixel = 0
		trackBg.ZIndex = container.ZIndex+1; trackBg.Parent = container
		local tbC = Instance.new("UICorner"); tbC.CornerRadius = UDim.new(1,0); tbC.Parent = trackBg
		local tbS = Instance.new("UIStroke"); tbS.Thickness = 1; tbS.Color = Color3.fromRGB(50,50,50); tbS.Parent = trackBg

		local fill = Instance.new("Frame")
		fill.BackgroundColor3 = Color3.fromRGB(80,80,80); fill.BorderSizePixel = 0
		fill.ZIndex = container.ZIndex+2; fill.Parent = trackBg
		local fC = Instance.new("UICorner"); fC.CornerRadius = UDim.new(1,0); fC.Parent = fill

		local knob = Instance.new("Frame")
		knob.Size = UDim2.fromOffset(14,14); knob.AnchorPoint = Vector2.new(0.5,0.5)
		knob.BackgroundColor3 = Color3.fromRGB(200,200,200); knob.BorderSizePixel = 0
		knob.ZIndex = container.ZIndex+5; knob.Parent = trackBg
		local kC = Instance.new("UICorner"); kC.CornerRadius = UDim.new(1,0); kC.Parent = knob

		local sepLine = Instance.new("Frame")
		sepLine.Size = UDim2.new(1,-24,0,1); sepLine.Position = UDim2.new(0,12,1,-1)
		sepLine.BackgroundColor3 = Color3.fromRGB(45,45,45); sepLine.BorderSizePixel = 0
		sepLine.ZIndex = container.ZIndex+1; sepLine.Parent = container

		local function updateVis()
			local v = getVal()
			local pct = math.clamp((v - minV) / (maxV - minV), 0, 1)
			fill.Size = UDim2.new(pct,0,1,0); knob.Position = UDim2.new(pct,0,0.5,0)
			lbl.Text = labelText .. ": " .. fmtVal(v)
		end
		updateVis()

		local dragging = false
		local function applyX(absX)
			local x0 = trackHit.AbsolutePosition.X; local w = trackHit.AbsoluteSize.X
			if w <= 0 then return end
			local pct = math.clamp((absX - x0) / w, 0, 1)
			local raw = minV + (maxV - minV) * pct
			if inc then raw = math.floor(raw / inc + 0.5) * inc end
			setVal(math.clamp(raw, minV, maxV))
			updateVis()
		end

		track(trackHit.MouseButton1Down:Connect(function() dragging=true; applyX(getMouseUiPos().X) end))
		track(UserInputService.InputEnded:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseButton1 then dragging=false end
		end))
		track(UserInputService.InputChanged:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseWheel then return end
			if dragging and inp.UserInputType == Enum.UserInputType.MouseMovement then applyX(getMouseUiPos().X) end
		end))
		track(trackHit.MouseWheelForward:Connect(function()
			exploitsContent.CanvasPosition = Vector2.new(exploitsContent.CanvasPosition.X, math.max(0, exploitsContent.CanvasPosition.Y-40))
		end))
		track(trackHit.MouseWheelBackward:Connect(function()
			exploitsContent.CanvasPosition = Vector2.new(exploitsContent.CanvasPosition.X, exploitsContent.CanvasPosition.Y+40)
		end))

		return container, updateVis
	end

	-- ── addExploitDropdown helper ──────────────────────────────────────────
	local function addExploitDropdown(parent, labelText, options, getVal, setVal, lo)
		local container = Instance.new("Frame")
		container.Name = labelText .. "Drop"
		container.Size = UDim2.new(1,-20,0,32)
		container.BackgroundTransparency = 1
		container.ZIndex = parent.ZIndex+1
		container.LayoutOrder = lo or 0
		container.Parent = parent

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1,-120,1,0); lbl.Position = UDim2.fromOffset(16,0)
		lbl.BackgroundTransparency = 1; lbl.Text = labelText
		lbl.TextColor3 = Color3.fromRGB(200,200,200)
		lbl.TextSize = 16; lbl.Font = Enum.Font.SourceSans
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.ZIndex = container.ZIndex+1; lbl.Parent = container

		local btn = Instance.new("TextButton")
		btn.AnchorPoint = Vector2.new(1,0.5); btn.Position = UDim2.new(1,-12,0.5,-1)
		btn.Size = UDim2.fromOffset(96,20)
		btn.BackgroundColor3 = Color3.fromRGB(28,28,28)
		btn.BorderSizePixel = 0; btn.AutoButtonColor = false
		btn.TextColor3 = Color3.fromRGB(200,200,200)
		btn.TextSize = 13; btn.Font = Enum.Font.SourceSans
		btn.Text = tostring(getVal()) .. " ▾"
		btn.ZIndex = container.ZIndex+2; btn.Parent = container
		local bC = Instance.new("UICorner"); bC.CornerRadius = UDim.new(0,3); bC.Parent = btn
		local bS = Instance.new("UIStroke"); bS.Thickness = 1; bS.Color = Color3.fromRGB(55,55,55); bS.Parent = btn

		local sepLine = Instance.new("Frame")
		sepLine.Size = UDim2.new(1,-24,0,1); sepLine.Position = UDim2.new(0,12,1,-1)
		sepLine.BackgroundColor3 = Color3.fromRGB(45,45,45); sepLine.BorderSizePixel = 0
		sepLine.ZIndex = container.ZIndex+1; sepLine.Parent = container

		local function refreshBtn() btn.Text = tostring(getVal()) .. " ▾" end

		local dropOpen = false; local dropFrame = nil; local dropOverlay = nil
		local function closeDrop()
			dropOpen = false
			if dropFrame   then pcall(function() dropFrame:Destroy()   end); dropFrame   = nil end
			if dropOverlay then pcall(function() dropOverlay:Destroy() end); dropOverlay = nil end
		end
		local function openDrop()
			if dropOpen then closeDrop(); return end
			dropOpen = true
			local itemH = 22; local dropH = #options * itemH + 6
			dropOverlay = Instance.new("TextButton")
			dropOverlay.BackgroundTransparency=1; dropOverlay.BorderSizePixel=0
			dropOverlay.Size=UDim2.new(1,0,1,0); dropOverlay.Text=""
			dropOverlay.AutoButtonColor=false; dropOverlay.ZIndex=198; dropOverlay.Parent=sg
			track(dropOverlay.MouseButton1Click:Connect(closeDrop))
			dropFrame = Instance.new("Frame")
			dropFrame.ZIndex=199; dropFrame.BorderSizePixel=0
			dropFrame.Size = UDim2.fromOffset(btn.AbsoluteSize.X+20, dropH)
			local ap = btn.AbsolutePosition
			dropFrame.Position = UDim2.fromOffset(ap.X-10, ap.Y+btn.AbsoluteSize.Y+2)
			local dfOB = Instance.new("Frame"); dfOB.Size=UDim2.new(1,0,1,0)
			dfOB.BackgroundColor3=Color3.fromRGB(0,0,0); dfOB.BorderSizePixel=0; dfOB.ZIndex=199; dfOB.Parent=dropFrame
			local dfOG = Instance.new("Frame"); dfOG.Position=UDim2.fromOffset(1,1); dfOG.Size=UDim2.new(1,-2,1,-2)
			dfOG.BackgroundColor3=Color3.fromRGB(60,60,60); dfOG.BorderSizePixel=0; dfOG.ZIndex=199; dfOG.Parent=dfOB
			local dfIn = Instance.new("Frame"); dfIn.Position=UDim2.fromOffset(1,1); dfIn.Size=UDim2.new(1,-2,1,-2)
			dfIn.BackgroundColor3=Color3.fromRGB(22,22,22); dfIn.BorderSizePixel=0; dfIn.ZIndex=199; dfIn.Parent=dfOG
			dropFrame.BackgroundTransparency=1; dropFrame.Parent=sg
			for i, opt in ipairs(options) do
				local isOn = tostring(getVal()) == tostring(opt)
				local item = Instance.new("TextButton")
				item.Size=UDim2.new(1,-6,0,itemH-2); item.Position=UDim2.fromOffset(3,3+(i-1)*itemH)
				item.BackgroundColor3=isOn and Color3.fromRGB(60,60,60) or Color3.fromRGB(28,28,28)
				item.BorderSizePixel=0; item.AutoButtonColor=false
				item.Text=(isOn and "✓  " or "    ")..tostring(opt)
				item.TextColor3=isOn and Color3.fromRGB(230,230,230) or Color3.fromRGB(160,160,160)
				item.TextSize=13; item.Font=Enum.Font.SourceSans
				item.TextXAlignment=Enum.TextXAlignment.Left
				item.ZIndex=204; item.Parent=dfIn
				local iC=Instance.new("UICorner"); iC.CornerRadius=UDim.new(0,3); iC.Parent=item
				local iP=Instance.new("UIPadding"); iP.PaddingLeft=UDim.new(0,8); iP.Parent=item
				track(item.MouseButton1Click:Connect(function()
					setVal(opt)
					refreshBtn()
					closeDrop()
				end))
			end
		end
		track(btn.MouseButton1Click:Connect(openDrop))
		return container, refreshBtn
	end

	-- ── addExploitKeybind helper ───────────────────────────────────────────
	local function addExploitKeybind(parent, labelText, getKey, setKey, lo)
		local bindListening = false
		local bindDotAnim   = nil

		local container = Instance.new("Frame")
		container.Size = UDim2.new(1,-20,0,32)
		container.BackgroundTransparency = 1
		container.ZIndex = parent.ZIndex+1
		container.LayoutOrder = lo or 0
		container.Parent = parent

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1,-120,1,0); lbl.Position = UDim2.fromOffset(16,0)
		lbl.BackgroundTransparency = 1; lbl.Text = labelText
		lbl.TextColor3 = Color3.fromRGB(200,200,200)
		lbl.TextSize = 16; lbl.Font = Enum.Font.SourceSans
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.ZIndex = container.ZIndex+1; lbl.Parent = container

		local function keyName(k)
			if typeof(k) == "EnumItem" then
				return tostring(k):gsub("Enum%.KeyCode%.", "")
			end
			return tostring(k)
		end

		local bindBtn = Instance.new("TextButton")
		bindBtn.AnchorPoint = Vector2.new(1,0.5); bindBtn.Position = UDim2.new(1,-12,0.5,-1)
		bindBtn.Size = UDim2.fromOffset(96,20)
		bindBtn.BackgroundColor3 = Color3.fromRGB(28,28,28)
		bindBtn.BorderSizePixel = 0; bindBtn.AutoButtonColor = false
		bindBtn.TextColor3 = Color3.fromRGB(200,200,200)
		bindBtn.TextSize = 13; bindBtn.Font = Enum.Font.SourceSans
		bindBtn.Text = keyName(getKey())
		bindBtn.ZIndex = container.ZIndex+2; bindBtn.Parent = container
		local bbC = Instance.new("UICorner"); bbC.CornerRadius = UDim.new(0,3); bbC.Parent = bindBtn
		local bbS = Instance.new("UIStroke"); bbS.Thickness = 1; bbS.Color = Color3.fromRGB(55,55,55); bbS.Parent = bindBtn

		local sepLine = Instance.new("Frame")
		sepLine.Size = UDim2.new(1,-24,0,1); sepLine.Position = UDim2.new(0,12,1,-1)
		sepLine.BackgroundColor3 = Color3.fromRGB(45,45,45); sepLine.BorderSizePixel = 0
		sepLine.ZIndex = container.ZIndex+1; sepLine.Parent = container

		local bindInputConn = nil
		local function stopListening()
			bindListening = false
			if bindDotAnim then bindDotAnim:Disconnect(); bindDotAnim = nil end
			bindBtn.Text = keyName(getKey())
			bindBtn.TextColor3 = Color3.fromRGB(200,200,200)
			bbS.Color = Color3.fromRGB(55,55,55)
			if bindInputConn then bindInputConn:Disconnect(); bindInputConn = nil end
		end
		local function startListening()
			if bindListening then stopListening(); return end
			bindListening = true
			local dots = 0
			bindDotAnim = RunService.RenderStepped:Connect(function()
				dots = (dots+1)%4
				bindBtn.Text = string.rep(".", dots==0 and 3 or dots)
				bindBtn.TextColor3 = Color3.fromRGB(255,255,120)
				bbS.Color = Color3.fromRGB(180,180,60)
			end)
			bindInputConn = UserInputService.InputBegan:Connect(function(input, gp)
				if not bindListening then return end
				if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
				if input.KeyCode == Enum.KeyCode.Escape then stopListening(); return end
				setKey(input.KeyCode)
				stopListening()
			end)
		end
		track(bindBtn.MouseButton1Click:Connect(startListening))
		return container
	end

	-- ── addExploitSectionDiv helper ────────────────────────────────────────
	local function addExploitDiv(parent, lo)
		local div = Instance.new("Frame")
		div.Size = UDim2.new(1,0,0,10); div.BackgroundTransparency = 1
		div.LayoutOrder = lo; div.ZIndex = parent.ZIndex+1; div.Parent = parent
		local line = Instance.new("Frame")
		line.Size = UDim2.new(1,-24,0,1); line.Position = UDim2.fromOffset(12,5)
		line.BackgroundColor3 = Color3.fromRGB(55,55,55); line.BorderSizePixel=0
		line.ZIndex=div.ZIndex+1; line.Parent=div
		return div
	end

	-- ── Profile buttons row ────────────────────────────────────────────────
	-- Profile selector (3 buttons: Standing / Moving / Jumping)
	local _yrProfileBtns = {}
	local _yrModeRefresh    = nil
	local _yrPitchRefresh   = nil
	local _yrCustomSlidUpd  = nil
	local _yrJitterTog      = nil
	local _yrJitterSlidUpd  = nil
	local _yrSpinSlidUpd    = nil

	local function yrLoadProfileUI()
		local prof = yrActiveProfile()
		if _yrModeRefresh  then _yrModeRefresh()  end
		if _yrPitchRefresh then _yrPitchRefresh() end
		if _yrCustomSlidUpd then _yrCustomSlidUpd() end
		if _yrJitterSlidUpd then _yrJitterSlidUpd() end
		if _yrSpinSlidUpd  then _yrSpinSlidUpd()  end
		-- update jitter toggle
		if _yrJitterTog then
			local prof2 = yrActiveProfile()
			setToggleState(_yrJitterTog, prof2.jitter or false, false)
		end
		-- highlight active profile button
		for name, pbtn in pairs(_yrProfileBtns) do
			local isActive = (name == (YAW.activeProfile or "Standing"))
			pbtn.BackgroundColor3 = isActive and Color3.fromRGB(60,60,60) or Color3.fromRGB(28,28,28)
			pbtn.TextColor3 = isActive and Color3.fromRGB(230,230,230) or Color3.fromRGB(160,160,160)
		end
	end

	-- ══════════════════════════════
	-- YAW ROTATOR секция
	-- ══════════════════════════════

	-- Header divider
	addExploitDiv(exploitsContent, 100)

	-- Title label
	local yrTitleRow = Instance.new("Frame")
	yrTitleRow.Size = UDim2.new(1,-20,0,22); yrTitleRow.BackgroundTransparency=1
	yrTitleRow.LayoutOrder=101; yrTitleRow.ZIndex=exploitsContent.ZIndex+1; yrTitleRow.Parent=exploitsContent
	local yrTitleLbl = Instance.new("TextLabel")
	yrTitleLbl.Size=UDim2.new(1,0,1,0); yrTitleLbl.Position=UDim2.fromOffset(16,0)
	yrTitleLbl.BackgroundTransparency=1; yrTitleLbl.Text="YAW ROTATOR"
	yrTitleLbl.TextColor3=Color3.fromRGB(130,130,130)
	yrTitleLbl.TextSize=12; yrTitleLbl.Font=Enum.Font.GothamBold
	yrTitleLbl.TextXAlignment=Enum.TextXAlignment.Left
	yrTitleLbl.ZIndex=yrTitleRow.ZIndex+1; yrTitleLbl.Parent=yrTitleRow

	-- Enable Yaw Rotator toggle
	local yrEnableToggle = addToggle(exploitsContent, "Yaw Rotator", false, function(v)
		YAW.enabled = v
	end)
	yrEnableToggle.LayoutOrder = 102

	-- At Targets toggle
	local yrAtTargetsToggle = addToggle(exploitsContent, "At Targets", false, function(v)
		YAW.atTargets = v
	end)
	yrAtTargetsToggle.LayoutOrder = 103

	-- ── Profile selector buttons ────────────────────────────────────────────
	local yrProfilesRow = Instance.new("Frame")
	yrProfilesRow.Size = UDim2.new(1,-20,0,32); yrProfilesRow.BackgroundTransparency=1
	yrProfilesRow.LayoutOrder=104; yrProfilesRow.ZIndex=exploitsContent.ZIndex+1; yrProfilesRow.Parent=exploitsContent

	local yrProfilesLbl = Instance.new("TextLabel")
	yrProfilesLbl.Size=UDim2.new(0,80,1,-2); yrProfilesLbl.Position=UDim2.fromOffset(16,0)
	yrProfilesLbl.BackgroundTransparency=1; yrProfilesLbl.Text="Profile"
	yrProfilesLbl.TextColor3=Color3.fromRGB(200,200,200)
	yrProfilesLbl.TextSize=16; yrProfilesLbl.Font=Enum.Font.SourceSans
	yrProfilesLbl.TextXAlignment=Enum.TextXAlignment.Left
	yrProfilesLbl.ZIndex=yrProfilesRow.ZIndex+1; yrProfilesLbl.Parent=yrProfilesRow

	local PROF_NAMES = {"Standing","Moving","Jumping"}
	for i, name in ipairs(PROF_NAMES) do
		local pb = Instance.new("TextButton")
		pb.Size = UDim2.fromOffset(62, 20)
		pb.AnchorPoint = Vector2.new(1,0.5)
		pb.Position = UDim2.new(1, -12 - (3-i)*66, 0.5, -1)
		pb.BackgroundColor3 = (name == "Standing") and Color3.fromRGB(60,60,60) or Color3.fromRGB(28,28,28)
		pb.BorderSizePixel = 0; pb.AutoButtonColor = false
		pb.TextColor3 = (name == "Standing") and Color3.fromRGB(230,230,230) or Color3.fromRGB(160,160,160)
		pb.TextSize = 11; pb.Font = Enum.Font.SourceSans; pb.Text = name
		pb.ZIndex = yrProfilesRow.ZIndex+2; pb.Parent = yrProfilesRow
		local pbC = Instance.new("UICorner"); pbC.CornerRadius=UDim.new(0,3); pbC.Parent=pb
		local pbS = Instance.new("UIStroke"); pbS.Thickness=1; pbS.Color=Color3.fromRGB(55,55,55); pbS.Parent=pb
		_yrProfileBtns[name] = pb
		track(pb.MouseButton1Click:Connect(function()
			YAW.activeProfile = name
			yrLoadProfileUI()
		end))
	end

	local yrProfSep = Instance.new("Frame")
	yrProfSep.Size=UDim2.new(1,-24,0,1); yrProfSep.Position=UDim2.new(0,12,1,-1)
	yrProfSep.BackgroundColor3=Color3.fromRGB(45,45,45); yrProfSep.BorderSizePixel=0
	yrProfSep.ZIndex=yrProfilesRow.ZIndex+1; yrProfSep.Parent=yrProfilesRow

	-- ── Profile settings label ──────────────────────────────────────────────
	local yrProfTitle = Instance.new("Frame")
	yrProfTitle.Size=UDim2.new(1,-20,0,18); yrProfTitle.BackgroundTransparency=1
	yrProfTitle.LayoutOrder=105; yrProfTitle.ZIndex=exploitsContent.ZIndex+1; yrProfTitle.Parent=exploitsContent
	local yrProfTitleLbl = Instance.new("TextLabel")
	yrProfTitleLbl.Size=UDim2.new(1,0,1,0); yrProfTitleLbl.Position=UDim2.fromOffset(16,0)
	yrProfTitleLbl.BackgroundTransparency=1; yrProfTitleLbl.Text="Profile Settings"
	yrProfTitleLbl.TextColor3=Color3.fromRGB(110,110,110)
	yrProfTitleLbl.TextSize=11; yrProfTitleLbl.Font=Enum.Font.GothamBold
	yrProfTitleLbl.TextXAlignment=Enum.TextXAlignment.Left
	yrProfTitleLbl.ZIndex=yrProfTitle.ZIndex+1; yrProfTitleLbl.Parent=yrProfTitle

	-- Mode dropdown (Jitter / Spin)
	local yrModeDrop, yrModeRefreshFn = addExploitDropdown(
		exploitsContent, "Mode", {"Jitter","Spin"},
		function() return yrActiveProfile().mode or "Jitter" end,
		function(v) yrActiveProfile().mode = v end,
		106
	)
	_yrModeRefresh = yrModeRefreshFn

	-- Pitch dropdown
	local yrPitchDrop, yrPitchRefreshFn = addExploitDropdown(
		exploitsContent, "Pitch", {"Back","Forward","Right","Left","Custom"},
		function() return yrActiveProfile().pitch or "Back" end,
		function(v) yrActiveProfile().pitch = v end,
		107
	)
	_yrPitchRefresh = yrPitchRefreshFn

	-- Custom Pitch Angle slider
	local _, yrCustomUpd = addExploitSlider(
		exploitsContent, "Custom Pitch Angle",
		function() return yrActiveProfile().pitchCustom or 180 end,
		function(v) yrActiveProfile().pitchCustom = v end,
		0, 360, 1, 108
	)
	_yrCustomSlidUpd = yrCustomUpd

	-- Jitter toggle
	local yrJitterTog = addToggle(exploitsContent, "Jitter", false, function(v)
		yrActiveProfile().jitter = v
	end)
	yrJitterTog.LayoutOrder = 109
	_yrJitterTog = yrJitterTog

	-- Jitter Speed slider
	local _, yrJitterSlidUpd = addExploitSlider(
		exploitsContent, "Jitter Speed",
		function() return yrActiveProfile().jitterSpeed or 10 end,
		function(v) yrActiveProfile().jitterSpeed = v end,
		1, 60, 1, 110
	)
	_yrJitterSlidUpd = yrJitterSlidUpd

	-- Spin Speed slider
	local _, yrSpinSlidUpd = addExploitSlider(
		exploitsContent, "Spin Speed",
		function() return yrActiveProfile().spinSpeed or 5 end,
		function(v) yrActiveProfile().spinSpeed = v end,
		1, 30, 1, 111
	)
	_yrSpinSlidUpd = yrSpinSlidUpd

	-- ══════════════════════════════
	-- YAW MANUAL секция
	-- ══════════════════════════════
	addExploitDiv(exploitsContent, 120)

	local yrManualTitle = Instance.new("Frame")
	yrManualTitle.Size=UDim2.new(1,-20,0,22); yrManualTitle.BackgroundTransparency=1
	yrManualTitle.LayoutOrder=121; yrManualTitle.ZIndex=exploitsContent.ZIndex+1; yrManualTitle.Parent=exploitsContent
	local yrManualTitleLbl = Instance.new("TextLabel")
	yrManualTitleLbl.Size=UDim2.new(1,0,1,0); yrManualTitleLbl.Position=UDim2.fromOffset(16,0)
	yrManualTitleLbl.BackgroundTransparency=1; yrManualTitleLbl.Text="YAW MANUAL"
	yrManualTitleLbl.TextColor3=Color3.fromRGB(130,130,130)
	yrManualTitleLbl.TextSize=12; yrManualTitleLbl.Font=Enum.Font.GothamBold
	yrManualTitleLbl.TextXAlignment=Enum.TextXAlignment.Left
	yrManualTitleLbl.ZIndex=yrManualTitle.ZIndex+1; yrManualTitleLbl.Parent=yrManualTitle

	local yrManualToggle = addToggle(exploitsContent, "Manual", false, function(v)
		YAW.manualEnabled = v
		if not v then YAW.manualActive = false end
	end)
	yrManualToggle.LayoutOrder = 122

	-- Left Key bind
	addExploitKeybind(
		exploitsContent, "Left Key",
		function() return YAW.manualLeftKey end,
		function(k) YAW.manualLeftKey = k end,
		123
	)

	-- Right Key bind
	addExploitKeybind(
		exploitsContent, "Right Key",
		function() return YAW.manualRightKey end,
		function(k) YAW.manualRightKey = k end,
		124
	)

	-- Manual Mode dropdown (Toggle / Hold / Always)
	addExploitDropdown(
		exploitsContent, "Manual Mode", {"Toggle","Hold","Always"},
		function()
			local m = YAW.manualMode or "toggle"
			return m:sub(1,1):upper() .. m:sub(2)
		end,
		function(v)
			YAW.manualMode = string.lower(v)
			if YAW.manualMode == "always" then
				YAW.manualActive = true
			elseif YAW.manualMode ~= "toggle" then
				YAW.manualActive = false
			end
		end,
		125
	)

	addExploitDiv(exploitsContent, 130)

	-- ── stats page ──
	local statsContent = Instance.new("Frame")
	statsContent.BackgroundTransparency = 1; statsContent.Position = UDim2.fromOffset(0,15)
	statsContent.Size = UDim2.new(1,0,1,-15); statsContent.Parent = pages["stats"]
	local st2 = Instance.new("UIListLayout"); st2.Padding = UDim.new(0,5); st2.Parent = statsContent
	addToggle(statsContent, "Stats", false, function(v) print("test") end)

	-- ── config page ──
	local configPage = pages["config"]

	-- ══ Реестр toggle-контейнеров для UI-синхронизации при load ══
	-- Заполняется по именам Frame после создания всех toggles.
	-- Ключ совпадает с ключом LOAD_STATE.
	local TOGGLE_FRAMES = {
		ab_enabled       = aimbotContent:FindFirstChild("AimbotToggle"),
		ab_vischeck      = aimbotContent:FindFirstChild("Wall CheckToggle"),
		ab_teamcheck     = aimbotContent:FindFirstChild("Team CheckToggle"),
		ab_autoswitch    = aimbotContent:FindFirstChild("Auto SwitchToggle"),
		ab_showfov       = aimbotContent:FindFirstChild("Show FOVToggle"),
		ab_fovcheck      = aimbotContent:FindFirstChild("FOV CheckToggle"),
		ab_autofire      = aimbotContent:FindFirstChild("Auto FireToggle"),
		ab_backcamera    = aimbotContent:FindFirstChild("Back CameraToggle"),
		vis_highlight    = visualContent:FindFirstChild("HighlightToggle"),
		hs_enabled       = miscContent:FindFirstChild("HitsoundToggle"),
		misc_tp_enabled  = miscContent:FindFirstChild("Third Person DistanceToggle"),
		misc_fov_enabled = miscContent:FindFirstChild("Field Of ViewToggle"),
		yaw_enabled      = exploitsContent:FindFirstChild("Yaw RotatorToggle"),
		yaw_atTargets    = exploitsContent:FindFirstChild("At TargetsToggle"),
		yaw_manualEnabled= exploitsContent:FindFirstChild("ManualToggle"),
		yaw_jitter       = exploitsContent:FindFirstChild("JitterToggle"),
		sprint_enabled   = exploitsContent:FindFirstChild("Auto SprintToggle"),
	}

	-- helper: синхронизировать визуал toggle с новым значением
	local function syncToggleUI(key, val)
		local frame = TOGGLE_FRAMES[key]
		if frame and toggleState[frame] then
			setToggleState(frame, val, false)
		end
	end

	-- ══ Регистрация всех настроек для save/load ══
	-- Aimbot
	SAVE_STATE["ab_enabled"]        = function() return AB.enabled end
	SAVE_STATE["ab_fov"]            = function() return AB.FOV end
	SAVE_STATE["ab_smoothness"]     = function() return AB.Smoothness end
	SAVE_STATE["ab_yoffset"]        = function() return AB.YOffset end
	SAVE_STATE["ab_vischeck"]       = function() return AB.VisCheck end
	SAVE_STATE["ab_teamcheck"]      = function() return AB.TeamCheck end
	SAVE_STATE["ab_autoswitch"]     = function() return AB.AutoSwitch end
	SAVE_STATE["ab_autofire"]       = function() return AB.AutoFire end
	SAVE_STATE["ab_backcamera"]     = function() return AB.BackCamera end
	SAVE_STATE["ab_bcd"]            = function() return AB.BackCameraDelay end
	SAVE_STATE["ab_fovcheck"]       = function() return AB.FOVCheck end
	SAVE_STATE["ab_showfov"]        = function() return AB_ShowFOV end
	SAVE_STATE["ab_aimkey"]         = function() return enumToStr(AB.AimKey) end
	SAVE_STATE["ab_targetparts"]    = function()
		local t = {}
		for k, v in pairs(AB.targetParts) do t[k] = v end
		return t
	end
	-- Visual
	SAVE_STATE["vis_highlight"]     = function() return highlightEnabled end
	SAVE_STATE["vis_hl_color"]      = function() return colorToTbl(highlightColor) end
	SAVE_STATE["vis_hl_alpha"]      = function() return highlightAlpha end
	-- Hitsound
	SAVE_STATE["hs_enabled"]        = function() return hsEnabled end
	SAVE_STATE["hs_volume"]         = function() return hsVolume end
	SAVE_STATE["hs_preset"]         = function() return hsPresetIdx end
	SAVE_STATE["hs_custom_id"]      = function() return hsCustomId end
	-- Misc: Field Of View
	SAVE_STATE["misc_fov_enabled"]  = function() return fovEnabled end
	SAVE_STATE["misc_fov_value"]    = function() return camFov end
	-- Misc: Third Person
	SAVE_STATE["misc_tp_enabled"]   = function() return tpEnabled end
	SAVE_STATE["misc_tp_distance"]  = function() return tpDistance end
	-- Yaw Rotator
	SAVE_STATE["yaw_enabled"]       = function() return YAW.enabled end
	SAVE_STATE["yaw_atTargets"]     = function() return YAW.atTargets end
	SAVE_STATE["yaw_activeProfile"] = function() return YAW.activeProfile end
	SAVE_STATE["yaw_profiles"]      = function()
		local t = {}
		for name, prof in pairs(YAW.profiles) do
			t[name] = {
				pitch       = prof.pitch,
				pitchCustom = prof.pitchCustom,
				mode        = prof.mode,
				jitter      = prof.jitter,
				jitterSpeed = prof.jitterSpeed,
				spinSpeed   = prof.spinSpeed,
			}
		end
		return t
	end
	SAVE_STATE["sprint_enabled"]     = function() return sprintEnabled end
	SAVE_STATE["yaw_jitter"]         = function() return yrActiveProfile().jitter or false end
	SAVE_STATE["yaw_manualEnabled"]  = function() return YAW.manualEnabled end
	SAVE_STATE["yaw_manualMode"]     = function() return YAW.manualMode end
	SAVE_STATE["yaw_manualLeftKey"]  = function()
		return tostring(YAW.manualLeftKey):gsub("Enum%.KeyCode%.", "")
	end
	SAVE_STATE["yaw_manualRightKey"] = function()
		return tostring(YAW.manualRightKey):gsub("Enum%.KeyCode%.", "")
	end

	-- ══ Setters для load (применяют значения в рантайм + обновляют UI) ══
	local LOAD_STATE = {}
	LOAD_STATE["ab_enabled"]        = function(v) AB.enabled = v==true; syncToggleUI("ab_enabled", v==true) end
	LOAD_STATE["ab_fov"]            = function(v) if type(v)=="number" then AB.FOV = v; if fovCircle then fovCircle.Radius = v end end end
	LOAD_STATE["ab_smoothness"]     = function(v) if type(v)=="number" then AB.Smoothness = v end end
	LOAD_STATE["ab_yoffset"]        = function(v) if type(v)=="number" then AB.YOffset = v end end
	LOAD_STATE["ab_vischeck"]       = function(v) AB.VisCheck = v==true; syncToggleUI("ab_vischeck", v==true) end
	LOAD_STATE["ab_teamcheck"]      = function(v) AB.TeamCheck = v==true; syncToggleUI("ab_teamcheck", v==true) end
	LOAD_STATE["ab_autoswitch"]     = function(v) AB.AutoSwitch = v==true; syncToggleUI("ab_autoswitch", v==true) end
	LOAD_STATE["ab_autofire"]       = function(v) AB.AutoFire = v==true; syncToggleUI("ab_autofire", v==true) end
	LOAD_STATE["ab_backcamera"]     = function(v) AB.BackCamera = v==true; syncToggleUI("ab_backcamera", v==true) end
	LOAD_STATE["ab_bcd"]            = function(v) if type(v)=="number" then AB.BackCameraDelay = v end end
	LOAD_STATE["ab_fovcheck"]       = function(v) AB.FOVCheck = v==true; syncToggleUI("ab_fovcheck", v==true) end
	LOAD_STATE["ab_showfov"]        = function(v) AB_ShowFOV = v==true; syncToggleUI("ab_showfov", v==true) end
	LOAD_STATE["ab_aimkey"]         = function(v) if type(v)=="string" then AB.AimKey = strToAimKey(v) end end
	LOAD_STATE["ab_targetparts"]    = function(v) if type(v)=="table" then for k,b in pairs(v) do AB.targetParts[k] = b end end end
	LOAD_STATE["vis_highlight"]     = function(v)
		highlightEnabled = v==true
		syncToggleUI("vis_highlight", v==true)
		setHighlightEnabled(highlightEnabled)
	end
	LOAD_STATE["vis_hl_color"]      = function(v) local c = tblToColor(v); if c then highlightColor = c; refreshHighlightColors() end end
	LOAD_STATE["vis_hl_alpha"]      = function(v) if type(v)=="number" then highlightAlpha = v; refreshHighlightColors() end end
	LOAD_STATE["hs_enabled"]        = function(v) hsEnabled = v==true; syncToggleUI("hs_enabled", v==true) end
	LOAD_STATE["hs_volume"]         = function(v) if type(v)=="number" then hsVolume = v; if hsSound then pcall(function() hsSound.Volume = v/100 end) end end end
	LOAD_STATE["hs_preset"]         = function(v) if type(v)=="number" then hsPresetIdx = v; createHsSound() end end
	LOAD_STATE["hs_custom_id"]      = function(v) if type(v)=="string" then hsCustomId = v end end
	-- Misc: Field Of View
	LOAD_STATE["misc_fov_enabled"]  = function(v)
		fovEnabled = v==true
		syncToggleUI("misc_fov_enabled", v==true)
	end
	LOAD_STATE["misc_fov_value"]    = function(v)
		if type(v)=="number" then camFov = math.clamp(v, 30, 120) end
	end
	-- Misc: Third Person
	LOAD_STATE["misc_tp_enabled"]   = function(v)
		tpEnabled = v==true
		syncToggleUI("misc_tp_enabled", v==true)
		if tpEnabled then applyThirdPerson() end
	end
	LOAD_STATE["misc_tp_distance"]  = function(v)
		if type(v)=="number" then tpDistance = math.clamp(v, 4, 60) end
	end
	-- Yaw Rotator
	LOAD_STATE["yaw_enabled"]       = function(v)
		YAW.enabled = v==true
		syncToggleUI("yaw_enabled", v==true)
		if v==true then startYawRotator() else stopYawRotator() end
	end
	LOAD_STATE["yaw_atTargets"]     = function(v)
		YAW.atTargets = v==true
		syncToggleUI("yaw_atTargets", v==true)
	end
	LOAD_STATE["yaw_activeProfile"] = function(v)
		if type(v)=="string" and YAW.profiles[v] then
			YAW.activeProfile = v
			yrLoadProfileUI()
		end
	end
	LOAD_STATE["yaw_profiles"]      = function(v)
		if type(v)~="table" then return end
		for name, prof in pairs(v) do
			if type(prof)=="table" and YAW.profiles[name] then
				local p = YAW.profiles[name]
				if prof.pitch       ~= nil then p.pitch       = prof.pitch       end
				if prof.pitchCustom ~= nil then p.pitchCustom = prof.pitchCustom end
				if prof.mode        ~= nil then p.mode        = prof.mode        end
				if prof.jitter      ~= nil then p.jitter      = prof.jitter      end
				if prof.jitterSpeed ~= nil then p.jitterSpeed = prof.jitterSpeed end
				if prof.spinSpeed   ~= nil then p.spinSpeed   = prof.spinSpeed   end
			end
		end
		yrLoadProfileUI()
	end
	LOAD_STATE["yaw_manualEnabled"] = function(v)
		YAW.manualEnabled = v==true
		syncToggleUI("yaw_manualEnabled", v==true)
		if not v then YAW.manualActive = false end
	end
	LOAD_STATE["yaw_manualMode"]    = function(v)
		if type(v)=="string" then YAW.manualMode = v end
	end
	LOAD_STATE["yaw_manualLeftKey"] = function(v)
		if type(v)=="string" then
			pcall(function() YAW.manualLeftKey = Enum.KeyCode[v] end)
		end
	end
	LOAD_STATE["yaw_manualRightKey"] = function(v)
		if type(v)=="string" then
			pcall(function() YAW.manualRightKey = Enum.KeyCode[v] end)
		end
	end
	LOAD_STATE["yaw_jitter"]        = function(v)
		yrActiveProfile().jitter = v==true
		syncToggleUI("yaw_jitter", v==true)
	end
	LOAD_STATE["sprint_enabled"]    = function(v)
		sprintEnabled = v==true
		syncToggleUI("sprint_enabled", v==true)
		if v==true then startSprint() end
	end

	local function doSave()
		if not cfgWriteAvailable() then return false end
		cfgEnsureFolder()
		local ok = pcall(function()
			local t = {}
			for k, getter in pairs(SAVE_STATE) do
				pcall(function() t[k] = getter() end)
			end
			writefile(CONFIG_FILE, HttpService:JSONEncode(t))
		end)
		return ok
	end

	local function doLoad()
		if not cfgWriteAvailable() then return false end
		local hasFile = true
		if type(isfile) == "function" then hasFile = isfile(CONFIG_FILE) end
		if not hasFile then return false end
		local ok = pcall(function()
			local raw = readfile(CONFIG_FILE)
			local t = HttpService:JSONDecode(raw)
			for k, setter in pairs(LOAD_STATE) do
				if t[k] ~= nil then
					pcall(setter, t[k])
				end
			end
		end)
		return ok
	end

	-- Автозагрузка при старте перенесена в конец createGui(),
	-- после инициализации TOGGLE_FRAMES, чтобы syncToggleUI работал корректно.

	-- ── Кнопки Save / Load в config page ──
	local cfgY = 10

	local function makeCfgBtn(label, yPos, onClick)
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.fromOffset(100, 26)
		btn.Position = UDim2.fromOffset(10, yPos)
		btn.BackgroundColor3 = Color3.fromRGB(28, 28, 28)
		btn.BorderSizePixel = 0
		btn.Text = label
		btn.TextColor3 = Color3.fromRGB(210, 210, 210)
		btn.TextSize = 14
		btn.Font = Enum.Font.SourceSans
		btn.AutoButtonColor = false
		btn.ZIndex = 80
		btn.Parent = configPage
		local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0,4); bc.Parent = btn
		local bs = Instance.new("UIStroke"); bs.Thickness = 1; bs.Color = Color3.fromRGB(50,50,50); bs.Parent = btn
		local function flash(success)
			local col = success and Color3.fromRGB(60,100,60) or Color3.fromRGB(100,50,50)
			btn.BackgroundColor3 = col
			task.delay(0.6, function()
				TweenService:Create(btn, TweenInfo.new(0.3), {BackgroundColor3 = Color3.fromRGB(28,28,28)}):Play()
			end)
		end
		track(btn.MouseButton1Click:Connect(function()
			local ok = onClick()
			flash(ok)
		end))
		return btn
	end

	makeCfgBtn("Save Config", cfgY,      function() return doSave() end)
	makeCfgBtn("Load Config", cfgY + 34, function() return doLoad() end)

	-- Статус (показывает PlaceId и путь файла)
	local cfgInfo = Instance.new("TextLabel")
	cfgInfo.Size = UDim2.new(1, -16, 0, 40)
	cfgInfo.Position = UDim2.fromOffset(10, cfgY + 72)
	cfgInfo.BackgroundTransparency = 1
	cfgInfo.Text = "Place: " .. tostring(game.PlaceId) .. "\nFile: " .. CONFIG_FILE
	cfgInfo.TextColor3 = Color3.fromRGB(100, 100, 100)
	cfgInfo.TextSize = 11
	cfgInfo.Font = Enum.Font.SourceSans
	cfgInfo.TextXAlignment = Enum.TextXAlignment.Left
	cfgInfo.TextWrapped = true
	cfgInfo.ZIndex = 80
	cfgInfo.Parent = configPage

	-- Разделитель
	local cfgDiv = Instance.new("Frame")
	cfgDiv.Size = UDim2.new(1, -20, 0, 1)
	cfgDiv.Position = UDim2.fromOffset(10, cfgY + 118)
	cfgDiv.BackgroundColor3 = Color3.fromRGB(45,45,45)
	cfgDiv.BorderSizePixel = 0; cfgDiv.ZIndex = 80; cfgDiv.Parent = configPage

	local unloadBtn = Instance.new("TextButton")
	unloadBtn.Name = "Unload"
	unloadBtn.AnchorPoint = Vector2.new(0, 0)
	unloadBtn.Position = UDim2.fromOffset(10, cfgY + 128)
	unloadBtn.Size = UDim2.fromOffset(80, 24)
	unloadBtn.BackgroundColor3 = Color3.fromRGB(32, 32, 32)
	unloadBtn.BorderSizePixel = 0
	unloadBtn.Text = "Unload"
	unloadBtn.TextColor3 = Color3.fromRGB(220, 220, 220)
	unloadBtn.TextSize = 14
	unloadBtn.Font = Enum.Font.SourceSans
	unloadBtn.AutoButtonColor = false
	unloadBtn.ZIndex = 80
	unloadBtn.Parent = configPage

	local unloadCorner = Instance.new("UICorner")
	unloadCorner.CornerRadius = UDim.new(0, 4)
	unloadCorner.Parent = unloadBtn

	local unloadStroke = Instance.new("UIStroke")
	unloadStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	unloadStroke.Thickness = 1
	unloadStroke.Color = Color3.fromRGB(45, 45, 45)
	unloadStroke.Transparency = 0
	unloadStroke.Parent = unloadBtn

	track(unloadBtn.MouseButton1Click:Connect(function()
		unload()
	end))

	-- Inner outline
	local innerOutline = Instance.new("Frame")
	innerOutline.Position = content.Position; innerOutline.Size = content.Size
	innerOutline.BackgroundTransparency = 1; innerOutline.BorderSizePixel = 0
	innerOutline.ZIndex = 10; innerOutline.Parent = frameArea
	local iStroke = Instance.new("UIStroke")
	iStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; iStroke.Thickness = 1
	iStroke.Color = Color3.fromRGB(85, 85, 85); iStroke.Parent = innerOutline

	-- Drag window
	track(outerBlack.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragActive = true; dragInput = input
			dragStartMouse = input.Position; dragStartPos = root.Position
		end
	end))
	track(outerBlack.InputEnded:Connect(function(input)
		if input == dragInput then dragActive = false; dragInput = nil end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		if dragActive and dragInput and dragStartMouse and dragStartPos then
			local delta = input.Position - dragStartMouse
			root.Position = UDim2.fromOffset(
				dragStartPos.X.Offset + delta.X,
				dragStartPos.Y.Offset + delta.Y
			)
		end
	end))

	switchTab("aimbot")

	-- Автозагрузка конфига — вызывается ЗДЕСЬ, когда TOGGLE_FRAMES уже
	-- инициализирован и все UI-элементы созданы. Иначе syncToggleUI не
	-- находит фреймы и цвета включённых toggles не обновляются.
	task.defer(function() pcall(doLoad) end)

	screenGui = sg
	return sg
end

local function setOpen(open)
	isOpen = open
	local sg = createGui()
	if sg then sg.Enabled = open end
end

destroyGui()
createGui()
setOpen(false)

track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if isUnloaded then return end
	if gameProcessed then return end
	if input.KeyCode == TOGGLE_KEY then
		setOpen(not isOpen)
	end
end))

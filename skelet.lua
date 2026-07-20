-- Wall Dasher v6 | Toggle: DELETE key
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")

local player = Players.LocalPlayer
local enabled = false
local connection = nil

-- НАСТРОЙКИ (меняются через GUI)
local CFG = {
    ANCHOR_X    = -48.573814392089844,
    ANCHOR_Y    = 1860.6036376953125,
    ANCHOR_Z    = -491.220703125,
    AMP_X       = 10,    -- размах по X
    AMP_Z       = 0,     -- размах по Z (0 = не двигаться по Z)
    DASH_SPEED  = 30,    -- скорость осцилляции
    FLY_SPEED   = 1000,  -- скорость подлёта
}

-- ======================== GUI ========================
local sg = Instance.new("ScreenGui", game.CoreGui)
sg.Name = "WallDasher"
sg.ResetOnSpawn = false

-- Главный фрейм
local mainFrame = Instance.new("Frame", sg)
mainFrame.Size = UDim2.new(0, 260, 0, 40)
mainFrame.Position = UDim2.new(0, 10, 0, 10)
mainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
mainFrame.BorderSizePixel = 0
Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 10)

local titleLabel = Instance.new("TextLabel", mainFrame)
titleLabel.Size = UDim2.new(0.6, 0, 1, 0)
titleLabel.Position = UDim2.new(0, 10, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.TextColor3 = Color3.new(1, 1, 1)
titleLabel.Text = "⚡ Wall Dasher v6"
titleLabel.TextScaled = true
titleLabel.TextXAlignment = Enum.TextXAlignment.Left

local statusLabel = Instance.new("TextLabel", mainFrame)
statusLabel.Size = UDim2.new(0.4, -10, 1, 0)
statusLabel.Position = UDim2.new(0.6, 0, 0, 0)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
statusLabel.Text = "OFF [DEL]"
statusLabel.TextScaled = true

-- Кнопка открыть настройки
local settingsBtn = Instance.new("TextButton", mainFrame)
settingsBtn.Size = UDim2.new(0, 28, 0, 28)
settingsBtn.Position = UDim2.new(1, -34, 0.5, -14)
settingsBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
settingsBtn.TextColor3 = Color3.new(1,1,1)
settingsBtn.Text = "⚙"
settingsBtn.TextScaled = true
settingsBtn.BorderSizePixel = 0
Instance.new("UICorner", settingsBtn).CornerRadius = UDim.new(0, 6)

-- Панель настроек
local settingsPanel = Instance.new("Frame", sg)
settingsPanel.Size = UDim2.new(0, 300, 0, 390)
settingsPanel.Position = UDim2.new(0, 10, 0, 58)
settingsPanel.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
settingsPanel.BorderSizePixel = 0
settingsPanel.Visible = false
Instance.new("UICorner", settingsPanel).CornerRadius = UDim.new(0, 10)

local panelTitle = Instance.new("TextLabel", settingsPanel)
panelTitle.Size = UDim2.new(1, 0, 0, 36)
panelTitle.BackgroundTransparency = 1
panelTitle.TextColor3 = Color3.fromRGB(200, 200, 200)
panelTitle.Text = "Настройки"
panelTitle.TextScaled = true

settingsBtn.MouseButton1Click:Connect(function()
    settingsPanel.Visible = not settingsPanel.Visible
end)

-- Функция создания строки настройки
local function makeRow(parent, yPos, labelText, cfgKey)
    local row = Instance.new("Frame", parent)
    row.Size = UDim2.new(1, -20, 0, 38)
    row.Position = UDim2.new(0, 10, 0, yPos)
    row.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
    row.BorderSizePixel = 0
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

    local lbl = Instance.new("TextLabel", row)
    lbl.Size = UDim2.new(0.55, 0, 1, 0)
    lbl.Position = UDim2.new(0, 8, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3 = Color3.fromRGB(200, 200, 200)
    lbl.Text = labelText
    lbl.TextScaled = true
    lbl.TextXAlignment = Enum.TextXAlignment.Left

    local box = Instance.new("TextBox", row)
    box.Size = UDim2.new(0.4, -8, 0.7, 0)
    box.Position = UDim2.new(0.57, 0, 0.15, 0)
    box.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
    box.TextColor3 = Color3.new(1,1,1)
    box.Text = tostring(CFG[cfgKey])
    box.TextScaled = true
    box.BorderSizePixel = 0
    box.ClearTextOnFocus = false
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 4)

    box.FocusLost:Connect(function()
        local val = tonumber(box.Text)
        if val then
            CFG[cfgKey] = val
            box.Text = tostring(val)
            -- Если активен — перезапустить
            if enabled then
                if connection then connection:Disconnect() connection = nil end
                task.defer(function() startDash() end)
            end
        else
            box.Text = tostring(CFG[cfgKey])
        end
    end)

    return row
end

-- Строки настроек
makeRow(settingsPanel, 42,  "Anchor X",    "ANCHOR_X")
makeRow(settingsPanel, 86,  "Anchor Y",    "ANCHOR_Y")
makeRow(settingsPanel, 130, "Anchor Z",    "ANCHOR_Z")
makeRow(settingsPanel, 174, "Amp X (±)",   "AMP_X")
makeRow(settingsPanel, 218, "Amp Z (±)",   "AMP_Z")
makeRow(settingsPanel, 262, "Dash Speed",  "DASH_SPEED")
makeRow(settingsPanel, 306, "Fly Speed",   "FLY_SPEED")

local hint = Instance.new("TextLabel", settingsPanel)
hint.Size = UDim2.new(1, -20, 0, 28)
hint.Position = UDim2.new(0, 10, 0, 350)
hint.BackgroundTransparency = 1
hint.TextColor3 = Color3.fromRGB(120, 120, 120)
hint.Text = "Amp Z=0 → не двигаться по Z"
hint.TextScaled = true

-- ======================== ЛОГИКА ========================
local function getChar() return player.Character end
local function getHRP()
    local c = getChar()
    return c and c:FindFirstChild("HumanoidRootPart")
end

function startDash()
    if connection then connection:Disconnect() connection = nil end

    local hrp = getHRP()
    if not hrp then return end
    local char = getChar()
    if not char then return end

    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        hum:ChangeState(Enum.HumanoidStateType.Physics)
    end

    local phase = 1  -- 1=летим к ANCHOR, 2=дёргаемся

    connection = RunService.Heartbeat:Connect(function(dt)
        if not enabled then return end
        local h = getHRP()
        if not h then return end
        local c = getChar()
        if not c then return end

        -- Noclip каждый кадр
        for _, p in ipairs(c:GetDescendants()) do
            if p:IsA("BasePart") then
                p.CanCollide = false
            end
        end

        -- Держим Physics стейт
        local hm = c:FindFirstChildOfClass("Humanoid")
        if hm and hm:GetState() ~= Enum.HumanoidStateType.Physics then
            hm:ChangeState(Enum.HumanoidStateType.Physics)
        end

        local anchor = Vector3.new(CFG.ANCHOR_X, CFG.ANCHOR_Y, CFG.ANCHOR_Z)
        local target

        if phase == 1 then
            target = anchor
            local dist = (h.Position - anchor).Magnitude
            if dist < 4 then
                phase = 2
            end
        else
            local t = tick() * CFG.DASH_SPEED
            local ox = math.sin(t) * CFG.AMP_X
            local oz = math.sin(t) * CFG.AMP_Z
            target = Vector3.new(anchor.X + ox, anchor.Y, anchor.Z + oz)
        end

        local diff = target - h.Position
        local dist = diff.Magnitude

        if dist > 0.3 then
            local speed = math.min(CFG.FLY_SPEED, dist / dt)
            h.AssemblyLinearVelocity = diff.Unit * speed
        else
            h.AssemblyLinearVelocity = Vector3.zero
        end
    end)
end

local function stopDash()
    if connection then connection:Disconnect() connection = nil end
    local char = getChar()
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        hum.PlatformStand = false
        hum:ChangeState(Enum.HumanoidStateType.GettingUp)
    end
end

UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.Delete then
        enabled = not enabled
        if enabled then
            statusLabel.Text = "ON [DEL]"
            statusLabel.TextColor3 = Color3.fromRGB(80, 255, 80)
            startDash()
        else
            statusLabel.Text = "OFF [DEL]"
            statusLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
            stopDash()
        end
    end
end)

print("⚡ Wall Dasher v6 loaded | DELETE = toggle")

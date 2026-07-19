local Fluent = loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer

-- ========================
-- НАСТРОЙКИ
-- ========================
local MY_PLOT = "Plot_6"
local IGNORED_TOOLS = { ["Bat"] = true, ["Noob Antenna"] = true }
local ToServer = game:GetService("ReplicatedStorage"):WaitForChild("Events"):WaitForChild("ToServer")

-- ========================
-- УТИЛИТЫ
-- ========================
local function log(msg)
    print("[AutoRob] " .. msg)
end

local function toNum(s)
    s = tostring(s):lower()
    local n = tonumber(s:match("[%d%.]+")) or 0
    if s:find("m") then n = n * 1000000
    elseif s:find("k") then n = n * 1000 end
    return n
end

local function teleportToBase()
    local myPlot = workspace.Plots:FindFirstChild(MY_PLOT)
    local spawn = myPlot and myPlot:FindFirstChild("PlayerSpawn")
    local char = lp.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root and spawn then
        root.CFrame = spawn.CFrame + Vector3.new(0, 3, 0)
        task.wait(0.3)
    end
end

local function teleportTo(pos)
    for _ = 1, 3 do
        local char = lp.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then
            root.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
            task.wait(0.05)
            if (root.Position - pos).Magnitude < 15 then break end
        else
            task.wait(0.1)
        end
    end
end

-- Проверка что украденный предмет есть (в Character или Backpack)
local function getStolenTool()
    local char = lp.Character
    if char then
        for _, v in pairs(char:GetChildren()) do
            if v:IsA("Tool") and not IGNORED_TOOLS[v.Name] then
                return v
            end
        end
    end
    for _, v in pairs(lp.Backpack:GetChildren()) do
        if v:IsA("Tool") and not IGNORED_TOOLS[v.Name] then
            return v
        end
    end
    return nil
end

-- ========================
-- ПОИСК ЦЕЛИ
-- ========================
local function getBestTarget()
    local best = nil
    local bestValue = 0

    for _, plot in pairs(workspace.Plots:GetChildren()) do
        if plot.Name == MY_PLOT then continue end
        local objects = plot:FindFirstChild("Objects")
        if not objects then continue end

        for _, obj in pairs(objects:GetChildren()) do
            -- Проверяем RobPrompt включён (база открыта)
            local robPrompt = obj:FindFirstChild("RobPrompt", true)
            if not robPrompt or not robPrompt.Enabled then continue end

            -- Ищем Amount лейбл
            local gui = obj:FindFirstChild("ObjectGui", true)
            if not gui then continue end

            for _, label in pairs(gui:GetDescendants()) do
                if label.Name == "Amount" and (label:IsA("TextLabel") or label:IsA("TextBox")) then
                    local text = label.Text
                    if text:find("/s") then continue end -- пропускаем /s объекты

                    local cur, max = text:match("([%d%.]+[kKmM]?)%s*/%s*([%d%.]+[kKmM]?)")
                    if not cur or not max then continue end

                    local cNum = toNum(cur)
                    local mNum = toNum(max)

                    if cNum >= mNum and mNum > bestValue then
                        bestValue = mNum
                        best = {
                            plot = plot.Name,
                            obj = obj,
                            prompt = robPrompt,
                            value = mNum,
                            text = text,
                            name = obj.Name
                        }
                        log("Найдена цель: " .. obj.Name .. " | " .. text .. " | plot=" .. plot.Name)
                    end
                end
            end
        end
    end

    return best
end

-- ========================
-- КРАЖА
-- ========================
local function doRob(target)
    log("Начинаем кражу: " .. target.name .. " (" .. target.text .. ")")

    -- Позиция промпта
    local attachment = target.prompt.Parent
    local part = attachment.Parent
    local pos

    if part:IsA("BasePart") then
        pos = part.Position
    elseif part:IsA("Model") and part.PrimaryPart then
        pos = part.PrimaryPart.Position
    else
        log("ОШИБКА: не найдена позиция промпта")
        return false
    end

    -- Телепорт к объекту
    log("Телепорт к " .. target.name .. " pos=" .. tostring(pos))
    teleportTo(pos)
    task.wait(0.15)

    -- Активируем промпт
    log("Активируем RobPrompt...")
    fireproximityprompt(target.prompt)

    -- Каждый кадр проверяем: объект фулл? база открыта? предмет появился?
    log("Ждём предмет в руках...")
    local timeout = tick() + 6
    local stolen = nil

    local function isTargetStillValid()
        if not target.obj or not target.obj.Parent then return false end
        if not target.prompt or not target.prompt.Enabled then
            log("✗ База закрылась — отменяем")
            return false
        end
        local gui = target.obj:FindFirstChild("ObjectGui", true)
        if gui then
            for _, label in pairs(gui:GetDescendants()) do
                if label.Name == "Amount" and label:IsA("TextLabel") then
                    local cur, max = label.Text:match("([%d%.]+[kKmM]?)%s*/%s*([%d%.]+[kKmM]?)")
                    if cur and max and toNum(cur) < toNum(max) then
                        log("✗ Объект больше не фулл — отменяем")
                        return false
                    end
                end
            end
        end
        return true
    end

    while tick() < timeout do
        task.wait(0.05)
        if not isTargetStillValid() then
            teleportToBase()
            return false
        end
        stolen = getStolenTool()
        if stolen then
            log("✓ УКРАДЕНО: " .. stolen.Name)
            break
        end
    end

    if not stolen then
        log("✗ Кража не удалась (таймаут)")
        teleportToBase()
        return false
    end

    -- Телепорт на базу
    log("Телепорт на базу...")
    teleportToBase()
    log("✓ На базе!")
    return true
end

-- ========================
-- GUI
-- ========================
local Window = Fluent:CreateWindow({
    Title = "AutoRob",
    SubTitle = "v2.0",
    TabWidth = 140,
    Size = UDim2.fromOffset(480, 360),
    Acrylic = false,
    Theme = "Dark",
    MinimizeKey = Enum.KeyCode.Delete
})

local Tabs = {
    Main = Window:AddTab({ Title = "Main", Icon = "home" }),
    Debug = Window:AddTab({ Title = "Debug", Icon = "terminal" }),
}

-- Статус через лог и notify
local lastStatus = "Ожидание..."
local function setStatus(text)
    lastStatus = text
    log(text)
end

-- Статус параграф (обновляем через пересоздание не нужно, просто показываем в notify)
Tabs.Main:AddParagraph({
    Title = "Инфо",
    Content = "Мой плот: " .. MY_PLOT .. " | Delete = открыть/закрыть"
})

-- Найти цель
Tabs.Main:AddButton({
    Title = "Найти лучшую цель",
    Description = "Показывает самый дорогой заполненный объект",
    Callback = function()
        local t = getBestTarget()
        if t then
            Fluent:Notify({ Title = "Цель найдена!", Content = t.name .. " | " .. t.text .. "\nПлот: " .. t.plot, Duration = 5 })
        else
            Fluent:Notify({ Title = "Целей нет", Content = "Нет заполненных открытых баз", Duration = 3 })
        end
    end
})

-- Украсть один раз
Tabs.Main:AddButton({
    Title = "Украсть сейчас",
    Description = "Разовая кража лучшего объекта",
    Callback = function()
        local t = getBestTarget()
        if t then
            setStatus("Крадём: " .. t.name)
            local ok = doRob(t)
            setStatus(ok and ("✓ Украдено: " .. t.name) or "✗ Не удалось")
            Fluent:Notify({
                Title = ok and "Украдено!" or "Не удалось",
                Content = t.name .. " | " .. t.text,
                Duration = 3
            })
        else
            setStatus("Нет целей")
            Fluent:Notify({ Title = "Нечего красть", Content = "Нет заполненных объектов", Duration = 3 })
        end
    end
})

-- Авто-кража
local autoEnabled = false
local isRobbing = false
local heartbeat = nil

local AutoToggle = Tabs.Main:AddToggle("AutoRob", {
    Title = "Авто-кража",
    Description = "Каждый кадр ищет заполненную цель и крадёт",
    Default = false
})

AutoToggle:OnChanged(function()
    autoEnabled = Fluent.Options.AutoRob.Value

    if autoEnabled then
        isRobbing = false
        heartbeat = RunService.Heartbeat:Connect(function()
            if not autoEnabled or isRobbing then return end
            local t = getBestTarget()
            if t then
                isRobbing = true
                task.spawn(function()
                    setStatus("Крадём: " .. t.name .. " (" .. t.text .. ")")
                    local ok = doRob(t)
                    setStatus(ok and ("✓ Украдено: " .. t.name) or ("✗ Фейл: " .. t.name))
                    task.wait(0.5)
                    isRobbing = false
                end)
            else
                setStatus("Ждём заполненную цель...")
            end
        end)
        Fluent:Notify({ Title = "Авто-кража", Content = "Включена", Duration = 2 })
    else
        autoEnabled = false
        isRobbing = false
        if heartbeat then heartbeat:Disconnect() heartbeat = nil end
        setStatus("Остановлено")
        Fluent:Notify({ Title = "Авто-кража", Content = "Выключена", Duration = 2 })
    end
end)

-- Телепорт на базу
Tabs.Main:AddButton({
    Title = "Телепорт на базу",
    Description = MY_PLOT,
    Callback = function()
        teleportToBase()
    end
})

-- Debug таб
Tabs.Debug:AddButton({
    Title = "Дебаг: что в руках?",
    Description = "Показывает Tool который держишь",
    Callback = function()
        local tool = getStolenTool()
        if tool then
            local info = "Tool: " .. tool.Name .. "\n"
            for k, v in pairs(tool:GetAttributes()) do
                info = info .. k .. " = " .. tostring(v) .. "\n"
            end
            Fluent:Notify({ Title = "В руках:", Content = info, Duration = 8 })
            log(info)
        else
            Fluent:Notify({ Title = "В руках пусто", Content = "Нет украденного предмета", Duration = 3 })
        end
    end
})

Tabs.Debug:AddButton({
    Title = "Дебаг: все цели",
    Description = "Показывает все объекты во всех плотах",
    Callback = function()
        local lines = {}
        for _, plot in pairs(workspace.Plots:GetChildren()) do
            if plot.Name == MY_PLOT then continue end
            local objects = plot:FindFirstChild("Objects")
            if not objects then continue end
            for _, obj in pairs(objects:GetChildren()) do
                local rp = obj:FindFirstChild("RobPrompt", true)
                local enabled = rp and tostring(rp.Enabled) or "no prompt"
                local gui = obj:FindFirstChild("ObjectGui", true)
                local amount = "?"
                if gui then
                    for _, l in pairs(gui:GetDescendants()) do
                        if l.Name == "Amount" and l:IsA("TextLabel") then
                            amount = l.Text
                        end
                    end
                end
                table.insert(lines, plot.Name .. " | " .. obj.Name .. " | " .. amount .. " | open=" .. enabled)
            end
        end
        local out = table.concat(lines, "\n")
        setclipboard(out)
        log(out)
        Fluent:Notify({ Title = "Скопировано!", Content = tostring(#lines) .. " объектов", Duration = 3 })
    end
})

Window:SelectTab(1)
Fluent:Notify({ Title = "AutoRob загружен", Content = "Delete = открыть/закрыть", Duration = 4 })

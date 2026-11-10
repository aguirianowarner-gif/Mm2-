--[[
    Wxnnxrx Hub 2.6.3 - Basic Test UI - MM2
    Original Luau client-side hub with mobile-friendly UI.

    Included:
      - Player ESP with role labels, highlights and distance
      - Coin and dropped-gun locator
      - Fly, Noclip, WalkSpeed, JumpPower and Infinite Jump
      - Anti-Fling velocity mitigation and Anti-Void recovery
      - FullBright, Fog control and camera FOV
      - Teleport to a named player / Murderer / Sheriff
      - Experimental coin collection and dropped-gun approach
      - Sheriff target assist / auto shoot and murderer knife automation
      - Role alerts, rejoin, UI hide/show and cleanup

    Notes:
      - This is a client-side script. MM2 server validation controls rewards,
        weapon pickup, combat, wins and other server-authoritative actions.
      - Executor compatibility varies. Delta Android has not been runtime-tested.
      - No anti-detection, credential collection or obfuscation. Combat hooks only
        redirect aim data for recognized weapon calls when executor hooks exist.
]]

--// Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local CoreGui = game:GetService("CoreGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = workspace.CurrentCamera

--// Avoid duplicate GUIs
local GUI_NAME = "WxnnxrxHub26"
local oldGui
pcall(function()
    local parent = gethui and gethui() or CoreGui
    oldGui = parent:FindFirstChild(GUI_NAME) or parent:FindFirstChild("WxnnxrxHub25") or parent:FindFirstChild("WxnnxrxHub24")
end)
if oldGui then pcall(function() oldGui:Destroy() end) end

--// Runtime state
local running = true
local currentCharacter = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local currentHumanoid = currentCharacter:FindFirstChildOfClass("Humanoid")
local currentRoot = currentCharacter:FindFirstChild("HumanoidRootPart")

local State = {
    PlayerESP = false,
    ESP_Murderer = true,
    ESP_Sheriff = true,
    ESP_Innocent = true,
    ESP_Distance = true,
    CoinESP = false,
    GunESP = false,
    Fly = false,
    Noclip = false,
    InfiniteJump = false,
    DoubleJump = false,
    InfiniteWallHop = false,
    SpeedGlitch = false,
    FullBright = false,
    RemoveFog = false,
    AutoFarm = false,
    AutoGrabGun = false,
    RoleAlerts = true,
    NearMurdererAlert = true,
    AutoFarmCandy = false,
    SpinBot = false,
    BunnyHop = false,
    WallHop = false,
    PerformanceMode = false,
    HUD = true,
    AutoSaveConfig = false,
    ESP_Box = false,
    ESP_Tracers = false,
    ESP_Name = true,
    SmartNotifications = true,
    Spectate = false,
    DayMode = false,
    AntiAFK = false,
    AntiFling = false,
    AntiVoid = false,
    SilentAim = false,
    KnifeSilentAim = false,
    AutoShoot = false,
    FastShoot = false,
    KillAura = false,
    KillAll = false,
    ShootMurderer = false,
    FloatingShootButton = false,
}

local appliedWalkSpeed, appliedJumpPower
local InnocentESPColorHex = "55DC87"
local savedThemeIndex = 1

-- Load known settings while ignoring malformed or unknown values.
pcall(function()
    if type(readfile) == "function" and type(isfile) == "function" then
        local configPath = isfile("WxnnxrxHub26_Config.json") and "WxnnxrxHub26_Config.json"
            or (isfile("WxnnxrxHub25_Config.json") and "WxnnxrxHub25_Config.json" or nil)
        if not configPath then return end
        local decoded = game:GetService("HttpService"):JSONDecode(readfile(configPath))
        if type(decoded) == "table" then
            for key, value in pairs(decoded) do
                if State[key] ~= nil and type(State[key]) == "boolean" and type(value) == "boolean" then
                    State[key] = value
                end
            end
            if type(decoded.WalkSpeedValue) == "number" then
                appliedWalkSpeed = math.clamp(decoded.WalkSpeedValue, 0, 100)
            end
            if type(decoded.JumpPowerValue) == "number" then
                appliedJumpPower = math.clamp(decoded.JumpPowerValue, 0, 150)
            end
            if type(decoded.InnocentESPColorHex) == "string" then
                local candidate = string.gsub(decoded.InnocentESPColorHex, "#", "")
                if string.match(candidate, "^%x%x%x%x%x%x$") then
                    InnocentESPColorHex = string.upper(candidate)
                end
            end
            if type(decoded.ThemeIndex) == "number" then savedThemeIndex = math.clamp(math.floor(decoded.ThemeIndex), 1, 5) end
        end
    end
end)

local ESPObjects = {}
local CoinObjects = {}
local GunObjects = {}
local savedCollisions = {}
local flyVelocity, flyGyro
local originalSpeed, originalJump, originalFOV
local originalLighting = {
    Brightness = Lighting.Brightness,
    ClockTime = Lighting.ClockTime,
    GlobalShadows = Lighting.GlobalShadows,
    Ambient = Lighting.Ambient,
    OutdoorAmbient = Lighting.OutdoorAmbient,
    FogEnd = Lighting.FogEnd,
    FogStart = Lighting.FogStart,
}
local shutdown
local lastRole = "UNKNOWN"
local lastNearAlert = 0
local alertDistance = 35
local lastSafeCFrame = nil
local lastSafeUpdate = 0
local lastAntiFlingTime = 0
local lastAntiVoidTime = 0
local fallDestroyHeight = -500
pcall(function()
    fallDestroyHeight = workspace.FallenPartsDestroyHeight
end)

--// Small helpers
local function safeDestroy(obj)
    if obj then pcall(function() obj:Destroy() end) end
end

local function make(className, parent, properties)
    local object = Instance.new(className)
    for property, value in pairs(properties or {}) do
        pcall(function() object[property] = value end)
    end

    -- FIX 2.6.2: Delta/Roblox mobile buttons must be explicitly interactable.
    -- GuiButton.Activated is used by every tab, toggle, action and floating button.
    -- Setting this centrally prevents individual controls from silently ignoring taps.
    if object:IsA("GuiButton") then
        pcall(function() object.Active = true end)
        pcall(function() object.Interactable = true end)
    elseif object:IsA("TextBox") then
        -- Ensure search and value/profile fields can receive touch focus.
        pcall(function() object.Active = true end)
        pcall(function() object.Interactable = true end)
    end

    object.Parent = parent
    return object
end

local function round(object, radius)
    make("UICorner", object, {CornerRadius = UDim.new(0, radius or 8)})
end

local function stroke(object, color, thickness, transparency)
    make("UIStroke", object, {
        Color = color or Color3.fromRGB(70, 75, 95),
        Thickness = thickness or 1,
        Transparency = transparency or 0.2,
    })
end

local function notify(title, message)
    local titleText = tostring(title or "")
    local isErrorNotice = string.find(string.lower(titleText), "error", 1, true) ~= nil
    if State and State.SmartNotifications == false and not isErrorNotice then return end
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = title,
            Text = message,
            Duration = 3,
        })
    end)
end

--// Reversible local performance mode: suppresses cosmetic effects and shadows.
--// Every changed property is saved once and restored to its exact prior value.
local performanceSaved = {}
local performanceDescendantConnection

local function setPerformanceObject(object, enabled)
    if not object then return end

    local shouldDisableEffect =
        object:IsA("ParticleEmitter")
        or object:IsA("Trail")
        or object:IsA("Beam")
        or object:IsA("Smoke")
        or object:IsA("Fire")
        or object:IsA("Sparkles")
        or object:IsA("PostEffect")

    local function saveAndSet(property, value)
        local ok, original = pcall(function() return object[property] end)
        if not ok then return end

        performanceSaved[object] = performanceSaved[object] or {}
        if performanceSaved[object][property] == nil then
            performanceSaved[object][property] = original
        end
        pcall(function() object[property] = value end)
    end

    if enabled then
        if shouldDisableEffect then
            saveAndSet("Enabled", false)
        end
        if object:IsA("BasePart") then
            saveAndSet("CastShadow", false)
        end
    end
end

local function setPerformanceMode(enabled)
    if enabled then
        for _, object in ipairs(workspace:GetDescendants()) do
            setPerformanceObject(object, true)
        end
        for _, object in ipairs(Lighting:GetDescendants()) do
            setPerformanceObject(object, true)
        end

        if performanceDescendantConnection then
            performanceDescendantConnection:Disconnect()
        end
        performanceDescendantConnection = workspace.DescendantAdded:Connect(function(object)
            if running and State.PerformanceMode then
                setPerformanceObject(object, true)
            end
        end)
    else
        if performanceDescendantConnection then
            performanceDescendantConnection:Disconnect()
            performanceDescendantConnection = nil
        end

        for object, properties in pairs(performanceSaved) do
            if object and object.Parent then
                for property, original in pairs(properties) do
                    pcall(function() object[property] = original end)
                end
            end
        end
        table.clear(performanceSaved)
    end
end

local function getCharacter(player)
    return player and player.Character
end

local function getRoot(player)
    local character = getCharacter(player)
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid(player)
    local character = getCharacter(player)
    return character and character:FindFirstChildOfClass("Humanoid")
end

local function toolHasMarker(tool, keyword)
    if not tool or not tool:IsA("Tool") then return false end
    local lowerName = string.lower(tool.Name)
    if string.find(lowerName, keyword, 1, true) then return true end
    for _, descendant in ipairs(tool:GetDescendants()) do
        local childName = string.lower(descendant.Name)
        if keyword == "knife" and (string.find(childName, "knife", 1, true)
            or childName == "slashstart" or childName == "flingknife") then
            return true
        end
        if keyword == "gun" and (string.find(childName, "gunserver", 1, true)
            or childName == "shootgun" or childName == "shootstart") then
            return true
        end
    end
    return false
end

local function findTool(player, keyword)
    if not player then return nil end
    local character = player.Character
    local backpack = player:FindFirstChildOfClass("Backpack")
    if character then
        for _, child in ipairs(character:GetChildren()) do
            if child:IsA("Tool") and toolHasMarker(child, keyword) then return child end
        end
    end
    if backpack then
        for _, child in ipairs(backpack:GetChildren()) do
            if child:IsA("Tool") and toolHasMarker(child, keyword) then return child end
        end
    end
    return nil
end

local function getRole(player)
    if findTool(player, "knife") then return "MURDERER" end
    if findTool(player, "gun") then return "SHERIFF" end
    if player == LocalPlayer and not currentCharacter then return "UNKNOWN" end
    return "INNOCENT"
end

local function getInnocentESPColor()
    local hex = string.gsub(tostring(InnocentESPColorHex or "55DC87"), "#", "")
    if not string.match(hex, "^%x%x%x%x%x%x$") then
        hex = "55DC87"
    end
    local red = tonumber(string.sub(hex, 1, 2), 16) or 85
    local green = tonumber(string.sub(hex, 3, 4), 16) or 220
    local blue = tonumber(string.sub(hex, 5, 6), 16) or 135
    return Color3.fromRGB(red, green, blue)
end

local function roleColor(role)
    if role == "MURDERER" then return Color3.fromRGB(255, 75, 80) end
    if role == "SHERIFF" then return Color3.fromRGB(75, 155, 255) end
    if role == "INNOCENT" then return getInnocentESPColor() end
    return Color3.fromRGB(220, 220, 230)
end

local function getMapCoinContainer()
    local direct = workspace:FindFirstChild("CoinContainer", true)
    if direct then return direct end
    return nil
end

local function getCurrentMapName()
    local mapRoot = workspace:FindFirstChild("Map") or workspace:FindFirstChild("map")
    if mapRoot then
        for _, child in ipairs(mapRoot:GetChildren()) do
            if child:IsA("Model") or child:IsA("Folder") then return child.Name end
        end
        return mapRoot.Name
    end
    -- Fallback: look for a likely map model, excluding known gameplay containers.
    for _, child in ipairs(workspace:GetChildren()) do
        local lower = string.lower(child.Name)
        if (child:IsA("Model") or child:IsA("Folder"))
            and not string.find(lower, "coin", 1, true)
            and not string.find(lower, "lobby", 1, true)
            and not string.find(lower, "camera", 1, true)
            and not string.find(lower, "drop", 1, true) then
            if child:FindFirstChildWhichIsA("BasePart", true) then return child.Name end
        end
    end
    return "No detectado"
end

local function getAlivePlayerCount()
    local alive = 0
    for _, player in ipairs(Players:GetPlayers()) do
        local humanoid = getHumanoid(player)
        if humanoid and humanoid.Health > 0 then alive += 1 end
    end
    return alive
end

local function getRoundTimerText()
    local timerNames = {"RoundTimer", "GameTimer", "Timer", "TimeLeft", "RoundTime"}
    for _, name in ipairs(timerNames) do
        local valueObject = workspace:FindFirstChild(name, true)
        if valueObject and (valueObject:IsA("StringValue") or valueObject:IsA("IntValue") or valueObject:IsA("NumberValue")) then
            return tostring(valueObject.Value)
        end
        if valueObject and valueObject:IsA("TextLabel") then
            return tostring(valueObject.Text)
        end
    end
    return "N/D"
end

local function getPingMilliseconds()
    local ok, value = pcall(function()
        return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and type(value) == "number" then return math.floor(value + 0.5) end
    return nil
end

local function getCandyContainer()
    return workspace:FindFirstChild("CandyContainer", true) or workspace:FindFirstChild("Candy", true)
end

local function findDroppedGun()
    local candidates = {"GunDrop", "Gun_Drop", "DroppedGun", "GunDropPart"}
    for _, name in ipairs(candidates) do
        local found = workspace:FindFirstChild(name, true)
        if found then return found end
    end
    return nil
end

local function getObjectPosition(object)
    if not object then return nil end
    if object:IsA("BasePart") then return object.Position end
    if object:IsA("Model") then
        local ok, pivot = pcall(function() return object:GetPivot() end)
        if ok then return pivot.Position end
    end
    return nil
end

local function getObjectAdornee(object)
    if not object then return nil end
    if object:IsA("BasePart") then return object end
    if object:IsA("Model") then
        return object.PrimaryPart or object:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end

--// WXNNXRX HUB 2.4 UI • interfaz integrada en el motor 2.2
local guiParent = PlayerGui
pcall(function()
    if gethui then guiParent = gethui() else guiParent = CoreGui end
end)

local oldGui
pcall(function() oldGui = guiParent:FindFirstChild("WxnnxrxHub26") or guiParent:FindFirstChild("WxnnxrxHub25") or guiParent:FindFirstChild("WxnnxrxHub24") end)
if oldGui then pcall(function() oldGui:Destroy() end) end

local COLORS = {
    Background = Color3.fromRGB(20, 20, 20),
    Panel = Color3.fromRGB(32, 32, 32),
    Panel2 = Color3.fromRGB(48, 48, 48),
    Panel3 = Color3.fromRGB(65, 65, 65),
    Blue = Color3.fromRGB(90, 190, 110),
    BlueDark = Color3.fromRGB(55, 135, 75),
    Text = Color3.fromRGB(255, 255, 255),
    Muted = Color3.fromRGB(215, 215, 215),
    Off = Color3.fromRGB(95, 95, 95),
    White = Color3.fromRGB(255, 255, 255),
}

local function uiTween(object, duration, properties, style, direction)
    -- Simple diagnostic UI: no animations or delayed visual transitions.
    for property, value in pairs(properties or {}) do
        pcall(function() object[property] = value end)
    end
    return nil
end

local function addCorner(object, radius)
    make("UICorner", object, {CornerRadius = UDim.new(0, radius or 10)})
end

local function addStroke(object, color, thickness, transparency)
    make("UIStroke", object, {
        Color = color or COLORS.Blue,
        Thickness = thickness or 1,
        Transparency = transparency or 0.55,
    })
end

local ScreenGui = make("ScreenGui", guiParent, {
    Name = "WxnnxrxHub26",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    IgnoreGuiInset = true,
    DisplayOrder = 50,
})

local HUDFrame = make("Frame", ScreenGui, {
    Name = "WxnnxrxHUD", AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -12, 0, 12), Size = UDim2.fromOffset(188, 104),
    BackgroundColor3 = COLORS.Background, BackgroundTransparency = 0.12,
    BorderSizePixel = 0, Visible = State.HUD, ZIndex = 20,
})
addCorner(HUDFrame, 10)
addStroke(HUDFrame, COLORS.Blue, 1, 0.35)
local HUDTitle = make("TextLabel", HUDFrame, {
    Position = UDim2.fromOffset(9, 5), Size = UDim2.new(1, -18, 0, 18),
    BackgroundTransparency = 1, Text = "WXNNXRX  •  MM2", TextColor3 = COLORS.Blue,
    Font = Enum.Font.GothamBold, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 21,
})
local HUDInfo = make("TextLabel", HUDFrame, {
    Position = UDim2.fromOffset(9, 25), Size = UDim2.new(1, -18, 1, -30),
    BackgroundTransparency = 1, Text = "FPS: --  |  Ping: --\nRol: --\nMapa: --\nVivos: --",
    TextColor3 = COLORS.Text, Font = Enum.Font.GothamMedium, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    TextWrapped = true, ZIndex = 21,
})

local Main = make("Frame", ScreenGui, {
    Name = "Main",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, 0),
    Size = UDim2.fromOffset(600, 440),
    BackgroundColor3 = COLORS.Background,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Active = true,
})
addCorner(Main, 15)
addStroke(Main, COLORS.Blue, 1.2, 0.48)
local MainScale = make("UIScale", Main, {Scale = 1})

local function updateScale()
    local camera = workspace.CurrentCamera
    if not camera then return end
    local viewport = camera.ViewportSize
    MainScale.Scale = math.clamp(math.min(viewport.X / 600, viewport.Y / 460), 0.60, 1)
end
updateScale()
local viewportConnection
local function bindCurrentCamera()
    if viewportConnection then
        viewportConnection:Disconnect()
        viewportConnection = nil
    end
    Camera = workspace.CurrentCamera
    if Camera then
        updateScale()
        viewportConnection = Camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
    end
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindCurrentCamera)
bindCurrentCamera()

local Header = make("Frame", Main, {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, 52),
    BackgroundColor3 = COLORS.Panel,
    BorderSizePixel = 0,
    ZIndex = 2,
    Active = true,
})
make("Frame", Header, {
    Position = UDim2.new(0, 0, 1, -9),
    Size = UDim2.new(1, 0, 0, 9),
    BackgroundColor3 = COLORS.Panel,
    BorderSizePixel = 0,
    ZIndex = 2,
})
make("TextLabel", Header, {
    Name = "Title",
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(15, 0),
    Size = UDim2.new(1, -115, 1, 0),
    Font = Enum.Font.GothamBold,
    Text = "WXNNXRX  HUB  2.6.4",
    TextColor3 = COLORS.Text,
    TextSize = 15,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 3,
})

local MinButton = make("TextButton", Header, {
    Name = "Minimize",
    Position = UDim2.new(1, -78, 0, 10),
    Size = UDim2.fromOffset(28, 28),
    BackgroundColor3 = COLORS.Panel3,
    BorderSizePixel = 0,
    Text = "—",
    TextColor3 = COLORS.Text,
    Font = Enum.Font.GothamBold,
    TextSize = 16,
    AutoButtonColor = false,
    ZIndex = 4,
})
addCorner(MinButton, 8)

local CloseButton = make("TextButton", Header, {
    Name = "Close",
    Position = UDim2.new(1, -42, 0, 10),
    Size = UDim2.fromOffset(28, 28),
    BackgroundColor3 = COLORS.Panel3,
    BorderSizePixel = 0,
    Text = "×",
    TextColor3 = COLORS.Text,
    Font = Enum.Font.GothamBold,
    TextSize = 20,
    AutoButtonColor = false,
    ZIndex = 4,
})
addCorner(CloseButton, 8)

local Sidebar = make("ScrollingFrame", Main, {
    Name = "Sidebar",
    Position = UDim2.fromOffset(10, 62),
    Size = UDim2.new(0, 125, 1, -72),
    BackgroundColor3 = COLORS.Panel,
    BorderSizePixel = 0,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = COLORS.Blue,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    Active = true,
    ScrollingDirection = Enum.ScrollingDirection.Y,
})
addCorner(Sidebar, 11)
make("UIPadding", Sidebar, {
    PaddingTop = UDim.new(0, 9), PaddingLeft = UDim.new(0, 7),
    PaddingRight = UDim.new(0, 7), PaddingBottom = UDim.new(0, 8),
})
make("UIListLayout", Sidebar, {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder})

local ContentHost = make("Frame", Main, {
    Name = "ContentHost",
    Position = UDim2.fromOffset(145, 62),
    Size = UDim2.new(1, -155, 1, -72),
    BackgroundColor3 = COLORS.Panel,
    BorderSizePixel = 0,
    ClipsDescendants = true,
})
addCorner(ContentHost, 11)

local SearchBox = make("TextBox", ContentHost, {
    Name = "Search",
    Position = UDim2.fromOffset(10, 9),
    Size = UDim2.new(1, -20, 0, 32),
    BackgroundColor3 = COLORS.Panel2,
    BorderSizePixel = 0,
    ClearTextOnFocus = false,
    PlaceholderText = "Buscar opciones...",
    PlaceholderColor3 = COLORS.Muted,
    Text = "",
    TextColor3 = COLORS.Text,
    Font = Enum.Font.Gotham,
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
})
addCorner(SearchBox, 8)
make("UIPadding", SearchBox, {PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10)})

local PageHost = make("Frame", ContentHost, {
    Name = "PageHost",
    Position = UDim2.fromOffset(8, 49),
    Size = UDim2.new(1, -16, 1, -57),
    BackgroundTransparency = 1,
    ClipsDescendants = true,
})

local pageNames = {"Home", "ESP", "Jugador", "Farm", "Combate+", "Alertas", "Teleport", "Visuales", "Troleo", "Extras", "Bomb Jump", "Ajustes"}
local pages, navButtons = {}, {}
local activePageName = "Home"
local searchQuery = ""

local function refreshPageCanvas(page)
    if not page or not page.Scroll or not page.Layout then return end
    local contentHeight = page.Layout.AbsoluteContentSize.Y + 18
    local viewportHeight = page.Scroll.AbsoluteSize.Y
    page.Scroll.CanvasSize = UDim2.new(0, 0, 0, math.max(contentHeight, viewportHeight))
end

local function createPage(name)
    -- Use ordinary Frames instead of CanvasGroups. This avoids relying on
    -- GroupTransparency support in executor-rendered mobile interfaces.
    local group = make("Frame", PageHost, {
        Name = name,
        Size = UDim2.fromScale(1, 1),
        Position = UDim2.fromOffset(0, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Visible = false,
        ClipsDescendants = true,
        ZIndex = 1,
    })

    local scroll = make("ScrollingFrame", group, {
        Name = "Options",
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = COLORS.Blue,
        CanvasPosition = Vector2.zero,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.None,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        Active = true,
        ZIndex = 1,
    })

    make("UIPadding", scroll, {
        PaddingTop = UDim.new(0, 5),
        PaddingLeft = UDim.new(0, 5),
        PaddingRight = UDim.new(0, 7),
        PaddingBottom = UDim.new(0, 9),
    })

    local layout = make("UIListLayout", scroll, {
        Padding = UDim.new(0, 8),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })

    local emptyState = make("TextLabel", group, {
        Name = "NoSearchResults",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(1, -28, 0, 54),
        BackgroundTransparency = 1,
        Text = "No hay resultados.\nBorra la búsqueda para ver las opciones.",
        TextColor3 = COLORS.Muted,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextWrapped = true,
        Visible = false,
        ZIndex = 5,
    })

    local page = {
        Group = group,
        Scroll = scroll,
        Layout = layout,
        EmptyState = emptyState,
        FilterItems = {},
    }
    pages[name] = page

    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        refreshPageCanvas(page)
    end)
    scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        refreshPageCanvas(page)
    end)
end

for _, name in ipairs(pageNames) do
    createPage(name)
end

local function addFilterItem(pageName, object, searchText)
    local page = pages[pageName]
    if not page then return end
    table.insert(page.FilterItems, {
        Object = object,
        Text = string.lower(tostring(searchText or "")),
    })
    -- Force a canvas refresh after newly-created controls are measured.
    task.defer(function()
        if page.Group and page.Group.Parent then
            refreshPageCanvas(page)
        end
    end)
end

local function applySearch()
    local page = pages[activePageName]
    if not page then return end

    local query = string.lower(searchQuery or "")
    local matches = 0
    for _, item in ipairs(page.FilterItems) do
        local object = item.Object
        if object and object.Parent then
            local matched = query == ""
                or string.find(item.Text, query, 1, true) ~= nil
            object.Visible = matched
            if matched then matches += 1 end
        end
    end

    if page.EmptyState then
        page.EmptyState.Visible = query ~= "" and matches == 0
    end
    refreshPageCanvas(page)
    return matches
end

local function setActivePage(name)
    if not pages[name] then return end

    -- A search term from another category must not hide every option on this page.
    activePageName = name
    searchQuery = ""
    if SearchBox then
        SearchBox:ReleaseFocus()
        if SearchBox.Text ~= "" then
            SearchBox.Text = ""
        end
    end

    for pageName, page in pairs(pages) do
        page.Group.Visible = pageName == name
        page.Scroll.Visible = true
        if pageName == name then
            page.Scroll.CanvasPosition = Vector2.zero
        end
    end

    for pageName, button in pairs(navButtons) do
        local selected = pageName == name
        uiTween(button, 0.12, {
            BackgroundColor3 = selected and COLORS.BlueDark or COLORS.Panel2,
            TextColor3 = selected and COLORS.White or COLORS.Muted,
        })
    end

    applySearch()
    task.defer(function()
        local page = pages[name]
        if page and page.Group.Visible then
            refreshPageCanvas(page)
        end
    end)
end

-- Forward declaration: navigation callbacks are connected before the diagnostic
-- function is assigned. Without this local declaration, Lua captures a nil global
-- and every tab tap errors before setActivePage() can run.
local diagnosticCount = 0
local diagnosticStatusLabel = nil
local markControlPressed

for index, name in ipairs(pageNames) do
    local button = make("TextButton", Sidebar, {
        Name = "Nav_" .. name,
        Size = UDim2.new(1, 0, 0, 40),
        BackgroundColor3 = name == "Home" and COLORS.BlueDark or COLORS.Panel2,
        BorderSizePixel = 0,
        Text = name,
        TextColor3 = name == "Home" and COLORS.White or COLORS.Muted,
        Font = Enum.Font.GothamSemibold,
        TextSize = 13,
        AutoButtonColor = true,
        LayoutOrder = index,
        Active = true,
        ZIndex = 3,
    })
    addCorner(button, 8)
    navButtons[name] = button
    button.Activated:Connect(function()
        markControlPressed("Pestaña " .. name)
        setActivePage(name)
    end)
end

-- Home is visible on first load; every other page remains hidden.
for pageName, page in pairs(pages) do
    page.Group.Visible = pageName == "Home"
    page.Scroll.Visible = true
end

markControlPressed = function(controlName)
    diagnosticCount += 1
    if diagnosticStatusLabel and diagnosticStatusLabel.Parent then
        diagnosticStatusLabel.Text = "Toques detectados: " .. tostring(diagnosticCount) .. " | Último: " .. tostring(controlName)
    end
end

local function addSection(pageName, title)
    local row = make("TextLabel", pages[pageName].Scroll, {
        Name = "Section", Size = UDim2.new(1, -3, 0, 25),
        BackgroundTransparency = 1, Text = string.upper(title),
        TextColor3 = COLORS.Blue, Font = Enum.Font.GothamBold,
        TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
    })
    addFilterItem(pageName, row, title)
    return row
end

local function addLabel(pageName, value, height)
    local row = make("TextLabel", pages[pageName].Scroll, {
        Name = "Info", Size = UDim2.new(1, -3, 0, height or 42),
        BackgroundColor3 = COLORS.Panel2, BorderSizePixel = 0,
        Text = value, TextColor3 = COLORS.Muted, Font = Enum.Font.Gotham,
        TextSize = 11, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
    })
    addCorner(row, 9)
    make("UIPadding", row, {PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 8)})
    addFilterItem(pageName, row, value)
    return row
end

local toggleRenderers, toggleCallbacks = {}, {}
local scheduleAutoSave = nil
local function addToggle(pageName, title, stateKey, callback)
    local row = make("Frame", pages[pageName].Scroll, {
        Name = "Toggle_" .. stateKey, Size = UDim2.new(1, -3, 0, 50),
        BackgroundColor3 = COLORS.Panel2, BorderSizePixel = 0,
    })
    addCorner(row, 9)
    make("TextLabel", row, {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(11, 0),
        Size = UDim2.new(1, -72, 1, 0), Font = Enum.Font.GothamMedium,
        Text = title, TextColor3 = COLORS.Text, TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    local track = make("TextButton", row, {
        Name = "Switch", Position = UDim2.new(1, -53, 0.5, -11),
        Size = UDim2.fromOffset(42, 22), BackgroundColor3 = COLORS.Off,
        BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    })
    addCorner(track, 20)
    local knob = make("Frame", track, {
        Name = "Knob", Position = UDim2.fromOffset(3, 3),
        Size = UDim2.fromOffset(16, 16), BackgroundColor3 = COLORS.White,
        BorderSizePixel = 0,
    })
    addCorner(knob, 20)
    local function render(animate)
        local enabled = State[stateKey] == true
        local color = enabled and COLORS.Blue or COLORS.Off
        local position = enabled and UDim2.new(1, -19, 0, 3) or UDim2.fromOffset(3, 3)
        if animate then
            uiTween(track, 0.14, {BackgroundColor3 = color})
            uiTween(knob, 0.14, {Position = position})
        else
            track.BackgroundColor3 = color
            knob.Position = position
        end
    end
    toggleRenderers[stateKey] = render
    toggleCallbacks[stateKey] = callback
    track.Activated:Connect(function()
        markControlPressed(title)
        State[stateKey] = not State[stateKey]
        render(true)
        if callback then
            local ok, err = pcall(callback, State[stateKey])
            if not ok then
                warn("[Wxnnxrx] " .. tostring(err))
                notify("Error en " .. tostring(title), tostring(err):gsub("[\r\n]", " "):sub(1, 150))
            end
        end
        if scheduleAutoSave then scheduleAutoSave() end
    end)
    render(false)
    addFilterItem(pageName, row, title)
    return row
end

local function addButton(pageName, title, callback)
    local button = make("TextButton", pages[pageName].Scroll, {
        Name = "Button", Size = UDim2.new(1, -3, 0, 48),
        BackgroundColor3 = COLORS.Panel2, BorderSizePixel = 0,
        Text = title, TextColor3 = COLORS.Text, Font = Enum.Font.GothamMedium,
        TextSize = 14, AutoButtonColor = true,
    })
    addCorner(button, 9)
    button.Activated:Connect(function()
        markControlPressed(title)
        uiTween(button, 0.08, {BackgroundColor3 = COLORS.BlueDark})
        task.delay(0.09, function()
            if button.Parent then uiTween(button, 0.13, {BackgroundColor3 = COLORS.Panel2}) end
        end)
        if callback then
            local ok, err = pcall(callback)
            if not ok then
                warn("[Wxnnxrx] " .. tostring(err))
                notify("Error en " .. tostring(title), tostring(err):gsub("[\r\n]", " "):sub(1, 150))
            end
        end
    end)
    addFilterItem(pageName, button, title)
    return button
end

local function addInput(pageName, title, placeholder, defaultValue)
    local row = make("Frame", pages[pageName].Scroll, {
        Name = "InputRow", Size = UDim2.new(1, -3, 0, 72),
        BackgroundColor3 = COLORS.Panel2, BorderSizePixel = 0,
    })
    addCorner(row, 9)
    make("TextLabel", row, {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 4),
        Size = UDim2.new(1, -20, 0, 20), Font = Enum.Font.GothamMedium,
        Text = title, TextColor3 = COLORS.Text, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    local input = make("TextBox", row, {
        Position = UDim2.fromOffset(9, 30), Size = UDim2.new(1, -18, 0, 30),
        BackgroundColor3 = COLORS.Panel3, BorderSizePixel = 0,
        ClearTextOnFocus = false, PlaceholderText = placeholder or "Escribe aquí...",
        Text = defaultValue or "", TextColor3 = COLORS.Text,
        PlaceholderColor3 = COLORS.Muted, Font = Enum.Font.Gotham, TextSize = 14,
    })
    addCorner(input, 7)
    addFilterItem(pageName, row, title)
    return input
end

local function addInputButton(pageName, title, placeholder, defaultValue, buttonText, callback)
    local input = addInput(pageName, title, placeholder, defaultValue)
    local row = input.Parent
    input.Size = UDim2.new(0.48, -7, 0, 30)
    local action = make("TextButton", row, {
        Position = UDim2.new(0.52, 0, 0, 30), Size = UDim2.new(0.48, -9, 0, 30),
        BackgroundColor3 = COLORS.BlueDark, BorderSizePixel = 0,
        Text = buttonText, TextColor3 = COLORS.White, Font = Enum.Font.GothamBold,
        TextSize = 10, AutoButtonColor = false,
    })
    addCorner(action, 7)
    action.Activated:Connect(function()
        markControlPressed(title)
        if callback then
            local ok, err = pcall(callback, input.Text)
            if not ok then
                warn("[Wxnnxrx] " .. tostring(err))
                notify("Error en " .. tostring(title), tostring(err):gsub("[\r\n]", " "):sub(1, 150))
            end
        end
        if scheduleAutoSave then scheduleAutoSave() end
    end)
    return input
end


-- HOME
addSection("Home", "Bienvenido")
local homeBrand = make("Frame", pages.Home.Scroll, {
    Name = "BrandBlock", Size = UDim2.new(1, -3, 0, 112),
    BackgroundColor3 = COLORS.Panel2, BorderSizePixel = 0,
})
addCorner(homeBrand, 12)
addStroke(homeBrand, COLORS.Blue, 1, 0.65)
make("TextLabel", homeBrand, {
    BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.42, 0), Size = UDim2.new(1, -20, 0, 40),
    Font = Enum.Font.GothamBlack, Text = "WXNNXRX",
    TextColor3 = COLORS.Text, TextSize = 25,
})
make("TextLabel", homeBrand, {
    BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.72, 0), Size = UDim2.new(1, -20, 0, 20),
    Font = Enum.Font.GothamBold, Text = "HUB  2.6.4  •  INPUT FIX",
    TextColor3 = COLORS.Blue, TextSize = 12,
})
addFilterItem("Home", homeBrand, "Wxnnxrx Hub 2.6.3 Basic Test MM2")
local roleLabel = addLabel("Home", "Tu rol: comprobando...", 34)
local statusLabel = addLabel("Home", "Toques detectados: 0", 32)
diagnosticStatusLabel = statusLabel
addButton("Home", "Actualizar mi rol", function() roleLabel.Text = "Tu rol: " .. getRole(LocalPlayer) end)
addLabel("Home", "Wxnnxrx 2.6 • movimiento, ESP personalizable y herramientas móviles.", 44)
addToggle("Home", "Mostrar HUD compacto", "HUD", function(enabled) HUDFrame.Visible = enabled end)

-- ESP
addSection("ESP", "Jugadores")
addToggle("ESP", "Activar Player ESP", "PlayerESP")
addToggle("ESP", "Mostrar Murderer", "ESP_Murderer")
addToggle("ESP", "Mostrar Sheriff", "ESP_Sheriff")
addToggle("ESP", "Mostrar Innocent", "ESP_Innocent")
local innocentColorBox = addInputButton("ESP", "Color SOLO de Innocents (HEX)", "Ejemplo: #55DC87", "#" .. InnocentESPColorHex, "Aplicar", function(valueText)
    local candidate = string.gsub(tostring(valueText or ""), "#", "")
    if not string.match(candidate, "^%x%x%x%x%x%x$") then
        notify("Color de Innocents", "Usa un HEX válido de 6 dígitos, por ejemplo #55DC87.")
        return
    end
    InnocentESPColorHex = string.upper(candidate)
    notify("Color de Innocents", "Color personalizado aplicado solo al ESP de inocentes.")
end)
addToggle("ESP", "Mostrar nombres", "ESP_Name")
addToggle("ESP", "Mostrar distancia", "ESP_Distance")
addToggle("ESP", "Box ESP", "ESP_Box")
addToggle("ESP", "Tracers", "ESP_Tracers")
addSection("ESP", "Objetos")
addToggle("ESP", "Coin ESP", "CoinESP")
addToggle("ESP", "Dropped Gun ESP", "GunESP")

-- PLAYER
addSection("Jugador", "Movimiento")
addToggle("Jugador", "Fly", "Fly", function(enabled)
    if enabled then
        if not currentRoot then State.Fly = false; notify("Fly", "No se encontró tu personaje."); return end
        safeDestroy(flyVelocity); safeDestroy(flyGyro)
        flyVelocity = make("BodyVelocity", currentRoot, {
            Name = "WxnnxrxFlyVelocity", MaxForce = Vector3.new(100000, 100000, 100000),
            Velocity = Vector3.zero, P = 25000,
        })
        flyGyro = make("BodyGyro", currentRoot, {
            Name = "WxnnxrxFlyGyro", MaxTorque = Vector3.new(100000, 100000, 100000),
            P = 25000, CFrame = Camera.CFrame,
        })
        notify("Fly", "Activado. Usa el joystick y el botón de salto.")
    else
        safeDestroy(flyVelocity); flyVelocity = nil
        safeDestroy(flyGyro); flyGyro = nil
        notify("Fly", "Desactivado.")
    end
end)
addToggle("Jugador", "Noclip", "Noclip", function(enabled)
    if not enabled then
        for part, canCollide in pairs(savedCollisions) do
            if part and part.Parent then pcall(function() part.CanCollide = canCollide end) end
        end
        table.clear(savedCollisions)
    end
end)
addToggle("Jugador", "Infinite Jump", "InfiniteJump")
addToggle("Jugador", "Double Jump", "DoubleJump", function(enabled)
    notify("Double Jump", enabled and "Segundo salto en el aire activado." or "Desactivado.")
end)
local speedBox = addInputButton("Jugador", "WalkSpeed (0–100)", "Ejemplo: 28 o 12", tostring(appliedWalkSpeed or 28), "Aplicar", function(valueText)
    local value = tonumber(valueText)
    if value == nil then
        notify("WalkSpeed", "Escribe un número válido entre 0 y 100.")
        return
    end
    value = math.clamp(value, 0, 100)
    appliedWalkSpeed = value
    if currentHumanoid then currentHumanoid.WalkSpeed = value end
    notify("Jugador", "WalkSpeed aplicado: " .. tostring(value))
end)
local jumpBox = addInputButton("Jugador", "JumpPower (0–150)", "Ejemplo: 65 o 35", tostring(appliedJumpPower or 65), "Aplicar", function(valueText)
    local value = tonumber(valueText)
    if value == nil then
        notify("JumpPower", "Escribe un número válido entre 0 y 150.")
        return
    end
    value = math.clamp(value, 0, 150)
    appliedJumpPower = value
    if currentHumanoid then
        pcall(function() currentHumanoid.UseJumpPower = true end)
        currentHumanoid.JumpPower = value
    end
    notify("Jugador", "JumpPower aplicado: " .. tostring(value))
end)
addButton("Jugador", "Restaurar movimiento", function()
    appliedWalkSpeed = nil
    appliedJumpPower = nil
    if currentHumanoid then
        currentHumanoid.WalkSpeed = originalSpeed or 16
        pcall(function() currentHumanoid.JumpPower = originalJump or 50 end)
    end
    State.Fly = false; State.Noclip = false
    safeDestroy(flyVelocity); flyVelocity = nil
    safeDestroy(flyGyro); flyGyro = nil
    for part, canCollide in pairs(savedCollisions) do
        if part and part.Parent then pcall(function() part.CanCollide = canCollide end) end
    end
    table.clear(savedCollisions)
    notify("Jugador", "Movimiento restaurado.")
end)

-- FARM
local minimized = false
local FloatingShootButton
addSection("Farm", "Recolección")
addToggle("Farm", "Auto Farm Coins (experimental)", "AutoFarm", function(enabled)
    if enabled then notify("Auto Farm", "Experimental: el servidor decide si recoge las monedas.") end
end)
addToggle("Farm", "Ir hacia Dropped Gun (experimental)", "AutoGrabGun", function(enabled)
    if enabled then notify("Gun", "Se intentará acercar al arma caída si aparece.") end
end)
addToggle("Farm", "Auto Farm Candy (experimental)", "AutoFarmCandy", function(enabled)
    notify("Candy Farm", enabled and "Buscando caramelos visibles." or "Desactivado.")
end)

-- COMBAT
addSection("Combate+", "Combate • experimental")
addToggle("Combate+", "Silent Aim • Sheriff", "SilentAim")
addToggle("Combate+", "Knife Silent Aim • Murderer", "KnifeSilentAim")
addToggle("Combate+", "Auto Shoot • apunta al Murderer", "AutoShoot")
addToggle("Combate+", "Fast Shoot • auto-disparo rápido", "FastShoot")
addToggle("Combate+", "Kill Aura • cuchillo cercano", "KillAura")
addToggle("Combate+", "Kill All • intenta recorrer jugadores", "KillAll", function(enabled)
    if enabled then notify("Kill All", "Intento activado. Debes ser Murderer; el servidor puede bloquearlo.") end
end)
addToggle("Combate+", "Shoot Murderer • Sheriff", "ShootMurderer")
addToggle("Combate+", "Botón grande Shoot Murderer al minimizar", "FloatingShootButton", function(enabled)
    if FloatingShootButton then
        FloatingShootButton.Visible = enabled and minimized
    end
end)
addLabel("Combate+", "Los intentos de combate dependen del rol, del executor y de la validación del servidor MM2.", 52)

-- ALERTS
addSection("Alertas", "Detección de roles")
addToggle("Alertas", "Notificaciones inteligentes", "SmartNotifications")
addToggle("Alertas", "Notificar cuando cambia mi rol", "RoleAlerts")
addToggle("Alertas", "Avisar si Murderer está cerca", "NearMurdererAlert")

-- TELEPORT
addSection("Teleport", "Teletransporte local")
local targetBox = addInputButton("Teleport", "Nombre del jugador", "Nombre o parte del nombre", "", "Ir", function(queryText)
    local query = string.lower(queryText)
    if query == "" then notify("Teleport", "Escribe un nombre primero."); return end
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and string.find(string.lower(player.Name), query, 1, true) then
            local targetRoot = getRoot(player)
            if targetRoot and currentRoot then currentRoot.CFrame = targetRoot.CFrame * CFrame.new(0, 0, 3) end
            notify("Teleport", "Destino: " .. player.Name)
            return
        end
    end
    notify("Teleport", "No se encontró ese jugador.")
end)
local function teleportToRole(role)
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and getRole(player) == role then
            local targetRoot = getRoot(player)
            if targetRoot and currentRoot then currentRoot.CFrame = targetRoot.CFrame * CFrame.new(0, 0, 3) end
            return
        end
    end
    notify("Teleport", "No se detectó el rol solicitado.")
end
addButton("Teleport", "Teleport al Murderer", function() teleportToRole("MURDERER") end)
addButton("Teleport", "Teleport al Sheriff", function() teleportToRole("SHERIFF") end)
addButton("Teleport", "Teleport al arma caída", function()
    local gun = findDroppedGun()
    local pos = getObjectPosition(gun)
    if pos and currentRoot then currentRoot.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
    else notify("Teleport", "No se encontró un arma caída.") end
end)

-- VISUALS
addSection("Visuales", "Iluminación")
addToggle("Visuales", "FullBright", "FullBright", function(enabled)
    if enabled then
        Lighting.Brightness = 3; Lighting.ClockTime = 14; Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(190, 190, 190)
        Lighting.OutdoorAmbient = Color3.fromRGB(190, 190, 190)
    else
        for property, value in pairs(originalLighting) do pcall(function() Lighting[property] = value end) end
    end
end)
addToggle("Visuales", "Remove Fog", "RemoveFog", function(enabled)
    if enabled then Lighting.FogStart = 0; Lighting.FogEnd = 100000
    else
        Lighting.FogStart = originalLighting.FogStart
        Lighting.FogEnd = originalLighting.FogEnd
    end
end)
local fovBox = addInputButton("Visuales", "Camera FOV (50–120)", "Ejemplo: 85", "85", "Aplicar", function(valueText)
    local value = math.clamp(tonumber(valueText) or 70, 50, 120)
    if Camera then Camera.FieldOfView = value end
    notify("Visuales", "FOV aplicado: " .. value)
end)
addButton("Visuales", "Restaurar iluminación y FOV", function()
    for property, value in pairs(originalLighting) do pcall(function() Lighting[property] = value end) end
    if Camera then Camera.FieldOfView = originalFOV or 70 end
    State.FullBright = false; State.RemoveFog = false
end)

-- TROLLING
addSection("Troleo", "Espectador y movimiento")
local spectateBox = addInputButton("Troleo", "Jugador para espectar", "Nombre o parte del nombre", "", "Ver", function(queryText)
    local query = string.lower(queryText)
    if query == "" then notify("Spectate", "Escribe un nombre."); return end
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and string.find(string.lower(player.Name), query, 1, true) then
            local humanoid = getHumanoid(player)
            if humanoid and Camera then
                spectatingPlayer = player
                Camera.CameraSubject = humanoid
                State.Spectate = true
                notify("Spectate", "Ahora observas a " .. player.Name)
                return
            end
        end
    end
    notify("Spectate", "No se encontró un jugador válido.")
end)
addButton("Troleo", "Dejar de espectar", function()
    spectatingPlayer = nil; State.Spectate = false
    if Camera and currentHumanoid then Camera.CameraSubject = currentHumanoid end
    notify("Spectate", "Cámara restaurada.")
end)
addToggle("Troleo", "Spin Bot visual (local)", "SpinBot")

-- EXTRAS
addSection("Extras", "Utilidades")
addToggle("Extras", "Bunny Hop", "BunnyHop")
addToggle("Extras", "Speed Glitch (experimental)", "SpeedGlitch", function(enabled)
    if enabled then
        notify("Speed Glitch", "Impulso local activado. Puede ser limitado por el servidor.")
    else
        notify("Speed Glitch", "Impulso desactivado.")
    end
end)
addLabel("Extras", "Speed Glitch: usa la dirección del joystick móvil para aplicar un impulso local. No garantiza replicación en el servidor.", 42)
addToggle("Extras", "Wall Hop", "WallHop", function(enabled)
    notify("Wall Hop", enabled
        and "Activado. Pulsa el botón de salto cerca de una pared."
        or "Desactivado.")
end)
addToggle("Extras", "Modo Rendimiento • menos efectos", "PerformanceMode", function(enabled)
    setPerformanceMode(enabled)
    notify("Modo Rendimiento", enabled
        and "Efectos cosméticos y sombras locales reducidos."
        or "Se restauraron los efectos y sombras originales.")
end)
addLabel("Extras", "Reduce partículas y sombras para ayudar en móviles con tirones.", 30)
addToggle("Extras", "Anti-Fling", "AntiFling", function(enabled)
    notify("Anti-Fling", enabled
        and "Mitigación de velocidades físicas extremas activada."
        or "Desactivado.")
end)
addToggle("Extras", "Anti-Void", "AntiVoid", function(enabled)
    if enabled then
        lastSafeCFrame = nil
        lastSafeUpdate = 0
        notify("Anti-Void", "Guardando posiciones seguras para recuperarte de caídas.")
    else
        notify("Anti-Void", "Desactivado.")
    end
end)
addToggle("Extras", "Anti-AFK", "AntiAFK", function(enabled)
    if enabled then notify("Anti-AFK", "Activado durante esta sesión.") end
end)
addToggle("Extras", "Day Mode (iluminación local)", "DayMode", function(enabled)
    if enabled then Lighting.ClockTime = 14; Lighting.Brightness = 2
    else Lighting.ClockTime = originalLighting.ClockTime; Lighting.Brightness = originalLighting.Brightness end
end)
addButton("Extras", "Tercera persona", function()
    LocalPlayer.CameraMode = Enum.CameraMode.Classic
    LocalPlayer.CameraMinZoomDistance = 8
    LocalPlayer.CameraMaxZoomDistance = 18
    notify("Cámara", "Distancia de tercera persona ajustada.")
end)
addButton("Extras", "Restaurar cámara", function()
    LocalPlayer.CameraMinZoomDistance = 0.5
    LocalPlayer.CameraMaxZoomDistance = 128
    if Camera and currentHumanoid then Camera.CameraSubject = currentHumanoid end
    spectatingPlayer = nil; State.Spectate = false
end)

-- SETTINGS
addSection("Ajustes", "Interfaz")
addButton("Ajustes", "Ocultar / mostrar (RightControl)", function()
    Main.Visible = not Main.Visible
end)
addButton("Ajustes", "Rejoin servidor", function()
    notify("Rejoin", "Solicitando reconexión...")
    pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
end)
addButton("Ajustes", "Cerrar Wxnnxrx Hub", function()
    if shutdown then shutdown() end
end)

addSection("Ajustes", "Temas")
local themeIndex = savedThemeIndex or 1
local themes = {
    {name = "Azul", blue = Color3.fromRGB(35,125,255), dark = Color3.fromRGB(22,82,180)},
    {name = "Morado", blue = Color3.fromRGB(170,95,255), dark = Color3.fromRGB(105,55,180)},
    {name = "Rojo", blue = Color3.fromRGB(255,85,100), dark = Color3.fromRGB(170,45,65)},
    {name = "Verde", blue = Color3.fromRGB(65,210,145), dark = Color3.fromRGB(30,135,95)},
    {name = "Cian", blue = Color3.fromRGB(45,205,225), dark = Color3.fromRGB(20,125,155)},
}
local function applyTheme(index)
    themeIndex = math.clamp(math.floor(tonumber(index) or 1), 1, #themes)
    local theme = themes[themeIndex]
    COLORS.Blue, COLORS.BlueDark = theme.blue, theme.dark
    for _, object in ipairs(ScreenGui:GetDescendants()) do
        if object:IsA("UIStroke") then object.Color = COLORS.Blue end
        if object:IsA("ScrollingFrame") then object.ScrollBarImageColor3 = COLORS.Blue end
        if object:IsA("TextLabel") and (object.Name == "Title" or object.Name == "Section") then object.TextColor3 = COLORS.Blue end
    end
    local stroke = Main:FindFirstChildOfClass("UIStroke")
    if stroke then stroke.Color = COLORS.Blue end
    if HUDTitle then HUDTitle.TextColor3 = COLORS.Blue end
end
applyTheme(themeIndex)
addButton("Ajustes", "Cambiar tema / color", function()
    applyTheme(themeIndex % #themes + 1)
    notify("Tema", "Tema " .. themes[themeIndex].name .. " aplicado.")
    if scheduleAutoSave then scheduleAutoSave() end
end)

addSection("Ajustes", "Guardar y cargar")
local configProfileBox = addInput("Ajustes", "Nombre del perfil", "Ejemplo: Combate, Escape o Visual", "Principal")
local CONFIG_FILE = "WxnnxrxHub26_Config.json"
local PROFILE_FOLDER = "WxnnxrxHub26_Profiles"
local applyingConfig = false
local autoSaveQueued = false
local function buildConfigPayload()
    local payload = {Version = 1, ThemeIndex = themeIndex, WalkSpeedValue = appliedWalkSpeed,
        JumpPowerValue = appliedJumpPower, InnocentESPColorHex = InnocentESPColorHex}
    for key, value in pairs(State) do
        if type(value) == "boolean" then payload[key] = value end
    end
    return payload
end
local function encodeConfig()
    return game:GetService("HttpService"):JSONEncode(buildConfigPayload())
end
local function writeConfig(path)
    if type(writefile) ~= "function" then return false, "Este executor no ofrece writefile." end
    local ok, encoded = pcall(encodeConfig)
    if not ok then return false, "No se pudo convertir la configuración a JSON." end
    local saved, err = pcall(function() writefile(path, encoded) end)
    if not saved then return false, tostring(err) end
    return true
end
local function applyConfig(decoded)
    if type(decoded) ~= "table" then return false, "Archivo de configuración inválido." end
    applyingConfig = true
    for key, value in pairs(decoded) do
        if State[key] ~= nil and type(State[key]) == "boolean" and type(value) == "boolean" then
            State[key] = value
            if toggleRenderers[key] then toggleRenderers[key](false) end
            local callback = toggleCallbacks[key]
            if callback then pcall(callback, value) end
        end
    end
    if type(decoded.WalkSpeedValue) == "number" then
        appliedWalkSpeed = math.clamp(decoded.WalkSpeedValue, 0, 100)
        if speedBox and speedBox.Parent then speedBox.Text = tostring(appliedWalkSpeed) end
        if currentHumanoid then pcall(function() currentHumanoid.WalkSpeed = appliedWalkSpeed end) end
    end
    if type(decoded.JumpPowerValue) == "number" then
        appliedJumpPower = math.clamp(decoded.JumpPowerValue, 0, 150)
        if jumpBox and jumpBox.Parent then jumpBox.Text = tostring(appliedJumpPower) end
        if currentHumanoid then pcall(function() currentHumanoid.JumpPower = appliedJumpPower end) end
    end
    if type(decoded.InnocentESPColorHex) == "string" then
        local candidate = string.gsub(decoded.InnocentESPColorHex, "#", "")
        if string.match(candidate, "^%x%x%x%x%x%x$") then
            InnocentESPColorHex = string.upper(candidate)
            if innocentColorBox and innocentColorBox.Parent then innocentColorBox.Text = "#" .. InnocentESPColorHex end
        end
    end
    if type(decoded.ThemeIndex) == "number" then applyTheme(decoded.ThemeIndex) end
    applyingConfig = false
    return true
end
local function readConfig(path)
    if type(readfile) ~= "function" or type(isfile) ~= "function" then return false, "Este executor no ofrece readfile/isfile." end
    if not isfile(path) then return false, "No existe ese archivo de configuración." end
    local ok, decoded = pcall(function() return game:GetService("HttpService"):JSONDecode(readfile(path)) end)
    if not ok then return false, "El JSON está dañado o no es válido." end
    return applyConfig(decoded)
end
local function cleanProfileName(value)
    local name = tostring(value or ""):gsub("[^%w_%-]", "_"):sub(1, 28)
    if name == "" then return nil end
    return name
end
local function ensureProfileFolder()
    if type(makefolder) == "function" and type(isfolder) == "function" then
        if not isfolder(PROFILE_FOLDER) then pcall(function() makefolder(PROFILE_FOLDER) end) end
    end
    if type(isfolder) == "function" and not isfolder(PROFILE_FOLDER) then return false end
    return true
end
addButton("Ajustes", "Guardar configuración principal", function()
    local ok, err = writeConfig(CONFIG_FILE)
    notify("Configuración", ok and "Configuración principal guardada." or err)
end)
addButton("Ajustes", "Cargar configuración principal", function()
    local ok, err = readConfig(CONFIG_FILE)
    notify("Configuración", ok and "Configuración principal cargada." or err)
end)
addButton("Ajustes", "Guardar perfil con este nombre", function()
    local name = cleanProfileName(configProfileBox.Text)
    if not name then notify("Perfiles", "Escribe un nombre válido."); return end
    if not ensureProfileFolder() then notify("Perfiles", "Este executor no permite crear carpetas."); return end
    local ok, err = writeConfig(PROFILE_FOLDER .. "/" .. name .. ".json")
    notify("Perfiles", ok and ("Perfil '" .. name .. "' guardado.") or err)
end)
addButton("Ajustes", "Cargar perfil con este nombre", function()
    local name = cleanProfileName(configProfileBox.Text)
    if not name then notify("Perfiles", "Escribe el nombre del perfil."); return end
    local ok, err = readConfig(PROFILE_FOLDER .. "/" .. name .. ".json")
    notify("Perfiles", ok and ("Perfil '" .. name .. "' cargado.") or err)
end)
addButton("Ajustes", "Exportar configuración al portapapeles", function()
    if type(setclipboard) ~= "function" then notify("Exportar", "Tu executor no ofrece setclipboard."); return end
    local ok, encoded = pcall(encodeConfig)
    if not ok then notify("Exportar", "No se pudo generar el JSON."); return end
    local copied, copyError = pcall(setclipboard, encoded)
    if copied then notify("Exportar", "JSON copiado al portapapeles.")
    else notify("Exportar", "No se pudo copiar: " .. tostring(copyError)) end
end)
addInputButton("Ajustes", "Importar configuración (JSON)", "Pega aquí el JSON", "", "IMPORTAR", function(raw)
    local ok, decoded = pcall(function() return game:GetService("HttpService"):JSONDecode(raw) end)
    if not ok then notify("Importar", "JSON inválido."); return end
    local applied, err = applyConfig(decoded)
    notify("Importar", applied and "Configuración importada." or err)
end)
addButton("Ajustes", "Restaurar valores predeterminados", function()
    local defaults = {PlayerESP=false, ESP_Murderer=true, ESP_Sheriff=true, ESP_Innocent=true, ESP_Distance=true,
        CoinESP=false, GunESP=false, Fly=false, Noclip=false, InfiniteJump=false, DoubleJump=false,
        InfiniteWallHop=false, SpeedGlitch=false, FullBright=false, RemoveFog=false, AutoFarm=false,
        AutoGrabGun=false, RoleAlerts=true, NearMurdererAlert=true, AutoFarmCandy=false, SpinBot=false,
        BunnyHop=false, WallHop=false, PerformanceMode=false, HUD=true, ESP_Box=false, ESP_Tracers=false,
        ESP_Name=true, SmartNotifications=true, Spectate=false, DayMode=false, AntiAFK=false, AntiFling=false,
        AntiVoid=false, SilentAim=false, KnifeSilentAim=false, AutoShoot=false, FastShoot=false, KillAura=false,
        KillAll=false, ShootMurderer=false, FloatingShootButton=false, AutoSaveConfig=false}
    applyConfig(defaults)
    appliedWalkSpeed, appliedJumpPower = 16, 50
    if currentHumanoid then pcall(function() currentHumanoid.WalkSpeed = 16; currentHumanoid.JumpPower = 50 end) end
    InnocentESPColorHex = "55DC87"
    applyTheme(1)
    notify("Configuración", "Valores predeterminados restaurados.")
end)
addToggle("Ajustes", "Autoguardar cambios", "AutoSaveConfig", function(enabled)
    notify("Autoguardado", enabled and "Se guardarán los cambios automáticamente." or "Autoguardado desactivado.")
end)
addLabel("Ajustes", "Los archivos se guardan localmente. Se necesita writefile/readfile; los perfiles requieren además soporte de carpetas. No se usa DataStore del juego desde el cliente.", 56)
addLabel("Ajustes", "WXNNXRX HUB 2.6.2 • Configuración y perfiles", 30)
-- Apply callback-backed options restored from disk after the UI has registered them.
-- This keeps persisted toggles and their actual effects in sync on startup.
for stateKey, callback in pairs(toggleCallbacks) do
    if State[stateKey] == true and callback then
        local ok, err = pcall(callback, true)
        if not ok then warn("[Wxnnxrx] No se pudo restaurar " .. tostring(stateKey) .. ": " .. tostring(err)) end
    end
end

scheduleAutoSave = function()
    if applyingConfig or not State.AutoSaveConfig or autoSaveQueued then return end
    autoSaveQueued = true
    task.delay(1.2, function()
        autoSaveQueued = false
        if running and State.AutoSaveConfig then
            local ok, err = writeConfig(CONFIG_FILE)
            if not ok then warn("[Wxnnxrx] Autoguardado: " .. tostring(err)) end
        end
    end)
end

-- Live search filters only the current category.
SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
    searchQuery = SearchBox.Text or ""
    local matches = applySearch()
    local page = pages[activePageName]
    if page then
        page.Scroll.CanvasPosition = Vector2.zero
        refreshPageCanvas(page)
    end
    if searchQuery ~= "" and matches == 0 then
        SearchBox.PlaceholderText = "Sin resultados en esta categoría"
    else
        SearchBox.PlaceholderText = "Buscar opciones..."
    end
end)

-- Floating WX button and animated minimize / restore.
local getClosestCombatTarget
local tryShootTarget
local FloatingButton = make("TextButton", ScreenGui, {
    Name = "FloatingWX", AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -18, 1, -24), Size = UDim2.fromOffset(52, 52),
    BackgroundColor3 = COLORS.BlueDark, BorderSizePixel = 0, Text = "WX",
    TextColor3 = COLORS.White, Font = Enum.Font.GothamBlack, TextSize = 16,
    AutoButtonColor = false, Visible = false, ZIndex = 20,
})
addCorner(FloatingButton, 18)
addStroke(FloatingButton, COLORS.Blue, 1.4, 0.15)

FloatingShootButton = make("TextButton", ScreenGui, {
    Name = "FloatingShootMurderer", AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -18, 1, -88), Size = UDim2.fromOffset(190, 54),
    BackgroundColor3 = Color3.fromRGB(190, 48, 58), BorderSizePixel = 0,
    Text = "SHOOT MURDERER", TextColor3 = COLORS.White,
    Font = Enum.Font.GothamBlack, TextSize = 14,
    AutoButtonColor = true, Visible = false, ZIndex = 21,
})
addCorner(FloatingShootButton, 15)
addStroke(FloatingShootButton, Color3.fromRGB(255, 115, 125), 1.5, 0.08)
FloatingShootButton.Activated:Connect(function()
    markControlPressed("Botón flotante de disparo")
    if getRole(LocalPlayer) ~= "SHERIFF" then
        notify("Shoot Murderer", "Debes tener el rol Sheriff para disparar.")
        return
    end
    local target = getClosestCombatTarget and getClosestCombatTarget("MURDERER", true)
    if not target then
        notify("Shoot Murderer", "No se detecta al Murderer en pantalla.")
        return
    end
    if tryShootTarget then
        local fired = tryShootTarget(target)
        if not fired then notify("Shoot Murderer", "No se pudo disparar; revisa tu arma y el alcance.") end
    end
end)

local function openPanel()
    Main.Visible = true
    FloatingButton.Visible = false
    FloatingShootButton.Visible = false
    minimized = false
    MainScale.Scale = 0.88
    uiTween(MainScale, 0.22, {Scale = 1}, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
end
local function minimizePanel()
    if minimized then return end
    minimized = true
    uiTween(MainScale, 0.12, {Scale = 0.9})
    task.delay(0.12, function()
        if minimized then
            Main.Visible = false
            FloatingButton.Visible = true
            FloatingShootButton.Visible = State.FloatingShootButton == true
        end
    end)
end
MinButton.Activated:Connect(function() markControlPressed("Minimizar"); minimizePanel() end)
FloatingButton.Activated:Connect(function() markControlPressed("Abrir panel"); openPanel() end)
CloseButton.Activated:Connect(function()
    Main.Visible = false
    minimized = true
    FloatingButton.Visible = true
    FloatingShootButton.Visible = State.FloatingShootButton == true
end)

-- Drag from header only; keep the original touch InputObject until it is released.
local dragging = false
local dragStart = nil
local startPosition = nil
local dragInput = nil
local dragMode = nil

local function pointerOver(object, point)
    local pos, size = object.AbsolutePosition, object.AbsoluteSize
    return point.X >= pos.X and point.X <= pos.X + size.X
        and point.Y >= pos.Y and point.Y <= pos.Y + size.Y
end

local function movePanelTo(point)
    if not dragging or not dragStart or not startPosition then return end
    local delta = point - dragStart
    Main.Position = UDim2.new(
        startPosition.X.Scale, startPosition.X.Offset + delta.X,
        startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
    )
end

Header.InputBegan:Connect(function(input)
    local inputType = input.UserInputType
    if inputType ~= Enum.UserInputType.MouseButton1
        and inputType ~= Enum.UserInputType.Touch then
        return
    end

    if pointerOver(MinButton, input.Position) or pointerOver(CloseButton, input.Position) then
        return
    end

    dragging = true
    dragStart = input.Position
    startPosition = Main.Position
    dragInput = input
    dragMode = inputType == Enum.UserInputType.Touch and "Touch" or "Mouse"
end)

UserInputService.InputChanged:Connect(function(input)
    if not dragging then return end

    if dragMode == "Mouse" and input.UserInputType == Enum.UserInputType.MouseMovement then
        movePanelTo(input.Position)
    elseif dragMode == "Touch" and input.UserInputType == Enum.UserInputType.Touch then
        -- On touch devices Roblox may report the updated touch as either the
        -- original InputObject or another Touch update. A single active drag
        -- is allowed, so only touch movement is used while that drag is held.
        movePanelTo(input.Position)
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if not dragging then return end
    if input == dragInput
        or (dragMode == "Mouse" and input.UserInputType == Enum.UserInputType.MouseButton1)
        or (dragMode == "Touch" and input.UserInputType == Enum.UserInputType.Touch) then
        dragging = false
        dragStart = nil
        startPosition = nil
        dragInput = nil
        dragMode = nil
    end
end)

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.RightControl then
        if Main.Visible then minimizePanel() else openPanel() end
    end
end)

openPanel()
task.defer(function()
    if running and ScreenGui and ScreenGui.Parent then
        notify("Wxnnxrx Hub 2.6.2", "Interfaz lista. Usa las pestañas para ver las opciones.")
    end
end)

--// Infinite jump + Wall Hop (supports keyboard and the mobile jump button)
local lastWallHopAt = 0
local WALL_HOP_COOLDOWN = 0.22
local INFINITE_WALL_HOP_COOLDOWN = 0.12
local wallHopCooldown = WALL_HOP_COOLDOWN
local WALL_HOP_DISTANCE = 3.1
local WALL_HOP_UP_SPEED = 38
local WALL_HOP_PUSH_SPEED = 25

local wallHopRaycastParams = RaycastParams.new()
wallHopRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
wallHopRaycastParams.IgnoreWater = true

local function attemptWallHop()
    if not running or not (State.WallHop or State.InfiniteWallHop) then return end
    if not currentCharacter or not currentCharacter.Parent then return end
    if not currentHumanoid or currentHumanoid.Health <= 0 then return end
    if not currentRoot or not currentRoot.Parent then return end

    local now = os.clock()
    wallHopCooldown = State.InfiniteWallHop and INFINITE_WALL_HOP_COOLDOWN or WALL_HOP_COOLDOWN
    if now - lastWallHopAt < wallHopCooldown then return end

    wallHopRaycastParams.FilterDescendantsInstances = {currentCharacter}

    local rootCFrame = currentRoot.CFrame
    local moveDirection = currentHumanoid.MoveDirection
    local directions = {}

    if moveDirection.Magnitude > 0.05 then
        table.insert(directions, moveDirection.Unit)
    end
    table.insert(directions, rootCFrame.LookVector)
    table.insert(directions, -rootCFrame.LookVector)
    table.insert(directions, rootCFrame.RightVector)
    table.insert(directions, -rootCFrame.RightVector)

    local origin = currentRoot.Position + Vector3.new(0, 0.25, 0)
    local wallResult = nil

    for _, direction in ipairs(directions) do
        local result = workspace:Raycast(
            origin,
            direction * WALL_HOP_DISTANCE,
            wallHopRaycastParams
        )

        if result and math.abs(result.Normal.Y) <= 0.25 then
            local hit = result.Instance
            local isSolid = hit == workspace.Terrain
                or (hit:IsA("BasePart") and hit.CanCollide)
            if isSolid then
                wallResult = result
                break
            end
        end
    end

    if not wallResult then return end

    local normal = wallResult.Normal
    local velocity = currentRoot.AssemblyLinearVelocity
    local horizontalPush = Vector3.new(normal.X, 0, normal.Z) * WALL_HOP_PUSH_SPEED
    currentRoot.AssemblyLinearVelocity = Vector3.new(
        velocity.X + horizontalPush.X,
        math.max(velocity.Y, WALL_HOP_UP_SPEED),
        velocity.Z + horizontalPush.Z
    )

    lastWallHopAt = now
    pcall(function()
        currentHumanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    end)
end

local doubleJumpUsed = false
local function bindDoubleJumpReset(humanoid)
    doubleJumpUsed = false
    if not humanoid then return end
    humanoid.StateChanged:Connect(function(_, newState)
        if newState == Enum.HumanoidStateType.Landed
            or newState == Enum.HumanoidStateType.Running
            or newState == Enum.HumanoidStateType.RunningNoPhysics then
            doubleJumpUsed = false
        end
    end)
end
bindDoubleJumpReset(currentHumanoid)

UserInputService.JumpRequest:Connect(function()
    if not running or not currentHumanoid then return end

    local humanoidState = currentHumanoid:GetState()
    local airborne = humanoidState == Enum.HumanoidStateType.Freefall
        or humanoidState == Enum.HumanoidStateType.Jumping
        or humanoidState == Enum.HumanoidStateType.FallingDown

    if State.InfiniteJump then
        pcall(function() currentHumanoid:ChangeState(Enum.HumanoidStateType.Jumping) end)
    elseif State.DoubleJump and airborne and not doubleJumpUsed then
        doubleJumpUsed = true
        pcall(function()
            currentHumanoid:ChangeState(Enum.HumanoidStateType.Jumping)
            if currentRoot then
                local velocity = currentRoot.AssemblyLinearVelocity
                currentRoot.AssemblyLinearVelocity = Vector3.new(velocity.X, math.max(velocity.Y, 42), velocity.Z)
            end
        end)
    end

    -- Roblox JumpRequest también detecta el botón de salto táctil.
    if State.WallHop or State.InfiniteWallHop then
        local ok, err = pcall(attemptWallHop)
        if not ok then warn("[Wxnnxrx] Wall Hop: " .. tostring(err)) end
    end
end)

--// Character refresh
LocalPlayer.CharacterAdded:Connect(function(character)
    currentCharacter = character
    currentHumanoid = character:WaitForChild("Humanoid", 10)
    currentRoot = character:WaitForChild("HumanoidRootPart", 10)
    bindDoubleJumpReset(currentHumanoid)
    lastSafeCFrame = nil
    lastSafeUpdate = 0
    if currentHumanoid then
        originalSpeed = currentHumanoid.WalkSpeed
        pcall(function() originalJump = currentHumanoid.JumpPower end)
        if appliedWalkSpeed ~= nil then
            pcall(function() currentHumanoid.WalkSpeed = appliedWalkSpeed end)
        end
        if appliedJumpPower ~= nil then
            pcall(function()
                currentHumanoid.UseJumpPower = true
                currentHumanoid.JumpPower = appliedJumpPower
            end)
        end
    end
    safeDestroy(flyVelocity); flyVelocity = nil
    safeDestroy(flyGyro); flyGyro = nil
    if State.Fly and currentRoot then
        flyVelocity = make("BodyVelocity", currentRoot, {Name = "WxnnxrxFlyVelocity", MaxForce = Vector3.new(100000,100000,100000), Velocity = Vector3.zero, P = 25000})
        flyGyro = make("BodyGyro", currentRoot, {Name = "WxnnxrxFlyGyro", MaxTorque = Vector3.new(100000,100000,100000), P = 25000, CFrame = Camera.CFrame})
    end
end)

--// Save initial values
if currentHumanoid then
    originalSpeed = currentHumanoid.WalkSpeed
    pcall(function() originalJump = currentHumanoid.JumpPower end)
    if appliedWalkSpeed ~= nil then
        pcall(function() currentHumanoid.WalkSpeed = appliedWalkSpeed end)
    end
    if appliedJumpPower ~= nil then
        pcall(function()
            currentHumanoid.UseJumpPower = true
            currentHumanoid.JumpPower = appliedJumpPower
        end)
    end
end
if Camera then originalFOV = Camera.FieldOfView end

--// ESP cleanup helpers
local function clearPlayerESP(player)
    local bundle = ESPObjects[player]
    if bundle then
        safeDestroy(bundle.highlight)
        safeDestroy(bundle.billboard)
        safeDestroy(bundle.box)
        safeDestroy(bundle.tracer)
        ESPObjects[player] = nil
    end
end

local function updatePlayerESP(player)
    if player == LocalPlayer then return end
    if not (State.PlayerESP or State.ESP_Box or State.ESP_Tracers) then clearPlayerESP(player); return end
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local head = character and character:FindFirstChild("Head")
    if not character or not root or not head then clearPlayerESP(player); return end

    local role = getRole(player)
    local allowed = (role == "MURDERER" and State.ESP_Murderer)
        or (role == "SHERIFF" and State.ESP_Sheriff)
        or (role == "INNOCENT" and State.ESP_Innocent)
    if not allowed then clearPlayerESP(player); return end

    local bundle = ESPObjects[player]
    if not bundle or bundle.character ~= character then
        clearPlayerESP(player)
        local highlight = make("Highlight", character, {
            Name = "WxnnxrxPlayerESP", Adornee = character,
            FillColor = roleColor(role), OutlineColor = roleColor(role),
            FillTransparency = 0.88, OutlineTransparency = 0.05,
            DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
        })
        local billboard = make("BillboardGui", character, {
            Name = "WxnnxrxRoleESP", Adornee = head, AlwaysOnTop = true,
            Size = UDim2.fromOffset(190, 34), StudsOffset = Vector3.new(0, 2.5, 0),
        })
        local label = make("TextLabel", billboard, {
            Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
            TextColor3 = roleColor(role), TextStrokeTransparency = 0.25,
            Font = Enum.Font.GothamBold, TextSize = 12,
            Text = player.Name .. " • " .. role,
        })
        local box = make("BoxHandleAdornment", workspace, {
            Name = "WxnnxrxBoxESP", Adornee = root, AlwaysOnTop = true,
            ZIndex = 10, Size = Vector3.new(4.2, 6.2, 2.4),
            Color3 = roleColor(role), Transparency = 0.35,
        })
        local tracer = make("Frame", ScreenGui, {
            Name = "WxnnxrxTracer", AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.fromOffset(0, 0), Size = UDim2.fromOffset(1, 2),
            BackgroundColor3 = roleColor(role), BorderSizePixel = 0,
            Visible = false, ZIndex = 15,
        })
        bundle = {highlight = highlight, billboard = billboard, label = label,
            box = box, tracer = tracer, character = character}
        ESPObjects[player] = bundle
    end

    local color = roleColor(role)
    bundle.highlight.FillColor = color
    bundle.highlight.OutlineColor = color
    bundle.box.Color3 = color
    bundle.box.Adornee = root
    bundle.box.Visible = State.ESP_Box
    bundle.tracer.Visible = false
    if State.ESP_Tracers and Camera then
        local viewport, onScreen = Camera:WorldToViewportPoint(root.Position)
        if onScreen and viewport.Z > 0 then
            local origin = Vector2.new(Camera.ViewportSize.X * 0.5, Camera.ViewportSize.Y - 4)
            local target = Vector2.new(viewport.X, viewport.Y)
            local diff = target - origin
            bundle.tracer.Position = UDim2.fromOffset(origin.X, origin.Y)
            bundle.tracer.Size = UDim2.fromOffset(diff.Magnitude, 2)
            bundle.tracer.Rotation = math.deg(math.atan2(diff.Y, diff.X))
            bundle.tracer.BackgroundColor3 = color
            bundle.tracer.Visible = true
        end
    end
    local distanceText = ""
    if State.ESP_Distance and currentRoot then
        distanceText = " • " .. tostring(math.floor((root.Position - currentRoot.Position).Magnitude)) .. "m"
    end
    local nameText = State.ESP_Name and player.Name or "JUGADOR"
    bundle.label.Text = nameText .. " • " .. role .. distanceText
    bundle.label.Visible = State.PlayerESP
    bundle.highlight.Enabled = State.PlayerESP
    bundle.label.TextColor3 = color
end

local function clearObjectESP(storage)
    for object, gui in pairs(storage) do
        safeDestroy(gui)
        storage[object] = nil
    end
end

--// Combat helpers: all actions are best-effort client interactions.
local CombatFOV = 850
local CombatMeleeRange = 17
local CombatPrediction = 0.12
local lastGunAction = 0
local lastKnifeAction = 0
local nextKillAllAt = 0
local killAllBusy = false
local CombatMouse = nil
pcall(function() CombatMouse = LocalPlayer:GetMouse() end)

local function isAliveTarget(player)
    if not player or player == LocalPlayer then return false end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    return character ~= nil and humanoid ~= nil and humanoid.Health > 0 and root ~= nil
end

local function getAimPart(player)
    local character = player and player.Character
    if not character then return nil end
    return character:FindFirstChild("Head")
        or character:FindFirstChild("UpperTorso")
        or character:FindFirstChild("HumanoidRootPart")
end

local function getPredictedPosition(player)
    local part = getAimPart(player)
    if not part then return nil end
    local root = getRoot(player)
    local velocity = root and root.AssemblyLinearVelocity or Vector3.zero
    return part.Position + velocity * CombatPrediction
end

getClosestCombatTarget = function(roleFilter, requireOnScreen)
    if not Camera then Camera = workspace.CurrentCamera end
    if not Camera then return nil end
    local center = Vector2.new(Camera.ViewportSize.X * 0.5, Camera.ViewportSize.Y * 0.5)
    local bestPlayer, bestDistance = nil, CombatFOV
    for _, player in ipairs(Players:GetPlayers()) do
        if isAliveTarget(player) and (not roleFilter or getRole(player) == roleFilter) then
            local part = getAimPart(player)
            if part then
                local screen, onScreen = Camera:WorldToViewportPoint(part.Position)
                if onScreen or not requireOnScreen then
                    local distance = (Vector2.new(screen.X, screen.Y) - center).Magnitude
                    if distance < bestDistance then
                        bestDistance = distance
                        bestPlayer = player
                    end
                end
            end
        end
    end
    return bestPlayer, bestDistance
end

local function getClosestPlayerByWorldDistance(maxRange)
    local bestPlayer, bestDistance = nil, maxRange or math.huge
    if not currentRoot then return nil end
    for _, player in ipairs(Players:GetPlayers()) do
        if isAliveTarget(player) then
            local root = getRoot(player)
            if root then
                local distance = (root.Position - currentRoot.Position).Magnitude
                if distance < bestDistance then
                    bestPlayer, bestDistance = player, distance
                end
            end
        end
    end
    return bestPlayer, bestDistance
end

local function equipCombatTool(keyword)
    local tool = findTool(LocalPlayer, keyword)
    if not tool then return nil end
    if tool.Parent ~= currentCharacter and currentHumanoid then
        pcall(function() currentHumanoid:EquipTool(tool) end)
        task.wait(0.05)
    end
    return tool
end

local function tryKnifeOnTarget(target, allowTeleport)
    if getRole(LocalPlayer) ~= "MURDERER" or not isAliveTarget(target) then return false end
    local character = target.Character
    local targetRoot = getRoot(target)
    local myRoot = currentRoot
    if not (character and targetRoot and myRoot and myRoot.Parent) then return false end
    if character:FindFirstChildOfClass("ForceField") then return false end

    local knife = equipCombatTool("knife")
    if not knife then return false end

    local distance = (targetRoot.Position - myRoot.Position).Magnitude
    if allowTeleport and distance > 10 then
        pcall(function()
            myRoot.CFrame = targetRoot.CFrame * CFrame.new(0, 0, 2.4)
        end)
        task.wait(0.06)
        distance = (targetRoot.Position - myRoot.Position).Magnitude
    end
    if distance > CombatMeleeRange then return false end

    local handle = knife:FindFirstChild("Handle") or knife:FindFirstChildWhichIsA("BasePart", true)
    local fired = false
    pcall(function()
        knife:Activate()
        fired = true
    end)
    if handle and typeof(firetouchinterest) == "function" then
        pcall(function()
            firetouchinterest(targetRoot, handle, 0)
            firetouchinterest(targetRoot, handle, 1)
            fired = true
        end)
    end

    -- Compatibility fallback for MM2 builds exposing the older knife Events folder.
    local events = knife:FindFirstChild("Events")
    local stabRemote = events and events:FindFirstChild("KnifeStabbed")
    local touchRemote = events and events:FindFirstChild("HandleTouched")
    if stabRemote and stabRemote:IsA("RemoteEvent") then
        pcall(function()
            stabRemote:FireServer()
            if touchRemote and touchRemote:IsA("RemoteEvent") then
                touchRemote:FireServer(targetRoot)
            end
            fired = true
        end)
    end
    return fired
end

tryShootTarget = function(target)
    if getRole(LocalPlayer) ~= "SHERIFF" or not isAliveTarget(target) then return false end
    local gun = equipCombatTool("gun")
    if not gun then return false end
    local now = os.clock()
    local delay = State.FastShoot and 0.12 or 0.28
    if now - lastGunAction < delay then return false end
    lastGunAction = now
    local fired = false
    pcall(function()
        gun:Activate()
        fired = true
    end)
    return fired
end

-- Optional executor hooks: redirect only the game's own aim reads / combat calls.
local CombatHooksInstalled = false
local function installCombatHooks()
    if CombatHooksInstalled then return end
    if type(hookmetamethod) ~= "function" or type(newcclosure) ~= "function" then
        return
    end
    CombatHooksInstalled = true

    pcall(function()
        local oldIndex
        oldIndex = hookmetamethod(game, "__index", newcclosure(function(self, key)
            if self == CombatMouse and key == "Hit" then
                if State.SilentAim and getRole(LocalPlayer) == "SHERIFF" then
                    local target = getClosestCombatTarget("MURDERER", true)
                    local position = target and getPredictedPosition(target)
                    if position then return CFrame.new(position) end
                elseif State.KnifeSilentAim and getRole(LocalPlayer) == "MURDERER" then
                    local target = getClosestCombatTarget(nil, true)
                    local position = target and getPredictedPosition(target)
                    if position then return CFrame.new(position) end
                end
            elseif self == CombatMouse and key == "Target" then
                if State.SilentAim and getRole(LocalPlayer) == "SHERIFF" then
                    local target = getClosestCombatTarget("MURDERER", true)
                    local part = target and getAimPart(target)
                    if part then return part end
                elseif State.KnifeSilentAim and getRole(LocalPlayer) == "MURDERER" then
                    local target = getClosestCombatTarget(nil, true)
                    local part = target and getAimPart(target)
                    if part then return part end
                end
            end
            return oldIndex(self, key)
        end))
    end)

    pcall(function()
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
            local method = ""
            pcall(function() method = getnamecallmethod() end)
            local args = table.pack(...)
            local isInternalCall = false
            if type(checkcaller) == "function" then
                pcall(function() isInternalCall = checkcaller() end)
            end
            if not isInternalCall and typeof(self) == "Instance" then
                local remoteName = string.lower(self.Name)
                local aimPosition = nil
                if State.SilentAim and getRole(LocalPlayer) == "SHERIFF"
                    and (method == "InvokeServer" or method == "FireServer")
                    and (remoteName == "shootgun" or remoteName == "shootstart" or remoteName == "shoot") then
                    local target = getClosestCombatTarget("MURDERER", true)
                    aimPosition = target and getPredictedPosition(target)
                    if aimPosition then
                        if remoteName == "shootgun" and typeof(args[2]) == "Vector3" then
                            args[2] = aimPosition
                        elseif remoteName == "shootgun" and typeof(args[2]) == "CFrame" then
                            args[2] = CFrame.new(aimPosition)
                        else
                            for index = args.n, 1, -1 do
                                if typeof(args[index]) == "Vector3" then
                                    args[index] = aimPosition
                                    break
                                elseif typeof(args[index]) == "CFrame" then
                                    args[index] = CFrame.new(aimPosition)
                                    break
                                end
                            end
                        end
                    end
                elseif State.KnifeSilentAim and getRole(LocalPlayer) == "MURDERER"
                    and (method == "InvokeServer" or method == "FireServer")
                    and (string.find(remoteName, "throw", 1, true)
                        or string.find(remoteName, "flingknife", 1, true)) then
                    local target = getClosestCombatTarget(nil, true)
                    aimPosition = target and getPredictedPosition(target)
                    if aimPosition then
                        for index = 1, args.n do
                            if typeof(args[index]) == "Vector3" then
                                args[index] = aimPosition
                                break
                            elseif typeof(args[index]) == "CFrame" then
                                args[index] = CFrame.new(aimPosition)
                                break
                            end
                        end
                    end
                end
            end
            return oldNamecall(self, table.unpack(args, 1, args.n))
        end))
    end)
end

installCombatHooks()

local function runCombatAutomation()
    local now = os.clock()
    if State.KillAll and not killAllBusy and now >= nextKillAllAt then
        if getRole(LocalPlayer) ~= "MURDERER" then
            nextKillAllAt = now + 1.5
        else
            killAllBusy = true
            nextKillAllAt = now + 1.1
            task.spawn(function()
                local returnCFrame = currentRoot and currentRoot.CFrame
                for _, target in ipairs(Players:GetPlayers()) do
                    if not running or not State.KillAll then break end
                    if target ~= LocalPlayer and isAliveTarget(target) then
                        tryKnifeOnTarget(target, true)
                        task.wait(0.18)
                    end
                end
                if currentRoot and currentRoot.Parent and returnCFrame then
                    pcall(function() currentRoot.CFrame = returnCFrame end)
                end
                killAllBusy = false
            end)
        end
    end

    if State.KillAura and getRole(LocalPlayer) == "MURDERER" and now - lastKnifeAction >= 0.22 then
        local target = getClosestPlayerByWorldDistance(CombatMeleeRange)
        if target then
            local myRoot = currentRoot
            local targetRoot = getRoot(target)
            if myRoot and targetRoot and (targetRoot.Position - myRoot.Position).Magnitude <= CombatMeleeRange then
                lastKnifeAction = now
                tryKnifeOnTarget(target, false)
            end
        end
    end

    if (State.AutoShoot or State.FastShoot or State.ShootMurderer) and getRole(LocalPlayer) == "SHERIFF" then
        local target = getClosestCombatTarget("MURDERER", true)
        if target then tryShootTarget(target) end
    end
end

shutdown = function()
    if not running then return end
    if State.PerformanceMode then
        State.PerformanceMode = false
        setPerformanceMode(false)
    end
    running = false
    State.Fly = false
    State.Noclip = false
    State.SpeedGlitch = false
    State.AutoFarm = false
    State.AutoGrabGun = false
    State.AutoFarmCandy = false
    State.SpinBot = false
    State.BunnyHop = false
    State.WallHop = false
    State.InfiniteWallHop = false
    State.DoubleJump = false
    State.Spectate = false
    State.AntiAFK = false
    State.AntiFling = false
    State.AntiVoid = false
    State.DayMode = false
    State.SilentAim = false
    State.KnifeSilentAim = false
    State.AutoShoot = false
    State.FastShoot = false
    State.KillAura = false
    State.KillAll = false
    State.ShootMurderer = false
    State.FloatingShootButton = false
    safeDestroy(flyVelocity); flyVelocity = nil
    safeDestroy(flyGyro); flyGyro = nil
    for part, canCollide in pairs(savedCollisions) do
        if part and part.Parent then pcall(function() part.CanCollide = canCollide end) end
    end
    table.clear(savedCollisions)
    if currentHumanoid then
        pcall(function() currentHumanoid.WalkSpeed = originalSpeed or 16 end)
        pcall(function() currentHumanoid.JumpPower = originalJump or 50 end)
    end
    for _, bundle in pairs(ESPObjects) do
        safeDestroy(bundle.highlight)
        safeDestroy(bundle.billboard)
        safeDestroy(bundle.box)
        safeDestroy(bundle.tracer)
    end
    table.clear(ESPObjects)
    clearObjectESP(CoinObjects)
    clearObjectESP(GunObjects)
    for property, value in pairs(originalLighting) do
        pcall(function() Lighting[property] = value end)
    end
    if Camera then pcall(function() Camera.FieldOfView = originalFOV or 70 end) end
    safeDestroy(ScreenGui)
end

local function updateObjectESP(object, storage, name, color)
    local adornee = getObjectAdornee(object)
    if not adornee then
        safeDestroy(storage[object]); storage[object] = nil
        return
    end
    if not storage[object] then
        local billboard = make("BillboardGui", ScreenGui, {
            Name = name,
            Adornee = adornee,
            AlwaysOnTop = true,
            Size = UDim2.fromOffset(110, 25),
        })
        make("TextLabel", billboard, {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Text = name,
            TextColor3 = color,
            TextStrokeTransparency = 0.2,
            Font = Enum.Font.GothamBold,
            TextSize = 11,
        })
        storage[object] = billboard
    else
        storage[object].Adornee = adornee
    end
end

--// Main update loop: ESP, movement and alerts
task.spawn(function()
    local lastESPUpdate = 0
    local lastStatusUpdate = 0
    while running do
        local delta = RunService.Heartbeat:Wait()
        if currentCharacter and currentCharacter.Parent then
            currentHumanoid = currentCharacter:FindFirstChildOfClass("Humanoid")
            currentRoot = currentCharacter:FindFirstChild("HumanoidRootPart")
        end

        if State.Fly and currentRoot and currentHumanoid and flyVelocity and flyGyro then
            local move = currentHumanoid.MoveDirection * 55
            local vertical = 0
            if UserInputService:IsKeyDown(Enum.KeyCode.Space) or currentHumanoid.Jump then vertical = 42 end
            if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then vertical = -42 end
            flyVelocity.Velocity = Vector3.new(move.X, vertical, move.Z)
            if Camera then flyGyro.CFrame = Camera.CFrame end
        end

        if State.Noclip and currentCharacter then
            for _, part in ipairs(currentCharacter:GetDescendants()) do
                if part:IsA("BasePart") then
                    if savedCollisions[part] == nil then savedCollisions[part] = part.CanCollide end
                    part.CanCollide = false
                end
            end
        end

        -- Experimental local speed-glitch approximation. Uses MoveDirection, so
        -- the mobile joystick works; the server may clamp or reject the velocity.
        if State.SpeedGlitch and currentHumanoid and currentRoot and currentRoot.Parent then
            local direction = currentHumanoid.MoveDirection
            if direction.Magnitude > 0.08 then
                local flatDirection = Vector3.new(direction.X, 0, direction.Z)
                if flatDirection.Magnitude > 0.01 then
                    local currentVelocity = currentRoot.AssemblyLinearVelocity
                    local targetSpeed = math.max(32, currentHumanoid.WalkSpeed)
                    local targetVelocity = flatDirection.Unit * targetSpeed
                    local blend = 0.32
                    currentRoot.AssemblyLinearVelocity = Vector3.new(
                        currentVelocity.X + (targetVelocity.X - currentVelocity.X) * blend,
                        currentVelocity.Y,
                        currentVelocity.Z + (targetVelocity.Z - currentVelocity.Z) * blend
                    )
                end
            end
        end

        -- Anti-Fling: dampens extreme local assembly velocities. This cannot
        -- override server-authoritative physics, but can reduce client-side flings.
        if State.AntiFling and currentRoot and currentRoot.Parent then
            local linearSpeed = currentRoot.AssemblyLinearVelocity.Magnitude
            local angularSpeed = currentRoot.AssemblyAngularVelocity.Magnitude
            if (linearSpeed > 125 or angularSpeed > 85) and os.clock() - lastAntiFlingTime > 0.35 then
                lastAntiFlingTime = os.clock()
                pcall(function()
                    for _, part in ipairs(currentCharacter:GetDescendants()) do
                        if part:IsA("BasePart") then
                            part.AssemblyLinearVelocity = Vector3.zero
                            part.AssemblyAngularVelocity = Vector3.zero
                        end
                    end
                    if currentHumanoid then
                        currentHumanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
                    end
                end)
            end
        end

        -- Keep a recent grounded position, then use it if the character is
        -- about to cross Roblox's fallen-parts destruction height.
        if currentRoot and currentRoot.Parent and currentHumanoid then
            local rootY = currentRoot.Position.Y
            if currentHumanoid.FloorMaterial ~= Enum.Material.Air
                and rootY > fallDestroyHeight + 35
                and os.clock() - lastSafeUpdate > 0.2 then
                lastSafeCFrame = currentRoot.CFrame
                lastSafeUpdate = os.clock()
            end

            if State.AntiVoid and rootY <= fallDestroyHeight + 12
                and lastSafeCFrame and os.clock() - lastAntiVoidTime > 1 then
                lastAntiVoidTime = os.clock()
                pcall(function()
                    currentRoot.CFrame = lastSafeCFrame + Vector3.new(0, 4, 0)
                    currentRoot.AssemblyLinearVelocity = Vector3.zero
                    currentRoot.AssemblyAngularVelocity = Vector3.zero
                    if currentHumanoid then
                        currentHumanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
                    end
                end)
                notify("Anti-Void", "Intentando devolverte a tu última posición segura.")
            end
        end

        runCombatAutomation()

        if os.clock() - lastESPUpdate >= 0.35 then
            lastESPUpdate = os.clock()
            for _, player in ipairs(Players:GetPlayers()) do
                updatePlayerESP(player)
            end

            if State.CoinESP then
                local container = getMapCoinContainer()
                local seen = {}
                if container then
                    for _, object in ipairs(container:GetDescendants()) do
                        if object:IsA("BasePart") then
                            seen[object] = true
                            updateObjectESP(object, CoinObjects, "COIN", Color3.fromRGB(255, 210, 70))
                        end
                    end
                end
                for object, billboard in pairs(CoinObjects) do
                    if not seen[object] then safeDestroy(billboard); CoinObjects[object] = nil end
                end
            else
                clearObjectESP(CoinObjects)
            end

            if State.GunESP then
                local gun = findDroppedGun()
                if gun then updateObjectESP(gun, GunObjects, "DROPPED GUN", Color3.fromRGB(90, 170, 255))
                else clearObjectESP(GunObjects) end
            else
                clearObjectESP(GunObjects)
            end
        end

        local role = getRole(LocalPlayer)
        if State.RoleAlerts and role ~= lastRole then
            if lastRole ~= "UNKNOWN" then notify("Cambio de rol", "Tu rol ahora es " .. role) end
            lastRole = role
        end

        if State.NearMurdererAlert and currentRoot and os.clock() - lastNearAlert > 4 then
            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= LocalPlayer and getRole(player) == "MURDERER" then
                    local root = getRoot(player)
                    if root and (root.Position - currentRoot.Position).Magnitude <= alertDistance then
                        lastNearAlert = os.clock()
                        notify("¡Murderer cerca!", player.Name .. " está cerca de ti.")
                        break
                    end
                end
            end
        end

        if os.clock() - lastStatusUpdate > 1 then
            lastStatusUpdate = os.clock()
            if roleLabel and roleLabel.Parent then roleLabel.Text = "Tu rol: " .. role end
            if statusLabel and statusLabel.Parent then statusLabel.Text = "Estado: " .. (State.AutoFarm and "Auto Farm activo" or "listo") end
            if HUDFrame and HUDFrame.Parent then
                HUDFrame.Visible = State.HUD
                local fps = delta > 0 and math.floor(1 / delta + 0.5) or 0
                local ping = getPingMilliseconds()
                local mapName = getCurrentMapName()
                local aliveCount = getAlivePlayerCount()
                local pingText = ping and (tostring(ping) .. " ms") or "N/D"
                HUDInfo.Text = "FPS: " .. tostring(fps) .. "  |  Ping: " .. pingText
                    .. "\nRol: " .. role .. "\nMapa: " .. mapName
                    .. "\nVivos: " .. tostring(aliveCount) .. "  |  Tiempo: " .. getRoundTimerText()
            end
        end
    end
end)

--// Experimental coin farm loop
task.spawn(function()
    while running do
        if State.AutoFarm and currentRoot then
            local container = getMapCoinContainer()
            if container then
                local coins = {}
                for _, object in ipairs(container:GetDescendants()) do
                    if object:IsA("BasePart") and object.Transparency < 1 then
                        table.insert(coins, object)
                    end
                end
                for _, coin in ipairs(coins) do
                    if not running or not State.AutoFarm then break end
                    if coin and coin.Parent and currentRoot and currentRoot.Parent then
                        currentRoot.CFrame = coin.CFrame * CFrame.new(0, 2, 0)
                        task.wait(0.28)
                    end
                end
            end
        end
        task.wait(0.35)
    end
end)

--// Experimental dropped-gun approach loop
task.spawn(function()
    while running do
        if State.AutoGrabGun and currentRoot then
            local gun = findDroppedGun()
            local pos = getObjectPosition(gun)
            if pos then
                currentRoot.CFrame = CFrame.new(pos + Vector3.new(0, 2.5, 0))
                task.wait(1.2)
            end
        end
        task.wait(0.35)
    end
end)

--// Experimental candy farm loop
 task.spawn(function()
    while running do
        if State.AutoFarmCandy and currentRoot then
            local container = getCandyContainer()
            if container then
                for _, candy in ipairs(container:GetDescendants()) do
                    if not running or not State.AutoFarmCandy then break end
                    if candy:IsA("BasePart") and candy.Transparency < 1 and currentRoot and currentRoot.Parent then
                        currentRoot.CFrame = candy.CFrame * CFrame.new(0, 2, 0)
                        task.wait(0.25)
                    end
                end
            end
        end
        task.wait(0.4)
    end
end)

--// Local spin and bunny-hop effects
local lastHop = 0
RunService.Heartbeat:Connect(function()
    if not running then return end
    if State.SpinBot and currentRoot then currentRoot.CFrame = currentRoot.CFrame * CFrame.Angles(0, math.rad(18), 0) end
    if State.BunnyHop and currentHumanoid and currentHumanoid.FloorMaterial ~= Enum.Material.Air and os.clock() - lastHop > 0.18 then
        lastHop = os.clock()
        currentHumanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)

--// Anti-AFK
pcall(function()
    LocalPlayer.Idled:Connect(function()
        if State.AntiAFK and running then
            local VirtualUser = game:GetService("VirtualUser")
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end
    end)
end)

Players.PlayerRemoving:Connect(function(player)
    clearPlayerESP(player)
end)


--// Integrated Complement Wxnnxrx: MM2 FakeBomb Jump
-- This is integrated into the existing hub page; no second ScreenGui is created.
do
    local bombPageName = "Bomb Jump"
    addSection(bombPageName, "BOMB JUMP")
    addLabel(bombPageName,
        "Usa la FakeBomb/PrankBomb de MM2 para intentar ejecutar el salto explosivo. Necesitas tenerla en el inventario.",
        48)

    local bombStatusLabel = addLabel(bombPageName, "ESTADO: LISTO", 34)
    local bombBusy = false
    local bombCooldownUntil = 0
    local BOMB_COOLDOWN = 5.2

    local function setIntegratedBombStatus(message)
        if bombStatusLabel and bombStatusLabel.Parent then
            bombStatusLabel.Text = "ESTADO: " .. tostring(message)
        end
    end

    local function findIntegratedFakeBomb(character, backpack)
        local function findIn(container)
            if not container then return nil end
            for _, item in ipairs(container:GetChildren()) do
                if item:IsA("Tool") then
                    local n = string.lower(item.Name)
                    if n == "fakebomb" or n == "prankbomb" then
                        return item
                    end
                end
            end
            return nil
        end
        return findIn(character)
            or findIn(backpack and backpack:FindFirstChild("Toys"))
            or findIn(backpack)
    end

    local function equipIntegratedFakeBomb(character, humanoid, backpack)
        local bomb = findIntegratedFakeBomb(character, backpack)
        if not bomb then return nil end

        if bomb.Parent ~= character then
            pcall(function() humanoid:EquipTool(bomb) end)
        end
        task.wait(0.12)

        if bomb.Parent ~= character then return nil end
        return bomb
    end

    local function integratedBombJump()
        if bombBusy then return end
        local now = os.clock()
        if now < bombCooldownUntil then
            setIntegratedBombStatus("ESPERA " .. math.ceil(bombCooldownUntil - now) .. " s")
            return
        end

        local character = LocalPlayer.Character
        local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not character or not humanoid or not root or humanoid.Health <= 0 then
            setIntegratedBombStatus("NO HAY PERSONAJE ACTIVO")
            return
        end

        bombBusy = true
        setIntegratedBombStatus("PREPARANDO...")
        task.spawn(function()
            local ok, err = pcall(function()
                local bomb = equipIntegratedFakeBomb(character, humanoid, backpack)
                if not bomb then
                    error("No se encontró FakeBomb/PrankBomb equipada o en el inventario.")
                end

                local remote = bomb:FindFirstChild("Remote")
                if not remote or not remote:IsA("RemoteEvent") then
                    error("La herramienta no contiene el RemoteEvent esperado.")
                end

                bombCooldownUntil = os.clock() + BOMB_COOLDOWN

                local function jump()
                    if not root.Parent or humanoid.Health <= 0 then return end
                    local power
                    if humanoid.UseJumpPower == false then
                        power = math.sqrt(2 * (workspace.Gravity or 196.2) * math.max(humanoid.JumpHeight or 7.2, 1))
                    else
                        power = math.max(humanoid.JumpPower or 50, 50)
                    end
                    local velocity = root.AssemblyLinearVelocity
                    root.AssemblyLinearVelocity = Vector3.new(velocity.X, power, velocity.Z)
                    pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Jumping) end)
                end

                jump()
                task.wait(0.12)
                if not root.Parent then error("El personaje cambió durante la acción.") end
                remote:FireServer(CFrame.new(root.Position - Vector3.new(0, 2.5, 0)), 50)
                task.wait(0.22)
                jump()
            end)

            if ok then
                setIntegratedBombStatus("SOLICITUD ENVIADA · VERIFICA EL SALTO")
            else
                setIntegratedBombStatus(tostring(err):gsub("[\r\n]", " "))
                warn("[Wxnnxrx] Bomb Jump: " .. tostring(err))
            end
            task.wait(0.7)
            bombBusy = false
        end)
    end

    addButton(bombPageName, "💣  ACTIVAR BOMB JUMP", integratedBombJump)
    addLabel(bombPageName,
        "Enfriamiento: 5.2 segundos. La acción requiere la herramienta FakeBomb/PrankBomb y puede ser rechazada por el servidor.",
        42)
end


notify("Wxnnxrx Hub 2.6.2", "Actualización cargada.")
print("[Wxnnxrx Hub 2.6.2] Loaded successfully.")

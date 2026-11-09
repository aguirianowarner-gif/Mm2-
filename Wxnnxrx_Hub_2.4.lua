--[[
    Wxnnxrx Hub 2.4 - MM2
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

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = workspace.CurrentCamera

--// Avoid duplicate GUIs
local GUI_NAME = "WxnnxrxHub24"
local oldGui
pcall(function()
    oldGui = (gethui and gethui() or CoreGui):FindFirstChild(GUI_NAME)
end)
if oldGui then
    pcall(function() oldGui:Destroy() end)
end

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
    FullBright = false,
    RemoveFog = false,
    AutoFarm = false,
    AutoGrabGun = false,
    RoleAlerts = true,
    NearMurdererAlert = true,
    AutoFarmCandy = false,
    SpinBot = false,
    BunnyHop = false,
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
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = title,
            Text = message,
            Duration = 3,
        })
    end)
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

local function roleColor(role)
    if role == "MURDERER" then return Color3.fromRGB(255, 75, 80) end
    if role == "SHERIFF" then return Color3.fromRGB(75, 155, 255) end
    if role == "INNOCENT" then return Color3.fromRGB(85, 220, 135) end
    return Color3.fromRGB(220, 220, 230)
end

local function getMapCoinContainer()
    local direct = workspace:FindFirstChild("CoinContainer", true)
    if direct then return direct end
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
pcall(function() oldGui = guiParent:FindFirstChild("WxnnxrxHub24") end)
if oldGui then pcall(function() oldGui:Destroy() end) end

local COLORS = {
    Background = Color3.fromRGB(8, 13, 27),
    Panel = Color3.fromRGB(13, 21, 40),
    Panel2 = Color3.fromRGB(18, 29, 52),
    Panel3 = Color3.fromRGB(24, 38, 65),
    Blue = Color3.fromRGB(35, 125, 255),
    BlueDark = Color3.fromRGB(22, 82, 180),
    Text = Color3.fromRGB(238, 244, 255),
    Muted = Color3.fromRGB(145, 163, 190),
    Off = Color3.fromRGB(54, 67, 91),
    White = Color3.fromRGB(255, 255, 255),
}

local function uiTween(object, duration, properties, style, direction)
    local info = TweenInfo.new(duration, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out)
    local animation = TweenService:Create(object, info, properties)
    animation:Play()
    return animation
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
    Name = "WxnnxrxHub24",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    IgnoreGuiInset = true,
    DisplayOrder = 50,
})

local Main = make("Frame", ScreenGui, {
    Name = "Main",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, 0),
    Size = UDim2.fromOffset(540, 365),
    BackgroundColor3 = COLORS.Background,
    BorderSizePixel = 0,
    ClipsDescendants = true,
})
addCorner(Main, 15)
addStroke(Main, COLORS.Blue, 1.2, 0.48)
local MainScale = make("UIScale", Main, {Scale = 0.88})

local function updateScale()
    local camera = workspace.CurrentCamera
    if not camera then return end
    local viewport = camera.ViewportSize
    MainScale.Scale = math.clamp(math.min(viewport.X / 540, viewport.Y / 390), 0.55, 1)
end
updateScale()
if workspace.CurrentCamera then
    workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
end

local Header = make("Frame", Main, {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, 48),
    BackgroundColor3 = COLORS.Panel,
    BorderSizePixel = 0,
    ZIndex = 2,
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
    Text = "WXNNXRX  HUB  2.4",
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
    Position = UDim2.fromOffset(10, 58),
    Size = UDim2.new(0, 112, 1, -68),
    BackgroundColor3 = COLORS.Panel,
    BorderSizePixel = 0,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = COLORS.Blue,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
})
addCorner(Sidebar, 11)
make("UIPadding", Sidebar, {
    PaddingTop = UDim.new(0, 9), PaddingLeft = UDim.new(0, 7),
    PaddingRight = UDim.new(0, 7), PaddingBottom = UDim.new(0, 8),
})
make("UIListLayout", Sidebar, {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder})

local ContentHost = make("Frame", Main, {
    Name = "ContentHost",
    Position = UDim2.fromOffset(132, 58),
    Size = UDim2.new(1, -142, 1, -68),
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

local pageNames = {"Home", "ESP", "Jugador", "Farm", "Combate+", "Alertas", "Teleport", "Visuales", "Troleo", "Extras", "Ajustes"}
local pages, navButtons = {}, {}
local activePageName = "Home"
local searchQuery = ""

local function createPage(name)
    local group = make("CanvasGroup", PageHost, {
        Name = name, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
        GroupTransparency = 1, Visible = false,
    })
    local scroll = make("ScrollingFrame", group, {
        Name = "Options", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
        BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = COLORS.Blue,
        CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    })
    make("UIPadding", scroll, {
        PaddingTop = UDim.new(0, 5), PaddingLeft = UDim.new(0, 5),
        PaddingRight = UDim.new(0, 7), PaddingBottom = UDim.new(0, 9),
    })
    make("UIListLayout", scroll, {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder})
    pages[name] = {Group = group, Scroll = scroll, FilterItems = {}}
end
for _, name in ipairs(pageNames) do createPage(name) end

local function addFilterItem(pageName, object, searchText)
    table.insert(pages[pageName].FilterItems, {Object = object, Text = string.lower(searchText or "")})
end

local function applySearch()
    local query = string.lower(searchQuery)
    for _, item in ipairs(pages[activePageName].FilterItems) do
        item.Object.Visible = query == "" or string.find(item.Text, query, 1, true) ~= nil
    end
end

local function setActivePage(name)
    if not pages[name] or name == activePageName then return end
    local oldName = activePageName
    local oldPage = pages[oldName] and pages[oldName].Group
    local newPage = pages[name].Group
    activePageName = name
    for pageName, button in pairs(navButtons) do
        local selected = pageName == name
        uiTween(button, 0.12, {
            BackgroundColor3 = selected and COLORS.BlueDark or COLORS.Panel2,
            TextColor3 = selected and COLORS.White or COLORS.Muted,
        })
    end
    newPage.Visible = true
    newPage.GroupTransparency = 1
    applySearch()
    uiTween(newPage, 0.16, {GroupTransparency = 0})
    if oldPage then
        local fadeOut = uiTween(oldPage, 0.13, {GroupTransparency = 1})
        fadeOut.Completed:Connect(function()
            if oldPage.Parent and activePageName ~= oldName then oldPage.Visible = false end
        end)
    end
end

for index, name in ipairs(pageNames) do
    local button = make("TextButton", Sidebar, {
        Name = "Nav_" .. name, Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = name == "Home" and COLORS.BlueDark or COLORS.Panel2,
        BorderSizePixel = 0, Text = name,
        TextColor3 = name == "Home" and COLORS.White or COLORS.Muted,
        Font = Enum.Font.GothamSemibold, TextSize = 11, AutoButtonColor = false,
        LayoutOrder = index,
    })
    addCorner(button, 8)
    navButtons[name] = button
    button.Activated:Connect(function() setActivePage(name) end)
end
pages.Home.Group.Visible = true
pages.Home.Group.GroupTransparency = 0

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

local function addToggle(pageName, title, stateKey, callback)
    local row = make("Frame", pages[pageName].Scroll, {
        Name = "Toggle_" .. stateKey, Size = UDim2.new(1, -3, 0, 43),
        BackgroundColor3 = COLORS.Panel2, BorderSizePixel = 0,
    })
    addCorner(row, 9)
    make("TextLabel", row, {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(11, 0),
        Size = UDim2.new(1, -72, 1, 0), Font = Enum.Font.GothamMedium,
        Text = title, TextColor3 = COLORS.Text, TextSize = 12,
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
    track.Activated:Connect(function()
        State[stateKey] = not State[stateKey]
        render(true)
        if callback then
            local ok, err = pcall(callback, State[stateKey])
            if not ok then warn("[Wxnnxrx] " .. tostring(err)) end
        end
    end)
    render(false)
    addFilterItem(pageName, row, title)
    return row
end

local function addButton(pageName, title, callback)
    local button = make("TextButton", pages[pageName].Scroll, {
        Name = "Button", Size = UDim2.new(1, -3, 0, 40),
        BackgroundColor3 = COLORS.Panel2, BorderSizePixel = 0,
        Text = title, TextColor3 = COLORS.Text, Font = Enum.Font.GothamMedium,
        TextSize = 12, AutoButtonColor = false,
    })
    addCorner(button, 9)
    button.Activated:Connect(function()
        uiTween(button, 0.08, {BackgroundColor3 = COLORS.BlueDark})
        task.delay(0.09, function()
            if button.Parent then uiTween(button, 0.13, {BackgroundColor3 = COLORS.Panel2}) end
        end)
        if callback then
            local ok, err = pcall(callback)
            if not ok then warn("[Wxnnxrx] " .. tostring(err)); notify("Wxnnxrx", "Ocurrió un error en esa acción.") end
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
        PlaceholderColor3 = COLORS.Muted, Font = Enum.Font.Gotham, TextSize = 11,
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
        if callback then
            local ok, err = pcall(callback, input.Text)
            if not ok then warn("[Wxnnxrx] " .. tostring(err)) end
        end
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
    Font = Enum.Font.GothamBold, Text = "HUB  2.4  •  MM2",
    TextColor3 = COLORS.Blue, TextSize = 12,
})
addFilterItem("Home", homeBrand, "Wxnnxrx Hub 2.4 MM2")
local roleLabel = addLabel("Home", "Tu rol: comprobando...", 34)
local statusLabel = addLabel("Estado: listo", 32)
addButton("Home", "Actualizar mi rol", function() roleLabel.Text = "Tu rol: " .. getRole(LocalPlayer) end)
addLabel("Home", "Interfaz 2.4 integrada con las funciones y sistemas de Wxnnxrx 2.2.", 44)

-- ESP
addSection("ESP", "Jugadores")
addToggle("ESP", "Activar Player ESP", "PlayerESP")
addToggle("ESP", "Mostrar Murderer", "ESP_Murderer")
addToggle("ESP", "Mostrar Sheriff", "ESP_Sheriff")
addToggle("ESP", "Mostrar Innocent", "ESP_Innocent")
addToggle("ESP", "Mostrar distancia", "ESP_Distance")
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
local speedBox = addInputButton("Jugador", "WalkSpeed (16–100)", "Ejemplo: 28", "28", "Aplicar", function(valueText)
    local value = math.clamp(tonumber(valueText) or 16, 16, 100)
    if currentHumanoid then currentHumanoid.WalkSpeed = value end
    notify("Jugador", "WalkSpeed aplicado: " .. value)
end)
local jumpBox = addInputButton("Jugador", "JumpPower (50–150)", "Ejemplo: 65", "65", "Aplicar", function(valueText)
    local value = math.clamp(tonumber(valueText) or 50, 50, 150)
    if currentHumanoid then
        pcall(function() currentHumanoid.UseJumpPower = true end)
        currentHumanoid.JumpPower = value
    end
    notify("Jugador", "JumpPower aplicado: " .. value)
end)
addButton("Jugador", "Restaurar movimiento", function()
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
addLabel("Ajustes", "WXNNXRX HUB 2.4 • Interfaz azul integrada", 34)

-- Live search filters only the current category.
SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
    searchQuery = SearchBox.Text
    applySearch()
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
MinButton.Activated:Connect(minimizePanel)
FloatingButton.Activated:Connect(openPanel)
CloseButton.Activated:Connect(function()
    Main.Visible = false
    FloatingButton.Visible = false
    FloatingShootButton.Visible = false
end)

-- Drag from header only; exclude the minimize and close controls.
local dragging, dragStart, startPosition = false, nil, nil
local dragInput
local function pointerOver(object, point)
    local pos, size = object.AbsolutePosition, object.AbsoluteSize
    return point.X >= pos.X and point.X <= pos.X + size.X
        and point.Y >= pos.Y and point.Y <= pos.Y + size.Y
end
Header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        if pointerOver(MinButton, input.Position) or pointerOver(CloseButton, input.Position) then return end
        dragging = true
        dragStart = input.Position
        startPosition = Main.Position
        dragInput = input
    end
end)
Header.InputEnded:Connect(function(input)
    if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
        dragInput = nil
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        Main.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X,
            startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
    end
end)
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.RightControl then
        if Main.Visible then minimizePanel() else openPanel() end
    end
end)

openPanel()

--// Infinite jump
UserInputService.JumpRequest:Connect(function()
    if State.InfiniteJump and currentHumanoid then
        pcall(function() currentHumanoid:ChangeState(Enum.HumanoidStateType.Jumping) end)
    end
end)

--// Character refresh
LocalPlayer.CharacterAdded:Connect(function(character)
    currentCharacter = character
    currentHumanoid = character:WaitForChild("Humanoid", 10)
    currentRoot = character:WaitForChild("HumanoidRootPart", 10)
    lastSafeCFrame = nil
    lastSafeUpdate = 0
    if currentHumanoid then
        originalSpeed = currentHumanoid.WalkSpeed
        pcall(function() originalJump = currentHumanoid.JumpPower end)
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
end
if Camera then originalFOV = Camera.FieldOfView end

--// ESP cleanup helpers
local function clearPlayerESP(player)
    local bundle = ESPObjects[player]
    if bundle then
        safeDestroy(bundle.highlight)
        safeDestroy(bundle.billboard)
        ESPObjects[player] = nil
    end
end

local function updatePlayerESP(player)
    if player == LocalPlayer then return end
    if not State.PlayerESP then clearPlayerESP(player); return end
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
            Name = "WxnnxrxPlayerESP",
            Adornee = character,
            FillColor = roleColor(role),
            OutlineColor = roleColor(role),
            FillTransparency = 0.78,
            OutlineTransparency = 0.05,
            DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
        })
        local billboard = make("BillboardGui", character, {
            Name = "WxnnxrxRoleESP",
            Adornee = head,
            AlwaysOnTop = true,
            Size = UDim2.fromOffset(180, 34),
            StudsOffset = Vector3.new(0, 2.5, 0),
        })
        local label = make("TextLabel", billboard, {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            TextColor3 = roleColor(role),
            TextStrokeTransparency = 0.25,
            Font = Enum.Font.GothamBold,
            TextSize = 12,
            Text = player.Name .. " • " .. role,
        })
        bundle = {highlight = highlight, billboard = billboard, label = label, character = character}
        ESPObjects[player] = bundle
    end

    local color = roleColor(role)
    bundle.highlight.FillColor = color
    bundle.highlight.OutlineColor = color
    local distanceText = ""
    if State.ESP_Distance and currentRoot then
        distanceText = " • " .. tostring(math.floor((root.Position - currentRoot.Position).Magnitude)) .. "m"
    end
    bundle.label.Text = player.Name .. " • " .. role .. distanceText
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
    running = false
    State.Fly = false
    State.Noclip = false
    State.AutoFarm = false
    State.AutoGrabGun = false
    State.AutoFarmCandy = false
    State.SpinBot = false
    State.BunnyHop = false
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

        if os.clock() - lastStatusUpdate > 1.5 then
            lastStatusUpdate = os.clock()
            if roleLabel and roleLabel.Parent then roleLabel.Text = "Tu rol: " .. role end
            if statusLabel and statusLabel.Parent then statusLabel.Text = "Estado: " .. (State.AutoFarm and "Auto Farm activo" or "listo") end
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

notify("Wxnnxrx Hub 2.4", "Cargado. Panel ampliado listo.")
print("[Wxnnxrx Hub 2.4] Loaded successfully.")

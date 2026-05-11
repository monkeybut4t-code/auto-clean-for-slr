local Config = {
    Enabled = false,
    TweenSpeed = 0.55,
    ArriveDelay = 0.25,
    CleanWaitMax = 3.0,
    CleanCheckRate = 0.05,
    InteractDelay = 0.3,
    PollRate = 0.8,
    TotalPuddles = 8,
    DebugMode = false,
}

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

-- Wait for player FIRST
local player = Players.LocalPlayer
if not player then
    player = Players.PlayerAdded:Wait()
end

local currentTween = nil

-- Utility: Safe logging
local function log(message, level)
    level = level or "INFO"
    if not Config.DebugMode and level == "DEBUG" then return end
    print(string.format("[AutoClean %s] %s", level, message))
end

-- Character helpers
local function getChar()
    if not player then return nil end
    if player.Character and player.Character:FindFirstChild("Humanoid") then
        return player.Character
    end
    return player.CharacterAdded:Wait()
end

local function getHRP()
    local char = getChar()
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart")
end

local function dist3D(a, b)
    if not a or not b then return math.huge end
    local dx = b.X - a.X
    local dy = b.Y - a.Y
    local dz = b.Z - a.Z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- Validate puddle
local function isCleanable(part)
    if not part or not part.Parent then return false end
    local prompt = part:FindFirstChildOfClass("ProximityPrompt")
    if not prompt then return false end
    local okE, enabled = pcall(function() return prompt.Enabled end)
    if okE and enabled == false then return false end
    local okT, trans = pcall(function() return part.Transparency end)
    if okT and trans and trans >= 1 then return false end
    return true
end

-- Tween movement - FIXED
local function tweenTo(targetPos)
    local hrp = getHRP()
    if not hrp or not targetPos then 
        log("tweenTo: missing HRP or targetPos", "WARN")
        return false 
    end

    if currentTween then
        pcall(function() currentTween:Cancel() end)
        currentTween = nil
    end

    local startPos = hrp.Position
    if not startPos or not targetPos then return false end
    
    local distance = (targetPos - startPos).Magnitude
    if distance < 0.1 then return true end -- Already there
    
    local time = math.clamp(distance / 30 * Config.TweenSpeed, 0.2, 1.5)

    -- Simple CFrame: just the position
    local goalPos = targetPos + Vector3.new(0, 3, 0)
    local goalCFrame = CFrame.new(goalPos)

    local tweenInfo = TweenInfo.new(
        time,
        Enum.EasingStyle.Quad,
        Enum.EasingDirection.Out
    )

    local tween = TweenService:Create(hrp, tweenInfo, {CFrame = goalCFrame})
    currentTween = tween
    
    log(string.format("🎯 Tweening (distance: %.1f, time: %.2fs)", distance, time), "INFO")
    tween:Play()
    tween.Completed:Wait()
    
    return true
end

-- Press and release E key
local function pressE()
    keypress(0x45)
    task.wait(0.05)
    keyrelease(0x45)
end

-- Zero out the prompt hold duration
local function zeroPrompt(prompt)
    if not prompt then return end
    pcall(function()
        if prompt:FindFirstChild("HoldDuration") then
            prompt.HoldDuration.Value = 0
        end
    end)
end

-- Clean and wait for completion
local function cleanAndWait(part)
    if not isCleanable(part) then return false end
    
    local prompt = part:FindFirstChildOfClass("ProximityPrompt")
    if prompt then zeroPrompt(prompt) end
    
    log(string.format("🔧 Starting to clean: %s", part.Name), "INFO")
    
    pressE()
    local t0 = os.clock()
    
    while os.clock() - t0 < Config.CleanWaitMax do
        task.wait(Config.CleanCheckRate)
        
        -- Check if puddle is cleaned (disappears/becomes uncleanable)
        if not isCleanable(part) then
            log(string.format("✓ Puddle cleaned: %s", part.Name), "INFO")
            task.wait(Config.InteractDelay)
            return true
        end
        
        -- Repeat E press every 0.5 seconds to keep interaction active
        if (os.clock() - t0) % 0.5 < Config.CleanCheckRate then
            pressE()
        end
    end
    
    log(string.format("✗ Cleaning timeout: %s", part.Name), "WARN")
    return not isCleanable(part)
end

-- Get cleanable puddles sorted by distance
local function getActivePuddles()
    local cleanFolder
    pcall(function()
        cleanFolder = workspace.Map.Jobs.CleanNPC.Clean
    end)
    if not cleanFolder then return {} end

    local hrp = getHRP()
    local myPos = hrp and hrp.Position
    local puddles = {}

    for i = 1, Config.TotalPuddles do
        local part = cleanFolder:FindFirstChild(tostring(i))
        if part and isCleanable(part) then
            local okPos, pos = pcall(function() return part.Position end)
            if okPos and pos then
                local d = myPos and dist3D(myPos, pos) or 9999
                table.insert(puddles, {part = part, pos = pos, dist = d})
            end
        end
    end

    table.sort(puddles, function(a, b) return a.dist < b.dist end)
    return puddles
end

log("Auto-clean script initialized", "INFO")

-- Main Loop
task.spawn(function()
    log("Main loop started", "INFO")
    
    while true do
        task.wait(Config.PollRate)
        
        if not Config.Enabled then continue end

        local puddles = getActivePuddles()
        if #puddles == 0 then
            log("No cleanable puddles found", "DEBUG")
            continue
        end

        log(string.format("Found %d puddles", #puddles), "INFO")

        for _, entry in ipairs(puddles) do
            if not Config.Enabled then break end
            if not isCleanable(entry.part) then continue end

            -- Tween to puddle
            local success = tweenTo(entry.pos)
            if not success then continue end

            -- Wait before interacting
            task.wait(Config.ArriveDelay)
            if not isCleanable(entry.part) then continue end

            -- Clean and wait
            cleanAndWait(entry.part)
        end
    end
end)

-- Toggle with J key
pcall(function()
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        
        if input.KeyCode == Enum.KeyCode.J then
            Config.Enabled = not Config.Enabled
            log(string.format("⚙️ Auto-clean %s", Config.Enabled and "ENABLED" or "DISABLED"), "INFO")
        elseif input.KeyCode == Enum.KeyCode.K then
            Config.Enabled = false
            if currentTween then pcall(function() currentTween:Cancel() end) end
            log("🛑 Emergency stop", "WARN")
        end
    end)
end)

-- Cleanup on respawn
pcall(function()
    player.CharacterAdded:Connect(function()
        if currentTween then pcall(function() currentTween:Cancel() end) end
        log("Character respawned", "DEBUG")
    end)
end)

log("Auto Clean ready! Press J to toggle, K to stop.", "INFO")

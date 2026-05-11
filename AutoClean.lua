local Config = {
    Enabled = false,
    TweenSpeed = 0.6, -- base speed multiplier
    ArriveDistance = 5,
    PollRate = 1,
    TotalPuddles = 8,
    DebugMode = true, -- ENABLED FOR DEBUGGING
}

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

-- Wait for player FIRST before anything else
local player = Players.LocalPlayer
if not player then
    player = Players.PlayerAdded:Wait()
end

local currentTween = nil
local isMoving = false

-- Utility: Safe logging
local function log(message, level)
    level = level or "INFO"
    if not Config.DebugMode and level == "DEBUG" then return end
    print(string.format("[AutoClean %s] %s", level, message))
end

-- Character helpers with safety checks
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
    
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        log("HumanoidRootPart not found", "WARN")
        return nil
    end
    return hrp
end

-- Validate puddle is cleanable
local function isCleanable(part)
    if not part or not part.Parent then 
        log(string.format("Part validation failed: part=%s, hasParent=%s", tostring(part), part and part.Parent and "yes" or "no"), "DEBUG")
        return false 
    end
    
    -- Check proximity prompt exists and is enabled
    local prompt = part:FindFirstChildOfClass("ProximityPrompt")
    if not prompt then 
        log(string.format("No ProximityPrompt found on %s", part.Name), "DEBUG")
        return false 
    end
    if not prompt.Enabled then 
        log(string.format("ProximityPrompt disabled on %s", part.Name), "DEBUG")
        return false 
    end
    
    -- Check visibility
    if part.Transparency >= 1 then 
        log(string.format("Part %s is invisible (transparency: %f)", part.Name, part.Transparency), "DEBUG")
        return false 
    end
    
    log(string.format("✓ %s is cleanable", part.Name), "DEBUG")
    return true
end

-- Safely get puddle folder with fallback paths
local function getPuddleFolder()
    log("Searching for puddle folder...", "DEBUG")
    
    local paths = {
        function() return workspace.Map.Jobs.CleanNPC.Clean end,
        function() return workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Jobs") and workspace.Map.Jobs:FindFirstChild("CleanNPC") and workspace.Map.Jobs.CleanNPC:FindFirstChild("Clean") end,
    }
    
    for i, pathFunc in ipairs(paths) do
        local folder = pathFunc()
        if folder then 
            log(string.format("✓ Found puddle folder at path %d: %s", i, folder:GetFullName()), "INFO")
            return folder 
        end
        log(string.format("Path %d failed", i), "DEBUG")
    end
    
    log("Puddle folder not found in workspace", "WARN")
    return nil
end

-- Get puddles sorted by distance
local function getPuddles()
    local folder = getPuddleFolder()
    if not folder then 
        log("Cannot get puddles: folder not found", "WARN")
        return {} 
    end
    
    local hrp = getHRP()
    if not hrp then 
        log("Cannot get puddles: HRP not found", "WARN")
        return {} 
    end
    
    local list = {}
    log(string.format("Checking %d puddle slots...", Config.TotalPuddles), "DEBUG")
    
    for i = 1, Config.TotalPuddles do
        local part = folder:FindFirstChild(tostring(i))
        if part then
            log(string.format("  [%d] Found part: %s", i, part.Name), "DEBUG")
            if isCleanable(part) then
                local dist = (hrp.Position - part.Position).Magnitude
                log(string.format("    ✓ Cleanable! Distance: %.1f", dist), "DEBUG")
                table.insert(list, {part = part, dist = dist, index = i})
            else
                log(string.format("    ✗ Not cleanable", part.Name), "DEBUG")
            end
        else
            log(string.format("  [%d] No part found", i), "DEBUG")
        end
    end
    
    -- Sort by distance
    table.sort(list, function(a, b) return a.dist < b.dist end)
    
    log(string.format("Total cleanable puddles: %d", #list), "INFO")
    return list
end

-- Cancel current movement
local function cancelTween()
    if currentTween then
        pcall(function() currentTween:Cancel() end)
        currentTween = nil
    end
    isMoving = false
end

-- Smooth tween movement with safety
local function tweenTo(targetPos)
    local hrp = getHRP()
    if not hrp then 
        log("tweenTo: HRP not found", "WARN")
        return false 
    end
    
    -- Cancel previous tween
    cancelTween()
    
    local startPos = hrp.Position
    local distance = (startPos - targetPos).Magnitude
    
    -- Clamp time (0.2s minimum, 1.5s maximum)
    local time = math.clamp(distance * 0.08 / Config.TweenSpeed, 0.2, 1.5)
    
    -- Calculate direction for smooth rotation
    local direction = (targetPos - startPos).Unit
    local lookCFrame = CFrame.lookAt(startPos, startPos + direction)
    
    -- Target position with height offset
    local goalCFrame = CFrame.new(targetPos + Vector3.new(0, 3, 0)) * 
        CFrame.Angles(0, select(2, lookCFrame:ToEulerAnglesYXZ()), 0)
    
    local tweenInfo = TweenInfo.new(
        time,
        Enum.EasingStyle.Quad,
        Enum.EasingDirection.Out
    )
    
    local tween = TweenService:Create(hrp, tweenInfo, {CFrame = goalCFrame})
    
    isMoving = true
    currentTween = tween
    
    tween.Completed:Connect(function()
        isMoving = false
        log("Tween completed", "DEBUG")
    end)
    
    log(string.format("🎯 Starting tween (distance: %.1f, time: %.2fs)", distance, time), "INFO")
    tween:Play()
    
    return true
end

-- Interact with puddle
local function clean(part)
    if not part then return false end
    
    local prompt = part:FindFirstChildOfClass("ProximityPrompt")
    if not prompt or not prompt.Enabled then
        log("Prompt not found or disabled on: " .. part.Name, "DEBUG")
        return false
    end
    
    local success = pcall(function()
        fireproximityprompt(prompt)
    end)
    
    if success then
        log("✓ Cleaned puddle: " .. part.Name, "INFO")
    else
        log("✗ Failed to clean puddle: " .. part.Name, "WARN")
    end
    
    return success
end

-- Move to puddle and clean it
local function goClean(part)
    if not isCleanable(part) then 
        log("goClean: part not cleanable", "DEBUG")
        return false 
    end
    
    log(string.format("🚀 Moving to puddle: %s", part.Name), "INFO")
    
    -- Move to puddle
    if not tweenTo(part.Position) then 
        log("goClean: tweenTo failed", "WARN")
        return false 
    end
    
    -- Wait for movement to complete
    while isMoving do
        task.wait(0.1)
    end
    
    log("Movement complete, checking puddle...", "DEBUG")
    
    -- Check if still cleanable after movement
    if not isCleanable(part) then
        log("Puddle became uncleanable during movement: " .. part.Name, "DEBUG")
        return false
    end
    
    -- Verify arrival distance
    local hrp = getHRP()
    if not hrp then 
        log("goClean: HRP lost after movement", "WARN")
        return false 
    end
    
    local distance = (hrp.Position - part.Position).Magnitude
    if distance > Config.ArriveDistance then
        log(string.format("Failed to reach puddle (distance: %.1f)", distance), "DEBUG")
        return false
    end
    
    -- Clean the puddle
    return clean(part)
end

log("Auto-clean script initialized", "INFO")

-- Main loop
task.spawn(function()
    log("Auto-clean main loop started", "INFO")
    
    while true do
        task.wait(Config.PollRate)
        
        if not Config.Enabled then continue end
        
        log("--- POLL CYCLE ---", "DEBUG")
        
        -- Safety check: character exists
        local hrp = getHRP()
        if not hrp then
            log("Character missing, waiting for respawn", "WARN")
            task.wait(2)
            continue
        end
        
        local puddles = getPuddles()
        
        if #puddles == 0 then
            log("❌ No cleanable puddles found", "WARN")
            continue
        end
        
        log(string.format("📍 Found %d cleanable puddles, processing...", #puddles), "INFO")
        
        for _, data in ipairs(puddles) do
            if not Config.Enabled then break end
            
            -- Double-check puddle is still cleanable
            if not isCleanable(data.part) then
                log("Puddle no longer cleanable, skipping: " .. data.part.Name, "DEBUG")
                continue
            end
            
            goClean(data.part)
            
            -- Small delay between puddles to avoid spam
            task.wait(0.5)
        end
    end
end)

-- Toggle with J key (now safe since player is loaded)
pcall(function()
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        
        if input.KeyCode == Enum.KeyCode.J then
            Config.Enabled = not Config.Enabled
            log(string.format("⚙️ Auto-clean %s", Config.Enabled and "ENABLED" or "DISABLED"), "INFO")
        elseif input.KeyCode == Enum.KeyCode.K then
            -- Emergency stop
            Config.Enabled = false
            cancelTween()
            log("🛑 Emergency stop activated", "WARN")
        end
    end)
end)

-- Cleanup on character death (now safe since player is loaded)
pcall(function()
    player.CharacterAdded:Connect(function()
        cancelTween()
        log("Character respawned, movement cancelled", "DEBUG")
    end)
end)

log(string.format("Configuration loaded (TweenSpeed: %.1f, ArriveDistance: %d)", Config.TweenSpeed, Config.ArriveDistance), "INFO")

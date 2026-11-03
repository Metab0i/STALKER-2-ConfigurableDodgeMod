-- SimpleDodge - a from-scratch dodge mod for STALKER 2 (UE4SS Lua)
-- Double-tap Z = dodge left, C = dodge right, S = dodge back (camera-relative).
-- Uses the native Obj vitals API (GetSP/ForceSetSP) for the stamina cost.

local UEHelpers = require("UEHelpers")

-- ================= Config =================
-- Side dodges get killed by ground friction + held movement input, so they
-- need a bigger launch than the back dodge to travel a similar distance.
local SIDE_SPEED        = 900.0   -- horizontal launch velocity for left/right (cm/s)
local SIDE_UP           = 650.0   -- upward component for left/right (cm/s), high hop arc
local BACK_SPEED        = 900.0   -- horizontal launch velocity for back (cm/s)
local BACK_UP           = 200.0   -- upward component for back (cm/s)
local DOUBLE_TAP_WINDOW = 0.25    -- seconds between taps to count as double-tap
local COOLDOWN          = 0.60    -- seconds between dodges
local ENABLE_BACK       = true    -- double-tap S dodge backwards
local STAMINA_COST      = 20.0    -- stamina points spent per dodge (vanilla jump = 20)
local REQUIRE_STAMINA   = true    -- block dodge when stamina is insufficient
-- ==========================================

local lastTap   = { left = 0.0, right = 0.0, back = 0.0 }
local lastDodge = 0.0

local function Now()
    return os.clock()
end

-- Spend stamina through the native vitals API on the character.
-- Returns true if the cost was applied (or if stamina handling is unavailable).
local function SpendStamina(Pawn)
    if STAMINA_COST <= 0.0 then return true end

    local okCur, curSP = pcall(function() return Pawn:GetSP() end)
    if not okCur or curSP == nil then
        print("[SimpleDodge] GetSP unavailable, skipping stamina cost")
        return true
    end

    if REQUIRE_STAMINA and curSP < STAMINA_COST then
        print(string.format("[SimpleDodge] not enough stamina (%.1f < %.1f)", curSP, STAMINA_COST))
        return false
    end

    local newSP = math.floor(curSP - STAMINA_COST)
    if newSP < 0 then newSP = 0 end

    local okSet = pcall(function() Pawn:ForceSetSP(newSP) end)
    if okSet then
        print(string.format("[SimpleDodge] stamina %.1f -> %d", curSP, newSP))
    else
        print("[SimpleDodge] ForceSetSP failed, stamina unchanged")
    end
    return true
end

local function BuildLaunchVector(direction)
    -- direction: "left" | "right" | "back", relative to the camera
    local PC = UEHelpers.GetPlayerController()
    if not PC:IsValid() then return nil end
    local CameraManager = PC.PlayerCameraManager
    if not CameraManager:IsValid() then return nil end

    local MathLib = UEHelpers.GetKismetMathLibrary()
    local Rot = CameraManager:GetCameraRotation()

    local DirVector
    if direction == "left" then
        DirVector = MathLib:GetRightVector(Rot)
        DirVector = MathLib:Multiply_VectorFloat(DirVector, -1.0)
    elseif direction == "right" then
        DirVector = MathLib:GetRightVector(Rot)
    else -- back
        DirVector = MathLib:GetForwardVector(Rot)
        DirVector = MathLib:Multiply_VectorFloat(DirVector, -1.0)
    end

    local speed, up
    if direction == "back" then
        speed, up = BACK_SPEED, BACK_UP
    else
        speed, up = SIDE_SPEED, SIDE_UP
    end

    local Lateral = MathLib:Multiply_VectorFloat(DirVector, speed)
    local Up = MathLib:Multiply_VectorFloat(MathLib:GetUpVector(Rot), up)
    return MathLib:Add_VectorVector(Lateral, Up)
end

local function DoDodge(direction)
    if Now() - lastDodge < COOLDOWN then return end

    local PC = UEHelpers.GetPlayerController()
    if not PC:IsValid() then return end
    local Pawn = PC.Pawn
    if Pawn == nil or not Pawn:IsValid() then return end

    local Velocity = BuildLaunchVector(direction)
    if Velocity == nil then return end

    -- stamina gate: no dodge without the stamina to pay for it
    if not SpendStamina(Pawn) then
        lastTap.left, lastTap.right, lastTap.back = 0.0, 0.0, 0.0
        return
    end

    lastDodge = Now()
    lastTap.left, lastTap.right, lastTap.back = 0.0, 0.0, 0.0

    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            Pawn:LaunchCharacter(Velocity, true, true)
        end)
        if not ok then
            print(string.format("[SimpleDodge] LaunchCharacter failed: %s", tostring(err)))
        else
            print(string.format("[SimpleDodge] dodged %s", direction))
        end
    end)
end

local function HandleTap(direction)
    local t = Now()
    if t - lastTap[direction] <= DOUBLE_TAP_WINDOW then
        DoDodge(direction)
        lastTap[direction] = 0.0
    else
        lastTap[direction] = t
    end
end

RegisterKeyBind(Key.Z, function() HandleTap("left") end)
RegisterKeyBind(Key.C, function() HandleTap("right") end)
if ENABLE_BACK then
    RegisterKeyBind(Key.S, function() HandleTap("back") end)
end

-- F7: write the full object dump (for offline API discovery)
RegisterKeyBind(Key.F7, function()
    print("[SimpleDodge] dumping all objects (this may take a while)...")
    DumpAllObjects()
    print("[SimpleDodge] object dump written")
end)

print("[SimpleDodge] v1.3 loaded - double-tap Z (left), C (right), S (back), stamina cost on")

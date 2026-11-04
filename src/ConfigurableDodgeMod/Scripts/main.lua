-- Configurable Dodge Mod for S.T.A.L.K.E.R. 2 (UE4SS Lua) - v2.2
-- All key-binding lives in DodgeSignal.ps1 (ships with the mod, started
-- automatically below): it watches the configured keys at the OS level and
-- writes press counters to dodge_signals.txt. This script only EXECUTES the
-- dodge: it polls the counters, reads the movement input for direction, and
-- launches the character. Config: ConfigurableDodgeMod.ini (live-reloaded).

local UEHelpers = require("UEHelpers")

-- generation bump: hot reloads invalidate stale async loops (see file end)
DodgeMod_Generation = (DodgeMod_Generation or 0) + 1
local DODGE_MOD_GEN = DodgeMod_Generation

-- ================= dev harness =================
-- gated by a ".hotreload" dot-file next to the script; never ships
local devDir = nil
do
    local src = nil
    pcall(function()
        local s = debug.getinfo(1, "S").source
        src = string.sub(s, 1, 1) == "@" and string.sub(s, 2) or s
    end)
    if src ~= nil then
        devDir = string.match(src, "^(.*)[/\\][^/\\]+$")
    end
end
local devEnabled = false
local cfgPath = nil
do
    if devDir ~= nil then
        local lower = string.lower(devDir)
        local s = string.match(lower, "()scripts$")
        if s ~= nil then
            local root = string.sub(devDir, 1, s - 1)
            local sep = (string.find(root, "\\", 1, true) ~= nil) and "\\" or "/"
            cfgPath = root .. "ConfigurableDodgeMod.ini"
            pcall(function()
                local h = io.open(devDir .. sep .. ".hotreload", "rb")
                if h == nil then h = io.open(root .. ".hotreload", "rb") end
                if h ~= nil then
                    h:close()
                    devEnabled = true
                end
            end)
        end
    end
end

local function DevLog(line)
    if not devEnabled or devDir == nil then return end
    local sep = (string.find(devDir, "\\", 1, true) ~= nil) and "\\" or "/"
    pcall(function()
        local h = io.open(devDir .. sep .. "dodge_dev.log", "a")
        if h ~= nil then
            h:write(string.format("[g%d +%dms] %s\n", DODGE_MOD_GEN, math.floor((os.clock() % 100000) * 1000), line))
            h:close()
        end
    end)
end

-- ================= configuration =================
local MODALITY        = "button"           -- "button" or "doubletap"
local KEY_DODGE_BTN   = "Left Alt"
local DT_LEFT         = "Z"
local DT_RIGHT        = "C"
local DT_BACK         = "S"
local SIDE_SPEED      = 650.0
local SIDE_UP         = 500.0
local BACK_SPEED      = 900.0
local BACK_UP         = 200.0
local STAMINA_COST    = 20.0
local REQUIRE_STAMINA = true
local DOUBLE_TAP_WINDOW = 0.25
local COOLDOWN          = 0.60

local function Trim(s)
    return (string.gsub(s or "", "^%s*(.-)%s*$", "%1"))
end

local function ParseIniValue(content, key)
    for line in string.gmatch(content, "[^\r\n]+") do
        if not string.match(line, "^%s*;") and not string.match(line, "^%s*%[") then
            local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k ~= nil and string.upper(k) == string.upper(key) then
                return v
            end
        end
    end
    return nil
end

local function ApplyConfig(content)
    local function num(key, current)
        local v = ParseIniValue(content, key)
        if v ~= nil and tonumber(v) ~= nil then return tonumber(v) end
        return current
    end
    local function str(key, current)
        local v = ParseIniValue(content, key)
        if v ~= nil and v ~= "" then return v end
        return current
    end
    MODALITY = string.lower(str("Modality", MODALITY))
    if MODALITY ~= "doubletap" then MODALITY = "button" end
    KEY_DODGE_BTN = str("ButtonKey", KEY_DODGE_BTN)
    DT_LEFT  = str("DoubleTapLeft", DT_LEFT)
    DT_RIGHT = str("DoubleTapRight", DT_RIGHT)
    DT_BACK  = str("DoubleTapBack", DT_BACK)
    SIDE_SPEED   = num("SideHorizontal", SIDE_SPEED)
    SIDE_UP      = num("SideVertical", SIDE_UP)
    BACK_SPEED   = num("BackHorizontal", BACK_SPEED)
    BACK_UP      = num("BackVertical", BACK_UP)
    STAMINA_COST = num("StaminaCost", STAMINA_COST)
    DOUBLE_TAP_WINDOW = num("DoubleTapWindow", DOUBLE_TAP_WINDOW)
end

local iniContent = nil
if cfgPath ~= nil then
    pcall(function()
        local h = io.open(cfgPath, "rb")
        if h ~= nil then
            iniContent = h:read("*a") or ""
            h:close()
        end
    end)
end
if iniContent ~= nil then ApplyConfig(iniContent) end

-- signal channel (written by DodgeSignal.ps1, read below) - named pipe,
-- kernel memory: nothing touches the disk
local signalPath = "\\\\.\\pipe\\DodgeModSignal"

-- ================= dodge logic =================
-- cached player controller: UEHelpers.GetPlayerController() runs an uncached
-- object-array scan (~25-30 ms) - calling it per press was the stutter
local pcCache = nil
local function GetPC()
    if pcCache ~= nil then
        local ok, valid = pcall(function() return pcCache:IsValid() end)
        if ok and valid then return pcCache end
        pcCache = nil
    end
    local ok, pc = pcall(function() return UEHelpers.GetPlayerController() end)
    if ok and pc ~= nil and pc:IsValid() then
        pcCache = pc
        return pc
    end
    return nil
end

local lastDodge = 0.0
local lastStaminaMsg = 0.0

local function Now()
    return os.clock()
end

local function SpendStamina(Pawn)
    if STAMINA_COST <= 0.0 then return true end
    local okCur, curSP = pcall(function() return Pawn:GetSP() end)
    if not okCur or curSP == nil then
        return true
    end
    if REQUIRE_STAMINA and curSP < STAMINA_COST then
        local t = Now()
        if t - lastStaminaMsg > 5.0 then
            lastStaminaMsg = t
            print(string.format("[Configurable Dodge Mod] not enough stamina (%.1f < %.1f)", curSP, STAMINA_COST))
        end
        DevLog(string.format("blocked: low stamina %.1f < %.1f", curSP, STAMINA_COST))
        return false
    end
    local newSP = math.floor(curSP - STAMINA_COST)
    if newSP < 0 then newSP = 0 end
    pcall(function() Pawn:ForceSetSP(newSP) end)
    DevLog(string.format("stamina %.1f -> %.1f", curSP, newSP))
    return true
end

local function BuildLaunchVector(direction)
    local PC = GetPC()
    if PC == nil then return nil end
    local CameraManager = PC.PlayerCameraManager
    if CameraManager == nil or not CameraManager:IsValid() then return nil end
    local MathLib = UEHelpers.GetKismetMathLibrary()
    local okRot, Rot = pcall(function() return CameraManager:GetCameraRotation() end)
    if not okRot or Rot == nil then return nil end

    local DirVector
    if direction == "left" then
        DirVector = MathLib:GetRightVector(Rot)
        DirVector = MathLib:Multiply_VectorFloat(DirVector, -1.0)
    elseif direction == "right" then
        DirVector = MathLib:GetRightVector(Rot)
    else
        DirVector = MathLib:GetForwardVector(Rot)
        DirVector = MathLib:Multiply_VectorFloat(DirVector, -1.0)
    end

    local speed, up
    if direction == "back" then speed, up = BACK_SPEED, BACK_UP
    else speed, up = SIDE_SPEED, SIDE_UP end

    local Lateral = MathLib:Multiply_VectorFloat(DirVector, speed)
    local Up = MathLib:Multiply_VectorFloat(MathLib:GetUpVector(Rot), up)
    return MathLib:Add_VectorVector(Lateral, Up)
end

local function DoDodge(direction)
    local dodgeT0 = Now()
    if Now() - lastDodge < COOLDOWN then return end
    local PC = GetPC()
    if PC == nil then return end
    local Pawn = PC.Pawn
    if Pawn == nil or not Pawn:IsValid() then return end

    -- no dodging while gameplay is UI-blocked (stash, conversations, pause)
    local blocked = false
    pcall(function()
        if PC.bShowMouseCursor then blocked = true end
    end)
    if blocked then
        DevLog("blocked: menu UI")
        return
    end

    local Velocity = BuildLaunchVector(direction)
    if Velocity == nil then return end

    if not SpendStamina(Pawn) then
        return
    end

    lastDodge = Now()
    DevLog(string.format("dodge dir=%s (handler %.3f ms)", tostring(direction), (Now() - dodgeT0) * 1000))

    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            Pawn:LaunchCharacter(Velocity, true, true)
        end)
        if not ok then
            print(string.format("[Configurable Dodge Mod] LaunchCharacter failed: %s", tostring(err)))
        end
    end)
end

-- cached movement component (live movement input vector)
local lastInputComponentCache = nil

local function GetMoveInputComponent(Pawn)
    if lastInputComponentCache ~= nil then
        local ok, valid = pcall(function() return lastInputComponentCache:IsValid() end)
        if ok and valid then return lastInputComponentCache end
        lastInputComponentCache = nil
    end
    local ok, CM = pcall(function() return Pawn:GetMovementComponent() end)
    if ok and CM ~= nil and CM:IsValid() then
        lastInputComponentCache = CM
        return CM
    end
    return nil
end

--- which direction is the player's movement input currently pressed in?
local function GetMoveInputDirection()
    local PC = GetPC()
    if PC == nil then return nil end
    local Pawn = PC.Pawn
    if Pawn == nil or not Pawn:IsValid() then return nil end
    local CM = GetMoveInputComponent(Pawn)
    if CM == nil then return nil end
    local ok, iv = pcall(function() return CM:GetLastInputVector() end)
    if not ok or iv == nil then return nil end
    local ix, iy, iz
    pcall(function()
        ix, iy, iz = iv.X, iv.Y, iv.Z
        if type(ix) ~= "number" and iv.get ~= nil then
            local t = iv:get()
            ix, iy, iz = t.X, t.Y, t.Z
        end
    end)
    if type(ix) ~= "number" then return nil end
    if ix * ix + iy * iy + iz * iz < 0.01 then return nil end

    local CameraManager = PC.PlayerCameraManager
    if CameraManager == nil or not CameraManager:IsValid() then return nil end
    local MathLib = UEHelpers.GetKismetMathLibrary()
    local okRot, rot = pcall(function() return CameraManager:GetCameraRotation() end)
    if not okRot or rot == nil then return nil end
    local fwd = MathLib:GetForwardVector(rot)
    local right = MathLib:GetRightVector(rot)
    local dotFwd = fwd.X * ix + fwd.Y * iy + fwd.Z * iz
    local dotRight = right.X * ix + right.Y * iy + right.Z * iz

    -- dominant camera axis decides (forward movement maps to no dodge)
    if math.abs(dotRight) >= math.abs(dotFwd) then
        if dotRight > 0.0 then return "right" else return "left" end
    else
        if dotFwd < 0.0 then return "back" end
    end
    return nil
end

--- button modality press: dodge in the direction the movement keys are
--- currently pressed; standing still / forward without lateral input = none
local function HandleButtonPress()
    if MODALITY ~= "button" then return end
    local t0 = Now()
    local d = GetMoveInputDirection()
    if d == nil then
        DevLog(string.format("press: no move input (%.3f ms)", (Now() - t0) * 1000))
        return
    end
    DoDodge(d)
    DevLog(string.format("press: dodge dir=%s handler=%.3f ms", d, (Now() - t0) * 1000))
end

-- ================= signal file polling =================
-- DodgeSignal.ps1 maintains press counters for the configured keys:
--   btn=N (button modality)  dtl=N dtr=N dtb=N (double-tap modality)
-- A counter increase = a (double-)tap completed in the listener; we dodge.
local signalLast = {}
local signalMissingNoticed = false

LoopAsync(50, function()
    if DodgeMod_Generation ~= DODGE_MOD_GEN then return true end
    if signalPath == nil then return false end
    local content
    pcall(function()
        local h = io.open(signalPath, "r")
        -- NOTE: read("*l"), not read("*a") - the C runtime rejects the
        -- "copy to EOF" read on Windows named pipes (EINVAL), while a
        -- single line read works. The listener writes one line per
        -- connection and disconnects (EOF).
        if h ~= nil then content = h:read("*l"); h:close() end
    end)
    if content == nil then
        -- listener not running (or starting up): inform once after a grace period
        if not signalMissingNoticed and GetPC() ~= nil and Now() > 15.0 then
            signalMissingNoticed = true
            local msg = "Dodge keys are inactive: the key listener is not running. Restart the game once (the mod starts it automatically), or run DodgeSignal.ps1 in the mod folder."
            print("[Configurable Dodge Mod] " .. msg)
            pcall(function()
                local PC = GetPC()
                if PC ~= nil then
                    UEHelpers.GetKismetSystemLibrary():PrintString(PC, msg, true, false, { R = 1.0, G = 0.6, B = 0.2, A = 1.0 }, 10.0)
                end
            end)
        end
        return false
    end
    signalMissingNoticed = false

    -- the listener sends all counters on one line ("btn=N dtl=N dtr=N dtb=N"),
    -- so split on whitespace and parse each token
    for token in string.gmatch(content, "%S+") do
        local k, v = string.match(token, "^(%w+)=(%d+)$")
        if k ~= nil then
            local n = tonumber(v)
            local last = signalLast[k]
            if last == nil then
                signalLast[k] = n
            elseif n > last then
                signalLast[k] = n
                if k == "btn" and MODALITY == "button" then
                    HandleButtonPress()
                elseif k == "dtl" and MODALITY == "doubletap" then
                    DoDodge("left")
                elseif k == "dtr" and MODALITY == "doubletap" then
                    DoDodge("right")
                elseif k == "dtb" and MODALITY == "doubletap" then
                    DoDodge("back")
                end
            end
        end
    end
    return false
end)

-- ================= movement double-tap (doubletap modality bonus) =========
-- double-tapping a movement direction itself dodges (A/A, D/D, S/S) - read
-- from the live movement input, so it follows the game's bindings
local moveTap  = { left = 0.0, right = 0.0, back = 0.0 }
local moveHold = { left = false, right = false, back = false }

LoopAsync(60, function()
    if DodgeMod_Generation ~= DODGE_MOD_GEN then return true end
    if MODALITY ~= "doubletap" then return false end
    local d = GetMoveInputDirection()
    for _, dir in ipairs({ "left", "right", "back" }) do
        if d == dir then
            if not moveHold[dir] then
                moveHold[dir] = true
                local t = Now()
                if t - moveTap[dir] <= DOUBLE_TAP_WINDOW then
                    moveTap[dir] = 0.0
                    DoDodge(dir)
                else
                    moveTap[dir] = t
                end
            end
        else
            moveHold[dir] = false
        end
    end
    return false
end)

-- ================= auto-start the signal listener =================
-- (os.execute verified available; the listener is mutex-guarded, so double
-- spawns are harmless, and it auto-exits when the game closes)
if os ~= nil and type(os.execute) == "function" and cfgPath ~= nil then
    local listenerPath = string.gsub(cfgPath, "ConfigurableDodgeMod%.ini$", "DodgeSignal.ps1")
    pcall(function()
        os.execute('start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. listenerPath .. '"')
    end)
    DevLog("signal listener auto-started")
end

print(string.format("[Configurable Dodge Mod] v2.2 loaded - mode: %s (%s), stamina cost %.0f",
    MODALITY,
    MODALITY == "button" and ("dodge button " .. KEY_DODGE_BTN) or ("double-tap " .. DT_LEFT .. "/" .. DT_RIGHT .. "/" .. DT_BACK),
    STAMINA_COST))
DevLog(string.format("boot v2.2 gen=%d mode=%s btn=%s dt=%s/%s/%s", DODGE_MOD_GEN, MODALITY, KEY_DODGE_BTN, DT_LEFT, DT_RIGHT, DT_BACK))

-- ================= hot reload (dev only, .hotreload gated) =================
DodgeMod_BootComplete = DODGE_MOD_GEN
DodgeMod_Handlers = function() end  -- legacy: re-pointed so old watchers see a handover
-- watches main.lua AND the ini; either changing re-executes the mod
if devEnabled and devDir ~= nil and cfgPath ~= nil then
    local sep = (string.find(devDir, "\\", 1, true) ~= nil) and "\\" or "/"
    local selfPath = devDir .. sep .. "main.lua"
    local WatchMain, WatchIni = nil, nil
    pcall(function()
        local h1 = io.open(selfPath, "rb"); if h1 ~= nil then WatchMain = h1:read("*a"); h1:close() end
        local h2 = io.open(cfgPath, "rb"); if h2 ~= nil then WatchIni = h2:read("*a"); h2:close() end
    end)
    LoopAsync(1200, function()
        if DodgeMod_Generation ~= DODGE_MOD_GEN then return true end
        local newMain, newIni
        pcall(function()
            local h1 = io.open(selfPath, "rb"); if h1 ~= nil then newMain = h1:read("*a"); h1:close() end
            local h2 = io.open(cfgPath, "rb"); if h2 ~= nil then newIni = h2:read("*a"); h2:close() end
        end)
        local mainChanged = newMain ~= nil and newMain ~= WatchMain
        local iniChanged = newIni ~= nil and WatchIni ~= nil and newIni ~= WatchIni
        if not mainChanged and not iniChanged then return false end
        WatchMain, WatchIni = newMain, WatchIni
        DevLog(mainChanged and "hot reload: main.lua changed" or "hot reload: ini changed")
        DodgeMod_Generation = DODGE_MOD_GEN + 1
        local oldHandlers = DodgeMod_Handlers
        local okR, errR = pcall(dofile, selfPath)
        if not okR or DodgeMod_BootComplete ~= DodgeMod_Generation then
            if not okR then DevLog("RELOAD ERROR: " .. tostring(errR)) else DevLog("RELOAD ERROR: chunk did not finish booting") end
            DodgeMod_Generation = DODGE_MOD_GEN
            return false
        end
        return true
    end)
    DevLog("hot reload active")
end

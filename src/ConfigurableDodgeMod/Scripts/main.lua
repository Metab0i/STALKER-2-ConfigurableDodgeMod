-- Configurable Dodge Mod for S.T.A.L.K.E.R. 2 (UE4SS Lua) - v2.4
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
local DOUBLE_TAP_WINDOW = 0.155
local COOLDOWN          = 0.60

local function Trim(s)
    return (string.gsub(s or "", "^%s*(.-)%s*$", "%1"))
end

local function ParseIniValue(content, key)
    for line in string.gmatch(content, "[^\r\n]+") do
        if not string.match(line, "^%s*;") and not string.match(line, "^%s*%[") then
            local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k ~= nil and string.upper(k) == string.upper(key) then
                return (string.gsub(v, "%s*;.*$", ""))
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
    if Now() - lastDodge < COOLDOWN then
        DevLog(string.format("press ignored: cooldown (%.2fs left)", COOLDOWN - (Now() - lastDodge)))
        return
    end
    local PC = GetPC()
    if PC == nil then
        DevLog("press ignored: no player controller")
        return
    end
    local Pawn = PC.Pawn
    if Pawn == nil or not Pawn:IsValid() then
        DevLog("press ignored: no pawn")
        return
    end

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
    if Velocity == nil then
        DevLog("press ignored: could not build launch vector")
        return
    end

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
local lastNotice = 0.0
local lastRespawn = 0.0

-- Read one state line from the pipe. The listener serves one connection per
-- poll (write + disconnect), so a connect can race the re-listen window; a
-- second attempt in the same tick covers that.
local function ReadSignalLine()
    local content
    -- NOTE: read("*l"), not read("*a") - the C runtime rejects the
    -- "copy to EOF" read on Windows named pipes (EINVAL), while a single
    -- line read works. The listener writes one line per connection.
    pcall(function()
        local h = io.open(signalPath, "r")
        if h ~= nil then content = h:read("*l"); h:close() end
    end)
    if content == nil then
        pcall(function()
            local h = io.open(signalPath, "r")
            if h ~= nil then content = h:read("*l"); h:close() end
        end)
    end
    return content
end

-- Start the key listener without any console window: wscript (a windowless
-- host) runs PowerShell hidden, so the listener cannot steal focus from the
-- game the way a `start /min powershell` console sometimes can.
local function SpawnListener()
    if os == nil or type(os.execute) ~= "function" or cfgPath == nil then return end
    local launcher = string.gsub(cfgPath, "ConfigurableDodgeMod%.ini$", "LaunchListener.vbs")
    pcall(function()
        os.execute('wscript.exe //nologo //B "' .. launcher .. '"')
    end)
end

local function SignalStep()
    if signalPath == nil then return end
    local content = ReadSignalLine()
    if content == nil then
        -- listener not running (or starting up): after a grace period, show a
        -- repeating on-screen notice (top-left, orange) AND respawn the
        -- listener automatically - a crashed listener no longer disables the
        -- mod until the next restart
        if Now() > 15.0 and GetPC() ~= nil then
            if Now() - lastNotice > 45.0 then
                lastNotice = Now()
                local msg = "Dodge keys are inactive: the key listener is not running - restarting it automatically."
                print("[Configurable Dodge Mod] " .. msg)
                pcall(function()
                    local PC = GetPC()
                    if PC ~= nil then
                        UEHelpers.GetKismetSystemLibrary():PrintString(PC, msg, true, false, { R = 1.0, G = 0.6, B = 0.2, A = 1.0 }, 15.0)
                    end
                end)
            end
            if Now() - lastRespawn > 30.0 and os ~= nil and type(os.execute) == "function" and cfgPath ~= nil then
                lastRespawn = Now()
                SpawnListener()
                DevLog("listener missing - respawn attempted")
            end
        end
        return
    end
    lastNotice = 0.0

    -- the listener sends all counters on one line ("btn=N dtl=N dtr=N dtb=N"),
    -- so split on whitespace and parse each token
    for token in string.gmatch(content, "%S+") do
        local k, v = string.match(token, "^(%w+)=(%d+)$")
        if k ~= nil then
            local n = tonumber(v)
            local last = signalLast[k]
            if last == nil then
                signalLast[k] = n
            elseif n < last then
                -- the listener restarted and its counters reset: re-baseline
                -- instead of ignoring every value until the old high is passed
                signalLast[k] = n
                DevLog("signal counters reset (" .. k .. ")")
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
end

-- IMPORTANT: the whole step is pcall'd every tick. An uncaught error inside a
-- LoopAsync callback stops that loop permanently (this silently disabled
-- dodging for a whole session before), so errors are logged and the loop
-- keeps running.
LoopAsync(50, function()
    if DodgeMod_Generation ~= DODGE_MOD_GEN then return true end
    local ok, err = pcall(SignalStep)
    if not ok then DevLog("signal poll error: " .. tostring(err)) end
    return false
end)

-- ================= auto-start the signal listener =================
-- (started windowless via LaunchListener.vbs; the listener is mutex-guarded,
-- so double spawns are harmless, and it exits with the game)
SpawnListener()
DevLog("signal listener auto-started")

print(string.format("[Configurable Dodge Mod] v2.4 loaded - mode: %s (%s), stamina cost %.0f",
    MODALITY,
    MODALITY == "button" and ("dodge button " .. KEY_DODGE_BTN) or ("double-tap " .. DT_LEFT .. "/" .. DT_RIGHT .. "/" .. DT_BACK),
    STAMINA_COST))
DevLog(string.format("boot v2.4 gen=%d mode=%s btn=%s dt=%s/%s/%s", DODGE_MOD_GEN, MODALITY, KEY_DODGE_BTN, DT_LEFT, DT_RIGHT, DT_BACK))

-- ================= ini live reload (always on) =================
-- the listener re-reads the ini every ~2 s for key detection; this keeps the
-- in-game values (forces, stamina, modality, window) in sync the same way, so
-- editing ConfigurableDodgeMod.ini applies live - no restart needed
if cfgPath ~= nil then
    LoopAsync(2000, function()
        if DodgeMod_Generation ~= DODGE_MOD_GEN then return true end
        local ok, err = pcall(function()
            local newIni
            pcall(function()
                local h = io.open(cfgPath, "rb")
                if h ~= nil then newIni = h:read("*a"); h:close() end
            end)
            if newIni ~= nil and newIni ~= iniContent then
                iniContent = newIni
                ApplyConfig(newIni)
                DevLog("ini reloaded: mode=" .. MODALITY .. " btn=" .. KEY_DODGE_BTN)
                print(string.format("[Configurable Dodge Mod] ini reloaded - mode %s, dodge button %s, stamina %.0f",
                    MODALITY, MODALITY == "button" and KEY_DODGE_BTN or (DT_LEFT .. "/" .. DT_RIGHT .. "/" .. DT_BACK), STAMINA_COST))
            end
        end)
        if not ok then DevLog("ini watcher error: " .. tostring(err)) end
        return false
    end)
end

-- ================= hot reload (dev only, .hotreload gated) =================
DodgeMod_BootComplete = DODGE_MOD_GEN
-- watches main.lua only; the ini has its own always-on watcher above
if devEnabled and devDir ~= nil then
    local sep = (string.find(devDir, "\\", 1, true) ~= nil) and "\\" or "/"
    local selfPath = devDir .. sep .. "main.lua"
    local WatchMain = nil
    pcall(function()
        local h1 = io.open(selfPath, "rb"); if h1 ~= nil then WatchMain = h1:read("*a"); h1:close() end
    end)
    LoopAsync(1200, function()
        if DodgeMod_Generation ~= DODGE_MOD_GEN then return true end
        local newMain
        pcall(function()
            local h1 = io.open(selfPath, "rb"); if h1 ~= nil then newMain = h1:read("*a"); h1:close() end
        end)
        if newMain == nil or newMain == WatchMain then return false end
        WatchMain = newMain
        DevLog("hot reload: main.lua changed")
        DodgeMod_Generation = DODGE_MOD_GEN + 1
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

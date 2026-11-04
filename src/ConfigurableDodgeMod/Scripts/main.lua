-- Configurable Dodge Mod for S.T.A.L.K.E.R. 2 (UE4SS Lua) - v2.0
-- Standalone: no MCM. Configured via ConfigurableDodgeMod.ini (next to this
-- mod's folder) or the interactive Setup.ps1 that ships with the mod.
--
-- Two modalities, exactly one active (set [Config] Modality in the ini):
--   "button"    - hold a movement key, press the configured dodge button
--   "doubletap" - double-tap the configured dodge keys (Z/C/S by default)
-- The ini is re-read live: save it and changes apply within ~2 seconds.

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
if devDir ~= nil then
    local sep = (string.find(devDir, "\\", 1, true) ~= nil) and "\\" or "/"
    pcall(function()
        local h = io.open(devDir .. sep .. ".hotreload", "rb")
        if h ~= nil then
            h:close()
            devEnabled = true
        end
    end)
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
-- Defaults (the ini overrides them; Setup.ps1 writes the ini)
local MODALITY        = "button"           -- "button" or "doubletap"
local KEY_DODGE_BTN   = "Left Alt"         -- button modality
local DT_LEFT         = "Z"                -- double-tap modality
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
local ENABLE_BACK       = true

-- mod root (Scripts/..) - the ini lives there
local cfgPath = nil
do
    if devDir ~= nil then
        local lower = string.lower(devDir)
        local s = string.match(lower, "()scripts$")
        if s ~= nil then
            cfgPath = string.sub(devDir, 1, s - 1) .. "ConfigurableDodgeMod.ini"
        else
            local sep = (string.find(devDir, "\\", 1, true) ~= nil) and "\\" or "/"
            cfgPath = devDir .. sep .. ".." .. sep .. "ConfigurableDodgeMod.ini"
        end
    end
end

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

local lastTap   = { left = 0.0, right = 0.0, back = 0.0 }
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
        lastTap.left, lastTap.right, lastTap.back = 0.0, 0.0, 0.0
        return
    end

    local Velocity = BuildLaunchVector(direction)
    if Velocity == nil then return end

    if not SpendStamina(Pawn) then
        lastTap.left, lastTap.right, lastTap.back = 0.0, 0.0, 0.0
        return
    end

    lastDodge = Now()
    lastTap.left, lastTap.right, lastTap.back = 0.0, 0.0, 0.0
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

-- cached movement component (for the live movement input vector)
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
--- (the game's own input state, so it follows the game's bindings)
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

--- double-tap modality tap (keybind callback)
local function HandleTap(direction)
    if MODALITY ~= "doubletap" then return end
    local t = Now()
    if t - lastTap[direction] <= DOUBLE_TAP_WINDOW then
        lastTap[direction] = 0.0
        DoDodge(direction)
    else
        lastTap[direction] = t
    end
end

-- ================= input delivery =================
-- UE4SS has NO working keybind unregister, and its window-message hooks can
-- be unreliable in gameplay after world loads. So: each unique key is bound
-- exactly once per session with a thin callback routing through globals
-- (DodgeMod_Dispatch -> DodgeMod_Handlers, re-pointed by every reload), and
-- the hooks are re-registered whenever a new PlayerController spawns.
DodgeMod_BoundKeys = DodgeMod_BoundKeys or {}

local keyNameToValue = {}
for name, value in pairs(Key) do
    keyNameToValue[string.upper(name)] = value
end

local MOUSE_ALIASES = {
    THUMBMOUSEBUTTON  = "XBUTTON_ONE",
    THUMBMOUSEBUTTON2 = "XBUTTON_TWO",
    MOUSE4            = "XBUTTON_ONE",
    MOUSE5            = "XBUTTON_TWO",
    MOUSEBUTTON4      = "XBUTTON_ONE",
    MOUSEBUTTON5      = "XBUTTON_TWO",
}

local function ResolveKey(displayName)
    if type(displayName) ~= "string" or displayName == "" then return nil end
    -- Virtual-Key hex values (e.g. 0x58 = X, 0x05 = Mouse 4) bind directly.
    -- MODIFIER VKs (0xA0-0xA5, 0x10-0x12: Alt/Ctrl/Shift) register but never
    -- fire: they generate WM_SYSKEYDOWN which UE4SS does not process
    -- (verified live, boot-context registration). Reject them loudly.
    local hexv = string.match(string.upper(displayName), "^0X([0-9A-F][0-9A-F]?)$")
    if hexv ~= nil then
        local v = tonumber(hexv, 16)
        if v ~= nil and v >= 1 and v <= 0xFE then
            if (v >= 0xA0 and v <= 0xA5) or (v >= 0x10 and v <= 0x12) then
                return nil, "modifier keys (Alt/Ctrl/Shift) generate WM_SYSKEYDOWN which UE4SS does not process"
            end
            return v
        end
        return nil
    end
    if type(displayName) ~= "string" or displayName == "" then return nil end
    local name = string.upper(displayName)
    local v = keyNameToValue[name]
    if v ~= nil then return v end
    v = keyNameToValue[string.gsub(name, "%s+", "_")]
    if v ~= nil then return v end
    local collapsed = string.gsub(name, "[^%w]", "")
    v = keyNameToValue[collapsed]
    if v ~= nil then return v end
    local alias = MOUSE_ALIASES[collapsed]
    if alias ~= nil then return keyNameToValue[alias] end
    return nil
end

function DodgeMod_Dispatch(role, keyUpper)
    local H = DodgeMod_Handlers
    if H == nil then return end
    H(role, keyUpper)
end

local function EnsureBind(role, displayName)
    if type(displayName) ~= "string" or displayName == "" then return end
    local u = string.upper(displayName)
    if DodgeMod_BoundKeys[u] ~= nil then return end
    local k = ResolveKey(displayName)
    if k == nil then
        print("[Configurable Dodge Mod] cannot bind " .. role .. " key '" .. displayName .. "' (not a bindable key - modifiers like Alt are not supported; try a mouse button or another key)")
        return
    end
    DodgeMod_BoundKeys[u] = role
    local ok = pcall(function()
        RegisterKeyBind(k, function() DodgeMod_Dispatch(role, u) end)
    end)
    if not ok then
        DodgeMod_BoundKeys[u] = nil
        print("[Configurable Dodge Mod] RegisterKeyBind failed for " .. role .. " key: " .. displayName)
    else
        DevLog("bound role=" .. role .. " key=" .. displayName)
    end
end

function RebindKeys()
    if MODALITY == "doubletap" then
        EnsureBind("dt_left", DT_LEFT)
        EnsureBind("dt_right", DT_RIGHT)
        if ENABLE_BACK then EnsureBind("dt_back", DT_BACK) end
    else
        EnsureBind("button", KEY_DODGE_BTN)
    end
end

-- re-register hooks when the world changes (new PlayerController spawned):
-- heals the flaky gameplay delivery without stacking more than one bind per
-- world load, and name-filtered dispatch keeps stale callbacks harmless
local lastRebindAt = 0.0
NotifyOnNewObject("/Script/Engine.PlayerController", function()
    local t = Now()
    if t - lastRebindAt < 5.0 then return end
    lastRebindAt = t
    DodgeMod_BoundKeys = {}
    RebindKeys()
    DevLog("re-registered keybinds (new PlayerController)")
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

-- ================= boot =================
RebindKeys()

print(string.format("[Configurable Dodge Mod] v2.0 loaded - mode: %s (%s), stamina cost %.0f",
    MODALITY,
    MODALITY == "button" and ("dodge button " .. KEY_DODGE_BTN) or ("double-tap " .. DT_LEFT .. "/" .. DT_RIGHT .. (ENABLE_BACK and ("/" .. DT_BACK) or "")),
    STAMINA_COST))
DevLog(string.format("boot v2.0 gen=%d mode=%s btn=%s dt=%s/%s/%s", DODGE_MOD_GEN, MODALITY, KEY_DODGE_BTN, DT_LEFT, DT_RIGHT, DT_BACK))

-- ================= hot reload (dev only, .hotreload gated) =================
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
        if not okR or DodgeMod_Handlers == oldHandlers then
            if not okR then DevLog("RELOAD ERROR: " .. tostring(errR)) else DevLog("RELOAD ERROR: chunk did not finish booting") end
            DodgeMod_Generation = DODGE_MOD_GEN
            return false
        end
        return true
    end)
    DevLog("hot reload active")
end

-- ================= dispatcher wiring (must stay last) =================
DodgeMod_Handlers = function(role, keyUpper)
    if MODALITY == "doubletap" then
        if role == "dt_left" and keyUpper == string.upper(DT_LEFT) then
            HandleTap("left")
        elseif role == "dt_right" and keyUpper == string.upper(DT_RIGHT) then
            HandleTap("right")
        elseif role == "dt_back" and keyUpper == string.upper(DT_BACK) then
            HandleTap("back")
        end
        return
    end
    if role == "button" and keyUpper == string.upper(KEY_DODGE_BTN) then
        HandleButtonPress()
    end
end
DevLog("dispatcher wired gen=" .. tostring(DODGE_MOD_GEN))

-- TEST: does an Input table exist?
if devEnabled then
    DevLog("probe: type(Input)=" .. type(Input))
    if type(Input) == "table" then
        for _, n in ipairs({ "IsKeyPressed", "IsKeyDown", "GetKey", "WasKeyPressed" }) do
            DevLog("probe: Input." .. n .. " = " .. type(Input[n]))
        end
        local ok, r = pcall(function() return Input.IsKeyPressed(0x58) end)
        DevLog("probe: IsKeyPressed(0x58) -> " .. tostring(ok) .. " / " .. tostring(r))
    end
end

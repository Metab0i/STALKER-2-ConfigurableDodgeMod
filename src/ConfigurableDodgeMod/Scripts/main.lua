-- Configurable Dodge Mod for S.T.A.L.K.E.R. 2 (UE4SS Lua) - v2.4
-- PROTOTYPE BRANCH (experiment/native-input): input is read through the
-- engine's own key state (PlayerController:IsInputKeyDown) with edge
-- detection and double-tap timing in Lua. No PowerShell listener, no pipe.
-- Config: ConfigurableDodgeMod.ini (live-reloaded).

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

-- ================= engine input (native prototype) =================
-- Reads the configured keys through the game's own input system instead of the
-- PowerShell listener: no external process, no pipe, no window hooks.
-- Keys are resolved from the same ini values Setup writes (VK hex or names,
-- including mouse buttons and modifiers).

local FKEY_BY_VK = {
    [0x08] = "BackSpace", [0x09] = "Tab", [0x0D] = "Enter", [0x13] = "Pause", [0x14] = "CapsLock",
    [0x1B] = "Escape", [0x20] = "SpaceBar", [0x21] = "PageUp", [0x22] = "PageDown", [0x23] = "End",
    [0x24] = "Home", [0x25] = "Left", [0x26] = "Up", [0x27] = "Right", [0x28] = "Down",
    [0x2D] = "Insert", [0x2E] = "Delete",
    [0x5B] = "LeftWindows", [0x5C] = "RightWindows",
    [0xA0] = "LeftShift", [0xA1] = "RightShift", [0xA2] = "LeftControl", [0xA3] = "RightControl",
    [0xA4] = "LeftAlt", [0xA5] = "RightAlt",
    [0xBA] = "Semicolon", [0xBB] = "Equals", [0xBC] = "Comma", [0xBD] = "Hyphen", [0xBE] = "Period",
    [0xBF] = "Slash", [0xC0] = "Tilde", [0xDB] = "LeftBracket", [0xDC] = "Backslash",
    [0xDD] = "RightBracket", [0xDE] = "Apostrophe", [0xE2] = "Backslash",
    [0x01] = "LeftMouseButton", [0x02] = "RightMouseButton", [0x04] = "MiddleMouseButton",
    [0x05] = "ThumbMouseButton", [0x06] = "ThumbMouseButton2",
}
local DIGIT_FKEY = { "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }
for i = 0, 9 do FKEY_BY_VK[0x30 + i] = DIGIT_FKEY[i + 1] end
for i = 1, 12 do FKEY_BY_VK[0x6F + i] = "F" .. i end
for i = 0, 25 do FKEY_BY_VK[0x41 + i] = string.char(65 + i) end

local NAME_ALIAS = {
    ["Left Alt"] = "LeftAlt", ["Right Alt"] = "RightAlt",
    ["Left Ctrl"] = "LeftControl", ["Right Ctrl"] = "RightControl",
    ["Left Control"] = "LeftControl", ["Right Control"] = "RightControl",
    ["Left Shift"] = "LeftShift", ["Right Shift"] = "RightShift",
    ["Left Win"] = "LeftWindows", ["Right Win"] = "RightWindows",
    ["Space"] = "SpaceBar", ["Backspace"] = "BackSpace",
    [";"] = "Semicolon", ["="] = "Equals", [","] = "Comma", ["-"] = "Hyphen", ["."] = "Period",
    ["/"] = "Slash", ["`"] = "Tilde", ["["] = "LeftBracket", ["\\"] = "Backslash",
    ["]"] = "RightBracket", ["'"] = "Apostrophe",
}

local function ResolveFKeyName(raw)
    if raw == nil then return nil end
    local v = Trim(raw)
    if v == "" then return nil end
    local hex = string.match(v, "^0[xX](%x+)$")
    if hex ~= nil then return FKEY_BY_VK[tonumber(hex, 16)] end
    if NAME_ALIAS[v] ~= nil then return NAME_ALIAS[v] end
    if v:match("^%d$") then return DIGIT_FKEY[tonumber(v) + 1] end
    if v:match("^[%a][%w_]*$") then return v end
    return nil
end

-- This UE4SS build exposes FName but not an FKey constructor, so an FKey
-- instance is cloned from the player input's debug exec bindings and renamed.
local function MakeFKey(name, index)
    if name == nil then return nil end
    local PC = GetPC()
    if PC == nil then return nil end
    local okPI, PI = pcall(function() return PC.PlayerInput end)
    if not okPI or PI == nil then return nil end
    local okB, binds = pcall(function() return PI.DebugExecBindings end)
    if not okB or binds == nil then return nil end
    local okK, key = pcall(function() return binds[index or 1].Key end)
    if not okK or key == nil then return nil end
    local okSet = pcall(function() key.KeyName = UEHelpers.FindOrAddFName(name) end)
    if not okSet then return nil end
    return key
end

local BtnName, DTName = nil, { left = nil, right = nil, back = nil }
local BtnKey, DTKey = nil, { left = nil, right = nil, back = nil }
local prevDown = {}
local lastTap = { left = 0.0, right = 0.0, back = 0.0 }

local function BuildKeys()
    BtnName = ResolveFKeyName(KEY_DODGE_BTN)
    DTName.left = ResolveFKeyName(DT_LEFT)
    DTName.right = ResolveFKeyName(DT_RIGHT)
    DTName.back = ResolveFKeyName(DT_BACK)
    BtnKey = MakeFKey(BtnName, 1)
    DTKey.left = MakeFKey(DTName.left, 2)
    DTKey.right = MakeFKey(DTName.right, 3)
    DTKey.back = MakeFKey(DTName.back, 4)
    prevDown = {}
    lastTap = { left = 0.0, right = 0.0, back = 0.0 }
    DevLog(string.format("native input keys: btn=%s dt=%s/%s/%s structs=%s/%s/%s/%s",
        tostring(BtnName), tostring(DTName.left), tostring(DTName.right), tostring(DTName.back),
        tostring(BtnKey ~= nil), tostring(DTKey.left ~= nil), tostring(DTKey.right ~= nil), tostring(DTKey.back ~= nil)))
    local function keyName(k)
        if k == nil then return "nil" end
        local ok, v = pcall(function() return k.KeyName:ToString() end)
        if ok then return tostring(v) end
        return tostring(k.KeyName)
    end
    DevLog("native key names: btn=" .. keyName(BtnKey) .. " dt=" .. keyName(DTKey.left) .. "/" .. keyName(DTKey.right) .. "/" .. keyName(DTKey.back))
end

-- edge detection on the engine's own key state (frame independent)
local lastPcWarn = 0.0
local function KeyJustPressed(id, key)
    if key == nil then return false end
    local PC = GetPC()
    if PC == nil then
        if Now() - lastPcWarn > 10.0 then
            lastPcWarn = Now()
            DevLog("native input: no player controller")
        end
        return false
    end
    local ok, down = pcall(function() return PC:IsInputKeyDown(key) end)
    if not ok then
        if Now() - lastPcWarn > 10.0 then
            lastPcWarn = Now()
            DevLog("native input: IsInputKeyDown failed for " .. id)
        end
        down = false
    end
    local pressed = down and not prevDown[id]
    prevDown[id] = down
    if pressed then DevLog("engine key down: " .. id) end
    return pressed
end

local function NativeStep()
    if GetPC() == nil then return end
    if MODALITY == "button" then
        if KeyJustPressed("btn", BtnKey) then
            HandleButtonPress()
        end
        return
    end
    for _, d in ipairs({ "left", "right", "back" }) do
        if KeyJustPressed("dt" .. d, DTKey[d]) then
            local t = Now()
            if lastTap[d] > 0.0 and (t - lastTap[d]) <= DOUBLE_TAP_WINDOW then
                lastTap[d] = 0.0
                DoDodge(d)
            else
                lastTap[d] = t
            end
        end
    end
end

BuildKeys()

LoopAsync(10, function()
    if DodgeMod_Generation ~= DODGE_MOD_GEN then return true end
    local ok, err = pcall(NativeStep)
    if not ok then DevLog("native input error: " .. tostring(err)) end
    return false
end)

print("[Configurable Dodge Mod] input: engine polling (native prototype)")
print(string.format("[Configurable Dodge Mod] v2.4 loaded - native input - mode: %s (%s), stamina cost %.0f",
    MODALITY,
    MODALITY == "button" and ("dodge button " .. KEY_DODGE_BTN) or ("double-tap " .. DT_LEFT .. "/" .. DT_RIGHT .. "/" .. DT_BACK),
    STAMINA_COST))
DevLog(string.format("boot v2.4 gen=%d input=native mode=%s btn=%s dt=%s/%s/%s", DODGE_MOD_GEN, MODALITY, KEY_DODGE_BTN, DT_LEFT, DT_RIGHT, DT_BACK))

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
                BuildKeys()
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

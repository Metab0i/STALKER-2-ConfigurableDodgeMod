-- Configurable Dodge Mod for S.T.A.L.K.E.R. 2 (UE4SS Lua) - v3.4
-- Input: UE4SS keybind events only, including raw modifier-key bindings.
-- No listener, no pipe, no hooks, no engine key-state polling.
-- Config: ConfigurableDodgeMod.ini (live-reloaded).

local UEHelpers = require("UEHelpers")

-- Invalidate stale asynchronous callbacks if UE4SS restarts the mod.
DodgeMod_Generation = (DodgeMod_Generation or 0) + 1
local DODGE_MOD_GEN = DodgeMod_Generation

-- Discover the installed ini beside the Scripts directory. This path lookup is
-- production configuration loading, not a development/debug facility.
local cfgPath = nil
do
    local src = nil
    pcall(function()
        local s = debug.getinfo(1, "S").source
        src = string.sub(s, 1, 1) == "@" and string.sub(s, 2) or s
    end)
    local scriptDir = src ~= nil and string.match(src, "^(.*)[/\\][^/\\]+$") or nil
    if scriptDir ~= nil then
        local s = string.match(string.lower(scriptDir), "()scripts$")
        if s ~= nil then
            cfgPath = string.sub(scriptDir, 1, s - 1) .. "ConfigurableDodgeMod.ini"
        end
    end
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
local STAMINA_COST    = 15.0
local REQUIRE_STAMINA = true
local DOUBLE_TAP_WINDOW = 0.155
local COOLDOWN          = 0.60
local ENERGY_DRINK_ENABLED = true
local ENERGY_DRINK_FREE_SECONDS = 4.5
local ENERGY_DRINK_JUMP = 50.0

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
    ENERGY_DRINK_ENABLED = num("EnergyDrinkEffect", ENERGY_DRINK_ENABLED and 1 or 0) ~= 0
    ENERGY_DRINK_FREE_SECONDS = num("EnergyDrinkFreeSeconds", ENERGY_DRINK_FREE_SECONDS)
    ENERGY_DRINK_JUMP = num("EnergyDrinkOveruseJump", ENERGY_DRINK_JUMP)
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
local energyFreeUntil = 0.0
local lastOveruse = nil
local lastOveruseAt = 0.0
local lastPawnKey = nil

local function Now()
    return os.clock()
end

local function ParamNumber(p)
    if p == nil then return nil end
    if type(p) == "number" then return p end
    local v = nil
    pcall(function() v = p:get() end)
    if v == nil then pcall(function() v = p:ToString() end) end
    if type(v) == "number" then return v end
    if v ~= nil then
        local n = tonumber(v)
        if n ~= nil then return n end
    end
    return nil
end

local function PawnKey(obj)
    local key = nil
    pcall(function() key = obj:GetAddress() end)
    if key == nil then pcall(function() key = obj:GetFullName() end) end
    return key
end

-- Single place that consumes a periodic or per-dodge overuse sample. A sharp
-- rise means a drink was just consumed; a changed pawn resets the baseline so
-- loading a save can never look like a drink.
local function ObserveOveruse(v, t, key, recent)
    if v == nil then return end
    if key ~= nil and key ~= lastPawnKey then
        lastPawnKey = key
        lastOveruse = nil
    end
    -- only a jump between two recent samples counts as a drink
    if recent and lastOveruse ~= nil and (v - lastOveruse) >= ENERGY_DRINK_JUMP then
        energyFreeUntil = t + ENERGY_DRINK_FREE_SECONDS
    end
    lastOveruseAt = t
    lastOveruse = v
end

local function RefreshOveruse(Pawn)
    local ok, ou = pcall(function() return Pawn:GetEnergeticOveruseValue() end)
    if not ok then return end
    local v = ParamNumber(ou)
    if v == nil then return end
    local t = Now()
    local recent = lastOveruse ~= nil and (t - lastOveruseAt) <= 5.0
    ObserveOveruse(v, t, PawnKey(Pawn), recent)
end

local function SpendStamina(Pawn)
    if STAMINA_COST <= 0.0 then return true end
    if ENERGY_DRINK_ENABLED then
        RefreshOveruse(Pawn)
    end
    if ENERGY_DRINK_ENABLED and Now() < energyFreeUntil then
        return true
    end
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
        return false
    end
    local newSP = math.floor(curSP - STAMINA_COST)
    if newSP < 0 then newSP = 0 end
    pcall(function() Pawn:ForceSetSP(newSP) end)
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
    if blocked then return end

    local Velocity = BuildLaunchVector(direction)
    if Velocity == nil or not SpendStamina(Pawn) then return end

    lastDodge = Now()
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
    local d = GetMoveInputDirection()
    if d ~= nil then DoDodge(d) end
end

-- ================= UE4SS keybind input =================
-- Resolves friendly ini aliases and Windows VK-hex values into key names,
-- then registers the corresponding UE4SS keybind events.

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
    [0x6A] = "Multiply", [0x6B] = "Add", [0x6D] = "Subtract", [0x6E] = "Decimal", [0x6F] = "Divide",
    [0x90] = "NumLock", [0x91] = "ScrollLock",
    [0x01] = "LeftMouseButton", [0x02] = "RightMouseButton", [0x04] = "MiddleMouseButton",
    [0x05] = "ThumbMouseButton", [0x06] = "ThumbMouseButton2",
}
local DIGIT_FKEY = { "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }
for i = 0, 9 do FKEY_BY_VK[0x30 + i] = DIGIT_FKEY[i + 1] end
for i = 1, 12 do FKEY_BY_VK[0x6F + i] = "F" .. i end
for i = 0, 25 do FKEY_BY_VK[0x41 + i] = string.char(65 + i) end
local NUMPAD_FKEY = { "NumPadZero", "NumPadOne", "NumPadTwo", "NumPadThree", "NumPadFour", "NumPadFive", "NumPadSix", "NumPadSeven", "NumPadEight", "NumPadNine" }
for i = 0, 9 do FKEY_BY_VK[0x60 + i] = NUMPAD_FKEY[i + 1] end

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
-- UE4SS Key enum names used for ordinary keybind registration
local KEYENUM_BY_NAME = {}
do
    local function add(n, kname)
        local ok, v = pcall(function() return Key[kname] end)
        if ok and v ~= nil then KEYENUM_BY_NAME[n] = v end
    end
    for c = string.byte("A"), string.byte("Z") do
        local ch = string.char(c)
        add(ch, ch)
    end
    local DIG = { "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE" }
    for i = 0, 9 do
        add(tostring(i), DIG[i + 1])
        add(DIG[i + 1], DIG[i + 1])
    end
    for i = 1, 12 do add("F" .. i, "F" .. i) end
    add("Left", "LEFT_ARROW"); add("Up", "UP_ARROW"); add("Right", "RIGHT_ARROW"); add("Down", "DOWN_ARROW")
    add("Home", "HOME"); add("End", "END"); add("PageUp", "PAGE_UP"); add("PageDown", "PAGE_DOWN")
    add("Insert", "INS"); add("Delete", "DEL")
    add("BackSpace", "BACKSPACE"); add("Tab", "TAB"); add("Enter", "RETURN"); add("Escape", "ESCAPE")
    add("SpaceBar", "SPACE"); add("Pause", "PAUSE"); add("CapsLock", "CAPS_LOCK")
    add("NumLock", "NUM_LOCK"); add("ScrollLock", "SCROLL_LOCK")
    add("LeftWindows", "LEFT_WIN"); add("RightWindows", "RIGHT_WIN")
    for i = 0, 9 do add("NumPad" .. DIG[i + 1], "NUM_" .. DIG[i + 1]) end
    add("Multiply", "MULTIPLY"); add("Add", "ADD"); add("Subtract", "SUBTRACT")
    add("Decimal", "DECIMAL"); add("Divide", "DIVIDE")
    add("Semicolon", "OEM_ONE"); add("Equals", "OEM_PLUS"); add("Comma", "OEM_COMMA")
    add("Hyphen", "OEM_MINUS"); add("Period", "OEM_PERIOD"); add("Slash", "OEM_TWO")
    add("Tilde", "OEM_THREE"); add("LeftBracket", "OEM_FOUR"); add("Backslash", "OEM_FIVE")
    add("RightBracket", "OEM_SIX"); add("Apostrophe", "OEM_SEVEN")
    add("LeftMouseButton", "LEFT_MOUSE_BUTTON"); add("RightMouseButton", "RIGHT_MOUSE_BUTTON")
    add("MiddleMouseButton", "MIDDLE_MOUSE_BUTTON"); add("ThumbMouseButton", "XBUTTON_ONE")
    add("ThumbMouseButton2", "XBUTTON_TWO")
end

-- UE4SS omits modifiers from its public Key table, but its Win32 input source
-- still polls their virtual-key codes. A modifier press also reports its generic
-- modifier bit, so both the key and that modifier must be registered.
local MODIFIER_BIND_BY_NAME = {
    LeftShift    = { key = 0xA0, modifiers = { 0x10 } },
    RightShift   = { key = 0xA1, modifiers = { 0x10 } },
    LeftControl  = { key = 0xA2, modifiers = { 0x11 } },
    RightControl = { key = 0xA3, modifiers = { 0x11 } },
    LeftAlt      = { key = 0xA4, modifiers = { 0x12 } },
    RightAlt     = { key = 0xA5, modifiers = { 0x12 } },
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

local BtnName, DTName = nil, { left = nil, right = nil, back = nil }
local lastTap = { left = 0.0, right = 0.0, back = 0.0 }

local function ResolveInputKeys()
    BtnName = ResolveFKeyName(KEY_DODGE_BTN)
    DTName.left = ResolveFKeyName(DT_LEFT)
    DTName.right = ResolveFKeyName(DT_RIGHT)
    DTName.back = ResolveFKeyName(DT_BACK)
    lastTap = { left = 0.0, right = 0.0, back = 0.0 }
end

ExecuteInGameThread(function() pcall(ResolveInputKeys) end)

-- ---------------- input: keybind events ----------------
local function TapKey(d)
    local t = Now()
    if lastTap[d] > 0.0 and (t - lastTap[d]) <= DOUBLE_TAP_WINDOW then
        lastTap[d] = 0.0
        DoDodge(d)
    else
        lastTap[d] = t
    end
end

DodgeMod_KeyActions = {}

local function RegisterInputKey(ke, modifiers)
    if ke == nil then return end
    modifiers = modifiers or {}
    local okReg, isReg = pcall(function() return IsKeyBindRegistered(ke, modifiers) end)
    if okReg and isReg then return end
    local ok, err = pcall(function()
        RegisterKeyBindAsync(ke, modifiers, function()
            local act = DodgeMod_KeyActions[ke]
            if act == nil then return end
            ExecuteInGameThread(function()
                local ok2, err2 = pcall(act)
                if not ok2 then print("[Configurable Dodge Mod] keybind action error: " .. tostring(err2)) end
            end)
        end)
    end)
    if not ok then
        print("[Configurable Dodge Mod] keybind registration failed for key=" .. tostring(ke) .. ": " .. tostring(err))
    end
end

local function EnsureInputBinds()
    local desired = {}
    local desiredModifiers = {}
    local function addBind(name, action)
        local spec = name ~= nil and MODIFIER_BIND_BY_NAME[name] or nil
        local ke = spec ~= nil and spec.key or (name ~= nil and KEYENUM_BY_NAME[name] or nil)
        if ke == nil then return end
        desired[ke] = action
        desiredModifiers[ke] = spec ~= nil and spec.modifiers or {}
    end

    if MODALITY == "button" then
        addBind(BtnName, HandleButtonPress)
    else
        for _, d in ipairs({ "left", "right", "back" }) do
            addBind(DTName[d], function() TapKey(d) end)
        end
    end
    DodgeMod_KeyActions = desired
    for ke in pairs(desired) do RegisterInputKey(ke, desiredModifiers[ke]) end
end

pcall(EnsureInputBinds)

-- 1 s maintenance: energy baseline and keybind upkeep
LoopAsync(1000, function()
    if DodgeMod_Generation ~= DODGE_MOD_GEN then return true end
    ExecuteInGameThread(function()
        pcall(function()
            local PC = GetPC()
            if PC == nil then return end
            local pawn = PC.Pawn
            if pawn ~= nil and pawn:IsValid() and ENERGY_DRINK_ENABLED then
                RefreshOveruse(pawn)
            end
            EnsureInputBinds()
        end)
    end)
    return false
end)
print(string.format("[Configurable Dodge Mod] v3.4 loaded - keybind input - mode: %s (%s), stamina cost %.0f",
    MODALITY,
    MODALITY == "button" and ("dodge button " .. KEY_DODGE_BTN) or ("double-tap " .. DT_LEFT .. "/" .. DT_RIGHT .. "/" .. DT_BACK),
    STAMINA_COST))

-- ================= ini live reload (always on) =================
-- File I/O stays off the game thread; applying the new values is scheduled on
-- the game thread. Changes apply within about two seconds without a restart.
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
                ExecuteInGameThread(function()
                    local ok2, err2 = pcall(function()
                        ApplyConfig(newIni)
                        ResolveInputKeys()
                        print(string.format("[Configurable Dodge Mod] ini reloaded - mode %s, dodge button %s, stamina %.0f",
                            MODALITY, MODALITY == "button" and KEY_DODGE_BTN or (DT_LEFT .. "/" .. DT_RIGHT .. "/" .. DT_BACK), STAMINA_COST))
                    end)
                    if not ok2 then print("[Configurable Dodge Mod] ini apply error: " .. tostring(err2)) end
                end)
            end
        end)
        if not ok then print("[Configurable Dodge Mod] ini watcher error: " .. tostring(err)) end
        return false
    end)
end




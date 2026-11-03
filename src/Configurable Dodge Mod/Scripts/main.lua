-- Configurable Dodge Mod - a from-scratch dodge mod for STALKER 2 (UE4SS Lua)
-- v1.5: MCM (Mod Configuration Menu) integration + stamina + rebindable
-- double-tap keys. Live values are polled from MCM every couple of seconds.

local UEHelpers = require("UEHelpers")

-- ================= Defaults (MCM overrides these at runtime) =================
local SIDE_SPEED        = 900.0   -- horizontal launch for left/right (cm/s)
local SIDE_UP           = 650.0   -- upward launch for left/right (cm/s)
local BACK_SPEED        = 900.0   -- horizontal launch for back (cm/s)
local BACK_UP           = 200.0   -- upward launch for back (cm/s)
local STAMINA_COST      = 20.0    -- stamina points per dodge (vanilla jump = 20)
local REQUIRE_STAMINA   = true    -- block dodge if stamina insufficient
local DOUBLE_TAP_WINDOW = 0.25    -- seconds between taps to count as double-tap
local COOLDOWN          = 0.60    -- seconds between dodges
local ENABLE_BACK       = true

local KEY_LEFT  = "Z"
local KEY_RIGHT = "C"
local KEY_BACK  = "S"

-- ================= MCM bridge =================
local MOD_ID = "Configurable Dodge Mod"
local AUTHOR = "Configurable Dodge Mod Team"

-- E_MCM_SettingType numbers. The enum's names are stripped in the shipping
-- build, so the mapping is resolved by a one-time in-menu probe (see
-- docs/mcm). Fill these in after the user reports the probe results.
local MCM_TYPE_FLOAT   = nil
local MCM_TYPE_KEYBIND = nil

--- register one setting as both the default row and the normal row
local function MCMRegister(Manager, id, typeNum, values)
    -- values is a table with the current/default payloads
    local argsDefault = {
        MOD_ID, id, id .. " (Configurable Dodge Mod default)", nil, AUTHOR, nil, nil,
        typeNum, true, 0, values.defaultFloat, 10.0, values.defaultKey, ""
    }
    local argsCurrent = {
        MOD_ID, id, "Tap-dodge tuning. Hover text kept short.", nil, AUTHOR,
        nil, nil, typeNum,
        true, 0, values.currentFloat, values.step or 10.0, values.currentKey, ""
    }
    local okD = pcall(function() Manager:RegisterDefaultModSetting(unpack(argsDefault)) end)
    local okR = pcall(function() Manager:RegisterModSetting(unpack(argsCurrent)) end)
    return okD and okR
end

--- one-time registration sequence
local mcmsRegistered = false
local function RegisterAllSettings(Manager)
    if mcmsRegistered then return true end
    if MCM_TYPE_FLOAT == nil or MCM_TYPE_KEYBIND == nil then return false end

    local floatEntries = {
        { id = "Side Horizontal", value = SIDE_SPEED,   step = 50.0 },
        { id = "Side Upward",     value = SIDE_UP,      step = 50.0 },
        { id = "Back Horizontal", value = BACK_SPEED,   step = 50.0 },
        { id = "Back Upward",     value = BACK_UP,      step = 50.0 },
        { id = "Stamina Cost",    value = STAMINA_COST, step = 1.0 },
    }
    local keyEntries = {
        { id = "Dodge Left Key",  value = KEY_LEFT },
        { id = "Dodge Right Key", value = KEY_RIGHT },
        { id = "Dodge Back Key",  value = KEY_BACK },
    }

    local allOk = true
    for _, e in ipairs(floatEntries) do
        if not MCMRegister(Manager, e.id, MCM_TYPE_FLOAT,
            { defaultFloat = e.value, currentFloat = e.value, step = e.step }) then
            allOk = false
        end
    end
    for _, e in ipairs(keyEntries) do
        if not MCMRegister(Manager, e.id, MCM_TYPE_KEYBIND,
            { defaultKey = e.value, currentKey = e.value }) then
            allOk = false
        end
    end

    mcmsRegistered = allOk
    if mcmsRegistered then
        print("[Configurable Dodge Mod] MCM registration complete (5 values + 3 keys)")
    end
    return allOk
end

--- diagnostic: register Type=0..9 rows so the menu shows which number makes
--- which widget. Remove after the mapping is confirmed.
local typeProbeDone = false
local function RunTypeProbe(Manager)
    if typeProbeDone then return end
    typeProbeDone = true
    print("[Configurable Dodge Mod] MCM: registering 10 diagnostic entries (one per Type value)")
    for i = 0, 9 do
        pcall(function()
            Manager:RegisterModSetting(MOD_ID,
                string.format("Probe type %d", i),
                string.format("Diagnostic entry: Type byte = %d", i),
                nil, AUTHOR, nil, nil, i,
                true, 0, 100.0 + i, 10.0,
                string.format("KEY%d", i), "")
        end)
    end
end

local ManagerRef = nil

--- locate MCM's manager actor (spawns with its world subsystem after load)
local function GetMCMManager()
    if ManagerRef ~= nil then
        local ok, valid = pcall(function() return ManagerRef:IsValid() end)
        if ok and valid then return ManagerRef end
        ManagerRef = nil
    end
    local m = FindFirstOf("BP_MCM_Manager_C")
    if m ~= nil and m:IsValid() then
        ManagerRef = m
        print("[Configurable Dodge Mod] MCM manager located: " .. m:GetFullName())
        return m
    end
    return nil
end

--- poll MCM for live values and apply them
local pollDebugged = false
local function PollMCM()
    if not mcmsRegistered then return end
    local Manager = GetMCMManager()
    if Manager == nil then return end

    local function ReadOut(modId, settingId)
        local outTable = {}
        pcall(function()
            outTable = Manager:GetModSetting(modId, settingId)
        end)
        return outTable
    end

    local floatMap = {
        ["Side Horizontal"] = function(v) SIDE_SPEED = v end,
        ["Side Upward"]     = function(v) SIDE_UP = v end,
        ["Back Horizontal"] = function(v) BACK_SPEED = v end,
        ["Back Upward"]     = function(v) BACK_UP = v end,
        ["Stamina Cost"]    = function(v) STAMINA_COST = v end,
    }
    for sid, apply in pairs(floatMap) do
        local out = ReadOut(MOD_ID, sid)
        if type(out) == "table" and out.FloatValue ~= nil then
            local v = tonumber(out.FloatValue)
            if v ~= nil then apply(v) end
        elseif not pollDebugged then
            print("[Configurable Dodge Mod] poll debug: GetModSetting('" .. sid .. "') -> "
                .. tostring(out) .. " type=" .. type(out))
        end
    end

    local keyMapSet = {
        ["Dodge Left Key"]  = function(v) KEY_LEFT = v end,
        ["Dodge Right Key"] = function(v) KEY_RIGHT = v end,
        ["Dodge Back Key"]  = function(v) KEY_BACK = v end,
    }
    for sid, apply in pairs(keyMapSet) do
        local out = ReadOut(MOD_ID, sid)
        if type(out) == "table" then
            local v = out.KeyBind or out.StringValue
            if type(v) == "string" and v ~= "" and v ~= nil then apply(v) end
        end
    end
    pollDebugged = true
end

-- ================= dodge logic =================
local lastTap   = { left = 0.0, right = 0.0, back = 0.0 }
local lastDodge = 0.0
local bindingToken = { left = "", right = "", back = "" }

local function Now()
    return os.clock()
end

--- spend stamina through the native vitals API; true if dodging may proceed
local function SpendStamina(Pawn)
    if STAMINA_COST <= 0.0 then return true end
    local okCur, curSP = pcall(function() return Pawn:GetSP() end)
    if not okCur or curSP == nil then
        print("[Configurable Dodge Mod] GetSP unavailable, skipping stamina cost")
        return true
    end
    if REQUIRE_STAMINA and curSP < STAMINA_COST then
        print(string.format("[Configurable Dodge Mod] not enough stamina (%.1f < %.1f)", curSP, STAMINA_COST))
        return false
    end
    local newSP = math.floor(curSP - STAMINA_COST)
    if newSP < 0 then newSP = 0 end
    pcall(function() Pawn:ForceSetSP(newSP) end)
    print(string.format("[Configurable Dodge Mod] stamina %.1f -> %d", curSP, newSP))
    return true
end

--- camera-relative launch vector
local function BuildLaunchVector(direction)
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
    local PC = UEHelpers.GetPlayerController()
    if not PC:IsValid() then return end
    local Pawn = PC.Pawn
    if Pawn == nil or not Pawn:IsValid() then return end
    local Velocity = BuildLaunchVector(direction)
    if Velocity == nil then return end

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
            print(string.format("[Configurable Dodge Mod] LaunchCharacter failed: %s", tostring(err)))
        else
            print(string.format("[Configurable Dodge Mod] dodged %s", direction))
        end
    end)
end

local function HandleTap(direction)
    local t = Now()
    if t - lastTap[direction] <= DOUBLE_TAP_WINDOW then
        lastTap[direction] = 0.0
        DoDodge(direction)
    else
        lastTap[direction] = t
    end
end

-- ================= keybind management =================
local keyNameToValue = {}
for name, value in pairs(Key) do
    keyNameToValue[string.upper(name)] = value
end

local function ResolveKey(displayName)
    if type(displayName) ~= "string" or displayName == "" then return nil end
    return keyNameToValue[string.upper(displayName)]
end

--- (re)register the double-tap keybinds for the current key strings
local function RegisterDodges()
    local defs = {
        { name = KEY_LEFT,  dir = "left" },
        { name = KEY_RIGHT, dir = "right" },
        { name = KEY_BACK,  dir = "back" },
    }
    for _, d in ipairs(defs) do
        if bindingToken[d.dir] ~= d.name then
            -- drop the stale binding first (harmless if missing)
            local oldKey = ResolveKey(bindingToken[d.dir])
            if oldKey ~= nil then
                pcall(function() UnregisterKeyBind(oldKey) end)
            end
            local k = ResolveKey(d.name)
            if k ~= nil then
                bindingToken[d.dir] = d.name
                RegisterKeyBind(k, function() HandleTap(d.dir) end)
            else
                print("[Configurable Dodge Mod] unknown key name: " .. tostring(d.name))
            end
        end
    end
end


-- ================= boot =================
--- background: locate MCM, register, and poll for live values
-- register the initial double-tap keybinds
RegisterDodges()

-- background: locate MCM, register, and poll for live values
LoopAsync(3000, function()
    local Manager = GetMCMManager()
    if Manager == nil then return false end
    if MCM_TYPE_FLOAT ~= nil then
        if not mcmsRegistered then RegisterAllSettings(Manager) end
        if mcmsRegistered then PollMCM() end
    else
        -- one-time diagnostic pass while the type mapping is unknown
        RunTypeProbe(Manager)
    end
    return false
end)

-- F7: write the full object dump (offline API discovery)
RegisterKeyBind(Key.F7, function()
    print("[Configurable Dodge Mod] dumping all objects (this may take a while)...")
    DumpAllObjects()
    print("[Configurable Dodge Mod] object dump written")
end)

print("[Configurable Dodge Mod] v1.5 loaded - double-tap: " .. KEY_LEFT .. "/" .. KEY_RIGHT
    .. (ENABLE_BACK and ("/" .. KEY_BACK) or "")
    .. ", stamina cost " .. tostring(STAMINA_COST)
    .. (MCM_TYPE_FLOAT == nil and ", MCM: probe mode (types unresolved)" or ", MCM: live"))




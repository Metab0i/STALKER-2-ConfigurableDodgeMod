-- Configurable Dodge Mod for STALKER 2 (UE4SS Lua) - v1.6
-- Double-tap Z/C/S = dodge. Values configurable in MCM (live).
-- Stamina via the native Obj vitals API (GetSP/ForceSetSP).

local UEHelpers = require("UEHelpers")

-- ================= Defaults (MCM overrides them at runtime) =================
local SIDE_SPEED        = 650.0   -- horizontal launch for left/right (cm/s)
local SIDE_UP           = 500.0   -- upward launch for left/right (cm/s)
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
-- E_MCM_SettingType mapping (verified empirically against the menu widgets):
-- 0=Bool, 1=Int, 2=Float, 3=String, 4=Transform, 5=Vector,
-- 6=Rotator, 7=ComboBox, 8=KeyBind, 9=Button
local MOD_ID       = "Configurable Dodge Mod"
local AUTHOR       = "noahbhodier"
local TYPE_FLOAT   = 2
local TYPE_KEYBIND = 8

local ManagerRef = nil

local function GetMCMManager()
    if ManagerRef ~= nil then
        local ok, valid = pcall(function() return ManagerRef:IsValid() end)
        if ok and valid then return ManagerRef end
        ManagerRef = nil
    end
    local m = FindFirstOf("BP_MCM_Manager_C")
    if m ~= nil and m:IsValid() then
        ManagerRef = m
        return m
    end
    return nil
end

--- shared zeroed-struct helpers for the fixed 20-param BP calls
--- (UE4SS drops nil args from positional counting, so never pass nils)
local paramsCache = nil
local function GetParamStructs()
    if paramsCache ~= nil then return paramsCache end
    local MathLib = UEHelpers.GetKismetMathLibrary()
    local SysLib = nil
    pcall(function() SysLib = UEHelpers.GetKismetSystemLibrary() end)
    local zeroRot
    local okRot = pcall(function() zeroRot = MathLib:MakeRotator(0.0, 0.0, 0.0) end)
    if not okRot or zeroRot == nil then return nil end
    local zeroVec = MathLib:Multiply_VectorFloat(MathLib:GetForwardVector(zeroRot), 0.0)
    local oneVec  = MathLib:GetForwardVector(zeroRot) -- (1,0,0) works as a scale
    local transform = nil
    if SysLib ~= nil then
        pcall(function() transform = SysLib:MakeTransform(zeroVec, zeroRot, oneVec) end)
    end
    if transform == nil then
        pcall(function() transform = MathLib:MakeTransform(zeroVec, zeroRot, oneVec) end)
    end
    if transform == nil then
        pcall(function()
            local PC = UEHelpers.GetPlayerController()
            transform = PC.Pawn.K2_GetRootComponent():K2_GetComponentToWorld()
        end)
    end
    if transform == nil then return nil end
    -- resolve a neutral black texture by scanning loaded textures by name
    -- (path-based FindObject lookups fail in the running menu context)
    local tex = nil
    local function TexOK(t)
        if t == nil or not t:IsValid() then return false end
        local clsRes, cls = pcall(function() return t:GetClass():GetFullName() end)
        return clsRes and string.find(cls, "Texture2D", 1, true) ~= nil
    end
    pcall(function()
        local all = FindAllOf("Texture2D")
        if all ~= nil then
            for _, t in pairs(all) do
                local ok, fn = pcall(function() return t:GetFullName() end)
                if TexOK(t) and fn ~= nil then
                    local n = string.lower(fn)
                    if string.find(n, "/engine/engineresources/black", 1, true) then tex = t; break end
                end
            end
        end
    end)
    if not TexOK(tex) then
        pcall(function()
            local all = FindAllOf("Texture2D")
            for _, t in pairs(all) do
                local ok, fn = pcall(function() return t:GetFullName() end)
                if TexOK(t) and fn ~= nil then
                    local n = string.lower(fn)
                    if string.find(n, "dark", 1, true) then tex = t; break end
                end
            end
        end)
    end
    if not TexOK(tex) then tex = GetMCMManager() end
    local okInfo, texName = pcall(function() return tex:GetFullName() end)
    paramsCache = { transform = transform, vector = zeroVec, rotator = zeroRot, tex = tex }
    return paramsCache
end

--- register one MCM setting (both the default row and the live row)
local function MCMRegister(Manager, id, hoverText, typeNum, payload, step, category)
    local p = GetParamStructs()
    if p == nil then
        print("[Configurable Dodge Mod] MCM register '" .. id .. "': param structs unavailable")
        return false
    end
    local function Call(fn)
        local floatValue, keyBind
        if typeNum == TYPE_KEYBIND then
            floatValue, keyBind = 0.0, payload
        else
            floatValue, keyBind = payload, ""
        end
        fn(MOD_ID, id, hoverText, p.tex, AUTHOR, category or "Dodging", p.tex,
           typeNum, false, 0, floatValue, step or 10.0, "",
           p.transform, p.vector, p.rotator, {}, 0,
           keyBind, "")
    end
    local okD, errD = pcall(function()
        Call(function(...) Manager:RegisterDefaultModSetting(...) end)
    end)
    local okR, errR = pcall(function()
        Call(function(...) Manager:RegisterModSetting(...) end)
    end)
    if not okD or not okR then
        print(string.format("[Configurable Dodge Mod] MCM register '%s' failed: %s | %s",
            id, tostring(errD), tostring(errR)))
    end
    return okD and okR
end

local mcmsRegistered = false
local function RegisterAllSettings(Manager)
    if mcmsRegistered then return true end
    local ok = true
    -- float settings
    ok = ok and MCMRegister(Manager, "Side Dodge Horizontal Force", "Side dodge horizontal strength (cm/s)", TYPE_FLOAT, SIDE_SPEED, 50.0, "Force")
    ok = ok and MCMRegister(Manager, "Side Dodge Vertical Force", "Side dodge upward strength (cm/s)", TYPE_FLOAT, SIDE_UP, 50.0, "Force")
    ok = ok and MCMRegister(Manager, "Back Dodge Horizontal Force", "Back dodge horizontal strength (cm/s)", TYPE_FLOAT, BACK_SPEED, 50.0, "Force")
    ok = ok and MCMRegister(Manager, "Back Dodge Vertical Force", "Back dodge upward strength (cm/s)", TYPE_FLOAT, BACK_UP, 50.0, "Force")
    ok = ok and MCMRegister(Manager, "Jump Stamina Cost", "Stamina points spent per dodge", TYPE_FLOAT, STAMINA_COST, 1.0, "Force")
    -- keybind settings (KeyBind value is a key display-name string)
    ok = ok and MCMRegister(Manager, "Double-Tap Dodge Left Key", "Double-tap key for dodging left", TYPE_KEYBIND, KEY_LEFT, 10.0, "Keybinds")
    ok = ok and MCMRegister(Manager, "Double-Tap Dodge Right Key", "Double-tap key for dodging right", TYPE_KEYBIND, KEY_RIGHT, 10.0, "Keybinds")
    ok = ok and MCMRegister(Manager, "Double-Tap Dodge Back Key", "Double-tap key for dodging back", TYPE_KEYBIND, KEY_BACK, 10.0, "Keybinds")
    if ok then
        pcall(function() Manager:AddUniqueModID(MOD_ID) end)
        -- (removed: reset-to-default wiped user-saved keybinds)
        mcmsRegistered = true
        print("[Configurable Dodge Mod] MCM registration complete (5 values + 3 keys)")
    end
    return mcmsRegistered
end

--- poll MCM for live values by reading its settings structs directly.
--- (GetModSetting is NOT used: struct-typed out params crash the engine.)
---
--- ST_MCM_ModSetting fields carry BP suffixes (exact names from the object
--- dump, stable for MCM v2.0): ModID_19_..., SettingID_20_...,
--- FloatValue_16_..., Keybind_62_..., StringValue_26_...
local POLL_FIELDS = {
    ModID      = "ModID_19_16F2EB904B3610C78A68FE94C1064C9B",
    SettingID  = "SettingID_20_5CDB958A4AF1113D73FA76BF15153E78",
    FloatValue = "FloatValue_16_E0EA58D748E2B9B186FCED891767F185",
    Keybind    = "Keybind_62_CF901DBB4A4DAA21E77F54AD4ED29C34",
    HeaderTex  = "ModHeaderTexture_42_C01538A843C60BE6C47FADBFB6BB34F1",
    CatHeaderTex = "CategoryHeaderTexture_43_30703B2641BF6F0194D7BFA044B78A7B",
    Author     = "AuthorName_46_43C738034EF7062D6409F693394C94DE",
    StringVal  = "StringValue_26_B78D47C643D5E3E436C23D80FA592A41",
}


--- FString fields return userdata; convert to a plain Lua string
local function FStr(v)
    if v == nil then return "" end
    if type(v) == "string" then return v end
    local ok, r = pcall(function() return v:ToString() end)
    if ok and type(r) == "string" then return r end
    return ""
end

local function PollMCM(Manager)
    local byName = {}
    for _, entry in ipairs(MCM_SETTINGS_BY_NAME) do byName[entry.id] = entry end

    local ok, err = pcall(function()
        Manager.AllSettings:ForEach(function(_, wrapper)
            local s = wrapper:get()
            if s == nil then return end
            local sid = FStr(s[POLL_FIELDS.SettingID])
            local entry = byName[sid]
            if entry == nil then return end
            if FStr(s[POLL_FIELDS.ModID]) ~= MOD_ID then return end
            -- repair persisted rows: MCM's save caches old header graphics
            pcall(function()
                local p = GetParamStructs()
                if p ~= nil and p.tex ~= nil then
                    if s[POLL_FIELDS.HeaderTex] ~= p.tex then s[POLL_FIELDS.HeaderTex] = p.tex end
                    if s[POLL_FIELDS.CatHeaderTex] ~= p.tex then s[POLL_FIELDS.CatHeaderTex] = p.tex end
                end
                s[POLL_FIELDS.Author] = AUTHOR
            end)
            if entry.isFloat then
                local v = s[POLL_FIELDS.FloatValue]
                if type(v) == "number" and math.abs(v - entry.current) > 0.0001 then
                    entry.current = v
                    entry.applyFunc(v)
                end
            else
                local v = FStr(s[POLL_FIELDS.Keybind])
                if v ~= "" and v ~= tostring(entry.current) then
                    entry.current = v
                    entry.applyFunc(v)
                    RebindKeys()
                end
            end
        end)
    end)
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
        return true
    end
    if REQUIRE_STAMINA and curSP < STAMINA_COST then
        print(string.format("[Configurable Dodge Mod] not enough stamina (%.1f < %.1f)", curSP, STAMINA_COST))
        return false
    end
    local newSP = math.floor(curSP - STAMINA_COST)
    if newSP < 0 then newSP = 0 end
    pcall(function() Pawn:ForceSetSP(newSP) end)
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
function RebindKeys()
    local defs = {
        { name = KEY_LEFT,  dir = "left" },
        { name = KEY_RIGHT, dir = "right" },
        { name = KEY_BACK,  dir = "back" },
    }
    for _, d in ipairs(defs) do
        if bindingToken[d.dir] ~= d.name and (d.dir ~= "back" or ENABLE_BACK) then
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

-- ================= MCM settings table (built after functions exist) =========
MCM_SETTINGS_BY_NAME = {
    { id = "Side Dodge Horizontal Force", isFloat = true, current = SIDE_SPEED,   applyFunc = function(v) SIDE_SPEED = v end },
    { id = "Side Dodge Vertical Force", isFloat = true, current = SIDE_UP,      applyFunc = function(v) SIDE_UP = v end },
    { id = "Back Dodge Horizontal Force", isFloat = true, current = BACK_SPEED,   applyFunc = function(v) BACK_SPEED = v end },
    { id = "Back Dodge Vertical Force", isFloat = true, current = BACK_UP,      applyFunc = function(v) BACK_UP = v end },
    { id = "Jump Stamina Cost", isFloat = true, current = STAMINA_COST, applyFunc = function(v) STAMINA_COST = v end },
    { id = "Double-Tap Dodge Left Key", isFloat = false, current = KEY_LEFT,  applyFunc = function(v) KEY_LEFT = v end },
    { id = "Double-Tap Dodge Right Key", isFloat = false, current = KEY_RIGHT, applyFunc = function(v) KEY_RIGHT = v end },
    { id = "Double-Tap Dodge Back Key", isFloat = false, current = KEY_BACK,  applyFunc = function(v) KEY_BACK = v end },
}

-- ================= boot =================
RebindKeys()

--- background: locate the current MCM manager (a new one spawns per world /
--- save load), register on it, and poll for live values.
--- Each save carries its own MCM settings, so registration must repeat
--- whenever the manager instance changes.
local lastManagerAddr = nil
LoopAsync(3000, function()
    local Manager = FindFirstOf("BP_MCM_Manager_C")
    if Manager == nil or not Manager:IsValid() then return false end

    local okAddr, addr = pcall(function() return Manager:GetAddress() end)
    if okAddr and addr ~= nil and addr ~= lastManagerAddr then
        lastManagerAddr = addr
        mcmsRegistered = false
    end

    if not mcmsRegistered then
        if not RegisterAllSettings(Manager) then return false end
    end
    PollMCM(Manager)
    return false
end)

print("[Configurable Dodge Mod] v1.6 loaded - double-tap: " .. KEY_LEFT .. "/" .. KEY_RIGHT
    .. (ENABLE_BACK and ("/" .. KEY_BACK) or "")
    .. ", stamina cost " .. tostring(STAMINA_COST) .. ", MCM integration active")


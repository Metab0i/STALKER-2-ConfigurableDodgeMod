-- Configurable Dodge Mod for STALKER 2 (UE4SS Lua) - v1.8
-- Double-tap Z/C/S = dodge, or hold direction + press dodge button (toggleable
-- in MCM). Values configurable in MCM (live).
-- Stamina via the native Obj vitals API (GetSP/ForceSetSP).
-- v1.8: mouse side buttons as dodge buttons via MCM toggles; no dodging while
-- gameplay is UI-blocked.

local UEHelpers = require("UEHelpers")

-- ================= dev harness (generation + telemetry) =================
-- Generation bump: every in-memory reload (hot-reload watcher at the end of
-- this file) increments it; stale async loops check this and stop.
DodgeMod_Generation = (DodgeMod_Generation or 0) + 1
local DODGE_MOD_GEN = DodgeMod_Generation

-- Dev features activate only when a ".hotreload" dot-file sits next to this
-- script. Releases never have it, so none of this ships.
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

--- append one line to dodge_dev.log next to the script (dev builds only)
--- includes monotonic ms so per-press latency is measurable
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
local TYPE_BOOL    = 0
local TYPE_FLOAT   = 2
local TYPE_KEYBIND = 8

-- dodge-button mode: pressing the dodge button dodges in the direction the
-- movement keys are currently pressed (left/right/back; standing still
-- without lateral input does nothing)
local BUTTON_MODE = true
local KEY_DODGE_BTN = "ThumbMouseButton2" -- Mouse 5 (mouse delivery is the reliable path)

-- independent toggle for the original double-tap mode
local DOUBLE_TAP_ENABLED = true

local ManagerRef = nil

-- cached player controller: GetPC() runs an uncached
-- FindFirstOf (full object-array scan, ~25-30 ms) — calling it 3-4x per dodge
-- press was the stutter. Cache + validate instead.
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
            local PC = GetPC()
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
        local boolValue, floatValue, keyBind
        if typeNum == TYPE_KEYBIND then
            boolValue, floatValue, keyBind = false, 0.0, payload
        elseif typeNum == TYPE_BOOL then
            boolValue, floatValue, keyBind = payload, 0.0, ""
        else
            boolValue, floatValue, keyBind = false, payload, ""
        end
        fn(MOD_ID, id, hoverText, p.tex, AUTHOR, category or "Dodging", p.tex,
           typeNum, boolValue, 0, floatValue, step or 10.0, "",
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

--- our settings already present on this manager? (prevents duplicate rows
--- when re-registration is skipped/re-attempted)
local function HasOurSettings(Manager)
    local found = false
    pcall(function()
        Manager.AllSettings:ForEach(function(_, wrapper)
            local s = wrapper:get()
            if s == nil then return end
            if FStr(s[POLL_FIELDS.ModID]) == MOD_ID then found = true end
        end)
    end)
    return found
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
    -- toggles (independent of each other)
    ok = ok and MCMRegister(Manager, "Enable Dodge Button Mode", "Dodge by pressing the dodge button while holding a direction key or while moving (in addition to double-tap)", TYPE_BOOL, BUTTON_MODE, 10.0, "Keybinds")
    ok = ok and MCMRegister(Manager, "Enable Double-Tap Dodge", "Toggles the original double-tap dodging on or off", TYPE_BOOL, DOUBLE_TAP_ENABLED, 10.0, "Keybinds")
    -- keybind settings (KeyBind value is a key display-name string)
    ok = ok and MCMRegister(Manager, "Double-Tap Dodge Left Key", "Double-tap key for dodging left", TYPE_KEYBIND, KEY_LEFT, 10.0, "Keybinds")
    ok = ok and MCMRegister(Manager, "Double-Tap Dodge Right Key", "Double-tap key for dodging right", TYPE_KEYBIND, KEY_RIGHT, 10.0, "Keybinds")
    ok = ok and MCMRegister(Manager, "Double-Tap Dodge Back Key", "Double-tap key for dodging back", TYPE_KEYBIND, KEY_BACK, 10.0, "Keybinds")
    ok = ok and MCMRegister(Manager, "Dodge Button Key", "Button to press together with a direction key", TYPE_KEYBIND, KEY_DODGE_BTN, 10.0, "Keybinds")
    if ok then
        pcall(function() Manager:AddUniqueModID(MOD_ID) end)
        -- (removed: reset-to-default wiped user-saved keybinds)

        mcmsRegistered = true
        print("[Configurable Dodge Mod] MCM registration complete (2 toggles + 5 values + 4 keys)")
        DevLog("mcm registered (2 toggles + 5 values + 4 keys)")
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
    BoolValue  = "BoolValue_18_561E7B474E51CDC6C657A89251AA5995",
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
                    DevLog("mcm set '" .. sid .. "' = " .. tostring(v))
                end
            elseif entry.isBool then
                local v = s[POLL_FIELDS.BoolValue]
                if type(v) == "boolean" and v ~= entry.current then
                    entry.current = v
                    entry.applyFunc(v)
                    DevLog("mcm set '" .. sid .. "' = " .. tostring(v))
                end
            else
                local v = FStr(s[POLL_FIELDS.Keybind])
                -- sanitize: LMB/RMB/MMB can never be dodge buttons (UI navigation)
                if sid == "Dodge Button Key" and BAD_MOUSE_NAMES[v] then
                    s[POLL_FIELDS.Keybind] = "ThumbMouseButton2"
                    v = "ThumbMouseButton2"
                    DevLog("sanitized dodge button (UI mouse key) -> ThumbMouseButton2")
                end
                -- dev visibility: what the row holds right now (throttled)
                if sid == "Dodge Button Key" and v ~= PollLastBtnLog then
                    PollLastBtnLog = v
                    DevLog("poll: Dodge Button Key = '" .. v .. "'")
                end
                if v ~= "" and v ~= tostring(entry.current) then
                    entry.current = v
                    entry.applyFunc(v)
                    DevLog("mcm set '" .. sid .. "' = " .. v)
                    HookAnyKeyEvents()
                end
            end
        end)
    end)
end

-- ================= dodge logic =================
local lastTap   = { left = 0.0, right = 0.0, back = 0.0 }
local lastDodge = 0.0
local lastStaminaMsg = 0.0

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

--- camera-relative launch vector
local function BuildLaunchVector(direction)
    local PC = GetPC()
    if not PC:IsValid() then return nil end
    local CameraManager = PC.PlayerCameraManager
    if not CameraManager:IsValid() then return nil end
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
    if PC == nil or not PC:IsValid() then return end
    local Pawn = PC.Pawn
    if Pawn == nil or not Pawn:IsValid() then return end

    -- don't dodge while gameplay is UI-blocked: conversations, stash viewing,
    -- pause menus etc. show the mouse cursor
    local blocked = false
    pcall(function()
        if PC.bShowMouseCursor then blocked = true end
    end)
    if blocked then
        DevLog("blocked: menu UI")
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
    DevLog(string.format("dodge dir=%s (handler total %.3f ms, launch scheduled)", tostring(direction), (Now() - dodgeT0) * 1000))

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
    if not DOUBLE_TAP_ENABLED then return end
    if t - lastTap[direction] <= DOUBLE_TAP_WINDOW then
        lastTap[direction] = 0.0
        DoDodge(direction)
    else
        lastTap[direction] = t
    end
end

--- which direction is the player's movement input currently pressed in?
--- Reads the character movement component's live input vector (the same
--- data the game itself uses), so it reflects the game's actual movement
--- key bindings; returns "left"/"right"/"back" or nil.
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

local function GetMoveInputDirection()
    local PC = GetPC()
    if PC == nil or not PC:IsValid() then return nil end
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
    if not CameraManager:IsValid() then return nil end
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

--- dodge button pressed: dodge in the direction the movement keys are
--- currently pressed (left/right/back). Standing still or moving forward
--- without lateral input → no dodge (there is no trustworthy direction).
--- Timing is measured (telemetry) to catch any per-press overhead.
local function HandleButtonPress()
    if not BUTTON_MODE then return end
    local t0 = Now()
    local d = GetMoveInputDirection()
    if d == nil then
        DevLog(string.format("press: no move input (%.3f ms)", (Now() - t0) * 1000))
        return
    end
    DoDodge(d)
    DevLog(string.format("press: dodge dir=%s handler=%.3f ms", d, (Now() - t0) * 1000))
end

-- ================= keybind management =================
local keyNameToValue = {}
for name, value in pairs(Key) do
    keyNameToValue[string.upper(name)] = value
end

local function ResolveKey(displayName)
    if type(displayName) ~= "string" or displayName == "" then return nil end
    local name = string.upper(displayName)
    local v = keyNameToValue[name]
    if v ~= nil then return v end
    v = keyNameToValue[string.gsub(name, "%s+", "_")]
    if v ~= nil then return v end
    return keyNameToValue[string.gsub(name, "[^%w", "")]
end

-- GAMEPLAY INPUT: UE4SS's window-message keybind hooks stop delivering after
-- the world loads (observed live), so gameplay input is hooked through the
-- MCM manager's own "Any Key" input events instead - the game's native input
-- routing, reliable in gameplay. The FKey KeyName matches the display names
-- MCM stores, so a plain name comparison covers everything.
local ANYKEY_HOOKED = false

function ProbeAnyKeyFunctions()
    for _, num in ipairs({ 5, 6, 7, 8, 15 }) do
        local p = "/ModConfigurationMenu/BP_MCM_Manager.BP_MCM_Manager_C:InpActEvt_AnyKey_K2Node_InputKeyEvent_" .. num
        local ok, f = pcall(function() return StaticFindObject(p) end)
        if ok and f ~= nil and f:IsValid() then
            local okn, fn = pcall(function() return f:GetFullName() end)
            DevLog("anykey probe " .. num .. " FOUND: " .. tostring(fn))
        else
            DevLog("anykey probe " .. num .. " NOT FOUND")
        end
    end
end
function HookAnyKeyEvents()
    DevLog("HookAnyKeyEvents enter, hooked=" .. tostring(ANYKEY_HOOKED) .. " dev=" .. tostring(devEnabled))
    if ANYKEY_HOOKED then return end
    local nums = { 5, 6, 7, 8, 15 }
    for _, num in ipairs(nums) do
        local fn = "/ModConfigurationMenu/BP_MCM_Manager.BP_MCM_Manager_C:InpActEvt_AnyKey_K2Node_InputKeyEvent_" .. num
        local ok, err = pcall(function()
            RegisterHook(fn, function(_, Key)
                local name = nil
                pcall(function()
                    local k = Key:get()
                    name = k.KeyName:ToString()
                end)
                if name ~= nil and name ~= "" then
                    DodgeMod_Dispatch("anykey", string.upper(name))
                end
            end)
        end)
        DevLog("anykey hook " .. num .. ": ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
        ANYKEY_HOOKED = true -- attempted; failed stubs are not hookable, do not retry
    end
end

-- movement double-tap: dodge by double-tapping a movement direction (the
-- game's own bindings - A/A, D/D, S/S by default). Read from the live
-- movement input, so it follows rebinding and needs no key hooks.
local moveTap  = { left = 0.0, right = 0.0, back = 0.0 }
local moveHold = { left = false, right = false, back = false }

LoopAsync(60, function()
    if DodgeMod_Generation ~= DODGE_MOD_GEN then return true end
    if not DOUBLE_TAP_ENABLED then return false end
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
function DodgeMod_Dispatch(role, keyUpper)
    if devEnabled then DevLog("dispatch role=" .. tostring(role) .. " key=" .. tostring(keyUpper)) end
    local H = DodgeMod_Handlers
    if H == nil then return end
    H(role, keyUpper)
end

-- mouse button keys and the engine display names MCM stores for them
-- ALL mouse buttons are capturable. The capture only arms ~400 ms after the
-- row's listening transition, so the click that OPENS the field can never
-- bind itself, and accidental UI clicks right after opening are ignored too.
MOUSE_BY_KEY = {
    XBUTTON_ONE         = "ThumbMouseButton",
    XBUTTON_TWO         = "ThumbMouseButton2",
    LEFT_MOUSE_BUTTON   = "LeftMouseButton",
    RIGHT_MOUSE_BUTTON  = "RightMouseButton",
    MIDDLE_MOUSE_BUTTON = "MiddleMouseButton",
}
-- garbage values that must never stay bound (sanitize on poll)
BAD_MOUSE_NAMES = { LeftMouseButton = true, RightMouseButton = true, MiddleMouseButton = true }
MOUSE_DISPLAY_NAMES = {}
for _, d in pairs(MOUSE_BY_KEY) do MOUSE_DISPLAY_NAMES[d] = true end

function IsMouseDisplayName(name)
    return MOUSE_DISPLAY_NAMES[name] == true
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
    { id = "Enable Dodge Button Mode", isBool = true, current = BUTTON_MODE, applyFunc = function(v) BUTTON_MODE = v end },
    { id = "Enable Double-Tap Dodge", isBool = true, current = DOUBLE_TAP_ENABLED, applyFunc = function(v) DOUBLE_TAP_ENABLED = v end },
    { id = "Dodge Button Key", isFloat = false, current = KEY_DODGE_BTN, applyFunc = function(v) KEY_DODGE_BTN = v end },
}

-- ================= boot =================
-- ============ mouse-button capture ============
-- MCM's keybind field captures keys through an "Any Key" input event, which
-- Unreal never fires for mouse buttons. So the mod listens for the mouse
-- buttons itself: when the "Dodge Button Key" row is actively waiting for a
-- key (ListeningToKey), a mouse press binds that button through MCM's data.
local dodgeRowWidget = nil

local function GetDodgeRow()
    if dodgeRowWidget ~= nil then
        local ok, valid = pcall(function() return dodgeRowWidget:IsValid() end)
        if ok and valid then return dodgeRowWidget end
        dodgeRowWidget = nil
    end
    local M = GetMCMManager()
    if M == nil then return nil end
    local uiOpen = false
    pcall(function() uiOpen = M.UI end)
    if not uiOpen then
        pcall(function() if M.MCMUI ~= nil then uiOpen = true end end)
    end
    if not uiOpen then return nil end
    pcall(function()
        local rows = FindAllOf("WBP_MCM_SettingKey_C")
        for _, w in pairs(rows or {}) do
            if w ~= nil and w:IsValid() then
                local mid, sid = "", ""
                pcall(function() mid = FStr(w.ModId); sid = FStr(w.SettingID) end)
                if mid == MOD_ID and sid == "Dodge Button Key" then
                    dodgeRowWidget = w
                    break
                end
            end
        end
    end)
    return dodgeRowWidget
end

--- write the bound key name into the MCM row struct so it persists with the
--- save exactly like a user-captured keybind
local function PersistDodgeButton(value)
    pcall(function()
        local Manager = FindFirstOf("BP_MCM_Manager_C")
        if Manager == nil or not Manager:IsValid() then return end
        Manager.AllSettings:ForEach(function(_, wrapper)
            local s = wrapper:get()
            if s == nil then return end
            if FStr(s[POLL_FIELDS.ModID]) ~= MOD_ID then return end
            if FStr(s[POLL_FIELDS.SettingID]) ~= "Dodge Button Key" then return end
            s[POLL_FIELDS.Keybind] = value
        end)
    end)
end

local function SetTextBlockString(tb, str)
    pcall(function()
        local TextLib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        if TextLib ~= nil then
            tb:SetText(TextLib:Conv_StringToText(str))
        end
    end)
end

--- collect TextBlock widgets nested under a widget via panel recursion
local function CollectTextBlocks(widget, depth, out)
    if widget == nil or depth > 6 then return end
    local ok, cn = pcall(function() return widget:GetClass():GetFullName() end)
    if ok and type(cn) == "string" and string.find(cn, "TextBlock", 1, true) then
        out[#out + 1] = widget
        return
    end
    local ok2, count = pcall(function() return widget:GetChildrenCount() end)
    if ok2 and type(count) == "number" then
        for i = 0, count - 1 do
            local child
            pcall(function() child = widget:GetChildAt(i) end)
            if child ~= nil then CollectTextBlocks(child, depth + 1, out) end
        end
    end
end

--- update the row's value strings and swap the visible value-chip text
local function RefreshRowValueText(row, oldName, newName)
    pcall(function() row.Value = newName end)
    pcall(function() row.ChosenKey = newName end)
    pcall(function()
        local sk = row.SettingKey
        if sk ~= nil and sk:IsValid() then
            local tbs = {}
            CollectTextBlocks(sk, 0, tbs)
            for _, tb in ipairs(tbs) do
                local okTxt, cur = pcall(function() return FStr(tb:GetText()) end)
                if okTxt and (cur == oldName or cur == "") then
                    SetTextBlockString(tb, newName)
                end
            end
        end
    end)
end

local function BindMouseToDodge(mouseKey, row)
    local displayName = MOUSE_BY_KEY[mouseKey]
    if displayName == nil then return end
    if KEY_DODGE_BTN == displayName then
        pcall(function() row.ListeningToKey = false end)
        return
    end
    local oldName = KEY_DODGE_BTN
    KEY_DODGE_BTN = displayName
    PersistDodgeButton(displayName)
    HookAnyKeyEvents()
    RefreshRowValueText(row, oldName, displayName)
    pcall(function() row.ListeningToKey = false end)
    print("[Configurable Dodge Mod] dodge button assigned: " .. displayName)
end

--- called on every mouse-button press. Gameplay: straight to the dodge
--- decision, no MCM reads at all. MCM menu: capture path - the press only
--- binds once the capture state is ARMED (>= 400 ms after the row started
--- listening), so the opening click and instant double-clicks never bind.
function OnMouseCapturePress(mouseKey)
    local inUI = false
    pcall(function()
        local PC = GetPC()
        if PC ~= nil and PC:IsValid() then inUI = PC.bShowMouseCursor end
    end)
    if not inUI then
        local displayName = MOUSE_BY_KEY[mouseKey]
        if displayName ~= nil and displayName == KEY_DODGE_BTN then
            HandleButtonPress()
        end
        lastListeningState = false
        return
    end

    if lastListeningState and captureArmedAt ~= nil and Now() >= captureArmedAt then
        local row = GetDodgeRow()
        if row ~= nil then
            BindMouseToDodge(mouseKey, row)
            return
        end
    end
    DevLog(string.format("mouse %s ignored (listening=%s armed=%s)",
        tostring(mouseKey), tostring(lastListeningState), tostring(captureArmedAt ~= nil and Now() >= captureArmedAt)))
end
--- keep the capture-start timestamp fresh without per-press reads
--- capture arming state machine (owned by this poll; the press handler only
--- consults it). The row starts listening at the INSTANT of the opening
--- click, so a bind is only accepted once the listening state has been
--- stable for ARM_DELAY - the opening click itself can never bind.
local captureArmedAt = nil

LoopAsync(150, function()
    if DodgeMod_Generation ~= DODGE_MOD_GEN then return true end
    local row = dodgeRowWidget
    local listening = false
    if row ~= nil then
        local okValid, valid = pcall(function() return row:IsValid() end)
        if okValid and valid then
            pcall(function() listening = row.ListeningToKey end)
        else
            dodgeRowWidget = nil
        end
    end
    local t = Now()
    if listening then
        if lastListeningState == false then
            -- transition just observed: arm capture after a short grace delay
            captureArmedAt = t + 0.4
        end
    else
        if lastListeningState == true then
            captureArmedAt = nil
        end
    end
    lastListeningState = listening
    return false
end)

-- ================= MCM manager loop (generation-guarded) =================

ProbeAnyKeyFunctions()
HookAnyKeyEvents()

-- mouse bindings (boot context): MCM capture + gameplay dodge
for key, _ in pairs(MOUSE_BY_KEY) do
    local k = keyNameToValue[key]
    if k ~= nil then
        local mk = key
        pcall(function()
            RegisterKeyBind(k, function() DodgeMod_Dispatch("mouse", mk) end)
        end)
    end
end


--- background: locate the current MCM manager (a new one spawns per world /
--- save load), register on it, and poll for live values.
--- Each save carries its own MCM settings, so registration must repeat
--- whenever the manager instance changes.
local lastManagerAddr = nil

LoopAsync(3000, function()
    if DodgeMod_Generation ~= DODGE_MOD_GEN then return true end
    local Manager = FindFirstOf("BP_MCM_Manager_C")
    if Manager == nil or not Manager:IsValid() then return false end

    local okAddr, addr = pcall(function() return Manager:GetAddress() end)
    if okAddr and addr ~= nil and addr ~= lastManagerAddr then
        lastManagerAddr = addr
        mcmsRegistered = false
    end

    if not mcmsRegistered then
        if HasOurSettings(Manager) then
            mcmsRegistered = true
        else
            if not RegisterAllSettings(Manager) then return false end
        end
    end
    PollMCM(Manager)
    return false
end)

print("[Configurable Dodge Mod] v1.8 loaded - double-tap: "
    .. (DOUBLE_TAP_ENABLED and (KEY_LEFT .. "/" .. KEY_RIGHT .. (ENABLE_BACK and ("/" .. KEY_BACK) or "")) or "off")
    .. ", button mode: " .. (BUTTON_MODE and (KEY_DODGE_BTN) or "off")
    .. ", stamina cost " .. tostring(STAMINA_COST) .. ", MCM integration active")
DevLog(string.format("boot v1.8 gen=%d dev=%s", DODGE_MOD_GEN, tostring(devEnabled)))

-- ============ hot reload (dev only) ============
-- Watches this script's own bytes while ".hotreload" is next to it; on any
-- change it unregisters everything we own and re-executes the file. Disabled
-- entirely in releases (no gate file).
if devEnabled and devDir ~= nil then
    local selfPath = devDir
    local sep = (string.find(devDir, "\\", 1, true) ~= nil) and "\\" or "/"
    selfPath = devDir .. sep .. "main.lua"
    local WatchContent = nil
    pcall(function()
        local h = io.open(selfPath, "rb")
        if h ~= nil then WatchContent = h:read("*a"); h:close() end
    end)
    LoopAsync(1200, function()
        if DodgeMod_Generation ~= DODGE_MOD_GEN then return true end
        local newContent
        pcall(function()
            local h = io.open(selfPath, "rb")
            if h ~= nil then newContent = h:read("*a"); h:close() end
        end)
        if newContent == nil or newContent == WatchContent then return false end
        WatchContent = newContent
        DevLog("hot reload: main.lua changed on disk, re-executing")
        -- no unregistering: keybinds are bound once per session and dispatch
        -- through globals, so the fresh chunk simply re-points the handlers
        local oldHandlers = DodgeMod_Handlers
        DodgeMod_Generation = DODGE_MOD_GEN + 1
        local okR, errR = pcall(dofile, selfPath)
        if not okR or DodgeMod_Handlers == oldHandlers then
            -- the fresh chunk failed to boot: reclaim our generation so these
            -- loops (including this watcher) stay alive and can retry
            if not okR then DevLog("RELOAD ERROR: " .. tostring(errR)) else DevLog("RELOAD ERROR: chunk did not finish booting") end
            DodgeMod_Generation = DODGE_MOD_GEN
            return false
        end
        return true
    end)
    DevLog("hot reload active: editing main.lua will apply within ~1-2s")
end

-- ================= dispatcher wiring (must stay last) =================
-- The global dispatcher routes key events into THIS chunk's logic. Hook
-- callbacks reference DodgeMod_Dispatch and DodgeMod_Handlers as globals,
-- so every reload re-points them here.
DodgeMod_Handlers = function(role, keyUpper)
    if role == "anykey" then
        -- gameplay input through the game's own routing; menus are ignored
        -- (MCM handles its own capture there)
        local inUI = false
        pcall(function()
            local PC = GetPC()
            if PC ~= nil and PC:IsValid() then inUI = PC.bShowMouseCursor end
        end)
        if inUI then return end
        if keyUpper == string.upper(KEY_DODGE_BTN) then
            HandleButtonPress()
        elseif keyUpper == string.upper(KEY_LEFT) then
            HandleTap("left")
        elseif keyUpper == string.upper(KEY_RIGHT) then
            HandleTap("right")
        elseif ENABLE_BACK and keyUpper == string.upper(KEY_BACK) then
            HandleTap("back")
        end
        return
    end
    if role == "left" and keyUpper == string.upper(KEY_LEFT) then
        HandleTap("left")
    elseif role == "right" and keyUpper == string.upper(KEY_RIGHT) then
        HandleTap("right")
    elseif role == "back" and keyUpper == string.upper(KEY_BACK) then
        HandleTap("back")
    elseif role == "button" and keyUpper == string.upper(KEY_DODGE_BTN) then
        HandleButtonPress()
    elseif role == "mouse" then
        OnMouseCapturePress(keyUpper)
    end
end
DevLog("dispatcher wired gen=" .. tostring(DODGE_MOD_GEN))


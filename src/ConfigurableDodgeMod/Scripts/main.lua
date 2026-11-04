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
-- The canonical MCM keybind delivery: a BP actor with an "Any Key" input
-- event receives EVERY keypress in gameplay (modifiers included - Left Alt
-- included), and the mod compares GetKeyDisplayName against the configured
-- key. The MCM manager actor is always in the world with input enabled, so
-- we hook ITS AnyKey event functions - found at runtime by iterating live
-- UFunction objects (static name lookups fail for these).
local function KeyNorm(s)
    return string.upper(string.gsub(s or "", "[^%w]", ""))
end

local ANYKEY_HOOKED = false

function HookAnyKeyEvents()
    if ANYKEY_HOOKED then return end
    local hooked = 0
    pcall(function()
        local all = FindAllOf("Function")
        local seen = {}
        for _, f in pairs(all or {}) do
            local okn, fn = pcall(function() return f:GetFullName() end)
            if okn and type(fn) == "string" and string.find(fn, "InpActEvt_AnyKey", 1, true) and string.find(fn, "BP_MCM_Manager_C", 1, true) then
                if seen[fn] == nil then
                    seen[fn] = true
                    -- GetFullName includes an object-type prefix and uses the
                    -- dump's separators; strip the prefix and try both class
                    -- separator variants. This UE4SS build's RegisterHook
                    -- requires pre AND post callbacks (3 args).
                    local bare = string.gsub(fn, "^%w+%s+", "")
                    local dotted = string.gsub(bare, "^(.-):([%w_]+_C:)", "%1.%2")
                    local fulldot = string.gsub(dotted, "(_C):", "%1.")
                    local function OnKey(_, Key)
                        local name = nil
                        pcall(function()
                            local k = Key:get()
                            name = k.KeyName:ToString()
                        end)
                        if name ~= nil and name ~= "" then
                            DodgeMod_Dispatch("anykey", name)
                        end
                    end
                    local function Empty() end
                    local okH, errH = pcall(function()
                        RegisterHook(bare, OnKey, Empty)
                    end)
                    if not okH then
                        okH, errH = pcall(function()
                            RegisterHook(dotted, OnKey, Empty)
                        end)
                    end
                    DevLog("anykey hook attempt: ok=" .. tostring(okH) .. (okH and (" [" .. bare .. "]") or (" err=" .. tostring(errH))))
                    if okH then hooked = hooked + 1 end
                end
            end
        end
    end)
    if hooked > 0 then
        ANYKEY_HOOKED = true
        DevLog("anykey hooks registered: " .. hooked)
    end
end

-- mouse buttons: window-message hooks DO deliver in gameplay (verified),
-- so mouse-configured dodge buttons use them directly
local MOUSE_ALIASES = {
    THUMBMOUSEBUTTON  = "XBUTTON_ONE",
    THUMBMOUSEBUTTON2 = "XBUTTON_TWO",
    MOUSE4            = "XBUTTON_ONE",
    MOUSE5            = "XBUTTON_TWO",
    MOUSEBUTTON4      = "XBUTTON_ONE",
    MOUSEBUTTON5      = "XBUTTON_TWO",
}

local keyNameToValue = {}
for name, value in pairs(Key) do
    keyNameToValue[string.upper(name)] = value
end

local function ResolveMouseKey(displayName)
    local name = KeyNorm(displayName)
    local alias = MOUSE_ALIASES[name]
    if alias ~= nil then return keyNameToValue[alias] end
    return keyNameToValue[name]
end

DodgeMod_BoundMouse = DodgeMod_BoundMouse or {}

local function EnsureMouseBinds()
    if MODALITY ~= "button" then return end
    local n = KeyNorm(KEY_DODGE_BTN)
    if not MOUSE_ALIASES[n] and not (n == "LEFTMOUSEBUTTON" or n == "RIGHTMOUSEBUTTON" or n == "MIDDLEMOUSEBUTTON") then return end
    if DodgeMod_BoundMouse[n] then return end
    local vk = ResolveMouseKey(KEY_DODGE_BTN)
    if vk == nil then return end
    DodgeMod_BoundMouse[n] = true
    pcall(function()
        RegisterKeyBind(vk, function() HandleButtonPress() end)
    end)
    DevLog("mouse dodge button bound: " .. KEY_DODGE_BTN)
end

EnsureMouseBinds()

function DodgeMod_Dispatch(role, keyUpper)
    local H = DodgeMod_Handlers
    if H == nil then return end
    H(role, keyUpper)
end

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


-- the modifier listener, baked into this file as an EncodedCommand payload
-- (UTF16LE base64 of ModifierListener.ps1 - no separate script ships)
local LISTENER_B64 =
    "IwAgAEMAbwBuAGYAaQBnAHUAcgBhAGIAbABlACAARABvAGQAZwBlACAATQBvAGQAIAAtACAAbQBvAGQAaQBmAGkAZQByACAAawBlAHkAIABsAGkAcwB0AGUAbgBlAHIAIAAoAHYAMwAsACAAZwBlAG4AZQByAGkAYwApAAoAIwAgAFcAYQB0AGMAaABlAHMAIABBAEwA"
  ..     "TAAgAG0AbwBkAGkAZgBpAGUAcgAgAGsAZQB5AHMAIABhAHQAIAB0AGgAZQAgAE8AUwAgAGwAZQB2AGUAbAAgACgARwBlAHQAQQBzAHkAbgBjAEsAZQB5AFMAdABhAHQAZQAgAC0AIABVAEUANABTAFMAJwBzACAAaQBuAHAAdQB0AAoAIwAgAGgAbwBvAGsAIABjAGEA"
  ..     "bgBuAG8AdAAgAHMAZQBlACAAdABoAGUAbQApACAAYQBuAGQAIAB0AHIAYQBuAHMAbABhAHQAZQBzACAAZQBhAGMAaAAgAHAAcgBlAHMAcwAgAGkAbgB0AG8AIABhACAAcwB5AG4AdABoAGUAdABpAGMAIABGADEAMwAtAEYAMQA4AAoAIwAgAGsAZQB5AHAAcgBlAHMA"
  ..     "cwAsACAAdwBoAGkAYwBoACAAVQBFADQAUwBTACAAZABlAGwAaQB2AGUAcgBzACAAcgBlAGwAaQBhAGIAbAB5AC4AIABUAGgAZQAgAG0AbwBkACAAYgBpAG4AZABzACAAdABoAG8AcwBlACAARgAtAGsAZQB5AHMALgAKACMAIABTAHQAYQByAHQAZQBkACAAYQB1AHQA"
  ..     "bwBtAGEAdABpAGMAYQBsAGwAeQAgAGIAeQAgAHQAaABlACAAbQBvAGQAIABhAHQAIABnAGEAbQBlACAAYgBvAG8AdAAuACAARQB4AGkAdABzACAAdwBoAGUAbgAgAHQAaABlACAAZwBhAG0AZQAgAGMAbABvAHMAZQBzAC4ACgAjACAAUgBlAGYAdQBzAGUAcwAgAHQA"
  ..     "bwAgAHIAdQBuACAAdAB3AGkAYwBlACAAKABtAHUAdABlAHgAKQAuAAoACgBBAGQAZAAtAFQAeQBwAGUAIABAACIACgB1AHMAaQBuAGcAIABTAHkAcwB0AGUAbQA7AAoAdQBzAGkAbgBnACAAUwB5AHMAdABlAG0ALgBSAHUAbgB0AGkAbQBlAC4ASQBuAHQAZQByAG8A"
  ..     "cABTAGUAcgB2AGkAYwBlAHMAOwAKAHAAdQBiAGwAaQBjACAAcwB0AGEAdABpAGMAIABjAGwAYQBzAHMAIABNAG8AZABMAGkAcwB0AGUAbgAgAHsACgAgACAAIAAgAFsARABsAGwASQBtAHAAbwByAHQAKAAiAHUAcwBlAHIAMwAyAC4AZABsAGwAIgApAF0AIABwAHUA"
  ..     "YgBsAGkAYwAgAHMAdABhAHQAaQBjACAAZQB4AHQAZQByAG4AIABzAGgAbwByAHQAIABHAGUAdABBAHMAeQBuAGMASwBlAHkAUwB0AGEAdABlACgAaQBuAHQAIAB2AEsAZQB5ACkAOwAKACAAIAAgACAAWwBEAGwAbABJAG0AcABvAHIAdAAoACIAdQBzAGUAcgAzADIA"
  ..     "LgBkAGwAbAAiACkAXQAgAHAAdQBiAGwAaQBjACAAcwB0AGEAdABpAGMAIABlAHgAdABlAHIAbgAgAHUAaQBuAHQAIABTAGUAbgBkAEkAbgBwAHUAdAAoAHUAaQBuAHQAIABuACwAIABJAE4AUABVAFQAWwBdACAAcAAsACAAaQBuAHQAIABzAGkAegBlACkAOwAKACAA"
  ..     "IAAgACAAWwBEAGwAbABJAG0AcABvAHIAdAAoACIAawBlAHIAbgBlAGwAMwAyAC4AZABsAGwAIgApAF0AIABwAHUAYgBsAGkAYwAgAHMAdABhAHQAaQBjACAAZQB4AHQAZQByAG4AIABiAG8AbwBsACAAQwByAGUAYQB0AGUATQB1AHQAZQB4ACgASQBuAHQAUAB0AHIA"
  ..     "IABhAHQAdAByACwAIABiAG8AbwBsACAAaQBuAGkAdABpAGEAbAAsACAAcwB0AHIAaQBuAGcAIABuAGEAbQBlACkAOwAKACAAIAAgACAAWwBTAHQAcgB1AGMAdABMAGEAeQBvAHUAdAAoAEwAYQB5AG8AdQB0AEsAaQBuAGQALgBTAGUAcQB1AGUAbgB0AGkAYQBsACkA"
  ..     "XQAgAHAAdQBiAGwAaQBjACAAcwB0AHIAdQBjAHQAIABLAEUAWQBCAEQASQBOAFAAVQBUACAAewAgAHAAdQBiAGwAaQBjACAAdQBzAGgAbwByAHQAIAB2AGsAOwAgAHAAdQBiAGwAaQBjACAAdQBzAGgAbwByAHQAIABzAGMAYQBuADsAIABwAHUAYgBsAGkAYwAgAHUA"
  ..     "aQBuAHQAIABmAGwAYQBnAHMAOwAgAHAAdQBiAGwAaQBjACAAdQBpAG4AdAAgAHQAaQBtAGUAOwAgAHAAdQBiAGwAaQBjACAASQBuAHQAUAB0AHIAIABlAHgAdAByAGEAOwAgAH0ACgAgACAAIAAgAFsAUwB0AHIAdQBjAHQATABhAHkAbwB1AHQAKABMAGEAeQBvAHUA"
  ..     "dABLAGkAbgBkAC4AUwBlAHEAdQBlAG4AdABpAGEAbAApAF0AIABwAHUAYgBsAGkAYwAgAHMAdAByAHUAYwB0ACAASQBOAFAAVQBUACAAewAgAHAAdQBiAGwAaQBjACAAdQBpAG4AdAAgAHQAeQBwAGUAOwAgAHAAdQBiAGwAaQBjACAASwBFAFkAQgBEAEkATgBQAFUA"
  ..     "VAAgAGsAaQA7ACAAcAB1AGIAbABpAGMAIAB1AGwAbwBuAGcAIABwAGEAZAA7ACAAfQAKACAAIAAgACAAcAB1AGIAbABpAGMAIABzAHQAYQB0AGkAYwAgAHYAbwBpAGQAIABUAGEAcAAoAHUAcwBoAG8AcgB0ACAAdgBrACkAIAB7AAoAIAAgACAAIAAgACAAIAAgAEkA"
  ..     "TgBQAFUAVABbAF0AIABkACAAPQAgAG4AZQB3ACAASQBOAFAAVQBUAFsAMQBdADsAIABkAFsAMABdAC4AdAB5AHAAZQAgAD0AIAAxADsAIABkAFsAMABdAC4AawBpAC4AdgBrACAAPQAgAHYAawA7AAoAIAAgACAAIAAgACAAIAAgAFMAZQBuAGQASQBuAHAAdQB0ACgA"
  ..     "MQAsACAAZAAsACAATQBhAHIAcwBoAGEAbAAuAFMAaQB6AGUATwBmACgAdAB5AHAAZQBvAGYAKABJAE4AUABVAFQAKQApACkAOwAKACAAIAAgACAAIAAgACAAIABTAHkAcwB0AGUAbQAuAFQAaAByAGUAYQBkAGkAbgBnAC4AVABoAHIAZQBhAGQALgBTAGwAZQBlAHAA"
  ..     "KAAzADAAKQA7AAoAIAAgACAAIAAgACAAIAAgAEkATgBQAFUAVABbAF0AIAB1ACAAPQAgAG4AZQB3ACAASQBOAFAAVQBUAFsAMQBdADsAIAB1AFsAMABdAC4AdAB5AHAAZQAgAD0AIAAxADsAIAB1AFsAMABdAC4AawBpACAAPQAgAG4AZQB3ACAASwBFAFkAQgBEAEkA"
  ..     "TgBQAFUAVAAgAHsAIAB2AGsAIAA9ACAAdgBrACwAIABmAGwAYQBnAHMAIAA9ACAAMgAgAH0AOwAKACAAIAAgACAAIAAgACAAIABTAGUAbgBkAEkAbgBwAHUAdAAoADEALAAgAHUALAAgAE0AYQByAHMAaABhAGwALgBTAGkAegBlAE8AZgAoAHQAeQBwAGUAbwBmACgA"
  ..     "SQBOAFAAVQBUACkAKQApADsACgAgACAAIAAgAH0ACgB9AAoAIgBAAAoACgAkAGMAcgBlAGEAdABlAGQAIAA9ACAAJABmAGEAbABzAGUACgB0AHIAeQAgAHsAIAAkAG0AdQB0AGUAeAAgAD0AIABbAFMAeQBzAHQAZQBtAC4AVABoAHIAZQBhAGQAaQBuAGcALgBNAHUA"
  ..     "dABlAHgAXQA6ADoAbgBlAHcAKAAkAHQAcgB1AGUALAAgACIARABvAGQAZwBlAE0AbwBkAE0AbwBkAGkAZgBpAGUAcgBMAGkAcwB0AGUAbgBlAHIAIgAsACAAWwByAGUAZgBdACQAYwByAGUAYQB0AGUAZAApACAAfQAgAGMAYQB0AGMAaAAgAHsAIAAkAGMAcgBlAGEA"
  ..     "dABlAGQAIAA9ACAAJAB0AHIAdQBlACAAfQAKAGkAZgAgACgALQBuAG8AdAAgACQAYwByAGUAYQB0AGUAZAApACAAewAgAGUAeABpAHQAIAB9AAoACgAjACAAbQBvAGQAaQBmAGkAZQByACAAVgBLACAALQA+ACAAcwB5AG4AdABoAGUAdABpAGMAIABGAC0AawBlAHkA"
  ..     "IABWAEsAIAAoAHAAcgBpAHYAYQB0AGUAIABjAGgAYQBuAG4AZQBsACwAIABuAG8AIABrAGUAeQBiAG8AYQByAGQAIABoAGEAcwAgAEYAMQAzACsAKQAKACQAbQBhAHAAIAA9ACAAQAB7AAoAIAAgACAAIAAwAHgAQQAwACAAPQAgADAAeAA4ADAAIAAgACMAIABMAGUA"
  ..     "ZgB0ACAAUwBoAGkAZgB0ACAAIAAtAD4AIABGADEANwAKACAAIAAgACAAMAB4AEEAMQAgAD0AIAAwAHgAOAAxACAAIAAjACAAUgBpAGcAaAB0ACAAUwBoAGkAZgB0ACAALQA+ACAARgAxADgACgAgACAAIAAgADAAeABBADIAIAA9ACAAMAB4ADcARQAgACAAIwAgAEwA"
  ..     "ZQBmAHQAIABDAHQAcgBsACAAIAAgAC0APgAgAEYAMQA1AAoAIAAgACAAIAAwAHgAQQAzACAAPQAgADAAeAA3AEYAIAAgACMAIABSAGkAZwBoAHQAIABDAHQAcgBsACAAIAAtAD4AIABGADEANgAKACAAIAAgACAAMAB4AEEANAAgAD0AIAAwAHgANwBDACAAIAAjACAA"
  ..     "TABlAGYAdAAgAEEAbAB0ACAAIAAgACAALQA+ACAARgAxADMACgAgACAAIAAgADAAeABBADUAIAA9ACAAMAB4ADcARAAgACAAIwAgAFIAaQBnAGgAdAAgAEEAbAB0ACAAIAAgAC0APgAgAEYAMQA0AAoAIAAgACAAIAAwAHgAMQAwACAAPQAgADAAeAA3AEMAIAAgACMA"
  ..     "IABnAGUAbgBlAHIAaQBjACAAUwBoAGkAZgB0AAoAIAAgACAAIAAwAHgAMQAxACAAPQAgADAAeAA3AEUAIAAgACMAIABnAGUAbgBlAHIAaQBjACAAQwB0AHIAbAAKACAAIAAgACAAMAB4ADEAMgAgAD0AIAAwAHgANwBDACAAIAAjACAAZwBlAG4AZQByAGkAYwAgAEEA"
  ..     "bAB0AAoAfQAKACQAdwBhAHMARABvAHcAbgAgAD0AIABAAHsAfQAKACQAbQBvAGQAVgBLAHMAIAA9ACAAQAAoACQAbQBhAHAALgBLAGUAeQBzACkACgAKAFcAcgBpAHQAZQAtAEgAbwBzAHQAIAAiAE0AbwBkAGkAZgBpAGUAcgAgAGsAZQB5ACAAbABpAHMAdABlAG4A"
  ..     "ZQByACAAcgB1AG4AbgBpAG4AZwAgACgAQQBsAHQALwBDAHQAcgBsAC8AUwBoAGkAZgB0ACAALQA+ACAAZABvAGQAZwBlACAAaQBuAHAAdQB0AHMAKQAuACIACgBXAHIAaQB0AGUALQBIAG8AcwB0ACAAIgBBAHUAdABvAC0AZQB4AGkAdABzACAAdwBoAGUAbgAgAHQA"
  ..     "aABlACAAZwBhAG0AZQAgAGMAbABvAHMAZQBzAC4AIgAKAAoAdwBoAGkAbABlACAAKAAkAHQAcgB1AGUAKQAgAHsACgAgACAAIAAgAGYAbwByAGUAYQBjAGgAIAAoACQAbQB2AGsAIABpAG4AIAAkAG0AbwBkAFYASwBzACkAIAB7AAoAIAAgACAAIAAgACAAIAAgACQA"
  ..     "ZABvAHcAbgAgAD0AIAAoACgAWwBNAG8AZABMAGkAcwB0AGUAbgBdADoAOgBHAGUAdABBAHMAeQBuAGMASwBlAHkAUwB0AGEAdABlACgAJABtAHYAawApACAALQBiAGEAbgBkACAAMAB4ADgAMAAwADAAKQAgAC0AbgBlACAAMAApAAoAIAAgACAAIAAgACAAIAAgAGkA"
  ..     "ZgAgACgAJABkAG8AdwBuACAALQBhAG4AZAAgAC0AbgBvAHQAIAAkAHcAYQBzAEQAbwB3AG4AWwAkAG0AdgBrAF0AKQAgAHsACgAgACAAIAAgACAAIAAgACAAIAAgACAAIABbAE0AbwBkAEwAaQBzAHQAZQBuAF0AOgA6AFQAYQBwACgAWwBiAHkAdABlAF0AJABtAGEA"
  ..     "cABbACQAbQB2AGsAXQApAAoAIAAgACAAIAAgACAAIAAgAH0ACgAgACAAIAAgACAAIAAgACAAJAB3AGEAcwBEAG8AdwBuAFsAJABtAHYAawBdACAAPQAgACQAZABvAHcAbgAKACAAIAAgACAAfQAKAAoAIAAgACAAIAAjACAAYQB1AHQAbwAtAGUAeABpAHQAIAB3AGgA"
  ..     "ZQBuACAAdABoAGUAIABnAGEAbQBlACAAYwBsAG8AcwBlAHMACgAgACAAIAAgACQAYQBsAGkAdgBlACAAPQAgACQAZgBhAGwAcwBlAAoAIAAgACAAIABmAG8AcgBlAGEAYwBoACAAKAAkAG4AIABpAG4AIABAACgAJwBTAHQAYQBsAGsAZQByADIALQBXAGkAbgA2ADQA"
  ..     "LQBTAGgAaQBwAHAAaQBuAGcAJwAsACAAJwBTAHQAYQBsAGsAZQByADIAJwApACkAIAB7AAoAIAAgACAAIAAgACAAIAAgAGkAZgAgACgARwBlAHQALQBQAHIAbwBjAGUAcwBzACAALQBOAGEAbQBlACAAJABuACAALQBFAHIAcgBvAHIAQQBjAHQAaQBvAG4AIABTAGkA"
  ..     "bABlAG4AdABsAHkAQwBvAG4AdABpAG4AdQBlACkAIAB7ACAAJABhAGwAaQB2AGUAIAA9ACAAJAB0AHIAdQBlADsAIABiAHIAZQBhAGsAIAB9AAoAIAAgACAAIAB9AAoAIAAgACAAIABpAGYAIAAoAC0AbgBvAHQAIAAkAGEAbABpAHYAZQApACAAewAgAGIAcgBlAGEA"
  ..     "awAgAH0ACgAgACAAIAAgAFMAdABhAHIAdAAtAFMAbABlAGUAcAAgAC0ATQBpAGwAbABpAHMAZQBjAG8AbgBkAHMAIAAyADUACgB9AAoA"

-- ================= boot =================
-- modifier keys (Left Alt etc.) cannot be bound via UE4SS hooks; when one is
-- configured, the mod binds the key's private F13-F24 channel instead and
-- auto-starts the companion listener, which taps that F-key on each press
local modifierButton = false
do
    local n = string.upper(string.gsub(KEY_DODGE_BTN, "[^%w]", ""))
    if n == "LEFTALT" or n == "LALT" or n == "ALT" then KEY_DODGE_BTN = "F13"; modifierButton = true
    elseif n == "RIGHTALT" or n == "RALT" then KEY_DODGE_BTN = "F14"; modifierButton = true
    elseif n == "LEFTCONTROL" or n == "LCTRL" or n == "CTRL" then KEY_DODGE_BTN = "F15"; modifierButton = true
    elseif n == "RIGHTCONTROL" or n == "RCTRL" then KEY_DODGE_BTN = "F16"; modifierButton = true
    elseif n == "LEFTSHIFT" or n == "LSHIFT" or n == "SHIFT" then KEY_DODGE_BTN = "F17"; modifierButton = true
    elseif n == "RIGHTSHIFT" or n == "RSHIFT" then KEY_DODGE_BTN = "F18"; modifierButton = true end
end
if MODALITY == "button" and modifierButton then
    if cfgPath ~= nil and os ~= nil and type(os.execute) == "function" then
        local listenerPath = string.gsub(cfgPath, "ConfigurableDodgeMod%.ini$", "ModifierListener.ps1")
        pcall(function()
            os.execute('start "DodgeModListener" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. listenerPath .. '"')
        end)
        print("[Configurable Dodge Mod] Dodge button: " .. KEY_DODGE_BTN .. ". A small background helper was started so this key works - if dodging does not respond, restart the game once. If it still does not work, your system is blocking the helper: open ConfigurableDodgeMod.ini and set ButtonKey=X (or any letter / mouse button).")
        DevLog("modifier listener auto-started, bind=" .. KEY_DODGE_BTN)
    end
    -- boot-context bind of the private F-key (dofile-context binds never fire)
    local k = keyNameToValue[KEY_DODGE_BTN]
    if k ~= nil then
        pcall(function()
            RegisterKeyBind(k, function() DodgeMod_Dispatch("button", KEY_DODGE_BTN) end)
        end)
        DevLog("bound modifier channel: " .. KEY_DODGE_BTN)
    end
end
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
-- role "anykey": the MCM manager's AnyKey input events (fire on every
-- keypress in gameplay, modifiers included). Key names arrive as engine
-- KeyNames ("LeftAlt", "X", "ThumbMouseButton2") and are compared against
-- the normalized ini config.
DodgeMod_Handlers = function(role, keyUpper)
    if role == "anykey" then
        local inUI = false
        pcall(function()
            local PC = GetPC()
            if PC ~= nil and PC:IsValid() then inUI = PC.bShowMouseCursor end
        end)
        if inUI then return end
        if MODALITY == "button" then
            if keyUpper == KeyNorm(KEY_DODGE_BTN) then
                HandleButtonPress()
            end
        else
            if keyUpper == KeyNorm(DT_LEFT) then
                HandleTap("left")
            elseif keyUpper == KeyNorm(DT_RIGHT) then
                HandleTap("right")
            elseif ENABLE_BACK and keyUpper == KeyNorm(DT_BACK) then
                HandleTap("back")
            end
        end
    elseif role == "mouse" then
        -- mouse-configured dodge buttons (window hooks, verified in gameplay)
        if MODALITY == "button" and keyUpper == KeyNorm(KEY_DODGE_BTN) then
            HandleButtonPress()
        end
    end
end
DevLog("dispatcher wired gen=" .. tostring(DODGE_MOD_GEN))

-- TEST: os.execute availability (for auto-starting the Alt listener)
if devEnabled then
    DevLog("probe: type(os.execute)=" .. type(os and os.execute))
    local testFile = cfgPath and (string.gsub(cfgPath, "ConfigurableDodgeMod%.ini$", "os_execute_test.txt")) or "os_execute_test.txt"
    pcall(function()
        os.execute('cmd /c echo ok > "' .. testFile .. '"')
    end)
    local content = nil
    pcall(function()
        local h = io.open(testFile, "r")
        if h ~= nil then content = h:read("*a"); h:close() end
    end)
    DevLog("probe: os.execute wrote file: " .. tostring(content ~= nil))
end
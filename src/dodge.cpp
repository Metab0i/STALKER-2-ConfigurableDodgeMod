// Configurable Dodge Mod (native) for S.T.A.L.K.E.R. 2, update 2.1.0 (build a6b31ee).
//
// Loads as a UE4SS C++ mod: drop ConfigurableDodgeNative\ into
// Stalker2\Binaries\Win64\ue4ss\Mods\ and enable it in mods.txt.
// UE4SS loads dlls\main.dll and calls start_mod(); this mod then hooks the
// game's PeekMessageW import, ticks on the game thread, and launches the
// character directly. ConfigurableDodge.ini sits next to the mod folder.
//
// Everything below that carries a "verified" note was checked against the
// shipped binary; see README.md for how.

#include <windows.h>
#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <cmath>
#include <cstdio>
#include <cwchar>

namespace
{
    // FUObjectArray. Verified: UE4SS's own GUObjectArray signature on this build
    // resolves to 0xA0D4980 (ObjObjects at +0x10).
    constexpr uintptr_t RVA_UOBJECT_ARRAY = 0x0A0D4980;
    // Verified by disassembly: float GetSP(pawn) / void ForceSetSP(pawn,int) /
    // float GetOveruse(pawn).
    constexpr uintptr_t RVA_GET_SP = 0x01FB413C;
    constexpr uintptr_t RVA_FORCE_SET_SP = 0x068984C2;
    constexpr uintptr_t RVA_GET_OVERUSE = 0x06896BB6;
    // Verified: the game's import table resolves USER32!PeekMessageW at this RVA.
    // Used to get a safe per-frame tick on the game thread.
    constexpr uintptr_t RVA_PEEK_MESSAGE_IAT = 0x09C37B30;

    // Not statically verified; checked at runtime before the call is made.
    constexpr size_t VTABLE_LAUNCH_CHARACTER = 0x948;

    constexpr size_t OFF_OBJECT_INTERNAL_INDEX = 0x0C;
    // Verified against ue4ss/UE4SS_ObjectDump.txt for this build.
    constexpr size_t OFF_CONTROLLER_PAWN = 0x2F0;
    constexpr size_t OFF_CONTROLLER_ROTATION = 0x328;
    constexpr size_t OFF_PLAYER_CONTROLLER_PLAYER = 0x350;
    constexpr size_t OFF_PLAYER_CONTROLLER_CAMERA = 0x368;
    constexpr size_t OFF_PLAYER_CONTROLLER_CURSOR = 0x56C;
    constexpr size_t OFF_PAWN_LAST_INPUT = 0x310;
    constexpr size_t OFF_PAWN_CONTROLLER = 0x2E0;

    constexpr wchar_t MOD_VERSION[] = L"4.0.0";

    constexpr uint64_t TICK_INTERVAL_MS = 10;
    constexpr uint64_t FIND_RETRY_MS = 1000;
    constexpr int32_t SCAN_LIMIT = 400000;

    // UE5 large-world-coordinates: FVector/FRotator are three doubles.
    struct FVector
    {
        double X;
        double Y;
        double Z;
    };

    struct FRotator
    {
        double Pitch;
        double Yaw;
        double Roll;
    };

    static_assert(sizeof(FVector) == 24, "UE5 FVector is 3 doubles");
    static_assert(sizeof(FRotator) == 24, "UE5 FRotator is 3 doubles");

    struct FUObjectItem
    {
        void* Object;
        int32_t Flags;
        int32_t ClusterRootIndex;
        int32_t SerialNumber;
    };

    struct TUObjectArray
    {
        FUObjectItem** Objects;
        void* PreAllocatedObjects;
        int32_t MaxElements;
        int32_t NumElements;
        int32_t MaxChunks;
        int32_t NumChunks;
    };

    struct FUObjectArray
    {
        int32_t ObjFirstGCIndex;
        int32_t ObjLastNonGCIndex;
        int32_t MaxObjectsNotConsideredByGC;
        uint8_t OpenForDisregardForGC;
        uint8_t Padding[3];
        TUObjectArray ObjObjects;
    };

    static_assert(offsetof(FUObjectArray, ObjObjects) == 0x10);

    using LaunchCharacterFn = void(__fastcall*)(void*, FVector*, int32_t, int32_t);
    using GetSPFn = float(__fastcall*)(void*);
    using ForceSetSPFn = void(__fastcall*)(void*, int32_t);
    using GetOveruseFn = float(__fastcall*)(void*);
    using PeekMessageFn = BOOL(WINAPI*)(LPMSG, HWND, UINT, UINT, UINT);

    enum DodgeDirection
    {
        DodgeNone = 0,
        DodgeLeft = 1,
        DodgeRight = 2,
        DodgeBack = 3
    };

    struct Config
    {
        int modality;
        int buttonKey;
        int leftKey;
        int rightKey;
        int backKey;
        double sideHorizontal;
        double sideVertical;
        double backHorizontal;
        double backVertical;
        double doubleTapWindow;
        double cooldown;
        double staminaCost;
        int requireStamina;
        int energyDrink;
        double energyFreeSeconds;
        double energyOveruseJump;
        int requireCursorFree;
        int log;
    };

    Config g_config{};
    HMODULE g_self{};
    uintptr_t g_base{};
    uintptr_t g_baseEnd{};
    FUObjectArray* g_objects{};
    DWORD g_gameThread{};
    PeekMessageFn g_realPeek{};
    void* g_controller{};
    void* g_pawn{};
    bool g_prevButton{};
    bool g_prevLeft{};
    bool g_prevRight{};
    bool g_prevBack{};
    uint64_t g_lastTapLeft{};
    uint64_t g_lastTapRight{};
    uint64_t g_lastTapBack{};
    uint64_t g_lastDodge{};
    uint64_t g_lastTick{};
    uint64_t g_lastFind{};
    uint64_t g_lastFindLog{};
    uint64_t g_energyFreeUntil{};

    bool g_hookInstalled{};
    bool g_pawnLogged{};
    bool g_stopping{};
    uint64_t g_configStamp{};
    uint64_t g_lastConfigPoll{};
    float g_lastOveruse = -1.0f;
    wchar_t g_iniPath[MAX_PATH]{};
    wchar_t g_logPath[MAX_PATH]{};

    // UTF-8 on disk: readable with any editor and grep, unlike UTF-16.
    void Log(const wchar_t* text)
    {
        if (g_config.log == 0 || g_logPath[0] == 0)
        {
            return;
        }

        HANDLE file = CreateFileW(g_logPath, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE)
        {
            return;
        }

        char buffer[1024]{};
        int bytes = WideCharToMultiByte(CP_UTF8, 0, text, -1, buffer, static_cast<int>(sizeof(buffer)) - 2, nullptr, nullptr);
        if (bytes > 1)
        {
            DWORD written = 0;
            buffer[bytes - 1] = '\r';
            buffer[bytes] = '\n';
            WriteFile(file, buffer, static_cast<DWORD>(bytes + 1), &written, nullptr);
        }

        CloseHandle(file);
    }

    void Logf(const wchar_t* format, ...)
    {
        if (g_config.log == 0 || g_logPath[0] == 0)
        {
            return;
        }

        wchar_t buffer[512]{};
        va_list args;
        va_start(args, format);
        _vsnwprintf_s(buffer, _TRUNCATE, format, args);
        va_end(args);
        Log(buffer);
    }

    void ReplaceFileName(wchar_t* path, const wchar_t* name)
    {
        wchar_t* slash = wcsrchr(path, L'\\');
        if (slash == nullptr)
        {
            return;
        }

        wcsncpy(slash + 1, name, MAX_PATH - static_cast<size_t>(slash + 1 - path));
        path[MAX_PATH - 1] = 0;
    }

    void StripFile(wchar_t* path)
    {
        wchar_t* slash = wcsrchr(path, L'\\');
        if (slash != nullptr)
        {
            *slash = 0;
        }
    }

    bool FileExists(const wchar_t* path)
    {
        DWORD attributes = GetFileAttributesW(path);
        return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
    }

    // The DLL lives in <mod>\dlls\main.dll; the ini ships in <mod>\.
    void BuildPaths()
    {
        wchar_t module[MAX_PATH]{};
        GetModuleFileNameW(g_self, module, MAX_PATH);

        wchar_t dllDir[MAX_PATH]{};
        wcscpy(dllDir, module);
        StripFile(dllDir);

        wchar_t modRoot[MAX_PATH]{};
        wcscpy(modRoot, dllDir);
        StripFile(modRoot);

        // lstrcpy/lstrcat, not swprintf: MinGW's wide printf treats %s as narrow.
        lstrcpyW(g_iniPath, modRoot);
        lstrcatW(g_iniPath, L"\\ConfigurableDodge.ini");
        if (!FileExists(g_iniPath))
        {
            lstrcpyW(g_iniPath, dllDir);
            lstrcatW(g_iniPath, L"\\ConfigurableDodge.ini");
        }

        lstrcpyW(g_logPath, modRoot);
        lstrcatW(g_logPath, L"\\ConfigurableDodge.log");
    }

    bool ConfigChanged()
    {
        WIN32_FILE_ATTRIBUTE_DATA data{};
        if (GetFileAttributesExW(g_iniPath, GetFileExInfoStandard, &data) == 0)
        {
            return false;
        }

        uint64_t stamp = (static_cast<uint64_t>(data.ftLastWriteTime.dwHighDateTime) << 32) |
                         data.ftLastWriteTime.dwLowDateTime;
        if (stamp == g_configStamp)
        {
            return false;
        }

        g_configStamp = stamp;
        return true;
    }

    int IniInt(const wchar_t* key, int fallback)
    {
        return static_cast<int>(GetPrivateProfileIntW(L"Config", key, fallback, g_iniPath));
    }

    double IniFloat(const wchar_t* key, double fallback)
    {
        wchar_t buffer[64]{};
        GetPrivateProfileStringW(L"Config", key, L"", buffer, 64, g_iniPath);
        if (buffer[0] == 0)
        {
            return fallback;
        }

        return wcstod(buffer, nullptr);
    }

    void IniString(const wchar_t* key, const wchar_t* fallback, wchar_t* buffer, DWORD size)
    {
        GetPrivateProfileStringW(L"Config", key, fallback, buffer, size, g_iniPath);
    }

    int ParseKey(const wchar_t* value, int fallback)
    {
        if (value == nullptr || value[0] == 0)
        {
            return fallback;
        }

        if (value[0] == L'0' && (value[1] == L'x' || value[1] == L'X'))
        {
            return static_cast<int>(wcstoul(value + 2, nullptr, 16));
        }

        if (wcslen(value) == 1)
        {
            wchar_t c = value[0];
            if (c >= L'a' && c <= L'z')
            {
                c = static_cast<wchar_t>(c - L'a' + L'A');
            }

            if ((c >= L'A' && c <= L'Z') || (c >= L'0' && c <= L'9'))
            {
                return c;
            }
        }

        if ((value[0] == L'F' || value[0] == L'f') && value[1] != 0)
        {
            int number = static_cast<int>(wcstol(value + 1, nullptr, 10));
            if (number >= 1 && number <= 24)
            {
                return VK_F1 + number - 1;
            }
        }

        if (lstrcmpiW(value, L"Left Alt") == 0) return VK_LMENU;
        if (lstrcmpiW(value, L"Right Alt") == 0) return VK_RMENU;
        if (lstrcmpiW(value, L"Left Ctrl") == 0) return VK_LCONTROL;
        if (lstrcmpiW(value, L"Left Control") == 0) return VK_LCONTROL;
        if (lstrcmpiW(value, L"Right Ctrl") == 0) return VK_RCONTROL;
        if (lstrcmpiW(value, L"Right Control") == 0) return VK_RCONTROL;
        if (lstrcmpiW(value, L"Left Shift") == 0) return VK_LSHIFT;
        if (lstrcmpiW(value, L"Right Shift") == 0) return VK_RSHIFT;
        if (lstrcmpiW(value, L"Space") == 0) return VK_SPACE;
        if (lstrcmpiW(value, L"SpaceBar") == 0) return VK_SPACE;
        if (lstrcmpiW(value, L"Tab") == 0) return VK_TAB;
        if (lstrcmpiW(value, L"Enter") == 0) return VK_RETURN;
        if (lstrcmpiW(value, L"Escape") == 0) return VK_ESCAPE;
        if (lstrcmpiW(value, L"Backspace") == 0) return VK_BACK;
        if (lstrcmpiW(value, L"Mouse Left") == 0) return VK_LBUTTON;
        if (lstrcmpiW(value, L"Mouse Right") == 0) return VK_RBUTTON;
        if (lstrcmpiW(value, L"Mouse Middle") == 0) return VK_MBUTTON;
        if (lstrcmpiW(value, L"Mouse 4") == 0) return VK_XBUTTON1;
        if (lstrcmpiW(value, L"Mouse 5") == 0) return VK_XBUTTON2;

        return fallback;
    }

    void LoadConfig()
    {
        wchar_t value[64]{};

        IniString(L"Modality", L"button", value, 64);
        g_config.modality = lstrcmpiW(value, L"doubletap") == 0 ? 1 : 0;

        IniString(L"ButtonKey", L"Left Alt", value, 64);
        g_config.buttonKey = ParseKey(value, VK_LMENU);

        IniString(L"DoubleTapLeft", L"Z", value, 64);
        g_config.leftKey = ParseKey(value, L'Z');

        IniString(L"DoubleTapRight", L"C", value, 64);
        g_config.rightKey = ParseKey(value, L'C');

        IniString(L"DoubleTapBack", L"S", value, 64);
        g_config.backKey = ParseKey(value, L'S');

        g_config.sideHorizontal = IniFloat(L"SideHorizontal", 650.0);
        g_config.sideVertical = IniFloat(L"SideVertical", 500.0);
        g_config.backHorizontal = IniFloat(L"BackHorizontal", 900.0);
        g_config.backVertical = IniFloat(L"BackVertical", 200.0);
        g_config.doubleTapWindow = IniFloat(L"DoubleTapWindow", 0.155);
        g_config.cooldown = IniFloat(L"Cooldown", 0.6);
        g_config.staminaCost = IniFloat(L"StaminaCost", 15.0);
        g_config.requireStamina = IniInt(L"RequireStamina", 1);
        g_config.energyDrink = IniInt(L"EnergyDrinkEffect", 1);
        g_config.energyFreeSeconds = IniFloat(L"EnergyDrinkFreeSeconds", 4.5);
        g_config.energyOveruseJump = IniFloat(L"EnergyDrinkOveruseJump", 50.0);
        g_config.requireCursorFree = IniInt(L"RequireCursorFree", 1);
        g_config.log = IniInt(L"Log", 1);
    }

    uintptr_t g_readableBase{1};
    uintptr_t g_readableEnd{};

    void InvalidateReadableCache()
    {
        g_readableBase = 1;
        g_readableEnd = 0;
    }

    bool Readable(const void* address, size_t size)
    {
        if (address == nullptr || size == 0)
        {
            return false;
        }

        // Objects live in long contiguous regions; a cached hit avoids a
        // VirtualQuery per object. Only readable ranges are cached.
        auto probe = reinterpret_cast<uintptr_t>(address);
        if (probe >= g_readableBase && probe + size <= g_readableEnd)
        {
            return true;
        }

        MEMORY_BASIC_INFORMATION info{};
        if (VirtualQuery(address, &info, sizeof(info)) == 0)
        {
            return false;
        }

        if (info.State != MEM_COMMIT || (info.Protect & (PAGE_NOACCESS | PAGE_GUARD)) != 0)
        {
            return false;
        }

        auto start = reinterpret_cast<uintptr_t>(address);
        auto regionEnd = reinterpret_cast<uintptr_t>(info.BaseAddress) + info.RegionSize;
        if (start + size <= regionEnd)
        {
            g_readableBase = reinterpret_cast<uintptr_t>(info.BaseAddress);
            g_readableEnd = regionEnd;
            return true;
        }

        return false;
    }

    bool InOwnImage(const void* address)
    {
        auto value = reinterpret_cast<uintptr_t>(address);
        return value >= g_base && value < g_baseEnd;
    }

    bool KeyDown(int key)
    {
        return key != 0 && (GetAsyncKeyState(key) & 0x8000) != 0;
    }

    bool OwnWindowFocused()
    {
        HWND foreground = GetForegroundWindow();
        if (foreground == nullptr)
        {
            return false;
        }

        DWORD pid = 0;
        GetWindowThreadProcessId(foreground, &pid);
        return pid == GetCurrentProcessId();
    }

    bool IsLiveObject(void* object)
    {
        if (object == nullptr || g_objects == nullptr || !Readable(object, OFF_OBJECT_INTERNAL_INDEX + sizeof(int32_t)))
        {
            return false;
        }

        int32_t index = *reinterpret_cast<int32_t*>(reinterpret_cast<uint8_t*>(object) + OFF_OBJECT_INTERNAL_INDEX);
        TUObjectArray& array = g_objects->ObjObjects;
        if (index < 0 || index >= array.NumElements)
        {
            return false;
        }

        int32_t chunk = index >> 16;
        int32_t within = index & 0xFFFF;
        if (chunk < 0 || chunk >= array.NumChunks || array.Objects == nullptr || !Readable(array.Objects + chunk, sizeof(FUObjectItem*)))
        {
            return false;
        }

        FUObjectItem* item = array.Objects[chunk];
        if (item == nullptr || !Readable(item + within, sizeof(FUObjectItem)))
        {
            return false;
        }

        return (item + within)->Object == object;
    }

    bool FindController()
    {
        if (g_objects == nullptr || !Readable(g_objects, sizeof(FUObjectArray)))
        {
            return false;
        }

        TUObjectArray& array = g_objects->ObjObjects;
        if (array.Objects == nullptr || array.NumElements < 1000 || array.NumChunks <= 0)
        {
            return false;
        }

        int32_t limit = array.NumElements < SCAN_LIMIT ? array.NumElements : SCAN_LIMIT;
        int32_t linked = 0;
        int32_t ownerMatches = 0;
        for (int32_t chunk = 0; chunk < array.NumChunks; ++chunk)
        {
            int32_t first = chunk * 0x10000;
            if (first >= limit)
            {
                break;
            }

            int32_t count = limit - first;
            if (count > 0x10000)
            {
                count = 0x10000;
            }

            FUObjectItem** chunkSlot = array.Objects + chunk;
            if (!Readable(chunkSlot, sizeof(FUObjectItem*)))
            {
                continue;
            }

            FUObjectItem* items = *chunkSlot;
            if (items == nullptr || !Readable(items, sizeof(FUObjectItem)))
            {
                continue;
            }

            for (int32_t within = 0; within < count; ++within)
            {
            FUObjectItem* item = items + within;
            if (!Readable(item, sizeof(FUObjectItem)))
            {
                continue;
            }

            void* object = (item + within)->Object;
            if (object == nullptr || !Readable(object, OFF_PLAYER_CONTROLLER_PLAYER + sizeof(void*)))
            {
                continue;
            }

            void* player = *reinterpret_cast<void**>(reinterpret_cast<uint8_t*>(object) + OFF_PLAYER_CONTROLLER_PLAYER);
            if (player == nullptr || player == object || !Readable(player, 0x38))
            {
                continue;
            }

            ++linked;

            // ULocalPlayer::PlayerController back-pointer. Verified offset (0x30)
            // in ue4ss/UE4SS_ObjectDump.txt. The pawn is resolved lazily so a
            // controller without a possessed pawn (main menu) still matches.
            if (*reinterpret_cast<void**>(reinterpret_cast<uint8_t*>(player) + 0x30) != object)
            {
                continue;
            }

            ++ownerMatches;

            g_controller = object;
            g_pawn = nullptr;
            Logf(L"controller found (index %d of %d, controller 0x%llx)", first + within, array.NumElements,
                 static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(object)));
            return true;
            }
        }

        Logf(L"scan: %d objects, %d with player pointer, %d with player->controller match",
             limit, linked, ownerMatches);
        return false;
    }

    bool EnsurePawn()
    {
        if (g_controller == nullptr || !IsLiveObject(g_controller))
        {
            g_controller = nullptr;
            g_pawn = nullptr;
            return false;
        }

        void* pawn = *reinterpret_cast<void**>(reinterpret_cast<uint8_t*>(g_controller) + OFF_CONTROLLER_PAWN);
        if (pawn == nullptr || !IsLiveObject(pawn) || !Readable(pawn, 0x330))
        {
            g_pawn = nullptr;
            return false;
        }

        g_pawn = pawn;
        return true;
    }

    // Verified: Pawn::LastControlInputVector at +0x310, struct FVector (3 doubles).
    int GetMoveDirection()
    {
        FVector input = *reinterpret_cast<FVector*>(reinterpret_cast<uint8_t*>(g_pawn) + OFF_PAWN_LAST_INPUT);
        double magnitude = input.X * input.X + input.Y * input.Y + input.Z * input.Z;
        if (!std::isfinite(magnitude) || magnitude < 0.01)
        {
            return DodgeNone;
        }

        FRotator rotation = *reinterpret_cast<FRotator*>(reinterpret_cast<uint8_t*>(g_controller) + OFF_CONTROLLER_ROTATION);
        double yaw = rotation.Yaw;
        if (!std::isfinite(yaw))
        {
            return DodgeNone;
        }

        double radians = yaw * 0.017453292519943295;
        double forwardDot = cos(radians) * input.X + sin(radians) * input.Y;
        double rightDot = -sin(radians) * input.X + cos(radians) * input.Y;

        if (fabs(rightDot) >= fabs(forwardDot))
        {
            return rightDot > 0.0 ? DodgeRight : DodgeLeft;
        }

        return forwardDot < 0.0 ? DodgeBack : DodgeNone;
    }

    bool SpendStamina(uint64_t now)
    {
        if (g_config.staminaCost <= 0.0)
        {
            return true;
        }

        if (g_config.energyDrink != 0)
        {
            auto getOveruse = reinterpret_cast<GetOveruseFn>(g_base + RVA_GET_OVERUSE);
            float overuse = getOveruse(g_pawn);
            if (g_lastOveruse >= 0.0f && overuse - g_lastOveruse >= g_config.energyOveruseJump)
            {
                g_energyFreeUntil = now + static_cast<uint64_t>(g_config.energyFreeSeconds * 1000.0);
                Logf(L"energy drink detected (overuse %.1f -> %.1f): free dodges for %.2fs",
                     g_lastOveruse, overuse, g_config.energyFreeSeconds);
            }

            g_lastOveruse = overuse;

            if (now < g_energyFreeUntil)
            {
                return true;
            }
        }

        auto getSP = reinterpret_cast<GetSPFn>(g_base + RVA_GET_SP);
        auto forceSetSP = reinterpret_cast<ForceSetSPFn>(g_base + RVA_FORCE_SET_SP);
        float stamina = getSP(g_pawn);

        if (g_config.requireStamina != 0 && stamina < g_config.staminaCost)
        {
            Logf(L"blocked: low stamina %.1f < %.1f", stamina, g_config.staminaCost);
            return false;
        }

        int32_t next = static_cast<int32_t>(stamina - g_config.staminaCost);
        if (next < 0)
        {
            next = 0;
        }

        forceSetSP(g_pawn, next);
        Logf(L"stamina %.1f -> %d", stamina, next);
        return true;
    }

    void Dodge(uint64_t now, int direction)
    {
        if (now - g_lastDodge < static_cast<uint64_t>(g_config.cooldown * 1000.0))
        {
            return;
        }

        // bShowMouseCursor is a bitfield (field mask 1, bit mask 1); the byte
        // at +0x56C holds other flags too, so test only bit 0.
        uint8_t cursorFlags = *reinterpret_cast<uint8_t*>(reinterpret_cast<uint8_t*>(g_controller) + OFF_PLAYER_CONTROLLER_CURSOR);
        if (g_config.requireCursorFree != 0 && (cursorFlags & 1) != 0)
        {
            Logf(L"blocked: menu cursor visible (byte 0x%02x)", cursorFlags);
            return;
        }

        FRotator rotation = *reinterpret_cast<FRotator*>(reinterpret_cast<uint8_t*>(g_controller) + OFF_CONTROLLER_ROTATION);
        if (!std::isfinite(rotation.Yaw) || fabs(rotation.Yaw) > 1.0e6)
        {
            Logf(L"aborted: control rotation not sane (yaw %.3f)", rotation.Yaw);
            return;
        }

        if (!SpendStamina(now))
        {
            return;
        }

        double yaw = rotation.Yaw * 0.017453292519943295;
        double forwardX = cos(yaw);
        double forwardY = sin(yaw);
        double rightX = -sin(yaw);
        double rightY = cos(yaw);

        FVector velocity{};
        if (direction == DodgeLeft)
        {
            velocity.X = rightX * -g_config.sideHorizontal;
            velocity.Y = rightY * -g_config.sideHorizontal;
            velocity.Z = g_config.sideVertical;
        }
        else if (direction == DodgeRight)
        {
            velocity.X = rightX * g_config.sideHorizontal;
            velocity.Y = rightY * g_config.sideHorizontal;
            velocity.Z = g_config.sideVertical;
        }
        else
        {
            velocity.X = forwardX * -g_config.backHorizontal;
            velocity.Y = forwardY * -g_config.backHorizontal;
            velocity.Z = g_config.backVertical;
        }

        void** vtable = *reinterpret_cast<void***>(g_pawn);
        if (vtable == nullptr || !Readable(vtable + (VTABLE_LAUNCH_CHARACTER / sizeof(void*)), sizeof(void*)))
        {
            Log(L"aborted: vtable unreadable");
            return;
        }

        auto launch = reinterpret_cast<LaunchCharacterFn>(vtable[VTABLE_LAUNCH_CHARACTER / sizeof(void*)]);
        if (launch == nullptr || !InOwnImage(reinterpret_cast<void*>(launch)))
        {
            Logf(L"aborted: LaunchCharacter slot 0x%llx not in game image",
                 static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(launch)));
            return;
        }

        launch(g_pawn, &velocity, 1, 1);
        g_lastDodge = now;
        Logf(L"dodge dir=%d yaw=%.2f v=(%.0f, %.0f, %.0f)", direction, rotation.Yaw,
             velocity.X, velocity.Y, velocity.Z);
    }

    void Tick()
    {
        if (!g_hookInstalled || !OwnWindowFocused())
        {
            return;
        }

        // The detour runs on the thread that pumps messages for the game window;
        // pin that thread on first use. DllMain's thread is UE4SS's loader thread
        // under a mod loader, so it must not be used for this.
        if (g_gameThread == 0)
        {
            g_gameThread = GetCurrentThreadId();
        }

        if (GetCurrentThreadId() != g_gameThread)
        {
            return;
        }

        // Cached readable ranges must not outlive a tick: the game frees and
        // recomits memory between frames (level loads, GC).
        InvalidateReadableCache();

        uint64_t now = GetTickCount64();
        if (now - g_lastConfigPoll >= 500)
        {
            g_lastConfigPoll = now;
            if (ConfigChanged())
            {
                LoadConfig();
                Log(L"config reloaded");
            }
        }

        if (now - g_lastTick < TICK_INTERVAL_MS)
        {
            return;
        }
        g_lastTick = now;

        if (g_controller == nullptr)
        {
            if (now - g_lastFind < FIND_RETRY_MS)
            {
                return;
            }

            g_lastFind = now;
            if (!FindController())
            {
                if (now - g_lastFindLog >= 5000)
                {
                    g_lastFindLog = now;
                    Log(L"controller not found");
                }

                return;
            }

            g_pawnLogged = false;
        }

        if (!g_pawnLogged && g_pawn != nullptr)
        {
            // Recorded once per controller: lets the vtable slot be checked
            // against the binary without guessing.
            void** vtable = *reinterpret_cast<void***>(g_pawn);
            void* slot = vtable != nullptr ? vtable[VTABLE_LAUNCH_CHARACTER / sizeof(void*)] : nullptr;
            Logf(L"pawn 0x%llx vtable 0x%llx launch_slot 0x%llx",
                 static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(g_pawn)),
                 static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(vtable)),
                 static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(slot)));
            g_pawnLogged = true;
        }

        if (!EnsurePawn())
        {
            return;
        }

        if (g_config.modality == 0)
        {
            bool down = KeyDown(g_config.buttonKey);
            if (down && !g_prevButton)
            {
                int direction = GetMoveDirection();
                if (direction != DodgeNone)
                {
                    Dodge(now, direction);
                }
            }
            g_prevButton = down;
            return;
        }

        auto tap = [&](int key, bool& previous, uint64_t& lastTap, int direction)
        {
            bool down = KeyDown(key);
            if (down && !previous)
            {
                if (lastTap != 0 && now - lastTap <= static_cast<uint64_t>(g_config.doubleTapWindow * 1000.0))
                {
                    lastTap = 0;
                    Dodge(now, direction);
                }
                else
                {
                    lastTap = now;
                }
            }
            previous = down;
        };

        tap(g_config.leftKey, g_prevLeft, g_lastTapLeft, DodgeLeft);
        tap(g_config.rightKey, g_prevRight, g_lastTapRight, DodgeRight);
        tap(g_config.backKey, g_prevBack, g_lastTapBack, DodgeBack);
    }

    BOOL WINAPI PeekMessageDetour(LPMSG message, HWND window, UINT filterMin, UINT filterMax, UINT remove)
    {
        Tick();
        return g_realPeek(message, window, filterMin, filterMax, remove);
    }

    DWORD WINAPI InitThread(LPVOID)
    {
        LoadConfig();
        wchar_t initMessage[64]{};
        lstrcpyW(initMessage, L"native dodge init v");
        lstrcatW(initMessage, MOD_VERSION);
        Log(initMessage);

        HMODULE user32 = nullptr;
        for (int i = 0; i < 300 && !g_stopping; ++i)
        {
            g_base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
            user32 = GetModuleHandleW(L"user32.dll");
            if (g_base != 0 && user32 != nullptr)
            {
                break;
            }

            Sleep(100);
        }

        if (g_base == 0)
        {
            Log(L"main module not found");
            return 0;
        }

        auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(g_base);
        auto nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(g_base + static_cast<uintptr_t>(dos->e_lfanew));
        g_baseEnd = g_base + nt->OptionalHeader.SizeOfImage;

        if (user32 == nullptr)
        {
            user32 = LoadLibraryW(L"user32.dll");
        }

        if (user32 == nullptr)
        {
            Log(L"user32 not found");
            return 0;
        }

        g_objects = reinterpret_cast<FUObjectArray*>(g_base + RVA_UOBJECT_ARRAY);
        void** target = reinterpret_cast<void**>(g_base + RVA_PEEK_MESSAGE_IAT);
        auto expected = reinterpret_cast<PeekMessageFn>(GetProcAddress(user32, "PeekMessageW"));
        if (expected == nullptr)
        {
            Log(L"PeekMessageW not found");
            return 0;
        }

        for (int i = 0; i < 300 && !g_stopping && *target != reinterpret_cast<void*>(expected); ++i)
        {
            Sleep(100);
        }

        if (*target != reinterpret_cast<void*>(expected))
        {
            Log(L"PeekMessageW IAT entry not ready");
            return 0;
        }

        g_realPeek = expected;
        DWORD oldProtect = 0;
        if (VirtualProtect(target, sizeof(void*), PAGE_READWRITE, &oldProtect) == 0)
        {
            Log(L"IAT unprotect failed");
            return 0;
        }

        *target = reinterpret_cast<void*>(&PeekMessageDetour);
        VirtualProtect(target, sizeof(void*), oldProtect, &oldProtect);
        g_hookInstalled = true;
        Logf(L"PeekMessageW hooked (module 0x%llx-0x%llx)",
             static_cast<unsigned long long>(g_base), static_cast<unsigned long long>(g_baseEnd));
        return 0;
    }

}

// UE4SS C++ mod contract: start_mod() runs once the program is up, and
// uninstall_mod() must tolerate the pointer start_mod() returned. Returning
// nullptr keeps UE4SS from calling any CppUserModBase virtual on a fake object;
// the DLL stays loaded and our own init thread does the work.
extern "C" __declspec(dllexport) void* start_mod()
{
    // UE4SS may start a mod through both its mods.txt and enabled.txt passes.
    static LONG started = 0;
    if (InterlockedCompareExchange(&started, 1, 0) != 0)
    {
        Log(L"start_mod called again; already running");
        return nullptr;
    }

    // UE4SS frees a mod DLL whose start_mod returned nullptr; a pinned module
    // can never be unmapped, so the game's PeekMessage import stays valid.
    HMODULE pinned = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                       reinterpret_cast<LPCWSTR>(&start_mod), &pinned);

    DWORD threadId = 0;
    HANDLE thread = CreateThread(nullptr, 0, InitThread, nullptr, 0, &threadId);
    if (thread != nullptr)
    {
        CloseHandle(thread);
    }

    return nullptr;
}

extern "C" __declspec(dllexport) void uninstall_mod(void*)
{
    g_stopping = true;
    if (g_hookInstalled)
    {
        void** target = reinterpret_cast<void**>(g_base + RVA_PEEK_MESSAGE_IAT);
        DWORD oldProtect = 0;
        if (VirtualProtect(target, sizeof(void*), PAGE_READWRITE, &oldProtect) != 0)
        {
            *target = reinterpret_cast<void*>(g_realPeek);
            VirtualProtect(target, sizeof(void*), oldProtect, &oldProtect);
        }

        g_hookInstalled = false;
    }

    Log(L"native dodge unloaded");
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        g_self = instance;
        DisableThreadLibraryCalls(instance);
        BuildPaths();
        LoadConfig();
    }

    return TRUE;
}

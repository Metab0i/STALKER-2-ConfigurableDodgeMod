Configurable Dodge Mod (native) for S.T.A.L.K.E.R. 2 - update 2.1
==================================================================

Hold a movement key (A / D / S) and press Left Alt to dodge. Each dodge costs
stamina; energy drinks make dodges free for a few seconds, like the base game.

INSTALL
  1. Install UE4SS for update 2.1 (requires an already working UE4SS setup).
  2. Copy the folder "ConfigurableDodgeNative" into
        Stalker2\Binaries\Win64\ue4ss\Mods\
  3. Add this line to Stalker2\Binaries\Win64\ue4ss\Mods\mods.txt:
        ConfigurableDodgeNative : 1
  4. Start the game.

No files outside the mod folder are modified. To uninstall, delete the folder
and the mods.txt line.

CONFIGURE
  Edit ConfigurableDodge.ini in this folder. Changes apply within about a
  second, without restarting the game.

    Modality             button | doubletap
    ButtonKey            dodge button for button mode (default Left Alt)
    DoubleTapLeft/Right/Back, DoubleTapWindow
                         double-tap mode bindings (default Z / C / S, 0.155 s)
    SideHorizontal, SideVertical
                         side dodge force in cm/s (default 650 / 500)
    BackHorizontal, BackVertical
                         back dodge force in cm/s (default 900 / 200)
    Cooldown             minimum seconds between dodges (default 0.6)
    StaminaCost          stamina per dodge, 0 = free (default 15)
    RequireStamina       1 = refuse dodges below StaminaCost
    EnergyDrinkEffect    1 = free dodges during the drink's no-drain window
    EnergyDrinkFreeSeconds, EnergyDrinkOveruseJump
                         that window's length and the detection threshold
    Log                  1 = write ConfigurableDodge.log
    RequireCursorFree    1 = no dodging while a menu/cursor is up

DEBUG
  Set Log=1 and read ConfigurableDodge.log. Every dodge records direction,
  yaw, and the launch vector; every refused dodge records why.

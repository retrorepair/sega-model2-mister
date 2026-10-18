# GunCon 2 on this core: what Main_MiSTer does and what the core has to do

Written for the core's author (alphanu1) by retrorepair, 2026-10-18. The app side is a patch series against `MiSTer-devel/Main_MiSTer`
(pinned commit 13f1de9); the series and its tests live in the private repo `retrorepair/MiSTer-GunCon2`, and the parts that matter to a
core are copied here: `patches/0014..0017`, and the tracker itself (`lightgun_crt.cpp/.h`) with its unit tests.

## What a core has to provide (nothing, except for the beacon)

1. **The gun position.** Main_MiSTer maps the GunCon 2's raw X (time since the HSync pulse) and Y (lines since VSync), with one universal
   calibration (the GunCal core, five shots, once) and the core's own measured video timing (`video_calc` in `hps_io.sv`), onto the core's
   picture, and gives the core `joystick_l_analog_N`, an absolute position, -127..+127 edge to edge, saturating at the ends when aimed off
   the screen. This is what `m2_vcop_guns.sv` already reads. Two things the app needs to know about the core, per core name, in a table
   (`guncal_sync_table` in `input.cpp`): the HSync pulse width and the VSync lines (the framework measures where the picture starts after the
   pulse, not how wide the pulse is). For this core: 64 px, 3 lines, measured from `m2_video_timing.sv`.
2. **The core's off-screen strip.** `m2_vcop_guns.sv` flags a gun off-screen within 5% of its range of either end (X 24 / Y 19 units, as MAME's
   model1io2 does). That strip of the picture is a dead zone for an absolute gun. The app handles it with an *inset* (patch 0014): an aim in the
   strip is moved to its inner edge, everything else is exact, and only a real off-screen shot goes into the strip. A one-line alternative on the
   core's side would remove the dead zone altogether: flag off-screen only when the stick is saturated (|a| = 127), which is exactly what a
   calibrated absolute gun (Sinden, GUN4IR) does when it leaves the screen.
3. **The beacon (patch 0017).** Optional, but without it a CRT gun cannot see a dark enemy: a GunCon reads only where there is light, and
   anything under about a third of full brightness is invisible to it (measured on this core with the crosshair on). Virtua Cop's own flash,
   in this core's output, is a black frame (51 of 52 shots saw the gun's spot go dark), so it gives no measurement; the arcade cabinet's
   gun board sat in the video path and presumably supplied its own flash. The contract:
   * `joystick_3` bit 0, driven by Main_MiSTer (`user_io_joystick_word(3, 1)`), is a *level*: while it is high the core shows the **whole
     picture white**, in whole fields (never a torn frame), for at most ~6 fields whatever the level does.
   * The app raises it on a trigger pull, holds the trigger back, reads the gun for about 55 ms (the first lit report after darkness has a
     junk Y, so it needs a few fields of light), then lowers it and gives the core the aim and the trigger together. If the gun saw
     nothing during the white fields it is off the screen, and the app says so (an exact reload, with no guessing).
   * `rtl/video/m2_scan15.sv` implements it in the video path (`beacon` input). Any core that does the same and is listed in
     `crtgun_beacon_core()` gets it; a core that is listed but does not respond makes every shot a reload, so the list is explicit, and
     `LIGHTGUN_CRT_BEACON=0` in MiSTer.ini turns the app's side off.

## What the traces showed (a GUNDBG=1 build records every raw report; `tools/mister/*.py` in the GunCon repo read them)

* The picture geometry from the measured video is right to a few raw units (lit X 181..739 against a predicted 166..759: about 3% overscan each
  side, symmetric).
* Every shot is followed by one black frame (the gun reads X = 1 for 35..52 ms), then the picture again; the first lit report after it has Y = 5.
* The kernel only reports a gun when a value changes, so a gun that goes dark and stays still sends nothing for seconds; the tracker's timed
  decisions used to be taken (and the core told) only at the next report: aims frozen for a few seconds and off-screen decisions arriving late
  (patch 0016).
* Dark patches of the picture are lost to the gun, which is what the beacon is for.

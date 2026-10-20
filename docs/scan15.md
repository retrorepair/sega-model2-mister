# 15 kHz "Filled" and a light-gun beacon: a scan converter for CRTs

Work by retrorepair for GunCon 2 / CRT use of the Sega Model 2 core. Branch `guncon-scan15` of
`retrorepair/sega-model2-mister` (a working copy of `alphanu1/sega-model2-mister`, GPL-3.0).

## The problem

The core's 15 kHz mode (R682) showed the game's 384 lines one-to-one, as two interlaced fields of 192. On a 15 kHz CRT that means
borders (a field is about 262 lines with about 240 visible; 192 of them is 80% of the height) and flicker and soft text (a one-line
stroke exists in one field only). No timing change fixes either: the game runs at a fixed 57.52 Hz, and filling a field's 240 lines from
192 needs a vertical scale. Scaling in the MiSTer's scaler was tried and rejected: it retimes 57.52 Hz to its own mode, it adds delay (bad
for a light gun), and it applied the core's declared aspect.

## The converter (rtl/video/m2_scan15.sv)

The renderer stays on its native 24 kHz timing, the path that has been proven since the start. A converter sits between its finished pixels
and the video pins:

- **In:** the native 496 x 384 picture, one sample per `ce_pix`, written into a ring of twelve lines (6144 x 24 bits).
- **Out:** its own 15 kHz interlaced timing: the same 656-pixel line, hsync 520..584, 262/263-line fields, **240 visible lines a field,
  480 a frame**. Output frame row `m` samples the source at row `4m/5` (384 to 480 is exactly 4 to 5, so the weights repeat every five
  output rows and nothing is dropped, doubled or sharpened into a jaggy).
- **No frame of delay, no drift.** A native frame is 1,738,400 `clk_mem` cycles; two output fields are 3,476,800: exactly two native
  frames, both rates exact rationals off the same clock, so once the output counters are aligned to a native frame they stay aligned.
  The first visible output row comes `D_PX` = 1660 output pixels (about 168 us, four native lines) after the native frame starts, which puts
  the rows it needs 86 us inside both ring limits.
- **Pairing.** Two output fields are two native frames, an (even, odd) pair whose parity is whatever it was at start. A game that shows a
  new image every second frame (Virtua Cop: 28.8 Hz) has every output frame made of two different images if the pair straddles the change,
  so every moving thing is combed. The converter watches the renderer's `show_tag` and, if the image changed on an odd frame eight times
  running, declares that frame the even one, once. The bench checks both phases, and that a three-frame or one-frame cadence is left alone.
- **Field order** (judged on a real CRT; the core in `releases/` and on the author's card has it): in the 262/263-line mode field 0, the field whose
  vsync is aligned to the line start (263 lines, vsync on lines 247 to 249), carries the even output rows 0, 2 ... 478; field 1, whose vsync starts
  half a line early (262 lines), carries the odd rows 1, 3 ... 479; 240 visible lines in each, from line 0 of the field. Field 0 is made from the first
  (even) native frame of each pair and field 1 from the second. In the code that is `swp` = 0 (`r_c <= (field ^ swp) ? 3'd0 : 3'd4`). The same CRT
  showed the 1:1 mode's field order looking wrong by comparison; its row parity reads the same (`ypos = {vcnt, field}`), so the difference may be
  which native frame goes into which field, which the converter locks (pairing, above) and the 1:1 mode leaves to chance. Not established.
- **15 kHz is always this picture.** The 1:1 picture and the options only it had (`15kHz lines`, `15kHz width`, `15kHz picture`) are gone,
  and the renderer's own interlace path is tied off (`vid_il_c` is a constant 0). 24 kHz is unchanged.

A vertical low-pass (1/4, 1/2, 1/4 on the output rows) was built and measured: it halves the peak line-to-line jump but makes a good image
too soft, so it is not in the build; the weights are a constant sharp table (4:5 bilinear).

## The beacon

A CRT gun reads only where there is light. A dark enemy, or a dark patch of the picture, gives it nothing: the aim falls back to the last
bright spot, and an off-screen shot cannot be told from a dark one. The games' own flash does not help: Virtua Cop's, in this core, is one black
frame (51 of 52 shots saw the gun's spot go dark during it; traces in the GunCon repo), and a lit reading right after it has a junk Y of 5.
MAME's driver names the cabinet's gun interface board (837-12079, an Altera FLEX chip and a 315-5338A) and emulates only the numbers it
reports; the video passes through that board, and the best reading of the evidence is that its own flash is what lights the sensor.
The core cannot see that board, so the converter supplies the light.

While Main_MiSTer holds `joystick_3` bit 0 high the converter shows **whole white fields** (at most six, whatever the app does; never a
torn field). The app (patch 0017 of the GunCon repo) holds the gun's trigger back on a pull, asks for the flash, collects the readings and
after about 55 ms gives the core the aim and the trigger together; if the whole picture was white and the gun saw none of it, the gun is
off the screen: an exact reload, with no edge or dark-frame guessing. There is no OSD switch (the app, not the core, decides); with
`LIGHTGUN_CRT_BEACON=0` in `MiSTer.ini` the app does not ask and the flash never appears.

## Verification

`sim/video/tb_m2_scan15.sv` (Verilator 5; `sim/video/run_scan15.sh [mode] [D_PX] [frames] [filt] [swp] [cad] [ph] [bc]`) drives the
converter from the core's own `m2_video_timing` in native mode, encodes (frame, row, column) in every pixel, and checks:

- every output pixel against a blend worked out in the bench from first principles (3 to 10 million pixels, 0 mismatches);
- that the output row steps through the 4:5 sequence and the ring words read are the rows asked for, of one native frame;
- hsync 64 pixels, 496 visible, vsync intervals exactly one native frame; margins 85.6 us and 86.0 us at `D_PX` = 1660;
- pairing: with a new image every second frame, in either phase, no output frame is made of two images once locked;
- the beacon (`bc=1`): a four-field request gives exactly four white fields (476,160 pixels), none of the picture around it changes,
  and the beacon ends cleanly.

## Area, and why a build may have no HDMI

The core is at 99% of the chip with HDMI. The smoothing build failed to fit three times ("Fitter requires N LABs ... only 4,191": 4,194,
4,203, 4,197) because the fitter's own speed optimisation moves the count by about 10 for small changes, and seeds do not help (the count is
the same for every seed). `Model2.qsf` therefore sets the framework's `MISTER_DEBUG_NOHDMI` for a CRT build: no HDMI scaler (`ascal`), HDMI
OSD, shadow mask or PLL adjust; synthesis 40,562 to 36,570 ALMs (10% of the chip), 88% in the fit, all clocks pass. The cost: no HDMI
picture and no scaler screenshot; the CRT path is untouched (`vga_scaler=0`, `composite_sync=1`, `vga_mode=rgb`). Without the smoothing the
converter is smaller, and a build with HDMI is being tried.

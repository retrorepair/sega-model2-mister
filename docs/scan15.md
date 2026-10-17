# 15 kHz "Filled": a scan converter for CRTs

Work by retrorepair for GunCon 2 / CRT use of the Sega Model 2 core. Branch `guncon-scan15` of
`retrorepair/sega-model2-mister` (a private working copy of `alphanu1/sega-model2-mister`, GPL-3.0).

## The problem

The core's 15 kHz mode (R682) shows the game's 384 lines one-to-one, as two interlaced fields of 192. On a 15 kHz CRT that means:

- **Borders.** A field is about 262 lines with about 240 visible; 192 of them is 80% of the height.
- **Flicker and soft text.** A one-line stroke exists in one field only, so it blinks at 29 Hz.

No timing change fixes either. The game runs at a fixed 57.52 Hz. Filling a field's 240 lines from 192 would need a field of about
210 lines in total, which at 57.5 Hz is a 12 kHz line rate, far below what a TV locks to. Filling needs a vertical scale.

Scaling in the MiSTer's scaler was tried and rejected: it has to retime 57.52 Hz to its own mode (repeating a frame about every 24), it
adds delay (bad for a light gun, whose position must reach the game right after the game's own flash), and it applied the core's declared
aspect, giving a 320x192 picture instead of 320x240.

## The design (rtl/video/m2_scan15.sv)

The renderer stays on its native 24 kHz timing, the path that has been proven since the start. A converter sits between its finished
pixels and the video pins:

- **In:** the native 496 x 384 picture, one sample per `ce_pix`. Every line goes into a ring of eight lines (4096 x 24 bits).
- **Out:** its own 15 kHz interlaced timing: the same 656-pixel line, hsync 520..584, 262/263-line fields, **240 visible lines a field,
  480 a frame**. Output frame row `j` reads source rows `floor(4j/5)` and the next and blends them with weight `(4j mod 5)/5`
  (0, .2, .4, .6, .8). 384 to 480 is exactly 4 to 5, so the weights repeat every five output rows and nothing is dropped, doubled or
  sharpened into a jaggy. Blend = `(a(5-r) + b r + 2) * 3277 >> 14`, exact to within the rounding of 1/5.
- **Why no frame of delay and no drift.** A native frame is 656 x 424 pixels at 16/100 of `clk_mem` = 1,738,400 cycles. Two output
  fields (525 lines of 656 pixels at 861/8692 of `clk_mem`) are 3,476,800 cycles: exactly two native frames. Both enables are exact
  rational rates off the same clock, so once the output counters are aligned to a native frame start they stay aligned; the alignment is
  repeated at every second native frame and is a no-op once it holds. The output's first visible row comes `D_PX` = 850 output pixels
  (about 86 us, a bit over two native lines) after the native frame starts.
- **Where the picture sits.** The vsync is placed so the first visible row has the same centre the 1:1 mode's picture has:
  vsync 247..250 of a 263-line field (field 1: half a line early, which is what interlaces), so 13 lines after vsync end, 7 before it.

### Why only 262/263 lines (15.1 kHz)

An 8-line ring is only enough if the output does not consume source lines faster than they arrive. The output consumes 1.6 source
lines per output line. At 262/263 the output line is 66.2 us, so 240 lines last 15.89 ms against the source's 15.74 ms: the output lags,
by at most a few lines. At 273/274 (63.6 us) 240 lines last 15.26 ms, 0.5 ms *less* than the source: the output would catch up by 12
lines and need a ring of 14+ (24+ memory blocks of 20 free). The bench shows this failure plainly (`sim/video/run_scan15.sh 0`).
So "Filled" forces the 262/263 timing whatever the line-count option says.

## OSD

`15kHz picture: 1 to 1 / Filled (15.1kHz)`, status bit 64. No effect at 24 kHz. Default 1 to 1 (the existing behaviour).

## Verification

`sim/video/tb_m2_scan15.sv` (Verilator 5; `sim/video/run_scan15.sh [mode] [D_PX] [frames]`) drives the converter from the core's own
`m2_video_timing` in native mode, encodes (frame, row, column) in every pixel, and checks:

- every output pixel against the exact blend of the two source rows it must have used (6.8 million pixels over 60 native frames: 0
  mismatches);
- that the ring held the rows asked for, of one native frame (0 mismatches);
- hsync 64 pixels, 496 visible, vsync intervals exactly one native frame;
- the margins, in nanoseconds, before a word is read too early and before it is overwritten too early: **44.8 us and 44.8 us** at
  `D_PX` = 850, each more than a native line.

## Area

The core is at 99% of the chip. The converter is about 125 logic ALUTs, 6 DSP blocks and 12 memory blocks (one 4096 x 24 RAM). The first
build was 6 LABs over (4,197 needed, 4,191 available); trimming the staging registers (the converter now writes straight into the ring and
reads the second row straight off the RAM output) let the fit through placement preparation. Whether a seed closes timing is the usual
lottery for this design (see the README, "Building").

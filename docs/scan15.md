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

- **In:** the native 496 x 384 picture, one sample per `ce_pix`. Every line goes into a ring of twelve lines (6144 x 24 bits).
- **Out:** its own 15 kHz interlaced timing: the same 656-pixel line, hsync 520..584, 262/263-line fields, **240 visible lines a field,
  480 a frame**. Output frame row `m` samples the source at row `4m/5`: 384 to 480 is exactly 4 to 5, so the sampling positions repeat
  every five output rows and nothing is dropped, doubled or sharpened into a jaggy. The sample is a linear blend of the two rows either
  side, with weight `(4m mod 5)/5`.
- **Why no frame of delay and no drift.** A native frame is 656 x 424 pixels at 16/100 of `clk_mem` = 1,738,400 cycles. Two output
  fields (525 lines of 656 pixels at 861/8692 of `clk_mem`) are 3,476,800 cycles: exactly two native frames. Both enables are exact
  rational rates off the same clock, so once the output counters are aligned to a native frame start they stay aligned; the alignment is
  repeated at every second native frame and is a no-op once it holds. The output's first visible row comes `D_PX` = 1660 output pixels
  (about 168 us, four native lines) after the native frame starts.
- **Where the picture sits.** The vsync is placed so the first visible row has the same centre the 1:1 mode's picture has:
  vsync 247..250 of a 263-line field (field 1: half a line early, which is what interlaces), so 13 lines after vsync end, 7 before it.

### The vertical smoothing (OSD: Vertical smoothing, default On)

The plain 4:5 blend is sharp: a one-row line in the game lands on one output row at a weight of 0.8 to 1.0, and that row belongs to
one field. Half the time the other field gets 40% of its light: a 29 Hz flicker. So the output row is not B(m), the blend, but the
vertical low-pass the consoles used on 480i:

    out(m) = B(m-1)/4 + B(m)/2 + B(m+1)/4

B(m-1) and B(m+1) lie 0.8 source rows either side of B(m), so this reads four source rows, s-1 to s+2, with weights worked out in
exact twentieths (`4 12 4 0 | 3 10 7 0 | 2 9 8 1 | 1 8 9 2 | 0 7 10 3` for the five phases). A one-row line now puts the same energy in
both fields for every position (min/max field energy 1.00; the plain blend: 0.40 at worst), and motion between the two fields of a
frame is combed half as hard. The price is a little vertical softness. Off is the plain blend.

### Pairing the two fields of a frame (automatic)

Two output fields are two native frames, an (even, odd) pair whose parity is whatever it was when the core started. A game that shows
a new image every second frame (Virtua Cop: 28.8 Hz) has every output frame made of two different images if the pair straddles the
change, and every moving object is combed, every frame. So the converter watches the renderer's `show_tag` (the image on show, it
changes in the vertical blank before the first frame of a new image) and, if it changed on an odd frame eight times running, declares
that frame the even one, once. A cadence that varies by a frame now and then never gets eight in a row and is left alone. The bench
checks this for both phases of a two-frame cadence (no output frame made of two images once locked), and that a three-frame or
one-frame cadence is left alone.

### Field order (OSD: Field order, default Normal)

Normal puts the even rows on the field whose vsync is aligned to a line. Swapped puts the odd rows there. Which one a given TV wants
depends on where it puts a field relative to the sync; if the picture looks vertically doubled or the line pairs look swapped, try it.

### Why only 262/263 lines (15.1 kHz)

A ring is only enough if the output does not consume source lines faster than they arrive. The output consumes 1.6 source lines per
output line. At 262/263 the output line is 66.2 us, so 240 lines last 15.89 ms against the source's 15.74 ms: the output lags, by
about 3.7 source rows over the field. At 273/274 (63.6 us) 240 lines last 15.26 ms, 0.5 ms *less* than the source: the output would
catch up by 12 lines. So "Filled" forces the 262/263 timing whatever the line-count option says.

### Why twelve lines

With the four-row filter the rows needed span s-1..s+2 while the source's write front sits 2 to 6 rows ahead of s over the field (the
3.7-row drift above). An 8-line ring has just 4 rows of room for that, leaving a margin of only 2 to 4 us each way. Twelve lines
(6144 x 24, fifteen M10K blocks against twelve for 4096 x 24; the chip has 553 and the last fit used 545) leave 86 us each way, two
native lines.

## OSD

15 kHz is now always the Filled picture. The 1:1 picture and the options that only it had (`15kHz lines`, `15kHz width`, `15kHz picture`) are
gone, and the renderer's own interlace path is tied off (`vid_il_c` is a constant 0), so the synthesis removes it. That was done to make
room: the smoothing build needed 4,203 logic blocks of 4,191 and the first and second fits failed on it. Synthesis says the retirement frees
76 ALMs (40,638 to 40,562) and 25 registers, which is less than hoped.

- `Vertical smoothing: On / Off`, bit 65. 15 kHz only.
- `Field order: Normal / Swapped`, bit 66. 15 kHz only.
- `Video: Native 24kHz / 15kHz interlaced` (bit 42, or the CRT MRA's flag) picks the output as before.

## Verification

`sim/video/tb_m2_scan15.sv` (Verilator 5; `sim/video/run_scan15.sh [mode] [D_PX] [frames] [filt] [swp] [cad] [ph]`) drives the
converter from the core's own `m2_video_timing` in native mode, encodes (frame, row, column) in every pixel, and checks:

- every output pixel against a blend worked out in the bench from first principles (the three bilinear samples at 4(m-1)/5, 4m/5,
  4(m+1)/5 with rows clamped to the picture, not from the converter's own tables): 10.4 million pixels over 90 native frames, 0
  mismatches, with the filter on and off;
- that the output row on show steps through source row `4m/5`, fraction `4m mod 5`, and that the four ring words read are the four rows
  asked for, of one native frame (0 mismatches);
- hsync 64 pixels, 496 visible, vsync intervals exactly one native frame;
- the margins, in nanoseconds, before a word is read too early and before it is overwritten too early: **85.6 us and 86.0 us** at
  `D_PX` = 1660;
- pairing: with a new image every second frame, in either phase, and with the field order swapped, no output frame is made of two
  images once the converter has locked (about 18 native frames); with a three-frame cadence the lock never fires, and with a new image
  every frame no pairing is possible.

## Area, and why this build has no HDMI

The core is at 99% of the chip. The converter is about 174 ALUTs, 140 registers, 6 DSP blocks and 15 memory blocks (the first version, with
the plain blend and eight lines, was 134 ALUTs and 201 registers). The smoothing build failed to fit three times, each "Fitter requires N
LABs ... device contains only 4,191": 4,194, then 4,203 after trimming the converter (the fitter's own speed optimisation moves the count by
about 10 for small changes), then 4,197 after retiring the 1:1 picture (76 ALMs). Seeds do not help: the count is the same for every seed.

So `Model2.qsf` now sets the framework's `MISTER_DEBUG_NOHDMI`: no HDMI scaler (`ascal`), HDMI OSD, shadow mask or PLL adjust, and the analog
output comes straight from the core. Synthesis: 40,562 to 36,570 ALMs (about 4,000, 10% of the chip), registers 49,415 to 42,347, DSP blocks
94 to 81. The cost is that there is no HDMI picture and no scaler screenshot; the CRT path is untouched (`vga_scaler=0`, `composite_sync=1`,
`vga_mode=rgb` in the card's MiSTer.ini). The framework labels the switch "do not enable in release"; this is a CRT build.

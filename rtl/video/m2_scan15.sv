// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- 15 kHz "filled" output: a scan converter.
// Copyright (C) 2026 alphanu1; this module by retrorepair (GunCon 2 / CRT work).
//
// WHAT IT IS FOR
//
// The 15 kHz interlaced mode (R682) shows the game's 384 lines one-to-one: two
// fields of 192 lines in a 262-line field, so about 20% of a TV's height is
// black, and every one-line detail lives in one field only and flickers at
// 29 Hz. No timing change can fix either: a field has ~240 visible lines at the
// game's fixed 57.5 Hz, and filling them from 192 needs a vertical scale.
//
// WHAT IT DOES
//
// The whole renderer stays on its native 24 kHz timing (the path that has been
// proven from the start). This module sits between its finished pixels and the
// video pins:
//
//   in : the native 496 x 384 picture, one sample per `ce_in`, with its own DE
//        and vertical blank; every line is written into a ring of twelve lines.
//   out : a separate 15 kHz interlaced timing (the same 656-pixel line, the same
//        three line counts as the 1:1 mode), 240 visible lines per field, 480 a
//        frame: output row m samples the source at row 4m/5 (a blend of rows
//        floor(4m/5) and the next, weight (4m mod 5)/5), then, with `filt`, is
//        low-passed vertically with its two neighbours in the output (1/4, 1/2,
//        1/4), so a one-row line has the same light in both fields and does not
//        flicker at 29 Hz. 384 -> 480 is exactly 4 -> 5, so the weights repeat
//        every five output rows and no line is dropped, duplicated, or
//        sharpened into a jaggy.
//
// WHY THERE IS NO FRAME OF DELAY, AND NO DRIFT
//
// A native frame is 656 x 424 pixels at 16/100 of clk = 1,738,400 clk cycles.
// The two output fields are 547 (or 537, or 525) lines of 656 pixels at
// 547/5300 (537/5300, 861/8692) of clk: 3,476,800 cycles, exactly two native
// frames, in every mode. The two enables are exact rational rates off the same
// clock, so once the output counters are aligned to a native frame start they
// stay aligned for ever; the alignment is simply repeated every second frame
// (a no-op once it holds). The output runs D_PX output pixels after the native
// frame starts: about 170 us, four native lines, which puts the lines it needs
// (s-1 to s+2) 86 us inside both limits: written before they are read, and not
// yet overwritten by the write front in the 12-line ring (see the bench).
//
// GEOMETRY (taken from m2_video_timing so the picture sits where the 1:1 mode
// puts it): 656-pixel line, 496 visible, hsync 520..584 (64 pixels); fields of
// N0 and N0-1 lines; field 1's vsync starts half a line early, which is what
// interlaces. The vsync is placed so the first visible line has the same
// number of lines after vsync end as the 1:1 mode's picture CENTRE does:
// 240 visible lines start 24 lines earlier than 192 would.

`timescale 1ns/1ps

module m2_scan15 #(
  parameter int unsigned W    = 496,   // visible pixels per line
  parameter int unsigned HT   = 656,   // line length in output pixels
  parameter int unsigned HSS  = 520,   // hsync start
  parameter int unsigned HSE  = 584,   // hsync end (exclusive)
  parameter int unsigned VIS  = 240,   // visible lines per output field
  parameter int unsigned SRCH = 384,   // source lines
  parameter int unsigned D_PX = 1660   // output pixels from the native frame start to the first visible output line
) (
  input  logic        clk,             // the video clock (clk_mem)
  input  logic        rst_n,
  input  logic        en,              // converter selected
  input  logic        filt,            // vertical low-pass (flicker filter) on; off = the plain 4:5 blend
  input  logic        swp,             // field order swapped: the field with the aligned vsync shows the odd rows
  input  logic  [3:0] img_tag,         // names the image on show (the renderer's show_tag); asynchronous, changes in vertical blank

  // the native picture, sampled on ce_in
  input  logic        ce_in,
  input  logic        de_in,           // picture sample is inside the 496 x 384 window
  input  logic        vb_in,           // the native vertical blank
  input  logic [23:0] rgb_in,

  // the 15 kHz output
  input  logic        ce_out,
  input  logic        nl,              // 262/263 lines a field
  input  logic        ml,              // 268/269 (else 273/274)
  output logic        o_hs,
  output logic        o_vs,
  output logic        o_de,
  output logic        o_field,
  output logic [23:0] o_rgb,

  // for the bench
  output logic        dbg_align
);

  // ------------------------------------------------------------ the ring
  // Twelve lines of 512 words: a source row r lives in slot r mod 12 (384 is a multiple of 12, so the slots run on across
  // frames). Eight lines would be exactly enough for the four-row filter but leave only a few microseconds of margin
  // (see the bench); twelve cost three more memory blocks (6144 x 24 is 15, 4096 x 24 is 12) and leave a margin of tens.
  logic [23:0] ram [0:6143];
  logic        we_w;
  logic [12:0] wa_w;
  logic [23:0] wd_w;
  always_ff @(posedge clk) if (we_w) ram[wa_w] <= wd_w;

  logic [12:0] ra;
  logic [23:0] rd;
  always_ff @(posedge clk) rd <= ram[ra];

  // ------------------------------------------------------------ source side
  logic        vb_d, de_d;
  logic [8:0]  wx;
  logic [3:0]  wslot;                  // ring slot of the line being written
  logic        par;
  logic        fs_even;                // a native frame has just started, and it is the first of the two a frame of output spans

  // PAIRING. Two output fields are two native frames, and the pair is (even, odd) by a parity that is whatever it was when the
  // core started. A game that shows a new image every second frame has every output frame made of two DIFFERENT images if the
  // pair straddles the change, and each moving thing is then combed, every frame. So watch the image change: if for eight changes
  // running each fell on an odd frame, the pairing is wrong and the frame is declared the even one (once; a cadence that changes
  // by a frame now and then never gets eight in a row, and the pairing is left alone).
  // The tag is asynchronous but changes in the vertical blank, 1.6 ms before the frame start it is compared at, so one register
  // is a synchroniser enough.
  logic [3:0]  tg_s, tg_p;             // the tag, and its value at the last frame start
  logic [2:0]  bad;                    // changes in a row that fell on an odd frame
  always_ff @(posedge clk) tg_s <= img_tag;

  wire         fs_now  = vb_d && !vb_in;                   // the vertical blank ended on this sample
  wire         rise    = de_in && !de_d;                   // first pixel of a line
  wire [3:0]   ws_base = fs_now ? 4'd11 : wslot;
  wire [3:0]   ws_n    = rise ? ((ws_base == 4'd11) ? 4'd0 : ws_base + 4'd1) : ws_base;
  wire [8:0]   wx_n    = rise ? 9'd0 : wx;
  assign we_w = ce_in && de_in;
  assign wa_w = {ws_n, wx_n};
  assign wd_w = rgb_in;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vb_d <= 1'b1; de_d <= 1'b0; wx <= '0; wslot <= '0; par <= 1'b0; fs_even <= 1'b0; tg_p <= '0; bad <= '0;
    end else begin
      fs_even <= 1'b0;
      if (ce_in) begin
        vb_d <= vb_in;
        de_d <= de_in;
        wslot <= ws_n;
        if (fs_now) begin
          tg_p <= tg_s;
          if (tg_s != tg_p) begin
            if (par) bad <= 3'd0;      // the image changed on an even frame, as it should
            else     bad <= bad + 3'd1;
          end
          if (tg_s != tg_p && !par && bad == 3'd7) begin
            par     <= 1'b0;           // this odd frame is the even one from now on; the next is odd
            fs_even <= 1'b1;
            bad     <= 3'd0;
          end else begin
            par     <= ~par;
            fs_even <= par;            // par was 1: this frame is the even one
          end
        end
        wx <= de_in ? wx_n + 9'd1 : 9'd0;
      end
    end
  end

  // ------------------------------------------------------------ output timing
  logic [9:0] hcnt, vcnt;
  logic       field;

  wire [9:0] n0  = nl ? 10'd263 : ml ? 10'd269 : 10'd274;
  wire [9:0] vt  = field ? n0 - 10'd1 : n0;
  wire [9:0] vss = nl ? 10'd247 : ml ? 10'd250 : 10'd253;   // field 0's vsync start (3 lines)
  wire [9:0] vse = vss + 10'd3;

  localparam int unsigned DL = (D_PX + HT - 1) / HT;   // lines from the counters' value at the align to the end of field 1

  wire       hs_c  = (hcnt >= 10'(HSS)) && (hcnt < 10'(HSE));
  wire [19:0] vpos = {vcnt, hcnt};
  wire       vs_i0 = (vcnt >= vss) && (vcnt < vse);
  wire       vs_i1 = (vpos >= {vss - 10'd1, 10'(HT >> 1)}) && (vpos < {vse - 10'd1, 10'(HT >> 1)});
  wire       vs_c  = field ? vs_i1 : vs_i0;
  wire       de_c  = (hcnt < 10'(W)) && (vcnt < 10'(VIS));

  // The source row of the line on show is s = floor(4m/5), fraction r/5 with r = 4m mod 5, for the frame row
  // m = 2 * vcnt + the field's parity. Four rows are read, s-1 to s+2, clamped to the picture; they sit in ring slots
  // (row mod 12) that follow each other, so only the slot of the first, p, is tracked: p is the slot of row max(s-1, 0).
  // One line on, s moves by 1 + c (c = the carry of r + 3 mod 5), so p moves by c, and by one more unless s was 0 (then p
  // stands for row 0, not row -1). The clamps need no row number: s = 0 is the first line of a field, s >= 382 its last
  // (m >= 478), and s = 383 the last line of the field that carries the odd rows.
  logic [3:0] p;
  logic [2:0] r_c;
  wire        top   = (vcnt == 10'd0);                   // s = 0
  wire        last  = (vcnt == 10'(VIS - 1));            // s >= 382
  wire        lastb = last && (field ^ swp);             // s = 383
  wire  [3:0] r3    = {1'b0, r_c} + 4'd3;
  wire        rc    = (r3 >= 4'd5);
  wire  [2:0] r_n   = rc ? 3'(r3 - 4'd5) : 3'(r3);
  wire  [4:0] p_a   = {1'b0, p} + {4'd0, top ? 1'b0 : 1'b1} + {4'd0, rc};
  wire  [3:0] p_n   = (p_a >= 5'd12) ? 4'(p_a - 5'd12) : 4'(p_a);

  wire        align = fs_even && en;
  assign dbg_align = align;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hcnt <= '0; vcnt <= '0; field <= 1'b0; p <= '0; r_c <= '0;
    end else if (align) begin
      // the counters the free-running output would hold at this instant, once locked
      field <= 1'b1;
      vcnt  <= (n0 - 10'd1) - 10'(DL);
      hcnt  <= 10'(DL * HT - D_PX);
    end else if (ce_out) begin
      if (hcnt == 10'(HT - 1)) begin
        hcnt <= '0;
        if (vcnt == vt - 10'd1) begin
          vcnt  <= '0;
          field <= ~field;
          p     <= '0;
          r_c   <= (field ^ swp) ? 3'd0 : 3'd4;   // the field about to start: the odd rows' field starts on frame row 1 (4j = 4)
        end else begin
          vcnt <= vcnt + 10'd1;
          if (vcnt < 10'(VIS) - 10'd1) begin
            p   <= p_n;
            r_c <= r_n;
          end
        end
      end else begin
        hcnt <= hcnt + 10'd1;
      end
    end
  end

  // ------------------------------------------------------------ read, filter, output
  // After each output pixel enable the next pixel's four source words are read from the single ring RAM on consecutive
  // cycles (the enable is 10 to 11 cycles apart at 262/263), multiplied by the line's four weights and summed as they arrive,
  // scaled by 1/20 and held for the next enable. The four rows are s-1, s, s+1, s+2 (clamped to the picture).
  //
  // THE WEIGHTS, in twentieths. The 4:5 scale itself is a bilinear sample B(m) of the source at 4m/5 (rows s and s+1, weights
  // (5-r, r)/5, r = 4m mod 5). On an interlaced display that alone flickers: a one-row line sits on one output row, and so in
  // one field only, 29 times a second. With `filt` the output row is the vertical low-pass the consoles used on 480i,
  // out(m) = B(m-1)/4 + B(m)/2 + B(m+1)/4, so a line always has energy in both fields. B(m-1) and B(m+1) lie 0.8 source rows
  // either side, hence the four rows. The weights for r = 0..4 below are that sum worked out in exact fractions:
  //   smooth  4 12  4  0 | 3 10  7  0 | 2  9  8  1 | 1  8  9  2 | 0  7 10  3
  //   sharp   0 20  0  0 | 0 16  4  0 | 0 12  8  0 | 0  8 12  0 | 0  4 16  0   (B(m) alone)
  logic [3:0]  ph;
  logic [12:0] acc_r, acc_g, acc_b;       // at most 20 * 255 + 10
  logic [3:0]  q;                         // the ring slot being read

  // the slots of the four rows, one a cycle: p, then the next slot unless the row is clamped (top: row -1 is row 0, so the
  // second read repeats the first; bottom: rows past the last repeat it)
  function automatic logic [3:0] up1(input logic [3:0] a);
    return (a == 4'd11) ? 4'd0 : a + 4'd1;
  endfunction
  wire        hold = ((ph == 4'd2) && top) || ((ph == 4'd3) && lastb) || ((ph == 4'd4) && last);
  wire  [3:0] q_n  = (ph == 4'd1) ? p : hold ? q : up1(q);

  // the weight of the word that is on rd: tap 0 to 3 in ph 3 to 6 (tap = ph - 3, i.e. ph[1:0] + 1)
  logic [4:0] wcur;
  always_comb begin
    case ({filt, r_c, 2'(ph[1:0] + 2'd1)})
      {1'b1, 3'd0, 2'd0}: wcur = 5'd4;   {1'b1, 3'd0, 2'd1}: wcur = 5'd12;  {1'b1, 3'd0, 2'd2}: wcur = 5'd4;   {1'b1, 3'd0, 2'd3}: wcur = 5'd0;
      {1'b1, 3'd1, 2'd0}: wcur = 5'd3;   {1'b1, 3'd1, 2'd1}: wcur = 5'd10;  {1'b1, 3'd1, 2'd2}: wcur = 5'd7;   {1'b1, 3'd1, 2'd3}: wcur = 5'd0;
      {1'b1, 3'd2, 2'd0}: wcur = 5'd2;   {1'b1, 3'd2, 2'd1}: wcur = 5'd9;   {1'b1, 3'd2, 2'd2}: wcur = 5'd8;   {1'b1, 3'd2, 2'd3}: wcur = 5'd1;
      {1'b1, 3'd3, 2'd0}: wcur = 5'd1;   {1'b1, 3'd3, 2'd1}: wcur = 5'd8;   {1'b1, 3'd3, 2'd2}: wcur = 5'd9;   {1'b1, 3'd3, 2'd3}: wcur = 5'd2;
      {1'b1, 3'd4, 2'd0}: wcur = 5'd0;   {1'b1, 3'd4, 2'd1}: wcur = 5'd7;   {1'b1, 3'd4, 2'd2}: wcur = 5'd10;  {1'b1, 3'd4, 2'd3}: wcur = 5'd3;
      {1'b0, 3'd0, 2'd1}: wcur = 5'd20;  {1'b0, 3'd1, 2'd1}: wcur = 5'd16;  {1'b0, 3'd1, 2'd2}: wcur = 5'd4;
      {1'b0, 3'd2, 2'd1}: wcur = 5'd12;  {1'b0, 3'd2, 2'd2}: wcur = 5'd8;
      {1'b0, 3'd3, 2'd1}: wcur = 5'd8;   {1'b0, 3'd3, 2'd2}: wcur = 5'd12;
      {1'b0, 3'd4, 2'd1}: wcur = 5'd4;   {1'b0, 3'd4, 2'd2}: wcur = 5'd16;
      default:            wcur = 5'd0;
    endcase
  end

  // x 3277 / 65536 = x / 20 (exact for every multiple of 20 up to 20 * 255); the multiplier is combinational off acc, which
  // holds from ph 7 on, and the output register takes it at the next enable
  (* multstyle = "dsp" *) wire [24:0] mul_r = acc_r * 12'd3277;
  (* multstyle = "dsp" *) wire [24:0] mul_g = acc_g * 12'd3277;
  (* multstyle = "dsp" *) wire [24:0] mul_b = acc_b * 12'd3277;
  wire [23:0] blend = {mul_r[23:16], mul_g[23:16], mul_b[23:16]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ph <= 4'd0;
    else if (ce_out) ph <= 4'd1;
    else if (ph != 4'd0 && ph != 4'd15) ph <= ph + 4'd1;
  end

  // the datapath has no reset: it holds nothing that matters until the first line is read
  always_ff @(posedge clk) begin
    // the ring address for the next cycle: the four rows in the cycles after ph 1, 2, 3, 4
    q  <= q_n;
    ra <= {q_n, hcnt[8:0]};

    // the four words arrive on rd in ph 3 to 6: weight each and sum (the 10 is the rounding of the 1/20)
    if (ph >= 4'd3 && ph <= 4'd6) begin
      acc_r <= ((ph == 4'd3) ? 13'd10 : acc_r) + rd[23:16] * wcur;
      acc_g <= ((ph == 4'd3) ? 13'd10 : acc_g) + rd[15:8]  * wcur;
      acc_b <= ((ph == 4'd3) ? 13'd10 : acc_b) + rd[7:0]   * wcur;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_hs <= 1'b0; o_vs <= 1'b0; o_de <= 1'b0; o_field <= 1'b0; o_rgb <= '0;
    end else if (ce_out) begin
      o_hs    <= en && hs_c;
      o_vs    <= en && vs_c;
      o_de    <= en && de_c;
      o_field <= field;
      o_rgb   <= (en && de_c) ? blend : 24'd0;
    end
  end

endmodule

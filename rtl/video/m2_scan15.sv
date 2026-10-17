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
  logic [3:0]  tg1, tg2, tg_s, tg_p;   // tag synchroniser, the stable value, the value at the last frame start
  logic [2:0]  bad;                    // changes in a row that fell on an odd frame
  always_ff @(posedge clk) begin
    tg1 <= img_tag; tg2 <= tg1;
    if (tg1 == tg2) tg_s <= tg2;
  end

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

  // the source rows of the line on show: s and s + 1, weight r / 5 on the second
  logic [8:0] s_c;
  logic [3:0] sm_c;                    // s_c mod 12: the ring slot of row s
  logic [2:0] r_c;
  wire  [3:0] r3  = {1'b0, r_c} + 4'd3;
  wire        rc  = (r3 >= 4'd5);
  wire  [2:0] r_n = rc ? 3'(r3 - 4'd5) : 3'(r3);
  wire  [8:0] s_n = s_c + 9'd1 + {8'd0, rc};
  wire  [4:0] sm_a = {1'b0, sm_c} + 5'd1 + {4'd0, rc};
  wire  [3:0] sm_n = (sm_a >= 5'd12) ? 4'(sm_a - 5'd12) : 4'(sm_a);

  wire        align = fs_even && en;
  assign dbg_align = align;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hcnt <= '0; vcnt <= '0; field <= 1'b0; s_c <= '0; sm_c <= '0; r_c <= '0;
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
          s_c   <= '0;
          sm_c  <= '0;
          r_c   <= (field ^ swp) ? 3'd0 : 3'd4;   // the field about to start: the odd rows' field starts on frame row 1 (4j = 4)
        end else begin
          vcnt <= vcnt + 10'd1;
          if (vcnt < 10'(VIS) - 10'd1) begin
            s_c  <= s_n;
            sm_c <= sm_n;
            r_c  <= r_n;
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
  (* multstyle = "dsp" *) logic [12:0] pq_r, pq_g, pq_b;   // this cycle's tap x weight, registered
  logic [12:0] acc_r, acc_g, acc_b;       // at most 20 * 255 + 10
  logic [23:0] blend;

  // the ring slots (row mod 12) of rows s-1, s, s+1, s+2, the outer ones clamped to the picture's first and last rows
  function automatic logic [3:0] up1(input logic [3:0] a);
    return (a == 4'd11) ? 4'd0 : a + 4'd1;
  endfunction
  function automatic logic [3:0] up2(input logic [3:0] a);
    return (a >= 4'd10) ? a - 4'd10 : a + 4'd2;
  endfunction
  wire [3:0] k0 = (s_c == 9'd0) ? 4'd0 : (sm_c == 4'd0) ? 4'd11 : sm_c - 4'd1;
  wire [3:0] k2 = (s_c >= 9'(SRCH - 1)) ? sm_c : up1(sm_c);
  wire [3:0] k3 = (s_c >= 9'(SRCH - 1)) ? sm_c : (s_c == 9'(SRCH - 2)) ? up1(sm_c) : up2(sm_c);
  wire [3:0] ksel = (ph == 4'd1) ? k0 : (ph == 4'd3) ? k2 : (ph == 4'd4) ? k3 : sm_c;   // the slot to ask for after this cycle

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

  // x 3277 / 65536 = x / 20 (exact for every multiple of 20 up to 20 * 255)
  (* multstyle = "dsp" *) wire [24:0] mul_r = acc_r * 12'd3277;
  (* multstyle = "dsp" *) wire [24:0] mul_g = acc_g * 12'd3277;
  (* multstyle = "dsp" *) wire [24:0] mul_b = acc_b * 12'd3277;

  wire [12:0] a_in_r = (ph == 4'd4) ? 13'd10 : acc_r;    // + 10: the rounding of the 1/20
  wire [12:0] a_in_g = (ph == 4'd4) ? 13'd10 : acc_g;
  wire [12:0] a_in_b = (ph == 4'd4) ? 13'd10 : acc_b;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph <= 4'd0; ra <= '0;
      pq_r <= '0; pq_g <= '0; pq_b <= '0; acc_r <= '0; acc_g <= '0; acc_b <= '0; blend <= '0;
    end else begin
      if (ce_out) ph <= 4'd1;
      else if (ph != 4'd0 && ph != 4'd15) ph <= ph + 4'd1;

      // the ring address for the next cycle: rows s-1, s, s+1, s+2 in the cycles after ph 1, 2, 3, 4
      ra <= {ksel, hcnt[8:0]};

      // the product of the word on rd and its weight, every cycle (only ph 3 to 6 are the four taps)
      pq_r <= rd[23:16] * wcur;
      pq_g <= rd[15:8]  * wcur;
      pq_b <= rd[7:0]   * wcur;

      // and the sum of the four products, one cycle behind
      if (ph >= 4'd4 && ph <= 4'd7) begin
        acc_r <= a_in_r + pq_r;
        acc_g <= a_in_g + pq_g;
        acc_b <= a_in_b + pq_b;
      end
      if (ph == 4'd8) blend <= {mul_r[23:16], mul_g[23:16], mul_b[23:16]};
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

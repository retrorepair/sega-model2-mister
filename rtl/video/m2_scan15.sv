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
//        and vertical blank; every line is written into a ring of eight lines.
//   out : a separate 15 kHz interlaced timing (the same 656-pixel line, the same
//        three line counts as the 1:1 mode), 240 visible lines per field, 480 a
//        frame: output line j reads source rows floor(4j/5) and the next, and
//        blends them by (4j mod 5)/5. 384 -> 480 is exactly 4 -> 5, so the
//        weights repeat every five output lines and no line is dropped,
//        duplicated, or sharpened into a jaggy.
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
// frame starts: about 80 us, a bit more than one native line, which is just
// enough for the lines it needs to have been written and just short of
// overwriting the ones it still needs in an 8-line ring (see the bench for the
// margins both ways).
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
  parameter int unsigned D_PX = 850    // output pixels from the native frame start to the first visible output line
) (
  input  logic        clk,             // the video clock (clk_mem)
  input  logic        rst_n,
  input  logic        en,              // converter selected

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
  logic [23:0] ram [0:4095];           // eight lines of 512 words
  logic        we_w;
  logic [11:0] wa_w;
  logic [23:0] wd_w;
  always_ff @(posedge clk) if (we_w) ram[wa_w] <= wd_w;

  logic [11:0] ra;
  logic [23:0] rd;
  always_ff @(posedge clk) rd <= ram[ra];

  // ------------------------------------------------------------ source side
  logic        vb_d, de_d;
  logic [8:0]  wx, wy;
  logic        par;
  logic        fs_even;                // a native frame has just started, and it is the first of the two a frame of output spans

  wire         fs_now  = vb_d && !vb_in;                   // the vertical blank ended on this sample
  wire         rise    = de_in && !de_d;                   // first pixel of a line
  wire [8:0]   wy_base = fs_now ? 9'h1FF : wy;
  wire [8:0]   wy_n    = rise ? wy_base + 9'd1 : wy_base;
  wire [8:0]   wx_n    = rise ? 9'd0 : wx;
  assign we_w = ce_in && de_in;
  assign wa_w = {wy_n[2:0], wx_n};
  assign wd_w = rgb_in;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vb_d <= 1'b1; de_d <= 1'b0; wx <= '0; wy <= '0; par <= 1'b0; fs_even <= 1'b0;
    end else begin
      fs_even <= 1'b0;
      if (ce_in) begin
        vb_d <= vb_in;
        de_d <= de_in;
        wy   <= wy_n;
        if (fs_now) begin
          par     <= ~par;
          fs_even <= par;              // par was 1: this frame is the even one
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

  wire       hs_c  = (hcnt >= 10'(HSS)) && (hcnt < 10'(HSE));
  wire [19:0] vpos = {vcnt, hcnt};
  wire       vs_i0 = (vcnt >= vss) && (vcnt < vse);
  wire       vs_i1 = (vpos >= {vss - 10'd1, 10'(HT >> 1)}) && (vpos < {vse - 10'd1, 10'(HT >> 1)});
  wire       vs_c  = field ? vs_i1 : vs_i0;
  wire       de_c  = (hcnt < 10'(W)) && (vcnt < 10'(VIS));

  // the source rows of the line on show: s and s + 1, weight r / 5 on the second
  logic [8:0] s_c;
  logic [2:0] r_c;
  wire  [3:0] r3  = {1'b0, r_c} + 4'd3;
  wire        rc  = (r3 >= 4'd5);
  wire  [2:0] r_n = rc ? 3'(r3 - 4'd5) : 3'(r3);
  wire  [8:0] s_n = s_c + 9'd1 + {8'd0, rc};

  wire        align = fs_even && en;
  assign dbg_align = align;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hcnt <= '0; vcnt <= '0; field <= 1'b0; s_c <= '0; r_c <= '0;
    end else if (align) begin
      // the counters the free-running output would hold at this instant, once locked
      field <= 1'b1;
      vcnt  <= (n0 - 10'd1) - 10'd2;
      hcnt  <= 10'(2 * HT - D_PX);
    end else if (ce_out) begin
      if (hcnt == 10'(HT - 1)) begin
        hcnt <= '0;
        if (vcnt == vt - 10'd1) begin
          vcnt  <= '0;
          field <= ~field;
          s_c   <= '0;
          r_c   <= field ? 3'd0 : 3'd4;     // the field about to start: field 1 starts on frame row 1 (4j = 4)
        end else begin
          vcnt <= vcnt + 10'd1;
          if (vcnt < 10'(VIS) - 10'd1) begin
            s_c <= s_n;
            r_c <= r_n;
          end
        end
      end else begin
        hcnt <= hcnt + 10'd1;
      end
    end
  end

  // ------------------------------------------------------------ read, blend, output
  // After each output pixel enable the next pixel's two source words are read from the single ring RAM on consecutive
  // cycles (the enable is 9 to 10 cycles apart), blended in four registered stages, and held for the next enable.
  logic [3:0]  ph;
  logic [23:0] a_q;
  logic [2:0]  r_q;
  logic [10:0] sum_r, sum_g, sum_b;
  logic [24:0] mul_r, mul_g, mul_b;
  logic [23:0] blend;

  wire [8:0] sb = (s_c >= 9'(SRCH - 1)) ? s_c : s_c + 9'd1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph <= 4'd0; ra <= '0; a_q <= '0; r_q <= '0;
      sum_r <= '0; sum_g <= '0; sum_b <= '0; mul_r <= '0; mul_g <= '0; mul_b <= '0; blend <= '0;
    end else begin
      if (ce_out) ph <= 4'd1;
      else if (ph != 4'd0 && ph != 4'd15) ph <= ph + 4'd1;

      case (ph)
        4'd1: begin ra <= {s_c[2:0], hcnt[8:0]}; r_q <= r_c; end
        4'd2: ra <= {sb[2:0], hcnt[8:0]};
        4'd3: a_q <= rd;                    // row s
        4'd4: begin                         // rd is row s + 1 now
          sum_r <= a_q[23:16] * (4'd5 - {1'b0, r_q}) + rd[23:16] * r_q + 11'd2;
          sum_g <= a_q[15:8]  * (4'd5 - {1'b0, r_q}) + rd[15:8]  * r_q + 11'd2;
          sum_b <= a_q[7:0]   * (4'd5 - {1'b0, r_q}) + rd[7:0]   * r_q + 11'd2;
        end
        4'd5: begin
          mul_r <= sum_r * 14'd3277;      // x 3277 / 16384 = x / 5 to within 1.5e-2 over the whole range
          mul_g <= sum_g * 14'd3277;
          mul_b <= sum_b * 14'd3277;
        end
        4'd6: blend <= {mul_r[21:14], mul_g[21:14], mul_b[21:14]};
        default: ;
      endcase
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

// SPDX-License-Identifier: GPL-3.0-or-later
// Bench for m2_scan15: the native timing module is the source, every pixel encodes (frame, line, column), and every output
// pixel is checked against the exact 4:5 blend of the source rows the converter must have used.
//
// Build and run from the repo root (WSL):
//   $ verilator --binary --timing -Wno-fatal --top-module tb_m2_scan15 sim/video/tb_m2_scan15.sv rtl/video/m2_scan15.sv rtl/video/m2_video_timing.sv -o tb
//   $ obj_dir/tb +mode=0
// Plusargs: mode=0 273/274 lines, 1 = 268/269, 2 = 262/263; frames=N native frames (default 14).
//
// Checks: output timing (hsync 64 px, 496 visible, equal vsync intervals), every blended pixel, that the ring held the row the
// converter asked for (the pattern names its row), and the margins in both directions.

`timescale 1ns/1ps

module tb_m2_scan15 #(parameter int DPX = 850);
  logic clk = 1'b0;
  always #5 clk = ~clk;                     // 100 MHz
  logic rst_n = 1'b0;

  int mode, nframes;
  logic nl, ml;
  initial begin
    if (!$value$plusargs("mode=%d", mode)) mode = 0;
    if (!$value$plusargs("frames=%d", nframes)) nframes = 14;
    nl = (mode == 2);
    ml = (mode == 1);
  end

  // ---- the two pixel enables, exactly as Model2.sv makes them
  logic [19:0] acc_i = 0, acc_o = 0;
  logic        ce_in = 0, ce_out = 0;
  wire  [19:0] on = nl ? 20'd861 : ml ? 20'd537 : 20'd547;
  wire  [19:0] od = nl ? 20'd8692 : 20'd5300;
  always @(posedge clk) begin
    if (acc_i >= 20'd100) acc_i <= 20'd0;
    else if (acc_i + 20'd16 >= 20'd100) begin acc_i <= acc_i + 20'd16 - 20'd100; ce_in <= 1'b1; end
    else begin acc_i <= acc_i + 20'd16; ce_in <= 1'b0; end
    if (acc_o >= od) acc_o <= 20'd0;
    else if (acc_o + on >= od) begin acc_o <= acc_o + on - od; ce_out <= 1'b1; end
    else begin acc_o <= acc_o + on; ce_out <= 1'b0; end
  end

  // ---- the native source
  logic [9:0] thc, tvc;
  logic       thb, tvb;
  m2_video_timing tm (.clk(clk), .ce_pix(ce_in), .rst_n(rst_n), .interlace(1'b0), .ntsc_lines(1'b0),
                      .mid_lines(1'b0), .narrow(1'b0), .hcnt(thc), .vcnt(tvc), .hblank(thb), .vblank(tvb),
                      .hsync(), .vsync(), .visible(), .line_start(), .line_number(), .vblank_start(), .field(),
                      .ypos(), .vtotal());

  logic [7:0]  frame = 8'd0;
  logic        vb_prev = 1'b1;
  logic        de_s, vb_s;
  logic [23:0] rgb_s;

  function automatic logic [23:0] pat(input logic [7:0] f, input int y, input int x);
    return {y[7:0], x[7:0], f[3:0], y[8], x[8], 2'b00};
  endfunction

  always @(posedge clk) if (ce_in) begin
    de_s  <= ~(thb | tvb);
    vb_s  <= tvb;
    vb_prev <= tvb;
    if (vb_prev && !tvb) frame <= frame + 8'd1;
    rgb_s <= pat((vb_prev && !tvb) ? frame + 8'd1 : frame, int'(tvc), int'(thc));
  end

  // ---- the device under test
  logic o_hs, o_vs, o_de, o_field, dbg_align;
  logic [23:0] o_rgb;
  m2_scan15 #(.D_PX(DPX)) dut (.clk(clk), .rst_n(rst_n), .en(1'b1), .ce_in(ce_in), .de_in(de_s), .vb_in(vb_s), .rgb_in(rgb_s),
                 .ce_out(ce_out), .nl(nl), .ml(ml), .o_hs(o_hs), .o_vs(o_vs), .o_de(o_de), .o_field(o_field),
                 .o_rgb(o_rgb), .dbg_align(dbg_align));

  initial begin #200 rst_n = 1'b1; end

  // ---- expected blend, as the converter defines it
  function automatic logic [7:0] blend8(input logic [7:0] a, input logic [7:0] b, input int r);
    int s;
    s = a * (5 - r) + b * r + 2;
    return 8'((s * 3277) >> 14);
  endfunction

  // ---- monitors (one block, blocking arithmetic on automatic variables)
  int       fails = 0, checked = 0, ring_fails = 0;
  longint   wt    [8][512];                 // when each ring word was last written
  longint   lastrd[8][512];                 // and last read since
  longint   min_avail = 64'h7FFFFFFFFFFFFFFF, min_over = 64'h7FFFFFFFFFFFFFFF;
  logic [7:0] exp_r, exp_g, exp_b;
  logic       exp_vis = 0;
  logic       ce_out_d = 0;
  logic [7:0] pr, pg, pb;
  logic       pvis = 0;

  // output timing structure
  int  de_lines = 0, vs_seen = 0, hs_w = 0, hs_max = 0, de_w = 0, de_max = 0, nint = 0;
  longint vs_prev = 0;
  longint vs_int [8];
  logic o_hs_d = 0, o_vs_d = 0, o_de_d = 0;

  always @(posedge clk) begin
    automatic logic warm = (frame >= 8'd3);
    ce_out_d <= ce_out;

    // source writes: how long after its last read was this word overwritten?
    if (dut.we_q) begin
      automatic int slot = int'(dut.wa_q[11:9]);
      automatic int x    = int'(dut.wa_q[8:0]);
      if (warm && lastrd[slot][x] != 0) begin
        automatic longint sl = $time - lastrd[slot][x];
        if (sl < min_over) min_over = sl;
      end
      wt[slot][x]     = $time;
      lastrd[slot][x] = 0;
    end

    // reads: the converter puts two addresses a pixel apart (ph 2: row s, ph 3: row s + 1)
    if ((dut.ph == 4'd2 || dut.ph == 4'd3) && dut.de_c) begin
      automatic int slot = int'(dut.ra[11:9]);
      automatic int x    = int'(dut.ra[8:0]);
      lastrd[slot][x] = $time;
      if (warm) begin
        automatic longint av = $time - wt[slot][x];
        if (av < min_avail) min_avail = av;
      end
    end

    // at ph 5 both source words are in a_q / b_q: they must be the rows asked for, of one native frame
    if (dut.ph == 4'd5 && dut.de_c && warm) begin
      automatic int s  = int'(dut.s_c);
      automatic int sb = (s >= 383) ? s : s + 1;
      automatic int x  = int'(dut.hcnt[8:0]);
      automatic logic [7:0] fa = {4'd0, dut.a_q[7:4]};
      automatic logic [7:0] fb = {4'd0, dut.b_q[7:4]};
      if (dut.a_q !== pat(fa, s, x) || dut.b_q !== pat(fb, sb, x) || fa != fb) begin
        ring_fails++;
        if (ring_fails <= 5) $display("RING  x=%0d s=%0d a=%h b=%h (frames %0d %0d) at %0t", x, s, dut.a_q, dut.b_q, fa, fb, $time);
      end
      exp_r   = blend8(dut.a_q[23:16], dut.b_q[23:16], int'(dut.r_q));
      exp_g   = blend8(dut.a_q[15:8],  dut.b_q[15:8],  int'(dut.r_q));
      exp_b   = blend8(dut.a_q[7:0],   dut.b_q[7:0],   int'(dut.r_q));
      exp_vis = 1'b1;
    end

    // the output latches the pixel prepared in the previous period on every enable
    if (ce_out) begin pr = exp_r; pg = exp_g; pb = exp_b; pvis = exp_vis; exp_vis = 1'b0; end
    if (ce_out_d) begin
      if (o_de && warm) begin
        checked++;
        if (!pvis || o_rgb !== {pr, pg, pb}) begin
          fails++;
          if (fails <= 5) $display("PIXEL got %h want %h (prepared %0d) at %0t", o_rgb, {pr, pg, pb}, pvis, $time);
        end
      end
      o_hs_d <= o_hs; o_vs_d <= o_vs; o_de_d <= o_de;
      if (o_hs) hs_w++; else begin if (hs_w > hs_max) hs_max = hs_w; hs_w = 0; end
      if (o_de) de_w++; else begin if (de_w > de_max) de_max = de_w; de_w = 0; end
      if (o_de && !o_de_d) de_lines++;
      if (o_vs && !o_vs_d) begin
        if (vs_prev != 0 && nint < 8) begin vs_int[nint] = $time - vs_prev; nint++; end
        vs_prev = $time;
        vs_seen++;
        de_lines = 0;
      end
    end
  end

  // ---- run, then report
  initial begin
    wait (rst_n);
    wait (frame >= nframes[7:0]);
    $display("mode %0d (%s): %0d native frames", mode, nl ? "262/263" : ml ? "268/269" : "273/274", frame);
    $display("  pixels checked %0d, blend mismatches %0d, ring mismatches %0d", checked, fails, ring_fails);
    $display("  hsync width %0d px, visible width %0d px, vsyncs %0d", hs_max, de_max, vs_seen);
    for (int i = 1; i < nint; i++) $display("  vsync interval %0d: %0d ns (native frame = 17384000 ns)", i, vs_int[i]);
    $display("  margin before the data is written (smallest, ns): %0d   margin before it is overwritten (smallest, ns): %0d",
             min_avail, min_over);
    if (fails == 0 && ring_fails == 0 && checked > 100000 && hs_max == 64 && de_max == 496) $display("PASS");
    else $display("FAIL");
    $finish;
  end

  initial begin #2000000000 $display("TIMEOUT"); $finish; end
endmodule

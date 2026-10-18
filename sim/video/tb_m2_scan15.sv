// SPDX-License-Identifier: GPL-3.0-or-later
// Bench for m2_scan15: the native timing module is the source, every pixel encodes (frame, line, column), and every output
// pixel is checked against a blend worked out here from first principles (not from the converter's own tables).
//
// Build and run from the repo root (WSL):
//   $ sim/video/run_scan15.sh [mode] [D_PX] [frames] [filt]
// Plusargs: mode=0 273/274 lines, 1 = 268/269, 2 = 262/263; frames=N native frames (default 14); filt=0/1 flicker filter;
// bc=1 raise the beacon for about four fields part way through (the picture must be white for whole fields, then normal again); swp=0/1 field order; cad=N the game shows a new image every N native frames (0 = never), ph=P at the frames where
// frame mod N == P (the converter must pair the fields so the changes land on the first field of a frame).
//
// Checks: output timing (hsync 64 px, 496 visible, equal vsync intervals), that the output row on show steps through the
// 4:5 sequence (source row 4m/5, fraction 4m mod 5, m = 2 * field line + field), that the four ring words read are the four rows
// asked for of ONE native frame, every output pixel, and the margins in both directions.

`timescale 1ns/1ps

module tb_m2_scan15 #(parameter int DPX = 1660);
  logic clk = 1'b0;
  always #5 clk = ~clk;                     // 100 MHz
  logic rst_n = 1'b0;

  int mode, nframes, filt_i, swp_i, cad, cph, bc_i;
  logic nl, ml, filt, swp;
  initial begin
    if (!$value$plusargs("mode=%d", mode)) mode = 0;
    if (!$value$plusargs("frames=%d", nframes)) nframes = 14;
    if (!$value$plusargs("filt=%d", filt_i)) filt_i = 1;
    if (!$value$plusargs("swp=%d", swp_i)) swp_i = 0;
    if (!$value$plusargs("cad=%d", cad)) cad = 2;
    if (!$value$plusargs("ph=%d", cph)) cph = 0;
    if (!$value$plusargs("bc=%d", bc_i)) bc_i = 0;
    nl = (mode == 2);
    ml = (mode == 1);
    filt = (filt_i != 0);
    swp = (swp_i != 0);
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
  logic [3:0]  tag = 4'd0;                  // the renderer's show_tag: changes in the vertical blank before a frame of a new image
  logic [3:0]  imgid [16];                  // the tag of each native frame, by frame mod 16
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
    if (vb_prev && !tvb) begin frame <= frame + 8'd1; imgid[(frame + 8'd1) & 8'd15] = tag; end
    if (!vb_prev && tvb && cad != 0 && ((int'(frame) + 1) % cad) == cph) tag <= tag + 4'd1;
    rgb_s <= pat((vb_prev && !tvb) ? frame + 8'd1 : frame, int'(tvc), int'(thc));
  end

  // ---- the device under test
  logic o_hs, o_vs, o_de, o_field, dbg_align;
  logic [23:0] o_rgb;
  m2_scan15 #(.D_PX(DPX)) dut (.clk(clk), .rst_n(rst_n), .en(1'b1), .filt(filt), .swp(swp), .img_tag(tag), .beacon(bcn), .ce_in(ce_in), .de_in(de_s), .vb_in(vb_s),
                 .rgb_in(rgb_s), .ce_out(ce_out), .nl(nl), .ml(ml), .o_hs(o_hs), .o_vs(o_vs), .o_de(o_de), .o_field(o_field),
                 .o_rgb(o_rgb), .dbg_align(dbg_align));

  logic bcn = 1'b0;
  initial begin #200 rst_n = 1'b1; end
  initial begin
    wait (rst_n);
    if (bc_i != 0) begin
      wait (frame >= 8'd36);
      #1234567 bcn = 1'b1;                    // an arbitrary instant
      #69000000 bcn = 1'b0;                   // about four fields
    end
  end

  // ---- the expected picture, from first principles
  // B(m): the source sampled at row 4m/5 with a linear blend, as five times its value: (5 - f) * R[row] + f * R[row + 1],
  // rows clamped to the picture. An output row is c(-1) B(m-1) + c(0) B(m) + c(1) B(m+1) with (1,2,1)/4 filtered, (0,4,0)/4 not.
  function automatic int clampr(input int r);
    return (r < 0) ? 0 : (r > 383) ? 383 : r;
  endfunction

  function automatic int chan(input logic [23:0] p, input int ch);
    return (ch == 0) ? int'(p[23:16]) : (ch == 1) ? int'(p[15:8]) : int'(p[7:0]);
  endfunction

  function automatic int bil5(input logic [7:0] f, input int m, input int x, input int ch);
    int pos, row, fr;
    pos = 4 * m;
    row = (pos >= 0) ? pos / 5 : -1;
    fr  = pos - 5 * row;
    return (5 - fr) * chan(pat(f, clampr(row), x), ch) + fr * chan(pat(f, clampr(row + 1), x), ch);
  endfunction

  function automatic logic [7:0] expect8(input logic [7:0] f, input int m, input int x, input int ch, input logic fl);
    int s;
    s = fl ? (bil5(f, m - 1, x, ch) + 2 * bil5(f, m, x, ch) + bil5(f, m + 1, x, ch)) : 4 * bil5(f, m, x, ch);
    return 8'(((s + 10) * 3277) >> 16);
  endfunction

  // ---- monitors (one block, blocking arithmetic on automatic variables)
  int       fails = 0, checked = 0, ring_fails = 0, step_fails = 0;
  longint   wt    [12][512];                 // when each ring word was last written
  longint   lastrd[12][512];                 // and last read since
  longint   min_avail = 64'h7FFFFFFFFFFFFFFF, min_over = 64'h7FFFFFFFFFFFFFFF;
  logic [7:0] exp_r, exp_g, exp_b;
  logic       exp_vis = 0;
  logic       ce_out_d = 0;
  logic [7:0] pr, pg, pb;
  logic       pvis = 0;
  logic [7:0] cur_f = 8'd0;
  int         bc_white = 0, bc_bad = 0, bc_fields = 0;
  logic       pbc = 1'b0, bc_prev = 1'b0;
  int         pairs = 0, pair_bad = 0;
  logic [3:0] last_a = 4'd0;
  logic       a_ok = 1'b0;

  // output timing structure
  int  de_lines = 0, vs_seen = 0, hs_w = 0, hs_max = 0, de_w = 0, de_max = 0, nint = 0;
  longint vs_prev = 0;
  longint vs_int [8];
  logic o_hs_d = 0, o_vs_d = 0, o_de_d = 0;

  always @(posedge clk) begin
    automatic logic warm = (frame >= 8'd3);
    ce_out_d <= ce_out;
    if (dut.fs_now && dut.ce_in && frame < 60 && $test$plusargs("dbg")) $display("FS frame %0d par %0d tg_s %0d tg_p %0d bad %0d tag %0d", frame, dut.par, dut.tg_s, dut.tg_p, dut.bad, tag);

    // source writes: how long after its last read was this word overwritten?
    if (dut.we_w) begin
      automatic int slot = int'(dut.wa_w[12:9]);
      automatic int x    = int'(dut.wa_w[8:0]);
      if (warm && lastrd[slot][x] != 0) begin
        automatic longint sl = $time - lastrd[slot][x];
        if (sl < min_over) min_over = sl;
      end
      wt[slot][x]     = $time;
      lastrd[slot][x] = 0;
    end

    // reads: the converter puts four addresses on the ring in consecutive cycles (ph 2 to 5)
    if (dut.ph >= 4'd2 && dut.ph <= 4'd5 && dut.de_c) begin
      automatic int slot = int'(dut.ra[12:9]);
      automatic int x    = int'(dut.ra[8:0]);
      lastrd[slot][x] = $time;
      if (warm) begin
        automatic longint av = $time - wt[slot][x];
        if (av < min_avail) min_avail = av;
      end
    end

    // the four words arrive on rd in ph 3 to 6: they must be rows s-1, s, s+1, s+2 (clamped) of ONE native frame
    if (dut.ph >= 4'd3 && dut.ph <= 4'd6 && dut.de_c && warm) begin
      automatic int k  = int'(dut.ph) - 3;
      automatic int m  = 2 * int'(dut.vcnt) + int'(dut.field ^ swp);
      automatic int s  = (4 * m) / 5;
      automatic int x  = int'(dut.hcnt[8:0]);
      automatic int row = clampr(s + k - 1);
      automatic logic [7:0] f = {4'd0, dut.rd[7:4]};
      if (k == 0) begin
        cur_f = f;
        if (dut.vcnt == 10'd0 && dut.hcnt == 10'd0 && frame >= 8'd40) begin
          if (dut.field == 1'b0) begin last_a = imgid[f[3:0]]; a_ok = 1'b1; end
          else if (a_ok) begin
            pairs++;
            if (imgid[f[3:0]] != last_a) begin pair_bad++; $display("PAIRBAD at native frame %0d", frame); end
          end
        end
        // the output row on show steps through fraction 4m mod 5 (the row itself is checked by the ring words below)
        if (int'(dut.r_c) != (4 * m) % 5) begin
          step_fails++;
          if (step_fails <= 5) $display("STEP  m=%0d r=%0d want r=%0d at %0t", m, int'(dut.r_c), (4 * m) % 5, $time);
        end
      end
      if (dut.rd !== pat(f, row, x) || f != cur_f) begin
        ring_fails++;
        if (ring_fails <= 5) $display("RING  tap %0d x=%0d s=%0d want row %0d: rd=%h (frame %0d, wanted %0d) at %0t", k, x, s, row, dut.rd, f, cur_f, $time);
      end
    end

    // all four words are in: the expected pixel
    if (dut.ph == 4'd7 && dut.de_c && warm) begin
      automatic int m = 2 * int'(dut.vcnt) + int'(dut.field ^ swp);
      automatic int x = int'(dut.hcnt[8:0]);
      exp_r   = expect8(cur_f, m, x, 0, filt);
      exp_g   = expect8(cur_f, m, x, 1, filt);
      exp_b   = expect8(cur_f, m, x, 2, filt);
      exp_vis = 1'b1;
    end

    // the output latches the pixel prepared in the previous period on every enable
    if (ce_out) begin pr = exp_r; pg = exp_g; pb = exp_b; pvis = exp_vis; exp_vis = 1'b0; pbc = dut.bc_on; end
    if (ce_out_d) begin
      if (o_de && warm && pbc) begin
        if (o_rgb === 24'hFFFFFF) bc_white++; else bc_bad++;                      // a beacon field is white, all of it
      end else if (o_de && warm) begin
        checked++;
        if (!pvis || o_rgb !== {pr, pg, pb}) begin
          fails++;
          if (fails <= 5) $display("PIXEL got %h want %h (prepared %0d) at %0t", o_rgb, {pr, pg, pb}, pvis, $time);
        end
      end
      o_hs_d <= o_hs; o_vs_d <= o_vs; o_de_d <= o_de;
      if (pbc && !bc_prev) bc_fields++;
      bc_prev = pbc;
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
    $display("mode %0d (%s): %0d native frames, filter %0d", mode, nl ? "262/263" : ml ? "268/269" : "273/274", frame, filt_i);
    $display("  pixels checked %0d, blend mismatches %0d, ring mismatches %0d, row-step mismatches %0d", checked, fails, ring_fails, step_fails);
    $display("  hsync width %0d px, visible width %0d px, vsyncs %0d", hs_max, de_max, vs_seen);
    if (bc_i != 0) $display("  beacon: %0d white pixels (%0d fields of 119040), %0d not white, bc_on at the end %0d", bc_white, bc_white / 119040, bc_bad, dut.bc_on);
    $display("  image cadence %0d phase %0d, field order swapped %0d: output frames %0d, made of two images %0d", cad, cph, swp_i, pairs, pair_bad);
    for (int i = 1; i < nint; i++) $display("  vsync interval %0d: %0d ns (native frame = 17384000 ns)", i, vs_int[i]);
    $display("  margin before the data is written (smallest, ns): %0d   margin before it is overwritten (smallest, ns): %0d",
             min_avail, min_over);
    if (fails == 0 && ring_fails == 0 && step_fails == 0 && checked > 100000 && hs_max == 64 && de_max == 496 &&
        !(bc_i != 0 && (bc_bad != 0 || bc_white < 3 * 119040 || bc_white > 6 * 119040 || dut.bc_on)) &&
        !(cad == 2 && nframes >= 70 && (pairs < 10 || pair_bad != 0))) $display("PASS");
    else $display("FAIL");
    $finish;
  end

  initial begin #2000000000 $display("TIMEOUT"); $finish; end
endmodule

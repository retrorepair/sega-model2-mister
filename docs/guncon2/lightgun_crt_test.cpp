// Host-side tests for lightgun_crt (no MiSTer needed):
//   g++ -std=gnu++14 -Wall -Wextra -I. test/lightgun_crt_test.cpp lightgun_crt.cpp -o /tmp/lgtest && /tmp/lgtest
#include <stdio.h>
#include <stdlib.h>
#include "lightgun_crt.h"

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL line %d: %s\n", __LINE__, #cond); failures++; } } while (0)

// default GunCon 2 calibration used by Main_MiSTer: X 145..700, Y 25..245
static crtgun_params P = { 145, 700, 25, 245, CRTGUN_DEF_X_VALID_MIN, CRTGUN_DEF_SHOT_MS, CRTGUN_DEF_DARK_MS, CRTGUN_DEF_EDGE_PCT, 0, 0 };

// the same box with the aim taken from the game's flash
static crtgun_params P1 = { 145, 700, 25, 245, CRTGUN_DEF_X_VALID_MIN, CRTGUN_DEF_SHOT_MS, CRTGUN_DEF_DARK_MS, CRTGUN_DEF_EDGE_PCT, 1, 0 };

// the same box for a core that can flash the picture white on request
static crtgun_params PB = { 145, 700, 25, 245, CRTGUN_DEF_X_VALID_MIN, CRTGUN_DEF_SHOT_MS, CRTGUN_DEF_DARK_MS, CRTGUN_DEF_EDGE_PCT, 0, 1 };

struct Rig
{
	crtgun_state s;
	uint32_t t;
	const crtgun_params *pp;
	Rig(uint32_t t0 = 1000) : t(t0), pp(&P) { crtgun_reset(&s); }
	Rig(const crtgun_params *params, uint32_t t0 = 1000) : t(t0), pp(params) { crtgun_reset(&s); }
	void report(uint32_t at, int x, int y) { t = at; crtgun_set_axis(&s, true, x, pp); crtgun_set_axis(&s, false, y, pp); crtgun_update(&s, pp, t); crtgun_report(&s, pp, t); }
	void trigger(uint32_t at, bool down) { t = at; crtgun_set_trigger(&s, down, t, pp); crtgun_update(&s, pp, t); }
	void bc_trigger(uint32_t at, bool down) { t = at; crtgun_beacon_trigger(&s, pp, down, t); crtgun_update(&s, pp, t); crtgun_beacon_poll(&s, pp, t); }
	void poll(uint32_t at) { t = at; crtgun_update(&s, pp, t); crtgun_beacon_poll(&s, pp, t); }
};

static void test_tracking_passes_through()
{
	Rig r;
	r.report(1000, 400, 130);
	CHECK(!r.s.offscreen && r.s.out_x == 400 && r.s.out_y == 130);
	r.report(1020, 410, 131);
	CHECK(!r.s.offscreen && r.s.out_x == 410 && r.s.out_y == 131);
}

static void test_never_seen_light_is_offscreen()
{
	// real data: a gun at rest in the dark reports X toggling 0/1, Y constant 5
	Rig r;
	for (int i = 0; i < 200; i++)
	{
		r.report(1000 + i * 20, i & 1, 5);
		CHECK(r.s.offscreen);
		CHECK(r.s.out_x < P.xmin && r.s.out_y < P.ymin);
	}
}

static void test_interior_dark_gap_holds_then_expires()
{
	Rig r;
	r.report(1000, 420, 135);                    // centre of the screen
	r.report(1020, 0, 5);                        // beam lost
	CHECK(!r.s.offscreen && r.s.out_x == 420 && r.s.out_y == 135);
	r.report(1020 + P.dark_ms, 0, 5);            // exactly dark_ms after the light was lost: still held
	CHECK(!r.s.offscreen);
	r.report(1021 + P.dark_ms, 0, 5);            // one ms past
	CHECK(r.s.offscreen);
	r.report(2000, 430, 140);                    // light is back
	CHECK(!r.s.offscreen && r.s.out_x == 430);
}

static void test_leaving_through_an_edge_is_immediate()
{
	Rig r;
	r.report(1000, 690, 130);                    // near the right edge
	r.report(1020, 0, 5);
	CHECK(r.s.offscreen);
	Rig r2;
	r2.report(1000, 400, 30);                    // near the top edge
	r2.report(1020, 1, 5);
	CHECK(r2.s.offscreen);
	Rig r3;
	r3.report(1000, 150, 130);                   // near the left edge
	r3.report(1020, 0, 5);
	CHECK(r3.s.offscreen);
	Rig r4;
	r4.report(1000, 400, 240);                   // near the bottom edge
	r4.report(1020, 0, 5);
	CHECK(r4.s.offscreen);
}

static void test_shot_flash_is_held_even_at_an_edge()
{
	Rig r;
	r.report(1000, 695, 130);                    // aiming at the very edge
	r.trigger(1010, true);
	r.report(1030, 0, 5);                        // the game blanks the screen
	CHECK(!r.s.offscreen && r.s.out_x == 695);
	r.report(1010 + P.shot_ms, 0, 5);
	CHECK(!r.s.offscreen);
	r.report(1011 + P.shot_ms, 0, 5);            // window over, edge position, no light: now offscreen
	CHECK(r.s.offscreen);
}

static void test_flash_measurement_replaces_the_held_position()
{
	Rig r;
	r.report(1000, 300, 100);
	r.trigger(1010, true);
	r.report(1030, 0, 5);                        // black frame
	CHECK(r.s.out_x == 300);
	r.report(1060, 305, 102);                    // the target box lights up: the real measurement
	CHECK(!r.s.offscreen && r.s.out_x == 305 && r.s.out_y == 102);
	r.report(1080, 0, 5);                        // back to dark, still inside the window
	CHECK(!r.s.offscreen && r.s.out_x == 305);
}

static void test_shot_with_no_light_stays_offscreen()
{
	// aiming off the screen and pulling the trigger (reload) must not turn into an on-screen shot
	Rig r;
	r.report(1000, 690, 130);
	r.report(1020, 0, 5);                        // left through the right edge
	CHECK(r.s.offscreen);
	r.trigger(1100, true);
	r.report(1120, 0, 5);
	CHECK(r.s.offscreen);
	CHECK(!r.s.shot);
}

static void test_dark_scene_shot_uses_interior_hold()
{
	Rig r;
	r.report(1000, 420, 135);
	r.report(1020, 0, 5);                        // scene went dark
	r.trigger(1100, true);                       // pulled in the dark: no shot window...
	CHECK(!r.s.shot);
	r.report(1120, 0, 5);
	CHECK(!r.s.offscreen && r.s.out_x == 420);   // ...but the interior hold still applies
}

static void test_still_gun_loses_light_much_later()
{
	// The kernel sends nothing while values are unchanged, so a gun held still on a bright spot is silent
	// for as long as it likes. The gap is measured from when the light went, not from the last event.
	Rig r;
	r.report(1000, 420, 135);
	r.report(31000, 0, 5);                       // 30 s of silence, then the screen blinks
	CHECK(!r.s.offscreen && r.s.out_x == 420);
	r.report(31000 + P.dark_ms, 0, 5);
	CHECK(!r.s.offscreen);
	r.report(31001 + P.dark_ms, 0, 5);
	CHECK(r.s.offscreen);
}

static void test_time_wraparound()
{
	Rig r(0xFFFFFFF0u);
	r.report(0xFFFFFFF0u, 420, 135);
	r.report(0xFFFFFFF0u + 100, 0, 5);           // wraps past zero
	CHECK(!r.s.offscreen);
	r.report(0xFFFFFFF0u + 100 + P.dark_ms, 0, 5);
	CHECK(!r.s.offscreen);
	r.report(0xFFFFFFF0u + 101 + P.dark_ms, 0, 5);
	CHECK(r.s.offscreen);
}

// ---- mode 1: aim from the game's flash ----

static void test_flash_mode_holds_between_pulls()
{
	Rig r(&P1);
	r.report(1000, 300, 100);
	CHECK(!r.s.pub_off && r.s.pub_x == (P1.xmin + P1.xmax) / 2 && r.s.pub_y == (P1.ymin + P1.ymax) / 2);   // no pull yet: the middle
	r.report(1020, 350, 150);
	r.report(1040, 0, 5);
	r.report(1060, 500, 200);
	CHECK(!r.s.pub_off && r.s.pub_x == (P1.xmin + P1.xmax) / 2);                                              // the scene does not move it
}

static void test_pull_with_light_takes_the_flash_readings()
{
	Rig r(&P1);
	r.report(1000, 300, 100);
	r.trigger(1010, true);
	CHECK(!r.s.pub_off && r.s.pub_x == 300 && r.s.pub_y == 100);              // the best estimate at the instant of the pull
	r.report(1060, 0, 5);                                                      // the black frame
	CHECK(r.s.pub_x == 300);
	r.report(1100, 310, 102);                                                  // the flash
	CHECK(r.s.pub_x == 310 && r.s.pub_y == 102);
	r.report(1117, 312, 103);
	r.report(1133, 308, 101);
	CHECK(r.s.pub_x == 310 && r.s.pub_y == 102);                               // median of the first three
	r.report(1200, 400, 200);                                                  // the scene afterwards
	CHECK(r.s.pub_x == 310 && r.s.pub_y == 102 && !r.s.pub_off);
}

static void test_pull_in_the_dark_waits_for_the_flash()
{
	Rig r(&P1);
	for (int i = 0; i < 20; i++) r.report(1000 + i * 20, i & 1, 5);          // nothing but noise
	r.trigger(1500, true);
	CHECK(r.s.pub_off);                                                        // nothing seen: offscreen until the flash says otherwise
	r.report(1560, 0, 5);
	CHECK(r.s.pub_off);
	r.report(1580, 250, 120);                                                  // the game's flash lights up the aim
	CHECK(!r.s.pub_off && r.s.pub_x == 250 && r.s.pub_y == 120);
	r.report(1597, 252, 121);
	r.report(1613, 248, 119);
	CHECK(r.s.pub_x == 250 && r.s.pub_y == 120);
}

static void test_pull_with_no_flash_stays_offscreen()
{
	Rig r(&P1);
	for (int i = 0; i < 10; i++) r.report(1000 + i * 20, i & 1, 5);
	r.trigger(1300, true);
	for (int i = 0; i < 30; i++) r.report(1320 + i * 20, i & 1, 5);          // no light for 600 ms
	CHECK(r.s.pub_off);
	r.report(2000, 300, 100);                                                  // too late: the window is over
	CHECK(r.s.pub_off);
}

static void test_dark_interior_pull_holds_the_aim_until_the_flash()
{
	Rig r(&P1);
	r.report(1000, 420, 135);                                                  // aiming mid-screen
	r.report(1020, 0, 5);                                                      // scene went dark
	r.trigger(1200, true);
	CHECK(!r.s.pub_off && r.s.pub_x == 420 && r.s.pub_y == 135);              // the interior hold carries the aim
	r.report(1260, 424, 138);                                                  // flash
	CHECK(r.s.pub_x == 424 && r.s.pub_y == 138);
}

static void test_each_pull_restarts_the_measurement()
{
	Rig r(&P1);
	r.report(1000, 300, 100);
	r.trigger(1010, true);
	r.report(1050, 300, 100); r.report(1067, 301, 100); r.report(1083, 299, 100);
	r.trigger(1100, false);
	CHECK(r.s.pub_x == 300);
	r.report(1500, 500, 200);
	r.trigger(1510, true);
	CHECK(r.s.pub_x == 500 && r.s.pub_y == 200);
	r.report(1560, 502, 201); r.report(1577, 498, 199); r.report(1593, 500, 200);
	CHECK(r.s.pub_x == 500 && r.s.pub_y == 200);
}

// the kernel driver keeps only the low byte of Y: for a picture that reaches past line 255 a lit report in the wrapped lines is put back
static void test_wrapped_y_is_restored_when_the_picture_reaches_past_255()
{
	crtgun_params q = P;
	q.ymin = 22; q.ymax = 273;                 // Terminator 2: 18 picture lines past 255
	Rig r(&q);
	r.report(1000, 400, 5);                    // line 261, light
	CHECK(r.s.raw_y == 261);
	r.report(1020, 400, 17);                   // line 273, the last picture line
	CHECK(r.s.raw_y == 273);
	r.report(1040, 400, 19);                   // 3 lines past the picture: still the wrapped zone (slack 2)
	CHECK(r.s.raw_y == 275);
	r.report(1060, 400, 120);                  // the middle of the screen is never touched
	CHECK(r.s.raw_y == 120);
	r.report(1080, 400, 24);                   // just under the top of the picture
	CHECK(r.s.raw_y == 24);
	r.report(1100, 0, 5);                      // no light: junk Y is left alone
	CHECK(r.s.raw_y == 5);

	crtgun_params u = P;                       // a picture that ends before 256 never has anything unwrapped
	u.ymin = 30; u.ymax = 250;
	Rig r2(&u);
	r2.report(1000, 400, 5);
	CHECK(r2.s.raw_y == 5);
}

// The first report after the game's black flash frame has the right X but Y = 5, a line above the picture: not an aim.
static void test_the_report_after_the_black_frame_is_not_an_aim()
{
	Rig r;
	r.report(1000, 400, 130);
	r.trigger(1010, true);
	r.report(1040, 0, 143);                           // the black frame
	r.report(1057, 400, 5);                           // right X, Y above the picture
	CHECK(r.s.out_x == 400 && r.s.out_y == 130);      // still the aim from before: the junk report was ignored
	r.report(1074, 402, 131);
	CHECK(r.s.out_x == 402 && r.s.out_y == 131);

	Rig q(&P1);                                       // flash mode: a dark scene, so the flash readings ARE the measurement
	q.report(1000, 300, 100);
	q.trigger(1010, true);
	q.report(1040, 0, 143);
	q.report(1057, 300, 5);                           // not counted as the first flash reading
	q.report(1074, 302, 101);
	q.report(1091, 303, 102);
	q.report(1108, 301, 100);
	CHECK(q.s.pub_x == 302 && q.s.pub_y == 101 && !q.s.pub_off);
}

// ---- beacon: the core flashes the picture white on request
static void test_beacon_steady_gun_on_the_screen()
{
	Rig r(&PB);
	r.report(1000, 400, 130);
	r.bc_trigger(1010, true);
	CHECK(r.s.bc_req && r.s.bc_phase == 1 && !r.s.bc_ev_press);      // the flash is asked for, the trigger is held back
	r.poll(1030);
	CHECK(r.s.bc_phase == 1 && !r.s.bc_ev_press);
	r.poll(1070);                                                      // a steady gun sends nothing new: what it last reported is the aim
	CHECK(r.s.bc_ev_press && !r.s.bc_req && r.s.bc_phase == 2);
	CHECK(!r.s.pub_off && r.s.pub_x == 400 && r.s.pub_y == 130);
}

static void test_beacon_lights_a_dark_aim()
{
	Rig r(&PB);
	for (int i = 0; i < 10; i++) r.report(500 + i * 20, i & 1, 5);   // dark: nothing
	r.bc_trigger(1010, true);
	r.report(1020, 0, 143);                                          // the flash has not reached the spot yet
	r.report(1030, 400, 5);                                          // first lit report: right X, junk Y: not a reading
	CHECK(r.s.bc_n == 0 && !r.s.bc_ev_press);
	r.report(1040, 402, 131);
	CHECK(r.s.bc_n == 1 && !r.s.bc_ev_press);
	r.report(1057, 404, 132);                                        // two good readings: decide
	CHECK(r.s.bc_ev_press && !r.s.pub_off && r.s.pub_x == 404 && r.s.pub_y == 132);
	CHECK(r.s.bc_phase == 2);
}

static void test_beacon_no_light_is_offscreen()
{
	Rig r(&PB);
	r.report(1000, 400, 130);
	r.report(1020, 0, 5);                                            // the gun swings off the screen
	r.bc_trigger(1100, true);
	r.poll(1140);
	CHECK(!r.s.bc_ev_press && r.s.bc_phase == 1);
	r.poll(1160);                                                      // 60 ms of white picture and not a photon: off the screen
	CHECK(!r.s.bc_ev_press);
	r.poll(1190);
	CHECK(r.s.bc_ev_press && r.s.pub_off);
}

static void test_beacon_tap_gives_press_then_release_later()
{
	Rig r(&PB);
	r.report(1000, 400, 130);
	r.bc_trigger(1010, true);
	r.bc_trigger(1030, false);                                       // a tap, over before the measurement
	CHECK(!r.s.bc_ev_press && !r.s.bc_ev_release);
	r.poll(1070);
	CHECK(r.s.bc_ev_press && !r.s.bc_ev_release);                    // the press first
	r.s.bc_ev_press = false;
	r.poll(1090);
	CHECK(!r.s.bc_ev_release);                                       // and held for at least 40 ms
	r.poll(1115);
	CHECK(r.s.bc_ev_release);
}

static void test_beacon_new_pull_releases_the_old_press_first()
{
	Rig r(&PB);
	r.report(1000, 400, 130);
	r.bc_trigger(1010, true);
	r.poll(1070);
	CHECK(r.s.bc_ev_press);
	r.s.bc_ev_press = false;
	r.bc_trigger(1200, true);                                        // the trigger never came up in the tracker's books? it did not: a second pull needs a release in between
	r.bc_trigger(1230, false);
	r.bc_trigger(1300, true);                                        // a new pull while the last press is still down at the core
	CHECK(r.s.bc_phase == 1 && r.s.bc_req);
}

static void test_beacon_hold_expires_and_the_aim_follows_the_gun_again()
{
	Rig r(&PB);
	r.report(1000, 400, 130);
	r.bc_trigger(1010, true);
	r.poll(1070);
	r.report(1100, 420, 140);                                        // the gun moves during the hold: the held aim does not
	CHECK(r.s.pub_x == 400);
	r.poll(1070 + CRTGUN_BC_HOLD_MS);
	CHECK(r.s.bc_phase == 0);
	r.report(1400, 430, 141);
	CHECK(r.s.pub_x == 430 && r.s.pub_y == 141);
}

int main()
{
	test_beacon_steady_gun_on_the_screen();
	test_beacon_lights_a_dark_aim();
	test_beacon_no_light_is_offscreen();
	test_beacon_tap_gives_press_then_release_later();
	test_beacon_new_pull_releases_the_old_press_first();
	test_beacon_hold_expires_and_the_aim_follows_the_gun_again();
	test_the_report_after_the_black_frame_is_not_an_aim();
	test_wrapped_y_is_restored_when_the_picture_reaches_past_255();
	test_tracking_passes_through();
	test_never_seen_light_is_offscreen();
	test_interior_dark_gap_holds_then_expires();
	test_leaving_through_an_edge_is_immediate();
	test_shot_flash_is_held_even_at_an_edge();
	test_flash_measurement_replaces_the_held_position();
	test_shot_with_no_light_stays_offscreen();
	test_dark_scene_shot_uses_interior_hold();
	test_still_gun_loses_light_much_later();
	test_time_wraparound();
	test_flash_mode_holds_between_pulls();
	test_pull_with_light_takes_the_flash_readings();
	test_pull_in_the_dark_waits_for_the_flash();
	test_pull_with_no_flash_stays_offscreen();
	test_dark_interior_pull_holds_the_aim_until_the_flash();
	test_each_pull_restarts_the_measurement();
	if (failures) { printf("%d check(s) failed\n", failures); return 1; }
	printf("all lightgun_crt tests passed\n");
	return 0;
}

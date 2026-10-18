#ifndef LIGHTGUN_CRT_H
#define LIGHTGUN_CRT_H

#include <stdint.h>

// Position tracker for CRT lightguns (GunCon 2).
//
// A CRT gun only reports a position while its photodiode sees the beam. Where it sees nothing
// (dark scene, the game's own flash blanking the screen, gun pointed away) the GunCon 2 reports
// X = 0 (or 1 from stray light) and a meaningless Y. This module decides, from raw reports, what
// position the core should be given.
//
// The decision uses only physical facts:
//  - Losing the beam in the interior of the picture cannot be the gun leaving the screen (it would
//    have to cross an edge first), so it is a dark frame: keep the last position.
//  - Losing the beam at an edge is the gun leaving the screen: report offscreen at once.
//  - A shot flash (the game blanks the screen and lights targets after a trigger pull) is exactly
//    when the real hardware measures the position, so a trigger pull made while the gun was tracking
//    opens a window in which dark reports are ignored and valid reports (the flash) are taken.
//
// The kernel only delivers a report when a value changed, so a gun held perfectly still sends nothing;
// "no event" therefore means "unchanged", and the time of the last valid event says nothing about how
// long the light has really been gone. The dark-gap timer starts at the transition to "no light".
//
// Two ways to hand a position to the core (params.mode):
//   0  follow the gun continuously, applying the rules above;
//   1  take the aim from the game's flash and hold it. The game flashes the screen after the trigger so the gun can
//      measure, and the readings during that flash are the clean ones; between shots the scene (mostly dark in many
//      games) makes the gun's readings wander or vanish. On a trigger pull the pointer is set to the rules' best
//      estimate at that instant, then to the median of the first CRTGUN_FLASH_N valid readings that follow (the
//      flash), and it then stays put until the next pull. A pull with no light and no flash stays offscreen.
//
// No video or core knowledge is needed; times are in milliseconds and may wrap.

struct crtgun_params
{
	int32_t  xmin, xmax;    // calibrated screen rectangle in raw gun units
	int32_t  ymin, ymax;
	int32_t  x_valid_min;   // raw X below this means "no light"
	uint32_t shot_ms;       // window after a trigger pull (made while tracking) that ignores dark reports
	uint32_t dark_ms;       // longest hold across a dark gap that began inside the screen
	int32_t  edge_pct;      // percentage of each axis span, from each edge, that counts as "edge"
	int32_t  mode;          // 0 continuous, 1 aim from the game's flash (see above)
	int32_t  beacon;        // 1: the core flashes the whole picture white when asked (see "Beacon" below); 0: it cannot
};

#define CRTGUN_FLASH_N 3   // valid readings after a pull that make up the flash measurement

// Beacon. A CRT gun reads only where there is light: a dark enemy, or a dark patch of the picture, gives it nothing and the aim is lost,
// and the games' own flash is not a measurement (Virtua Cop's is a black frame). On the arcade cabinet a gun interface board in the video
// path supplies the light; here the CORE does, when the app asks: it shows the whole picture white for a few fields. On a trigger pull
// the tracker holds the trigger back, asks for the flash, collects what the gun sees, and then gives the core the aim and the trigger
// together. Seeing no light during the flash is proof the gun is off the screen, so that is an exact reload, with no guessing about dark
// frames or edges. The first lit report after darkness has a junk Y (it is rejected by crtgun_valid), so the flash has to last a few fields.
#define CRTGUN_BC_MAXN        8
#define CRTGUN_BC_SETTLE_MS   55    // the flash has been on long enough for any aim: decide with what has been seen
#define CRTGUN_BC_GIVEUP_MS   85    // nothing seen by now: the gun is off the screen
#define CRTGUN_BC_HOLD_MS     250   // the measured aim is held this long after the trigger is given (the game reads it a frame or two later)
#define CRTGUN_BC_MIN_PRESS_MS 40   // the trigger is given to the core for at least this long (its I/O board scans at 1 kHz)

struct crtgun_state
{
	int32_t  raw_x, raw_y;  // latest raw report
	int32_t  last_x, last_y;// last valid sample
	uint32_t lost_t;        // when the gun last went from seeing light to not seeing it
	uint32_t shot_t;        // time of the trigger pull that opened the shot window
	bool     seen;          // at least one valid sample so far
	bool     was_valid;     // the previous update saw light
	bool     trig;          // trigger currently down
	bool     shot;          // shot window open (until shot_t + shot_ms)

	// result of the last crtgun_update(): what the rules say right now
	int32_t  out_x, out_y;  // position, raw gun units
	bool     offscreen;     // true: out_x/out_y are forced outside the screen

	// mode 1 (aim from the flash)
	bool     pub_init;
	bool     win_open;      // collecting the flash measurement
	uint32_t win_t0;        // time of the pull
	int      win_n;
	int32_t  win_x[CRTGUN_FLASH_N], win_y[CRTGUN_FLASH_N];

	// what to give the core: out_x/out_y in mode 0, the held aim in mode 1
	int32_t  pub_x, pub_y;
	bool     pub_off;

	// beacon (params.beacon)
	int      bc_phase;      // 0 idle (the aim follows the gun), 1 measuring (flash requested, trigger held back), 2 holding the measured aim
	uint32_t bc_t0;         // the pull
	uint32_t bc_hold_until;
	uint32_t bc_press_t;
	int      bc_n;
	int32_t  bc_x[CRTGUN_BC_MAXN], bc_y[CRTGUN_BC_MAXN];
	bool     bc_req;        // the flash is requested (a level the caller sends to the core)
	bool     bc_trig_in;    // the physical trigger is down
	bool     bc_pressed;    // the core has been given the press
	bool     bc_rel_pending;// the trigger came up before (or just after) the press: give the release once the press has been long enough
	bool     bc_ev_press;   // event for the caller: give the core the trigger press now (the caller clears it)
	bool     bc_ev_release; // event for the caller: give the core the trigger release now (the caller clears it)
};

#define CRTGUN_DEF_X_VALID_MIN 16
#define CRTGUN_DEF_SHOT_MS     400   // how long after a pull the flash is waited for
#define CRTGUN_DEF_DARK_MS     500
#define CRTGUN_DEF_EDGE_PCT    12
#define CRTGUN_DEF_MODE        1

void crtgun_reset(crtgun_state *s);

// Feed raw data, then call crtgun_update(). now_ms is the report time (kernel event time).
// p is needed for Y: see the wrap note in lightgun_crt.cpp.
void crtgun_set_axis(crtgun_state *s, bool is_x, int32_t value, const crtgun_params *p);
void crtgun_set_trigger(crtgun_state *s, bool down, uint32_t now_ms, const crtgun_params *p);

// Recompute out_x / out_y / offscreen (call after any single event) ...
void crtgun_update(crtgun_state *s, const crtgun_params *p, uint32_t now_ms);
// ... and call this at the end of each complete gun report (the SYN event): it also feeds the flash measurement.
void crtgun_report(crtgun_state *s, const crtgun_params *p, uint32_t now_ms);

// Beacon: the physical trigger changed (call instead of letting the press and release reach the core), and the poll that turns what the gun
// has seen into decisions (call after every event and every few ms). The caller sends bc_req to the core and, on bc_ev_press / bc_ev_release,
// gives the core the trigger press / release.
void crtgun_beacon_trigger(crtgun_state *s, const crtgun_params *p, bool down, uint32_t now_ms);
void crtgun_beacon_poll(crtgun_state *s, const crtgun_params *p, uint32_t now_ms);

// True if the gun reports light at all (raw X at or above the "no light" level).
static inline bool crtgun_lit(const crtgun_state *s, const crtgun_params *p)
{
	return s->raw_x >= p->x_valid_min;
}

// A reading that is lit AND could be a place on the picture. The first report after a blackout (the game's shot flash is one black
// frame) comes with the right X but Y = 5, a line above the top of the picture where nothing is drawn: it is not an aim, and taken as one
// it threw the aim to the top edge at the very moment the game read it. Anything more than CRTGUN_RANGE_SLACK_PCT of the span outside the
// calibrated picture, on either axis, is rejected as if there were no light.
#define CRTGUN_RANGE_SLACK_PCT 4
static inline bool crtgun_valid(const crtgun_state *s, const crtgun_params *p)
{
	if (!crtgun_lit(s, p)) return false;
	int32_t mx = (int32_t)(((int64_t)(p->xmax - p->xmin) * CRTGUN_RANGE_SLACK_PCT) / 100);
	int32_t my = (int32_t)(((int64_t)(p->ymax - p->ymin) * CRTGUN_RANGE_SLACK_PCT) / 100);
	return s->raw_x >= p->xmin - mx && s->raw_x <= p->xmax + mx && s->raw_y >= p->ymin - my && s->raw_y <= p->ymax + my;
}

#endif

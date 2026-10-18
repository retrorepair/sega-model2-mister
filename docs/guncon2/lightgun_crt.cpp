#include <string.h>
#include "lightgun_crt.h"

void crtgun_reset(crtgun_state *s)
{
	memset(s, 0, sizeof(*s));
}

// PLATFORM LIMIT, to be removed with the driver fix: the GunCon 2 reports Y as 16 bits, but the kernel driver
// (drivers/hid/hid-guncon2.c: y = data[4]) keeps only the low byte, so line 256 arrives as 0, 257 as 1, and so on. A picture whose
// bottom is past line 255 (Terminator 2, Point Blank 2, Time Crisis) would have its last lines read as the top of the screen. Those
// wrapped values are never a real reading: nothing above the picture is lit, so a report WITH light whose Y falls in the wrapped
// lines of the picture (plus CRTGUN_Y_WRAP_SLACK for the calibration's own error) has the 256 put back. Without light the Y is junk
// and left alone. The proper fix is the one-line driver patch in patches/kernel/.
#define CRTGUN_Y_WRAP        256
#define CRTGUN_Y_WRAP_SLACK  2

void crtgun_set_axis(crtgun_state *s, bool is_x, int32_t value, const crtgun_params *p)
{
	if (is_x)
	{
		s->raw_x = value;
		return;
	}

	if (p && p->ymax >= CRTGUN_Y_WRAP && value >= 0 && crtgun_lit(s, p) && value <= p->ymax - CRTGUN_Y_WRAP + CRTGUN_Y_WRAP_SLACK)
		value += CRTGUN_Y_WRAP;
	s->raw_y = value;
}

// The last valid sample is "interior" if it is at least edge_pct of the span away from every edge.
static bool is_interior(const crtgun_state *s, const crtgun_params *p)
{
	int32_t mx = (int32_t)(((int64_t)(p->xmax - p->xmin) * p->edge_pct) / 100);
	int32_t my = (int32_t)(((int64_t)(p->ymax - p->ymin) * p->edge_pct) / 100);
	return s->last_x >= p->xmin + mx && s->last_x <= p->xmax - mx &&
	       s->last_y >= p->ymin + my && s->last_y <= p->ymax - my;
}

static void update_rules(crtgun_state *s, const crtgun_params *p, uint32_t now_ms);

static int32_t median3(const int32_t *v, int n)
{
	int32_t t[CRTGUN_FLASH_N] = {};
	if (n < 1) return 0;
	for (int i = 0; i < n; i++) t[i] = v[i];
	for (int i = 1; i < n; i++)
	{
		int32_t k = t[i];
		int j = i - 1;
		while (j >= 0 && t[j] > k) { t[j + 1] = t[j]; j--; }
		t[j + 1] = k;
	}
	return t[n / 2];
}

// the value to give the core, from the rules' estimate and, in mode 1, the held aim
static void publish(crtgun_state *s, const crtgun_params *p, uint32_t now_ms)
{
	if (p->beacon && s->bc_phase != 0) return;      // a beacon measurement (or its hold) owns the aim

	if (p->mode != 1)
	{
		s->pub_x = s->out_x;
		s->pub_y = s->out_y;
		s->pub_off = s->offscreen;
		return;
	}

	if (!s->pub_init)
	{
		s->pub_init = true;
		s->pub_x = (p->xmin + p->xmax) / 2;
		s->pub_y = (p->ymin + p->ymax) / 2;
		s->pub_off = false;
	}

	if (s->win_open && (uint32_t)(now_ms - s->win_t0) > p->shot_ms) s->win_open = false;
}

void crtgun_set_trigger(crtgun_state *s, bool down, uint32_t now_ms, const crtgun_params *p)
{
	if (down && !s->trig && p->mode == 1)
	{
		// the rules' best estimate at this instant is the aim until the flash arrives
		update_rules(s, p, now_ms);
		s->pub_init = true;
		s->pub_x = s->out_x;
		s->pub_y = s->out_y;
		s->pub_off = s->offscreen;
		s->win_open = true;
		s->win_t0 = now_ms;
		s->win_n = 0;
	}

	if (down && !s->trig)
	{
		// Only a pull made while the gun is tracking can be followed through the game's flash.
		// A pull with no light (gun pointed off the screen, or at black) must stay as it is.
		if (crtgun_valid(s, p))
		{
			s->shot = true;
			s->shot_t = now_ms;
		}
	}
	s->trig = down;
}

static void update_rules(crtgun_state *s, const crtgun_params *p, uint32_t now_ms)
{
	if (s->shot && (uint32_t)(now_ms - s->shot_t) > p->shot_ms) s->shot = false;

	if (crtgun_valid(s, p))
	{
		s->seen = true;
		s->last_x = s->raw_x;
		s->last_y = s->raw_y;
		s->was_valid = true;
		s->out_x = s->raw_x;
		s->out_y = s->raw_y;
		s->offscreen = false;
		return;
	}

	// No light from here on.
	if (s->was_valid)
	{
		s->was_valid = false;
		s->lost_t = now_ms;
	}
	bool hold = false;
	if (s->seen)
	{
		if (s->shot) hold = true;                                                              // the game's own flash
		else if (is_interior(s, p) && (uint32_t)(now_ms - s->lost_t) <= p->dark_ms) hold = true; // dark frame
	}

	if (hold)
	{
		s->out_x = s->last_x;
		s->out_y = s->last_y;
		s->offscreen = false;
	}
	else
	{
		// One unit outside the calibrated rectangle: the core's pipeline clamps this to the edge value,
		// which every lightgun core already treats as "offscreen".
		s->out_x = p->xmin - 1;
		s->out_y = p->ymin - 1;
		s->offscreen = true;
	}
}

void crtgun_update(crtgun_state *s, const crtgun_params *p, uint32_t now_ms)
{
	update_rules(s, p, now_ms);
	publish(s, p, now_ms);
}

static int32_t median_n(const int32_t *v, int n)
{
	int32_t t[CRTGUN_BC_MAXN];
	if (n < 1) return 0;
	if (n > CRTGUN_BC_MAXN) n = CRTGUN_BC_MAXN;
	for (int i = 0; i < n; i++) t[i] = v[i];
	for (int i = 1; i < n; i++)
	{
		int32_t k = t[i];
		int j = i - 1;
		while (j >= 0 && t[j] > k) { t[j + 1] = t[j]; j--; }
		t[j + 1] = k;
	}
	return t[n / 2];
}

void crtgun_beacon_trigger(crtgun_state *s, const crtgun_params *p, bool down, uint32_t now_ms)
{
	if (!p->beacon) return;
	if (down && !s->bc_trig_in)
	{
		if (s->bc_pressed) s->bc_ev_release = true;       // the core still has the last press down: let it go so the next one is a new edge
		s->bc_trig_in = true;
		s->bc_phase = 1;
		s->bc_t0 = now_ms;
		s->bc_n = 0;
		s->bc_req = true;
		s->bc_pressed = false;
		s->bc_rel_pending = false;
		s->bc_ev_press = s->bc_ev_release = false;
	}
	else if (!down && s->bc_trig_in)
	{
		s->bc_trig_in = false;
		if (s->bc_pressed || s->bc_phase == 1) s->bc_rel_pending = true;     // the release follows the press, never before it
	}
}

void crtgun_beacon_poll(crtgun_state *s, const crtgun_params *p, uint32_t now_ms)
{
	if (!p->beacon) return;

	if (s->bc_phase == 1)
	{
		uint32_t dt = now_ms - s->bc_t0;
		bool now_valid = crtgun_valid(s, p);
		bool decide = (s->bc_n >= 2 && dt >= 20) || (dt >= CRTGUN_BC_SETTLE_MS && (s->bc_n > 0 || now_valid)) || dt >= CRTGUN_BC_GIVEUP_MS;
		if (decide)
		{
			// A steady gun sends nothing new (the kernel reports changes only), so what it last reported counts too.
			if (s->bc_n > 0)
			{
				s->pub_x = median_n(s->bc_x, s->bc_n);
				s->pub_y = median_n(s->bc_y, s->bc_n);
				s->pub_off = false;
			}
			else if (now_valid)
			{
				s->pub_x = s->raw_x;
				s->pub_y = s->raw_y;
				s->pub_off = false;
			}
			else
			{
				s->pub_off = true;              // the whole picture was lit and the gun saw none of it: it is not pointing at the screen
			}
			s->bc_req = false;
			s->bc_phase = 2;
			s->bc_hold_until = now_ms + CRTGUN_BC_HOLD_MS;
			s->bc_pressed = true;
			s->bc_press_t = now_ms;
			s->bc_ev_press = true;
		}
	}
	else if (s->bc_phase == 2)
	{
		if ((int32_t)(now_ms - s->bc_hold_until) >= 0) s->bc_phase = 0;           // the aim follows the gun again
	}

	if (s->bc_pressed && s->bc_rel_pending && (uint32_t)(now_ms - s->bc_press_t) >= CRTGUN_BC_MIN_PRESS_MS)
	{
		s->bc_rel_pending = false;
		s->bc_pressed = false;
		s->bc_ev_release = true;
	}
}

// One complete gun report has arrived (the SYN event): in mode 1 it may be part of the flash measurement.
void crtgun_report(crtgun_state *s, const crtgun_params *p, uint32_t now_ms)
{
	update_rules(s, p, now_ms);
	publish(s, p, now_ms);

	if (p->beacon && s->bc_phase == 1 && crtgun_valid(s, p) && s->bc_n < CRTGUN_BC_MAXN)
	{
		s->bc_x[s->bc_n] = s->raw_x;
		s->bc_y[s->bc_n] = s->raw_y;
		s->bc_n++;
	}
	crtgun_beacon_poll(s, p, now_ms);

	if (p->mode == 1 && s->win_open && crtgun_valid(s, p))
	{
		s->win_x[s->win_n] = s->raw_x;
		s->win_y[s->win_n] = s->raw_y;
		s->win_n++;
		s->pub_x = median3(s->win_x, s->win_n);
		s->pub_y = median3(s->win_y, s->win_n);
		s->pub_off = false;
		if (s->win_n >= CRTGUN_FLASH_N) s->win_open = false;     // the flash is in: hold it
	}
}

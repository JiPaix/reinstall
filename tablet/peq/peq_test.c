/*
 * Host test of peq.c (build.sh test): the series against libm, each filter
 * type against what it should do to a sine. With arguments (a control list
 * as android.sh passes it to module-ladspa-sink), prints that curve instead:
 *     ./build.sh curve "-4,1,120,4,1,0,440,0,1,…"
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "peq.c"

#define RATE 48000

static LADSPA_Data controls[PORTS];

/* Gain in dB of the current controls at hz, from the RMS of the second half
 * of a second of sine (the filters have settled by then). */
static double gain_at(double hz) {
	static LADSPA_Data x[RATE], y[RATE];
	const LADSPA_Descriptor *d = ladspa_descriptor(0);
	LADSPA_Handle h = d->instantiate(d, RATE);
	d->connect_port(h, IN, x);
	d->connect_port(h, OUT, y);
	for (int p = PREAMP; p < PORTS; p++)
		d->connect_port(h, p, &controls[p]);
	d->activate(h);
	for (int i = 0; i < RATE; i++)
		x[i] = 0.1 * sin(2 * M_PI * hz * i / RATE);
	d->run(h, RATE / 2); /* two blocks: the state carries over */
	d->connect_port(h, IN, x + RATE / 2);
	d->connect_port(h, OUT, y + RATE / 2);
	d->run(h, RATE / 2);
	d->cleanup(h);
	double in = 0, out = 0;
	for (int i = RATE / 2; i < RATE; i++)
		in += x[i] * x[i], out += y[i] * y[i];
	return 10 * log10(out / in);
}

static void set(const char *list) {
	memset(controls, 0, sizeof controls);
	for (int b = 0; b < BANDS; b++)
		controls[FIRST_BAND + 4 * b + 1] = 1000, controls[FIRST_BAND + 4 * b + 3] = 1;
	char *s = strdup(list), *tok, *save;
	int p = PREAMP;
	for (tok = strtok_r(s, ",", &save); tok && p < PORTS; tok = strtok_r(0, ",", &save))
		controls[p++] = atof(tok);
	free(s);
}

static int failed;

static void expect(const char *what, double hz, double want, double tolerance) {
	double got = gain_at(hz);
	if (fabs(got - want) > tolerance) {
		printf("FAIL %s at %g Hz: %.2f dB, want %.2f ± %.2f\n", what, hz, got, want, tolerance);
		failed = 1;
	}
}

static void below(const char *what, double hz, double max) {
	double got = gain_at(hz);
	if (got > max) {
		printf("FAIL %s at %g Hz: %.2f dB, want below %.2f\n", what, hz, got, max);
		failed = 1;
	}
}

int main(int argc, char **argv) {
	if (argc > 1) {
		/* module-ladspa-sink takes a full list or refuses to load: one value per
		 * control, no more, no less (a stray band stopped the tablet's daemon). */
		int values = 1;
		for (const char *c = argv[1]; *c; c++)
			values += *c == ',';
		if (values != PORTS - PREAMP) {
			fprintf(stderr, "%d values, the plugin has %d controls\n", values, PORTS - PREAMP);
			return 2;
		}
		set(argv[1]);
		double peak = -99;
		for (double hz = 20; hz <= 20000; hz *= 1.02) {
			double g = gain_at(hz);
			if (g > peak)
				peak = g;
		}
		static const double show[] = {40, 60, 80, 100, 120, 150, 200, 250, 300, 500, 1000, 2000, 3000, 4000, 5000, 8000, 10000, 12000, 16000};
		for (unsigned i = 0; i < sizeof show / sizeof *show; i++)
			printf("%6.0f Hz %+6.2f dB\n", show[i], gain_at(show[i]));
		printf("highest %+.2f dB\n", peak);
		return 0;
	}

	for (double x = -12; x <= 12; x += 0.37)
		if (fabs(xexp(x) - exp(x)) > 1e-9 * exp(x))
			printf("FAIL xexp(%g) = %.15g, want %.15g\n", x, xexp(x), exp(x)), failed = 1;
	for (double x = 0; x <= M_PI; x += 0.01)
		if (fabs(xsin(x) - sin(x)) > 1e-12 || fabs(xcos(x) - cos(x)) > 1e-12)
			printf("FAIL xsin/xcos(%g)\n", x), failed = 1;

	set("0");
	expect("all off", 50, 0, 0.01);
	expect("all off", 5000, 0, 0.01);
	set("-4");
	expect("preamp", 1000, -4, 0.01);
	set("0,1,1000,6,1");
	expect("peaking", 1000, 6, 0.05);
	expect("peaking", 100, 0, 0.3);
	expect("peaking", 10000, 0, 0.3);
	set("0,1,1000,-6,2");
	expect("peaking cut", 1000, -6, 0.05);
	set("0,2,100,6,0.707");
	expect("low shelf", 20, 6, 0.3);
	expect("low shelf", 100, 3, 0.1);
	expect("low shelf", 5000, 0, 0.1);
	set("0,3,8000,3,0.707");
	expect("high shelf", 18000, 3, 0.3);
	expect("high shelf", 8000, 1.5, 0.1);
	expect("high shelf", 200, 0, 0.1);
	set("0,4,100,0,0.707");
	expect("high-pass", 100, -3.01, 0.05);
	below("high-pass", 25, -23);
	expect("high-pass", 2000, 0, 0.05);
	set("0,5,5000,0,0.707");
	expect("low-pass", 5000, -3.01, 0.05);
	below("low-pass", 20000, -20);
	set("0,0,1000,12,1,1,1000,6,1"); /* band 1 off: only band 2 counts */
	expect("off band", 1000, 6, 0.05);
	set("0,9,1000,12,1"); /* an unknown type is off */
	expect("unknown type", 1000, 0, 0.01);

	/* A moved control takes effect at the next run, as module-ladspa-sink's
	 * D-Bus updates do. */
	{
		static LADSPA_Data x[256], y[256];
		const LADSPA_Descriptor *d = ladspa_descriptor(0);
		set("0");
		LADSPA_Handle h = d->instantiate(d, RATE);
		d->connect_port(h, IN, x);
		d->connect_port(h, OUT, y);
		for (int p = PREAMP; p < PORTS; p++)
			d->connect_port(h, p, &controls[p]);
		d->activate(h);
		for (int i = 0; i < 256; i++)
			x[i] = 0.5;
		d->run(h, 256);
		controls[PREAMP] = -6.0206;
		d->run(h, 256);
		if (fabs(y[255] - 0.25) > 1e-4)
			printf("FAIL moved preamp: %g, want 0.25\n", y[255]), failed = 1;
		d->cleanup(h);
	}
	/* Every instance freed goes back to the pool. */
	{
		const LADSPA_Descriptor *d = ladspa_descriptor(0);
		for (int i = 0; i < 3 * POOL; i++) {
			LADSPA_Handle h = d->instantiate(d, RATE);
			if (!h) {
				printf("FAIL pool exhausted after %d instances\n", i), failed = 1;
				break;
			}
			d->cleanup(h);
		}
	}
	if (ladspa_descriptor(1))
		printf("FAIL a second descriptor\n"), failed = 1;

	puts(failed ? "FAILED" : "ok");
	return failed;
}

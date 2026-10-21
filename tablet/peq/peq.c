/*
 * A parametric equalizer as a LADSPA plugin, for PulseAudio's
 * module-ladspa-sink on the tablet (android.sh). Termux packages no LADSPA
 * equalizer (only ladspa-sdk's examples), hence this one.
 *
 * Mono: module-ladspa-sink runs one instance per channel. Controls, in port
 * order (the module's control=… list): the preamp in dB, then six bands of
 * type, frequency (Hz), gain (dB) and Q. Types: 0 off, 1 peaking, 2 low
 * shelf, 3 high shelf, 4 high-pass, 5 low-pass (gain unused for the last
 * two). Biquads from the RBJ Audio EQ Cookbook.
 *
 * Built freestanding (build.sh): no libc, no libm, so one .so loads in any
 * Termux whatever its NDK level. Hence the series below in place of exp/sin/
 * cos, and a fixed pool of instances in place of malloc.
 */

#define BANDS 6
#define POOL 64
#define LN10 2.302585092994046
#define PI 3.141592653589793

/* The LADSPA 1.1 ABI, the part this plugin uses. */
typedef float LADSPA_Data;
typedef void *LADSPA_Handle;
typedef struct {
	int HintDescriptor;
	LADSPA_Data LowerBound, UpperBound;
} LADSPA_PortRangeHint;
typedef struct LADSPA_Descriptor {
	unsigned long UniqueID;
	const char *Label;
	int Properties;
	const char *Name, *Maker, *Copyright;
	unsigned long PortCount;
	const int *PortDescriptors;
	const char *const *PortNames;
	const LADSPA_PortRangeHint *PortRangeHints;
	void *ImplementationData;
	LADSPA_Handle (*instantiate)(const struct LADSPA_Descriptor *, unsigned long);
	void (*connect_port)(LADSPA_Handle, unsigned long, LADSPA_Data *);
	void (*activate)(LADSPA_Handle);
	void (*run)(LADSPA_Handle, unsigned long);
	void (*run_adding)(LADSPA_Handle, unsigned long);
	void (*set_run_adding_gain)(LADSPA_Handle, LADSPA_Data);
	void (*deactivate)(LADSPA_Handle);
	void (*cleanup)(LADSPA_Handle);
} LADSPA_Descriptor;

#define HARD_RT_CAPABLE 0x4
#define PORT_INPUT 0x1
#define PORT_OUTPUT 0x2
#define PORT_CONTROL 0x4
#define PORT_AUDIO 0x8
#define HINT_BELOW 0x1
#define HINT_ABOVE 0x2
#define HINT_LOG 0x10
#define HINT_INTEGER 0x20
#define HINT_DEFAULT_MIN 0x40
#define HINT_DEFAULT_0 0x200
#define HINT_DEFAULT_1 0x240
#define HINT_DEFAULT_440 0x2C0

enum { OFF, PEAK, LOW_SHELF, HIGH_SHELF, HIGH_PASS, LOW_PASS, TYPES };
enum { IN, OUT, PREAMP, FIRST_BAND, PORTS = FIRST_BAND + 4 * BANDS };

typedef struct {
	double b0, b1, b2, a1, a2, z1, z2;
} biquad;

typedef struct {
	int used, fresh; /* fresh: coefficients to make at the next run */
	double rate, gain;
	LADSPA_Data *port[PORTS];
	LADSPA_Data seen[PORTS]; /* the controls the coefficients were made from */
	biquad band[BANDS];
} instance;

static instance pool[POOL];

#ifdef __ANDROID__
/* The compiler calls memset to zero a struct, freestanding or not. volatile:
 * or it would turn this very loop into a call to itself. */
void *memset(void *d, int c, unsigned long n) {
	volatile unsigned char *p = d;
	while (n--)
		*p++ = (unsigned char)c;
	return d;
}
#endif

/* exp(x): halve x until small, a series, then square back. */
static double xexp(double x) {
	int halvings = 0;
	while (x > 0.5 || x < -0.5) {
		x /= 2;
		halvings++;
	}
	double sum = 1, term = 1;
	for (int n = 1; n < 20; n++) {
		term *= x / n;
		sum += term;
	}
	while (halvings--)
		sum *= sum;
	return sum;
}

/* sin and cos of 0 ≤ x ≤ π, all an angular frequency below Nyquist needs. */
static double xsin(double x) {
	double sum = x, term = x;
	for (int n = 1; n < 25; n++) {
		term *= -x * x / ((2 * n) * (2 * n + 1));
		sum += term;
	}
	return sum;
}

static double xcos(double x) {
	double sum = 1, term = 1;
	for (int n = 1; n < 25; n++) {
		term *= -x * x / ((2 * n - 1) * (2 * n));
		sum += term;
	}
	return sum;
}

static void design(biquad *f, int type, double rate, double hz, double db, double q) {
	if (hz < 10)
		hz = 10;
	if (hz > 0.45 * rate)
		hz = 0.45 * rate;
	if (q < 0.1)
		q = 0.1;
	double w = 2 * PI * hz / rate, c = xcos(w), alpha = xsin(w) / (2 * q);
	double A = xexp(db * LN10 / 40), sA = xexp(db * LN10 / 80);
	double b0 = 1, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;
	switch (type) {
	case PEAK:
		b0 = 1 + alpha * A, b1 = -2 * c, b2 = 1 - alpha * A;
		a0 = 1 + alpha / A, a1 = -2 * c, a2 = 1 - alpha / A;
		break;
	case LOW_SHELF:
		b0 = A * ((A + 1) - (A - 1) * c + 2 * sA * alpha);
		b1 = 2 * A * ((A - 1) - (A + 1) * c);
		b2 = A * ((A + 1) - (A - 1) * c - 2 * sA * alpha);
		a0 = (A + 1) + (A - 1) * c + 2 * sA * alpha;
		a1 = -2 * ((A - 1) + (A + 1) * c);
		a2 = (A + 1) + (A - 1) * c - 2 * sA * alpha;
		break;
	case HIGH_SHELF:
		b0 = A * ((A + 1) + (A - 1) * c + 2 * sA * alpha);
		b1 = -2 * A * ((A - 1) + (A + 1) * c);
		b2 = A * ((A + 1) + (A - 1) * c - 2 * sA * alpha);
		a0 = (A + 1) - (A - 1) * c + 2 * sA * alpha;
		a1 = 2 * ((A - 1) - (A + 1) * c);
		a2 = (A + 1) - (A - 1) * c - 2 * sA * alpha;
		break;
	case HIGH_PASS:
		b0 = (1 + c) / 2, b1 = -(1 + c), b2 = (1 + c) / 2;
		a0 = 1 + alpha, a1 = -2 * c, a2 = 1 - alpha;
		break;
	case LOW_PASS:
		b0 = (1 - c) / 2, b1 = 1 - c, b2 = (1 - c) / 2;
		a0 = 1 + alpha, a1 = -2 * c, a2 = 1 - alpha;
		break;
	}
	f->b0 = b0 / a0, f->b1 = b1 / a0, f->b2 = b2 / a0;
	f->a1 = a1 / a0, f->a2 = a2 / a0;
}

/* Coefficients again only when a control moved; the filters keep their state. */
static void update(instance *in) {
	int moved = in->fresh;
	in->fresh = 0;
	for (int p = PREAMP; p < PORTS; p++) {
		LADSPA_Data v = in->port[p] ? *in->port[p] : 0;
		if (v != in->seen[p])
			moved = 1;
		in->seen[p] = v;
	}
	if (!moved)
		return;
	in->gain = xexp(in->seen[PREAMP] * LN10 / 20);
	for (int b = 0; b < BANDS; b++) {
		LADSPA_Data *k = &in->seen[FIRST_BAND + 4 * b];
		int type = (int)k[0];
		biquad *f = &in->band[b];
		double z1 = f->z1, z2 = f->z2;
		design(f, type > OFF && type < TYPES ? type : OFF, in->rate, k[1], k[2], k[3]);
		f->z1 = z1, f->z2 = z2;
	}
}

static LADSPA_Handle instantiate(const LADSPA_Descriptor *d, unsigned long rate) {
	(void)d;
	for (int i = 0; i < POOL; i++) {
		instance *in = &pool[i];
		if (in->used)
			continue;
		*in = (instance){.used = 1, .fresh = 1, .rate = rate};
		return in;
	}
	return 0;
}

static void connect_port(LADSPA_Handle h, unsigned long port, LADSPA_Data *data) {
	if (port < PORTS)
		((instance *)h)->port[port] = data;
}

static void activate(LADSPA_Handle h) {
	instance *in = h;
	for (int b = 0; b < BANDS; b++)
		in->band[b].z1 = in->band[b].z2 = 0;
	in->fresh = 1;
}

static void run(LADSPA_Handle h, unsigned long frames) {
	instance *in = h;
	update(in);
	const LADSPA_Data *x = in->port[IN];
	LADSPA_Data *y = in->port[OUT];
	int active[BANDS], n = 0;
	for (int b = 0; b < BANDS; b++) {
		int type = (int)in->seen[FIRST_BAND + 4 * b];
		if (type > OFF && type < TYPES)
			active[n++] = b;
	}
	for (unsigned long i = 0; i < frames; i++) {
		double s = x[i] * in->gain;
		for (int j = 0; j < n; j++) {
			biquad *f = &in->band[active[j]];
			double o = f->b0 * s + f->z1;
			f->z1 = f->b1 * s - f->a1 * o + f->z2;
			f->z2 = f->b2 * s - f->a2 * o;
			s = o;
		}
		y[i] = (LADSPA_Data)s;
	}
	/* Denormals: the tails of a silence decay into them. */
	for (int b = 0; b < BANDS; b++) {
		biquad *f = &in->band[b];
		if (f->z1 < 1e-20 && f->z1 > -1e-20)
			f->z1 = 0;
		if (f->z2 < 1e-20 && f->z2 > -1e-20)
			f->z2 = 0;
	}
}

static void cleanup(LADSPA_Handle h) {
	((instance *)h)->used = 0;
}

static const char *const names[PORTS] = {
	"Input", "Output", "Preamp (dB)",
#define BAND(n) "Band " #n " type", "Band " #n " frequency (Hz)", "Band " #n " gain (dB)", "Band " #n " Q"
	BAND(1), BAND(2), BAND(3), BAND(4), BAND(5), BAND(6),
#undef BAND
};

#define CTL (PORT_INPUT | PORT_CONTROL)
static const int ports[PORTS] = {
	PORT_INPUT | PORT_AUDIO, PORT_OUTPUT | PORT_AUDIO, CTL,
	CTL, CTL, CTL, CTL, CTL, CTL, CTL, CTL, CTL, CTL, CTL, CTL,
	CTL, CTL, CTL, CTL, CTL, CTL, CTL, CTL, CTL, CTL, CTL, CTL,
};

#define DB {HINT_BELOW | HINT_ABOVE | HINT_DEFAULT_0, -24, 24}
#define TYPE {HINT_BELOW | HINT_ABOVE | HINT_INTEGER | HINT_DEFAULT_MIN, 0, TYPES - 1}
#define HZ {HINT_BELOW | HINT_ABOVE | HINT_LOG | HINT_DEFAULT_440, 10, 22000}
#define Q {HINT_BELOW | HINT_ABOVE | HINT_DEFAULT_1, 0.1, 10}
static const LADSPA_PortRangeHint hints[PORTS] = {
	{0, 0, 0}, {0, 0, 0}, DB,
	TYPE, HZ, DB, Q, TYPE, HZ, DB, Q, TYPE, HZ, DB, Q,
	TYPE, HZ, DB, Q, TYPE, HZ, DB, Q, TYPE, HZ, DB, Q,
};

static const LADSPA_Descriptor descriptor = {
	.UniqueID = 4790, /* unregistered: any free id will do on this tablet */
	.Label = "peq",
	.Properties = HARD_RT_CAPABLE,
	.Name = "Parametric EQ (6 bands)",
	.Maker = "reinstall (android.sh)",
	.Copyright = "None",
	.PortCount = PORTS,
	.PortDescriptors = ports,
	.PortNames = names,
	.PortRangeHints = hints,
	.instantiate = instantiate,
	.connect_port = connect_port,
	.activate = activate,
	.run = run,
	.cleanup = cleanup,
};

__attribute__((visibility("default"))) const LADSPA_Descriptor *ladspa_descriptor(unsigned long index) {
	return index == 0 ? &descriptor : 0;
}

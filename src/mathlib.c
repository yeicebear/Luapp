// mathlib.c
// math stuff that the c standard library technically has but
// you always end up rewriting anyway.
// vectors, matrices, lerp, easing curves, perlin noise, trig wrappers.
// nothing here requires sdl2 or threads. pure math, no dependencies.
// linkto "mathlib" — separate from stdlib on purpose.
// floats are all double (f64) because lpp has no f32 type.

#include <math.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define lpp_ptr intptr_t
#define PI 3.14159265358979323846


// ---- trig & basics ----
// just wrappers. yes you could call them via extern yourself. this is lazier.

double math_sin(double x)  { return sin(x); }
double math_cos(double x)  { return cos(x); }
double math_tan(double x)  { return tan(x); }
double math_asin(double x) { return asin(x); }
double math_acos(double x) { return acos(x); }
double math_atan(double x) { return atan(x); }
double math_atan2(double y, double x) { return atan2(y, x); }
double math_sqrt(double x) { return sqrt(x < 0 ? 0 : x); }
double math_abs(double x)  { return fabs(x); }
double math_floor(double x){ return floor(x); }
double math_ceil(double x) { return ceil(x); }
double math_round(double x){ return round(x); }
double math_pow(double b, double e) { return pow(b, e); }
double math_log(double x)  { return x > 0 ? log(x) : 0; }
double math_log2(double x) { return x > 0 ? log2(x) : 0; }
double math_exp(double x)  { return exp(x); }
double math_pi(void)       { return PI; }

// min/max/clamp for doubles. int versions too because you'll want them.
double math_min(double a, double b)            { return a < b ? a : b; }
double math_max(double a, double b)            { return a > b ? a : b; }
double math_clamp(double v, double lo, double hi){ return v < lo ? lo : (v > hi ? hi : v); }
int    math_min_int(int a, int b)              { return a < b ? a : b; }
int    math_max_int(int a, int b)              { return a > b ? a : b; }
int    math_clamp_int(int v, int lo, int hi)   { return v < lo ? lo : (v > hi ? hi : v); }

// linear interpolation. t=0 returns a, t=1 returns b, anything in between is smooth.
double math_lerp(double a, double b, double t) { return a + (b - a) * t; }

// map a value from one range to another. classic "remap" utility.
double math_remap(double v, double in_lo, double in_hi, double out_lo, double out_hi) {
    if (in_hi == in_lo) return out_lo;
    double t = (v - in_lo) / (in_hi - in_lo);
    return out_lo + t * (out_hi - out_lo);
}

// degrees <-> radians because everyone forgets which way this goes
double math_deg(double r) { return r * (180.0 / PI); }
double math_rad(double d) { return d * (PI / 180.0); }

// distance between two 2d points
double math_dist2(double x1, double y1, double x2, double y2) {
    double dx = x2 - x1, dy = y2 - y1;
    return sqrt(dx*dx + dy*dy);
}

// distance between two 3d points
double math_dist3(double x1, double y1, double z1, double x2, double y2, double z2) {
    double dx = x2-x1, dy = y2-y1, dz = z2-z1;
    return sqrt(dx*dx + dy*dy + dz*dz);
}


// ---- easing functions ----
// all take t in [0,1] and return a value in [0,1].
// they're just math — no allocations, no state.
// these are the ones robert penner published forever ago. everyone uses them.

double math_ease_in_quad(double t)   { return t*t; }
double math_ease_out_quad(double t)  { return t*(2-t); }
double math_ease_inout_quad(double t){ return t<0.5 ? 2*t*t : -1+(4-2*t)*t; }

double math_ease_in_cubic(double t)  { return t*t*t; }
double math_ease_out_cubic(double t) { double f=t-1; return f*f*f+1; }
double math_ease_inout_cubic(double t){
    return t<0.5 ? 4*t*t*t : (t-1)*(2*t-2)*(2*t-2)+1;
}

double math_ease_in_sine(double t)   { return 1 - cos(t * PI / 2); }
double math_ease_out_sine(double t)  { return sin(t * PI / 2); }
double math_ease_inout_sine(double t){ return -(cos(PI*t)-1)/2; }

double math_ease_in_elastic(double t){
    if (t == 0 || t == 1) return t;
    return -pow(2, 10*t-10) * sin((t*10-10.75) * (2*PI/3));
}
double math_ease_out_elastic(double t){
    if (t == 0 || t == 1) return t;
    return pow(2, -10*t) * sin((t*10-0.75) * (2*PI/3)) + 1;
}


// ---- 2d vector ----
// stored on the heap as two doubles (16 bytes).
// functions return a new vec2 handle or modify through a pointer.
// yes you could just use two floats. sometimes you want to pass a vec2 around.

typedef struct { double x, y; } lpp_vec2;

lpp_ptr math_vec2_new(double x, double y) {
    lpp_vec2 *v = malloc(sizeof(lpp_vec2));
    if (!v) return 0;
    v->x = x; v->y = y;
    return (lpp_ptr)v;
}

double math_vec2_x(lpp_ptr h) { return h ? ((lpp_vec2*)h)->x : 0; }
double math_vec2_y(lpp_ptr h) { return h ? ((lpp_vec2*)h)->y : 0; }

void math_vec2_set(lpp_ptr h, double x, double y) {
    if (!h) return;
    ((lpp_vec2*)h)->x = x;
    ((lpp_vec2*)h)->y = y;
}

// returns a NEW vec2 (caller must free it)
lpp_ptr math_vec2_add(lpp_ptr a, lpp_ptr b) {
    if (!a || !b) return 0;
    lpp_vec2 *va = (lpp_vec2*)a, *vb = (lpp_vec2*)b;
    return math_vec2_new(va->x + vb->x, va->y + vb->y);
}

lpp_ptr math_vec2_sub(lpp_ptr a, lpp_ptr b) {
    if (!a || !b) return 0;
    lpp_vec2 *va = (lpp_vec2*)a, *vb = (lpp_vec2*)b;
    return math_vec2_new(va->x - vb->x, va->y - vb->y);
}

lpp_ptr math_vec2_scale(lpp_ptr a, double s) {
    if (!a) return 0;
    lpp_vec2 *v = (lpp_vec2*)a;
    return math_vec2_new(v->x * s, v->y * s);
}

double math_vec2_dot(lpp_ptr a, lpp_ptr b) {
    if (!a || !b) return 0;
    lpp_vec2 *va = (lpp_vec2*)a, *vb = (lpp_vec2*)b;
    return va->x*vb->x + va->y*vb->y;
}

double math_vec2_len(lpp_ptr a) {
    if (!a) return 0;
    lpp_vec2 *v = (lpp_vec2*)a;
    return sqrt(v->x*v->x + v->y*v->y);
}

// returns a new normalized vec2. the original is untouched.
lpp_ptr math_vec2_norm(lpp_ptr a) {
    if (!a) return 0;
    lpp_vec2 *v = (lpp_vec2*)a;
    double len = sqrt(v->x*v->x + v->y*v->y);
    if (len == 0) return math_vec2_new(0, 0);
    return math_vec2_new(v->x/len, v->y/len);
}

// the 2d "cross product" — really just the z component of the 3d cross.
// useful for checking which side of a line a point is on.
double math_vec2_cross(lpp_ptr a, lpp_ptr b) {
    if (!a || !b) return 0;
    lpp_vec2 *va = (lpp_vec2*)a, *vb = (lpp_vec2*)b;
    return va->x*vb->y - va->y*vb->x;
}

void math_vec2_free(lpp_ptr h) { if (h) free((void*)h); }


// ---- 3d vector ----
// same pattern as vec2 but with a z component.

typedef struct { double x, y, z; } lpp_vec3;

lpp_ptr math_vec3_new(double x, double y, double z) {
    lpp_vec3 *v = malloc(sizeof(lpp_vec3));
    if (!v) return 0;
    v->x = x; v->y = y; v->z = z;
    return (lpp_ptr)v;
}

double math_vec3_x(lpp_ptr h) { return h ? ((lpp_vec3*)h)->x : 0; }
double math_vec3_y(lpp_ptr h) { return h ? ((lpp_vec3*)h)->y : 0; }
double math_vec3_z(lpp_ptr h) { return h ? ((lpp_vec3*)h)->z : 0; }

lpp_ptr math_vec3_add(lpp_ptr a, lpp_ptr b) {
    if (!a || !b) return 0;
    lpp_vec3 *va=(lpp_vec3*)a, *vb=(lpp_vec3*)b;
    return math_vec3_new(va->x+vb->x, va->y+vb->y, va->z+vb->z);
}

lpp_ptr math_vec3_sub(lpp_ptr a, lpp_ptr b) {
    if (!a || !b) return 0;
    lpp_vec3 *va=(lpp_vec3*)a, *vb=(lpp_vec3*)b;
    return math_vec3_new(va->x-vb->x, va->y-vb->y, va->z-vb->z);
}

lpp_ptr math_vec3_scale(lpp_ptr a, double s) {
    if (!a) return 0;
    lpp_vec3 *v=(lpp_vec3*)a;
    return math_vec3_new(v->x*s, v->y*s, v->z*s);
}

double math_vec3_dot(lpp_ptr a, lpp_ptr b) {
    if (!a || !b) return 0;
    lpp_vec3 *va=(lpp_vec3*)a, *vb=(lpp_vec3*)b;
    return va->x*vb->x + va->y*vb->y + va->z*vb->z;
}

// cross product: the vector perpendicular to both a and b.
// order matters — a x b != b x a.
lpp_ptr math_vec3_cross(lpp_ptr a, lpp_ptr b) {
    if (!a || !b) return 0;
    lpp_vec3 *va=(lpp_vec3*)a, *vb=(lpp_vec3*)b;
    return math_vec3_new(
        va->y*vb->z - va->z*vb->y,
        va->z*vb->x - va->x*vb->z,
        va->x*vb->y - va->y*vb->x
    );
}

double math_vec3_len(lpp_ptr a) {
    if (!a) return 0;
    lpp_vec3 *v=(lpp_vec3*)a;
    return sqrt(v->x*v->x + v->y*v->y + v->z*v->z);
}

lpp_ptr math_vec3_norm(lpp_ptr a) {
    if (!a) return 0;
    lpp_vec3 *v=(lpp_vec3*)a;
    double len = sqrt(v->x*v->x + v->y*v->y + v->z*v->z);
    if (len == 0) return math_vec3_new(0, 0, 0);
    return math_vec3_new(v->x/len, v->y/len, v->z/len);
}

void math_vec3_free(lpp_ptr h) { if (h) free((void*)h); }


// ---- 4x4 matrix ----
// stored as 16 doubles in row-major order on the heap.
// the kind of matrix you need for 3d transformations.
// multiply order: M * v (column vector on the right), left-to-right for transforms.

typedef struct { double m[16]; } lpp_mat4;

lpp_ptr math_mat4_identity(void) {
    lpp_mat4 *m = calloc(1, sizeof(lpp_mat4));
    if (!m) return 0;
    m->m[0] = m->m[5] = m->m[10] = m->m[15] = 1.0;
    return (lpp_ptr)m;
}

// get/set by row and column (0-indexed)
double math_mat4_get(lpp_ptr h, int row, int col) {
    if (!h || row<0||row>3||col<0||col>3) return 0;
    return ((lpp_mat4*)h)->m[row*4+col];
}

void math_mat4_set(lpp_ptr h, int row, int col, double v) {
    if (!h || row<0||row>3||col<0||col>3) return;
    ((lpp_mat4*)h)->m[row*4+col] = v;
}

// standard 3d transform matrices
lpp_ptr math_mat4_translate(double tx, double ty, double tz) {
    lpp_mat4 *m = calloc(1, sizeof(lpp_mat4));
    if (!m) return 0;
    m->m[0]=1; m->m[5]=1; m->m[10]=1; m->m[15]=1;
    m->m[3]=tx; m->m[7]=ty; m->m[11]=tz;
    return (lpp_ptr)m;
}

lpp_ptr math_mat4_scale(double sx, double sy, double sz) {
    lpp_mat4 *m = calloc(1, sizeof(lpp_mat4));
    if (!m) return 0;
    m->m[0]=sx; m->m[5]=sy; m->m[10]=sz; m->m[15]=1;
    return (lpp_ptr)m;
}

lpp_ptr math_mat4_rot_z(double angle_rad) {
    lpp_mat4 *m = calloc(1, sizeof(lpp_mat4));
    if (!m) return 0;
    double c = cos(angle_rad), s = sin(angle_rad);
    m->m[0]=c;  m->m[1]=-s;
    m->m[4]=s;  m->m[5]=c;
    m->m[10]=1; m->m[15]=1;
    return (lpp_ptr)m;
}

// matrix multiplication: returns a NEW mat4 = a * b
lpp_ptr math_mat4_mul(lpp_ptr ah, lpp_ptr bh) {
    if (!ah || !bh) return 0;
    double *a = ((lpp_mat4*)ah)->m;
    double *b = ((lpp_mat4*)bh)->m;
    lpp_mat4 *c = calloc(1, sizeof(lpp_mat4));
    if (!c) return 0;
    for (int r = 0; r < 4; r++)
        for (int col = 0; col < 4; col++)
            for (int k = 0; k < 4; k++)
                c->m[r*4+col] += a[r*4+k] * b[k*4+col];
    return (lpp_ptr)c;
}

void math_mat4_free(lpp_ptr h) { if (h) free((void*)h); }


// ---- perlin noise ----
// classic ken perlin gradient noise.
// returns values roughly in [-1, 1] (not exactly, don't trust the edges).
// seed it once with math_noise_seed(), then call math_noise2 or math_noise3.
// the permutation table is global — not thread-safe. if you care, use a mutex.

static int perm[512];
static int perm_seeded = 0;

void math_noise_seed(int seed) {
    srand((unsigned)seed);
    int p[256];
    for (int i = 0; i < 256; i++) p[i] = i;
    // fisher-yates shuffle
    for (int i = 255; i > 0; i--) {
        int j = rand() % (i+1);
        int tmp = p[i]; p[i] = p[j]; p[j] = tmp;
    }
    for (int i = 0; i < 512; i++) perm[i] = p[i & 255];
    perm_seeded = 1;
}

static double lpp_fade(double t) { return t*t*t*(t*(t*6-15)+10); }
static double lpp_grad2(int h, double x, double y) {
    int hh = h & 3;
    double u = hh < 2 ? x : y;
    double v = hh < 2 ? y : x;
    return ((hh & 1) ? -u : u) + ((hh & 2) ? -v : v);
}

double math_noise2(double x, double y) {
    if (!perm_seeded) math_noise_seed(42);
    int xi = (int)floor(x) & 255;
    int yi = (int)floor(y) & 255;
    double xf = x - floor(x);
    double yf = y - floor(y);
    double u = lpp_fade(xf);
    double v = lpp_fade(yf);
    int aa = perm[perm[xi]   + yi];
    int ab = perm[perm[xi]   + yi+1];
    int ba = perm[perm[xi+1] + yi];
    int bb = perm[perm[xi+1] + yi+1];
    double x1 = math_lerp(lpp_grad2(aa,xf,yf),   lpp_grad2(ba,xf-1,yf),   u);
    double x2 = math_lerp(lpp_grad2(ab,xf,yf-1), lpp_grad2(bb,xf-1,yf-1), u);
    return math_lerp(x1, x2, v);
}

// octave noise: layers multiple noise calls at increasing frequency and decreasing amplitude.
// octaves=6, persistence=0.5 is a typical starting point for terrain.
double math_noise2_octaves(double x, double y, int octaves, double persistence) {
    double total = 0, freq = 1, amp = 1, max_val = 0;
    for (int i = 0; i < octaves; i++) {
        total   += math_noise2(x*freq, y*freq) * amp;
        max_val += amp;
        amp     *= persistence;
        freq    *= 2;
    }
    return total / max_val;
}

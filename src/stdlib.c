// stdlib.c
// the core runtime helpers. no sdl2, no threads, no math beyond rand.
// if you need any of those, that's what the other libs are for.
// linkto "std" to get all of this. it's the base kit.
//
// a note on lpp_ptr: lpp's "long" type maps to intptr_t in C.
// on 64-bit linux/mac, C's "long" happens to also be 64 bits so it works fine.
// on windows with mingw, "long" is 32 bits even on 64-bit systems, which silently
// truncates pointers. intptr_t is always exactly pointer-sized on every platform.
// that's the only reason this typedef exists. it's not exciting.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>

#define lpp_ptr intptr_t

#ifdef _WIN32
#include <windows.h>
static void lpp_sleep_impl(int ms) { Sleep(ms > 0 ? ms : 0); }
#else
static void lpp_sleep_impl(int ms) {
    struct timespec t = { ms/1000, (ms%1000)*1000000L };
    nanosleep(&t, NULL);
}
#endif

static int lpp_seeded = 0;


// ---- printing ----
// these are the functions the compiler calls when you write print() in lpp.
// print_int is the default. the others you call by name.

void print_int(int x)         { printf("%d\n", x); }
void print_float(double x)    { printf("%f\n", x); }
void print_long(lpp_ptr x)    { printf("%lld\n", (long long)x); }
void print_str(const char *s) { if (s) puts(s); }
void print_char(int c)        { putchar(c); }


// ---- input ----
// blocks the entire program while waiting. no async here.

int input_int(void) {
    int v = 0;
    if (scanf("%d", &v) != 1) {
        int c;
        while ((c = getchar()) != '\n' && c != EOF) {}
    }
    return v;
}

int input_char(void) { return getchar(); }


// ---- random ----
// seeds from wall clock on first use. not cryptographic. don't use this for passwords.

int rand_int(int mn, int mx) {
    if (!lpp_seeded) { srand((unsigned)time(NULL)); lpp_seeded = 1; }
    if (mx <= mn) return mn;
    return mn + rand() % (mx - mn + 1);
}


// ---- time ----

int time_ms(void) {
#ifdef _WIN32
    return (int)GetTickCount();
#else
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
#endif
}

int sleep_ms(int ms) {
    if (ms <= 0) return 0;
    lpp_sleep_impl(ms);
    return 0;
}


// ---- string helpers ----
// lpp strings are just C char* pointers. these functions let you inspect them.
// you can't mutate them safely — use the string builder (sb_*) for that.

int str_len(const char *s)              { return s ? (int)strlen(s) : 0; }
int str_get(const char *s, int i)       { return (!s||i<0||i>=(int)strlen(s)) ? -1 : (unsigned char)s[i]; }
int str_cmp(const char *a, const char *b){ return (!a||!b) ? -1 : strcmp(a,b); }


// ---- file i/o ----
// file handles are lpp_ptr (intptr_t) rather than long because on windows
// sizeof(long) < sizeof(FILE*). this is the same reason as lpp_ptr itself.
// open → read or write → close. don't leave files open. you know this.

lpp_ptr file_open(const char *path, const char *mode) {
    FILE *f = fopen(path, mode);
    return (lpp_ptr)f;
}

int file_close(lpp_ptr fp)              { return fp ? fclose((FILE*)fp) : -1; }
int file_read_char(lpp_ptr fp)          { return fp ? fgetc((FILE*)fp) : -1; }
int file_write_char(lpp_ptr fp, int c)  { return fp ? fputc(c, (FILE*)fp) : -1; }
int file_write_str(lpp_ptr fp, const char *s) { return (fp&&s) ? fputs(s,(FILE*)fp) : -1; }
int file_write_int(lpp_ptr fp, int n)   { return fp ? fprintf((FILE*)fp, "%d", n) : -1; }
int file_eof(lpp_ptr fp)                { return fp ? feof((FILE*)fp) : 1; }


// ---- dynamic arrays ----
// a minimal growable vector. element size is fixed at creation time.
// the header lives just before the data pointer:
//   [len: long][cap: long][elemsize: long][data...]
// you pass around the data pointer (a long in lpp). the header is invisible.
// when realloc moves the block, the data pointer changes — that's why push
// functions return the (possibly new) pointer. always use the returned value.

#define LPP_ARR_HDR 24

typedef struct {
    long len, cap, elemsize;
    char data[];
} lpp_dynarray;

static lpp_dynarray *lpp_arr_hdr(lpp_ptr data) {
    return (lpp_dynarray*)(data - LPP_ARR_HDR);
}

lpp_ptr arr_new(int elemsize) {
    long cap = 8;
    lpp_dynarray *a = malloc(sizeof(lpp_dynarray) + cap * elemsize);
    if (!a) return 0;
    a->len = 0; a->cap = cap; a->elemsize = elemsize;
    return (lpp_ptr)a->data;
}

lpp_ptr arr_push_int(lpp_ptr data, int val) {
    lpp_dynarray *a = lpp_arr_hdr(data);
    if (a->len >= a->cap) {
        a->cap *= 2;
        a = realloc(a, sizeof(lpp_dynarray) + a->cap * a->elemsize);
        if (!a) return 0;
        data = (lpp_ptr)a->data;
    }
    ((int*)a->data)[a->len++] = val;
    return data;
}

lpp_ptr arr_push_long(lpp_ptr data, lpp_ptr val) {
    lpp_dynarray *a = lpp_arr_hdr(data);
    if (a->len >= a->cap) {
        a->cap *= 2;
        a = realloc(a, sizeof(lpp_dynarray) + a->cap * a->elemsize);
        if (!a) return 0;
        data = (lpp_ptr)a->data;
    }
    ((lpp_ptr*)a->data)[a->len++] = val;
    return data;
}

lpp_ptr arr_push_float(lpp_ptr data, double val) {
    lpp_dynarray *a = lpp_arr_hdr(data);
    if (a->len >= a->cap) {
        a->cap *= 2;
        a = realloc(a, sizeof(lpp_dynarray) + a->cap * a->elemsize);
        if (!a) return 0;
        data = (lpp_ptr)a->data;
    }
    ((double*)a->data)[a->len++] = val;
    return data;
}

int arr_len(lpp_ptr data) {
    return data ? (int)lpp_arr_hdr(data)->len : 0;
}

void arr_free(lpp_ptr data) {
    if (data) free(lpp_arr_hdr(data));
}


// ---- raw memory ----
// direct malloc/free/memcpy wrappers for when you know what you're doing.
// mem_alloc returns zeroed memory (calloc). don't assume it stays zero.

lpp_ptr mem_alloc(int n)                            { return n>0 ? (lpp_ptr)calloc(1,n) : 0; }
void    mem_free(lpp_ptr ptr)                       { if (ptr) free((void*)ptr); }
void    mem_copy(lpp_ptr dst, lpp_ptr src, int n)   { if (dst&&src&&n>0) memcpy((void*)dst,(const void*)src,n); }
void    mem_move(lpp_ptr dst, lpp_ptr src, int n)   { if (dst&&src&&n>0) memmove((void*)dst,(const void*)src,n); }
void    mem_set(lpp_ptr ptr, int val, int n)        { if (ptr&&n>0) memset((void*)ptr, val&0xFF, n); }


// ---- string builder ----
// for when you need to build a string piece by piece without doing it manually.
// sb_new() → sb_append() as many times as you want → sb_get() → sb_free().
// sb_get() returns a pointer into the builder's internal buffer.
// if you need the string to outlive the builder, copy it yourself.
//
// the layout: [len: int][cap: int][data...] — header just before the data pointer.

#define LPP_SB_HDR 8

typedef struct { int len, cap; char data[]; } lpp_sb;
static lpp_sb *lpp_sb_hdr(lpp_ptr h) { return (lpp_sb*)(h - LPP_SB_HDR); }

lpp_ptr sb_new(void) {
    int cap = 64;
    lpp_sb *sb = malloc(LPP_SB_HDR + cap + 1);
    if (!sb) return 0;
    sb->len = 0; sb->cap = cap; sb->data[0] = '\0';
    return (lpp_ptr)sb->data;
}

lpp_ptr sb_append(lpp_ptr h, const char *s) {
    if (!h || !s) return h;
    int n = (int)strlen(s);
    lpp_sb *sb = lpp_sb_hdr(h);
    if (sb->len + n > sb->cap) {
        int ncap = sb->cap;
        while (ncap < sb->len + n) ncap *= 2;
        sb = realloc(sb, LPP_SB_HDR + ncap + 1);
        if (!sb) return 0;
        sb->cap = ncap;
        h = (lpp_ptr)sb->data;
    }
    memcpy(sb->data + sb->len, s, n + 1);
    sb->len += n;
    return h;
}

const char *sb_get(lpp_ptr h) { return h ? lpp_sb_hdr(h)->data : ""; }
void        sb_free(lpp_ptr h){ if (h) free(lpp_sb_hdr(h)); }

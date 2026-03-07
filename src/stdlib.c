// lpp standard library
// the stuff that doesn't need SDL2. just C, stdio, and a little malloc.
// compiled into your program when you write: linkto "std"
// you need to declare whatever you use with extern func in your lpp file.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>


void print_int(int x)         { printf("%d\n", x); }
void print_float(double x)    { printf("%f\n", x); }
void print_str(const char *s) { if (s) puts(s); }
void print_char(int c)        { putchar(c); }
void print_long(long x)       { printf("%ld\n", x); }


int input_int(void) {
    int v = 0;
    if (scanf("%d", &v) != 1) {
        // eat leftover junk so the next read doesn't fail too
        int c; while ((c = getchar()) != '\n' && c != EOF) {}
    }
    return v;
}

// returns the ASCII value of one character from stdin.
// returns -1 on EOF, same as fgetc.
int input_char(void) {
    return getchar();
}


static int lpp_seeded = 0;

// rand_int(min, max) — inclusive on both ends.
// seeds from the clock the first time you call it.
int rand_int(int mn, int mx) {
    if (!lpp_seeded) { srand((unsigned)time(NULL)); lpp_seeded = 1; }
    if (mx <= mn) return mn;
    return mn + rand() % (mx - mn + 1);
}

// milliseconds since program started (approximately)
int time_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
}

// sleep for ms milliseconds. blocks the whole program, obviously.
int sleep_ms(int ms) {
    if (ms <= 0) return 0;
    struct timespec t = { ms/1000, (ms%1000)*1000000L };
    nanosleep(&t, NULL);
    return 0;
}

// these are pretty basic. real string manipulation is coming once lpp has
// proper byte arrays. for now you get length, indexing, and comparison.

// number of characters, not including the null terminator
int str_len(const char *s) { return s ? (int)strlen(s) : 0; }

// get the ASCII value of the character at index i
// returns -1 if out of bounds. no crashing, just -1.
int str_get(const char *s, int i) {
    if (!s || i < 0 || i >= (int)strlen(s)) return -1;
    return (unsigned char)s[i];
}

// returns 0 if equal, nonzero if not. same as C strcmp.
int str_cmp(const char *a, const char *b) {
    if (!a || !b) return -1;
    return strcmp(a, b);
}

// files are represented as long (which is really a FILE* cast to long).
// not pretty but it works and lpp doesn't have pointers yet.

// open a file. mode is "r", "w", "a" etc — same as fopen.
// returns 0 if it failed.
long file_open(const char *path, const char *mode) {
    FILE *f = fopen(path, mode);
    return (long)f;
}

int file_close(long fptr) {
    if (!fptr) return -1;
    return fclose((FILE*)fptr);
}

// read one character. returns -1 on EOF.
int file_read_char(long fptr) {
    if (!fptr) return -1;
    return fgetc((FILE*)fptr);
}

int file_write_char(long fptr, int c) {
    if (!fptr) return -1;
    return fputc(c, (FILE*)fptr);
}

int file_write_str(long fptr, const char *s) {
    if (!fptr || !s) return -1;
    return fputs(s, (FILE*)fptr);
}

// returns 1 if at end of file, 0 otherwise
int file_eof(long fptr) {
    if (!fptr) return 1;
    return feof((FILE*)fptr);
}

int file_write_int(long fptr, int n) {
    if (!fptr) return -1;
    return fprintf((FILE*)fptr, "%d", n);
}

// ─── dynamic arrays ───────────────────────────────────────────────────────────
// a growable array on the heap. uses a simple header + data layout:
//   [len: int64][cap: int64][elemsize: int64][...data...]
//
// arr_new returns a pointer to the DATA section, not the header.
// this means arr[i] pointer arithmetic works correctly in lpp codegen.
// the stdlib functions get the header back by subtracting 24 bytes.
//
// yes this is basically a hand-rolled std::vector. no i'm not sorry.

#define LPP_ARR_HDR 24  // 3 x 8-byte fields before data

typedef struct {
    long len;
    long cap;
    long elemsize;
    char data[];
} lpp_dynarray;

// create a new empty dynamic array. elemsize is bytes per element: 4 for int/char, 8 for float/long/str
long arr_new(int elemsize) {
    long cap = 8;  // start with 8 elements, doubles each time we run out
    lpp_dynarray *a = malloc(sizeof(lpp_dynarray) + cap * elemsize);
    if (!a) return 0;
    a->len      = 0;
    a->cap      = cap;
    a->elemsize = elemsize;
    return (long)a->data;
}

static lpp_dynarray *lpp_arr_hdr(long data) {
    return (lpp_dynarray*)(data - LPP_ARR_HDR);
}

// push an int (or char) value onto the end of the array.
// returns the (possibly new) data pointer — always update your variable with the return value.
long arr_push_int(long data, int val) {
    lpp_dynarray *a = lpp_arr_hdr(data);
    if (a->len >= a->cap) {
        a->cap *= 2;
        a = realloc(a, sizeof(lpp_dynarray) + a->cap * a->elemsize);
        if (!a) return 0;
        data = (long)a->data;
    }
    ((int*)a->data)[a->len] = val;
    a->len++;
    return data;
}

// push a float (double) value
long arr_push_float(long data, double val) {
    lpp_dynarray *a = lpp_arr_hdr(data);
    if (a->len >= a->cap) {
        a->cap *= 2;
        a = realloc(a, sizeof(lpp_dynarray) + a->cap * a->elemsize);
        if (!a) return 0;
        data = (long)a->data;
    }
    ((double*)a->data)[a->len] = val;
    a->len++;
    return data;
}

// push a long value (also works for string pointers)
long arr_push_long(long data, long val) {
    lpp_dynarray *a = lpp_arr_hdr(data);
    if (a->len >= a->cap) {
        a->cap *= 2;
        a = realloc(a, sizeof(lpp_dynarray) + a->cap * a->elemsize);
        if (!a) return 0;
        data = (long)a->data;
    }
    ((long*)a->data)[a->len] = val;
    a->len++;
    return data;
}

// how many elements are in the array right now
int arr_len(long data) {
    if (!data) return 0;
    return (int)lpp_arr_hdr(data)->len;
}

// free the whole array. don't use it after this.
void arr_free(long data) {
    if (!data) return;
    free(lpp_arr_hdr(data));
}

// get element at index. returns 0 if out of bounds.
int arr_get_int(long data, int i) {
    if (!data) return 0;
    lpp_dynarray *a = lpp_arr_hdr(data);
    if (i < 0 || i >= a->len) return 0;
    return ((int*)a->data)[i];
}

double arr_get_float(long data, int i) {
    if (!data) return 0;
    lpp_dynarray *a = lpp_arr_hdr(data);
    if (i < 0 || i >= a->len) return 0;
    return ((double*)a->data)[i];
}

// set element at index. silently does nothing if out of bounds.
void arr_set_int(long data, int i, int val) {
    if (!data) return;
    lpp_dynarray *a = lpp_arr_hdr(data);
    if (i < 0 || i >= a->len) return;
    ((int*)a->data)[i] = val;
}

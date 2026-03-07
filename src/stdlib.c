#include <stdio.h>
#include <stdlib.h>
#include <time.h>

void print_int(int x) { printf("%d\n", x); }
void print_str(const char *s) { puts(s); }

int input_int(void) {
    int v = 0;
    if (scanf("%d", &v) != 1) {
        int c;
        while ((c = getchar()) != '\n' && c != EOF) {}
    }
    return v;
}

static int seeded = 0;
int rand_int(int mn, int mx) {
    if (!seeded) { srand((unsigned)time(NULL)); seeded = 1; }
    if (mx <= mn) return mn;
    return mn + rand() % (mx - mn + 1);
}

int time_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
}

int sleep_ms(int ms) {
    if (ms <= 0) return 0;
    struct timespec t = { ms/1000, (ms%1000)*1000000L };
    nanosleep(&t, NULL);
    return 0;
}

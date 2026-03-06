#include <stdio.h>
#include <stdlib.h>

/* print_int / print_str are the only runtime builtins right now */

void print_int(int x) {
    printf("%d\n", x);
}

void print_str(const char *s) {
    puts(s);
}

extern int lang_main();

int main() {
    return lang_main();
}
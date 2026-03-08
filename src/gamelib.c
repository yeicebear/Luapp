// lpp gamelib
// SDL2 canvas + mouse + keyboard for making games.
// compiled into your program when you write: linkto "gamelib"
// you need SDL2 and SDL2_ttf installed. lpp will try to install them for you
// but if it fails just do it yourself, it's like one apt command.
//
// also duplicates print_int, rand_int, sleep_ms etc from stdlib
// so you don't have to linkto both. games need those too.


#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>

static SDL_Window   *win  = NULL;
static SDL_Renderer *ren  = NULL;
static TTF_Font     *font = NULL;
static int running = 0;


// open a window. call this first before anything else.
int canvas_init(int w, int h) {
    SDL_Init(SDL_INIT_VIDEO);
    TTF_Init();
    win = SDL_CreateWindow("lpp", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                           w, h, SDL_WINDOW_SHOWN);
    ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    running = 1;
    return 0;
}

// load a font from a ttf file. you need a font file on disk.
// returns 0 on success, -1 if it couldn't find the file.
int canvas_font(const char *path, int size) {
    font = TTF_OpenFont(path, size);
    return font ? 0 : -1;
}

// fill the whole screen with one color. call at the start of every frame.
int canvas_clear(int r, int g, int b) {
    SDL_SetRenderDrawColor(ren, r, g, b, 255);
    SDL_RenderClear(ren);
    return 0;
}

// set the current draw color for rects, lines, pixels
int canvas_color(int r, int g, int b) {
    SDL_SetRenderDrawColor(ren, r, g, b, 255);
    return 0;
}

// filled rectangle using the current color
int canvas_rect(int x, int y, int w, int h) {
    SDL_Rect r = {x, y, w, h};
    SDL_RenderFillRect(ren, &r);
    return 0;
}

// outline rectangle (no fill)
int canvas_rect_outline(int x, int y, int w, int h) {
    SDL_Rect r = {x, y, w, h};
    SDL_RenderDrawRect(ren, &r);
    return 0;
}

// single pixel
int canvas_pixel(int x, int y) {
    SDL_RenderDrawPoint(ren, x, y);
    return 0;
}

// line from (x1,y1) to (x2,y2)
int canvas_line(int x1, int y1, int x2, int y2) {
    SDL_RenderDrawLine(ren, x1, y1, x2, y2);
    return 0;
}

// draw a string at (x, y) with the given color.
// requires canvas_font to have been called first, otherwise you get nothing.
int canvas_text(int x, int y, int r, int g, int b, const char *text) {
    if (!font || !ren || !text) return -1;
    SDL_Color col = {r, g, b, 255};
    SDL_Surface *s = TTF_RenderText_Blended(font, text, col);
    if (!s) return -1;
    SDL_Texture *t = SDL_CreateTextureFromSurface(ren, s);
    SDL_Rect dst = {x, y, s->w, s->h};
    SDL_FreeSurface(s);
    SDL_RenderCopy(ren, t, NULL, &dst);
    SDL_DestroyTexture(t);
    return 0;
}

// draw an integer as text. saves you from needing int-to-string in lpp.
int canvas_int(int x, int y, int r, int g, int b, int n) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%d", n);
    return canvas_text(x, y, r, g, b, buf);
}

// draw a float as text, 2 decimal places.
int canvas_float(int x, int y, int r, int g, int b, double n) {
    char buf[64];
    snprintf(buf, sizeof(buf), "%.2f", n);
    return canvas_text(x, y, r, g, b, buf);
}

// flip the back buffer to the screen. call at the end of every frame.
int canvas_present(void) {
    SDL_RenderPresent(ren);
    return 0;
}

// pump the event queue. returns 0 when the user closes the window.
// use this as your while loop condition: while canvas_poll() { ... }
int canvas_poll(void) {
    SDL_Event e;
    while (SDL_PollEvent(&e))
        if (e.type == SDL_QUIT) running = 0;
    return running;
}

// returns 1 if the key is held down, 0 if not.
// key codes:
//   0=UP  1=DOWN  2=LEFT  3=RIGHT
//   4=SPACE  5=ESCAPE  6=ENTER
//   7=W  8=S  9=A  10=D
int canvas_key(int k) {
    SDL_PumpEvents();
    const Uint8 *ks = SDL_GetKeyboardState(NULL);
    SDL_Scancode sc;
    switch (k) {
        case 0:  sc = SDL_SCANCODE_UP;     break;
        case 1:  sc = SDL_SCANCODE_DOWN;   break;
        case 2:  sc = SDL_SCANCODE_LEFT;   break;
        case 3:  sc = SDL_SCANCODE_RIGHT;  break;
        case 4:  sc = SDL_SCANCODE_SPACE;  break;
        case 5:  sc = SDL_SCANCODE_ESCAPE; break;
        case 6:  sc = SDL_SCANCODE_RETURN; break;
        case 7:  sc = SDL_SCANCODE_W;      break;
        case 8:  sc = SDL_SCANCODE_S;      break;
        case 9:  sc = SDL_SCANCODE_A;      break;
        case 10: sc = SDL_SCANCODE_D;      break;
        default: return 0;
    }
    return ks[sc] ? 1 : 0;
}


int canvas_mouse_x(void) {
    int x, y;
    SDL_GetMouseState(&x, &y);
    return x;
}

int canvas_mouse_y(void) {
    int x, y;
    SDL_GetMouseState(&x, &y);
    return y;
}

// btn: 0=left click, 1=right click, 2=middle click
// returns 1 if held, 0 if not
int canvas_mouse_btn(int btn) {
    int x, y;
    Uint32 state = SDL_GetMouseState(&x, &y);
    switch (btn) {
        case 0: return (state & SDL_BUTTON(SDL_BUTTON_LEFT))   ? 1 : 0;
        case 1: return (state & SDL_BUTTON(SDL_BUTTON_RIGHT))  ? 1 : 0;
        case 2: return (state & SDL_BUTTON(SDL_BUTTON_MIDDLE)) ? 1 : 0;
        default: return 0;
    }
}

// close the window and clean up SDL. call at the end of main.
int canvas_quit(void) {
    if (ren) SDL_DestroyRenderer(ren);
    if (win) SDL_DestroyWindow(win);
    TTF_Quit();
    SDL_Quit();
    running = 0;
    return 0;
}

// duplicated from stdlib.c so linkto "gamelib" is self-contained.
// don't linkto both or you'll get duplicate symbol errors.

static int lpp_gl_seeded = 0;

int rand_int(int mn, int mx) {
    if (!lpp_gl_seeded) { srand((unsigned)time(NULL)); lpp_gl_seeded = 1; }
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

void print_int(int x)         { printf("%d\n", x); }
void print_str(const char *s) { if (s) puts(s); }
void print_float(double x)    { printf("%f\n", x); }
void print_char(int c)        { putchar(c); }

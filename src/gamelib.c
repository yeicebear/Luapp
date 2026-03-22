// gamelib.c
// sdl2 canvas for making games. window, renderer, keyboard, mouse, text.
// linkto "gamelib" gives you all of this. gamelib has no overlap with std.
// if you want print_int, rand_int, sleep_ms etc in a game, linkto "std" too.
//
// call canvas_init() first. always. if you call anything else first,
// the renderer is null and everything will silently do nothing or crash.
// call canvas_quit() when you're done to release the window.

#include <stdio.h>
#include <stdlib.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>

static SDL_Window   *win  = NULL;
static SDL_Renderer *ren  = NULL;
static TTF_Font     *font = NULL;
static int           running = 0;


// open a window. w and h are pixel dimensions. call this once at startup.
int canvas_init(int w, int h) {
    SDL_Init(SDL_INIT_VIDEO);
    TTF_Init();
    win = SDL_CreateWindow("lpp",
                           SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                           w, h, SDL_WINDOW_SHOWN);
    ren = SDL_CreateRenderer(win, -1,
                             SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    running = 1;
    return 0;
}

// load a font from a .ttf file on disk. size is in points.
// returns 0 on success, -1 if the file wasn't found.
// canvas_text won't do anything until you call this.
int canvas_font(const char *path, int size) {
    font = TTF_OpenFont(path, size);
    return font ? 0 : -1;
}

// fill the whole screen with a solid colour. call at the start of every frame.
int canvas_clear(int r, int g, int b) {
    SDL_SetRenderDrawColor(ren, r, g, b, 255);
    SDL_RenderClear(ren);
    return 0;
}

// set the active draw colour. used by canvas_rect, canvas_line, canvas_pixel.
int canvas_color(int r, int g, int b) {
    SDL_SetRenderDrawColor(ren, r, g, b, 255);
    return 0;
}

// draw a filled rectangle using the current colour.
int canvas_rect(int x, int y, int w, int h) {
    SDL_Rect r = {x, y, w, h};
    SDL_RenderFillRect(ren, &r);
    return 0;
}

// draw an outlined rectangle (no fill).
int canvas_rect_outline(int x, int y, int w, int h) {
    SDL_Rect r = {x, y, w, h};
    SDL_RenderDrawRect(ren, &r);
    return 0;
}

int canvas_pixel(int x, int y) {
    SDL_RenderDrawPoint(ren, x, y);
    return 0;
}

int canvas_line(int x1, int y1, int x2, int y2) {
    SDL_RenderDrawLine(ren, x1, y1, x2, y2);
    return 0;
}

// draw text at (x, y) using the loaded font. requires canvas_font() first.
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

// draw a float as text with 2 decimal places.
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
// use as your while loop condition: while canvas_poll() { ... }
int canvas_poll(void) {
    SDL_Event e;
    while (SDL_PollEvent(&e))
        if (e.type == SDL_QUIT) running = 0;
        return running;
}

// check if a key is held down. key codes:
//   0=UP  1=DOWN  2=LEFT  3=RIGHT  4=SPACE  5=ESCAPE  6=ENTER
//   7=W   8=S     9=A     10=D
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
        case 10: sc = SDL_SCANCODE_D;         break;
        case 11: sc = SDL_SCANCODE_1;         break;
        case 12: sc = SDL_SCANCODE_2;         break;
        case 13: sc = SDL_SCANCODE_3;         break;
        case 14: sc = SDL_SCANCODE_4;         break;
        case 15: sc = SDL_SCANCODE_5;         break;
        case 16: sc = SDL_SCANCODE_6;         break;
        case 17: sc = SDL_SCANCODE_7;         break;
        case 18: sc = SDL_SCANCODE_8;         break;
        case 19: sc = SDL_SCANCODE_9;         break;
        case 20: sc = SDL_SCANCODE_0;         break;
        case 21: sc = SDL_SCANCODE_BACKSPACE; break;
        default: return 0;
    }
    return ks[sc] ? 1 : 0;
}

int canvas_mouse_x(void) { int x, y; SDL_GetMouseState(&x, &y); return x; }
int canvas_mouse_y(void) { int x, y; SDL_GetMouseState(&x, &y); return y; }

// btn: 0=left, 1=right, 2=middle. returns 1 if held, 0 if not.
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

// close the window and clean up sdl. call at the end of main.
int canvas_quit(void) {
    if (ren) SDL_DestroyRenderer(ren);
    if (win) SDL_DestroyWindow(win);
    TTF_Quit();
    SDL_Quit();
    running = 0;
    return 0;
}


// ---- extended sdl2 drawing ----
// these weren't in the original gamelib. they're common enough to include.

// draw a circle using a midpoint algorithm. not filled.
int canvas_circle(int cx, int cy, int radius) {
    if (!ren) return -1;
    int x = radius, y = 0, err = 0;
    while (x >= y) {
        SDL_RenderDrawPoint(ren, cx+x, cy+y);
        SDL_RenderDrawPoint(ren, cx+y, cy+x);
        SDL_RenderDrawPoint(ren, cx-y, cy+x);
        SDL_RenderDrawPoint(ren, cx-x, cy+y);
        SDL_RenderDrawPoint(ren, cx-x, cy-y);
        SDL_RenderDrawPoint(ren, cx-y, cy-x);
        SDL_RenderDrawPoint(ren, cx+y, cy-x);
        SDL_RenderDrawPoint(ren, cx+x, cy-y);
        y++;
        if (err <= 0) err += 2*y+1;
        else { x--; err += 2*(y-x)+1; }
    }
    return 0;
}

// draw a filled circle. slow but correct.
int canvas_circle_fill(int cx, int cy, int radius) {
    if (!ren) return -1;
    for (int y = -radius; y <= radius; y++) {
        int dx = (int)SDL_sqrt(radius*radius - y*y);
        SDL_RenderDrawLine(ren, cx-dx, cy+y, cx+dx, cy+y);
    }
    return 0;
}

// set window title. useful for showing score or debug info.
int canvas_title(const char *title) {
    if (win && title) SDL_SetWindowTitle(win, title);
    return 0;
}

// get screen width and height of the window.
int canvas_width(void)  { int w=0, h=0; if (win) SDL_GetWindowSize(win, &w, &h); return w; }
int canvas_height(void) { int w=0, h=0; if (win) SDL_GetWindowSize(win, &w, &h); return h; }

// set draw opacity (alpha). 0=transparent, 255=opaque.
int canvas_alpha(int a) {
    if (!ren) return -1;
    SDL_SetRenderDrawBlendMode(ren, a < 255 ? SDL_BLENDMODE_BLEND : SDL_BLENDMODE_NONE);
    Uint8 r, g, b, old_a;
    SDL_GetRenderDrawColor(ren, &r, &g, &b, &old_a);
    SDL_SetRenderDrawColor(ren, r, g, b, (Uint8)a);
    return 0;
}

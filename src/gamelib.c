#include <stdio.h>
#include <stdlib.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>

static SDL_Window   *win  = NULL;
static SDL_Renderer *ren  = NULL;
static TTF_Font     *font = NULL;
static int running = 0;

int canvas_init(int w, int h) {
    SDL_Init(SDL_INIT_VIDEO);
    TTF_Init();
    win = SDL_CreateWindow("lpp", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, w, h, SDL_WINDOW_SHOWN);
    ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    running = 1;
    return 0;
}

int canvas_font(const char *path, int size) {
    font = TTF_OpenFont(path, size);
    return font ? 0 : -1;
}

int canvas_clear(int r, int g, int b) {
    SDL_SetRenderDrawColor(ren, r, g, b, 255);
    SDL_RenderClear(ren);
    return 0;
}

int canvas_color(int r, int g, int b) {
    SDL_SetRenderDrawColor(ren, r, g, b, 255);
    return 0;
}

int canvas_rect(int x, int y, int w, int h) {
    SDL_Rect r = {x, y, w, h};
    SDL_RenderFillRect(ren, &r);
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

int canvas_text(int x, int y, int r, int g, int b, const char *text) {
    if (!font || !ren) return -1;
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

int canvas_int(int x, int y, int r, int g, int b, int n) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%d", n);
    SDL_Color col = {r, g, b, 255};
    SDL_Surface *s = TTF_RenderText_Blended(font, buf, col);
    if (!s) return -1;
    SDL_Texture *t = SDL_CreateTextureFromSurface(ren, s);
    SDL_Rect dst = {x, y, s->w, s->h};
    SDL_FreeSurface(s);
    SDL_RenderCopy(ren, t, NULL, &dst);
    SDL_DestroyTexture(t);
    return 0;
}

int canvas_present(void) {
    SDL_RenderPresent(ren);
    return 0;
}

int canvas_poll(void) {
    SDL_Event e;
    while (SDL_PollEvent(&e))
        if (e.type == SDL_QUIT) running = 0;
    return running;
}

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

int canvas_quit(void) {
    if (ren) SDL_DestroyRenderer(ren);
    if (win) SDL_DestroyWindow(win);
    TTF_Quit();
    SDL_Quit();
    running = 0;
    return 0;
}

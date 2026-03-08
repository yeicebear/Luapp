#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// welcome to the stdlib
// stuf that doesnt need sdl2. that's in gamelib you dedbeet!
// nothing here is smart
// if u came looking for cleverness go back to lua

static int lpp_seeded = 0;


// printing junk
// yes this is just printf wrappers
void print_int(int x){ printf("%d\n",x); }
void print_float(double x){ printf("%f\n",x); }
void print_long(long x){ printf("%ld\n",x); }

void print_str(const char *s){
    if(s) puts(s);
}

void print_char(int c){
    putchar(c);
}


// input
// scanf is cursed but we using it anyway
int input_int(void){
    int v=0;

    if(scanf("%d",&v)!=1){
        int c;
        while((c=getchar())!='\n' && c!=EOF){}
    }

    return v;
}

// reads one char
// yes this blocks the program
int input_char(void){
    return getchar();
}


// random numbers
// not crypto
// not clever
int rand_int(int mn,int mx){
    if(!lpp_seeded){
        srand((unsigned)time(NULL));
        lpp_seeded=1;
    }

    if(mx<=mn) return mn;

    return mn+rand()%(mx-mn+1);
}


// time since start ish
int time_ms(void){
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC,&t);

    return (int)(t.tv_sec*1000+t.tv_nsec/1000000);
}


// blocks everything
// deal with it
int sleep_ms(int ms){
    if(ms<=0) return 0;

    struct timespec t={ms/1000,(ms%1000)*1000000L};
    nanosleep(&t,NULL);

    return 0;
}


// string helpers
// dont expect magic
int str_len(const char *s){
    return s?(int)strlen(s):0;
}

int str_get(const char *s,int i){
    if(!s||i<0||i>=(int)strlen(s)) return -1;
    return (unsigned char)s[i];
}

int str_cmp(const char *a,const char *b){
    if(!a||!b) return -1;
    return strcmp(a,b);
}


// file stuff
// file handles are longs
// yes its ugly
long file_open(const char *path,const char *mode){
    FILE *f=fopen(path,mode);
    return (long)f;
}

int file_close(long fptr){
    if(!fptr) return -1;
    return fclose((FILE*)fptr);
}

int file_read_char(long fptr){
    if(!fptr) return -1;
    return fgetc((FILE*)fptr);
}

int file_write_char(long fptr,int c){
    if(!fptr) return -1;
    return fputc(c,(FILE*)fptr);
}

int file_write_str(long fptr,const char *s){
    if(!fptr||!s) return -1;
    return fputs(s,(FILE*)fptr);
}

int file_write_int(long fptr,int n){
    if(!fptr) return -1;
    return fprintf((FILE*)fptr,"%d",n);
}

int file_eof(long fptr){
    if(!fptr) return 1;
    return feof((FILE*)fptr);
}


// dynamic arrays
// basicly a tiny vector clone
// future me will regret this
#define LPP_ARR_HDR 24

typedef struct{
    long len;
    long cap;
    long elemsize;
    char data[];
}lpp_dynarray;

static lpp_dynarray *lpp_arr_hdr(long data){
    return (lpp_dynarray*)(data-LPP_ARR_HDR);
}

long arr_new(int elemsize){
    long cap=8;

    lpp_dynarray *a=malloc(sizeof(lpp_dynarray)+cap*elemsize);
    if(!a) return 0;

    a->len=0;
    a->cap=cap;
    a->elemsize=elemsize;

    return (long)a->data;
}

long arr_push_int(long data,int val){
    lpp_dynarray *a=lpp_arr_hdr(data);

    if(a->len>=a->cap){
        a->cap*=2;
        a=realloc(a,sizeof(lpp_dynarray)+a->cap*a->elemsize);
        if(!a) return 0;
        data=(long)a->data;
    }

    ((int*)a->data)[a->len]=val;
    a->len++;

    return data;
}

long arr_push_long(long data,long val){
    lpp_dynarray *a=lpp_arr_hdr(data);

    if(a->len>=a->cap){
        a->cap*=2;
        a=realloc(a,sizeof(lpp_dynarray)+a->cap*a->elemsize);
        if(!a) return 0;
        data=(long)a->data;
    }

    ((long*)a->data)[a->len]=val;
    a->len++;

    return data;
}

long arr_push_float(long data,double val){
    lpp_dynarray *a=lpp_arr_hdr(data);

    if(a->len>=a->cap){
        a->cap*=2;
        a=realloc(a,sizeof(lpp_dynarray)+a->cap*a->elemsize);
        if(!a) return 0;
        data=(long)a->data;
    }

    ((double*)a->data)[a->len]=val;
    a->len++;

    return data;
}

int arr_len(long data){
    if(!data) return 0;
    return (int)lpp_arr_hdr(data)->len;
}

void arr_free(long data){
    if(!data) return;
    free(lpp_arr_hdr(data));
}


// raw memory
// pointer soup
long mem_alloc(int n){
    if(n<=0) return 0;
    return (long)calloc(1,n);
}

void mem_free(long ptr){
    if(ptr) free((void*)ptr);
}

void mem_copy(long dst,long src,int n){
    if(!dst||!src||n<=0) return;
    memcpy((void*)dst,(const void*)src,n);
}

void mem_move(long dst,long src,int n){
    if(!dst||!src||n<=0) return;
    memmove((void*)dst,(const void*)src,n);
}

void mem_set(long ptr,int val,int n){
    if(!ptr||n<=0) return;
    memset((void*)ptr,val&0xFF,n);
}


// string builder
// duct tape for strings
#define LPP_SB_HDR 8

typedef struct{
    int len;
    int cap;
    char data[];
}lpp_sb;

static lpp_sb *lpp_sb_hdr(long h){
    return (lpp_sb*)(h-LPP_SB_HDR);
}

long sb_new(void){
    int cap=64;

    lpp_sb *sb=malloc(LPP_SB_HDR+cap+1);
    if(!sb) return 0;

    sb->len=0;
    sb->cap=cap;
    sb->data[0]='\0';

    return (long)sb->data;
}

long sb_append(long h,const char *s){
    if(!h||!s) return h;

    int n=(int)strlen(s);
    lpp_sb *sb=lpp_sb_hdr(h);

    if(sb->len+n>sb->cap){
        int ncap=sb->cap;
        while(ncap<sb->len+n) ncap*=2;

        sb=realloc(sb,LPP_SB_HDR+ncap+1);
        if(!sb) return 0;

        sb->cap=ncap;
        h=(long)sb->data;
    }

    memcpy(sb->data+sb->len,s,n+1);
    sb->len+=n;

    return h;
}

const char *sb_get(long h){
    if(!h) return "";
    return lpp_sb_hdr(h)->data;
}

void sb_free(long h){
    if(h) free(lpp_sb_hdr(h));
}
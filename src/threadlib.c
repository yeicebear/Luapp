// threadlib.c
// concurrency for lpp. wraps pthreads into something that won't
// immediately kill you. channels, mutexes, thread handles.
// none of this is magic — it's just pthreads with a friendlier face.
// on windows you need mingw with winpthreads, which you probably already
// have if you're cross-compiling. on linux/mac this links against -lpthread.
//
// the design: a "thread" is just a long (pointer to a heap struct).
// a "mutex" is also a long. a "channel" is also a long.
// lpp can't hold raw C structs so we heap-allocate everything and hand
// back opaque integer handles. you free them when you're done.
// leaking them is your problem, not ours.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#ifdef _WIN32
// mingw ships winpthreads inside pthread.h, works the same way
#include <pthread.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

#define lpp_ptr intptr_t


// ---- mutex ----
// the simplest thing. wrap a pthread_mutex_t on the heap.
// thread_mutex_new() gives you a handle (long).
// thread_mutex_lock/unlock take that handle.
// thread_mutex_free destroys and frees it.

typedef struct {
    pthread_mutex_t m;
} lpp_mutex;

lpp_ptr thread_mutex_new(void) {
    lpp_mutex *mx = calloc(1, sizeof(lpp_mutex));
    if (!mx) return 0;
    pthread_mutex_init(&mx->m, NULL);
    return (lpp_ptr)mx;
}

int thread_mutex_lock(lpp_ptr h) {
    if (!h) return -1;
    return pthread_mutex_lock(&((lpp_mutex*)h)->m);
}

int thread_mutex_unlock(lpp_ptr h) {
    if (!h) return -1;
    return pthread_mutex_unlock(&((lpp_mutex*)h)->m);
}

void thread_mutex_free(lpp_ptr h) {
    if (!h) return;
    pthread_mutex_destroy(&((lpp_mutex*)h)->m);
    free((void*)h);
}


// ---- threads ----
// each thread gets a heap struct holding its pthread_t, a function pointer,
// a single integer argument, and the return value after it finishes.
// the function you pass must have the signature: func my_job(arg: int): int
// only int args/returns because lpp can't pass arbitrary structs across threads.
// if you need more data, write it into a global before spawning.

typedef struct {
    pthread_t      tid;
    int          (*fn)(int);
    int            arg;
    int            retval;
    int            done;     // 1 once the thread has returned
} lpp_thread;

static void* lpp_thread_entry(void *data) {
    lpp_thread *t = (lpp_thread*)data;
    t->retval = t->fn(t->arg);
    t->done   = 1;
    return NULL;
}

// fn_ptr is the address of the lpp function you want to run.
// pass it with &my_func in lpp (which resolves to the C function pointer via QBE).
// returns a thread handle (long), or 0 on failure.
lpp_ptr thread_spawn(lpp_ptr fn_ptr, int arg) {
    if (!fn_ptr) return 0;
    lpp_thread *t = calloc(1, sizeof(lpp_thread));
    if (!t) return 0;
    t->fn  = (int(*)(int))fn_ptr;
    t->arg = arg;
    t->done = 0;
    if (pthread_create(&t->tid, NULL, lpp_thread_entry, t) != 0) {
        free(t);
        return 0;
    }
    return (lpp_ptr)t;
}

// blocks until the thread finishes, then returns its return value.
int thread_join(lpp_ptr h) {
    if (!h) return -1;
    lpp_thread *t = (lpp_thread*)h;
    pthread_join(t->tid, NULL);
    return t->retval;
}

// 1 if the thread has finished, 0 if still running. doesn't block.
int thread_done(lpp_ptr h) {
    if (!h) return 1;
    return ((lpp_thread*)h)->done;
}

void thread_free(lpp_ptr h) {
    if (h) free((void*)h);
}


// ---- channel ----
// a blocking, single-slot integer channel. think Go channels but dumber.
// send blocks until the slot is empty. recv blocks until the slot is full.
// this is not a ring buffer. it holds exactly one int at a time.
// for real throughput you'd want a circular buffer. this is for learning.

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t  not_full;
    pthread_cond_t  not_empty;
    int             value;
    int             has_value;  // 1 = slot is occupied
} lpp_channel;

lpp_ptr thread_chan_new(void) {
    lpp_channel *c = calloc(1, sizeof(lpp_channel));
    if (!c) return 0;
    pthread_mutex_init(&c->lock, NULL);
    pthread_cond_init(&c->not_full,  NULL);
    pthread_cond_init(&c->not_empty, NULL);
    c->has_value = 0;
    return (lpp_ptr)c;
}

// blocks until the channel is empty, then puts val in and signals a waiting receiver.
int thread_chan_send(lpp_ptr h, int val) {
    if (!h) return -1;
    lpp_channel *c = (lpp_channel*)h;
    pthread_mutex_lock(&c->lock);
    while (c->has_value)
        pthread_cond_wait(&c->not_full, &c->lock);
    c->value     = val;
    c->has_value = 1;
    pthread_cond_signal(&c->not_empty);
    pthread_mutex_unlock(&c->lock);
    return 0;
}

// blocks until the channel has a value, then removes and returns it.
int thread_chan_recv(lpp_ptr h) {
    if (!h) return -1;
    lpp_channel *c = (lpp_channel*)h;
    pthread_mutex_lock(&c->lock);
    while (!c->has_value)
        pthread_cond_wait(&c->not_empty, &c->lock);
    int v        = c->value;
    c->has_value = 0;
    pthread_cond_signal(&c->not_full);
    pthread_mutex_unlock(&c->lock);
    return v;
}

void thread_chan_free(lpp_ptr h) {
    if (!h) return;
    lpp_channel *c = (lpp_channel*)h;
    pthread_mutex_destroy(&c->lock);
    pthread_cond_destroy(&c->not_full);
    pthread_cond_destroy(&c->not_empty);
    free(c);
}


// ---- atomic integer ----
// the dumbest possible atomic: a mutex-guarded int.
// not lock-free. not blazing fast. but correct and simple.
// for a real program you'd use _Atomic from C11 or platform intrinsics.

typedef struct {
    pthread_mutex_t lock;
    int value;
} lpp_atomic;

lpp_ptr thread_atomic_new(int init) {
    lpp_atomic *a = calloc(1, sizeof(lpp_atomic));
    if (!a) return 0;
    pthread_mutex_init(&a->lock, NULL);
    a->value = init;
    return (lpp_ptr)a;
}

int thread_atomic_get(lpp_ptr h) {
    if (!h) return 0;
    lpp_atomic *a = (lpp_atomic*)h;
    pthread_mutex_lock(&a->lock);
    int v = a->value;
    pthread_mutex_unlock(&a->lock);
    return v;
}

int thread_atomic_set(lpp_ptr h, int val) {
    if (!h) return -1;
    lpp_atomic *a = (lpp_atomic*)h;
    pthread_mutex_lock(&a->lock);
    a->value = val;
    pthread_mutex_unlock(&a->lock);
    return 0;
}

// atomically adds delta, returns the new value.
int thread_atomic_add(lpp_ptr h, int delta) {
    if (!h) return 0;
    lpp_atomic *a = (lpp_atomic*)h;
    pthread_mutex_lock(&a->lock);
    a->value += delta;
    int v = a->value;
    pthread_mutex_unlock(&a->lock);
    return v;
}

void thread_atomic_free(lpp_ptr h) {
    if (!h) return;
    lpp_atomic *a = (lpp_atomic*)h;
    pthread_mutex_destroy(&a->lock);
    free(a);
}

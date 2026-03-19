// ailib.c
// machine learning primitives you can actually understand without a phd.
// three things live here:
//   1. a tiny feedforward neural network (train and infer in the same process)
//   2. k-nearest-neighbor classifier (no training phase, just store examples)
//   3. linear regression (fit a line to data, predict new values)
//
// everything runs on the cpu in a single thread. no blas, no cuda, no tears.
// linkto "ailib" and linkto "mathlib" — ailib uses math_exp and math_sqrt.
// don't linkto both this and something that defines math_exp or you'll get a conflict.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>

#define lpp_ptr intptr_t


// ---- feedforward neural network ----
// a network is: input layer -> N hidden layers -> output layer.
// activation: sigmoid everywhere (simple, differentiable, everyone uses it to learn backprop).
// training: gradient descent with backpropagation. one sample at a time (online learning).
//
// the network struct is heap-allocated and opaque to lpp.
// weights are stored as flat arrays (row-major): w[layer][out_neuron][in_neuron].
// biases: b[layer][out_neuron].

#define NN_MAX_LAYERS 8
#define NN_MAX_NEURONS 256

typedef struct {
    int    n_layers;          // total layers including input and output
    int    sizes[NN_MAX_LAYERS];     // neurons per layer
    double *weights[NN_MAX_LAYERS]; // weights[l] connects layer l-1 to l
    double *biases[NN_MAX_LAYERS];  // biases[l] for neurons in layer l
    double *activations[NN_MAX_LAYERS]; // scratch space for forward pass
    double *deltas[NN_MAX_LAYERS];  // scratch space for backprop
    double lr;  // learning rate
} lpp_nn;

static double lpp_sigmoid(double x) { return 1.0 / (1.0 + exp(-x)); }
static double lpp_dsigmoid(double y) { return y * (1.0 - y); } // derivative, given output

// creates a network. layer_sizes is a C int array with n_layers entries.
// allocates all weight/bias/activation arrays and initialises weights to small random values.
static lpp_ptr lpp_nn_new_internal(int n_layers, int *sizes, double lr) {
    if (n_layers < 2 || n_layers > NN_MAX_LAYERS) return 0;
    lpp_nn *nn = calloc(1, sizeof(lpp_nn));
    if (!nn) return 0;
    nn->n_layers = n_layers;
    nn->lr = lr;
    for (int l = 0; l < n_layers; l++) nn->sizes[l] = sizes[l];

    for (int l = 1; l < n_layers; l++) {
        int in  = sizes[l-1];
        int out = sizes[l];
        nn->weights[l]     = malloc(out * in  * sizeof(double));
        nn->biases[l]      = malloc(out        * sizeof(double));
        nn->activations[l] = malloc(out        * sizeof(double));
        nn->deltas[l]      = malloc(out        * sizeof(double));
        if (!nn->weights[l]||!nn->biases[l]||!nn->activations[l]||!nn->deltas[l]) {
            // leak on alloc failure — acceptable for a learning lib
            free(nn); return 0;
        }
        // xavier initialisation: scale by 1/sqrt(fan_in)
        double scale = 1.0 / sqrt((double)in);
        for (int i = 0; i < out*in; i++)
            nn->weights[l][i] = ((double)rand()/RAND_MAX * 2 - 1) * scale;
        for (int i = 0; i < out; i++)
            nn->biases[l][i] = 0;
    }
    nn->activations[0] = malloc(sizes[0] * sizeof(double));
    if (!nn->activations[0]) { free(nn); return 0; }
    return (lpp_ptr)nn;
}

// creates a 3-layer network: input_size -> hidden_size -> output_size.
// learning rate 0.1 is a fine starting point. lower if training diverges.
lpp_ptr ai_nn_new(int input_size, int hidden_size, int output_size, double lr) {
    int sizes[3] = { input_size, hidden_size, output_size };
    return lpp_nn_new_internal(3, sizes, lr);
}

// sets one input value. call this for each input before ai_nn_forward.
void ai_nn_set_input(lpp_ptr h, int idx, double val) {
    if (!h) return;
    lpp_nn *nn = (lpp_nn*)h;
    if (idx < 0 || idx >= nn->sizes[0]) return;
    nn->activations[0][idx] = val;
}

// runs a forward pass. call ai_nn_get_output afterwards to read results.
void ai_nn_forward(lpp_ptr h) {
    if (!h) return;
    lpp_nn *nn = (lpp_nn*)h;
    for (int l = 1; l < nn->n_layers; l++) {
        int in  = nn->sizes[l-1];
        int out = nn->sizes[l];
        for (int j = 0; j < out; j++) {
            double sum = nn->biases[l][j];
            for (int i = 0; i < in; i++)
                sum += nn->activations[l-1][i] * nn->weights[l][j*in + i];
            nn->activations[l][j] = lpp_sigmoid(sum);
        }
    }
}

double ai_nn_get_output(lpp_ptr h, int idx) {
    if (!h) return 0;
    lpp_nn *nn = (lpp_nn*)h;
    int last = nn->n_layers - 1;
    if (idx < 0 || idx >= nn->sizes[last]) return 0;
    return nn->activations[last][idx];
}

// one backpropagation step.
// set inputs with ai_nn_set_input, call ai_nn_forward, then call this with the expected outputs.
// expected is a pointer to an array of output_size doubles.
// returns the mean squared error for this sample (useful for tracking convergence).
double ai_nn_train(lpp_ptr h, lpp_ptr expected_ptr) {
    if (!h || !expected_ptr) return -1;
    lpp_nn *nn  = (lpp_nn*)h;
    double *exp = (double*)expected_ptr;

    // compute output deltas (error * sigmoid derivative)
    int last = nn->n_layers - 1;
    double mse = 0;
    for (int j = 0; j < nn->sizes[last]; j++) {
        double err = exp[j] - nn->activations[last][j];
        mse += err * err;
        nn->deltas[last][j] = err * lpp_dsigmoid(nn->activations[last][j]);
    }
    mse /= nn->sizes[last];

    // propagate deltas backwards through hidden layers
    for (int l = last-1; l >= 1; l--) {
        int in  = nn->sizes[l];
        int out = nn->sizes[l+1];
        for (int i = 0; i < in; i++) {
            double sum = 0;
            for (int j = 0; j < out; j++)
                sum += nn->deltas[l+1][j] * nn->weights[l+1][j*in + i];
            nn->deltas[l][i] = sum * lpp_dsigmoid(nn->activations[l][i]);
        }
    }

    // update weights and biases
    for (int l = 1; l < nn->n_layers; l++) {
        int in  = nn->sizes[l-1];
        int out = nn->sizes[l];
        for (int j = 0; j < out; j++) {
            nn->biases[l][j] += nn->lr * nn->deltas[l][j];
            for (int i = 0; i < in; i++)
                nn->weights[l][j*in + i] += nn->lr * nn->deltas[l][j] * nn->activations[l-1][i];
        }
    }
    return mse;
}

// allocates a double array of size n for passing expected values to ai_nn_train.
// fill it with ai_expected_set(), pass to ai_nn_train, then free with ai_expected_free().
lpp_ptr ai_expected_new(int n) {
    double *e = calloc(n, sizeof(double));
    return (lpp_ptr)e;
}
void ai_expected_set(lpp_ptr h, int idx, double val) {
    if (h) ((double*)h)[idx] = val;
}
void ai_expected_free(lpp_ptr h) { if (h) free((void*)h); }

void ai_nn_free(lpp_ptr h) {
    if (!h) return;
    lpp_nn *nn = (lpp_nn*)h;
    for (int l = 0; l < nn->n_layers; l++) {
        free(nn->weights[l]); free(nn->biases[l]);
        free(nn->activations[l]); free(nn->deltas[l]);
    }
    free(nn);
}


// ---- k-nearest neighbor ----
// store labeled examples as (feature_vector, label) pairs.
// classify a new point by finding its k nearest stored examples and voting.
// distance is euclidean. no training phase — it's all at query time.
// this is o(n) per query. fine for small datasets, painful for large ones.

#define KNN_MAX_FEATURES 64

typedef struct {
    double  features[KNN_MAX_FEATURES];
    int     label;
} lpp_knn_sample;

typedef struct {
    lpp_knn_sample *samples;
    int             count;
    int             cap;
    int             n_features;
} lpp_knn;

lpp_ptr ai_knn_new(int n_features) {
    if (n_features <= 0 || n_features > KNN_MAX_FEATURES) return 0;
    lpp_knn *k = calloc(1, sizeof(lpp_knn));
    if (!k) return 0;
    k->cap = 64;
    k->samples = malloc(k->cap * sizeof(lpp_knn_sample));
    if (!k->samples) { free(k); return 0; }
    k->n_features = n_features;
    return (lpp_ptr)k;
}

// add a training example. features_ptr points to an array of n_features doubles.
void ai_knn_add(lpp_ptr h, lpp_ptr features_ptr, int label) {
    if (!h || !features_ptr) return;
    lpp_knn *k = (lpp_knn*)h;
    if (k->count >= k->cap) {
        k->cap *= 2;
        k->samples = realloc(k->samples, k->cap * sizeof(lpp_knn_sample));
        if (!k->samples) return;
    }
    memcpy(k->samples[k->count].features, (double*)features_ptr, k->n_features * sizeof(double));
    k->samples[k->count].label = label;
    k->count++;
}

// classify a point. returns the most common label among the k nearest neighbours.
// features_ptr points to an array of n_features doubles representing the query point.
int ai_knn_classify(lpp_ptr h, lpp_ptr features_ptr, int k) {
    if (!h || !features_ptr || k <= 0) return -1;
    lpp_knn *knn = (lpp_knn*)h;
    double *q = (double*)features_ptr;
    int n = knn->n_features;
    if (k > knn->count) k = knn->count;

    // distances to all samples
    double *dists = malloc(knn->count * sizeof(double));
    int    *idxs  = malloc(knn->count * sizeof(int));
    if (!dists || !idxs) { free(dists); free(idxs); return -1; }

    for (int i = 0; i < knn->count; i++) {
        double d = 0;
        for (int j = 0; j < n; j++) {
            double diff = q[j] - knn->samples[i].features[j];
            d += diff*diff;
        }
        dists[i] = d; // no sqrt needed for comparison
        idxs[i]  = i;
    }

    // partial insertion sort to find k smallest
    for (int i = 0; i < k; i++) {
        for (int j = i+1; j < knn->count; j++) {
            if (dists[j] < dists[i]) {
                double td = dists[i]; dists[i] = dists[j]; dists[j] = td;
                int    ti = idxs[i];  idxs[i]  = idxs[j];  idxs[j]  = ti;
            }
        }
    }

    // vote: count labels among k nearest, return most common
    // labels assumed to be small non-negative integers (up to 256)
    int votes[256] = {0};
    for (int i = 0; i < k; i++) {
        int lbl = knn->samples[idxs[i]].label;
        if (lbl >= 0 && lbl < 256) votes[lbl]++;
    }
    free(dists); free(idxs);

    int best_label = 0, best_count = 0;
    for (int i = 0; i < 256; i++) {
        if (votes[i] > best_count) { best_count = votes[i]; best_label = i; }
    }
    return best_label;
}

void ai_knn_free(lpp_ptr h) {
    if (!h) return;
    lpp_knn *k = (lpp_knn*)h;
    free(k->samples);
    free(k);
}

// allocate a feature array for knn add/classify calls.
lpp_ptr ai_features_new(int n) { return (lpp_ptr)calloc(n, sizeof(double)); }
void ai_features_set(lpp_ptr h, int idx, double val) { if (h) ((double*)h)[idx] = val; }
double ai_features_get(lpp_ptr h, int idx) { return h ? ((double*)h)[idx] : 0; }
void ai_features_free(lpp_ptr h) { if (h) free((void*)h); }


// ---- linear regression ----
// fits y = slope * x + intercept to a set of (x, y) pairs using ordinary least squares.
// the classic formula. exact solution, no iteration.

typedef struct {
    double sum_x, sum_y, sum_xx, sum_xy;
    int n;
    double slope, intercept;
    int fitted;
} lpp_linreg;

lpp_ptr ai_linreg_new(void) {
    lpp_linreg *r = calloc(1, sizeof(lpp_linreg));
    return (lpp_ptr)r;
}

void ai_linreg_add(lpp_ptr h, double x, double y) {
    if (!h) return;
    lpp_linreg *r = (lpp_linreg*)h;
    r->sum_x  += x;
    r->sum_y  += y;
    r->sum_xx += x*x;
    r->sum_xy += x*y;
    r->n++;
    r->fitted = 0;
}

// compute slope and intercept from the accumulated points. call before ai_linreg_predict.
void ai_linreg_fit(lpp_ptr h) {
    if (!h) return;
    lpp_linreg *r = (lpp_linreg*)h;
    if (r->n < 2) { r->slope = 0; r->intercept = 0; r->fitted = 1; return; }
    double n = r->n;
    double denom = n*r->sum_xx - r->sum_x*r->sum_x;
    if (denom == 0) { r->slope = 0; r->intercept = r->sum_y / n; r->fitted = 1; return; }
    r->slope     = (n*r->sum_xy - r->sum_x*r->sum_y) / denom;
    r->intercept = (r->sum_y - r->slope*r->sum_x) / n;
    r->fitted    = 1;
}

double ai_linreg_predict(lpp_ptr h, double x) {
    if (!h) return 0;
    lpp_linreg *r = (lpp_linreg*)h;
    if (!r->fitted) ai_linreg_fit(h);
    return r->slope * x + r->intercept;
}

double ai_linreg_slope(lpp_ptr h)     { return h ? ((lpp_linreg*)h)->slope     : 0; }
double ai_linreg_intercept(lpp_ptr h) { return h ? ((lpp_linreg*)h)->intercept : 0; }

void ai_linreg_free(lpp_ptr h) { if (h) free((void*)h); }

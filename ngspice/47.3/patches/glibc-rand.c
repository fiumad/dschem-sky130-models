/* glibc's rand(), srand() and rand_r(), for the WebAssembly build of ngspice.

   ngspice seeds its Monte Carlo generator from the C library: `setseed n`
   calls srand(n), and TausSeed() takes the generator's initial states from
   rand() (src/maths/misc/randnumb.c). Emscripten's C library (musl) has
   another rand() than glibc, so the same seed gave other samples in the
   browser than in ngspice on Linux (dschem issue #42). This file reproduces
   glibc's functions exactly, so that the two agree:

   - srand()/rand(): glibc's random() with its default state, TYPE_3 (an
     additive feedback generator x[i] = x[i-3] + x[i-31] over 31 words of
     32 bits, returning the top 31 bits), seeded by srandom_r(): the words
     from the Park-Miller generator 16807 * x mod (2^31 - 1), then 310
     outputs discarded (glibc stdlib/random_r.c, __srandom_r and
     __random_r). Without srand() it behaves as after srand(1), as glibc's
     does.
   - rand_r(): glibc's three-step linear congruential rand_r
     (stdlib/rand_r.c).

   scripts/build_ngspice_wasm.sh compiles this file for the WebAssembly
   build only and links it before Emscripten's C library, whose rand(),
   srand() and rand_r() it replaces; native builds do not use it (they have
   their own C library's). scripts/test_glibc_rand.sh compiles it natively
   under other names (GLIBC_RAND_NAME) and checks it against glibc.

   Not thread-safe, as glibc's rand() is not required to be (glibc locks;
   the WebAssembly ngspice runs in one thread). */

#if defined(__EMSCRIPTEN__) || defined(GLIBC_RAND_NAME)

#include <stdint.h>
#include <stdlib.h> /* the declarations these definitions must match */

/* ngspice scales rand() by RAND_MAX (TausSeed()): it must be glibc's too */
#if RAND_MAX != 2147483647
#error "RAND_MAX differs from glibc's: the samples would too"
#endif

#ifndef GLIBC_RAND_NAME
#define GLIBC_RAND_NAME(f) f
#endif

#define DEG 31 /* TYPE_3: the degree of the polynomial */
#define SEP 3  /* TYPE_3: the separation of the two taps */

static int32_t state[DEG];
static int fptr, rptr; /* indices into state: front and rear taps */
static int seeded;

static int32_t step(void)
{
    uint32_t val;
    /* glibc: val = *fptr += (uint32_t) *rptr; in unsigned arithmetic */
    val = (uint32_t)state[fptr] + (uint32_t)state[rptr];
    state[fptr] = (int32_t)val;
    if (++fptr >= DEG) {
        fptr = 0;
        ++rptr;
    } else if (++rptr >= DEG) {
        rptr = 0;
    }
    /* chuck the least random bit */
    return (int32_t)(val >> 1);
}

void GLIBC_RAND_NAME(srand)(unsigned int seed)
{
    int32_t word;
    int i;
    /* glibc: seed 0 is taken as 1 */
    if (seed == 0)
        seed = 1;
    /* glibc: int32_t word = seed (two's complement, as on every target) */
    word = (int32_t)seed;
    state[0] = word;
    for (i = 1; i < DEG; ++i) {
        /* state[i] = (16807 * state[i - 1]) % 2147483647, without
           overflowing 31 bits (Schrage's method), as glibc computes it */
        int64_t hi = word / 127773;
        int64_t lo = word % 127773;
        word = (int32_t)(16807 * lo - 2836 * hi);
        if (word < 0)
            word += 2147483647;
        state[i] = word;
    }
    fptr = SEP;
    rptr = 0;
    for (i = 0; i < 10 * DEG; ++i)
        (void)step();
    seeded = 1;
}

int GLIBC_RAND_NAME(rand)(void)
{
    if (!seeded)
        GLIBC_RAND_NAME(srand)(1);
    return (int)step();
}

int GLIBC_RAND_NAME(rand_r)(unsigned int *seed)
{
    unsigned int next = *seed;
    int result;

    next *= 1103515245;
    next += 12345;
    result = (unsigned int)(next / 65536) % 2048;

    next *= 1103515245;
    next += 12345;
    result <<= 10;
    result ^= (unsigned int)(next / 65536) % 1024;

    next *= 1103515245;
    next += 12345;
    result <<= 10;
    result ^= (unsigned int)(next / 65536) % 1024;

    *seed = next;
    return result;
}

#endif

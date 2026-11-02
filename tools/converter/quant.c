/* Ingenium's quantizers for WebAssembly (R72).
   The reference routines of llama.cpp's ggml-quants.c (release b11321, MIT
   licence, Copyright (c) 2023-2026 The ggml authors), reduced to the four types
   Ingenium writes and to plain C with no library, so that WebAssembly computes
   exactly what llama-quantize computes: every step in 32-bit floats, in the same
   order. Built with: clang --target=wasm32 -O2 -nostdlib -Wl,--no-entry -Wl,--export-dynamic */
typedef unsigned char u8;
typedef signed char i8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef int i32;

#define QK_K 256
#define GROUP_MAX_EPS 1e-15f
#define MAX(a,b) ((a) > (b) ? (a) : (b))
#define MIN(a,b) ((a) < (b) ? (a) : (b))

static inline float fabsf_(float x) { return __builtin_fabsf(x); }
static inline float sqrtf_(float x) { return __builtin_sqrtf(x); }
static inline float roundf_(float x) {
    float t = __builtin_truncf(x);
    if (fabsf_(x - t) >= 0.5f) t += (x < 0 ? -1.0f : 1.0f);
    return t;
}
static inline u32 fbits(float f) { union { float f; u32 u; } v; v.f = f; return v.u; }
static inline float bitsf(u32 u) { union { float f; u32 u; } v; v.u = u; return v.f; }

/* float -> half, round to nearest even (as F16C and numpy do) */
static u16 fp32_to_fp16(float x) {
    u32 f = fbits(x), fe = f & 0x7f800000u, fs;
    u16 hs = (u16)((f >> 16) & 0x8000u);
    if (fe >= 0x47800000u) {
        if (fe == 0x7f800000u) { fs = f & 0x007fffffu; if (fs) { u16 r = (u16)(0x7c00u + (fs >> 13)); if (r == 0x7c00u) r++; return hs + r; } }
        return hs + 0x7c00u;
    }
    if (fe <= 0x38000000u) {
        if (fe < 0x33000000u) return hs;
        fe >>= 23; fs = 0x00800000u + (f & 0x007fffffu); fs >>= (113 - fe);
        if (((fs & 0x3fffu) != 0x1000u) || (f & 0x7ffu)) fs += 0x1000u;
        return hs + (u16)(fs >> 13);
    }
    u16 he = (u16)((fe - 0x38000000u) >> 13);
    fs = f & 0x007fffffu;
    if ((fs & 0x3fffu) != 0x1000u) fs += 0x1000u;
    return hs + (u16)((fs >> 13) + he);
}
static float fp16_to_fp32(u16 h) {
    u32 s = (u32)(h & 0x8000u) << 16, e = (h >> 10) & 31, m = h & 1023;
    if (e == 0) { if (!m) return bitsf(s); float v = (float)m * (1.0f / 16777216.0f); return s ? -v : v; }
    if (e == 31) return bitsf(s | 0x7f800000u | (m << 13));
    return bitsf(s | ((e + 112) << 23) | (m << 13));
}
static inline void put16(u8 * p, u16 v) { p[0] = (u8)v; p[1] = (u8)(v >> 8); }

static inline int nearest_int(float fval) {
    float val = fval + 12582912.f;
    i32 i = (i32)fbits(val);
    return (i & 0x007fffff) - 0x00400000;
}

static void q8_0(const float * x, u8 * y, int k) {
    for (int i = 0; i < k/32; i++) {
        float amax = 0.0f;
        for (int j = 0; j < 32; j++) { const float v = x[i*32 + j]; amax = MAX(amax, fabsf_(v)); }
        const float d = amax / ((1 << 7) - 1);
        const float id = d ? 1.0f/d : 0.0f;
        put16(y, fp32_to_fp16(d));
        for (int j = 0; j < 32; ++j) y[2 + j] = (u8)(i8)roundf_(x[i*32 + j]*id);
        y += 34;
    }
}

static void q5_0(const float * x, u8 * y, int k) {
    for (int i = 0; i < k/32; i++) {
        float amax = 0.0f, max = 0.0f;
        for (int j = 0; j < 32; j++) { const float v = x[i*32 + j]; if (amax < fabsf_(v)) { amax = fabsf_(v); max = v; } }
        const float d = max / -16;
        const float id = d ? 1.0f/d : 0.0f;
        put16(y, fp32_to_fp16(d));
        u32 qh = 0;
        for (int j = 0; j < 16; ++j) {
            const float x0 = x[i*32 + j]*id, x1 = x[i*32 + 16 + j]*id;
            const u8 xi0 = (u8)MIN(31, (i8)(x0 + 16.5f));
            const u8 xi1 = (u8)MIN(31, (i8)(x1 + 16.5f));
            y[6 + j] = (u8)((xi0 & 0x0F) | ((xi1 & 0x0F) << 4));
            qh |= ((xi0 & 0x10u) >> 4) << (j + 0);
            qh |= ((xi1 & 0x10u) >> 4) << (j + 16);
        }
        y[2] = (u8)qh; y[3] = (u8)(qh >> 8); y[4] = (u8)(qh >> 16); y[5] = (u8)(qh >> 24);
        y += 22;
    }
}

static float make_qkx2_quants(int n, int nmax, const float * x, const float * weights,
        u8 * L, float * the_min, u8 * Laux, float rmin, float rdelta, int nstep) {
    float min = x[0], max = x[0];
    float sum_w = weights[0];
    float sum_x = sum_w * x[0];
    for (int i = 1; i < n; ++i) {
        if (x[i] < min) min = x[i];
        if (x[i] > max) max = x[i];
        float w = weights[i];
        sum_w += w;
        sum_x += w * x[i];
    }
    if (min > 0) min = 0;
    if (max == min) { for (int i = 0; i < n; ++i) L[i] = 0; *the_min = -min; return 0.f; }
    float iscale = nmax/(max - min);
    float scale = 1/iscale;
    float best_error = 0;
    for (int i = 0; i < n; ++i) {
        int l = nearest_int(iscale*(x[i] - min));
        L[i] = (u8)MAX(0, MIN(nmax, l));
        float diff = scale * L[i] + min - x[i];
        diff = diff * diff;
        float w = weights[i];
        best_error += w * diff;
    }
    for (int is = 0; is <= nstep; ++is) {
        iscale = (rmin + rdelta*is + nmax)/(max - min);
        float sum_l = 0, sum_l2 = 0, sum_xl = 0;
        for (int i = 0; i < n; ++i) {
            int l = nearest_int(iscale*(x[i] - min));
            l = MAX(0, MIN(nmax, l));
            Laux[i] = (u8)l;
            float w = weights[i];
            sum_l += w*l;
            sum_l2 += w*l*l;
            sum_xl += w*l*x[i];
        }
        float D = sum_w * sum_l2 - sum_l * sum_l;
        if (D > 0) {
            float this_scale = (sum_w * sum_xl - sum_x * sum_l)/D;
            float this_min   = (sum_l2 * sum_x - sum_l * sum_xl)/D;
            if (this_min > 0) { this_min = 0; this_scale = sum_xl / sum_l2; }
            float cur_error = 0;
            for (int i = 0; i < n; ++i) {
                float diff = this_scale * Laux[i] + this_min - x[i];
                diff = diff * diff;
                float w = weights[i];
                cur_error += w * diff;
            }
            if (cur_error < best_error) {
                for (int i = 0; i < n; ++i) L[i] = Laux[i];
                best_error = cur_error; scale = this_scale; min = this_min;
            }
        }
    }
    *the_min = -min;
    return scale;
}

static void get_scale_min_k4(int j, const u8 * q, u8 * d, u8 * m) {
    if (j < 4) { *d = q[j] & 63; *m = q[j + 4] & 63; }
    else { *d = (q[j+4] & 0xF) | ((q[j-4] >> 6) << 4); *m = (q[j+4] >> 4) | ((q[j-0] >> 6) << 4); }
}

static void q4_K(const float * x, u8 * y, int k) {
    u8 L[QK_K], Laux[32];
    float weights[32], mins[QK_K/32], scales[QK_K/32];
    for (int i = 0; i < k/QK_K; i++) {
        u8 * sc = y + 4;
        float max_scale = 0, max_min = 0;
        for (int j = 0; j < QK_K/32; ++j) {
            float sum_x2 = 0;
            for (int l = 0; l < 32; ++l) sum_x2 += x[32*j + l] * x[32*j + l];
            float av_x = sqrtf_(sum_x2/32);
            for (int l = 0; l < 32; ++l) weights[l] = av_x + fabsf_(x[32*j + l]);
            scales[j] = make_qkx2_quants(32, 15, x + 32*j, weights, L + 32*j, &mins[j], Laux, -1.f, 0.1f, 20);
            float scale = scales[j];
            if (scale > max_scale) max_scale = scale;
            float min = mins[j];
            if (min > max_min) max_min = min;
        }
        float inv_scale = max_scale > 0 ? 63.f/max_scale : 0.f;
        float inv_min   = max_min   > 0 ? 63.f/max_min   : 0.f;
        for (int j = 0; j < 12; ++j) sc[j] = 0;
        for (int j = 0; j < QK_K/32; ++j) {
            u8 ls = (u8)nearest_int(inv_scale*scales[j]);
            u8 lm = (u8)nearest_int(inv_min*mins[j]);
            ls = MIN(63, ls); lm = MIN(63, lm);
            if (j < 4) { sc[j] = ls; sc[j+4] = lm; }
            else { sc[j+4] = (ls & 0xF) | ((lm & 0xF) << 4); sc[j-4] |= ((ls >> 4) << 6); sc[j-0] |= ((lm >> 4) << 6); }
        }
        u16 dh = fp32_to_fp16(max_scale/63.f), mh = fp32_to_fp16(max_min/63.f);
        put16(y, dh); put16(y + 2, mh);
        u8 s, m;
        for (int j = 0; j < QK_K/32; ++j) {
            get_scale_min_k4(j, sc, &s, &m);
            const float d = fp16_to_fp32(dh) * s;
            if (!d) continue;
            const float dm = fp16_to_fp32(mh) * m;
            for (int ii = 0; ii < 32; ++ii) {
                int l = nearest_int((x[32*j + ii] + dm)/d);
                l = MAX(0, MIN(15, l));
                L[32*j + ii] = (u8)l;
            }
        }
        u8 * q = y + 16;
        for (int j = 0; j < QK_K; j += 64) { for (int l = 0; l < 32; ++l) q[l] = L[j + l] | (L[j + l + 32] << 4); q += 32; }
        x += QK_K; y += 144;
    }
}

static float make_qx_quants(int n, int nmax, const float * x, i8 * L) {
    float max = 0, amax = 0;
    for (int i = 0; i < n; ++i) { float ax = fabsf_(x[i]); if (ax > amax) { amax = ax; max = x[i]; } }
    if (amax < GROUP_MAX_EPS) { for (int i = 0; i < n; ++i) L[i] = 0; return 0.f; }
    float iscale = -nmax / max;
    float sumlx = 0, suml2 = 0;
    for (int i = 0; i < n; ++i) {
        int l = nearest_int(iscale * x[i]);
        l = MAX(-nmax, MIN(nmax-1, l));
        L[i] = (i8)(l + nmax);
        float w = x[i] * x[i];
        sumlx += w*x[i]*l;
        suml2 += w*l*l;
    }
    float scale = suml2 ? sumlx/suml2 : 0.0f;
    float best = scale * sumlx;
    for (int is = -9; is <= 9; ++is) {
        if (is == 0) continue;
        iscale = -(nmax + 0.1f*is) / max;
        sumlx = suml2 = 0;
        for (int i = 0; i < n; ++i) {
            int l = nearest_int(iscale * x[i]);
            l = MAX(-nmax, MIN(nmax-1, l));
            float w = x[i] * x[i];
            sumlx += w*x[i]*l;
            suml2 += w*l*l;
        }
        if (suml2 > 0 && sumlx*sumlx > best*suml2) {
            for (int i = 0; i < n; ++i) { int l = nearest_int(iscale * x[i]); L[i] = (i8)(nmax + MAX(-nmax, MIN(nmax-1, l))); }
            scale = sumlx/suml2; best = scale*sumlx;
        }
    }
    return scale;
}

static void q6_K(const float * x, u8 * y, int k) {
    i8 L[QK_K];
    float scales[QK_K/16];
    for (int i = 0; i < k/QK_K; i++) {
        u8 * ql = y, * qh = y + 128;
        i8 * sc = (i8 *)(y + 192);
        float max_scale = 0, max_abs_scale = 0;
        for (int ib = 0; ib < QK_K/16; ++ib) {
            const float scale = make_qx_quants(16, 32, x + 16*ib, L + 16*ib);
            scales[ib] = scale;
            const float abs_scale = fabsf_(scale);
            if (abs_scale > max_abs_scale) { max_abs_scale = abs_scale; max_scale = scale; }
        }
        if (max_abs_scale < GROUP_MAX_EPS) {
            for (int j = 0; j < 210; ++j) y[j] = 0;
            x += QK_K; y += 210;
            continue;
        }
        float iscale = -128.f/max_scale;
        u16 dh = fp32_to_fp16(1/iscale);
        put16(y + 208, dh);
        for (int ib = 0; ib < QK_K/16; ++ib) sc[ib] = (i8)MIN(127, nearest_int(iscale*scales[ib]));
        for (int j = 0; j < QK_K/16; ++j) {
            float d = fp16_to_fp32(dh) * sc[j];
            if (!d) continue;
            for (int ii = 0; ii < 16; ++ii) {
                int l = nearest_int(x[16*j + ii]/d);
                l = MAX(-32, MIN(31, l));
                L[16*j + ii] = (i8)(l + 32);
            }
        }
        for (int j = 0; j < QK_K; j += 128) {
            for (int l = 0; l < 32; ++l) {
                const u8 q1 = L[j + l +  0] & 0xF, q2 = L[j + l + 32] & 0xF, q3 = L[j + l + 64] & 0xF, q4 = L[j + l + 96] & 0xF;
                ql[l+ 0] = q1 | (q3 << 4);
                ql[l+32] = q2 | (q4 << 4);
                qh[l] = (u8)((L[j + l] >> 4) | ((L[j + l + 32] >> 4) << 2) | ((L[j + l + 64] >> 4) << 4) | ((L[j + l + 96] >> 4) << 6));
            }
            ql += 64; qh += 32;
        }
        x += QK_K; y += 210;
    }
}

/* the one entry point: type 8 Q8_0, 6 Q5_0, 12 Q4_K, 14 Q6_K, 1 F16; n floats at src, bytes to dst */
__attribute__((export_name("quantize")))
int quantize(int type, const float * src, u8 * dst, int n) {
    switch (type) {
        case 8:  q8_0(src, dst, n); return n/32*34;
        case 6:  q5_0(src, dst, n); return n/32*22;
        case 12: q4_K(src, dst, n); return n/256*144;
        case 14: q6_K(src, dst, n); return n/256*210;
        case 1:  for (int i = 0; i < n; i++) put16(dst + 2*i, fp32_to_fp16(src[i])); return 2*n;
    }
    return -1;
}

/* a simple bump allocator: the page asks for two buffers once */
extern unsigned char __heap_base;
__attribute__((export_name("heap_base")))
int heap_base(void) { return (int)&__heap_base; }

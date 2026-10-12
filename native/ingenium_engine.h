/*
   INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
   NO LICENCE IS GRANTED. See LICENCE.txt.

   The native engine shared by the Android/Fire app and the iPhone/iPad app.
   A small C interface over llama.cpp: load a GGUF model (from a path, or from
   an open FILE* positioned at a GGUF that sits inside a larger file, such as
   the app package itself), then stream a chat reply, with any "thinking" the
   model does kept apart from the answer. All of it runs on the device.
*/
#ifndef INGENIUM_ENGINE_H
#define INGENIUM_ENGINE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ie_model ie_model;

/* kind 0 = answer text, kind 1 = reasoning ("thinking") text */
typedef void (*ie_piece_cb)(void * user, int kind, const char * text, size_t len);
/* progress 0..1 while a model loads; return false to cancel the load */
typedef bool (*ie_progress_cb)(void * user, float progress);
/* level: 2 = info, 3 = warning, 4 = error (ggml's levels) */
typedef void (*ie_log_cb)(int level, const char * text);

/* once per process, before anything else */
void ie_backend_init(ie_log_cb log);

/* "llama.cpp b11321 (CPU: NEON ...)" style description; static string */
const char * ie_version(void);

/* GGUF metadata without loading the weights, as a JSON object (malloc'd; free
   with ie_free_str). Exactly one of path / fp. A FILE* is read from its
   current position and left where it was found. NULL when unreadable. */
char * ie_inspect(const char * path, FILE * fp);

typedef struct ie_load_params {
    int  n_ctx;          /* context length in tokens; 0 = 4096            */
    int  n_threads;      /* CPU threads; 0 = sensible default              */
    int  n_gpu_layers;   /* 0 = CPU only; -1 or 999 = all layers on GPU    */
    bool use_mmap;       /* map the file instead of copying it into RAM    */
} ie_load_params;

/* Load a model. Exactly one of path / fp (fp positioned at the GGUF start;
   it must stay open until ie_free). NULL on failure, with err filled. */
ie_model * ie_load(const char * path, FILE * fp, const ie_load_params * params,
                   ie_progress_cb progress, void * user, char * err, size_t err_len);

/* Stream one chat reply. messages_json is an OpenAI-style array of
   {"role":"system|user|assistant","content":"..."}; params_json may carry
   max_tokens, temperature, top_p, top_k, min_p, repeat_penalty,
   presence_penalty, frequency_penalty, seed and thinking (bool). Blocks until done. Returns a JSON object of statistics
   (malloc'd) or NULL on error, with err filled. */
char * ie_generate(ie_model * m, const char * messages_json, const char * params_json,
                   ie_piece_cb cb, void * user, char * err, size_t err_len);

/* Thread-safe. Ends a running ie_generate (or the prompt reading inside it)
   at the next step. */
void ie_abort(ie_model * m);

/* JSON object describing the loaded model (malloc'd). */
char * ie_model_info(ie_model * m);

void ie_free(ie_model * m);
void ie_free_str(char * s);

#ifdef __cplusplus
}
#endif
#endif

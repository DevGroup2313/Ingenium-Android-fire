/*
   INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
   NO LICENCE IS GRANTED. See LICENCE.txt.

   The native engine shared by the Android/Fire app and the iPhone/iPad app.
   See ingenium_engine.h for the interface. Built on llama.cpp; the chat
   template is applied from the model's own GGUF (Jinja, exactly as
   llama-server does it), and the reply is parsed while it streams so that
   reasoning ("thinking") arrives separately from the answer.
*/
#include "ingenium_engine.h"

#include "chat.h"
#include "common.h"
#include "ggml-backend.h"
#include "gguf.h"
#include "llama.h"

#if defined(IE_CPU_VARIANTS)
#    include <dlfcn.h>
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdarg>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#ifndef IE_LLAMA_TAG
#define IE_LLAMA_TAG "unknown"
#endif

// A saved copy of the part of the context memory that cannot be cut back
// (the running state of a recurrent or hybrid model such as LFM2.5 or
// Qwen3.5), taken when the first n_tokens of `cached` had been read.
struct ie_ckpt {
    size_t               n_tokens = 0;
    std::vector<uint8_t> data;
};

struct ie_model {
    llama_model *             model = nullptr;
    llama_context *           ctx   = nullptr;
    common_chat_templates_ptr tmpls;
    std::vector<llama_token>  cached;      // tokens now held in the context memory (sequence 0)
    std::vector<ie_ckpt>      ckpts;       // oldest first; each one's prefix matches `cached`
    bool                      part_rm = true;  // the memory can be cut back to any point
    std::atomic<bool>         abort{false};
    std::mutex                busy;        // one reply at a time
    int                       n_ctx     = 0;
    int                       n_threads = 0;
    bool                      gpu       = false;
    bool                      mmap      = false;
};

namespace {

ie_log_cb g_log = nullptr;

void log_tramp(ggml_log_level level, const char * text, void *) {
    if (g_log && text) {
        g_log((int) level, text);
    }
}

void set_err(char * err, size_t len, const char * fmt, ...) {
    if (!err || len == 0) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, len, fmt, ap);
    va_end(ap);
}

char * dup_str(const std::string & s) {
    char * out = (char *) malloc(s.size() + 1);
    if (out) {
        memcpy(out, s.data(), s.size());
        out[s.size()] = 0;
    }
    return out;
}

std::string jstr(const std::string & s) {
    std::string o = "\"";
    for (unsigned char c : s) {
        switch (c) {
            case '"':  o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n";  break;
            case '\r': o += "\\r";  break;
            case '\t': o += "\\t";  break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    o += buf;
                } else {
                    o += (char) c;
                }
        }
    }
    return o + "\"";
}

// true when s does not end in the middle of a UTF-8 sequence
bool utf8_complete(const std::string & s) {
    size_t n = s.size();
    for (size_t back = 1; back <= 4 && back <= n; ++back) {
        unsigned char c = (unsigned char) s[n - back];
        if ((c & 0xC0) == 0x80) {
            continue;  // continuation byte, keep looking for the lead byte
        }
        size_t need = 1;
        if ((c & 0xE0) == 0xC0) {
            need = 2;
        } else if ((c & 0xF0) == 0xE0) {
            need = 3;
        } else if ((c & 0xF8) == 0xF0) {
            need = 4;
        }
        return back >= need;
    }
    return true;
}

std::string meta_str(gguf_context * g, const std::string & key) {
    int64_t k = gguf_find_key(g, key.c_str());
    if (k < 0 || gguf_get_kv_type(g, k) != GGUF_TYPE_STRING) {
        return "";
    }
    return gguf_get_val_str(g, k);
}

long long meta_int(gguf_context * g, const std::string & key) {
    int64_t k = gguf_find_key(g, key.c_str());
    if (k < 0) {
        return -1;
    }
    switch (gguf_get_kv_type(g, k)) {
        case GGUF_TYPE_UINT8:  return gguf_get_val_u8(g, k);
        case GGUF_TYPE_INT8:   return gguf_get_val_i8(g, k);
        case GGUF_TYPE_UINT16: return gguf_get_val_u16(g, k);
        case GGUF_TYPE_INT16:  return gguf_get_val_i16(g, k);
        case GGUF_TYPE_UINT32: return gguf_get_val_u32(g, k);
        case GGUF_TYPE_INT32:  return gguf_get_val_i32(g, k);
        case GGUF_TYPE_UINT64: return (long long) gguf_get_val_u64(g, k);
        case GGUF_TYPE_INT64:  return (long long) gguf_get_val_i64(g, k);
        default:               return -1;
    }
}

int default_threads() {
    int n = 0;
    try {
        n = common_cpu_get_num_math();
    } catch (...) {
        n = 0;
    }
    if (n <= 0) {
        n = (int) std::thread::hardware_concurrency();
    }
    if (n <= 0) {
        n = 2;
    }
    return std::max(1, std::min(n, 8));
}

struct progress_bridge {
    ie_progress_cb cb;
    void *         user;
};

bool progress_tramp(float p, void * ud) {
    auto * pb = (progress_bridge *) ud;
    return pb->cb ? pb->cb(pb->user, p) : true;
}

bool abort_tramp(void * ud) {
    return ((ie_model *) ud)->abort.load();
}

// Keep the checkpoints small enough for a phone: at most four, and no more
// than about 96 MB together (the newest is always kept).
void save_ckpt(ie_model * m, size_t n_tokens) {
    const size_t size = llama_state_seq_get_size_ext(m->ctx, 0, LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY);
    if (size == 0) {
        return;
    }
    ie_ckpt c;
    c.n_tokens = n_tokens;
    try {
        c.data.resize(size);
    } catch (...) {
        return;
    }
    if (llama_state_seq_get_data_ext(m->ctx, c.data.data(), size, 0, LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY) != size) {
        return;
    }
    m->ckpts.erase(std::remove_if(m->ckpts.begin(), m->ckpts.end(),
                                  [&](const ie_ckpt & o) { return o.n_tokens == n_tokens; }),
                   m->ckpts.end());
    m->ckpts.push_back(std::move(c));
    const size_t cap_bytes = (size_t) 96 << 20;
    size_t       total     = 0;
    for (const auto & o : m->ckpts) {
        total += o.data.size();
    }
    while (m->ckpts.size() > 1 && (m->ckpts.size() > 4 || total > cap_bytes)) {
        total -= m->ckpts.front().data.size();
        m->ckpts.erase(m->ckpts.begin());
    }
}

// Some chat templates do not let llama.cpp's parser know that the model
// thinks (LFM2.5 Thinking's names only the closing tag), so its <think>
// block arrives as answer text. Split it here, while it streams.
void split_think(common_chat_msg & msg, bool partial) {
    if (!msg.reasoning_content.empty()) {
        return;
    }
    const std::string & c = msg.content;
    size_t              b = 0;
    while (b < c.size() && (c[b] == ' ' || c[b] == '\n' || c[b] == '\r' || c[b] == '\t')) {
        b++;
    }
    static const std::string open = "<think>", close = "</think>";
    if (c.compare(b, open.size(), open) != 0) {
        if (partial && c.size() > b && c.size() - b < open.size() && open.compare(0, c.size() - b, c, b) == 0) {
            msg.content.clear();  // "<thi" so far: wait for the rest of the tag
        }
        return;
    }
    size_t      e    = c.find(close, b + open.size());
    std::string body = c.substr(b + open.size(), e == std::string::npos ? std::string::npos : e - b - open.size());
    std::string rest = e == std::string::npos ? std::string() : c.substr(e + close.size());
    if (e == std::string::npos && partial) {
        // hold back a closing tag that has only partly arrived
        for (size_t k = close.size() - 1; k > 0; --k) {
            if (body.size() >= k && body.compare(body.size() - k, k, close, 0, k) == 0) {
                body.resize(body.size() - k);
                break;
            }
        }
    }
    size_t s0 = body.find_first_not_of(" \n\r\t");
    msg.reasoning_content = s0 == std::string::npos ? std::string() : body.substr(s0);
    size_t r0             = rest.find_first_not_of(" \n\r\t");
    msg.content           = r0 == std::string::npos ? std::string() : rest.substr(r0);
}

}  // namespace

extern "C" {

#if defined(IE_CPU_VARIANTS)
// The processor part of the engine is a separate library, built once per
// generation of chip. Load the best one this device supports from the folder
// that holds this library (the app's unpacked library folder).
static void ie_load_cpu_backend() {
    Dl_info     info;
    std::string dir;
    if (dladdr((void *) &ie_backend_init, &info) && info.dli_fname) {
        std::string f = info.dli_fname;
        size_t      s = f.find_last_of('/');
        if (s != std::string::npos) {
            dir = f.substr(0, s);
        }
    }
    if (!dir.empty() && dir.find('!') == std::string::npos) {
        ggml_backend_load_all_from_path(dir.c_str());
    }
    if (!ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU)) {
        // not found by looking in the folder: ask for each build by name, the
        // newest chips first; a build this device cannot run declines to load
        static const char * names[] = {
            "libggml-cpu-android_armv9.2_2.so", "libggml-cpu-android_armv9.2_1.so", "libggml-cpu-android_armv9.0_1.so",
            "libggml-cpu-android_armv8.6_1.so", "libggml-cpu-android_armv8.2_2.so", "libggml-cpu-android_armv8.2_1.so",
            "libggml-cpu-android_armv8.0_1.so", "libggml-cpu.so",
        };
        for (const char * n : names) {
            if (ggml_backend_load(n)) {
                break;
            }
        }
    }
    if (g_log) {
        g_log(ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU) ? 2 : 4,
              ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU)
                  ? "ingenium: processor part of the engine loaded\n"
                  : "ingenium: no processor part of the engine could be loaded\n");
    }
}
#endif

void ie_backend_init(ie_log_cb log) {
    static std::once_flag once;
    g_log = log;
    std::call_once(once, [] {
        llama_log_set(log_tramp, nullptr);
#if defined(IE_CPU_VARIANTS)
        ie_load_cpu_backend();
#endif
        llama_backend_init();
    });
}

const char * ie_version(void) {
    static std::string v;
    static std::once_flag once;
    std::call_once(once, [] { v = std::string("llama.cpp ") + IE_LLAMA_TAG + " | " + llama_print_system_info(); });
    return v.c_str();
}

char * ie_inspect(const char * path, FILE * fp) {
    gguf_init_params ip = { /*no_alloc*/ true, /*ctx*/ nullptr };
    gguf_context *   g  = nullptr;
    long long        at = 0;
    if (fp) {
        at = (long long) ftello(fp);
        g  = gguf_init_from_file_ptr(fp, ip);
        fseeko(fp, (off_t) at, SEEK_SET);
    } else if (path) {
        g = gguf_init_from_file(path, ip);
    }
    if (!g) {
        return nullptr;
    }
    std::string arch = meta_str(g, "general.architecture");
    std::string o    = "{";
    o += "\"arch\":" + jstr(arch);
    o += ",\"name\":" + jstr(meta_str(g, "general.name"));
    o += ",\"size_label\":" + jstr(meta_str(g, "general.size_label"));
    o += ",\"basename\":" + jstr(meta_str(g, "general.basename"));
    o += ",\"file_type\":" + std::to_string(meta_int(g, "general.file_type"));
    o += ",\"ctx_train\":" + std::to_string(meta_int(g, arch + ".context_length"));
    o += ",\"layers\":" + std::to_string(meta_int(g, arch + ".block_count"));
    o += ",\"has_template\":" + std::string(gguf_find_key(g, "tokenizer.chat_template") >= 0 ? "true" : "false");
    o += ",\"is_projector\":" + std::string(arch == "clip" ? "true" : "false");
    o += ",\"tensors\":" + std::to_string((long long) gguf_get_n_tensors(g));
    o += "}";
    gguf_free(g);
    return dup_str(o);
}

ie_model * ie_load(const char * path, FILE * fp, const ie_load_params * params, ie_progress_cb progress, void * user,
                   char * err, size_t err_len) {
    if (!path && !fp) {
        set_err(err, err_len, "no model file was given");
        return nullptr;
    }
    ie_load_params p = params ? *params : ie_load_params{ 0, 0, 0, true };

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers       = p.n_gpu_layers < 0 ? 999 : p.n_gpu_layers;
    mp.load_mode          = p.use_mmap ? LLAMA_LOAD_MODE_MMAP : LLAMA_LOAD_MODE_NONE;
    progress_bridge pb{ progress, user };
    if (progress) {
        mp.progress_callback           = progress_tramp;
        mp.progress_callback_user_data = &pb;
    }

    long long     start = fp ? (long long) ftello(fp) : 0;
    llama_model * model = fp ? llama_model_load_from_file_ptr(fp, mp) : llama_model_load_from_file(path, mp);
    bool          mmap  = p.use_mmap;
    if (!model && p.use_mmap) {
        // an embedded GGUF that is not aligned in its package cannot be mapped; read it instead
        if (fp) {
            fseeko(fp, (off_t) start, SEEK_SET);
        }
        mp.load_mode = LLAMA_LOAD_MODE_NONE;
        mmap         = false;
        model        = fp ? llama_model_load_from_file_ptr(fp, mp) : llama_model_load_from_file(path, mp);
    }
    if (!model) {
        set_err(err, err_len,
                "The model could not be loaded. The file may be damaged or incomplete, its architecture may be "
                "newer than this engine, or the device may not have enough free memory for it.");
        return nullptr;
    }

    auto * m      = new ie_model();
    m->model      = model;
    m->gpu        = mp.n_gpu_layers > 0;
    m->mmap       = mmap;
    m->n_threads  = p.n_threads > 0 ? p.n_threads : default_threads();

    llama_context_params cp = llama_context_default_params();
    int n_ctx               = p.n_ctx > 0 ? p.n_ctx : 4096;
    int train               = llama_model_n_ctx_train(model);
    if (train > 0 && n_ctx > train) {
        n_ctx = train;
    }
    cp.n_ctx               = (uint32_t) n_ctx;
    cp.n_batch             = 512;
    cp.n_ubatch            = 512;
    cp.n_seq_max           = 1;
    cp.n_threads           = m->n_threads;
    cp.n_threads_batch     = m->n_threads;
    cp.no_perf             = true;
    cp.abort_callback      = abort_tramp;
    cp.abort_callback_data = m;
    m->ctx                 = llama_init_from_model(model, cp);
    if (!m->ctx) {
        llama_model_free(model);
        delete m;
        set_err(err, err_len,
                "The model loaded, but its working memory (a context of %d tokens) could not be set up. Try a "
                "smaller context length or a smaller model.",
                n_ctx);
        return nullptr;
    }
    m->n_ctx = (int) llama_n_ctx(m->ctx);

    // Can the memory be cut back to any point? Attention-only models can; the
    // recurrent and hybrid ones (LFM2.5, Qwen3.5) cannot, so for them the
    // engine keeps checkpoints of their running state instead of reading the
    // whole conversation again whenever the history changes behind the newest
    // message (as it does when earlier thinking is left out of the history).
    try {
        m->part_rm = common_context_can_seq_rm(m->ctx) == COMMON_CONTEXT_SEQ_RM_TYPE_PART;
    } catch (...) {
        m->part_rm = !(llama_model_is_recurrent(model) || llama_model_is_hybrid(model));
    }
    llama_memory_clear(llama_get_memory(m->ctx), true);

    try {
        m->tmpls = common_chat_templates_init(model, "");
    } catch (const std::exception & e) {
        if (g_log) {
            g_log(3, (std::string("ingenium: the model's chat template could not be read (") + e.what() +
                      "); using ChatML\n").c_str());
        }
        try {
            m->tmpls = common_chat_templates_init(model, "chatml");
        } catch (...) {
        }
    }
    if (!m->tmpls) {
        ie_free(m);
        set_err(err, err_len, "The model has no usable chat template.");
        return nullptr;
    }
    return m;
}

char * ie_model_info(ie_model * m) {
    if (!m || !m->model) {
        return nullptr;
    }
    char desc[256] = { 0 };
    llama_model_desc(m->model, desc, sizeof(desc));
    char arch[128] = { 0 };
    llama_model_meta_val_str(m->model, "general.architecture", arch, sizeof(arch));
    char name[256] = { 0 };
    llama_model_meta_val_str(m->model, "general.name", name, sizeof(name));
    bool think = false;
    try {
        think = common_chat_templates_support_enable_thinking(m->tmpls.get());
    } catch (...) {
    }
    std::string o = "{";
    o += "\"desc\":" + jstr(desc);
    o += ",\"arch\":" + jstr(arch);
    o += ",\"name\":" + jstr(name);
    o += ",\"n_params\":" + std::to_string((unsigned long long) llama_model_n_params(m->model));
    o += ",\"size\":" + std::to_string((unsigned long long) llama_model_size(m->model));
    o += ",\"ctx_train\":" + std::to_string(llama_model_n_ctx_train(m->model));
    o += ",\"n_ctx\":" + std::to_string(m->n_ctx);
    o += ",\"threads\":" + std::to_string(m->n_threads);
    o += ",\"gpu\":" + std::string(m->gpu ? "true" : "false");
    o += ",\"mmap\":" + std::string(m->mmap ? "true" : "false");
    o += ",\"supports_thinking\":" + std::string(think ? "true" : "false");
    o += ",\"recurrent\":" +
         std::string(llama_model_is_recurrent(m->model) || llama_model_is_hybrid(m->model) ? "true" : "false");
    o += ",\"checkpoints\":" + std::string(m->part_rm ? "false" : "true");
    o += "}";
    return dup_str(o);
}

void ie_abort(ie_model * m) {
    if (m) {
        m->abort.store(true);
    }
}

char * ie_generate(ie_model * m, const char * messages_json, const char * params_json, ie_piece_cb cb, void * user,
                   char * err, size_t err_len) {
    if (!m || !m->ctx) {
        set_err(err, err_len, "No model is loaded.");
        return nullptr;
    }
    std::lock_guard<std::mutex> lock(m->busy);
    m->abort.store(false);
    const auto t0 = std::chrono::steady_clock::now();

    common_chat_params      chat;
    common_chat_parser_params pp;
    int                     max_tokens = 512;
    float                   temp = 0.7f, top_p = 0.95f, min_p = 0.05f, rep = 1.0f, presence = 0.0f, frequency = 0.0f;
    int                     top_k = 40;
    uint32_t                seed  = LLAMA_DEFAULT_SEED;
    bool                    thinking = false;
    bool                    prefill  = false;
    try {
        common_json msgs = common_json::parse(messages_json ? messages_json : "[]");
        common_json prm  = common_json::parse(params_json && *params_json ? params_json : "{}");
        max_tokens = prm.value("max_tokens", 512);
        temp       = prm.value("temperature", 0.7f);
        top_p      = prm.value("top_p", 0.95f);
        top_k      = prm.value("top_k", 40);
        min_p      = prm.value("min_p", 0.05f);
        rep        = prm.value("repeat_penalty", 1.0f);
        presence   = prm.value("presence_penalty", 0.0f);
        frequency  = prm.value("frequency_penalty", 0.0f);
        thinking   = prm.value("thinking", false);
        // R78: "prefill" reads the conversation only up to where the person's
        // words begin (the last message holds a marker there) and keeps the
        // state, so the first reply of a conversation does not wait for the
        // instructions to be read
        prefill    = prm.value("prefill", false);
        if (prm.contains("seed")) {
            seed = (uint32_t) prm.value("seed", 0LL);
        }

        common_chat_templates_inputs in;
        in.messages                              = common_chat_msgs_parse_oaicompat(msgs);
        in.use_jinja                             = true;
        in.add_generation_prompt                 = true;
        in.enable_thinking                       = thinking;
        in.reasoning_format                      = COMMON_REASONING_FORMAT_DEEPSEEK;
        in.chat_template_kwargs["enable_thinking"] = thinking ? "true" : "false";
        try {
            chat = common_chat_templates_apply(m->tmpls.get(), in);
        } catch (const std::exception & e) {
            if (g_log) {
                g_log(3, (std::string("ingenium: template failed (") + e.what() + "); trying the simple path\n").c_str());
            }
            in.use_jinja = false;
            in.chat_template_kwargs.clear();
            chat = common_chat_templates_apply(m->tmpls.get(), in);
        }
        pp                      = common_chat_parser_params(chat);
        pp.reasoning_format     = COMMON_REASONING_FORMAT_DEEPSEEK;
        pp.reasoning_in_content = false;
        pp.parse_tool_calls     = false;
        if (!chat.parser.empty()) {
            pp.parser.load(chat.parser);
        }
    } catch (const std::exception & e) {
        set_err(err, err_len, "The conversation could not be prepared for this model: %s", e.what());
        return nullptr;
    }

    if (prefill) {
        static const char * MARK = "\xE2\x81\xA3IngeniumPrefill\xE2\x81\xA3";  // U+2063 on both sides
        const size_t        at   = chat.prompt.find(MARK);
        if (at == std::string::npos) {
            set_err(err, err_len, "Reading ahead needs the marker where the person's words begin.");
            return nullptr;
        }
        chat.prompt.resize(at);
    }
    const llama_vocab *      vocab = llama_model_get_vocab(m->model);
    std::vector<llama_token> toks  = common_tokenize(vocab, chat.prompt, /*add_special*/ true, /*parse_special*/ true);
    const int                n_ctx = m->n_ctx;
    if ((int) toks.size() + 8 >= n_ctx) {
        set_err(err, err_len,
                "This conversation (%d tokens) is longer than the model's working memory (%d tokens). Start a new "
                "conversation, or raise the context length.",
                (int) toks.size(), n_ctx);
        return nullptr;
    }
    if (max_tokens <= 0 || max_tokens > n_ctx - (int) toks.size() - 1) {
        max_tokens = n_ctx - (int) toks.size() - 1;
    }

    // reuse whatever the context memory already holds of this prompt
    llama_memory_t mem    = llama_get_memory(m->ctx);
    size_t         n_keep = 0;
    while (n_keep < m->cached.size() && n_keep < toks.size() && m->cached[n_keep] == toks[n_keep]) {
        n_keep++;
    }
    if (prefill && n_keep == toks.size() && n_keep == m->cached.size()) {
        // already read: nothing to do
        return dup_str((std::string("{\"prefill\":true,\"tokens\":0,\"prompt_tokens\":") + std::to_string(toks.size()) +
                        ",\"reused_tokens\":" + std::to_string(n_keep) + ",\"from_checkpoint\":false,\"read_ms\":0,\"stop\":\"prefill\"}").c_str());
    }
    if (!prefill && n_keep == toks.size() && n_keep > 0) {
        n_keep--;  // at least one token must be evaluated to have something to sample from
    }
    bool from_ckpt = false;
    if (n_keep < m->cached.size()) {
        bool cut = llama_memory_seq_rm(mem, 0, (llama_pos) n_keep, -1);
        if (!cut) {
            // the running state cannot be cut back: take the latest checkpoint
            // at or before the point where the conversation changed
            const ie_ckpt * best = nullptr;
            for (const auto & c : m->ckpts) {
                if (c.n_tokens > 0 && c.n_tokens <= n_keep && (!best || c.n_tokens > best->n_tokens)) {
                    best = &c;
                }
            }
            if (best &&
                llama_state_seq_set_data_ext(m->ctx, best->data.data(), best->data.size(), 0,
                                             LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY) == best->data.size() &&
                llama_memory_seq_rm(mem, 0, (llama_pos) best->n_tokens, -1)) {
                n_keep    = best->n_tokens;
                cut       = true;
                from_ckpt = true;
            }
        }
        if (!cut) {
            llama_memory_clear(mem, true);
            n_keep = 0;
        }
    }
    m->cached.resize(n_keep);
    m->ckpts.erase(std::remove_if(m->ckpts.begin(), m->ckpts.end(),
                                  [&](const ie_ckpt & c) { return c.n_tokens > n_keep; }),
                   m->ckpts.end());

    std::string stop = "length";
    auto        fail = [&](const char * what, int rc) -> char * {
        llama_memory_clear(mem, true);
        m->cached.clear();
        m->ckpts.clear();
        set_err(err, err_len, "The engine stopped while %s (code %d).", what, rc);
        return nullptr;
    };

    // read the prompt. For a model kept by checkpoints, the last few tokens
    // (the opening of the reply, which the next turn may write differently)
    // are read separately, and the state just before them is saved: the next
    // turn starts from there instead of from the beginning.
    const size_t n_batch = 512;
    // (reading ahead keeps its state at the very end: the person's words follow it)
    const size_t ck_at   = m->part_rm ? (size_t) -1
                         : prefill ? toks.size()
                         : (toks.size() > n_keep + 4) ? toks.size() - 4 : (size_t) -1;
    for (size_t i = n_keep; i < toks.size();) {
        size_t end = std::min(i + n_batch, toks.size());
        if (ck_at != (size_t) -1 && i < ck_at && end > ck_at) {
            end = ck_at;
        }
        int n  = (int) (end - i);
        int rc = llama_decode(m->ctx, llama_batch_get_one(toks.data() + i, n));
        if (rc != 0) {
            if (m->abort.load()) {
                llama_memory_clear(mem, true);
                m->cached.clear();
                m->ckpts.clear();
                return dup_str("{\"tokens\":0,\"stop\":\"abort\"}");
            }
            return fail("reading the conversation", rc);
        }
        m->cached.insert(m->cached.end(), toks.begin() + i, toks.begin() + end);
        i = end;
        if (i == ck_at) {
            save_ckpt(m, i);
        }
    }
    const auto t_prompt = std::chrono::steady_clock::now();
    if (prefill) {
        char pb[256];
        snprintf(pb, sizeof(pb),
                 "{\"prefill\":true,\"tokens\":0,\"prompt_tokens\":%d,\"reused_tokens\":%d,\"from_checkpoint\":%s,"
                 "\"read_ms\":%.0f,\"stop\":\"prefill\"}",
                 (int) toks.size(), (int) n_keep, from_ckpt ? "true" : "false",
                 std::chrono::duration<double, std::milli>(t_prompt - t0).count());
        return dup_str(pb);
    }

    // sampling chain
    llama_sampler_chain_params sp = llama_sampler_chain_default_params();
    sp.no_perf                    = true;
    llama_sampler * smpl          = llama_sampler_chain_init(sp);
    // repetition, presence and frequency penalties over the last 64 tokens
    // (Qwen3.5's makers recommend a presence penalty; Liquid AI's a small
    // repetition penalty)
    if (rep > 1.0f || presence != 0.0f || frequency != 0.0f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, rep > 0.0f ? rep : 1.0f,
                                                                   frequency, presence));
    }
    if (temp <= 0.0f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
    } else {
        if (top_k > 0) {
            llama_sampler_chain_add(smpl, llama_sampler_init_top_k(top_k));
        }
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(top_p, 1));
        if (min_p > 0.0f) {
            llama_sampler_chain_add(smpl, llama_sampler_init_min_p(min_p, 1));
        }
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(temp));
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(seed));
    }

    // special tokens the template's parser needs to see (e.g. <think>)
    std::set<llama_token> keep_special;
    for (const auto & s : chat.preserved_tokens) {
        auto ids = common_tokenize(vocab, s, false, true);
        if (ids.size() == 1) {
            keep_special.insert(ids[0]);
        }
    }

    std::string     text;
    common_chat_msg shown;  // what has been handed to the caller so far
    auto            emit = [&](bool partial) {
        common_chat_msg now;
        try {
            now = common_chat_parse(text, partial, pp);
        } catch (const std::exception &) {
            if (partial) {
                return;
            }
            now         = shown;
            now.content = text;  // last resort: hand over the raw text
        }
        split_think(now, partial);
        std::vector<common_chat_msg_diff> diffs;
        try {
            diffs = common_chat_msg_diff::compute_diffs(shown, now);
        } catch (const std::exception &) {
            return;
        }
        for (const auto & d : diffs) {
            if (cb && !d.reasoning_content_delta.empty()) {
                cb(user, 1, d.reasoning_content_delta.data(), d.reasoning_content_delta.size());
            }
            if (cb && !d.content_delta.empty()) {
                cb(user, 0, d.content_delta.data(), d.content_delta.size());
            }
        }
        shown = now;
    };

    int n_gen = 0;
    while (n_gen < max_tokens) {
        if (m->abort.load()) {
            stop = "abort";
            break;
        }
        llama_token id = llama_sampler_sample(smpl, m->ctx, -1);
        if (llama_vocab_is_eog(vocab, id)) {
            stop = "stop";
            break;
        }
        std::string piece = common_token_to_piece(vocab, id, keep_special.count(id) > 0);
        text += piece;
        n_gen++;

        bool hit = false;
        for (const auto & s : chat.additional_stops) {
            if (s.empty()) {
                continue;
            }
            size_t from = text.size() > piece.size() + s.size() ? text.size() - piece.size() - s.size() : 0;
            size_t pos  = text.find(s, from);
            if (pos != std::string::npos) {
                text.resize(pos);
                hit = true;
            }
        }
        if (utf8_complete(text)) {
            emit(true);
        }
        if (hit) {
            stop = "stop";
            break;
        }
        if ((int) m->cached.size() + 1 >= n_ctx) {
            stop = "length";
            break;
        }
        int rc = llama_decode(m->ctx, llama_batch_get_one(&id, 1));
        if (rc != 0) {
            if (m->abort.load()) {
                stop = "abort";
                break;
            }
            llama_sampler_free(smpl);
            return fail("writing the reply", rc);
        }
        m->cached.push_back(id);
    }
    llama_sampler_free(smpl);
    emit(false);

    const auto   t1      = std::chrono::steady_clock::now();
    const double ms_read = std::chrono::duration<double, std::milli>(t_prompt - t0).count();
    const double ms_gen  = std::chrono::duration<double, std::milli>(t1 - t_prompt).count();
    char         buf[384];
    snprintf(buf, sizeof(buf),
             "{\"tokens\":%d,\"prompt_tokens\":%d,\"reused_tokens\":%d,\"from_checkpoint\":%s,\"read_ms\":%.0f,"
             "\"gen_ms\":%.0f,\"tokens_per_second\":%.2f,\"stop\":\"%s\"}",
             n_gen, (int) toks.size(), (int) n_keep, from_ckpt ? "true" : "false", ms_read, ms_gen,
             ms_gen > 0 ? n_gen * 1000.0 / ms_gen : 0.0, stop.c_str());
    return dup_str(buf);
}

void ie_free(ie_model * m) {
    if (!m) {
        return;
    }
    m->abort.store(true);
    {
        std::lock_guard<std::mutex> lock(m->busy);
        m->tmpls.reset();
        if (m->ctx) {
            llama_free(m->ctx);
        }
        if (m->model) {
            llama_model_free(m->model);
        }
        m->ctx   = nullptr;
        m->model = nullptr;
    }
    delete m;
}

void ie_free_str(char * s) {
    free(s);
}

}  // extern "C"

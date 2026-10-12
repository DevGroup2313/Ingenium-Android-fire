// Desktop check of the shared engine: build against a llama.cpp tree and run
//   engine_test <model.gguf> [--embedded]
// --embedded copies the model into a larger file at a 4096-byte offset and
// loads it through a FILE*, the way the Android app reads its built-in model
// straight out of the installed package.
#include "../ingenium_engine.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

static void on_log(int level, const char * text) {
    if (level >= 3) {
        fprintf(stderr, "[llama %d] %s", level, text);
    }
}

struct sink {
    std::string answer, thinking;
    int         pieces = 0;
};

static void on_piece(void * user, int kind, const char * text, size_t len) {
    auto * s = (sink *) user;
    (kind == 1 ? s->thinking : s->answer).append(text, len);
    s->pieces++;
}

static bool on_progress(void *, float p) {
    static int last = -1;
    int        pct  = (int) (p * 100);
    if (pct / 25 != last / 25) {
        fprintf(stderr, "  load %d%%\n", pct);
    }
    last = pct;
    return true;
}

static int ask(ie_model * m, const char * msgs, const char * params, const char * label, bool expect_thinking) {
    sink s;
    char err[512] = { 0 };
    auto t0       = std::chrono::steady_clock::now();
    char * stats  = ie_generate(m, msgs, params, on_piece, &s, err, sizeof(err));
    double secs   = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    if (!stats) {
        printf("FAIL %s: %s\n", label, err);
        return 1;
    }
    printf("--- %s (%.1fs, %d pieces)\n  thinking: %s\n  answer:   %s\n  stats:    %s\n", label, secs, s.pieces,
           s.thinking.empty() ? "(none)" : (s.thinking.substr(0, 160) + (s.thinking.size() > 160 ? "..." : "")).c_str(),
           s.answer.substr(0, 300).c_str(), stats);
    ie_free_str(stats);
    if (s.answer.empty() && !expect_thinking) {
        printf("FAIL %s: empty answer\n", label);
        return 1;
    }
    if (expect_thinking && s.thinking.empty()) {
        printf("NOTE %s: no separate thinking came back\n", label);
    }
    return 0;
}

int main(int argc, char ** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s model.gguf [--embedded]\n", argv[0]);
        return 2;
    }
    bool embedded = argc > 2 && !strcmp(argv[2], "--embedded");
    ie_backend_init(on_log);
    printf("engine: %s\n", ie_version());

    FILE *      fp  = nullptr;
    std::string tmp = "/tmp/ingenium_embedded_test.bin";
    if (embedded) {
        FILE * in  = fopen(argv[1], "rb");
        FILE * out = fopen(tmp.c_str(), "wb");
        if (!in || !out) {
            fprintf(stderr, "cannot prepare embedded copy\n");
            return 2;
        }
        std::string pad(4096, 'Z');
        fwrite(pad.data(), 1, pad.size(), out);
        char   buf[1 << 16];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
            fwrite(buf, 1, n, out);
        }
        fwrite("TRAILING-ZIP-DATA", 1, 17, out);
        fclose(in);
        fclose(out);
        fp = fopen(tmp.c_str(), "rb");
        fseeko(fp, 4096, SEEK_SET);
    }

    char * info = ie_inspect(embedded ? nullptr : argv[1], fp);
    printf("inspect: %s\n", info ? info : "(null)");
    if (!info) {
        return 1;
    }
    ie_free_str(info);
    if (fp && ftello(fp) != 4096) {
        printf("FAIL: inspect moved the file position\n");
        return 1;
    }

    ie_load_params lp{ 4096, 0, 0, true };
    char           err[512] = { 0 };
    ie_model *     m        = ie_load(embedded ? nullptr : argv[1], fp, &lp, on_progress, nullptr, err, sizeof(err));
    if (!m) {
        printf("FAIL load: %s\n", err);
        return 1;
    }
    info = ie_model_info(m);
    printf("model: %s\n", info);
    ie_free_str(info);

    int bad = 0;
    bad += ask(m, R"([{"role":"user","content":"What is 17 times 3? Answer briefly."}])",
               R"({"max_tokens":64,"temperature":0,"thinking":false})", "arithmetic, thinking off", false);
    bad += ask(m,
               R"([{"role":"user","content":"What is 17 times 3? Answer briefly."},{"role":"assistant","content":"51"},{"role":"user","content":"And that number plus 9?"}])",
               R"({"max_tokens":64,"temperature":0,"thinking":false})", "follow-up turn (memory reuse)", false);
    bad += ask(m, R"([{"role":"system","content":"You answer in French."},{"role":"user","content":"Say good morning."}])",
               R"({"max_tokens":48,"temperature":0.7,"top_p":0.9,"repeat_penalty":1.1,"seed":7})", "system prompt + sampling",
               false);
    bad += ask(m, R"([{"role":"user","content":"Is 91 a prime number?"}])",
               R"({"max_tokens":400,"temperature":0,"thinking":true})", "thinking on", true);
    bad += ask(m, R"([{"role":"user","content":"Écris un mot avec des accents et un emoji 🌧️."}])",
               R"({"max_tokens":40,"temperature":0})", "unicode", false);

    // stop from another thread while it writes
    {
        sink              s;
        std::atomic<bool> done{ false };
        std::thread       stopper([&] {
            std::this_thread::sleep_for(std::chrono::milliseconds(400));
            ie_abort(m);
        });
        char * st = ie_generate(m, R"([{"role":"user","content":"Count from 1 to 500, one number per line."}])",
                                R"({"max_tokens":2000,"temperature":0})", on_piece, &s, err, sizeof(err));
        stopper.join();
        printf("--- abort: %s, %zu chars before stopping\n", st ? st : err, s.answer.size());
        if (!st || !strstr(st, "\"abort\"")) {
            printf("FAIL abort did not report abort\n");
            bad++;
        }
        ie_free_str(st);
    }
    // the model must still answer after a stop
    bad += ask(m, R"([{"role":"user","content":"Name one colour."}])", R"({"max_tokens":16,"temperature":0})",
               "after abort", false);

    ie_free(m);
    if (fp) {
        fclose(fp);
        remove(tmp.c_str());
    }
    printf(bad ? "\nRESULT: %d problem(s)\n" : "\nRESULT: all checks passed\n", bad);
    return bad ? 1 : 0;
}

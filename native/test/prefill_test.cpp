// R78: reading ahead. The engine reads a conversation's instructions before the
// person writes, then the first reply reads only the person's words.
//   prefill_test <model.gguf>
// It asks the same question twice on a fresh engine: once cold, once after
// reading ahead, and checks that the second reply reused the instructions,
// read far fewer tokens, and gave the same answer.
#include "../ingenium_engine.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>

static void on_log(int level, const char * text) { if (level == 4) fprintf(stderr, "[llama %d] %s", level, text); }
struct sink { std::string answer; };
static void on_piece(void * user, int kind, const char * text, size_t len) { if (kind == 0) ((sink *) user)->answer.append(text, len); }
static int num(const std::string & js, const char * key) {
    size_t p = js.find(std::string("\"") + key + "\":"); if (p == std::string::npos) return -1;
    return atoi(js.c_str() + p + strlen(key) + 3);
}
static std::string run(ie_model * m, const std::string & msgs, const char * params, sink * s, double * secs) {
    char err[512] = { 0 }; auto t0 = std::chrono::steady_clock::now();
    char * st = ie_generate(m, msgs.c_str(), params, on_piece, s, err, sizeof(err));
    *secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    if (!st) { printf("FAIL: %s\n", err); exit(1); }
    std::string r = st; ie_free_str(st); return r;
}
int main(int argc, char ** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s model.gguf\n", argv[0]); return 2; }
    ie_backend_init(on_log);
    std::string sys;
    for (int i = 0; i < 24; i++) sys += "Rule " + std::to_string(i + 1) + ": answer plainly, say when you are not certain, and never invent a source. ";
    const std::string MARK = "\xE2\x81\xA3IngeniumPrefill\xE2\x81\xA3";
    const std::string q = "What is the capital of France? Answer in one word.";
    auto conv = [&](const std::string & s, const std::string & u) {
        return std::string("[{\"role\":\"system\",\"content\":\"") + s + "\"},{\"role\":\"user\",\"content\":\"" + u + "\"}]"; };
    const char * gen = "{\"max_tokens\":12,\"temperature\":0}";
    int fails = 0;
    for (int pass = 0; pass < 2; pass++) {
        ie_load_params lp = { 4096, 4, 0, true };
        char err[512] = { 0 };
        ie_model * m = ie_load(argv[1], nullptr, &lp, nullptr, nullptr, err, sizeof(err));
        if (!m) { printf("FAIL load: %s\n", err); return 1; }
        sink a, b; double ta, tp, tb;
        if (pass == 0) {
            std::string sa = run(m, conv(sys, q), gen, &a, &ta);
            printf("cold:        %.2fs  %s  answer %s\n", ta, sa.c_str(), a.answer.c_str());
        } else {
            std::string sp = run(m, conv(sys, MARK), "{\"prefill\":true}", &a, &tp);
            std::string again = run(m, conv(sys, MARK), "{\"prefill\":true}", &a, &tp);
            std::string sb = run(m, conv(sys, q), gen, &b, &tb);
            printf("read ahead:  %s\n  again:     %s\n", sp.c_str(), again.c_str());
            printf("first reply: %.2fs  %s  answer %s\n", tb, sb.c_str(), b.answer.c_str());
            int pt = num(sp, "prompt_tokens"), reused = num(sb, "reused_tokens"), total = num(sb, "prompt_tokens");
            if (sp.find("\"prefill\":true") == std::string::npos || pt < 100) { printf("FAIL: reading ahead did not read the instructions\n"); fails++; }
            if (num(again, "reused_tokens") != pt) { printf("FAIL: reading ahead twice read again\n"); fails++; }
            if (reused != pt) { printf("FAIL: the reply reused %d of the %d tokens read ahead\n", reused, pt); fails++; }
            if (total - reused > 40) { printf("FAIL: the reply still read %d tokens\n", total - reused); fails++; }
            if (b.answer.find("Paris") == std::string::npos) { printf("FAIL: the answer changed: %s\n", b.answer.c_str()); fails++; }
            // a missing marker is refused, plainly
            sink c; char e2[256] = { 0 };
            char * bad = ie_generate(m, conv(sys, "no marker").c_str(), "{\"prefill\":true}", on_piece, &c, e2, sizeof(e2));
            if (bad || !strstr(e2, "marker")) { printf("FAIL: a prefill without the marker was not refused\n"); fails++; if (bad) ie_free_str(bad); }
        }
        ie_free(m);
    }
    printf(fails ? "\n%d check(s) failed\n" : "\nall checks passed\n", fails);
    return fails ? 1 : 0;
}

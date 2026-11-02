# Ingenium's model converter (R72)

The page converts models into GGUF on the device itself: Hugging Face safetensors,
PyTorch `.bin`/`.pt`, MLX (2, 4 and 8-bit) and large GGUF files (a smaller copy).
Families: Llama, Mistral, Qwen2, Qwen2.5 and Qwen3, and models built on them.
Quality settings: Q4_K_M, Q8_0 and F16, chosen tensor by tensor as llama-quantize does.

| File | What it is |
| --- | --- |
| `ingconv_core.js` | Half floats and the quantizers (Q8_0, Q5_0, Q4_K, Q6_K) in JavaScript, every step in 32-bit floats |
| `quant.c`, `quant.wasm` | The same quantizers in C, from llama.cpp's `ggml-quants.c` (b11321, MIT), built for WebAssembly; about five times faster |
| `ingconv_read.js` | Readers: safetensors, PyTorch zip files (a pickle reader that accepts only tensors), GGUF, MLX dequantizing |
| `ingconv_vocab.js` | Tokenizers: byte-level BPE (with llama.cpp's fingerprint, found by tokenizing its test text), SentencePiece, special tokens |
| `ingconv_main.js` | Model families, tensor names and types, the GGUF writer, and the pipeline that keeps several pieces in flight |
| `ingconv_ui.js` | The "Convert a model" card, the pool of workers, and where the file goes (phone and tablet bridge, computer app, browser) |
| `chkhsh.json` | llama.cpp's table of tokenizer fingerprints (`conversion/base.py`) |
| `embed_conv.py` | Puts all of the above into `ingenium.html` (run it again after a change) |
| `test_conv.js`, `ggdump.py` | Converts a model folder with Node and dumps a GGUF for comparison with llama.cpp's own output |

Rebuilding the WebAssembly (needs clang with the wasm32 target):

    clang --target=wasm32 -O2 -ffp-contract=off -fno-builtin -nostdlib -Wl,--no-entry \
      -Wl,--export-dynamic -Wl,--initial-memory=1048576 -Wl,--max-memory=1073741824 \
      -Wl,--strip-all -o quant.wasm quant.c
    python3 embed_conv.py ../../ingenium.html

## What was checked (7 October 2026)

Each conversion was compared with llama.cpp's own tools (convert_hf_to_gguf.py and
llama-quantize, release b11321), tensor by tensor and key by key:

* SmolLM2 135M Instruct (Llama family, byte-level BPE): F16, Q8_0 and Q4_K_M identical.
* Qwen2.5 0.5B Instruct: F16 and Q4_K_M identical. Qwen3 0.6B: F16 and Q4_K_M identical.
* TinyLlama v0 (SentencePiece): identical from safetensors and from its PyTorch `.bin`.
* A smaller copy of SmolLM2's F16 GGUF: identical to llama-quantize's Q4_K_M.
* MLX Qwen2.5 0.5B Instruct 4-bit (llama.cpp cannot read MLX): converted to Q8_0, it
  answered "Paris" to "What is the capital of France?" and wrote coherent sentences.
* Tokenizer fingerprints matched llama.cpp's table for SmolLM2, Qwen2.5, Qwen3,
  Llama 3.2, DeepSeek R1 Distill Qwen, GPT-2, Qwen2.5 Coder, Granite 3.3 and Phi-2.
* Llama 3's rope scaling factors matched PyTorch's values exactly.

Identical output needs the same input values: llama-quantize reads an F16 file, so the
comparisons rounded the weights through F16 first (`test_conv.js ... viaF16`). The app
quantizes from the original values, which is at least as accurate.

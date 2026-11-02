# embed_conv.py <ingenium.html> : puts the R72 converter into the page (idempotent)
import base64, json, re, sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
P = sys.argv[1]
s = open(P, encoding='utf-8').read()
def strip_export(js):
    return re.sub(r'\nif\(typeof module!=="undefined"\)module\.exports=IC[A-Z];\s*$', '\n', js)
mods = ''.join(strip_export(open(os.path.join(HERE, f), encoding='utf-8').read()) for f in
               ['ingconv_core.js', 'ingconv_read.js', 'ingconv_vocab.js', 'ingconv_main.js', 'ingconv_ui.js'])
fps = json.load(open(os.path.join(HERE, 'chkhsh.json')))
fp_js = ('/* llama.cpp\'s list of BPE tokenizer fingerprints (conversion/base.py, release b11321) */\n'
         'var ING_TOKENIZER_FINGERPRINTS=' + json.dumps(fps, separators=(',', ':')) + ';\n')
block = '/* ==== R72 converter: begin ==== */\n' + fp_js + mods + '/* ==== R72 converter: end ==== */\n'
if '/* ==== R72 converter: begin ==== */' in s:
    s = re.sub(r'/\* ==== R72 converter: begin ==== \*/[\s\S]*?/\* ==== R72 converter: end ==== \*/\n', lambda m: block, s, count=1)
else:
    anchor = "/* R70: the cloud build's test inside the apps"
    assert s.count(anchor) == 1
    s = s.replace(anchor, block + anchor)
wasm = base64.b64encode(open(os.path.join(HERE, 'quant.wasm'), 'rb').read()).decode()
slot = '<script id="ingenium-quant-wasm" type="ingenium/quant-wasm">' + wasm + '</script>'
if 'id="ingenium-quant-wasm"' in s:
    s = re.sub(r'<script id="ingenium-quant-wasm"[^>]*>[^<]*</script>', lambda m: slot, s, count=1)
else:
    anchor = '<script id="ingenium-kit-bundle"'
    assert s.count(anchor) == 1
    s = s.replace(anchor, slot + '\n' + anchor)
css = '''/* R72: the converter's card */
.conv-pick{display:flex; gap:8px; flex-wrap:wrap; margin-top:10px}
#convCard.over{outline:2px dashed rgba(var(--accent-line-rgb),.45); outline-offset:3px}
.conv-head{margin-top:12px; padding-top:10px; border-top:1px solid var(--hairline)}
.conv-what{font-size:15px; color:var(--ink-1); overflow-wrap:anywhere}
.conv-opts{display:flex; flex-direction:column; gap:6px; margin-top:10px}
.conv-opt{display:flex; gap:9px; align-items:flex-start; padding:9px 10px; border:1px solid var(--hairline); border-radius:10px; cursor:pointer; background:var(--input-bg)}
.conv-opt input{margin-top:3px; flex:0 0 auto}
.conv-opt:has(input:checked){border-color:rgba(var(--accent-line-rgb),.55); background:var(--accent-softer)}
.conv-name{margin-top:10px; display:flex; flex-direction:column; gap:4px}
.conv-go{margin-top:12px; display:flex; flex-wrap:wrap; gap:8px; align-items:center}
.conv-bar{flex:1 1 100%; height:8px; border-radius:5px; background:var(--input-bg-hi); overflow:hidden}
.conv-bar i{display:block; height:100%; width:0; background:linear-gradient(90deg,var(--fill-hi),var(--fill-lo)); transition:width .25s ease}
#convProg{flex:1 1 100%; font-variant-numeric:tabular-nums}
#convNote:empty{display:none}
'''
if '/* R72: the converter\'s card */' not in s:
    anchor = '.dropzone{border:1.5px dashed'
    assert s.count(anchor) == 1
    s = s.replace(anchor, css + anchor)
html = '''      <div class="card" id="convCard">
        <h2 class="sec">Convert a model</h2>
        <p class="small muted" style="margin-top:0">Turns a model in another form into a GGUF file this app runs: Hugging Face's safetensors, PyTorch's .bin or .pt, and MLX (made for Macs). It also makes a smaller copy of a large GGUF. The work happens here, on this device; nothing is uploaded.</p>
        <div class="conv-pick">
          <button class="btn" id="convChoose">Choose the model's files</button>
          <button class="btn ghost" id="convFolder">Choose its folder</button>
          <input type="file" id="convFiles" multiple style="display:none">
        </div>
        <div class="small muted" style="margin-top:8px">Choose every file in the model's folder: config.json, the tokenizer files (tokenizer.json or tokenizer.model, with tokenizer_config.json) and the weights (.safetensors or .bin). The families it converts: Llama, Mistral, Qwen2, Qwen2.5 and Qwen3, and the many models built on them, such as SmolLM, TinyLlama and DeepSeek's Qwen-based models. The result is checked to match what llama.cpp's own tools make.</div>
        <div id="convPlan"></div>
        <div class="small" id="convNote" style="margin-top:8px"></div>
      </div>
'''
if 'id="convCard"' not in s:
    anchor = '''      <div class="card">
        <h2 class="sec">Your models</h2>'''
    assert s.count(anchor) == 1
    s = s.replace(anchor, html + anchor)
# the texts that said other forms need separate tools
s = s.replace('Accepts .gguf (runs directly), and .safetensors, .pt, .pth, .bin to convert first. The file stays on this device.',
              'Accepts .gguf, which runs directly. A model in another form (.safetensors, .bin, .pt, MLX) is converted below. The file stays on this device.')
s = s.replace('PyTorch files (.pt, .pth, .bin) and .safetensors need a one time conversion to GGUF with separate tools.',
              'PyTorch files (.pt, .pth, .bin), .safetensors and MLX models are converted to GGUF once, here, with "Convert a model" below.')
s = s.replace('Choose GGUF model files (.gguf). Other formats need converting to GGUF first.',
              'Choose GGUF model files (.gguf). A model in another form can be converted below, under Convert a model.')
# drops and picks that hold a model's folder go to the converter
old = 'function addEntries(entries){if(!entries||!entries.length)return;entries.forEach(function(en){'
new = '''function addEntries(entries){if(!entries||!entries.length)return;
  /* R72: a model's folder (its config, tokenizer and weights in another form) goes to the converter */
  var conv=entries.map(function(en){return en.file;});
  if(typeof convOpen==="function"&&conv.some(function(f){return /(^|\\/)config\\.json$|\\.(safetensors|pt|pth)$/i.test(f.name);})){convOpen(conv);return;}
  entries.forEach(function(en){'''
if 'R72: a model\'s folder' not in s:
    assert s.count(old) == 1
    s = s.replace(old, new)
open(P, 'w', encoding='utf-8').write(s)
print('embedded: %d KB of converter code, %d bytes of WebAssembly' % (len(block) // 1024, len(wasm) * 3 // 4))

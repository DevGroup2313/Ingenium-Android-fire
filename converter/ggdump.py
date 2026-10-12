# ggdump.py <file.gguf> : metadata and tensors in a comparable form
import sys, hashlib, json
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'llama.cpp', 'gguf-py'))
from gguf import GGUFReader, GGUFValueType
r = GGUFReader(sys.argv[1])
out = {}
for f in r.fields.values():
    if f.name.startswith('GGUF.'): continue
    t = f.types[0] if f.types else None
    if t == GGUFValueType.ARRAY:
        sub = f.types[1] if len(f.types) > 1 else None
        if sub == GGUFValueType.STRING:
            vals = [bytes(f.parts[i]).decode('utf-8', 'replace') for i in f.data]
        else:
            vals = [f.parts[i].tolist()[0] for i in f.data]
        h = hashlib.sha256(json.dumps(vals).encode()).hexdigest()[:12]
        out[f.name] = 'array[%s] n=%d sha=%s first=%s' % (sub.name if sub else '?', len(vals), h, json.dumps(vals[:4])[:120])
    elif t == GGUFValueType.STRING:
        v = bytes(f.parts[f.data[0]]).decode('utf-8', 'replace')
        out[f.name] = 'str ' + (v if len(v) < 90 else v[:60] + '... len=%d sha=%s' % (len(v), hashlib.sha256(v.encode()).hexdigest()[:12]))
    else:
        out[f.name] = '%s %r' % (t.name, f.parts[f.data[0]].tolist()[0])
for k in sorted(out): print('KV', k, '=', out[k])
for t in r.tensors:
    print('T', t.name, list(map(int, t.shape)), t.tensor_type.name, hashlib.sha256(bytes(t.data.tobytes())).hexdigest()[:16])

/* ============ R72: the converter, part 4: from a model folder to one GGUF file ============
   inspect(files) looks at what the person chose and says what it is; convert(plan,
   sink, opts) writes the GGUF, piece by piece, to a sink {write(bytes), close()}.
   The model families follow llama.cpp's converter (conversion/llama.py, qwen.py):
   Llama and Mistral (and the many models built on them, such as SmolLM and
   TinyLlama), Qwen2 and Qwen2.5, and Qwen3. Quality settings follow llama-quantize:
   Q4_K_M (small and fast), Q8_0 (near the original) and F16 (the original). */
var ICM=(function(){
  "use strict";
  var ARCH={
    LlamaForCausalLM:"llama",LLaMAForCausalLM:"llama",MistralForCausalLM:"llama",
    Qwen2ForCausalLM:"qwen2",Qwen3ForCausalLM:"qwen3"};
  var FTYPE={F32:0,F16:1,Q8_0:7,Q4_K_M:15};
  function baseName(n){return n.split(/[\\/]/).pop();}
  function lower(n){return baseName(n).toLowerCase();}
  function readText(f){return f.read(0,f.size).then(function(b){return new TextDecoder("utf-8").decode(b);});}
  function readJson(f){return readText(f).then(function(t){try{return JSON.parse(t);}catch(e){throw new Error(baseName(f.name)+" is not valid JSON");}});}
  /* ---------- what was chosen ---------- */
  function inspect(files){
    var by={};files.forEach(function(f){by[lower(f.name)]=f;});
    function get(n){return by[n]||null;}
    var weights=files.filter(function(f){return /\.safetensors$/i.test(f.name);}),kind="safetensors";
    if(!weights.length){weights=files.filter(function(f){return /\.(bin|pt|pth)$/i.test(f.name)&&!/training_args|optimizer|scheduler|rng_state/i.test(f.name);});kind="pytorch";}
    var gg=files.filter(function(f){return /\.gguf$/i.test(f.name);});
    if(gg.length===1&&!weights.length)return ICR.gguf(gg[0]).then(function(g){return {kind:"gguf",gguf:g,file:gg[0],files:files};});
    if(!weights.length)throw new Error(gg.length>1?"Choose one GGUF file at a time.":"No model weights were chosen. Choose all the files in the model's folder: config.json, the tokenizer files, and the .safetensors (or .bin) files.");
    if(!get("config.json"))throw new Error("config.json is missing. Choose every file in the model's folder, including config.json.");
    var p={kind:kind,files:files,weights:weights};
    return Promise.all([readJson(get("config.json")),get("tokenizer.json")?readJson(get("tokenizer.json")):null,
        get("tokenizer_config.json")?readJson(get("tokenizer_config.json")):null,get("generation_config.json")?readJson(get("generation_config.json")).catch(function(){return null;}):null,
        get("tokenizer.model")?get("tokenizer.model").read(0,get("tokenizer.model").size):null,
        get("added_tokens.json")?readJson(get("added_tokens.json")):null,get("merges.txt")?readText(get("merges.txt")):null,
        get("chat_template.jinja")?readText(get("chat_template.jinja")):(get("chat_template.json")?readJson(get("chat_template.json")).then(function(j){return j.chat_template;}):null)])
      .then(function(r){p.config=r[0];p.tokJson=r[1];p.tokConfig=r[2];p.genConfig=r[3];p.spm=r[4];p.addedJson=r[5];p.mergesTxt=r[6];p.extraTemplate=r[7];
        var cfg=p.config.text_config?Object.assign({},p.config,p.config.text_config):p.config;p.hp=cfg;
        var hf=(cfg.architectures||[])[0]||"";p.hfArch=hf;p.arch=ARCH[hf]||null;
        if(!p.arch)throw new Error("This model's family ("+(hf||cfg.model_type||"unknown")+") cannot be converted here yet. Ingenium converts Llama, Mistral, Qwen2, Qwen2.5 and Qwen3 models, and the many built on them. A GGUF copy of this model may already exist on Hugging Face.");
        if(!p.tokJson&&!p.spm)throw new Error("The tokenizer is missing: choose tokenizer.json (or tokenizer.model) too.");
        return Promise.all(weights.map(function(f){return kind==="safetensors"?ICR.safetensors(f):ICR.torchZip(f);}));})
      .then(function(list){var all={};list.forEach(function(x){x.tensors.forEach(function(t){all[t.name]=t;});});p.tensors=all;
        /* MLX: quantized weights come with .scales and .biases */
        var q=p.config.quantization||p.config.quantization_config;p.mlx=!!(q&&q.bits&&q.group_size&&Object.keys(all).some(function(k){return /\.scales$/.test(k);}));
        if(p.mlx){p.mlxq=q;if([2,4,8].indexOf(q.bits)<0)throw new Error("This MLX model uses "+q.bits+"-bit weights; Ingenium reads 2, 4 and 8-bit MLX models.");}
        else if(q&&q.quant_method)throw new Error("This model is already quantized ("+q.quant_method+"); choose the original (unquantized) model instead.");
        p.params=Object.keys(all).reduce(function(a,k){if(/\.(scales|biases)$/.test(k))return a;var t=all[k],n=t.shape.reduce(function(x,y){return x*y;},1);
          if(p.mlx&&all[k.replace(/\.weight$/,".scales")]&&t.dtype==="U32")n*=32/(p.mlxq.bits);return a+n;},0);
        return p;});}
  /* ---------- the model's settings, as GGUF keys ---------- */
  function find(hp,keys){for(var i=0;i<keys.length;i++)if(hp[keys[i]]!=null)return hp[keys[i]];return null;}
  function sizeLabel(n){var u=[[1e12,"T"],[1e9,"B"],[1e6,"M"],[1e3,"K"]];for(var i=0;i<u.length;i++)if(n>=u[i][0]){var v=n/u[i][0];return (v>=100?Math.round(v):Math.round(v*10)/10)+u[i][1];}return String(n);}
  function kvFor(p,ftype,name){
    var hp=p.hp,a=p.arch,kv=[],nl=find(hp,["num_hidden_layers","n_layers","n_layer"]);
    function add(k,t,v){kv.push({key:k,type:t,value:v});}
    add("general.architecture","str",a);add("general.type","str","model");add("general.name","str",name);
    add("general.size_label","str",sizeLabel(p.params));
    var g=p.genConfig;if(g){
      [["top_k","general.sampling.top_k","i32"],["top_p","general.sampling.top_p","f32"],["min_p","general.sampling.min_p","f32"],["temperature","general.sampling.temp","f32"],
       ["repetition_penalty","general.sampling.penalty_repeat","f32"]].forEach(function(s){if(typeof g[s[0]]==="number")add(s[1],s[2],g[s[0]]);});}
    if(a==="llama")add(a+".vocab_size","u32",hp.vocab_size);
    add(a+".block_count","u32",nl);
    var ctx=find(hp,["max_position_embeddings","n_ctx","n_positions","max_length","max_sequence_length","model_max_length"]);if(ctx!=null)add(a+".context_length","u32",ctx);
    add(a+".embedding_length","u32",hp.hidden_size);
    var ff=find(hp,["intermediate_size","n_inner","hidden_dim"]);if(ff!=null)add(a+".feed_forward_length","u32",ff);
    add(a+".attention.head_count","u32",hp.num_attention_heads);
    /* transformers' defaults, which llama.cpp's converter sees: as many key-value heads as heads */
    var kvh=find(hp,["num_key_value_heads","n_kv_heads"]);add(a+".attention.head_count_kv","u32",kvh!=null?kvh:hp.num_attention_heads);
    var rp=Object.assign({},hp.rope_scaling||{},hp.rope_parameters||{}),rt=rp.rope_type||rp.type,theta=rp.rope_theta!=null?rp.rope_theta:(hp.rope_theta!=null?hp.rope_theta:10000);
    if(rt==="linear"&&rp.factor!=null){add(a+".rope.scaling.type","str","linear");add(a+".rope.scaling.factor","f32",rp.factor);}
    else if(rt==="yarn"&&rp.factor!=null){add(a+".rope.scaling.type","str","yarn");add(a+".rope.scaling.factor","f32",rp.factor);
      if(rp.original_max_position_embeddings!=null)add(a+".rope.scaling.original_context_length","u32",rp.original_max_position_embeddings);}
    if(theta!=null)add(a+".rope.freq_base","f32",theta);
    var eps=find(hp,["rms_norm_eps","norm_eps"]);if(eps!=null)add(a+".attention.layer_norm_rms_epsilon","f32",eps);
    var hd=hp.head_dim!=null?hp.head_dim:(a==="llama"?Math.floor(hp.hidden_size/hp.num_attention_heads):null);
    if(hd!=null){add(a+".attention.key_length","u32",hd);add(a+".attention.value_length","u32",hd);}
    if(a==="llama")add(a+".rope.dimension_count","u32",hp.head_dim!=null?hp.head_dim:Math.floor(hp.hidden_size/hp.num_attention_heads));
    add("general.file_type","u32",FTYPE[ftype]);add("general.quantization_version","u32",2);
    return kv;}
  /* ---------- the tokenizer, as GGUF keys ---------- */
  function vocabKv(p,report){
    var kv=[],hp=p.hp,nv=hp.vocab_size;
    function add(k,t,v){kv.push({key:k,type:t,value:v});}
    var tc=p.tokConfig;
    if(p.arch==="llama"&&tc&&typeof tc.add_prefix_space==="boolean")add("tokenizer.ggml.add_space_prefix","bool",tc.add_prefix_space);
    var useSpm=!!p.spm,sv,v;
    if(useSpm){v=ICV.spmVocab(ICV.readSpm(p.spm),p.addedJson,tc,nv);
      add("tokenizer.ggml.model","str","llama");add("tokenizer.ggml.pre","str","default");
      add("tokenizer.ggml.tokens","arr:str",v.tokens);add("tokenizer.ggml.scores","arr:f32",v.scores);add("tokenizer.ggml.token_type","arr:i32",v.types);
      sv=ICV.specialVocab(p.tokJson,tc,p.config,v.tokens.length,p.extraTemplate);report.tokenizer="SentencePiece";}
    else{var hfv=p.arch==="llama"?ICV.llamaHfVocab(p.tokJson):null;
      var isL3=p.tokJson.model.type==="BPE"&&p.tokJson.model.ignore_merges&&!p.tokJson.model.byte_fallback;
      if(hfv&&!isL3&&p.tokJson.decoder&&p.tokJson.decoder.type==="Sequence"){
        add("tokenizer.ggml.model","str","llama");add("tokenizer.ggml.pre","str","default");
        add("tokenizer.ggml.tokens","arr:str",hfv.tokens);add("tokenizer.ggml.scores","arr:f32",hfv.scores);add("tokenizer.ggml.token_type","arr:i32",hfv.types);
        sv=ICV.specialVocab(p.tokJson,tc,p.config,null,p.extraTemplate);report.tokenizer="SentencePiece (tokenizer.json)";}
      else{if(p.tokJson.model.type!=="BPE")throw new Error("This tokenizer ("+p.tokJson.model.type+") is not supported yet.");
        var pre=ICV.detectPre(p.tokJson,tc);report.pre=pre;
        v=ICV.gpt2Vocab(p.tokJson,tc,nv);
        add("tokenizer.ggml.model","str","gpt2");add("tokenizer.ggml.pre","str",pre.name);
        add("tokenizer.ggml.tokens","arr:str",v.tokens);add("tokenizer.ggml.token_type","arr:i32",v.types);
        var mg=ICV.merges(p.tokJson,p.mergesTxt);if(mg.length)add("tokenizer.ggml.merges","arr:str",mg);
        sv=ICV.specialVocab(p.tokJson,tc,p.config,null,p.extraTemplate);report.tokenizer="byte-level BPE ("+pre.name+(pre.known?"":", by its pattern")+")";}}
    /* llama.cpp's converter turns the start token off for 49152-token Llama vocabularies (Granite and SmolLM) */
    if(p.arch==="llama"&&nv===49152)sv.add.bos=false;
    var names={bos:"bos_token_id",eos:"eos_token_id",unk:"unknown_token_id",sep:"seperator_token_id",pad:"padding_token_id",cls:"cls_token_id",mask:"mask_token_id",eot:"eot_token_id",eom:"eom_token_id"};
    Object.keys(sv.ids).forEach(function(t){if(names[t])add("tokenizer.ggml."+names[t],"u32",sv.ids[t]);});
    Object.keys(sv.add).forEach(function(t){add("tokenizer.ggml.add_"+t+"_token","bool",sv.add[t]);});
    if(sv.template!=null){if(typeof sv.template==="string")add("tokenizer.chat_template","str",sv.template);
      else sv.template.forEach(function(t){add(t.name==="default"?"tokenizer.chat_template":"tokenizer.chat_template."+t.name,"str",t.template);});}
    return kv;}
  /* ---------- which tensors, named how, stored as what ---------- */
  function mapName(n){
    var m;
    if(n==="model.embed_tokens.weight")return "token_embd.weight";
    if(n==="model.norm.weight")return "output_norm.weight";
    if(n==="lm_head.weight")return "output.weight";
    if((m=/^model\.layers\.(\d+)\.(.+)$/.exec(n))){var b="blk."+m[1]+".",r=m[2];
      var map={"input_layernorm.weight":"attn_norm.weight","post_attention_layernorm.weight":"ffn_norm.weight",
        "self_attn.q_proj.weight":"attn_q.weight","self_attn.k_proj.weight":"attn_k.weight","self_attn.v_proj.weight":"attn_v.weight",
        "self_attn.q_proj.bias":"attn_q.bias","self_attn.k_proj.bias":"attn_k.bias","self_attn.v_proj.bias":"attn_v.bias",
        "self_attn.o_proj.weight":"attn_output.weight","self_attn.q_norm.weight":"attn_q_norm.weight","self_attn.k_norm.weight":"attn_k_norm.weight",
        "mlp.gate_proj.weight":"ffn_gate.weight","mlp.up_proj.weight":"ffn_up.weight","mlp.down_proj.weight":"ffn_down.weight"};
      if(map[r])return b+map[r];}
    return null;}
  function useMoreBits(i,n){return i<Math.floor(n/8)||i>=Math.floor(7*n/8)||(i-Math.floor(n/8))%3===2;}
  function fits(type,cols){return cols%ICQ.TYPES[type].blk===0;}
  function fallback(type,cols){if(fits(type,cols))return type;var f=type==="Q4_K"?"Q5_0":type==="Q6_K"?"Q8_0":type;return fits(f,cols)?f:"F16";}
  function chooseType(q,gname,dims,cols,layer,nLayer,tied){
    if(dims<=1||/_norm\.weight$/.test(gname)||!/\.weight$/.test(gname))return "F32";
    if(q==="F16")return "F16";
    if(q==="F32")return "F32";
    if(q==="Q8_0")return fits("Q8_0",cols)?"Q8_0":"F16";
    /* Q4_K_M, as llama-quantize chooses it */
    if(gname==="output.weight"||(tied&&gname==="token_embd.weight"))return cols%256!==0?"Q8_0":"Q6_K";
    var t="Q4_K";
    if(/\.attn_v\.weight$/.test(gname)&&useMoreBits(layer,nLayer))t="Q6_K";
    if(/\.ffn_down\.weight$/.test(gname)&&useMoreBits(layer,nLayer))t="Q6_K";
    return fallback(t,cols);}
  function llama3RopeFactors(hp){
    var rp=Object.assign({},hp.rope_scaling||{},hp.rope_parameters||{});if(String(rp.rope_type||rp.type||"").toLowerCase()!=="llama3")return null;
    var base=rp.rope_theta!=null?rp.rope_theta:(hp.rope_theta!=null?hp.rope_theta:10000),dim=hp.head_dim!=null?hp.head_dim:Math.floor(hp.hidden_size/hp.num_attention_heads);
    var factor=rp.factor!=null?rp.factor:8,lo=rp.low_freq_factor!=null?rp.low_freq_factor:1,hi=rp.high_freq_factor!=null?rp.high_freq_factor:4,old=rp.original_max_position_embeddings||8192;
    /* step by step in 32-bit floats, as PyTorch computes it in llama.cpp's converter */
    var fr=Math.fround,lw=old/lo,hw=old/hi,out=new Float32Array(dim/2);
    for(var i=0;i<dim/2;i++){var f=fr(1/fr(Math.pow(base,fr(fr(2*i)/dim)))),wl=fr(fr(2*Math.PI)/f);
      if(wl<hw)out[i]=1;else if(wl>lw)out[i]=factor;
      else{var sm=fr(fr(fr(old/wl)-lo)/fr(hi-lo));out[i]=fr(1/fr(fr(fr(1-sm)/factor)+sm));}}
    return out;}
  function plan(p,q){
    var hp=p.hp,nl=find(hp,["num_hidden_layers","n_layers","n_layer"]),nh=hp.num_attention_heads,nkv=find(hp,["num_key_value_heads","n_kv_heads"])||nh;
    var names=Object.keys(p.tensors),list=[],tied=!p.tensors["lm_head.weight"];
    names.forEach(function(n){
      if(/\.(scales|biases)$/.test(n)&&p.mlx)return;
      if(/rotary_emb\.inv_freq$|\.attention\.masked_bias$|\.attention\.bias$/.test(n))return;
      var g=mapName(n);if(!g)throw new Error("This model has a part Ingenium does not know ("+n+"); it cannot be converted.");
      var t=p.tensors[n],shape=t.shape.slice(),src={kind:"plain",t:t};
      if(p.mlx&&p.tensors[n.replace(/\.weight$/,".scales")]&&/\.weight$/.test(n)){var base=n.replace(/\.weight$/,"");
        var ov=p.mlxq[base]&&typeof p.mlxq[base]==="object"?p.mlxq[base]:p.mlxq;
        src={kind:"mlx",q:{weight:t,scales:p.tensors[base+".scales"],biases:p.tensors[base+".biases"]||null,bits:ov.bits||p.mlxq.bits,group:ov.group_size||p.mlxq.group_size}};
        shape[shape.length-1]=shape[shape.length-1]*32/src.q.bits;}
      var m=/^blk\.(\d+)\./.exec(g),layer=m?+m[1]:-1,cols=shape[shape.length-1],rows=shape.length>1?shape.slice(0,-1).reduce(function(a,b){return a*b;},1):1;
      var perm=null;if(p.arch==="llama"){if(/attn_q\.(weight|bias)$/.test(g))perm=nh;if(/attn_k\.(weight|bias)$/.test(g))perm=nkv;}
      list.push({name:g,src:src,shape:shape,rows:rows,cols:cols,layer:layer,perm:perm,type:chooseType(q,g,shape.length,cols,layer,nl,tied)});});
    var rf=llama3RopeFactors(hp);if(rf&&p.arch==="llama")list.push({name:"rope_freqs.weight",src:{kind:"data",data:rf},shape:[rf.length],rows:1,cols:rf.length,layer:-1,perm:null,type:"F32"});
    /* the order llama-quantize writes: outside the blocks first, then block by block */
    function key(e){var m=/^blk\.(\d+)\.(.*)$/.exec(e.name);return m?[1,+m[1],m[2]]:[0,0,e.name];}
    list.sort(function(a,b){var x=key(a),y=key(b);for(var i=0;i<3;i++){if(x[i]<y[i])return -1;if(x[i]>y[i])return 1;}return 0;});
    list.forEach(function(e){e.nbytes=e.rows*ICQ.rowBytes(e.type,e.cols);});
    return list;}
  /* ---------- the GGUF file ---------- */
  var VT={u8:0,i8:1,u16:2,i16:3,u32:4,i32:5,f32:6,bool:7,str:8,arr:9,u64:10,i64:11,f64:12};
  function Bytes(){this.parts=[];this.len=0;this.cur=new Uint8Array(1<<16);this.pos=0;}
  Bytes.prototype.need=function(n){if(this.pos+n>this.cur.length){this.flush();if(n>this.cur.length)this.cur=new Uint8Array(n);}};
  Bytes.prototype.flush=function(){if(this.pos){this.parts.push(this.cur.slice(0,this.pos));this.len+=this.pos;this.pos=0;}};
  Bytes.prototype.dv=function(){return new DataView(this.cur.buffer);};
  Bytes.prototype.u32=function(v){this.need(4);this.dv().setUint32(this.pos,v>>>0,true);this.pos+=4;};
  Bytes.prototype.i32=function(v){this.need(4);this.dv().setInt32(this.pos,v|0,true);this.pos+=4;};
  Bytes.prototype.u64=function(v){this.need(8);var d=this.dv();d.setUint32(this.pos,v%4294967296,true);d.setUint32(this.pos+4,Math.floor(v/4294967296),true);this.pos+=8;};
  Bytes.prototype.f32=function(v){this.need(4);this.dv().setFloat32(this.pos,v,true);this.pos+=4;};
  Bytes.prototype.u8=function(v){this.need(1);this.cur[this.pos++]=v;};
  Bytes.prototype.str=function(s){var b=new TextEncoder().encode(s);this.u64(b.length);this.need(b.length);this.cur.set(b,this.pos);this.pos+=b.length;};
  Bytes.prototype.done=function(){this.flush();var o=new Uint8Array(this.len),p=0;this.parts.forEach(function(x){o.set(x,p);p+=x.length;});return o;};
  function writeVal(B,type,v){
    if(type.slice(0,4)==="arr:"){var it=type.slice(4);B.u32(VT[it]);B.u64(v.length);for(var i=0;i<v.length;i++)writeVal(B,it,v[i]);return;}
    switch(type){case "str":B.str(v);return;case "u32":B.u32(v);return;case "i32":B.i32(v);return;case "f32":B.f32(v);return;case "bool":B.u8(v?1:0);return;case "u64":B.u64(v);return;case "u8":B.u8(v);return;
      case "i8":B.u8(v&255);return;case "u16":B.u8(v&255);B.u8((v>>8)&255);return;case "i16":B.u8(v&255);B.u8((v>>8)&255);return;
      case "i64":B.u32(v>>>0);B.i32(Math.floor(v/4294967296));return;case "f64":B.need(8);B.dv().setFloat64(B.pos,v,true);B.pos+=8;return;}
    throw new Error("value type "+type);}
  function header(kv,tensors){
    var B=new Bytes();B.u32(0x46554747);B.u32(3);B.u64(tensors.length);B.u64(kv.length);
    kv.forEach(function(e){B.str(e.key);var t=e.type.slice(0,4)==="arr:"?"arr":e.type;B.u32(VT[t]);writeVal(B,e.type,e.value);});
    var off=0;tensors.forEach(function(t){B.str(t.name);var ne=t.shape.slice().reverse();B.u32(ne.length);ne.forEach(function(d){B.u64(d);});
      B.u32(t.typeId!=null?t.typeId:ICQ.TYPES[t.type].id);B.u64(off);t.offset=off;off+=t.nbytes;off=Math.ceil(off/32)*32;});
    var h=B.done(),pad=Math.ceil(h.length/32)*32-h.length;
    var out=new Uint8Array(h.length+pad);out.set(h);return {bytes:out,dataSize:off};}
  /* ---------- reading rows, in the GGUF's row order ---------- */
  function readRows(e,r0,n){
    if(e.src.kind==="data")return Promise.resolve(e.src.data.slice(r0*e.cols,(r0+n)*e.cols));
    var rd=function(a,b){return e.src.kind==="mlx"?ICR.readRowsMlx(e.src.q,a,b):ICR.readRows(e.src.t,a,b);};
    if(!e.perm)return rd(r0,n);
    if(e.shape.length===1)return rd(0,1).then(function(x){var len=x.length,hd1=len/e.perm,hf=hd1/2,y=new Float32Array(len);
      for(var k=0;k<len;k++){var h1=Math.floor(k/hd1),w1=k-h1*hd1;y[k]=x[h1*hd1+(w1&1)*hf+(w1>>1)];}return y;});
    /* llama's q and k rows are reordered within each head (convert's permute) */
    var hd=e.rows/e.perm,half=hd/2,cols=e.cols;
    return rd(r0,n).then(function(x){var y=new Float32Array(x.length);
      for(var r=0;r<n;r++){var gr=r0+r,h=Math.floor(gr/hd),w=gr-h*hd,i=w>>1,j=w&1,src=h*hd+j*half+i-r0;
        y.set(x.subarray(src*cols,(src+1)*cols),r*cols);}
      return y;});}
  function chunkRows(e,floats){var per=Math.max(1,Math.floor((floats||1048576)/e.cols));if(e.perm){var hd=e.rows/e.perm;per=Math.max(hd,Math.floor(per/hd)*hd);}return Math.min(per,e.rows);}
  /* the work in order: every chunk of every tensor, with the padding after each tensor */
  function tasksOf(tensors,floats){var out=[];tensors.forEach(function(e){
      if(e.copy){var o=0,CH=8*1048576;while(o<e.copy.nbytes){var n=Math.min(CH,e.copy.nbytes-o);out.push({e:e,copyAt:o,n:n,pad:0});o+=n;}
        if(out.length&&out[out.length-1].e===e)out[out.length-1].pad=(32-e.nbytes%32)%32;return;}
      var per=chunkRows(e,floats);for(var r=0;r<e.rows;r+=per)out.push({e:e,r0:r,n:Math.min(per,e.rows-r),pad:0});
      out[out.length-1].pad=(32-e.nbytes%32)%32;});return out;}
  /* several chunks in flight (read and encoded at once), written strictly in order */
  function pipeline(tasks,K,produce,put,stop){
    var next=0,inflight=[];
    function pump(){while(inflight.length<K&&next<tasks.length){var t=tasks[next++];
      var pr=produce(t).then(function(b){return {t:this,b:b};}.bind(t));pr.catch(function(){});inflight.push(pr);}}
    function step(){if(stop())return Promise.reject(new Error("stopped"));pump();if(!inflight.length)return Promise.resolve();
      return inflight.shift().then(function(r){return put(r.b).then(function(){return r.t.pad?put(new Uint8Array(r.t.pad)):null;});}).then(step);}
    return step();}
  /* ---------- the whole conversion ---------- */
  function prepare(p,q,name){
    var report={},tensors=plan(p,q),kv=kvFor(p,q,name).concat(vocabKv(p,report)),h=header(kv,tensors);
    return {tensors:tensors,kv:kv,h:h,total:h.bytes.length+h.dataSize,report:report,quality:q,name:name};}
  function encoder(opts){var viaF16=!!opts.viaF16,pool=opts.pool||null;
    return function(type,x,n,cols){if(viaF16&&type!=="F32")for(var i=0;i<x.length;i++)x[i]=ICQ.F16[ICQ.f32ToF16(x[i])];
      if(pool)return pool(type,x,n,cols);var rb=ICQ.rowBytes(type,cols),out=new Uint8Array(n*rb);for(var r=0;r<n;r++)ICQ.encode(type,x,r*cols,cols,out,r*rb);return Promise.resolve(out);};}
  function convert(p,sink,opts){
    opts=opts||{};var q=opts.quality||"Q4_K_M",stop=opts.stop||function(){return false;};
    var name=opts.name||(p.config._name_or_path?baseName(p.config._name_or_path):"Converted model");
    var P=opts.prepared||prepare(p,q,name),enc=encoder(opts),written=0;
    function put(b){written+=b.length;if(opts.progress)opts.progress(written,P.total);return sink.write(b);}
    var tasks=tasksOf(P.tensors,opts.chunkFloats);
    return put(P.h.bytes).then(function(){return pipeline(tasks,opts.parallel||1,function(t){return readRows(t.e,t.r0,t.n).then(function(x){return enc(t.e.type,x,t.n,t.e.cols);});},put,stop);})
      .then(function(){return sink.close();}).then(function(){var r=P.report;
        r.bytes=written;r.tensors=P.tensors.length;r.quality=q;r.name=name;r.arch=p.arch;
        r.types=P.tensors.reduce(function(a,t){a[t.type]=(a[t.type]||0)+1;return a;},{});return r;});}
  /* ---------- a smaller copy of a GGUF ---------- */
  function prepareRequant(g,q){
    var arch=null,nl=0;g.gguf.kv.forEach(function(e){if(e.key==="general.architecture")arch=e.value;});
    g.gguf.kv.forEach(function(e){if(e.key===arch+".block_count")nl=e.value;});
    var tied=!g.gguf.tensors.some(function(t){return t.name==="output.weight";});
    var tensors=g.gguf.tensors.map(function(t){var cols=t.ne[0],rows=t.ne.slice(1).reduce(function(a,b){return a*b;},1),m=/^blk\.(\d+)\./.exec(t.name);
      var can=["F32","F16","BF16","Q8_0"].indexOf(t.type)>=0,type=can?chooseType(q,t.name,t.ne.length,cols,m?+m[1]:-1,nl,tied):t.type;
      var copy=(!can||(type===t.type&&t.type!=="BF16"))?t:null;
      return {name:t.name,src:{kind:"plain",t:{src:t.src,offset:t.offset,dtype:t.type,shape:t.ne.slice().reverse()}},copy:copy,
        shape:t.ne.slice().reverse(),rows:rows,cols:cols,type:type,typeId:copy?t.typeId:null,perm:null,nbytes:copy?t.nbytes:rows*ICQ.rowBytes(type,cols)};});
    if(tensors.some(function(e){return e.copy&&e.copy.nbytes<0;}))throw new Error("this GGUF holds a kind of weights Ingenium cannot copy");
    var kv=[],any=false;g.gguf.kv.forEach(function(e){if(e.key==="general.alignment")return;var t=gtype(e.type,e.value);
      if(e.key==="general.file_type"){kv.push({key:e.key,type:"u32",value:FTYPE[q]});any=true;return;}
      kv.push({key:e.key,type:t,value:t.slice(0,4)==="arr:"?e.value.items:e.value});});
    if(!any)kv.push({key:"general.file_type",type:"u32",value:FTYPE[q]});
    var h=header(kv,tensors);return {tensors:tensors,kv:kv,h:h,total:h.bytes.length+h.dataSize,arch:arch,quality:q};}
  function requantize(g,sink,opts){
    opts=opts||{};var q=opts.quality||"Q4_K_M",stop=opts.stop||function(){return false;},P=opts.prepared||prepareRequant(g,q),enc=encoder(opts),written=0;
    function put(b){written+=b.length;if(opts.progress)opts.progress(written,P.total);return sink.write(b);}
    var tasks=tasksOf(P.tensors,opts.chunkFloats);
    return put(P.h.bytes).then(function(){return pipeline(tasks,opts.parallel||1,function(t){
        if(t.e.copy)return t.e.copy.src.read(t.e.copy.offset+t.copyAt,t.n);
        return ICR.readRows(t.e.src.t,t.r0,t.n).then(function(x){return enc(t.e.type,x,t.n,t.e.cols);});},put,stop);})
      .then(function(){return sink.close();}).then(function(){return {bytes:written,tensors:P.tensors.length,quality:q,arch:P.arch};});}
  function gtype(t,v){var m={0:"u8",1:"i8",2:"u16",3:"i16",4:"u32",5:"i32",6:"f32",7:"bool",8:"str",10:"u64",11:"i64",12:"f64"};
    if(t===9)return "arr:"+m[v.type];return m[t];}
  return {inspect:inspect,prepare:prepare,prepareRequant:prepareRequant,convert:convert,requantize:requantize,plan:plan,kvFor:kvFor,vocabKv:vocabKv,chooseType:chooseType,sizeLabel:sizeLabel,ARCH:ARCH};
})();
if(typeof module!=="undefined")module.exports=ICM;

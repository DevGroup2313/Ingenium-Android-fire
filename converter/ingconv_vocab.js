/* ============ R72: the converter, part 3: the tokenizer ============
   How a model splits text into tokens travels with it into the GGUF file. These
   functions follow llama.cpp's converter (conversion/base.py and gguf-py's
   vocab.py): byte-level BPE vocabularies (Llama 3, Qwen, SmolLM...), SentencePiece
   (tokenizer.model: Llama 2, Mistral...) and the special tokens. llama.cpp knows a
   BPE tokenizer's way of pre-splitting text by a fingerprint: the tokens its own
   tokenizer gives for one fixed test text. To find that fingerprint without Python,
   a small BPE tokenizer here encodes the same text. */
var ICV=(function(){
  "use strict";
  /* ---------- SHA-256 (for the fingerprint) ---------- */
  var K=[0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
  function sha256Hex(bytes){
    var h=[0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
    var l=bytes.length,n=((l+9+63)>>6)<<6,m=new Uint8Array(n);m.set(bytes);m[l]=0x80;
    var bits=l*8;for(var i=0;i<8;i++)m[n-1-i]=Math.floor(bits/Math.pow(2,8*i))&255;
    var w=new Uint32Array(64);
    for(var o=0;o<n;o+=64){for(i=0;i<16;i++)w[i]=(m[o+4*i]<<24)|(m[o+4*i+1]<<16)|(m[o+4*i+2]<<8)|m[o+4*i+3];
      for(i=16;i<64;i++){var x=w[i-15],y=w[i-2];
        var s0=((x>>>7)|(x<<25))^((x>>>18)|(x<<14))^(x>>>3),s1=((y>>>17)|(y<<15))^((y>>>19)|(y<<13))^(y>>>10);
        w[i]=(w[i-16]+s0+w[i-7]+s1)|0;}
      var a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
      for(i=0;i<64;i++){var S1=((e>>>6)|(e<<26))^((e>>>11)|(e<<21))^((e>>>25)|(e<<7)),ch=(e&f)^(~e&g),t1=(hh+S1+ch+K[i]+w[i])|0;
        var S0=((a>>>2)|(a<<30))^((a>>>13)|(a<<19))^((a>>>22)|(a<<10)),mj=(a&b)^(a&c)^(b&c),t2=(S0+mj)|0;
        hh=g;g=f;f=e;e=(d+t1)|0;d=c;c=b;b=a;a=(t1+t2)|0;}
      h[0]=(h[0]+a)|0;h[1]=(h[1]+b)|0;h[2]=(h[2]+c)|0;h[3]=(h[3]+d)|0;h[4]=(h[4]+e)|0;h[5]=(h[5]+f)|0;h[6]=(h[6]+g)|0;h[7]=(h[7]+hh)|0;}
    return h.map(function(v){return ("00000000"+(v>>>0).toString(16)).slice(-8);}).join("");}
  var TE=new TextEncoder();
  /* ---------- GPT-2's byte <-> character map ---------- */
  var B2U=[];(function(){var bs=[],i;for(i=33;i<=126;i++)bs.push(i);for(i=161;i<=172;i++)bs.push(i);for(i=174;i<=255;i++)bs.push(i);
    var cs=bs.slice(),n=0;for(i=0;i<256;i++)if(bs.indexOf(i)<0){bs.push(i);cs.push(256+n);n++;}
    for(i=0;i<bs.length;i++)B2U[bs[i]]=String.fromCharCode(cs[i]);})();
  function byteLevel(s){var b=TE.encode(s),o="";for(var i=0;i<b.length;i++)o+=B2U[b[i]];return o;}
  /* ---------- regexes from tokenizer.json, made fit for JavaScript ---------- */
  function jsRegex(src){
    /* (?i:...) groups: spell each letter both ways */
    var out="",i=0;
    while(i<src.length){
      if(src.substr(i,4)==="(?i:"){var depth=1,j=i+4;for(;j<src.length&&depth;j++){if(src[j]==="\\"){j++;continue;}if(src[j]==="(")depth++;else if(src[j]===")")depth--;}
        var inner=src.slice(i+4,j-1);out+="(?:"+inner.replace(/\\.|[A-Za-z]/g,function(c){return c.length>1?c:"["+c.toLowerCase()+c.toUpperCase()+"]";})+")";i=j;continue;}
      out+=src[i++];}
    /* possessive quantifiers and atomic groups have no JavaScript form; drop the possessiveness */
    out=out.replace(/(\{\d+(?:,\d*)?\})\+/g,"$1").replace(/([^\\])([+*?])\+/g,"$1$2").replace(/\(\?>/g,"(?:");
    return new RegExp(out,"gu");}
  var GPT2_RE="'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+";
  /* split one piece by a pattern with a tokenizers "behavior" */
  function splitBy(re,s,behavior,invert){
    var segs=[],p=0,m;re.lastIndex=0;
    while((m=re.exec(s))!==null){if(m[0]===""){re.lastIndex++;continue;}
      if(m.index>p)segs.push([p,m.index,false]);segs.push([m.index,m.index+m[0].length,true]);p=m.index+m[0].length;}
    if(p<s.length)segs.push([p,s.length,false]);
    if(invert)segs.forEach(function(x){x[2]=!x[2];});
    var parts=[],i;
    switch(behavior||"Isolated"){
      case "Removed":segs.forEach(function(x){if(!x[2])parts.push(s.slice(x[0],x[1]));});break;
      case "Isolated":segs.forEach(function(x){parts.push(s.slice(x[0],x[1]));});break;
      case "MergedWithPrevious":segs.forEach(function(x){if(x[2]&&parts.length)parts[parts.length-1]+=s.slice(x[0],x[1]);else parts.push(s.slice(x[0],x[1]));});break;
      case "MergedWithNext":{var carry="";segs.forEach(function(x){if(x[2])carry+=s.slice(x[0],x[1]);else{parts.push(carry+s.slice(x[0],x[1]));carry="";}});if(carry)parts.push(carry);break;}
      case "Contiguous":{var prev=false;segs.forEach(function(x){var t=s.slice(x[0],x[1]);if(x[2]&&prev&&parts.length)parts[parts.length-1]+=t;else parts.push(t);prev=x[2];});break;}
      default:throw new Error("unknown split behavior "+behavior);}
    return parts.filter(function(t){return t!=="";});}
  function preTokenize(pt,pieces){
    if(!pt)return pieces;
    switch(pt.type){
      case "Sequence":pt.pretokenizers.forEach(function(p){pieces=preTokenize(p,pieces);});return pieces;
      case "Split":{var pat=pt.pattern.Regex!=null?jsRegex(pt.pattern.Regex):new RegExp(pt.pattern.String.replace(/[.*+?^${}()|[\]\\]/g,"\\$&"),"gu");
        var out=[];pieces.forEach(function(s){out=out.concat(splitBy(pat,s,pt.behavior,pt.invert));});return out;}
      case "ByteLevel":{var re=pt.use_regex===false?null:jsRegex(GPT2_RE),o=[];
        pieces.forEach(function(s,idx){if(pt.add_prefix_space&&idx===0&&s[0]!==" ")s=" "+s;
          (re?splitBy(re,s,"Isolated",false):[s]).forEach(function(t){o.push(byteLevel(t));});});return o;}
      case "Digits":{var d=pt.individual_digits?/\p{N}/gu:/\p{N}+/gu,o2=[];pieces.forEach(function(s){o2=o2.concat(splitBy(d,s,"Isolated",false));});return o2;}
      case "Whitespace":{var o3=[];pieces.forEach(function(s){o3=o3.concat(s.match(/\w+|[^\w\s]+/gu)||[]);});return o3;}
      case "WhitespaceSplit":{var o4=[];pieces.forEach(function(s){o4=o4.concat(s.split(/\s+/).filter(Boolean));});return o4;}
      case "Punctuation":{var o5=[];pieces.forEach(function(s){o5=o5.concat(splitBy(/[\p{P}\p{S}]/gu,s,pt.behavior||"Isolated",false));});return o5;}}
    throw new Error("pre-tokenizer "+pt.type+" is not supported");}
  function normalize(n,s){
    if(!n)return s;
    switch(n.type){
      case "Sequence":n.normalizers.forEach(function(x){s=normalize(x,s);});return s;
      case "NFC":case "NFD":case "NFKC":case "NFKD":return s.normalize(n.type);
      case "Lowercase":return s.toLowerCase();
      case "Prepend":return n.prepend+s;
      case "Replace":{var pat=n.pattern.Regex!=null?jsRegex(n.pattern.Regex):new RegExp(n.pattern.String.replace(/[.*+?^${}()|[\]\\]/g,"\\$&"),"gu");return s.replace(pat,n.content);}
      case "Strip":{if(n.strip_left!==false)s=s.replace(/^\s+/,"");if(n.strip_right!==false)s=s.replace(/\s+$/,"");return s;}}
    throw new Error("normalizer "+n.type+" is not supported");}
  /* ---------- BPE ---------- */
  function bpeModel(tj){
    var m=tj.model,vocab=m.vocab,ranks=new Map();
    (m.merges||[]).forEach(function(x,i){var k=Array.isArray(x)?x[0]+" "+x[1]:x;if(!ranks.has(k))ranks.set(k,i);});
    function word(w){
      if(m.ignore_merges&&Object.prototype.hasOwnProperty.call(vocab,w))return [vocab[w]];
      var sym=Array.from(w);
      for(;;){var best=-1,bi=-1;
        for(var i=0;i<sym.length-1;i++){var r=ranks.get(sym[i]+" "+sym[i+1]);if(r!==undefined&&(best<0||r<best)){best=r;bi=i;}}
        if(bi<0)break;
        var a=sym[bi],b=sym[bi+1],merged=[];
        for(i=0;i<sym.length;){if(i<sym.length-1&&sym[i]===a&&sym[i+1]===b){merged.push(a+b);i+=2;}else merged.push(sym[i++]);}
        sym=merged;}
      var ids=[];sym.forEach(function(s){if(Object.prototype.hasOwnProperty.call(vocab,s))ids.push(vocab[s]);
        else if(m.byte_fallback){TE.encode(s).forEach(function(byte){var k="<0x"+("0"+byte.toString(16).toUpperCase()).slice(-2)+">";if(vocab[k]!==undefined)ids.push(vocab[k]);});}
        else if(m.unk_token&&vocab[m.unk_token]!==undefined)ids.push(vocab[m.unk_token]);});
      return ids;}
    return word;}
  /* encode as transformers' tokenizer.encode(text) would: added tokens, normalizer,
     pre-tokenizer, BPE, then the post-processor's special tokens */
  function encode(tj,tc,text){
    var word=bpeModel(tj),added=(tj.added_tokens||[]).slice().sort(function(a,b){return b.content.length-a.content.length;});
    var segs=[],i=0,buf="";
    while(i<text.length){var hit=null;for(var k=0;k<added.length;k++){var a=added[k];if(a.content&&text.startsWith(a.content,i)){hit=a;break;}}
      if(hit){if(buf)segs.push(buf);buf="";segs.push(hit);i+=hit.content.length;}else buf+=text[i++];}
    if(buf)segs.push(buf);
    var ids=[];
    segs.forEach(function(s){if(typeof s!=="string"){ids.push(s.id);return;}
      var n=normalize(tj.normalizer,s);
      preTokenize(tj.pre_tokenizer,[n]).forEach(function(p){Array.prototype.push.apply(ids,word(p));});});
    var cls=(tc&&tc.tokenizer_class)||"";
    var idOf=function(t){var c=typeof t==="string"?t:(t&&t.content);if(c==null)return null;
      var v=tj.model.vocab[c];if(v!==undefined)return v;var a=(tj.added_tokens||[]).filter(function(x){return x.content===c;})[0];return a?a.id:null;};
    if(/^LlamaTokenizer/.test(cls)){var bos=tc.add_bos_token!==false?idOf(tc.bos_token):null,eos=tc.add_eos_token?idOf(tc.eos_token):null;
      if(bos!=null)ids.unshift(bos);if(eos!=null)ids.push(eos);return ids;}
    var pp=tj.post_processor;
    (function apply(p){if(!p)return;
      if(p.type==="Sequence"){p.processors.forEach(apply);return;}
      if(p.type==="TemplateProcessing"){var pre=[],post=[],seen=false;
        p.single.forEach(function(e){if(e.Sequence){seen=true;return;}var sp=e.SpecialToken&&p.special_tokens[e.SpecialToken.id];
          if(sp)(seen?post:pre).push.apply(seen?post:pre,sp.ids);});
        ids=pre.concat(ids,post);}
      if(p.type==="RobertaProcessing"||p.type==="BertProcessing"){ids=[p.cls[1]].concat(ids,[p.sep[1]]);}})(pp);
    return ids;}
  var CHKTXT="\n \n\n \n\n\n \t \t\t \t\n  \n   \n    \n     \n🚀 (normal) 😶‍🌫️ (multiple emojis concatenated) ✅ 🦙🦙 3 33 333 3333 33333 333333 3333333 33333333 3.3 3..3 3...3 កាន់តែពិសេសអាច😁 ?我想在apple工作1314151天～ ------======= нещо на Български ''''''```````\"\"\"\"......!!!!!!?????? I've been 'told he's there, 'RE you sure? 'M not sure I'll make it, 'D you like some tea? We'Ve a'lL";
  var CHK={};
  function fingerprint(tj,tc){var ids=encode(tj,tc,CHKTXT);return sha256Hex(TE.encode("["+ids.join(", ")+"]"));}
  /* when the fingerprint is unknown: the pre-split regex decides, which is what
     llama.cpp actually uses each name for */
  function preByPattern(tj){
    var pats=[];(function walk(p){if(!p)return;if(p.type==="Sequence")p.pretokenizers.forEach(walk);
      else if(p.type==="Split"&&p.pattern&&p.pattern.Regex!=null)pats.push(p.pattern.Regex);
      else if(p.type==="ByteLevel"&&p.use_regex!==false)pats.push("gpt2");
      else if(p.type==="Digits")pats.push(p.individual_digits?"digits1":"digits");})(tj.pre_tokenizer);
    var s=pats.join(" | ");
    if(/\\p\{N\}\{1,3\}/.test(s)&&/\[\^\\r\\n\\p\{L\}\\p\{N\}\]\?\\p\{L\}\+/.test(s))return "llama-bpe";
    if(/\[\^\\r\\n\\p\{L\}\\p\{N\}\]\?\\p\{L\}\+\|\\p\{N\}\|/.test(s))return "qwen2";
    if(s==="digits1 | gpt2")return "smollm";
    if(s==="gpt2")return "gpt-2";
    return null;}
  function detectPre(tj,tc){var fp=null,name=null;
    try{fp=fingerprint(tj,tc);name=CHK[fp]||null;}catch(e){fp="error: "+(e&&e.message);}
    return {name:name||preByPattern(tj)||"default",fingerprint:fp,known:!!name};}
  /* ---------- vocabularies ---------- */
  var T={NORMAL:1,UNKNOWN:2,CONTROL:3,USER_DEFINED:4,UNUSED:5,BYTE:6};
  function looksSpecial(t){return t==="<pad>"||t==="<mask>"||t==="<2mass>"||t==="[@BOS@]"||(t.slice(0,2)==="<|"&&t.slice(-2)==="|>")||
    (t.slice(0,2)==="<｜"&&t.slice(-2)==="｜>")||(t.slice(0,7)==="<unused"&&t.slice(-1)===">");}
  function gpt2Vocab(tj,tc,nVocab){
    var rev=[],vocab=tj.model.vocab,addedById={};
    Object.keys(vocab).forEach(function(k){rev[vocab[k]]=k;});
    (tj.added_tokens||[]).forEach(function(a){rev[a.id]=a.content;addedById[a.id]=a;});
    /* the transformers tokenizer also counts tokenizer_config's added_tokens_decoder */
    var dec=(tc&&tc.added_tokens_decoder)||{};Object.keys(dec).forEach(function(id){var a=dec[id];if(!addedById[id]){rev[+id]=a.content;addedById[id]={id:+id,content:a.content,special:a.special,normalized:a.normalized};}});
    var n=nVocab||rev.length,tokens=[],types=[];
    for(var i=0;i<n;i++){
      if(rev[i]===undefined){tokens.push("[PAD"+i+"]");types.push(T.UNUSED);continue;}
      var t=rev[i],a=addedById[i];
      if(a){if(a.special||looksSpecial(t))types.push(T.CONTROL);else{t=t.replace(/▁/g," ");types.push(T.USER_DEFINED);}}
      else types.push(T.NORMAL);
      tokens.push(t);}
    return {tokens:tokens,types:types};}
  function merges(tj,mergesTxt){
    var m=tj&&tj.model&&tj.model.merges;
    if(Array.isArray(m)&&m.length){
      if(typeof m[0]==="string")return m;
      return m.map(function(p){return p.map(function(s){return s.replace(/ /g,"Ġ");}).join(" ");});}
    if(mergesTxt){var lines=mergesTxt.split(/\r?\n/),out=[];var start=lines.length&&lines[0].charAt(0)==="#"?1:0;
      for(var i=start;i<lines.length;i++){var l=lines[i].trim();if(!l)continue;var p=l.split(/\s+/);if(p.length===2)out.push(p[0]+" "+p[1]);}return out;}
    return [];}
  /* SentencePiece's tokenizer.model: a small protobuf */
  function readSpm(bytes){
    var p=0,pieces=[];
    function varint(){var v=0,s=1,b;do{b=bytes[p++];v+=(b&127)*s;s*=128;}while(b&128);return v;}
    var dv=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
    while(p<bytes.length){var key=varint(),f=Math.floor(key/8),wt=key&7;
      if(wt===2){var len=varint(),end=p+len;
        if(f===1){var piece={piece:"",score:0,type:1};var q=p;
          while(p<end){var k2=varint(),f2=Math.floor(k2/8),w2=k2&7;
            if(f2===1&&w2===2){var l2=varint();piece.piece=new TextDecoder("utf-8").decode(bytes.subarray(p,p+l2));p+=l2;}
            else if(f2===2&&w2===5){piece.score=dv.getFloat32(p,true);p+=4;}
            else if(f2===3&&w2===0){piece.type=varint();}
            else if(w2===0)varint();else if(w2===5)p+=4;else if(w2===1)p+=8;else if(w2===2){p+=varint();}else throw new Error("bad tokenizer.model");}
          pieces.push(piece);}
        p=end;}
      else if(wt===0)varint();else if(wt===5)p+=4;else if(wt===1)p+=8;else throw new Error("bad tokenizer.model");}
    if(!pieces.length)throw new Error("tokenizer.model holds no pieces");
    return pieces;}
  function spmVocab(pieces,addedJson,tc,nVocab){
    var n=nVocab||pieces.length,tokens=[],scores=[],types=[],i;
    for(i=0;i<n;i++){tokens.push("[PAD"+i+"]");scores.push(-10000);types.push(T.UNUSED);}
    for(i=0;i<pieces.length&&i<n;i++){tokens[i]=pieces[i].piece;scores[i]=pieces[i].score;types[i]=pieces[i].type||1;}
    if(addedJson)Object.keys(addedJson).forEach(function(k){var id=addedJson[k];if(id<n){tokens[id]=k;scores[id]=-1000;types[id]=T.USER_DEFINED;}});
    var dec=(tc&&tc.added_tokens_decoder)||{};
    Object.keys(dec).forEach(function(id){id=+id;if(id>=n)return;var d=dec[id],t=d.content;
      if(d.special||looksSpecial(t))types[id]=T.CONTROL;else{t=t.replace(/▁/g," ");types[id]=T.USER_DEFINED;}
      scores[id]=-1000;tokens[id]=t;});
    return {tokens:tokens,scores:scores,types:types};}
  /* tokenizer.json in SentencePiece style (byte fallback) without tokenizer.model */
  function llamaHfVocab(tj){
    var m=tj.model;if(m.type!=="BPE"||!m.byte_fallback)return null;
    var rev=[];Object.keys(m.vocab).forEach(function(k){rev[m.vocab[k]]=k;});
    var base=rev.length,special={},tokens=[],scores=[],types=[];(tj.added_tokens||[]).forEach(function(a){if(a.special)special[a.id]=1;});
    for(var i=0;i<base;i++){var t=rev[i]||("[PAD"+i+"]");tokens.push(t);scores.push(-1000);types.push(/^<0x[0-9A-Fa-f]{2}>$/.test(t)?T.BYTE:special[i]?T.CONTROL:T.NORMAL);}
    (tj.added_tokens||[]).filter(function(a){return a.id>=base;}).sort(function(a,b){return a.id-b.id;}).forEach(function(a){
      tokens.push(a.content);scores.push(-1000);types.push(a.special?T.CONTROL:T.USER_DEFINED);});
    return {tokens:tokens,scores:scores,types:types};}
  /* gguf-py's SpecialVocab: special token ids, add_*_token flags, chat template */
  function specialVocab(tj,tc,cfg,nVocab,extraTemplate){
    var ids={},add={},types=["bos","eos","unk","sep","pad","cls","mask"],out={ids:ids,add:add,template:null};
    tc=tc?JSON.parse(JSON.stringify(tc)):null;
    function setId(typ,id){if(typeof id!=="number"||id<0||Math.floor(id)!==id)return;if(nVocab==null||id<nVocab){if(!(typ in ids))ids[typ]=id;}}
    var added=(tj&&tj.added_tokens)||[];
    if(tj){var sb=tc&&tc.bos_token,scls=tc&&tc.cls_token,se=tc&&tc.eos_token,ssep=tc&&tc.sep_token;
      if(!sb&&scls&&tc){tc.bos_token=sb=scls;}if(!se&&ssep&&tc){tc.eos_token=se=ssep;}
      function content(x){return typeof x==="string"?x:(x&&x.content);}
      var pp=tj.post_processor;
      if(pp)(pp.processors||[pp]).forEach(function(p){
        if(p.type==="ByteLevel"){if(!("bos" in add))add.bos=false;if(!("eos" in add))add.eos=false;}
        else if(p.type==="RobertaProcessing"){add.bos=true;add.eos=true;add.sep=true;}
        else if(p.type==="TemplateProcessing"){var single=p.single||[],first=null,last=null;
          if(single.length>1){first=single[0].SpecialToken&&single[0].SpecialToken.id;
            if(first){if(!tc)sb=first;else if(first!==content(sb)&&first!==content(scls)){if(!sb)tc.bos_token=sb=first;if(!scls)tc.cls_token=scls=first;}
              add.bos=(first===content(sb)||first===content(scls));}
            last=single[single.length-1].SpecialToken&&single[single.length-1].SpecialToken.id;
            if(last){if(!tc)se=last;else if(last!==content(se)){if(types.indexOf("eot")<0){types.push("eot");tc.eot_token=se;}else if(types.indexOf("eom")<0){types.push("eom");tc.eom_token=se;}tc.eos_token=se=last;}
              add.eos=(last===content(se));}}
          var pair=p.pair||[];
          if(pair.length){var s0=(first&&pair[0].SpecialToken&&pair[0].SpecialToken.id===first)?1:0,s1=(last&&pair[pair.length-1].SpecialToken&&pair[pair.length-1].SpecialToken.id===last)?pair.length-1:pair.length;
            var mid=pair.slice(s0,s1);
            if(mid.length){var a=mid[0].Sequence&&mid[0].Sequence.id,b=mid[mid.length-1].Sequence&&mid[mid.length-1].Sequence.id;
              if(a==="A"&&b==="B"&&(mid=mid.slice(1,-1)).length){var addSep=false,e1=mid[0].SpecialToken&&mid[0].SpecialToken.id;
                if(e1&&(e1===content(ssep)||e1===content(se))&&!last)addSep=true;
                if(mid.length===2){var e2=mid[1].SpecialToken&&mid[1].SpecialToken.id;if(e2&&(e2===content(ssep)||e2===content(se)))addSep=true;}
                add.sep=addSep;if(addSep&&!ssep&&tc)tc.sep_token=se;}}}}});}
    if(tc){
      var tpl=tc.chat_template!==undefined?tc.chat_template:(extraTemplate!==undefined?extraTemplate:null);
      if(tpl==null||typeof tpl==="string"||Array.isArray(tpl))out.template=tpl;
      types.forEach(function(typ){var ae=tc["add_"+typ+"_token"];if(typeof ae==="boolean"&&!(typ in add))add[typ]=ae;
        var e=tc[typ+"_token"],c=typeof e==="string"?e:(e&&typeof e.content==="string"?e.content:null);if(c==null)return;
        var hit=added.filter(function(a){return a.content===c;})[0];setId(typ,hit?hit.id:undefined);});}
    if(cfg)types.forEach(function(typ){var v=cfg[typ+"_token_id"];if(v==null&&cfg.text_config)v=cfg.text_config[typ+"_token_id"];setId(typ,v);});
    return out;}
  return {sha256Hex:sha256Hex,encode:encode,fingerprint:fingerprint,detectPre:detectPre,setFingerprints:function(t){CHK=t;},
    gpt2Vocab:gpt2Vocab,merges:merges,readSpm:readSpm,spmVocab:spmVocab,llamaHfVocab:llamaHfVocab,specialVocab:specialVocab,T:T,CHKTXT:CHKTXT};
})();
if(typeof module!=="undefined")module.exports=ICV;

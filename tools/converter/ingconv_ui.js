/* ============ R72: the converter, part 5: on the Models page ============
   The person chooses a model's files (or drops them); Ingenium says what the model
   is, offers three sizes with their exact file sizes, and converts it here, on this
   device. The work is shared among background workers running llama.cpp's own
   quantizers (compiled to WebAssembly). The result goes where this copy of
   Ingenium keeps its models: inside the phone or tablet app, in the computer
   app's folder, or in the browser's own storage. */
var CONV_WASM_SLOT="ingenium-quant-wasm";
var _convWasm=null;
function convWasmBytes(){if(_convWasm)return _convWasm;var e=document.getElementById(CONV_WASM_SLOT);if(!e)return null;
  try{_convWasm=b64ToBytes(e.textContent.replace(/\s+/g,""));}catch(x){_convWasm=null;}return _convWasm;}
var CONV_TYPE_ID={F16:1,Q5_0:6,Q8_0:8,Q4_K:12,Q6_K:14};
/* a pool of workers, each with its own copy of the quantizers */
function convPool(){
  var wasm=convWasmBytes(),n=Math.max(1,Math.min(8,(navigator.hardwareConcurrency||2)-1)),workers=[],idle=[],queue=[],seq=0,waiting={},dead=false;
  var src="var Q=null;onmessage=function(e){var d=e.data;if(d.wasm){Q=new WebAssembly.Instance(new WebAssembly.Module(d.wasm),{}).exports;postMessage({ready:1});return;}"
    +"var mem=Q.memory,base=(Q.heap_base()+15)&~15,n=d.x.length,need=base+n*4+n*2+4096;"
    +"if(mem.buffer.byteLength<need)mem.grow(Math.ceil((need-mem.buffer.byteLength)/65536));"
    +"new Float32Array(mem.buffer,base,n).set(d.x);var o=base+n*4,len=0;"
    +"for(var r=0;r<d.rows;r++){len+=Q.quantize(d.type,base+r*d.cols*4,o+len,d.cols);}"
    +"var out=new Uint8Array(mem.buffer,o,len).slice();postMessage({id:d.id,out:out},[out.buffer]);};";
  function main(type,x,rows,cols){var out=new Uint8Array(rows*ICQ.rowBytes(type,cols));
    for(var r=0;r<rows;r++)ICQ.encode(type,x,r*cols,cols,out,r*ICQ.rowBytes(type,cols));return Promise.resolve(out);}
  if(!wasm||typeof Worker==="undefined"||typeof WebAssembly==="undefined")return {run:main,close:function(){},kind:"the page itself (slower)",n:1};
  try{var url=URL.createObjectURL(new Blob([src],{type:"text/javascript"}));
    for(var i=0;i<n;i++){var w=new Worker(url);w.onmessage=(function(w){return function(e){
        if(e.data.ready){idle.push(w);pump();return;}var cb=waiting[e.data.id];delete waiting[e.data.id];idle.push(w);pump();if(cb)cb.res(e.data.out);};})(w);
      w.onerror=function(ev){dead=true;Object.keys(waiting).forEach(function(k){waiting[k].rej(new Error("a worker stopped: "+(ev&&ev.message||"unknown")));delete waiting[k];});};
      w.postMessage({wasm:wasm});workers.push(w);}
  }catch(e){return {run:main,close:function(){},kind:"the page itself (slower)",n:1};}
  function pump(){while(idle.length&&queue.length){var job=queue.shift(),w=idle.shift();waiting[job.id]=job;
    w.postMessage({id:job.id,type:CONV_TYPE_ID[job.type],x:job.x,rows:job.rows,cols:job.cols},[job.x.buffer]);}}
  return {kind:workers.length+" worker"+(workers.length>1?"s":""),n:workers.length,
    run:function(type,x,rows,cols){if(dead)return main(type,x,rows,cols);
      if(type==="F32")return main(type,x,rows,cols);
      return new Promise(function(res,rej){queue.push({id:++seq,type:type,x:x,rows:rows,cols:cols,res:res,rej:rej});pump();});},
    close:function(){workers.forEach(function(w){try{w.terminate();}catch(e){}});try{URL.revokeObjectURL(url);}catch(e){}}};}
/* where the finished GGUF goes */
function convSink(name,total){
  var buf=[],bufLen=0,CH=4*1048576,id=null,first=true;
  function concat(){var o=new Uint8Array(bufLen),p=0;buf.forEach(function(b){o.set(b,p);p+=b.length;});buf=[];bufLen=0;return o;}
  function b64(u8){var s="",i,STEP=0x8000;for(i=0;i<u8.length;i+=STEP)s+=String.fromCharCode.apply(null,u8.subarray(i,i+STEP));return btoa(s);}
  if(INB){
    var send=function(force){if(!bufLen||(!force&&bufLen<CH))return Promise.resolve();var data=b64(concat());return INB.call("convertWrite",{id:id,data:data});};
    return {where:"inside this app",
      begin:function(){return INB.call("convertBegin",{name:name,size:total}).then(function(r){id=r.id;});},
      write:function(b){buf.push(b.slice());bufLen+=b.length;return send(false);},
      close:function(){return send(true).then(function(){return INB.call("convertEnd",{id:id});}).then(function(r){
        return ingNativeRefresh().then(function(){var m=state.models.filter(function(x){return x.nativeId===(r.model&&r.model.id);})[0];return m||null;});});},
      abort:function(){return id?INB.call("convertAbort",{id:id}).catch(function(){}):Promise.resolve();}};}
  if(shellStoreOK()){var api=shellApi(),mid=uid();
    var put=function(force){if(!bufLen||(!force&&bufLen<CH))return Promise.resolve();var data=b64(concat()),f=first;first=false;
      return Promise.resolve(api.put_model_part(mid,data,f)).then(function(ok){if(ok===false)throw new Error("the computer app could not write the file (is the disk full?)");});};
    return {where:"in Ingenium's folder on this computer",
      begin:function(){return Promise.resolve();},
      write:function(b){buf.push(b.slice());bufLen+=b.length;return put(false);},
      close:function(){return put(true).then(function(){
        var rec={id:mid,fileName:name+".gguf",customName:name.slice(0,40),sizeBytes:total,type:"GGUF",quant:parseQuant(name),paramB:parseParams(name),
          color:SWATCHES[state.models.length%SWATCHES.length],effort:3,tokens:1024,ctx:8192,fileState:"ready",stored:true,shellStored:true,converted:true};
        fileHandles[mid]=shellRemoteFile(rec);state.models.push(rec);saveState();renderModels();return rec;});},
      abort:function(){try{if(typeof api.delete_model_file==="function")api.delete_model_file(mid);}catch(e){}return Promise.resolve();}};}
  /* a web browser: the parts become one file in the browser's own storage */
  return {where:"in this browser's storage",
    begin:function(){return Promise.resolve();},
    write:function(b){buf.push(b.slice());bufLen+=b.length;return Promise.resolve();},
    close:function(){var f=new File(buf,name+".gguf",{type:"application/octet-stream"});buf=[];
      var before=state.models.length;addEntries([{file:f,handle:null}]);var rec=state.models[before]||null;if(rec){rec.converted=true;rec.customName=name.slice(0,40);saveState();renderModels();}return Promise.resolve(rec);},
    abort:function(){buf=[];return Promise.resolve();}};}
/* files from the browser's File objects */
function convSources(files){return files.map(function(f){var name=f.webkitRelativePath||f.name;
  return {name:name,size:f.size,read:function(o,n){return f.slice(o,o+n).arrayBuffer().then(function(b){return new Uint8Array(b);});}};});}
var convState={busy:false,stop:false,info:null};
function convIsModelFiles(files){return files.some(function(f){return /\.(safetensors|bin|pt|pth)$|(^|\/)config\.json$|tokenizer(_config)?\.json$|tokenizer\.model$/i.test(f.name);});}
function convNote(t){var n=$("convNote");if(n)n.textContent=t||"";}
function convPick(){if(convState.busy)return;var inp=$("convFiles");if(!inp)return;inp.value="";inp.click();}
function convSizeText(b){return fmtBytes(b);}
function convOpen(fileList){
  var files=Array.prototype.slice.call(fileList||[]);if(!files.length)return;
  if(convState.busy){convNote("A conversion is running; wait for it to finish.");return;}
  var card=$("convCard");if(card&&card.scrollIntoView)try{card.scrollIntoView({behavior:"smooth",block:"start"});}catch(e){}
  convNote("Reading "+files.length+" file"+(files.length>1?"s":"")+"…");$("convPlan").innerHTML="";
  ICM.inspect(convSources(files)).then(function(p){convState.info=p;convRender(p);},function(e){convNote(e&&e.message?e.message:String(e));});}
function convRender(p){
  var box=$("convPlan");box.innerHTML="";convNote("");
  var g=p.kind==="gguf";
  var arch=g?(p.gguf.kv.filter(function(e){return e.key==="general.architecture";})[0]||{}).value:p.arch;
  var head=el("div","conv-head");
  var nm=g?((p.gguf.kv.filter(function(e){return e.key==="general.name";})[0]||{}).value||p.file.name.replace(/\.gguf$/i,"")):convDefaultName(p);
  var fmt=g?"a GGUF file":p.mlx?("MLX, "+p.mlxq.bits+"-bit"):p.kind==="pytorch"?"PyTorch (.bin or .pt)":"safetensors";
  head.innerHTML='<div class="conv-what"><b>'+esc(nm)+'</b></div><div class="small muted">'+esc((arch||"unknown")+" family · "+fmt+(p.params?" · about "+ICM.sizeLabel(p.params)+" parameters":""))+'</div>';
  box.appendChild(head);
  var opts=[["Q4_K_M","Small and fast","Q4_K_M: about a quarter of the original size. The usual choice; quality stays close to the original."],
    ["Q8_0","Near the original","Q8_0: about half the original size, and very close to it."],
    ["F16","The original","F16: full quality, the largest file and the slowest to run."]];
  var use=lineupUsableGB(),pick=null,list=el("div","conv-opts");
  var compact=g&&!p.gguf.tensors.some(function(t){return ["F16","BF16","Q8_0"].indexOf(t.type)>=0||(t.type==="F32"&&t.ne.length>1);});
  if(compact){var c=el("p","small muted");c.textContent="This GGUF is already in a compact form, so there is nothing to make smaller. It runs as it is: add it with the box above.";box.appendChild(c);return;}
  opts.forEach(function(o){var bytes=0,ok=true;
    try{bytes=g?ICM.prepareRequant(p,o[0]).total:ICM.plan(p,o[0]).reduce(function(a,t){return a+Math.ceil(t.nbytes/32)*32;},0);}catch(e){ok=false;}
    if(!ok)return;
    var need=bytes/1073741824*1.12+0.7,fits=use==null||need<=use;
    var row=el("label","conv-opt");
    row.innerHTML='<input type="radio" name="convQ" value="'+o[0]+'"><span><b>'+esc(o[1])+'</b> · '+esc(convSizeText(bytes))+(fits?"":' <span class="lu-warn">larger than this device can comfortably run</span>')+'<br><span class="small muted">'+esc(o[2])+'</span></span>';
    if(!pick&&fits){pick=o[0];row.querySelector("input").checked=true;}
    list.appendChild(row);});
  if(!pick){var f=list.querySelector("input");if(f)f.checked=true;}
  box.appendChild(list);
  var nameRow=el("div","conv-name");nameRow.innerHTML='<label class="small muted" for="convName">Name in Ingenium</label><input id="convName" type="text" maxlength="60">';
  box.appendChild(nameRow);nameRow.querySelector("input").value=String(nm).slice(0,60);
  var go=el("div","conv-go");go.innerHTML='<button class="btn primary" id="convStart">Convert</button><button class="btn ghost" id="convStop" hidden>Stop</button>'
    +'<div class="conv-bar" hidden><i></i></div><div class="small muted" id="convProg"></div>';
  box.appendChild(go);
  $("convStart").onclick=convStart;$("convStop").onclick=function(){convState.stop=true;convNote("Stopping…");};}
/* a name for the result: the model's folder, its own record of where it came from, or its family and size */
function convDefaultName(p){
  var folder=p.files[0]&&p.files[0].name.split("/").length>1?p.files[0].name.split("/")[0]:"";
  var rec=String(p.config._name_or_path||(p.tokConfig&&p.tokConfig.name_or_path)||"").split("/").pop();
  if(/^(tmp|temp|model|checkpoint|\.)/i.test(rec))rec="";
  var fam={llama:"Llama",qwen2:"Qwen2",qwen3:"Qwen3"}[p.arch]||"Model";
  return (folder||rec||(fam+" "+ICM.sizeLabel(p.params))).replace(/[_]+/g," ").slice(0,60);}
function convStart(){
  var p=convState.info;if(!p||convState.busy)return;
  var q=(document.querySelector('input[name="convQ"]:checked')||{}).value||"Q4_K_M";
  var name=(($("convName")||{}).value||"Converted model").replace(/[\/\\:*?"<>|]+/g," ").trim()||"Converted model";
  var g=p.kind==="gguf",P;
  convNote("Preparing…");
  try{P=g?ICM.prepareRequant(p,q):ICM.prepare(p,q,name);}catch(e){convNote(e&&e.message?e.message:String(e));return;}
  convNote("");convState.busy=true;convState.stop=false;
  $("convStart").disabled=true;$("convStop").hidden=false;var bar=document.querySelector("#convPlan .conv-bar");if(bar)bar.hidden=false;
  var pool=convPool(),t0=Date.now(),lastPaint=0,sink=convSink(name,P.total),report=null,phone=!!INB;
  sink.begin().then(function(){
    var opts={quality:q,name:name,prepared:P,pool:pool.run,parallel:pool.n+1,chunkFloats:phone?524288:1048576,stop:function(){return convState.stop;},
      progress:function(d,t){var now=Date.now();if(now-lastPaint<250&&d<t)return;lastPaint=now;
        var f=t?d/t:0,bi=document.querySelector("#convPlan .conv-bar i");if(bi)bi.style.width=(100*f).toFixed(1)+"%";
        var secs=(now-t0)/1000,left=f>0.02?secs*(1-f)/f:null,pr=$("convProg");
        if(pr)pr.textContent=Math.floor(100*f)+"% · "+fmtBytes(d)+" of "+fmtBytes(t)+(left!=null?" · about "+convTime(left)+" left":"")+" · using "+pool.kind;}};
    var w={write:function(b){return sink.write(b);},close:function(){return Promise.resolve();}};
    return (g?ICM.requantize(p,w,opts):ICM.convert(p,w,opts)).then(function(r){report=r;return sink.close();});})
  .then(function(rec){pool.close();convState.busy=false;
    var secs=Math.round((Date.now()-t0)/1000),pre=report&&report.pre;
    var msg=name+" is ready ("+fmtBytes(report.bytes)+", "+report.quality+", made in "+convTime(secs)+"). It is kept "+sink.where+" and appears under Your models.";
    if(pre&&!pre.known)msg+=" Its tokenizer is not one llama.cpp lists by name, so Ingenium chose \""+pre.name+"\" from its pattern; if its replies look garbled, a ready-made GGUF from Hugging Face is the safer choice.";
    convNote(msg);$("convPlan").innerHTML="";convState.info=null;
    if(rec&&rec.id)setActive(rec.id,{fromUser:true});renderModels();})
  .catch(function(e){pool.close();convState.busy=false;var stopped=convState.stop;
    sink.abort().then(function(){
      convNote(stopped?"Stopped. Nothing was kept.":"The conversion did not finish: "+(e&&e.message?e.message:e));
      var b2=$("convStart");if(b2)b2.disabled=false;var s2=$("convStop");if(s2)s2.hidden=true;});});}
function convTime(s){s=Math.max(1,Math.round(s));if(s<60)return s+" s";var m=Math.round(s/60);if(m<60)return m+" min";return Math.floor(m/60)+" h "+(m%60)+" min";}
(function(){
  var b=$("convChoose");if(b)b.onclick=convPick;
  var inp=$("convFiles");if(inp)inp.onchange=function(){convOpen(inp.files);};
  var fb=$("convFolder");if(fb){var fi2=document.createElement("input");fi2.type="file";fi2.multiple=true;
    if("webkitdirectory" in fi2){fi2.setAttribute("webkitdirectory","");fi2.style.display="none";document.body.appendChild(fi2);
      fi2.onchange=function(){convOpen(fi2.files);};fb.onclick=function(){if(!convState.busy){fi2.value="";fi2.click();}};}
    else fb.hidden=true;}
  var cz=$("convCard");if(cz){["dragenter","dragover"].forEach(function(ev){cz.addEventListener(ev,function(e){e.preventDefault();cz.classList.add("over");});});
    ["dragleave","drop"].forEach(function(ev){cz.addEventListener(ev,function(e){e.preventDefault();cz.classList.remove("over");});});
    cz.addEventListener("drop",function(e){if(e.dataTransfer&&e.dataTransfer.files)convOpen(e.dataTransfer.files);});}
  try{var t={};(ING_TOKENIZER_FINGERPRINTS||[]).forEach(function(r){t[r[0]]=r[1];});ICV.setFingerprints(t);}catch(e){}
})();

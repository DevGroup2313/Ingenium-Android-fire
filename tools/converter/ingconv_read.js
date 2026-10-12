/* ============ R72: the converter, part 2: reading model files ============
   Every reader works on "sources": {name, size, read(offset, length)} that give
   bytes on demand, so a model of many gigabytes is never held in memory at once.
   safetensors (Hugging Face, MLX), PyTorch .bin/.pt (a zip holding a pickle; the
   pickle is read by a small interpreter that knows only how tensors are stored and
   refuses everything else, so no code inside a file can ever run) and GGUF. */
var ICR=(function(){
  "use strict";
  var TD=(typeof TextDecoder!=="undefined")?new TextDecoder("utf-8"):null;
  function utf8(b){return TD.decode(b);}
  function u64(dv,o){var lo=dv.getUint32(o,true),hi=dv.getUint32(o+4,true);if(hi>=0x200000)throw new Error("number too large");return hi*4294967296+lo;}
  var DSIZE={F64:8,F32:4,F16:2,BF16:2,I64:8,I32:4,U32:4,I16:2,U16:2,I8:1,U8:1,BOOL:1,F8_E4M3:1,F8_E5M2:1};
  /* ---------- safetensors ---------- */
  function safetensors(src){
    return src.read(0,8).then(function(h){var n=u64(new DataView(h.buffer,h.byteOffset,8),0);
      if(n<2||n>200*1048576||n+8>src.size)throw new Error(src.name+" is not a safetensors file");
      return src.read(8,n).then(function(b){var j=JSON.parse(utf8(b)),out=[];
        Object.keys(j).forEach(function(k){if(k==="__metadata__")return;var e=j[k];
          if(!DSIZE[e.dtype])throw new Error("unsupported number type "+e.dtype+" in "+src.name);
          out.push({name:k,dtype:e.dtype,shape:e.shape.slice(),src:src,offset:8+n+e.data_offsets[0],nbytes:e.data_offsets[1]-e.data_offsets[0]});});
        return {tensors:out,meta:j.__metadata__||{}};});});}
  /* ---------- zip (stored entries only, as torch.save writes them) ---------- */
  function zipEntries(src){
    var tail=Math.min(src.size,65536+22);
    return src.read(src.size-tail,tail).then(function(b){var dv=new DataView(b.buffer,b.byteOffset,b.byteLength),e=-1;
      for(var i=b.length-22;i>=0;i--)if(dv.getUint32(i,true)===0x06054b50){e=i;break;}
      if(e<0)throw new Error(src.name+" is not a zip archive");
      var cdSize=dv.getUint32(e+12,true),cdOff=dv.getUint32(e+16,true),count=dv.getUint16(e+10,true);
      var z64=e-20>=0&&dv.getUint32(e-20,true)===0x07064b50?u64(dv,e-20+8):-1;
      var go=z64>=0?src.read(z64,56).then(function(x){var d=new DataView(x.buffer,x.byteOffset,56);if(d.getUint32(0,true)!==0x06064b50)throw new Error("bad zip64");
          count=u64(d,32);cdSize=u64(d,40);cdOff=u64(d,48);}):Promise.resolve();
      return go.then(function(){return src.read(cdOff,cdSize);}).then(function(cd){var d=new DataView(cd.buffer,cd.byteOffset,cd.byteLength),p=0,list=[];
        for(var k=0;k<count;k++){if(d.getUint32(p,true)!==0x02014b50)throw new Error("bad zip directory");
          var method=d.getUint16(p+10,true),csize=d.getUint32(p+20,true),usize=d.getUint32(p+24,true),nl=d.getUint16(p+28,true),xl=d.getUint16(p+30,true),cl=d.getUint16(p+32,true),loc=d.getUint32(p+42,true);
          var name=utf8(cd.subarray(p+46,p+46+nl));
          var x=p+46+nl,xe=x+xl;while(x+4<=xe){var id=d.getUint16(x,true),sz=d.getUint16(x+2,true),q=x+4;
            if(id===1){if(usize===0xffffffff){usize=u64(d,q);q+=8;}if(csize===0xffffffff){csize=u64(d,q);q+=8;}if(loc===0xffffffff){loc=u64(d,q);q+=8;}}x+=4+sz;}
          list.push({name:name,method:method,size:usize,csize:csize,local:loc});p+=46+nl+xl+cl;}
        return list;});});}
  function zipDataOffset(src,ent){return src.read(ent.local,30).then(function(h){var d=new DataView(h.buffer,h.byteOffset,30);
    if(d.getUint32(0,true)!==0x04034b50)throw new Error("bad zip entry");return ent.local+30+d.getUint16(26,true)+d.getUint16(28,true);});}
  /* ---------- the pickle reader: only what torch.save writes ---------- */
  var STORAGE={FloatStorage:"F32",HalfStorage:"F16",BFloat16Storage:"BF16",DoubleStorage:"F64",LongStorage:"I64",IntStorage:"I32",
    ShortStorage:"I16",CharStorage:"I8",ByteStorage:"U8",BoolStorage:"BOOL"};
  var DTYPE={float32:"F32",float:"F32",float16:"F16",half:"F16",bfloat16:"BF16",float64:"F64",int64:"I64",int32:"I32",int16:"I16",int8:"I8",uint8:"U8",bool:"BOOL"};
  function Global(mod,name){this.mod=mod;this.name=name;}
  function unpickle(b){
    var dv=new DataView(b.buffer,b.byteOffset,b.byteLength),p=0,stack=[],marks=[],memo={},i,n;
    function pop(){return stack.pop();}
    function popMark(){var m=marks.pop();return stack.splice(m,stack.length-m);}
    function str(len){var s=utf8(b.subarray(p,p+len));p+=len;return s;}
    function line(){var e=b.indexOf(10,p),s=utf8(b.subarray(p,e));p=e+1;return s;}
    function call(f,args){
      if(!(f instanceof Global))throw new Error("this file asks for something other than tensors; it was not opened");
      var k=f.mod+"."+f.name;
      if(k==="collections.OrderedDict"||k==="builtins.dict")return {};
      if(k==="torch._utils._rebuild_tensor_v2"||k==="torch._utils._rebuild_tensor")return {tensor:true,storage:args[0],offset:args[1],shape:args[2],stride:args[3]};
      if(k==="torch._utils._rebuild_parameter"||k==="torch._utils._rebuild_parameter_with_state")return args[0];
      if(k==="torch.Size"||k==="builtins.tuple")return args[0]||[];
      if(k==="builtins.set"||k==="builtins.frozenset")return args[0]||[];
      throw new Error("this file asks for "+k+", which a model's weights never need; it was not opened");}
    for(;;){var op=b[p++];
      switch(op){
        case 0x80:p++;break;                       // PROTO
        case 0x95:p+=8;break;                      // FRAME
        case 0x2e:return pop();                    // STOP
        case 0x7d:stack.push({});break;            // EMPTY_DICT
        case 0x5d:stack.push([]);break;            // EMPTY_LIST
        case 0x29:stack.push([]);break;            // EMPTY_TUPLE
        case 0x28:marks.push(stack.length);break;  // MARK
        case 0x71:memo[b[p++]]=stack[stack.length-1];break;                       // BINPUT
        case 0x72:memo[dv.getUint32(p,true)]=stack[stack.length-1];p+=4;break;    // LONG_BINPUT
        case 0x94:memo[Object.keys(memo).length]=stack[stack.length-1];break;     // MEMOIZE
        case 0x68:stack.push(memo[b[p++]]);break;                                 // BINGET
        case 0x6a:stack.push(memo[dv.getUint32(p,true)]);p+=4;break;              // LONG_BINGET
        case 0x58:n=dv.getUint32(p,true);p+=4;stack.push(str(n));break;           // BINUNICODE
        case 0x8c:n=b[p++];stack.push(str(n));break;                              // SHORT_BINUNICODE
        case 0x8d:n=u64(dv,p);p+=8;stack.push(str(n));break;                      // BINUNICODE8
        case 0x55:n=b[p++];stack.push(str(n));break;                              // SHORT_BINSTRING
        case 0x54:n=dv.getUint32(p,true);p+=4;stack.push(str(n));break;           // BINSTRING
        case 0x43:n=b[p++];stack.push(b.slice(p,p+n));p+=n;break;                 // SHORT_BINBYTES
        case 0x42:n=dv.getUint32(p,true);p+=4;stack.push(b.slice(p,p+n));p+=n;break; // BINBYTES
        case 0x63:{var mod=line(),nm=line();stack.push(new Global(mod,nm));break;}  // GLOBAL
        case 0x93:{var nm2=pop(),mod2=pop();stack.push(new Global(mod2,nm2));break;} // STACK_GLOBAL
        case 0x4b:stack.push(b[p++]);break;                                       // BININT1
        case 0x4d:stack.push(dv.getUint16(p,true));p+=2;break;                    // BININT2
        case 0x4a:stack.push(dv.getInt32(p,true));p+=4;break;                     // BININT
        case 0x8a:{n=b[p++];var v=0,mul=1;for(i=0;i<n;i++){v+=b[p+i]*mul;mul*=256;}if(n&&b[p+n-1]>=128)v-=mul;p+=n;stack.push(v);break;} // LONG1
        case 0x47:stack.push(dv.getFloat64(p,false));p+=8;break;                  // BINFLOAT
        case 0x4e:stack.push(null);break;                                         // NONE
        case 0x88:stack.push(true);break;case 0x89:stack.push(false);break;       // NEWTRUE NEWFALSE
        case 0x85:stack.push([pop()]);break;                                      // TUPLE1
        case 0x86:{var t2=pop(),t1=pop();stack.push([t1,t2]);break;}              // TUPLE2
        case 0x87:{var u3=pop(),u2=pop(),u1=pop();stack.push([u1,u2,u3]);break;}  // TUPLE3
        case 0x74:stack.push(popMark());break;                                    // TUPLE
        case 0x6c:stack.push(popMark());break;                                    // LIST
        case 0x52:{var args=pop(),f=pop();stack.push(call(f,args));break;}        // REDUCE
        case 0x81:{var a2=pop(),c2=pop();stack.push(call(c2,a2));break;}          // NEWOBJ
        case 0x62:pop();break;                                                    // BUILD (state ignored)
        case 0x73:{var val=pop(),key=pop();stack[stack.length-1][key]=val;break;} // SETITEM
        case 0x75:{var kv=popMark(),d=stack[stack.length-1];for(i=0;i<kv.length;i+=2)d[kv[i]]=kv[i+1];break;} // SETITEMS
        case 0x61:{var it=pop();stack[stack.length-1].push(it);break;}            // APPEND
        case 0x65:{var items=popMark();Array.prototype.push.apply(stack[stack.length-1],items);break;} // APPENDS
        case 0x51:{var pid=pop();                                                 // BINPERSID
          if(!Array.isArray(pid)||pid[0]!=="storage")throw new Error("unknown stored object");
          var st=pid[1],dt=(st instanceof Global)?(STORAGE[st.name]||DTYPE[st.name]):null;
          if(!dt)throw new Error("unsupported storage "+(st&&st.name));
          stack.push({storage:true,dtype:dt,key:String(pid[2])});break;}
        default:throw new Error("unsupported pickle step 0x"+op.toString(16)+" at "+(p-1));}}}
  function torchZip(src){
    return zipEntries(src).then(function(list){
      var pkl=list.filter(function(e){return /(^|\/)data\.pkl$/.test(e.name);})[0];
      if(!pkl)throw new Error(src.name+" holds no data.pkl; it is not a PyTorch weights file");
      if(pkl.method!==0)throw new Error("compressed entries are not supported");
      var prefix=pkl.name.slice(0,pkl.name.length-"data.pkl".length);
      return zipDataOffset(src,pkl).then(function(o){return src.read(o,pkl.size);}).then(function(bytes){
        var root=unpickle(bytes);
        /* the weights may sit inside {"state_dict": ...} or {"model": ...} */
        function isDict(d){return d&&typeof d==="object"&&!Array.isArray(d)&&!d.tensor;}
        function hasTensors(d){return isDict(d)&&Object.keys(d).some(function(k){return d[k]&&d[k].tensor;});}
        var sd=root;if(!hasTensors(sd))["state_dict","model","module","model_state_dict"].forEach(function(k){if(!hasTensors(sd)&&root&&hasTensors(root[k]))sd=root[k];});
        if(!hasTensors(sd))throw new Error("no tensors found in "+src.name);
        var byKey={};list.forEach(function(e){if(e.name.indexOf(prefix+"data/")===0)byKey[e.name.slice(prefix.length+5)]=e;});
        var names=Object.keys(sd).filter(function(k){return sd[k]&&sd[k].tensor;});
        return Promise.all(names.map(function(k){var t=sd[k],ent=byKey[t.storage.key];
          if(!ent)throw new Error("storage "+t.storage.key+" is missing");
          if(ent.method!==0)throw new Error("compressed storages are not supported");
          var es=DSIZE[t.storage.dtype],shape=t.shape.slice(),want=1,ok=true;
          for(var i=shape.length-1;i>=0;i--){if(shape[i]!==1&&t.stride[i]!==want)ok=false;want*=shape[i];}
          if(!ok)throw new Error(k+" is stored transposed; save the model again with safetensors");
          return zipDataOffset(src,ent).then(function(o){return {name:k,dtype:t.storage.dtype,shape:shape,src:src,offset:o+t.offset*es,nbytes:want*es};});}))
          .then(function(ts){return {tensors:ts,meta:{}};});});});}
  /* ---------- GGUF (as an input, to make a smaller copy) ---------- */
  var GT={0:"F32",1:"F16",2:"Q4_0",3:"Q4_1",6:"Q5_0",7:"Q5_1",8:"Q8_0",10:"Q2_K",11:"Q3_K",12:"Q4_K",13:"Q5_K",14:"Q6_K",30:"BF16"};
  var GBLK={F32:[1,4],F16:[1,2],BF16:[1,2],Q4_0:[32,18],Q4_1:[32,20],Q5_0:[32,22],Q5_1:[32,24],Q8_0:[32,34],Q2_K:[256,84],Q3_K:[256,110],Q4_K:[256,144],Q5_K:[256,176],Q6_K:[256,210]};
  function gguf(src){
    var buf=null,base=0,pos=0;
    function need(n){if(buf&&pos+n<=base+buf.length)return Promise.resolve();
      var len=Math.max(n,4*1048576);return src.read(pos,Math.min(len,src.size-pos)).then(function(b){buf=b;base=pos;if(b.length<n)throw new Error("GGUF header is cut short");});}
    function dv(){return new DataView(buf.buffer,buf.byteOffset,buf.byteLength);}
    function rd(n,f){return need(n).then(function(){var v=f(dv(),pos-base);pos+=n;return v;});}
    function rU32(){return rd(4,function(d,o){return d.getUint32(o,true);});}
    function rU64(){return rd(8,function(d,o){return u64(d,o);});}
    function rStr(){return rU64().then(function(n){return need(n).then(function(){var s=utf8(buf.subarray(pos-base,pos-base+n));pos+=n;return s;});});}
    var SC={0:[1,"getUint8"],1:[1,"getInt8"],2:[2,"getUint16"],3:[2,"getInt16"],4:[4,"getUint32"],5:[4,"getInt32"],6:[4,"getFloat32"],7:[1,"getUint8"],10:[8,"u64"],11:[8,"i64"],12:[8,"getFloat64"]};
    function rVal(t){
      if(t===8)return rStr();
      if(t===9)return rU32().then(function(at){return rU64().then(function(n){var arr=[],i=0;
        function next(){if(i>=n)return Promise.resolve({type:at,items:arr});return rVal(at).then(function(v){arr.push(v);i++;return (i%4096)?next():Promise.resolve().then(next);});}
        return next();});});
      var s=SC[t];if(!s)throw new Error("unknown GGUF value type "+t);
      return rd(s[0],function(d,o){if(s[1]==="u64")return u64(d,o);if(s[1]==="i64"){return d.getInt32(o,true)+d.getInt32(o+4,true)*4294967296;}var v=d[s[1]](o,true);return t===7?!!v:v;});}
    var out={kv:[],tensors:[]};
    return rU32().then(function(m){if(m!==0x46554747)throw new Error(src.name+" is not a GGUF file");return rU32();})
      .then(function(ver){if(ver<2||ver>3)throw new Error("GGUF version "+ver+" is not supported");return rU64();})
      .then(function(nt){return rU64().then(function(nkv){
        var i=0;function kv(){if(i>=nkv)return Promise.resolve();return rStr().then(function(k){return rU32().then(function(t){return rVal(t).then(function(v){out.kv.push({key:k,type:t,value:v});i++;return kv();});});});}
        var j=0;function ti(){if(j>=nt)return Promise.resolve();var t={};return rStr().then(function(nm){t.name=nm;return rU32();}).then(function(nd){var dims=[],k=0;
            function dim(){if(k>=nd)return Promise.resolve();return rU64().then(function(x){dims.push(x);k++;return dim();});}
            return dim().then(function(){t.ne=dims;return rU32();});}).then(function(ty){t.type=GT[ty]||("type"+ty);t.typeId=ty;return rU64();})
          .then(function(off){t.rel=off;out.tensors.push(t);j++;return ti();});}
        return kv().then(ti);});})
      .then(function(){var al=32;out.kv.forEach(function(e){if(e.key==="general.alignment")al=e.value;});
        var start=Math.ceil(pos/al)*al;
        out.tensors.forEach(function(t){var bl=GBLK[t.type],n=t.ne.reduce(function(a,b){return a*b;},1);
          t.offset=start+t.rel;t.src=src;t.nbytes=bl?n/bl[0]*bl[1]:-1;t.shape=t.ne.slice().reverse();t.dtype=t.type;});
        return out;});}
  /* ---------- rows of a tensor as 32-bit floats ---------- */
  var _f=new Float32Array(1),_u=new Uint32Array(_f.buffer);
  function toF32(dtype,b,n,y){var dv=new DataView(b.buffer,b.byteOffset,b.byteLength),i;
    switch(dtype){
      case "F32":for(i=0;i<n;i++)y[i]=dv.getFloat32(4*i,true);return;
      case "F16":for(i=0;i<n;i++)y[i]=ICQ.F16[dv.getUint16(2*i,true)];return;
      case "BF16":for(i=0;i<n;i++){_u[0]=dv.getUint16(2*i,true)<<16;y[i]=_f[0];}return;
      case "F64":for(i=0;i<n;i++)y[i]=Math.fround(dv.getFloat64(8*i,true));return;
      case "Q8_0":ICQ.decode("Q8_0",b,0,n,y,0);return;}
    throw new Error("cannot read "+dtype+" weights");}
  function rowsOf(t){var s=t.shape;return s.length<2?1:s.slice(0,-1).reduce(function(a,b){return a*b;},1);}
  function colsOf(t){var s=t.shape;return s.length?s[s.length-1]:1;}
  /* read rows [r0, r0+n) of a plain tensor */
  function readRows(t,r0,n){var cols=colsOf(t),es=t.dtype==="Q8_0"?34/32:DSIZE[t.dtype];
    return t.src.read(t.offset+r0*cols*es,n*cols*es).then(function(b){var y=new Float32Array(n*cols);toF32(t.dtype,b,n*cols,y);return y;});}
  /* MLX: weight (packed uint32) + scales + biases, dequantized row by row */
  function readRowsMlx(q,r0,n){var w=q.weight,sc=q.scales,bi=q.biases,bits=q.bits,g=q.group,per=32/bits,mask=(1<<bits)-1;
    var packedCols=colsOf(w),cols=packedCols*per,groups=cols/g;
    return Promise.all([w.src.read(w.offset+r0*packedCols*4,n*packedCols*4),readRows(sc,r0,n),bi?readRows(bi,r0,n):Promise.resolve(null)]).then(function(r){
      var dv=new DataView(r[0].buffer,r[0].byteOffset,r[0].byteLength),S=r[1],B=r[2],y=new Float32Array(n*cols);
      for(var row=0;row<n;row++)for(var c=0;c<packedCols;c++){var word=dv.getUint32(4*(row*packedCols+c),true);
        for(var k=0;k<per;k++){var col=c*per+k,gi=row*groups+((col/g)|0);
          y[row*cols+col]=Math.fround(Math.fround(S[gi]*((word>>>(bits*k))&mask))+(B?B[gi]:0));}}
      return y;});}
  return {safetensors:safetensors,torchZip:torchZip,gguf:gguf,readRows:readRows,readRowsMlx:readRowsMlx,rowsOf:rowsOf,colsOf:colsOf,unpickle:unpickle,zipEntries:zipEntries,DSIZE:DSIZE};
})();
if(typeof module!=="undefined")module.exports=ICR;

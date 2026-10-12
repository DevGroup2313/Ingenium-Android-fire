// node test_conv.js <hf model dir> <out.gguf> <quality> [viaF16]
global.ICQ=require('./ingconv_core.js');global.ICR=require('./ingconv_read.js');global.ICV=require('./ingconv_vocab.js');global.ICM=require('./ingconv_main.js');
const fs=require('fs'),path=require('path');
const tab={};JSON.parse(fs.readFileSync(__dirname+'/chkhsh.json','utf8')).forEach(p=>tab[p[0]]=p[1]);ICV.setFingerprints(tab);
function fileSrc(p){const fd=fs.openSync(p,'r'),size=fs.fstatSync(fd).size;
  return {name:path.basename(p),size:size,read:(o,n)=>{const b=Buffer.alloc(n);fs.readSync(fd,b,0,n,o);return Promise.resolve(new Uint8Array(b.buffer,b.byteOffset,n));}};}
const dir=process.argv[2],out=process.argv[3],q=process.argv[4]||'F16',via=process.argv[5]==='viaF16',useW=process.argv.includes('workers');
// a pool of worker threads, each running quant.wasm, as the page's Web Workers do
let pool=null;
if(useW){const {Worker}=require('worker_threads');const wasm=fs.readFileSync(__dirname+'/quant.wasm');const N=4;const ws=[],idle=[],queue=[],waiting={};let seq=0;
  const src=`const {parentPort}=require('worker_threads');let Q;parentPort.on('message',d=>{if(d.wasm){Q=new WebAssembly.Instance(new WebAssembly.Module(d.wasm),{}).exports;parentPort.postMessage({ready:1});return;}
    const mem=Q.memory,base=(Q.heap_base()+15)&~15,n=d.x.length,need=base+n*4+n*2+4096;if(mem.buffer.byteLength<need)mem.grow(Math.ceil((need-mem.buffer.byteLength)/65536));
    new Float32Array(mem.buffer,base,n).set(d.x);const o=base+n*4;let len=0;for(let r=0;r<d.rows;r++)len+=Q.quantize(d.type,base+r*d.cols*4,o+len,d.cols);
    const out=new Uint8Array(mem.buffer,o,len).slice();parentPort.postMessage({id:d.id,out},[out.buffer]);});`;
  const pump=()=>{while(idle.length&&queue.length){const j=queue.shift(),w=idle.shift();waiting[j.id]=j;w.postMessage({id:j.id,type:{F16:1,Q5_0:6,Q8_0:8,Q4_K:12,Q6_K:14}[j.type],x:j.x,rows:j.rows,cols:j.cols},[j.x.buffer]);}};
  for(let i=0;i<N;i++){const w=new Worker(src,{eval:true});w.on('message',m=>{if(m.ready){idle.push(w);pump();return;}const j=waiting[m.id];delete waiting[m.id];idle.push(w);pump();j.res(m.out);});w.postMessage({wasm});ws.push(w);}
  pool={run:(type,x,rows,cols)=>{if(type==='F32'){const out=new Uint8Array(rows*cols*4);ICQ.encode('F32',x,0,rows*cols,out,0);return Promise.resolve(out);}return new Promise((res,rej)=>{queue.push({id:++seq,type,x,rows,cols,res,rej});pump();});},close:()=>ws.forEach(w=>w.terminate())};}
const files=fs.statSync(dir).isDirectory()?fs.readdirSync(dir).map(f=>fileSrc(path.join(dir,f))):[fileSrc(dir)];
const fd=fs.openSync(out,'w');let pos=0;
const sink={write:b=>{fs.writeSync(fd,b,0,b.length,pos);pos+=b.length;return Promise.resolve();},close:()=>{fs.closeSync(fd);return Promise.resolve();}};
const t0=Date.now();let last=0;
ICM.inspect(files).then(p=>{
  const opts={quality:q,viaF16:via,pool:pool&&pool.run,parallel:pool?6:1,progress:(d,t)=>{if(Date.now()-last>5000){last=Date.now();console.error('  '+(100*d/t).toFixed(1)+'%');}}};
  return p.kind==='gguf'?ICM.requantize(p,sink,opts):ICM.convert(p,sink,opts);})
 .then(r=>{console.log(JSON.stringify(r),((Date.now()-t0)/1000).toFixed(1)+'s');if(pool)pool.close();}).catch(e=>{console.error('FAILED',e.stack||e);process.exit(1);});

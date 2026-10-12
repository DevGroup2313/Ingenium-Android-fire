/* ============ R72: Ingenium's model converter, part 1: numbers and quantizers ============
   Turns weights into the forms a GGUF file holds. The quantizers are line-for-line
   ports of llama.cpp's reference routines (ggml-quants.c, release b11321), with
   every step rounded to 32-bit floats as the C code does, so a model converted
   here matches one converted by llama.cpp's own tools. */
var ICQ=(function(){
  "use strict";
  var fr=Math.fround;
  /* half floats, exactly as numpy and ggml round them (to nearest, ties to even) */
  var _f=new Float32Array(1),_u=new Uint32Array(_f.buffer);
  function f32bits(x){_f[0]=x;return _u[0];}
  function f32ToF16(x){
    var f=f32bits(x),hs=(f>>>16)&0x8000,fe=f&0x7f800000,fs;
    if(fe>=0x47800000){if(fe===0x7f800000){fs=f&0x007fffff;if(fs!==0){var r=0x7c00+(fs>>>13);if(r===0x7c00)r++;return hs+r;}return hs+0x7c00;}return hs+0x7c00;}
    if(fe<=0x38000000){if(fe<0x33000000)return hs;fe>>>=23;fs=0x00800000+(f&0x007fffff);fs>>>=(113-fe);
      if(((fs&0x3fff)!==0x1000)||(f&0x7ff))fs+=0x1000;return hs+(fs>>>13);}
    var he=(fe-0x38000000)>>>13;fs=f&0x007fffff;if((fs&0x3fff)!==0x1000)fs+=0x1000;return hs+((fs>>>13)+he);}
  var F16=new Float32Array(65536);
  (function(){for(var h=0;h<65536;h++){var s=(h&0x8000)?-1:1,e=(h>>10)&31,m=h&1023;
    F16[h]=e===0?s*m*Math.pow(2,-24):e===31?(m?NaN:s*Infinity):s*(1+m/1024)*Math.pow(2,e-15);}})();
  function f16ToF32(h){return F16[h];}
  /* nearest_int: float + 12582912, which rounds to nearest even in float32 */
  function nearestInt(v){return fr(fr(v)+12582912)-12582912;}
  function roundf(v){return v<0?-Math.floor(-v+0.5):Math.floor(v+0.5);}
  var QK_K=256;
  var TYPES={F32:{id:0,blk:1,size:4},F16:{id:1,blk:1,size:2},Q5_0:{id:6,blk:32,size:22},Q8_0:{id:8,blk:32,size:34},
    Q4_K:{id:12,blk:256,size:144},Q6_K:{id:14,blk:256,size:210},BF16:{id:30,blk:1,size:2}};
  function rowBytes(type,n){var t=TYPES[type];return n/t.blk*t.size;}
  function putF16(dv,o,x){dv.setUint16(o,f32ToF16(x),true);}

  function q8_0(x,xo,out,oo,n){var dv=new DataView(out.buffer,out.byteOffset,out.byteLength);
    for(var i=0;i<n/32;i++){var amax=0,b=xo+i*32;
      for(var j=0;j<32;j++){var a=Math.abs(x[b+j]);if(a>amax)amax=a;}
      var d=fr(amax/127),id=d?fr(1/d):0;putF16(dv,oo,d);
      for(j=0;j<32;j++)out[oo+2+j]=roundf(fr(x[b+j]*id))&255;
      oo+=34;}}
  function q5_0(x,xo,out,oo,n){var dv=new DataView(out.buffer,out.byteOffset,out.byteLength);
    for(var i=0;i<n/32;i++){var amax=0,max=0,b=xo+i*32;
      for(var j=0;j<32;j++){var v=x[b+j],a=Math.abs(v);if(amax<a){amax=a;max=v;}}
      var d=fr(max/-16),id=d?fr(1/d):0,qh=0;putF16(dv,oo,d);
      for(j=0;j<16;j++){var x0=fr(x[b+j]*id),x1=fr(x[b+16+j]*id);
        var i0=Math.min(31,Math.trunc(fr(x0+16.5))<<24>>24),i1=Math.min(31,Math.trunc(fr(x1+16.5))<<24>>24);
        out[oo+6+j]=((i0&15)|((i1&15)<<4))&255;
        qh|=((i0&0x10)>>>4)<<j;qh|=((i1&0x10)>>>4)<<(j+16);}
      dv.setUint32(oo+2,qh>>>0,true);oo+=22;}}
  /* make_qkx2_quants (n=32, nmax=15, rmin=-1, rdelta=0.1, nstep=20, use_mad=false) */
  var _L=new Uint8Array(QK_K),_Laux=new Uint8Array(32),_w=new Float32Array(32),_xs=new Float32Array(32);
  function makeQkx2(x,xo,w,L,lo,res){
    var n=32,nmax=15,min=x[xo],max=x[xo],sumW=w[0],sumX=fr(sumW*x[xo]),i,l;
    for(i=1;i<n;i++){var v=x[xo+i];if(v<min)min=v;if(v>max)max=v;sumW=fr(sumW+w[i]);sumX=fr(sumX+fr(w[i]*v));}
    if(min>0)min=0;
    if(max===min){for(i=0;i<n;i++)L[lo+i]=0;res.min=-min;return 0;}
    var iscale=fr(nmax/fr(max-min)),scale=fr(1/iscale),best=0;
    for(i=0;i<n;i++){l=nearestInt(fr(iscale*fr(x[xo+i]-min)));l=l<0?0:l>nmax?nmax:l;L[lo+i]=l;
      var diff=fr(fr(fr(scale*l)+min)-x[xo+i]);diff=fr(diff*diff);best=fr(best+fr(w[i]*diff));}
    for(var is=0;is<=20;is++){
      iscale=fr(fr(fr(-1+fr(fr(0.1)*is))+nmax)/fr(max-min));
      var sl=0,sl2=0,sxl=0;
      for(i=0;i<n;i++){l=nearestInt(fr(iscale*fr(x[xo+i]-min)));l=l<0?0:l>nmax?nmax:l;_Laux[i]=l;
        var wi=w[i];sl=fr(sl+fr(wi*l));sl2=fr(sl2+fr(fr(wi*l)*l));sxl=fr(sxl+fr(fr(wi*l)*x[xo+i]));}
      var D=fr(fr(sumW*sl2)-fr(sl*sl));
      if(D>0){var ts=fr(fr(fr(sumW*sxl)-fr(sumX*sl))/D),tm=fr(fr(fr(sl2*sumX)-fr(sl*sxl))/D);
        if(tm>0){tm=0;ts=fr(sxl/sl2);}
        var cur=0;for(i=0;i<n;i++){var df=fr(fr(fr(ts*_Laux[i])+tm)-x[xo+i]);df=fr(df*df);cur=fr(cur+fr(w[i]*df));}
        if(cur<best){for(i=0;i<n;i++)L[lo+i]=_Laux[i];best=cur;scale=ts;min=tm;}}}
    res.min=-min;return scale;}
  var _sc=new Float32Array(8),_mn=new Float32Array(8),_res={min:0},_scl=new Uint8Array(12);
  function q4_K(x,xo,out,oo,n){var dv=new DataView(out.buffer,out.byteOffset,out.byteLength);
    for(var i=0;i<n/QK_K;i++){var b=xo+i*QK_K,maxScale=0,maxMin=0,j,l;
      for(j=0;j<8;j++){var s2=0;for(l=0;l<32;l++){var v=x[b+32*j+l];s2=fr(s2+fr(v*v));}
        var av=fr(Math.sqrt(fr(s2/32)));for(l=0;l<32;l++)_w[l]=fr(av+Math.abs(x[b+32*j+l]));
        _sc[j]=makeQkx2(x,b+32*j,_w,_L,32*j,_res);_mn[j]=_res.min;
        if(_sc[j]>maxScale)maxScale=_sc[j];if(_mn[j]>maxMin)maxMin=_mn[j];}
      var invS=maxScale>0?fr(63/maxScale):0,invM=maxMin>0?fr(63/maxMin):0;
      _scl.fill(0);
      for(j=0;j<8;j++){var ls=nearestInt(fr(invS*_sc[j]))&255,lm=nearestInt(fr(invM*_mn[j]))&255;ls=Math.min(63,ls);lm=Math.min(63,lm);
        if(j<4){_scl[j]=ls;_scl[j+4]=lm;}else{_scl[j+4]=(ls&15)|((lm&15)<<4);_scl[j-4]|=((ls>>4)<<6);_scl[j]|=((lm>>4)<<6);}}
      var dh=f32ToF16(fr(maxScale/63)),mh=f32ToF16(fr(maxMin/63));
      dv.setUint16(oo,dh,true);dv.setUint16(oo+2,mh,true);for(j=0;j<12;j++)out[oo+4+j]=_scl[j];
      var dd=F16[dh],dm0=F16[mh];
      for(j=0;j<8;j++){var sc,m;if(j<4){sc=_scl[j]&63;m=_scl[j+4]&63;}else{sc=(_scl[j+4]&15)|((_scl[j-4]>>6)<<4);m=(_scl[j+4]>>4)|((_scl[j]>>6)<<4);}
        var d=fr(dd*sc);if(!d)continue;var dm=fr(dm0*m);
        for(var ii=0;ii<32;ii++){l=nearestInt(fr(fr(x[b+32*j+ii]+dm)/d));_L[32*j+ii]=l<0?0:l>15?15:l;}}
      var q=oo+16;for(j=0;j<QK_K;j+=64){for(l=0;l<32;l++)out[q+l]=_L[j+l]|(_L[j+l+32]<<4);q+=32;}
      oo+=144;}}
  /* make_qx_quants (n=16, nmax=32, rmse_type=1, no weights) */
  var _L6=new Int8Array(QK_K),_sc6=new Float32Array(16);
  function makeQx(x,xo,L,lo){var n=16,nmax=32,max=0,amax=0,i,l;
    for(i=0;i<n;i++){var ax=Math.abs(x[xo+i]);if(ax>amax){amax=ax;max=x[xo+i];}}
    if(amax<fr(1e-15)){for(i=0;i<n;i++)L[lo+i]=0;return 0;}
    var iscale=fr(-nmax/max),slx=0,sl2=0;
    for(i=0;i<n;i++){var xi=x[xo+i];l=nearestInt(fr(iscale*xi));l=l<-nmax?-nmax:l>nmax-1?nmax-1:l;L[lo+i]=l+nmax;
      var w=fr(xi*xi);slx=fr(slx+fr(fr(w*xi)*l));sl2=fr(sl2+fr(fr(w*l)*l));}
    var scale=sl2?fr(slx/sl2):0,best=fr(scale*slx);
    for(var is=-9;is<=9;is++){if(is===0)continue;
      iscale=fr(-fr(nmax+fr(fr(0.1)*is))/max);slx=0;sl2=0;
      for(i=0;i<n;i++){xi=x[xo+i];l=nearestInt(fr(iscale*xi));l=l<-nmax?-nmax:l>nmax-1?nmax-1:l;w=fr(xi*xi);
        slx=fr(slx+fr(fr(w*xi)*l));sl2=fr(sl2+fr(fr(w*l)*l));}
      if(sl2>0&&fr(slx*slx)>fr(best*sl2)){
        for(i=0;i<n;i++){l=nearestInt(fr(iscale*x[xo+i]));l=l<-nmax?-nmax:l>nmax-1?nmax-1:l;L[lo+i]=l+nmax;}
        scale=fr(slx/sl2);best=fr(scale*slx);}}
    return scale;}
  function q6_K(x,xo,out,oo,n){var dv=new DataView(out.buffer,out.byteOffset,out.byteLength);
    for(var i=0;i<n/QK_K;i++){var b=xo+i*QK_K,maxScale=0,maxAbs=0,ib,j,l;
      for(ib=0;ib<16;ib++){var s=makeQx(x,b+16*ib,_L6,16*ib);_sc6[ib]=s;var as=Math.abs(s);if(as>maxAbs){maxAbs=as;maxScale=s;}}
      if(maxAbs<fr(1e-15)){for(j=0;j<210;j++)out[oo+j]=0;oo+=210;continue;}
      var iscale=fr(-128/maxScale),dh=f32ToF16(fr(1/iscale));dv.setUint16(oo+208,dh,true);
      var scales=oo+192;for(ib=0;ib<16;ib++){var v=Math.min(127,nearestInt(fr(iscale*_sc6[ib])));out[scales+ib]=v&255;}
      var dd=F16[dh];
      for(j=0;j<16;j++){var scj=(out[scales+j]<<24>>24),d=fr(dd*scj);if(!d)continue;
        for(var ii=0;ii<16;ii++){l=nearestInt(fr(x[b+16*j+ii]/d));l=l<-32?-32:l>31?31:l;_L6[16*j+ii]=l+32;}}
      var ql=oo,qh=oo+128;
      for(j=0;j<QK_K;j+=128){for(l=0;l<32;l++){var q1=_L6[j+l]&15,q2=_L6[j+l+32]&15,q3=_L6[j+l+64]&15,q4=_L6[j+l+96]&15;
          out[ql+l]=q1|(q3<<4);out[ql+l+32]=q2|(q4<<4);
          out[qh+l]=(_L6[j+l]>>4)|((_L6[j+l+32]>>4)<<2)|((_L6[j+l+64]>>4)<<4)|((_L6[j+l+96]>>4)<<6);}
        ql+=64;qh+=32;}
      oo+=210;}}
  /* write n floats (one or more whole rows) as the given type */
  function encode(type,x,xo,n,out,oo){
    var i,dv;
    switch(type){
      case "F32":dv=new DataView(out.buffer,out.byteOffset,out.byteLength);for(i=0;i<n;i++)dv.setFloat32(oo+4*i,x[xo+i],true);return;
      case "F16":dv=new DataView(out.buffer,out.byteOffset,out.byteLength);for(i=0;i<n;i++)dv.setUint16(oo+2*i,f32ToF16(x[xo+i]),true);return;
      case "Q8_0":return q8_0(x,xo,out,oo,n);
      case "Q5_0":return q5_0(x,xo,out,oo,n);
      case "Q4_K":return q4_K(x,xo,out,oo,n);
      case "Q6_K":return q6_K(x,xo,out,oo,n);}
    throw new Error("no encoder for "+type);}
  /* the reverse, for reading GGUF inputs and for checks */
  function decode(type,bytes,bo,n,y,yo){var dv=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),i,j;
    switch(type){
      case "F32":for(i=0;i<n;i++)y[yo+i]=dv.getFloat32(bo+4*i,true);return;
      case "F16":for(i=0;i<n;i++)y[yo+i]=F16[dv.getUint16(bo+2*i,true)];return;
      case "BF16":for(i=0;i<n;i++){_u[0]=dv.getUint16(bo+2*i,true)<<16;y[yo+i]=_f[0];}return;
      case "Q8_0":for(i=0;i<n/32;i++){var d=F16[dv.getUint16(bo,true)];for(j=0;j<32;j++)y[yo+32*i+j]=fr(d*(bytes[bo+2+j]<<24>>24));bo+=34;}return;}
    throw new Error("cannot read "+type+" weights");}
  return {f32ToF16:f32ToF16,f16ToF32:f16ToF32,F16:F16,TYPES:TYPES,QK_K:QK_K,rowBytes:rowBytes,encode:encode,decode:decode,nearestInt:nearestInt};
})();
if(typeof module!=="undefined")module.exports=ICQ;

// Lossless conversion of opaque grayscale RGBA reference engravings to gray PNG.
// PNG filters predict each channel independently. Keeping the filtered red
// channel therefore preserves every sample when filtered R == G == B. Alpha
// is also verified as opaque, for every filter/row/pixel, before dropping it.
const fs=require('fs'),zlib=require('zlib');
const {Worker,isMainThread,parentPort,workerData}=require('worker_threads');
const table=Uint32Array.from({length:256},(_,i)=>{let c=i;for(let j=0;j<8;j++)c=(c&1)?0xedb88320^(c>>>1):c>>>1;return c>>>0;});
function crc(data){let c=0xffffffff;for(const b of data)c=table[(c^b)&255]^(c>>>8);return (c^0xffffffff)>>>0;}
function chunk(type,data){const tag=Buffer.from(type),out=Buffer.alloc(data.length+12);out.writeUInt32BE(data.length);tag.copy(out,4);data.copy(out,8);out.writeUInt32BE(crc(Buffer.concat([tag,data])),data.length+8);return out;}
function paeth(a,b,c){const p=a+b-c,pa=Math.abs(p-a),pb=Math.abs(p-b),pc=Math.abs(p-c);return pa<=pb&&pa<=pc?a:pb<=pc?b:c;}
function compact(input){
  const chunks=[];let ihdr;
  for(let at=8;at<input.length;){const size=input.readUInt32BE(at),type=input.toString('ascii',at+4,at+8),data=input.subarray(at+8,at+8+size);if(type==='IHDR')ihdr=data;if(type==='IDAT')chunks.push(data);at+=size+12;}
  if(!ihdr||ihdr[8]!==8||ihdr[9]!==6||ihdr[12]!==0)return input;
  const w=ihdr.readUInt32BE(0),h=ihdr.readUInt32BE(4),raw=zlib.inflateSync(Buffer.concat(chunks)),gray=Buffer.alloc((w+1)*h);
  if(raw.length!==(w*4+1)*h)return input;
  for(let y=0;y<h;y++){
    let src=y*(w*4+1),dst=y*(w+1);const filter=raw[src++];gray[dst++]=filter;
    if(filter>4)return input;
    const above=y?255:0;
    const expected=(left,upperLeft)=>{const predictor=[0,left,above,Math.floor((left+above)/2),paeth(left,above,upperLeft)][filter];return (255-predictor)&255;};
    const first=expected(0,0),rest=expected(255,y?255:0);
    for(let x=0;x<w;x++,src+=4){
      if(raw[src]!==raw[src+1]||raw[src]!==raw[src+2]||raw[src+3] !== (x?rest:first))return input;
      gray[dst++]=raw[src];
    }
  }
  const header=Buffer.from(ihdr);header[9]=0;
  const output=Buffer.concat([input.subarray(0,8),chunk('IHDR',header),chunk('sRGB',Buffer.from([0])),chunk('IDAT',zlib.deflateSync(gray,{level:9})),chunk('IEND',Buffer.alloc(0))]);
  return output.length<input.length?output:input;
}
module.exports={compact};
function processJobs(jobs){
  let before=0,after=0,count=0;
  for(const j of jobs){const original=fs.readFileSync(j.out),result=compact(original);before+=original.length;after+=result.length;if(result!==original){fs.writeFileSync(j.out,result);count++;}}
  return {count,before,after};
}
if(!isMainThread)parentPort.postMessage(processJobs(workerData));
else if(require.main===module){
  const jobs=JSON.parse(fs.readFileSync(process.argv[2],'utf8')).filter(j=>j.height===1148);
  Promise.all(Array.from({length:4},(_,i)=>new Promise((resolve,reject)=>{
    const worker=new Worker(__filename,{workerData:jobs.filter((_,n)=>n%4===i)});
    worker.once('message',resolve);worker.once('error',reject);
    worker.once('exit',code=>{if(code)reject(Error('PNG worker failed: '+code));});
  }))).then(rows=>{
    const total=rows.reduce((a,b)=>({count:a.count+b.count,before:a.before+b.before,after:a.after+b.after}),{count:0,before:0,after:0});
    process.stdout.write(JSON.stringify({images:total.count,beforeMB:total.before/1048576,afterMB:total.after/1048576})+'\n');
  }).catch(e=>{process.stderr.write(e.message+'\n');process.exitCode=1;});
}

// Rasterize path-only MuseScore SVGs locally. No browser or service is used at runtime.
const fs = require('fs'), path = require('path'), cp = require('child_process');
const jobs = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const work = path.dirname(path.resolve(process.argv[2]));
const chrome = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
for (let start = 0; start < jobs.length; start += 40) {
  const batch = jobs.slice(start, start + 40).filter(j => !fs.existsSync(j.out));
  if (!batch.length) continue;
  const inputs = batch.map(j => ({ svg: fs.readFileSync(j.in, 'utf8'), width: j.width, height: j.height }));
  const html = `<!doctype html><meta charset="utf-8"><pre id="result">pending</pre><script>
  const jobs=${JSON.stringify(inputs).replace(/</g, '\\u003c')};
  Promise.all(jobs.map(j=>new Promise((resolve,reject)=>{const image=new Image();image.onload=()=>{
    const c=document.createElement('canvas');c.width=j.width;c.height=j.height;
    const ctx=c.getContext('2d');ctx.fillStyle='white';ctx.fillRect(0,0,c.width,c.height);
    ctx.drawImage(image,0,0,c.width,c.height);resolve(c.toDataURL('image/png').split(',')[1]);
  };image.onerror=()=>reject(Error('SVG failed'));image.src='data:image/svg+xml;base64,'+btoa(unescape(encodeURIComponent(j.svg)));})))
  .then(png=>document.getElementById('result').textContent=JSON.stringify(png))
  .catch(e=>document.getElementById('result').textContent='ERROR: '+e.message);</script>`;
  const file = path.join(work, 'rasterize.html'); fs.writeFileSync(file, html);
  let output;
  try {
    output = cp.execFileSync(chrome, ['--headless=new','--no-sandbox','--disable-gpu','--no-first-run',
      '--disable-background-networking','--disable-breakpad','--disable-crash-reporter','--no-default-browser-check',
      '--user-data-dir='+path.join(work,'raster-profile-'+start+'-'+Date.now()),
      '--dump-dom','--virtual-time-budget=6000',new URL('file:///'+file.replace(/\\/g,'/')).href],
      {encoding:'utf8',maxBuffer:100*1024*1024,timeout:30000,windowsHide:true,stdio:['ignore','pipe','ignore']});
  } catch(error) {
    // Chrome can finish dump-dom and stall while shutting down. A complete
    // result is usable; never dump its multi-megabyte base64 output as an error.
    output=String(error.stdout||'');
    if(!output.includes('</pre>')) throw Error('Chrome rasterization failed: '+(error.code||error.status));
  }
  const match=output.match(/<pre id="result">([^<]+)<\/pre>/);
  if(!match || !match[1].startsWith('[')) throw Error('Rasterization failed: '+(match?.[1]||'missing output'));
  const png=JSON.parse(match[1]); if(png.length!==batch.length) throw Error('Incomplete image batch');
  png.forEach((data,i)=>fs.writeFileSync(batch[i].out,Buffer.from(data,'base64')));
  process.stdout.write(`Rasterized ${Math.min(start+40,jobs.length)} / ${jobs.length}\n`);
}

// Offline runtime check with a simulated DOM and Web Audio clock. No browser/GUI automation.
const fs=require('fs'),vm=require('vm'),assert=require('assert/strict'),path=require('path');
const file=path.join(__dirname,'CLASSICAL.html'),html=fs.readFileSync(file,'utf8');
const raw=html.match(/<script id="library-data" type="application\/json">([\s\S]*?)<\/script>/)[1];
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const ids=[...html.matchAll(/\bid="([^"]+)"/g)].map(x=>x[1]);let nodes={},timers=new Map(),events={},nextTimer=0,oscillators=[];
const drawing=new Proxy({},{get:()=>()=>{}});
for(const id of ids)nodes[id]={id,style:{},value:({tempo:'96',speed:'1',search:''})[id]||'',checked:false,disabled:false,textContent:'',innerHTML:'',addEventListener:(name,f)=>{events[id+':'+name]=f},getBoundingClientRect:()=>({width:800,height:165}),getContext:()=>drawing};
nodes['library-data'].textContent=raw;
class AudioContext{constructor(){this.currentTime=0;this.destination={}}async resume(){}createOscillator(){const o={frequency:{value:0},connect(){},disconnect(){},start(t){assert(Number.isFinite(t)&&t>=0)},stop(t){if(t!==undefined)assert(Number.isFinite(t));this.stopped=true},stopped:false};oscillators.push(o);return o}createGain(){return {gain:{setValueAtTime(){},linearRampToValueAtTime(){},exponentialRampToValueAtTime(){}},connect(){},disconnect(){}}}}
const body={classList:{add(){}},append(){}};
const document={getElementById:id=>{assert(nodes[id],`Missing element ${id}`);return nodes[id]},body,hidden:false,addEventListener:(name,f)=>{events['document:'+name]=f},createElement:()=>({click(){},remove(){}})};
const context=vm.createContext({document,window:{AudioContext,devicePixelRatio:1,addEventListener:(name,f)=>{events['window:'+name]=f}},localStorage:{getItem:()=>null,setItem(){}},Blob,URL,Set,console,setTimeout:(f,ms)=>{assert(ms>=0);timers.set(++nextTimer,{f,ms});return nextTimer},clearTimeout:id=>timers.delete(id),requestAnimationFrame:()=>1,cancelAnimationFrame(){}});
vm.runInContext(code,context);
async function main(){
 const items=vm.runInContext('D.items',context);assert.equal(items.length,39);assert.equal(items.filter(x=>x.ready).length,32);
 for(const item of items.filter(x=>!x.external)){
  vm.runInContext(`pick(${JSON.stringify(item.id)})`,context);await vm.runInContext('play()',context);
  assert(vm.runInContext('playing',context));assert(vm.runInContext('voices.length > 0',context));
  assert.equal(nodes.download.disabled,!item.ready);vm.runInContext('stop()',context);assert(!vm.runInContext('playing',context));assert.equal(timers.size,0);
 }
 vm.runInContext("composer='말러';renderNav();renderTracks()",context);assert(nodes.tracks.innerHTML.includes('교향곡 1번'));assert(!nodes.tracks.innerHTML.includes('피터와 늑대'));
 vm.runInContext("composer='쇼스타코비치';renderTracks()",context);assert(nodes.tracks.innerHTML.includes('XML 미확보'));assert(!nodes.tracks.innerHTML.includes('data-play='));
 nodes['ready-only'].checked=true;vm.runInContext('renderTracks()',context);assert(nodes.tracks.innerHTML.includes('조건에 맞는 곡이 없어요'));nodes['ready-only'].checked=false;
 vm.runInContext("pick('classical-gttm-189')",context);const pending=vm.runInContext('play()',context);vm.runInContext('stop()',context);await pending;assert.equal(vm.runInContext('voices.length',context),0,'stop while audio is resuming must cancel scheduling');
 nodes.loop.checked=true;await vm.runInContext('play()',context);assert.equal(timers.size,1);const finish=[...timers.values()][0].f;finish();await new Promise(setImmediate);assert(vm.runInContext('playing',context));vm.runInContext('stop()',context);
 nodes.speed.value='0.65';await vm.runInContext('play()',context);const slow=vm.runInContext('seconds',context);nodes.speed.value='1.2';await vm.runInContext('play()',context);assert(vm.runInContext('seconds',context)<slow);
 document.hidden=true;events['document:visibilitychange']();assert(!vm.runInContext('playing',context));assert.equal(vm.runInContext('voices.length',context),0);
 const report={localMelodies:36,eightBarFiles:32,externalLinks:3,audioSchedule:'passed (simulated Web Audio)',stopDuringResume:'passed',loopAndTempo:'passed',composerFilters:'passed',backgroundStops:'passed',browserVisualAndRealAudio:'not run'};
 fs.writeFileSync(path.join(__dirname,'player-checks.json'),JSON.stringify(report,null,2));console.log(report);
}
main().catch(e=>{console.error(e);process.exitCode=1});

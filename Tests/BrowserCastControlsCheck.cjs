'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync('Server/Web/receiver.js','utf8');
const block=source.slice(source.indexOf("  const castVideo=$('cast-video')"),source.indexOf("  window.addEventListener('pagehide'"));
function fixture(video){
  const button={attrs:{},setAttribute(k,v){this.attrs[k]=v;}},messages=[];
  video.addEventListener=(_,fn)=>{video.changed=fn;};
  vm.runInNewContext(block,{$:id=>id==='video'?video:button,status:s=>messages.push(s)});
  return {button,messages};
}
(async()=>{
  let picks=0;
  const video={webkitShowPlaybackTargetPicker(){picks++;}},f=fixture(video);
  await f.button.onclick();assert.equal(picks,1);assert.equal(f.button.attrs['data-active'],'false');
  video.webkitCurrentPlaybackTargetIsWireless=true;video.changed();assert.equal(f.button.attrs['data-active'],'true');
  video.webkitCurrentPlaybackTargetIsWireless=false;video.changed();assert.equal(f.button.attrs['data-active'],'false');
  const listeners={},remote={state:'disconnected',prompt(){picks++;return Promise.resolve();},addEventListener(k,fn){listeners[k]=fn;}};
  const r=fixture({remote});await r.button.onclick();assert.equal(picks,2);
  remote.state='connected';listeners.connect();assert.equal(r.button.attrs['aria-pressed'],'true');
  const no=fixture({});await no.button.onclick();assert.match(no.messages[0],/未开放/);
  const failure=fixture({webkitShowPlaybackTargetPicker(){throw Error('unavailable');}});
  await failure.button.onclick();assert.match(failure.messages[0],/未能选择/);
  assert.match(fs.readFileSync('Server/Web/receiver.html','utf8'),/id="cast-video"/);
  console.log('PASS system video picker, standard fallback, actual route state and unsupported/error feedback');
})().catch(error=>{console.error(error);process.exitCode=1;});

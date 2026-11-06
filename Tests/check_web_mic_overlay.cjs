'use strict';
// No network or device access: exercise production mute and pending capture cancellation.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const nodes=new Map();
const el=id=>{if(!nodes.has(id))nodes.set(id,{value:'',checked:false,style:{},attrs:{},setAttribute(key,value){this.attrs[key]=value;},addEventListener(){},replaceChildren(){}});return nodes.get(id);};
let resolveCapture,stopped=0,detached=0;
const track={kind:'audio',enabled:true,stop(){stopped++;}};
const stream={getTracks:()=>[track],getAudioTracks:()=>[track]};
const sender={track,replaceTrack(value){assert.equal(value,null);detached++;return Promise.resolve();}};
const sandbox={document:{getElementById:el},window:{},navigator:{language:'zh-CN',mediaDevices:{getUserMedia:()=>new Promise(resolve=>{resolveCapture=resolve;})}},crypto:require('node:crypto').webcrypto,localStorage:{getItem(){return null;},setItem(){}},clearInterval(){},TextEncoder};
vm.runInNewContext(fs.readFileSync('Server/Web/receiver-room.js','utf8'),sandbox);
(async()=>{
  el('voice-toggle').checked=true;
  await el('voice-toggle').onchange();
  assert.equal(el('voice-toggle').checked,true);assert.equal(resolveCapture,undefined);
  assert.match(el('voice-status').textContent,/连接就绪/);
  el('voice-toggle').checked=false;
  el('voice-input').value='chosen-before-connection';await el('voice-input').onchange();
  assert.equal(el('voice-input').value,'chosen-before-connection');assert.equal(resolveCapture,undefined);
  const session={pc:{getSenders:()=>[sender],createDataChannel:()=>({close(){}})},connected:true};
  sandbox.ToupingRoom.attach(session);session.roomReady=true;
  el('voice-toggle').checked=true;
  const pending=el('voice-toggle').onchange();
  el('voice-test').checked=true;
  el('mute-mic').onclick();
  assert.equal(track.enabled,false);assert.equal(detached,1);
  assert.equal(el('voice-toggle').checked,false);assert.equal(el('voice-test').checked,false);
  resolveCapture(stream);await pending;
  assert.equal(stopped,1);assert.equal(el('voice-toggle').checked,false);
  sandbox.ToupingRoom.stop(session);
  await el('mute-mic').onclick();
  assert.equal(el('voice-toggle').checked,true);assert.equal(el('mute-mic').attrs['data-state'],'pending');
  el('mute-mic').onclick();
  assert.equal(el('voice-toggle').checked,false);assert.equal(el('mute-mic').attrs['data-state'],'off');
  assert.equal(el('voice-status').textContent,'麦克风已关闭。');
  sandbox.navigator.mediaDevices.getUserMedia=async()=>stream;
  sandbox.navigator.mediaDevices.enumerateDevices=async()=>[{kind:'audioinput',deviceId:'mic-1',label:'测试设备'}];
  sandbox.Option=function(text,value){this.text=text;this.value=value;};
  sandbox.HTMLMediaElement=function(){};
  for(const id of ['voice-input','voice-output']) {
    el(id).replaceChildren=function(option){this.options=[option];};
    el(id).add=function(option){this.options.push(option);};
  }
  const before=stopped;
  await el('voice-input').onfocus();
  assert.equal(stopped,before);assert.equal(el('voice-toggle').checked,false);
  assert.equal(el('voice-input').options[1].value,'mic-1');
  assert.equal(detached,1); // Device access never attaches a sender.
  let captures=0;
  const liveTrack={kind:'audio',enabled:true,stop(){}}, liveStream={getTracks:()=>[liveTrack],getAudioTracks:()=>[liveTrack]};
  sandbox.navigator.mediaDevices.getUserMedia=async()=>{captures++;liveTrack.enabled=true;return liveStream;};
  sandbox.window.AudioContext=class {
    createAnalyser(){return {fftSize:256};}
    createMediaStreamSource(){return {connect(){}};}
    resume(){return Promise.resolve();} close(){return Promise.resolve();}
  };
  sandbox.setInterval=()=>1;
  const liveSender={track:null,replaceTrack(value){this.track=value;return Promise.resolve();}};
  const liveSession={pc:{createDataChannel:()=>({close(){}}),getSenders:()=>[liveSender],getTransceivers:()=>[{receiver:{track:{kind:'audio'}},sender:liveSender}]},connected:false};
  sandbox.ToupingRoom.attach(liveSession);el('voice-toggle').checked=true;
  liveSession.chat.onmessage({data:JSON.stringify({kind:'host',participant:'12345678-1234-1234-1234-123456789abc'})});
  assert.equal(captures,0); // Handshake alone must not start capture before connection.
  liveSession.connected=true;sandbox.ToupingRoom.ready(liveSession);
  await new Promise(setImmediate);
  assert.equal(captures,1);assert.equal(liveSender.track,liveTrack);assert.equal(el('mute-mic').attrs['data-state'],'on');
  sandbox.ToupingRoom.ready(liveSession);assert.equal(captures,1);
  el('screen-mic').onclick();assert.equal(liveSender.track,null);
  assert.equal(el('voice-button').textContent,'开启麦克');
  assert.equal(el('screen-mic').attrs['data-active'],'false');
  assert.equal(el('mute-mic').attrs['aria-label'],'打开麦克风');
  await el('voice-button').onclick();assert.equal(liveSender.track,liveTrack);
  assert.equal(el('screen-mic').textContent,'关闭麦克');
  assert.equal(el('screen-mic').attrs['data-active'],'true');
  assert.equal(el('mute-mic').attrs['aria-label'],'关闭麦克风');
  el('mute-mic').onclick();assert.equal(liveSender.track,null);
  sandbox.ToupingRoom.stop(liveSession);
  const events={},classes=new Set();
  el('viewer').classList={add:x=>classes.add(x),remove:x=>classes.delete(x),contains:x=>classes.has(x)};
  sandbox.window.addEventListener=(name,fn)=>{events[name]=fn;};
  sandbox.window.ToupingI18n={languages:[],strings:{}};
  sandbox.document.documentElement={};sandbox.document.querySelectorAll=()=>[];
  sandbox.location={protocol:'https:',hash:'',href:'https://test.invalid/'};
  sandbox.URLSearchParams=URLSearchParams;sandbox.URL=URL;
  vm.runInNewContext(fs.readFileSync('Server/Web/receiver.js','utf8'),sandbox);
  assert.equal(el('video').muted,false);
  el('video').srcObject={};el('video').play=()=>Promise.resolve();el('video').volume=1;
  el('sound').onclick();assert.equal(el('video').muted,true);assert.equal(el('speaker-sound').textContent,'开启声音');
  el('speaker-sound').onclick();assert.equal(el('video').muted,false);assert.equal(el('sound').textContent,'关闭声音');
  el('viewer-maximize').onclick();assert(classes.has('expanded'));
  el('exit-viewer').onclick();assert(!classes.has('expanded'));
  el('fullscreen').onclick();events.keydown({key:'Escape'});assert(!classes.has('expanded'));
  let requested=false;el('viewer').requestFullscreen=()=>{requested=true;return Promise.resolve();};
  el('fullscreen').onclick();assert(requested);assert(!classes.has('expanded'));
  el('viewer').requestFullscreen=()=>Promise.reject(Error('denied'));
  el('fullscreen').onclick();await Promise.resolve();assert(classes.has('expanded'));
  console.log('PASS connection-independent mic selection and device access, synchronized default-on speaker controls');
  console.log('PASS container fullscreen, fallback and exit');
  console.log('PASS overlay mute: immediate sender disable, detach, pending permission cancellation, disconnected action');
})().catch(error=>{console.error(error);process.exitCode=1;});

'use strict';
// No network or device access: exercise production mute and pending capture cancellation.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const nodes=new Map();
const el=id=>{if(!nodes.has(id))nodes.set(id,{value:'',checked:false,style:{},attrs:{},setAttribute(key,value){this.attrs[key]=value;},addEventListener(){},replaceChildren(){}});return nodes.get(id);};
// Real controls contain an SVG sibling: changing the label must preserve it.
const decorated=['voice-button','voice-test-button','speaker-sound'];
for(const id of decorated) {
  const node=el(id),label={textContent:''};node.decorationLost=false;
  node.querySelector=selector=>selector==='.control-label'?label:null;
  Object.defineProperty(node,'textContent',{get:()=>label.textContent,set:value=>{label.textContent=value;node.decorationLost=true;}});
}
let resolveCapture,stopped=0,detached=0;
const track={kind:'audio',enabled:true,stop(){stopped++;}};
const stream={getTracks:()=>[track],getAudioTracks:()=>[track]};
const sender={track,replaceTrack(value){assert.equal(value,null);detached++;return Promise.resolve();}};
const sandbox={document:{getElementById:el},window:{},navigator:{language:'zh-CN',mediaDevices:{getUserMedia:()=>new Promise(resolve=>{resolveCapture=resolve;})}},crypto:require('node:crypto').webcrypto,localStorage:{getItem(){return null;},setItem(){}},clearInterval(){},TextEncoder};
el('voice-toggle').checked=true; // Mirrors the default-on checkbox in the real HTML.
vm.runInNewContext(fs.readFileSync('Server/Web/receiver-room.js','utf8'),sandbox);
(async()=>{
  el('voice-toggle').checked=true;
  await el('voice-toggle').onchange();
  assert.equal(el('voice-toggle').checked,true);assert.equal(resolveCapture,undefined);
  assert.equal(el('voice-button').textContent,'话筒待开启');assert.equal(el('voice-button').attrs['data-active'],'false');
  assert.match(el('voice-status').textContent,/连接就绪/);
  el('voice-toggle').checked=false;
  el('voice-input').value='chosen-before-connection';await el('voice-input').onchange();
  assert.equal(el('voice-input').value,'chosen-before-connection');assert.equal(resolveCapture,undefined);
  const session={pc:{getSenders:()=>[sender],createDataChannel:()=>({close(){}})},connected:true};
  sandbox.ToupingRoom.attach(session);session.roomReady=true;
  el('voice-toggle').checked=true;
  const pending=el('voice-toggle').onchange();
  el('voice-test').checked=true;
  el('voice-button').onclick();
  assert.equal(track.enabled,false);assert.equal(detached,1);
  assert.equal(el('voice-toggle').checked,false);assert.equal(el('voice-test').checked,false);
  resolveCapture(stream);await pending;
  assert.equal(stopped,1);assert.equal(el('voice-toggle').checked,false);
  sandbox.ToupingRoom.stop(session);
  await el('voice-button').onclick();
  assert.equal(el('voice-toggle').checked,true);assert.equal(el('voice-button').textContent,'话筒待开启');
  el('voice-button').onclick();
  assert.equal(el('voice-toggle').checked,false);assert.equal(el('voice-button').textContent,'话筒已关闭');
  assert.equal(el('voice-status').textContent,'话筒已关闭。');
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
  let captures=0,lastConstraints,liveStops=0;
  const liveTrack={kind:'audio',enabled:true,stop(){liveStops++;}}, liveStream={getTracks:()=>[liveTrack],getAudioTracks:()=>[liveTrack]};
  sandbox.navigator.mediaDevices.getUserMedia=async constraints=>{lastConstraints=constraints;captures++;liveTrack.enabled=true;return liveStream;};
  sandbox.window.AudioContext=class {
    createAnalyser(){return {fftSize:256};}
    createMediaStreamSource(){return {connect(){}};}
    resume(){return Promise.resolve();} close(){return Promise.resolve();}
  };
  sandbox.setInterval=()=>1;
  const liveSender={track:null,replaceTrack(value){this.track=value;return Promise.resolve();}};
  const liveSession={pc:{createDataChannel:()=>({close(){}}),getSenders:()=>[liveSender],getTransceivers:()=>[{receiver:{track:{kind:'audio'}},sender:liveSender}]},connected:false};
  el('voice-input').value='';
  sandbox.ToupingRoom.attach(liveSession);el('voice-toggle').checked=true;
  liveSession.chat.onmessage({data:JSON.stringify({kind:'host',participant:'12345678-1234-1234-1234-123456789abc'})});
  assert.equal(captures,0); // Handshake alone must not start capture before connection.
  liveSession.connected=true;sandbox.ToupingRoom.ready(liveSession);
  await new Promise(setImmediate);
  assert.equal(captures,1);assert.equal(liveSender.track,liveTrack);assert.equal(el('voice-button').attrs['data-active'],'true');
  assert.equal(el('voice-button').textContent,'话筒已开启');assert.equal(el('voice-button').attrs['data-active'],'true');
  assert.equal(lastConstraints.audio.deviceId,undefined);assert.equal(lastConstraints.video,false);
  sandbox.ToupingRoom.ready(liveSession);assert.equal(captures,1);
  el('voice-button').onclick();assert.equal(liveSender.track,null);
  assert.equal(el('voice-button').textContent,'话筒已关闭');
  assert.equal(el('voice-button').attrs['data-active'],'false');
  assert.equal(el('voice-button').attrs['aria-label'],'话筒已关闭');
  await el('voice-button').onclick();assert.equal(liveSender.track,liveTrack);
  assert.equal(el('voice-button').textContent,'话筒已开启');
  assert.equal(el('voice-button').attrs['data-active'],'true');
  assert.equal(el('voice-button').attrs['aria-label'],'话筒已开启');
  el('voice-button').onclick();assert.equal(liveSender.track,null);
  await el('voice-button').onclick();
  const beforeDisconnect=liveStops;sandbox.ToupingRoom.stop(liveSession);
  assert(liveStops>beforeDisconnect);assert.equal(el('voice-toggle').checked,true);assert.equal(el('voice-button').textContent,'话筒待开启');
  const deniedSession={pc:liveSession.pc,connected:true};sandbox.ToupingRoom.attach(deniedSession);deniedSession.roomReady=true;
  sandbox.navigator.mediaDevices.getUserMedia=async()=>{throw Error('Synthetic permission denied');};
  sandbox.ToupingRoom.ready(deniedSession);await new Promise(setImmediate);
  assert.equal(el('voice-toggle').checked,false);assert.equal(el('voice-button').attrs['data-active'],'false');
  assert.equal(el('voice-button').textContent,'话筒已关闭');sandbox.ToupingRoom.stop(deniedSession);
  const events={};
  sandbox.window.addEventListener=(name,fn)=>{events[name]=fn;};
  sandbox.window.ToupingI18n={languages:[],strings:{}};
  sandbox.document.documentElement={};sandbox.document.querySelectorAll=()=>[];
  sandbox.location={protocol:'https:',hash:'',href:'https://test.invalid/'};
  sandbox.URLSearchParams=URLSearchParams;sandbox.URL=URL;
  vm.runInNewContext(fs.readFileSync('Server/Web/receiver.js','utf8'),sandbox);
  assert.equal(el('video').muted,false);
  el('video').srcObject={};el('video').play=()=>Promise.resolve();el('video').volume=1;
  el('speaker-sound').onclick();assert.equal(el('video').muted,true);assert.equal(el('speaker-sound').textContent,'声音已关闭');
  el('speaker-sound').onclick();assert.equal(el('video').muted,false);assert.equal(el('speaker-sound').textContent,'声音已开启');
  let requested=false,exited=false;
  el('video').requestFullscreen=()=>{requested=true;return Promise.resolve();};
  await el('fullscreen').onclick();assert(requested);
  sandbox.document.fullscreenElement=el('video');sandbox.document.exitFullscreen=async()=>{exited=true;sandbox.document.fullscreenElement=null;};
  await el('fullscreen').onclick();assert(exited);
  el('video').requestFullscreen=undefined;let safari=false;
  el('video').webkitEnterFullscreen=()=>{safari=true;};await el('fullscreen').onclick();assert(safari);
  el('video').requestFullscreen=()=>Promise.reject(Error('denied'));
  safari=false;await el('fullscreen').onclick();assert(safari);
  el('video').webkitEnterFullscreen=undefined;
  await el('fullscreen').onclick();assert.match(el('status').textContent,/系统控制栏/);
  for(const id of decorated)assert.equal(el(id).decorationLost,false,'SVG must survive label changes: '+id);
  console.log('PASS current-state wording, no green pending microphone, retained SVG ornaments');
  console.log('PASS connection-independent mic selection and device access, synchronized default-on speaker controls');
  console.log('PASS native video fullscreen, native exit, Safari media fullscreen and denial feedback');
  console.log('PASS default-on system mic intent, immediate mute/detach, permission cancellation and disconnect cleanup');
})().catch(error=>{console.error(error);process.exitCode=1;});

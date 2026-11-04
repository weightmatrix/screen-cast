// Exercise the production receiver state machine without cameras, media or a network.
const fs=require('node:fs'), vm=require('node:vm'), assert=require('node:assert/strict');
const crypto=require('node:crypto').webcrypto;
const nodes=new Map(), timers=new Map(); let next=0;
function node(id) {
  if(!nodes.has(id)) nodes.set(id,{value:'',textContent:'',disabled:false,muted:true,
    addEventListener(name,handler){this[name]=handler;},play(){return Promise.resolve();}});
  return nodes.get(id);
}
class PC {
  constructor(config){this.config=config; this.iceConnectionState='checking';this.iceGatheringState='gathering';PC.latest=this;}
  createDataChannel(){return {};}
  async setRemoteDescription(value){this.remoteDescription=value;}
  async addIceCandidate(){}
  async createAnswer(){return {type:'answer',sdp:'v=0\r\nm=audio 9 RTP/SAVPF 111\r\nm=video 9 RTP/SAVPF 96\r\n'};}
  async setLocalDescription(value){this.localDescription=value;}
  close(){this.iceConnectionState='closed';}
}
class WS {
  static OPEN=1;
  constructor(){this.readyState=1;this.sent=[];WS.latest=this;}
  send(text){this.sent.push(JSON.parse(text));}
  close(){this.readyState=3;}
}
const sandbox={document:{getElementById:node},location:{protocol:'https:',href:'https://test.invalid/touping/',hash:'#code=12345678'},
  window:{RTCPeerConnection:PC,addEventListener(){}},RTCPeerConnection:PC,WebSocket:WS,
  crypto,TextEncoder,URL,URLSearchParams,AbortController,MediaStream:class {addTrack(){}},
  localStorage:{getItem(){return null;},setItem(){}},console:{warn(){}},
  setTimeout(fn,ms){const id=++next;timers.set(id,{fn,ms});return id;},clearTimeout(id){timers.delete(id);},
  setInterval(fn,ms){const id=++next;timers.set(id,{fn,ms,interval:true});return id;},clearInterval(id){timers.delete(id);}};
vm.runInNewContext(fs.readFileSync('Server/Web/receiver.js','utf8'),sandbox);
const offer={type:'offer',sdp:'v=0\r\na=x-touping-audio:split-v1\r\nm=audio 9 RTP/SAVPF 111\r\nm=video 9 RTP/SAVPF 96\r\na=candidate:1 1 udp 1 secret-device.local 1234 typ host\r\n'};
async function start() {
  await node('join').submit({preventDefault(){}}); const ws=WS.latest; ws.onopen();
  ws.onmessage({data:JSON.stringify(offer)}); await new Promise(setImmediate);
  return {pc:PC.latest,ws};
}
(async()=>{
  const first=await start();
  assert.match(node('status').textContent,/配对成功/);
  first.pc.onicecandidate({candidate:{candidate:'candidate:2 1 udp 1 192.0.2.17 5555 typ srflx',sdpMid:'0',sdpMLineIndex:0}});
  assert.match(node('diagnostics').textContent,/srflx=1/);
  assert(!node('diagnostics').textContent.includes('192.0.2.17'));
  assert(!node('diagnostics').textContent.includes('secret-device'));
  assert(!node('diagnostics').textContent.includes('12345678'));
  [...timers.values()].find(value=>value.interval).fn();
  assert.match(node('status').textContent,/剩余/);
  [...timers.values()].find(value=>value.ms===25000).fn();
  assert.match(node('status').textContent,/25秒内未建立/);
  assert.equal(node('start').disabled,false); assert.equal(node('stop').disabled,true);
  const second=await start(); second.pc.connectionState='connected';second.pc.onconnectionstatechange();
  second.ws.onerror(); second.ws.onclose();
  assert.equal(node('start').disabled,true); assert.equal(node('stop').disabled,false);
  assert.match(node('status').textContent,/已连接/);
  assert(second.ws.sent.some(value=>value.type==='done'));
  assert(second.ws.sent.find(value=>value.type==='answer').sdp.includes('a=x-touping-audio:split-v1'));
  node('stop').onclick(); assert.equal(timers.size,0);
  console.log('PASS paired/direct stages, candidate privacy, countdown/timeout, post-pair close and cleanup');
})().catch(error=>{console.error(error);process.exitCode=1;});

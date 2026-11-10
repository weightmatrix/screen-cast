'use strict';
(() => {
  const el=id=>document.getElementById(id), read=(key,fallback)=>{try{return localStorage.getItem(key)||fallback;}catch(_){return fallback;}};
  const store=(key,value)=>{try{localStorage.setItem(key,value);}catch(_){}};
  const random=()=>crypto.randomUUID?crypto.randomUUID():Array.from(crypto.getRandomValues(new Uint8Array(16)),(x,i)=>(i===6?(x&15)|64:i===8?(x&63)|128:x).toString(16).padStart(2,'0')).join('').replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/,'$1-$2-$3-$4-$5');
  const language=(navigator.languages||[navigator.language||'en']).map(x=>x.toLowerCase()).find(x=>x.startsWith('zh') || ['en','es','de','fr','it','ja','ko'].includes(x.split('-')[0]))||'en';
  const key=/^zh-(tw|hk|mo|hant)/.test(language)?'zh-Hant':language.split('-')[0], locale=window.ToupingI18n?.languages.indexOf(key)??-1;
  const t=text=>window.ToupingI18n?.strings[text]?.[locale]||text;
  const controlText=(node,text)=>{(node.querySelector?.('.control-label')||node).textContent=t(text);};
  const participant=random(), fallback='访客-'+participant.slice(0,4);
  let active=null, microphone=null, context=null, analyser=null, meter=null, testing=false, generation=0, micAction=0;
  el('nickname').value=read('touping-nickname','');
  el('nickname').oninput=()=>{store('touping-nickname',el('nickname').value); hello(active);};
  const name=()=>el('nickname').value.replace(/[\p{Cc}]/gu,'').trim().slice(0,32)||fallback;
  el('nickname').placeholder='你的名字（选填）';
  function syncMicrophoneButton() {
    const requested=el('voice-toggle').checked;
    const sending=requested && microphone?.getAudioTracks().some(track=>track.enabled && track.readyState!=='ended' && active?.pc.getSenders().some(sender=>sender.track===track));
    const button=el('voice-button'), label=sending?'话筒已开启':requested?'话筒待开启':'话筒已关闭';
    controlText(button,label);button.setAttribute('aria-label',label);
    button.setAttribute('title',requested && !sending?'点击取消开启话筒（等待连接或授权）':sending?'点击关闭话筒':'点击开启话筒');
    button.setAttribute('aria-pressed',String(Boolean(sending)));button.setAttribute('data-active',String(Boolean(sending)));
    controlText(el('voice-test-button'),testing?'停止测试':'测试话筒');
    el('voice-test-button').setAttribute('aria-pressed',String(testing));el('voice-test-button').setAttribute('data-active',String(testing));
  }
  const notes=text=>{el('voice-status').textContent=text;syncMicrophoneButton();};
  function send(s,packet) {
    if(!s || s.closed || !s.chat || s.chat.readyState!=='open' || s.chat.bufferedAmount>32768) return false;
    const raw=JSON.stringify(packet); if(new TextEncoder().encode(raw).length>4096) return false;
    s.chat.send(raw); return true;
  }
  function hello(s) {send(s,{kind:'hello',participant,nickname:name()});}
  function showMessage(s,packet) {
    if(typeof packet.id!=='string' || !/^[a-f0-9-]{36}$/i.test(packet.id) || typeof packet.text!=='string' || !packet.text.trim() || Array.from(packet.text).length>500 || new TextEncoder().encode(packet.text).length>2000 || s.seen.has(packet.id)) return;
    const now=performance.now(); s.arrivals=s.arrivals.filter(x=>now-x<10000); if(s.arrivals.length>=160)return; s.arrivals.push(now);
    s.seen.add(packet.id);
    const row=document.createElement('div'), author=document.createElement('strong'), text=document.createElement('div');
    author.textContent=String(packet.author||'用户').replace(/[\p{Cc}]/gu,'').slice(0,32); text.textContent=packet.text;
    row.append(author,text); el('chat-messages').append(row); s.ids.push(packet.id);
    if(s.ids.length>200) {s.seen.delete(s.ids.shift());el('chat-messages').firstChild?.remove();}
    el('chat-messages').scrollTop=el('chat-messages').scrollHeight;
  }
  async function devices() {
    if(!navigator.mediaDevices?.enumerateDevices) {notes('当前浏览器或地址不支持话筒设备选择；局域网HTTP通常需改用App或HTTPS。'); return;}
    try {
      const list=await navigator.mediaDevices.enumerateDevices();
      for(const [id,kind] of [['voice-input','audioinput'],['voice-output','audiooutput']]) {
        const select=el(id), old=select.value; select.replaceChildren(new Option('系统默认',''));
        list.filter(x=>x.kind===kind).forEach((x,i)=>select.add(new Option(x.label||'设备 '+(i+1),x.deviceId)));
        if(Array.from(select.options).some(x=>x.value===old)) select.value=old;
      }
      if(!('setSinkId' in HTMLMediaElement.prototype)) notes('此浏览器由系统选择喇叭，无法在网页指定输出设备。');
    }catch(_){notes('无法读取声音设备，请检查浏览器权限。');}
  }
  async function startCapture() {
    const currentGeneration=++generation;
    if(!navigator.mediaDevices?.getUserMedia) throw Error('话筒需要浏览器权限和安全地址；请使用HTTPS或原生App。');
    const id=el('voice-input').value;
    const stream=await navigator.mediaDevices.getUserMedia({audio:{deviceId:id?{exact:id}:undefined,echoCancellation:true,noiseSuppression:true,autoGainControl:true},video:false});
    if(currentGeneration!==generation) {stream.getTracks().forEach(x=>x.stop());throw Error('话筒操作已取消');}
    if(microphone) microphone.getTracks().forEach(x=>x.stop()); microphone=stream;
    if(context) await context.close().catch(()=>{});
    context=new (window.AudioContext||window.webkitAudioContext)(); analyser=context.createAnalyser(); analyser.fftSize=256;
    context.createMediaStreamSource(stream).connect(analyser); await context.resume();
    if(meter)clearInterval(meter);
    meter=setInterval(()=>{const bytes=new Uint8Array(analyser.fftSize);analyser.getByteTimeDomainData(bytes);const peak=Math.max(...Array.from(bytes,x=>Math.abs(x-128)/128));el('mic-fill').style.height=Math.round(peak*100)+'%';},100);
    await devices(); return stream;
  }
  async function replaceMic() {
    const session=active;
    if(!session || session.closed || !session.connected || !session.roomReady) {notes('已选择发送，连接就绪后会请求话筒授权。');return;}
    const stream=await startCapture(), track=stream.getAudioTracks()[0];
    if(active!==session || session.closed || stream!==microphone) {track.stop();return;}
    const transceiver=session.pc.getTransceivers().find(x=>x.receiver.track.kind==='audio');
    if(!el('voice-toggle').checked) {track.stop();throw Error('话筒操作已取消');}
    if(!transceiver) {track.stop();throw Error('当前连接没有双向音频，请更新投送端。');}
    await transceiver.sender.replaceTrack(track);
    if(!el('voice-toggle').checked || active!==session || session.closed || stream!==microphone) {track.enabled=false;track.stop();return;}
    notes('话筒已开启，主控及其他接收者都能听见。');
  }
  function stopCapture() {
    generation++;
    microphone?.getTracks().forEach(x=>x.stop()); microphone=null;
    if(meter)clearInterval(meter);meter=null; if(context)context.close().catch(()=>{});context=null;analyser=null;
    el('mic-fill').style.height='0%';
  }
  // Stop tracks synchronously, including local testing and pending permission requests.
  function muteMicrophone() {
    micAction++;
    testing=false;el('voice-test').checked=false;el('voice-toggle').checked=false;
    stopCapture();
    for(const sender of active?.pc.getSenders()||[]) {
      if(sender.track?.kind==='audio') {sender.track.enabled=false;sender.replaceTrack(null).catch(()=>{});}
    }
    notes('话筒已关闭。');
  }
  el('voice-button').onclick=()=>{
    if(el('voice-toggle').checked) {muteMicrophone();return;}
    el('voice-toggle').checked=true;syncMicrophoneButton();
    return el('voice-toggle').onchange();
  };
  el('voice-toggle').onchange=async()=>{
    const action=++micAction;syncMicrophoneButton();
    try {
      if(el('voice-toggle').checked) await replaceMic();
      else {const sender=active?.pc.getSenders().find(x=>x.track?.kind==='audio'); if(sender)await sender.replaceTrack(null);if(!testing)stopCapture();notes('话筒已关闭。');}
    }catch(error){if(action===micAction){el('voice-toggle').checked=false;stopCapture();notes(error.message);}}
  };
  syncMicrophoneButton();
  el('voice-test').onchange=async()=>{
    testing=el('voice-test').checked;syncMicrophoneButton();
    try{if(testing && !microphone) await startCapture();else if(!testing && !el('voice-toggle').checked)stopCapture();}
    catch(error){testing=false;el('voice-test').checked=false;notes(error.message);}
  };
  el('voice-test-button').onclick=()=>{el('voice-test').checked=!el('voice-test').checked;return el('voice-test').onchange();};
  el('voice-input').onchange=async()=>{try{if(el('voice-toggle').checked)await replaceMic();else if(testing)await startCapture();}catch(error){el('voice-toggle').checked=false;stopCapture();notes(error.message);}};
  el('voice-input').onfocus=devices;
  el('voice-output').onchange=async()=>{try{if(!el('video').setSinkId)throw Error('请在系统声音设置选择喇叭。');await el('video').setSinkId(el('voice-output').value);}catch(error){notes(error.message);}};
  el('speaker-test').onclick=async()=>{
    // Short, local test tone; nothing is transmitted to other participants.
    try {
      const rate=48000, length=12000, bytes=new ArrayBuffer(44+length*2), view=new DataView(bytes);
      const text=(offset,value)=>Array.from(value).forEach((x,i)=>view.setUint8(offset+i,x.charCodeAt(0)));
      text(0,'RIFF');view.setUint32(4,36+length*2,true);text(8,'WAVE');text(12,'fmt ');view.setUint32(16,16,true);view.setUint16(20,1,true);view.setUint16(22,1,true);view.setUint32(24,rate,true);view.setUint32(28,rate*2,true);view.setUint16(32,2,true);view.setUint16(34,16,true);text(36,'data');view.setUint32(40,length*2,true);
      for(let i=0;i<length;i++)view.setInt16(44+i*2,Math.sin(i*2*Math.PI*440/rate)*2600*Math.min(1,i/480,(length-i)/480),true);
      const url=URL.createObjectURL(new Blob([bytes],{type:'audio/wav'})), player=new Audio(url);
      if(player.setSinkId)await player.setSinkId(el('voice-output').value);await player.play();el('speaker-fill').style.height='50%';
      setTimeout(()=>{player.pause();URL.revokeObjectURL(url);el('speaker-fill').style.height='0%';},400);
    }catch(_){notes('喇叭测试失败，请检查浏览器播放权限或系统输出设备。');}
  };
  el('chat-draft').placeholder=t('输入文字，所有人可见');
  el('chat-form').onsubmit=event=>{
    event.preventDefault();const text=el('chat-draft').value.trim(), now=performance.now();
    if(!active || !active.roomReady || !text || Array.from(text).length>500 || new TextEncoder().encode(text).length>2000) {el('chat-error').textContent='请先连接，消息最多500字。';return;}
    active.sent=active.sent.filter(x=>now-x<10000);if(active.sent.length>=8){el('chat-error').textContent='发送过于频繁，请稍后重试。';return;}
    if(send(active,{kind:'chat',id:random(),text})){active.sent.push(now);el('chat-draft').value='';el('chat-error').textContent='';}else el('chat-error').textContent='聊天室尚未连接，或发送队列已满。';
  };
  function ready(s) {
    if(active!==s || s.closed || !s.connected || !s.roomReady || s.micStarting || !el('voice-toggle').checked) return;
    if(microphone?.getAudioTracks().some(track=>s.pc.getSenders().some(sender=>sender.track===track))) return;
    s.micStarting=true;const action=micAction;
    replaceMic().catch(error=>{if(active===s && action===micAction){el('voice-toggle').checked=false;stopCapture();notes(error.message);}}).finally(()=>{s.micStarting=false;});
  }
  globalThis.ToupingRoom={
    ready,
    attach(s) {
      active=s;s.roomReady=false;s.seen=new Set();s.ids=[];s.arrivals=[];s.sent=[];el('chat-messages').replaceChildren();
      try{s.outputContext=new (window.AudioContext||window.webkitAudioContext)();s.outputAnalyser=s.outputContext.createAnalyser();s.outputAnalyser.fftSize=256;s.outputContext.resume().catch(()=>{});}catch(_){}
      s.chat=s.pc.createDataChannel('touping-room-text-v1',{negotiated:true,id:1,ordered:true});s.chat.onopen=()=>hello(s);
      s.chat.onmessage=event=>{if(active!==s || s.closed || typeof event.data!=='string' || new TextEncoder().encode(event.data).length>4096)return;try{const packet=JSON.parse(event.data);if((packet.kind==='hello'||packet.kind==='host') && typeof packet.participant==='string' && /^[a-f0-9-]{36}$/i.test(packet.participant)){s.roomReady=true;ready(s);return;}if(packet.kind==='chat')showMessage(s,packet);else if(packet.kind==='notice' && typeof packet.text==='string' && packet.text.length<=500)el('chat-error').textContent=packet.text;}catch(_){}};
    },
    track(s,stream){
      if(!s.outputContext || !s.outputAnalyser || stream.getAudioTracks().length===0)return;
      s.outputSource?.disconnect();s.outputSource=s.outputContext.createMediaStreamSource(stream);s.outputSource.connect(s.outputAnalyser);
      if(s.outputMeter)clearInterval(s.outputMeter);
      s.outputMeter=setInterval(()=>{const data=new Uint8Array(s.outputAnalyser.fftSize);s.outputAnalyser.getByteTimeDomainData(data);el('speaker-fill').style.height=(el('video').muted||el('video').paused?0:Math.round(Math.max(...Array.from(data,x=>Math.abs(x-128)/128))*100*el('video').volume))+'%';},100);
    },
    prepare(s){for(const transceiver of s.pc.getTransceivers())if(transceiver.receiver.track.kind==='audio')transceiver.direction='sendrecv';},
    stop(s){if(active!==s)return;active=null;stopCapture();if(s.outputMeter)clearInterval(s.outputMeter);s.outputContext?.close().catch(()=>{});testing=false;el('voice-test').checked=false;s.chat?.close();el('chat-messages').replaceChildren();notes('已断开，话筒已停止采集。');}
  };
  navigator.mediaDevices?.addEventListener?.('devicechange',devices);devices();
})();

'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const local = location.protocol === 'http:';
  const initial = new URLSearchParams(location.hash.slice(1)).get('code');
  if (/^\d{8}$/.test(initial || '')) $('code').value = initial;
  // Codes stay in the fragment, never in HTTP requests, referrers or page titles.
  $('route').textContent = local ? '局域网接收 · 输入发送端匹配码即可观看，无需外网。' : '公网接收 · 发送端须开启广域网匹配码，画面不经过服务器。';
  $('notice').textContent += local ? ' 仅在可信局域网使用此 HTTP 地址。' : ' 公网连接记录来源 IP、浏览器类型及随机应用标识；网络无法直连时会失败，不使用视频中继。';
  let current = null;
  function status(text) { $('status').textContent = text; }
  function tally(target, candidate) {
    if(target.seen.has(candidate) || target.seen.size >= 64) return;
    target.seen.add(candidate);
    const type=/ typ (host|srflx|prflx|relay)/.exec(candidate)?.[1];
    if(type) target[type]=(target[type] || 0)+1;
    const address=candidate.split(/\s+/)[4] || '';
    if(address.endsWith('.local')) target.mdns++; else if(address.includes(':')) target.v6++; else if(/^\d+\./.test(address)) target.v4++;
  }
  function diagnostics(s) {
    const describe=c=>`host=${c.host||0}, srflx=${c.srflx||0}, IPv4=${c.v4}, IPv6=${c.v6}, mDNS=${c.mdns}`;
    $('diagnostics').textContent=`网页版本：52\n阶段：${s.closed?'已结束':s.connected?'已直连':s.paired?'配对完成，直连检查':'等待配对'}\nICE：${s.pc.iceConnectionState} / 收集：${s.pc.iceGatheringState}\n本机候选：${describe(s.localCandidates)}\n对端候选：${describe(s.remoteCandidates)}\nSTUN错误次数：${s.stunErrors}，最近错误码：${s.stunCode||'无'}`;
  }
  function send(s, object) {
    if (current !== s || s.closed) return;
    if (++s.messages > 96 || (s.bytes += JSON.stringify(object).length) > 65536) throw Error('连接信息超过限制');
    if (local) {
      s.chain = s.chain.then(() => request('signal', {id:s.id, packet:object}, s)).catch(error => fail(s,error));
    } else if (s.ws && s.ws.readyState === WebSocket.OPEN) s.ws.send(JSON.stringify(object));
    else { if(s.pending.length >= 64) throw Error('等待信息过多'); s.pending.push(object); }
  }
  async function request(path, body, s) {
    const response = await fetch('./' + path, {method:'POST', headers:{'Content-Type':'application/json'},
      body:JSON.stringify(body), cache:'no-store', credentials:'omit', signal:s.abort.signal});
    const result = await response.json();
    if (!response.ok) throw Error(result.error || '连接请求失败');
    return result;
  }
  function stop(s, text) {
    if (!s || s.closed) return;
    s.closed = true; clearTimeout(s.timeout); clearTimeout(s.disconnected); clearTimeout(s.retry); clearInterval(s.clock);
    if (local && s.id) fetch('./leave', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({id:s.id}),keepalive:true}).catch(()=>{});
    s.abort.abort(); if(s.ws) s.ws.close(); s.pc.close(); diagnostics(s);
    if (current === s) { current = null; $('video').srcObject = null; $('start').disabled=false; $('stop').disabled=true; status(text || '已断开'); }
  }
  function fail(s, error) { if (current === s && !s.closed) { console.warn('接收连接失败：', error.message); stop(s, error.message || '连接失败，请重试'); } }
  async function receive(s, packet) {
    if (current !== s || s.closed) return;
    if ((s.received += JSON.stringify(packet).length) > 65536) throw Error('连接响应超过限制');
    if (packet.type === 'offer') {
      s.paired=true; status('配对成功，正在检查设备直连…');
      for(const candidate of packet.sdp.match(/^a=candidate:.*$/gm) || []) tally(s.remoteCandidates,candidate.slice(2));
      diagnostics(s);
      await s.pc.setRemoteDescription({type:'offer',sdp:packet.sdp});
      for(const ice of s.ice.splice(0)) await s.pc.addIceCandidate(ice);
      await s.pc.setLocalDescription(await s.pc.createAnswer());
      // Native endpoints require this session marker for their split stereo audio.
      const answer = packet.sdp.includes('a=x-touping-audio:split-v1')
        ? s.pc.localDescription.sdp.replace('\r\nm=', '\r\na=x-touping-audio:split-v1\r\nm=') : s.pc.localDescription.sdp;
      send(s,{type:'answer',sdp:answer});
    } else if (packet.type === 'candidate') {
      tally(s.remoteCandidates,packet.candidate); diagnostics(s);
      const ice = {candidate:packet.candidate,sdpMid:packet.mid,sdpMLineIndex:packet.line};
      if (s.pc.remoteDescription) await s.pc.addIceCandidate(ice); else s.ice.push(ice);
    } else if (packet.type === 'error') throw Error(packet.message || '未找到发送端');
  }
  function browserDevice() {
    let id;
    try { id=localStorage.getItem('touping-browser-id'); } catch(_) {}
    if(!/^[a-f0-9]{32}$/.test(id || '')) {
      id=Array.from(crypto.getRandomValues(new Uint8Array(16)), x=>x.toString(16).padStart(2,'0')).join('');
      try { localStorage.setItem('touping-browser-id',id); } catch(_) {}
    }
    return {installation_id:id,platform:'browser',model:'Browser',os_version:'0',app_version:'1.4',app_build:'52-web'};
  }
  async function publicJoin(s, code) {
    const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(code));
    const room=Array.from(new Uint8Array(digest),x=>x.toString(16).padStart(2,'0')).join('');
    const url=new URL('./signal',location.href); url.protocol='wss:';
    const ws=new WebSocket(url); s.ws=ws;
    ws.onopen=()=>{ if(current!==s) return ws.close(); ws.send(JSON.stringify({role:'receiver',room,device:browserDevice()})); };
    ws.onmessage=event=>{ s.chain=s.chain.then(()=>receive(s,JSON.parse(event.data))).catch(error=>fail(s,error)); };
    // The pairing server deliberately closes once both peers report connected.
    // Some browsers emit an error as that short-lived signaling socket closes.
    ws.onerror=()=>{if(!s.connected) fail(s,Error('无法连接配对服务，请检查网络'));};
    ws.onclose=()=>{ if(!s.closed && !s.connected) fail(s,Error(s.paired?'配对成功，但本次未建立视频直连；未使用中继，请查看连接诊断':'配对已结束，请确认发送端在线后重试')); };
  }
  async function localJoin(s, code) {
    const joined=await request('join',{code},s); s.id=joined.id;
    while(current===s && !s.closed && !s.connected) {
      const batch=await request('poll',{id:s.id},s);
      for(const packet of batch.events) await receive(s,packet);
      if(!s.connected) await new Promise(resolve=>{s.retry=setTimeout(resolve,300);});
    }
  }
  $('join').addEventListener('submit',async event=>{
    event.preventDefault(); if(current) stop(current);
    const code=$('code').value.trim(); if(!/^\d{8}$/.test(code)) return status('请输入八位数字匹配码');
    if(!window.RTCPeerConnection) return status('此浏览器不支持网页接收，请使用新版 Safari、Chrome 或 Edge');
    if(!local && !crypto.subtle) return status('请使用 HTTPS 地址及新版浏览器接收');
    let pc;
    try {pc=new RTCPeerConnection({iceServers:local?[]:[{urls:'stun:67.216.201.61:3478'},{urls:'stun:stun.cloudflare.com:3478'}]});}
    catch(_) {return status('浏览器无法建立直连，请检查网络权限或换用新版浏览器');}
    const counters=()=>({seen:new Set(),v4:0,v6:0,mdns:0});
    const s={pc,paired:false,localCandidates:counters(),remoteCandidates:counters(),stunErrors:0,
      abort:new AbortController(),chain:Promise.resolve(),pending:[],ice:[],messages:0,bytes:0,received:0,closed:false,connected:false};
    current=s; $('start').disabled=true; $('stop').disabled=false; status('正在连接发送端…');
    const stream=new MediaStream(); $('video').srcObject=stream;
    s.pc.createDataChannel('native-video-stats-v1',{negotiated:true,id:0,ordered:false,maxRetransmits:0});
    s.pc.ontrack=event=>{if(current!==s) return; stream.addTrack(event.track); $('video').play().catch(()=>{if(current===s && !s.closed) status('已收到媒体轨道，请点击播放器播放');});};
    s.pc.onicecandidate=event=>{if(event.candidate) try {tally(s.localCandidates,event.candidate.candidate); diagnostics(s); send(s,{type:'candidate',candidate:event.candidate.candidate,mid:event.candidate.sdpMid,line:event.candidate.sdpMLineIndex});} catch(error){fail(s,error);}};
    s.pc.onicecandidateerror=event=>{s.stunErrors++; s.stunCode=event.errorCode; if(current===s) diagnostics(s);};
    s.pc.onicegatheringstatechange=()=>{if(current===s) diagnostics(s);};
    s.pc.oniceconnectionstatechange=()=>{if(current===s) diagnostics(s);};
    s.pc.onconnectionstatechange=()=>{
      if(current!==s || s.closed) return;
      const state=s.pc.connectionState;
      if(state==='connected') {
        s.connected=true; clearTimeout(s.timeout); clearTimeout(s.disconnected); clearInterval(s.clock); diagnostics(s); status('已连接 · 设备直接传输');
        if(!local) { try {send(s,{type:'done'});} catch(error){fail(s,error);} }
      } else if(state==='failed') fail(s,Error('无法直连，请检查网络；此服务不提供视频中继'));
      else if(state==='disconnected') {status('连接中断，正在等待网络恢复…'); s.disconnected=setTimeout(()=>fail(s,Error('连接已中断，请重新接收')),8000);}
    };
    const deadline=Date.now()+25000;
    s.timeout=setTimeout(()=>fail(s,Error(s.paired?'配对成功，但25秒内未建立设备直连；未使用中继，请查看连接诊断':'配对超时，请确认地址、匹配码和网络')),25000);
    s.clock=setInterval(()=>{if(current===s && !s.closed && !s.connected) {status(`${s.paired?'配对成功，正在检查直连':'正在连接发送端'}（剩余${Math.max(0,Math.ceil((deadline-Date.now())/1000))}秒）`); diagnostics(s);}},1000);
    diagnostics(s);
    try { if(local) await localJoin(s,code); else await publicJoin(s,code); } catch(error){fail(s,error);}
  });
  $('stop').onclick=()=>stop(current);
  $('sound').onclick=()=>{const video=$('video'); video.muted=!video.muted; $('sound').textContent=video.muted?'开启声音':'关闭声音'; if(!video.muted) video.play().catch(()=>status('请点击播放器播放声音'));};
  $('fullscreen').onclick=()=>{const video=$('video'); if(video.requestFullscreen) video.requestFullscreen().catch(()=>{}); else if(video.webkitEnterFullscreen) video.webkitEnterFullscreen();};
  window.addEventListener('pagehide',()=>stop(current));
})();

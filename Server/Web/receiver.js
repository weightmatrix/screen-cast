'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const catalog=window.ToupingI18n;
  const language=(navigator.languages || [navigator.language]).map(x=>x.toLowerCase()).find(x=>x.startsWith('zh') || catalog.languages.includes(x.split('-')[0])) || 'en';
  const lang=/^zh-(tw|hk|mo|hant)/.test(language)?'zh-Hant':language.split('-')[0];
  const locale=catalog.languages.indexOf(lang);
  const t=text=>catalog.strings[text]?.[locale] || text;
  document.documentElement.lang=locale<0?'zh-Hans':catalog.languages[locale];
  document.querySelectorAll('[data-i18n]').forEach(el=>{el.textContent=t(el.dataset.i18n);});
  const controlText=(node,text)=>{(node.querySelector?.('.control-label')||node).textContent=t(text);};
  document.title='李知本·投屏自由 · '+t('接收工作台');
  const local = location.protocol === 'http:';
  const initial = (new URLSearchParams(location.hash.slice(1)).get('invite') || new URLSearchParams(location.hash.slice(1)).get('code'));
  // Per-origin, bounded local profiles. Never cookies or URL query parameters.
  const readPreference=(key,fallback)=>{try{return localStorage.getItem(key)??fallback;}catch(_){return fallback;}};
  const writePreference=(key,value)=>{try{localStorage.setItem(key,value);}catch(_){}};
  let profiles={},profileOrder=[];
  try {
    const saved=JSON.parse(readPreference('touping-receiver-profiles','{}'));
    if(saved && typeof saved==='object') {
      const entries=Array.isArray(saved)?saved.filter(x=>x && typeof x==='object').map(x=>[x.code,x]):Object.entries(saved);
      for(const [code,value] of entries.slice(-32))if(/^\d{6,36}$/.test(code) && value && typeof value==='object'){
        profiles[code]={password:typeof value.password==='string'?value.password.slice(0,256):'',application:typeof value.application==='string'?value.application.slice(0,200):''};
        profileOrder=profileOrder.filter(x=>x!==code);profileOrder.push(code);
      }
    }
  } catch(_) {}
  let profileCode='';
  const rememberProfile=()=>{
    if(!profileCode)return;
    delete profiles[profileCode];profileOrder=profileOrder.filter(code=>code!==profileCode);
    const password=$('password').value.slice(0,256),application=$('application').value.slice(0,200);
    if(password||application){profiles[profileCode]={password,application};profileOrder.push(profileCode);}
    while(profileOrder.length>32)delete profiles[profileOrder.shift()];
    writePreference('touping-receiver-profiles',JSON.stringify(profileOrder.map(code=>({code,...profiles[code]}))));
  };
  const restoreProfile=()=>{
    rememberProfile();
    const code=ToupingAuth.code($('code').value);profileCode=/^\d{6,36}$/.test(code)?code:'';
    $('password').value=profiles[profileCode]?.password||'';$('application').value=profiles[profileCode]?.application||'';
    if(profileCode)writePreference('touping-receiver-last-code',profileCode);
  };
  $('code').value=/^\d{6,36}$/.test(initial||'')?initial:readPreference('touping-receiver-last-code','');
  restoreProfile();
  $('code').addEventListener('input',restoreProfile);
  for(const id of ['password','application'])$(id).addEventListener('input',rememberProfile);
  // Codes stay in the fragment, never in HTTP requests, referrers or page titles.
  $('route').textContent = local ? '局域网接收 · 输入连接密码和申请文字，由投送者批准后接入。' : '公网邀请 · 输入连接密码和申请文字，由投送者批准后接入；画面不经过服务器。';
  $('notice').textContent += local ? ' 仅在可信局域网使用此 HTTP 地址。' : ' 公网连接记录来源 IP、浏览器类型及随机应用标识；网络无法直连时会失败，不使用视频中继。';
  let current = null;
  function status(text) { $('status').textContent = t(text); }
  function tally(target, candidate) {
    if(target.seen.has(candidate) || target.seen.size >= 64) return;
    target.seen.add(candidate);
    const type=/ typ (host|srflx|prflx|relay)/.exec(candidate)?.[1];
    if(type) target[type]=(target[type] || 0)+1;
    const address=candidate.split(/\s+/)[4] || '';
    if(address.endsWith('.local')) target.mdns++; else if(address.includes(':')) target.v6++; else if(/^\d+\./.test(address)) target.v4++;
  }
  function connectionPath(stats) {
    let transport;
    stats.forEach(item=>{if(item.type==='transport' && item.selectedCandidatePairId)transport=item;});
    const pair=transport && stats.get(transport.selectedCandidatePairId);
    if(!pair)return '当前媒体路径：等待实际路径统计';
    const local=stats.get(pair.localCandidateId)||{},remote=stats.get(pair.remoteCandidateId)||{};
    const address=c=>c.address||c.ip||'';
    const nonPublic=value=>{
      const text=String(value).toLowerCase().split('%')[0];
      if(text.endsWith('.local')||!text)return null;
      if(text.startsWith('::ffff:'))return nonPublic(text.slice(7));
      if(text.includes(':'))return /^(fc|fd|fe[89ab])/.test(text)||text==='::1'||text==='::'||text.startsWith('ff');
      const parts=text.split('.').map(Number);
      if(parts.length!==4||parts.some(x=>!Number.isInteger(x)||x<0||x>255))return null;
      const [a,b]=parts;return [0,10,127].includes(a)||(a===172&&b>=16&&b<=31)||(a===192&&b===168)||(a===169&&b===254)||(a===100&&b>=64&&b<=127)||a>=224;
    };
    let route='直连（地址隐藏，USB/局域网未确认）';
    if(local.candidateType==='relay'||remote.candidateType==='relay')route='中继路径';
    else if(/^127\./.test(address(remote))||address(remote)==='::1')route='本机回环直连';
    else if(local.networkType==='vpn')route='VPN/隧道直连（底层网络未知）';
    else if(nonPublic(address(local))===true&&nonPublic(address(remote))===true)route='内网地址直连（USB/局域网介质未确认）';
    else if(nonPublic(address(remote))===false)route='公网地址直连（可能同网回环）';
    else if([local.candidateType,remote.candidateType].some(x=>['srflx','prflx'].includes(x)))route='公网候选直连（范围待确认）';
    const network={wifi:'Wi-Fi',ethernet:'有线网络（USB未确认）',cellular:'蜂窝网络',vpn:'VPN/隧道'}[local.networkType]||'浏览器未公开（不能确认USB/Wi-Fi）';
    const protocol=String(local.protocol||remote.protocol||'未知').toUpperCase();
    const endpoint=c=>`${address(c)||'地址隐藏'}:${c.port??'—'}`;
    return `当前媒体路径：${route}\n本机接口：${network}\n传输协议：${protocol}\n实际媒体：${endpoint(local)} → ${endpoint(remote)}\n候选类型：${local.candidateType||'未知'} → ${remote.candidateType||'未知'}`;
  }
  function diagnostics(s) {
    const describe=c=>`host=${c.host||0}, srflx=${c.srflx||0}, IPv4=${c.v4}, IPv6=${c.v6}, mDNS=${c.mdns}`;
    $('diagnostics').textContent=`网页版本：92\n阶段：${s.closed?'已结束':s.connected?(s.picture?'已收到画面':'已直连，等待画面'):s.paired?'配对完成，直连检查':'等待配对'}\n${s.path||'当前媒体路径：等待实际路径统计'}\n优先顺序：USB可用网络 → 局域网 → 公网；以实际可达路径和链路质量为准\n最近采样传输：${s.flowing||'等待采样'}\nICE：${s.pc.iceConnectionState} / 收集：${s.pc.iceGatheringState}\n本机候选：${describe(s.localCandidates)}\n对端候选：${describe(s.remoteCandidates)}\nSTUN错误次数：${s.stunErrors}，最近错误码：${s.stunCode||'无'}\n${mediaDescription(s)}`;
  }
  function mediaDescription(s) {
    const video=$('video'), track=s.stream?.getVideoTracks()[0], media=s.media;
    const value=key=>Number.isFinite(media?.[key])?media[key]:'未知';
    return `视频轨道：${track?`${track.readyState} / ${track.muted?'等待数据':'有数据'}`:'未收到'}\n视频RTP：包=${value('packetsReceived')} / 字节=${value('bytesReceived')}\n视频帧：收到=${value('framesReceived')} / 解码=${value('framesDecoded')} / 关键帧=${value('keyFramesDecoded')} / 丢弃=${value('framesDropped')}\n编码：${s.codec||'未知'}\n播放器：${video.videoWidth||0}×${video.videoHeight||0} / ready=${video.readyState} / ${video.paused?'暂停':'播放中'} / 已呈现=${s.presented??'未知'}\n播放错误：${s.playError||'无'} / 媒体错误码：${video.error?.code||'无'}\n统计：${s.statsError?'暂不可用':media?'已读取':'等待读取'}`;
  }
  function pictureReady(s) {
    const video=$('video');
    return video.videoWidth>0 && video.videoHeight>0 && video.readyState>=2 && (s.presented>0 || video.currentTime>0);
  }
  function mediaStatus(s) {
    if(current!==s || s.closed || !s.connected) return;
    const video=$('video');
    if(pictureReady(s)) {
      if(!s.picture) {s.picture=true;status('已连接 · 已收到画面');}
    } else if(!s.picture && performance.now()-s.connectedAt>=12000) {
      if(s.playError) status('已直连，但播放器尚未播放；请点击“播放画面”');
      else if(!s.stream?.getVideoTracks().length) status('已直连，但没有收到视频轨道；请检查投送端是否仍在分享');
      else if(s.media && s.media.bytesReceived===0) status('已直连，但没有收到视频数据；请检查投送端是否仍在分享');
      else if(s.media && s.media.framesDecoded===0) status('已直连，视频尚未解码；请复制下方连接诊断');
      else if(video.paused) status('已直连，但播放器尚未播放；请点击“播放画面”');
      else status('已直连，仍未显示画面；请复制下方连接诊断');
    }
    diagnostics(s);
  }
  function playVideo(s, manual=false) {
    if(current!==s || s.closed || (!manual && s.picture)) return;
    const video=$('video');
    try {
      Promise.resolve(video.play()).then(()=>{if(current!==s || s.closed)return;s.playError='';mediaStatus(s);},error=>{
        if(current!==s || s.closed)return;
        s.playError=['NotAllowedError','NotSupportedError','AbortError'].includes(error.name)?error.name:'播放失败';
        status('已收到媒体轨道，请点击“播放画面”');diagnostics(s);
      });
    } catch(_) {s.playError='播放失败';diagnostics(s);}
  }
  async function sampleMedia(s) {
    if(current!==s || s.closed || !s.connected || s.statsBusy) return;
    s.statsBusy=true;
    try {
      const stats=await s.pc.getStats();
      if(current!==s || s.closed)return;
      let inbound;
      stats.forEach(item=>{if(item.type==='inbound-rtp' && (item.kind||item.mediaType)==='video' && !item.isRemote)inbound=item;});
      s.path=connectionPath(stats);
      const counters=new Map(),flowing=[];
      stats.forEach(item=>{
        if(!['inbound-rtp','outbound-rtp'].includes(item.type)||!['video','audio'].includes(item.kind||item.mediaType))return;
        const outbound=item.type==='outbound-rtp',count=item[outbound?'bytesSent':'bytesReceived']||0;
        counters.set(item.id,count);
        if(count<=(s.mediaCounters?.get(item.id)||0))return;
        const codec=stats.get(item.codecId)?.mimeType||item.kind||item.mediaType;
        const label=(outbound?'发送':'接收')+((item.kind||item.mediaType)==='video'?'画面':'声音')+`（${codec}）`;
        if(!flowing.includes(label))flowing.push(label);
      });
      stats.forEach(item=>{
        if(item.type!=='data-channel'||!['touping-room-text-v1','native-video-stats-v1'].includes(item.label))return;
        for(const [key,direction] of [['bytesSent','发送'],['bytesReceived','接收']]) {
          const id=item.id+key,count=item[key]||0;counters.set(id,count);
          const label=direction+(item.label==='touping-room-text-v1'?'文字/控制':'诊断数据');
          if(count>(s.mediaCounters?.get(id)||0)&&!flowing.includes(label))flowing.push(label);
        }
      });
      s.mediaCounters=counters;s.flowing=flowing.length?flowing.sort().join('、'):'本次采样无新增可统计数据';
      s.media=inbound;s.statsError=false;
      const codec=inbound && stats.get(inbound.codecId);
      s.codec=codec && /^video\/(H264|VP8|VP9|AV1)$/i.test(codec.mimeType)?codec.mimeType:'';
      const quality=$('video').getVideoPlaybackQuality?.();
      if(Number.isFinite(quality?.totalVideoFrames))s.presented=quality.totalVideoFrames;
      mediaStatus(s);
    } catch(_) {if(current===s && !s.closed){s.statsError=true;mediaStatus(s);}}
    finally {s.statsBusy=false;}
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
    if(s.connected) report(s, 'ended');
    window.ToupingRoom?.stop(s);
    s.closed = true; clearTimeout(s.timeout); clearTimeout(s.disconnected); clearTimeout(s.retry); clearInterval(s.clock); clearInterval(s.mediaClock);
    if (local && s.id) fetch('./leave', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({id:s.id}),keepalive:true}).catch(()=>{});
    s.abort.abort(); if(s.ws) s.ws.close(); s.pc.close(); diagnostics(s);
    if (current === s) { current = null; $('video').srcObject = null; $('start').disabled=false; $('stop').disabled=true; $('play').disabled=true; status(text || '已断开'); }
  }
  function fail(s, error) { if (current === s && !s.closed) { console.warn('接收连接失败：', error.message); stop(s, error.message || '连接失败，请重试'); } }
  async function receive(s, packet) {
    if (current !== s || s.closed) return;
    if ((s.received += JSON.stringify(packet).length) > 65536) throw Error('连接响应超过限制');
    if(packet.type === 'challenge') {
      if(!/^[a-f0-9]{32}$/.test(packet.nonce || '')) throw Error('无效连接验证');
      send(s,{type:'apply',proof:ToupingAuth.proof(s.verifier,packet.nonce),application:s.application,nickname:window.ToupingRoom?.nickname?.()||$('nickname').value.trim().slice(0,32)||'访客'});
    } else if(packet.type === 'waiting_approval') {
      status('接入申请已提交，等待投送者接受…');
      s.awaitingApproval = true;
    } else if(packet.type === 'approved') {
      s.awaitingApproval = false;
      s.auditSession = packet.session_id;
      report(s, 'attempt');
      clearTimeout(s.timeout);
      s.timeout=setTimeout(()=>fail(s,Error('获准接入后未能建立设备直连')),35000);
    } else if (packet.type === 'offer') {
      s.paired=true; s.awaitingApproval=false; clearTimeout(s.timeout); s.deadline=Date.now()+35000; s.timeout=setTimeout(()=>fail(s,Error('获准接入后未能建立设备直连')),35000); status('配对成功，正在检查设备直连…');
      for(const candidate of packet.sdp.match(/^a=candidate:.*$/gm) || []) tally(s.remoteCandidates,candidate.slice(2));
      diagnostics(s);
      await s.pc.setRemoteDescription({type:'offer',sdp:packet.sdp});
      window.ToupingRoom?.prepare(s);
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
    return {installation_id:id,platform:'browser',model:'Browser',os_version:'0',app_version:'1.4',app_build:'92-web'};
  }
  function report(s, event) {
    if(local || !/^[a-f0-9]{32}$/.test(s.auditSession || '')) return;
    const packet={role:'audit',route:'internet_code',session_id:s.auditSession,peer_role:'receiver',event,device:browserDevice()};
    if(event==='ended' && s.connectedAt!=null) packet.duration_ms=Math.floor(performance.now()-s.connectedAt);
    const url=new URL('./audit',location.href); url.protocol='wss:';
    const ws=new WebSocket(url);
    const timeout=setTimeout(()=>ws.close(),8000);
    ws.onopen=()=>ws.send(JSON.stringify(packet));
    ws.onmessage=()=>{clearTimeout(timeout); ws.close();};
    ws.onerror=()=>{clearTimeout(timeout); ws.close();};
  }
  async function publicJoin(s, code) {
    const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(code));
    const room=Array.from(new Uint8Array(digest),x=>x.toString(16).padStart(2,'0')).join('');
    const url=new URL('./signal',location.href); url.protocol='wss:';
    const ws=new WebSocket(url); s.ws=ws;
    ws.onopen=()=>{ if(current!==s) return ws.close(); ws.send(JSON.stringify({role:'receiver',room,device:browserDevice(),protocol:2})); };
    ws.onmessage=event=>{ s.chain=s.chain.then(()=>receive(s,JSON.parse(event.data))).catch(error=>fail(s,error)); };
    // The pairing server deliberately closes once both peers report connected.
    // Some browsers emit an error as that short-lived signaling socket closes.
    ws.onerror=()=>{if(!s.connected) fail(s,Error('无法连接配对服务，请检查网络'));};
    ws.onclose=()=>{ if(!s.closed && !s.connected) fail(s,Error(s.paired?'配对成功，但本次未建立视频直连；未使用中继，请查看连接诊断':'配对已结束，请确认发送端在线后重试')); };
  }
  async function localJoin(s, code) {
    const challenge=await fetch('./challenge',{cache:'no-store',signal:s.abort.signal}).then(response=>response.json());
    const joined=await request('join',{code,challenge:challenge.id,proof:ToupingAuth.proof(s.verifier,challenge.nonce),application:s.application,nickname:window.ToupingRoom?.nickname?.()||$('nickname').value.trim().slice(0,32)||'访客'},s); s.id=joined.id;
    s.awaitingApproval=true; status('接入申请已提交，等待投送者接受…');
    while(current===s && !s.closed && !s.connected) {
      const batch=await request('poll',{id:s.id},s);
      for(const packet of batch.events) await receive(s,packet);
      if(!s.connected) await new Promise(resolve=>{s.retry=setTimeout(resolve,300);});
    }
  }
  $('join').addEventListener('submit',async event=>{
    event.preventDefault(); if(current) stop(current);
    const code=ToupingAuth.code($('code').value); if(!/^\d{6,36}$/.test(code)) return status('请输入6至36位数字匹配码');
    if(ToupingAuth.code($('code').value)!==profileCode)restoreProfile();
    rememberProfile();
    const password=$('password').value.normalize('NFC'), application=$('application').value.trim();
    if(Array.from(password).length<6 || Array.from(password).length>64 || /[\p{Cc}]/u.test(password)) return status('请填写6至64位连接密码');
    if(!application || Array.from(application).length>200 || new TextEncoder().encode(application).length>800) return status('请填写1至200字申请文字');
    if(!window.RTCPeerConnection) return status('此浏览器不支持网页接收，请使用新版 Safari、Chrome 或 Edge');
    if(!local && !crypto.subtle) return status('请使用 HTTPS 地址及新版浏览器接收');
    let pc;
    try {pc=new RTCPeerConnection({iceServers:local?[]:[{urls:'stun:67.216.201.61:3478'},{urls:'stun:stun.cloudflare.com:3478'}]});}
    catch(_) {return status('浏览器无法建立直连，请检查网络权限或换用新版浏览器');}
    const counters=()=>({seen:new Set(),v4:0,v6:0,mdns:0});
    const s={pc,verifier:ToupingAuth.verifier(password,code),application,paired:false,localCandidates:counters(),remoteCandidates:counters(),stunErrors:0,
      abort:new AbortController(),chain:Promise.resolve(),pending:[],ice:[],messages:0,bytes:0,received:0,closed:false,connected:false};
    window.ToupingRoom?.attach(s);
    current=s; $('start').disabled=true; $('stop').disabled=false; status('正在连接发送端…');
    const stream=new MediaStream(); s.stream=stream;
    s.pc.createDataChannel('native-video-stats-v1',{negotiated:true,id:0,ordered:false,maxRetransmits:0});
    s.pc.ontrack=event=>{
      if(current!==s || s.closed) return;
      if(!stream.getTracks().includes(event.track))stream.addTrack(event.track);
      // Attach a populated stream: Safari may not activate an initially empty stream.
      $('video').srcObject=new MediaStream(stream.getTracks());
      $('play').disabled=false;
      // Optional audio metering must never prevent video playback.
      try {window.ToupingRoom?.track(s,stream);} catch(_) {s.meterError=true;}
      event.track.addEventListener('unmute',()=>{playVideo(s);diagnostics(s);},{signal:s.abort.signal});
      event.track.addEventListener('ended',()=>diagnostics(s),{signal:s.abort.signal});
      playVideo(s);diagnostics(s);
    };
    for(const name of ['loadeddata','playing','resize','pause','waiting','error']) {
      $('video').addEventListener(name,()=>{if(current===s && !s.closed)mediaStatus(s);},{signal:s.abort.signal});
    }
    s.mediaClock=setInterval(()=>sampleMedia(s),2000);
    s.pc.onicecandidate=event=>{if(event.candidate) try {tally(s.localCandidates,event.candidate.candidate); diagnostics(s); send(s,{type:'candidate',candidate:event.candidate.candidate,mid:event.candidate.sdpMid,line:event.candidate.sdpMLineIndex});} catch(error){fail(s,error);}};
    s.pc.onicecandidateerror=event=>{s.stunErrors++; s.stunCode=event.errorCode; if(current===s) diagnostics(s);};
    s.pc.onicegatheringstatechange=()=>{if(current===s) diagnostics(s);};
    s.pc.oniceconnectionstatechange=()=>{if(current===s) diagnostics(s);};
    s.pc.onconnectionstatechange=()=>{
      if(current!==s || s.closed) return;
      const state=s.pc.connectionState;
      if(state==='connected') {
        s.connected=true; s.connectedAt=performance.now(); report(s, 'connected'); clearTimeout(s.timeout); clearTimeout(s.disconnected); clearInterval(s.clock); diagnostics(s); status('已直连，等待首帧画面…'); sampleMedia(s); window.ToupingRoom?.ready(s);
        if(!local) { try {send(s,{type:'done'});} catch(error){fail(s,error);} }
      } else if(state==='failed') fail(s,Error('无法直连，请检查网络；此服务不提供视频中继'));
      else if(state==='disconnected') {status('连接中断，正在等待网络恢复…'); s.disconnected=setTimeout(()=>fail(s,Error('连接已中断，请重新接收')),8000);}
    };
    s.deadline=Date.now()+340000;
    s.timeout=setTimeout(()=>fail(s,Error(s.paired?'获准接入后未能建立设备直连，请查看连接诊断':'连接或申请超时，请确认邀请链接、密码及投送者状态')),340000);
    s.clock=setInterval(()=>{if(current===s && !s.closed && !s.connected) {status(`${s.awaitingApproval?'等待投送者接受接入申请':s.paired?'配对成功，正在检查直连':'正在连接发送端'}（剩余${Math.max(0,Math.ceil((s.deadline-Date.now())/1000))}秒）`); diagnostics(s);}},1000);
    diagnostics(s);
    try { if(local) await localJoin(s,code); else await publicJoin(s,code); } catch(error){fail(s,error);}
  });
  $('stop').onclick=()=>stop(current);
  $('play').onclick=()=>{if(current)playVideo(current,true);};
  const syncSound=()=>{
    const video=$('video'), muted=video.muted || video.volume===0;
    for(const id of ['speaker-sound']) {controlText($(id),muted?'声音已关闭':'声音已开启');$(id).setAttribute('title',muted?t('开启声音'):t('关闭声音'));$(id).setAttribute('aria-pressed',String(!muted));$(id).setAttribute('data-active',String(!muted));}
  };
  const toggleSound=()=>{
    const video=$('video');
    if(video.muted || video.volume===0) {video.muted=false;if(video.volume===0)video.volume=1;} else video.muted=true;
    syncSound();if(!video.muted && video.srcObject)video.play().catch(()=>status('请点击“播放画面”开启声音'));
  };
  $('video').muted=readPreference('touping-speaker-muted','false')==='true';
  const rememberedVolume=Number(readPreference('touping-speaker-volume','1'));
  $('video').volume=Number.isFinite(rememberedVolume)?Math.max(0,Math.min(1,rememberedVolume)):1;
  $('video').addEventListener('volumechange',()=>{syncSound();writePreference('touping-speaker-muted',String($('video').muted));writePreference('touping-speaker-volume',String($('video').volume));});
  $('speaker-sound').onclick=toggleSound;syncSound();
  // Use the media element's native fullscreen player; no persistent page overlay.
  const maximize=async()=>{
    const video=$('video');
    try {
      if(document.fullscreenElement) {await document.exitFullscreen();return;}
      if(video.webkitDisplayingFullscreen) {video.webkitExitFullscreen();return;}
      if(video.requestFullscreen) {
        try {await video.requestFullscreen();return;}
        catch(error) {if(!video.webkitEnterFullscreen && !video.webkitRequestFullscreen)throw error;}
      }
      if(video.webkitEnterFullscreen) {video.webkitEnterFullscreen();return;}
      if(video.webkitRequestFullscreen) {video.webkitRequestFullscreen();return;}
      status('请使用视频系统控制栏的全屏按钮；当前浏览器未开放网页全屏。');
    } catch(_) {status('请使用视频系统控制栏的全屏按钮；画面就绪后再试。');}
  };
  $('fullscreen').onclick=maximize;
  window.addEventListener('pagehide',()=>stop(current));
})();

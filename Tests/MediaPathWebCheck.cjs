'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync('Server/Web/receiver.js','utf8');
const code=source.slice(source.indexOf('  function connectionPath(stats, s)'),source.indexOf('  let lastReport'));
const sandbox={};vm.runInNewContext(code,sandbox);
function path(local,remote){return sandbox.connectionPath(new Map([
 ['transport',{type:'transport',selectedCandidatePairId:'chosen'}],
 ['unused',{type:'candidate-pair',state:'succeeded',localCandidateId:'fake',remoteCandidateId:'fake'}],
 ['chosen',{localCandidateId:'local',remoteCandidateId:'remote'}],['local',local],['remote',remote]
]), {});}
assert.match(path({address:'192.168.1.2',candidateType:'host',networkType:'ethernet'},{address:'192.168.1.3',candidateType:'host'}),/内网地址直连/);
assert.match(path({candidateType:'host'},{address:'peer.local',candidateType:'host'}),/未确认/);
assert.match(path({networkType:'ethernet'},{address:'8.8.8.8',candidateType:'srflx'}),/公网地址/);
assert.match(path({address:'192.168.1.2'},{address:'192.168.1.3',candidateType:'relay'}),/服务器中转/);
assert.match(path({networkType:'vpn'},{address:'192.168.1.3'}),/VPN/);
assert.match(path({networkType:'ethernet'},{address:'peer.local'}),/USB未确认/);
assert.match(sandbox.connectionPath(new Map()),/等待实际路径统计/);
console.log('PASS browser selected-pair evidence, private/public/relay/VPN paths, hidden addresses and USB uncertainty');
const reportSandbox = {
  local: true, document: {visibilityState:'visible', addEventListener(){}},
  performance: {now:()=>1000}, $: ()=>({}), mediaDescription:()=>'', describe:()=>''
};
const reportSource=source.slice(source.indexOf('  let lastReport'),source.indexOf("  $('copy-diagnostics')?."));
vm.runInNewContext(reportSource,reportSandbox);
const session={pc:{iceConnectionState:'disconnected',iceGatheringState:'complete'},closed:true,
  safeEnd:'网络中断', stunErrors:0, localCandidates:{}, remoteCandidates:{},
  path:'169.254.1.25 → private-host.local', id:'secret-session-id',
  safePath:{route:'内网直连',network:'有线',protocol:'UDP',candidates:'host → host',linkLocal:true,rtt:2},
  media:{framesDecoded:180,packetsLost:7}};
reportSandbox.diagnostics(session);
const report=vm.runInNewContext('lastReport',reportSandbox);
assert.match(report,/ICE disconnected/);
assert.match(report,/framesDecoded 180/);
assert.match(report,/packetsLost 7/);
assert.doesNotMatch(report,/169\.254|private-host|secret-session-id/);
console.log('PASS copied report retains disconnect stats without raw path or session ID');

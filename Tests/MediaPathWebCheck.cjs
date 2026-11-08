'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync('Server/Web/receiver.js','utf8');
const code=source.slice(source.indexOf('  function connectionPath(stats)'),source.indexOf('  function diagnostics(s)'));
const sandbox={};vm.runInNewContext(code,sandbox);
function path(local,remote){return sandbox.connectionPath(new Map([
 ['transport',{type:'transport',selectedCandidatePairId:'chosen'}],
 ['unused',{type:'candidate-pair',state:'succeeded',localCandidateId:'fake',remoteCandidateId:'fake'}],
 ['chosen',{localCandidateId:'local',remoteCandidateId:'remote'}],['local',local],['remote',remote]
]));}
assert.match(path({address:'192.168.1.2',candidateType:'host',networkType:'ethernet'},{address:'192.168.1.3',candidateType:'host'}),/内网地址直连/);
assert.match(path({candidateType:'host'},{address:'peer.local',candidateType:'host'}),/未确认/);
assert.match(path({networkType:'ethernet'},{address:'8.8.8.8',candidateType:'srflx'}),/公网地址/);
assert.match(path({address:'192.168.1.2'},{address:'192.168.1.3',candidateType:'relay'}),/中继路径/);
assert.match(path({networkType:'vpn'},{address:'192.168.1.3'}),/VPN/);
assert.match(path({networkType:'ethernet'},{address:'peer.local'}),/USB未确认/);
assert.match(sandbox.connectionPath(new Map()),/等待实际路径统计/);
console.log('PASS browser selected-pair evidence, private/public/relay/VPN paths, hidden addresses and USB uncertainty');

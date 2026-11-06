'use strict';
// Run against Tests/WebReceiverHarness.swift; synthetic media, never a user's screen.
// TOUPING_PLAYWRIGHT_MODULE and TOUPING_BROWSER_EXECUTABLE select local test tooling.
const {chromium}=require(process.env.TOUPING_PLAYWRIGHT_MODULE || 'playwright-core');
const assert=require('node:assert/strict'),path=require('node:path');
(async()=>{
  const browser=await chromium.launch({headless:true,...(process.env.TOUPING_BROWSER_EXECUTABLE?{executablePath:process.env.TOUPING_BROWSER_EXECUTABLE}:{}),args:['--autoplay-policy=no-user-gesture-required']});
  try {
    for(const mode of ['normal','meter-error','autoplay-blocked']) {
      const page=await browser.newPage(),errors=[];
      page.on('pageerror',error=>errors.push(error.message));
      await page.addInitScript(mode=>{
        const Native=window.RTCPeerConnection;
        window.RTCPeerConnection=class extends Native {constructor(...args){super(...args);window.fixturePeer=this;}};
        if(mode==='autoplay-blocked') {
          const play=HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play=function(){
            if(this.id==='video' && !window.fixtureAllowPlay)return Promise.reject(new DOMException('Synthetic permission block','NotAllowedError'));
            return play.call(this);
          };
        }
      },mode);
      await page.route('http://127.0.0.1:20319/**',route=>{
        const name=new URL(route.request().url()).pathname.slice(1)||'receiver.html';
        if(['receiver.html','receiver.js','receiver-i18n.js','receiver-auth.js','receiver-room.js'].includes(name))return route.fulfill({path:path.resolve('Server/Web',name),contentType:name.endsWith('.js')?'application/javascript':'text/html'});
        return route.continue();
      });
      await page.goto('http://127.0.0.1:20319/#invite=61328407');
      if(mode==='meter-error')await page.evaluate(()=>{window.ToupingRoom.track=()=>{throw Error('Synthetic unavailable audio meter');};});
      await page.fill('#password','Fixture-only-71');await page.fill('#application','Synthetic video regression');await page.click('#start');
      await page.waitForFunction(()=>window.fixturePeer?.connectionState==='connected',null,{timeout:20000});
      if(mode==='autoplay-blocked') {
        await page.waitForFunction(()=>document.getElementById('diagnostics').textContent.includes('NotAllowedError'));
        await page.evaluate(()=>{window.fixtureAllowPlay=true;});await page.click('#play');
      }
      await page.waitForFunction(()=>{
        const v=document.getElementById('video');return v.videoWidth>0 && !v.paused && v.currentTime>.5;
      },null,{timeout:15000});
      await page.waitForFunction(()=>/解码=[1-9]/.test(document.getElementById('diagnostics').textContent),null,{timeout:10000});
      const result=await page.evaluate(async()=>{
        const video=document.getElementById('video'),stats=await fixturePeer.getStats();
        const inbound=[...stats.values()].find(x=>x.type==='inbound-rtp' && x.kind==='video');
        const canvas=document.createElement('canvas');canvas.width=video.videoWidth;canvas.height=video.videoHeight;
        const context=canvas.getContext('2d');context.drawImage(video,0,0);
        const colors=[[.25,.25],[.75,.25],[.25,.75],[.75,.75]].map(([x,y])=>Array.from(context.getImageData(x*canvas.width,y*canvas.height,1,1).data).slice(0,3));
        return {width:video.videoWidth,height:video.videoHeight,decoded:inbound.framesDecoded,codec:stats.get(inbound.codecId).mimeType,colors,diagnostics:document.getElementById('diagnostics').textContent};
      });
      assert.equal(result.codec,'video/H264');assert.ok(result.decoded>0);assert.ok(result.width>=640);assert.ok(result.colors.every(rgb=>Math.max(...rgb)>180));
      assert.match(result.diagnostics,/网页版本：81/);assert.match(result.diagnostics,/已收到画面/);assert.deepEqual(errors,[]);
      await page.click('#stop');assert.equal(await page.$eval('#play',e=>e.disabled),true);
      console.log(`PASS browser ${mode}: H264 ${result.width}x${result.height}, decoded=${result.decoded}, four visible color samples, disconnect cleanup`);
      await page.close();
    }
  } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});

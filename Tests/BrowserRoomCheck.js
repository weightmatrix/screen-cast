'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),crypto=require('node:crypto').webcrypto;
class Element {
  constructor(){this.value='';this.textContent='';this.style={};this.children=[];this.options=[];this.hidden=true;this.checked=false;}
  setAttribute(key,value){(this.attrs??={})[key]=value;}
  addEventListener(){}
  replaceChildren(...items){this.children=[...items];}
  append(...items){for(const item of items){item.parent=this;this.children.push(item);}}
  add(item){this.options.push(item);}
  get firstChild(){return this.children[0];}
  remove(){if(this.parent)this.parent.children=this.parent.children.filter(x=>x!==this);}
}
const elements=new Map(),get=id=>{if(!elements.has(id))elements.set(id,new Element());return elements.get(id);};
const context={location:{protocol:'https:'},document:{getElementById:get,createElement:()=>new Element()},localStorage:{getItem:()=>null,setItem:()=>{}},navigator:{},crypto,TextEncoder,Option:class{constructor(text,value){this.text=text;this.value=value;}},HTMLMediaElement:class{},performance:{now:()=>1000},setTimeout,clearTimeout,setInterval,clearInterval,console};context.window=context;
vm.createContext(context);vm.runInContext(fs.readFileSync('Server/Web/receiver-room.js','utf8'),context);
const sent=[],chat={readyState:'open',bufferedAmount:0,send:raw=>sent.push(JSON.parse(raw)),close(){this.readyState='closed';}};
const session={closed:false,pc:{createDataChannel(label,options){assert.equal(label,'touping-room-text-v1');assert.equal(options.id,1);assert.equal(options.ordered,true);return chat;},getTransceivers:()=>[]}};
context.ToupingRoom.attach(session);chat.onopen();
assert.equal(sent[0].kind,'hello');assert.match(sent[0].participant,/^[a-f0-9-]{36}$/i);assert.ok(sent[0].nickname);assert.equal(sent[0].origin,'publicWeb');assert.match(get('nickname').value,/^访客·/);
const defaultName=get('nickname').value;context.location.protocol='http:';chat.onopen();assert.equal(sent.at(-1).origin,'localWeb');assert.equal(sent.at(-1).nickname,defaultName);context.location.protocol='https:';
chat.onmessage({data:JSON.stringify({kind:'host',participant:'33333333-3333-4333-8333-333333333333'})});
assert.equal(session.roomReady,true);
get('chat-draft').value='Synthetic browser message';get('chat-form').onsubmit({preventDefault(){}});assert.equal(sent.at(-1).kind,'chat');
const id='11111111-1111-4111-8111-111111111111';
chat.onmessage({data:JSON.stringify({kind:'chat',id,author:'<script>fixture</script>',text:'<img onerror=fixture>'})});
assert.equal(get('chat-messages').children.length,1);assert.equal(get('chat-messages').children[0].children[1].textContent,'<img onerror=fixture>');
chat.onmessage({data:JSON.stringify({kind:'chat',id,author:'other',text:'duplicate'})});assert.equal(get('chat-messages').children.length,1);
chat.onmessage({data:JSON.stringify({kind:'chat',id:'22222222-2222-4222-8222-222222222222',text:'x'.repeat(501)})});assert.equal(get('chat-messages').children.length,1);
for(let i=0;i<12;i++){get('chat-draft').value='Rate fixture';get('chat-form').onsubmit({preventDefault(){}});}
assert.equal(sent.filter(x=>x.kind==='chat').length,8);
context.ToupingRoom.stop(session);assert.equal(get('voice-toggle').checked,true);assert.equal(get('chat-messages').children.length,0);
console.log('PASS browser P2P channel/nickname, literal text rendering, message deduplication/limits/rate and disconnect cleanup');

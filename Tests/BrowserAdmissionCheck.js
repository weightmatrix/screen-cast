'use strict';
const assert=require('node:assert/strict'), crypto=require('node:crypto');
require('../Server/Web/receiver-auth.js');
for(const input of ['', 'abc', '🔒申请é', 'a'.repeat(1000)]) {
  assert.equal(ToupingAuth.hash(input),crypto.createHash('sha256').update(input).digest('hex'));
}
for(const password of ['Fixture-only-71', '秘密密码123', 'cafe\u0301-123']) {
  const invite='61328407', nonce='a'.repeat(32);
  const verifier=crypto.createHash('sha256').update('touping-auth-v2:'+invite+':'+password.normalize('NFC')).digest('hex');
  assert.equal(ToupingAuth.verifier(password,invite),verifier);
  assert.equal(ToupingAuth.proof(verifier,nonce),crypto.createHmac('sha256',verifier).update(nonce).digest('hex'));
}
assert.equal(ToupingAuth.code('https://example.test/#invite=61328407'),'61328407');
assert.equal(ToupingAuth.code('https://example.test/#code=61328407'),'61328407');
console.log('PASS browser admission SHA-256/HMAC against Node crypto, Unicode normalization and invitation parsing');

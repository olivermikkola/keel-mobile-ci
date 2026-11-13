import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handle, type AuthContext, type Store } from '../src/auth.ts';
class MemoryStore implements Store {
  values = new Map<string,string>();
  async get(k:string) { return this.values.get(k) ?? null; }
  async put(k:string,v:string) { this.values.set(k,v); }
  async delete(k:string) { this.values.delete(k); }
  async consume(k:string, expected:string) { if(this.values.get(k)!==expected) return false; this.values.delete(k); return true; }
}
const base = 'https://connector.example';
const appSecret = 'fixture-app-secret-never-native';
const userToken = 'ghu_fixture-user-token';
const refreshToken = 'ghr_fixture_refresh_token';
function env(): AuthContext & { STATE: MemoryStore } { return { STATE:new MemoryStore(), STORAGE_KEY:Buffer.alloc(32,7).toString('base64url'), OWNER:'owner' }; }
function request(path:string, body?:unknown, cookie?:string) { return new Request(base+path, { method:body?'POST':'GET', headers:cookie?{Cookie:cookie}:{}, body:body?JSON.stringify(body):undefined }); }
async function setup(e:AuthContext, owner='owner') {
  const start=await handle(request('/setup'),e);
  const cookie=start.headers.get('set-cookie')!.split(';')[0];
  const state=cookie.split('=')[1];
  const response=await handle(request('/setup/callback?state='+state+'&code='+'a'.repeat(40),undefined,cookie),e,async (url,options)=> {
    assert.equal(url,'https://api.github.com/app-manifests/'+'a'.repeat(40)+'/conversions');
    assert.equal(options?.method,'POST');assert.equal(options?.redirect,'manual');
    return Response.json({client_id:'Iv1.fixture',client_secret:appSecret,html_url:'https://github.com/apps/keel-fixture',owner:{login:owner},pem:'PRIVATE-KEY-MUST-BE-DISCARDED',webhook_secret:'DISCARD-ME'});
  });
  return response;
}
async function session(e:AuthContext) {
  const state=Buffer.alloc(32,1).toString('base64url');
  const verifier=Buffer.alloc(32,2).toString('base64url');
  const challenge=Buffer.from(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))).toString('base64url');
  const result=await handle(request('/start?state='+state+'&challenge='+challenge),e);
  assert.equal(result.status,302);
  const url=new URL(result.headers.get('location')!);
  assert.equal(url.hostname,'github.com'); assert.equal(url.searchParams.get('code_challenge'),challenge);
  return {state,verifier,code:'b'.repeat(20)};
}
test('owner-approved app setup encrypts configuration and discards unused keys',async()=> {
  const e=env();const result=await setup(e);assert.equal(result.status,200);
  const stored=await e.STATE.get('app');assert(stored);assert(!stored.includes(appSecret));assert(!stored.includes('PRIVATE-KEY'));assert(!stored.includes('DISCARD-ME'));
  const config=await (await handle(request('/config'),e)).json();
  assert.equal(config.configured,true);assert.equal(config.install_url,'https://github.com/apps/keel-fixture/installations/new');assert(!JSON.stringify(config).includes(appSecret));
  assert(![...e.STATE.values.keys()].some(k=>k.startsWith('setup:')));
});
test('wrong owner and missing setup cookie cannot bind an application',async()=> {
  const e=env();assert.match(await (await setup(e,'intruder')).text(),/Setup status: owner/);assert.equal(await e.STATE.get('app'),null);
  let called=false;
  const result=await handle(request('/setup/callback?state='+'a'.repeat(43)+'&code='+'b'.repeat(40)),e,async()=>{called=true;throw Error();});
  assert.match(await result.text(),/Setup status: expired/);assert.equal(called,false);
});
test('PKCE exchange delivers tokens in a no-store JSON response, never URL or storage',async()=> {
  const e=env();await setup(e);const fields=await session(e);
  const callback=await handle(request('/oauth/callback?state='+fields.state+'&code='+fields.code),e);
  assert.equal(new URL(callback.headers.get('location')!).protocol,'keelmobile:');assert(!callback.headers.get('location')!.includes(userToken));
  let calls=0;
  const network:typeof fetch=async(url,options)=> {
    calls++;assert.equal(url,'https://github.com/login/oauth/access_token');assert.equal(options?.redirect,'manual');
    const body=JSON.parse(String(options?.body));assert.equal(body.client_secret,appSecret);assert.equal(body.code_verifier,fields.verifier);
    return Response.json({access_token:userToken,refresh_token:refreshToken,expires_in:28800,token_type:'bearer'});
  };
  const response=await handle(request('/exchange',fields),e,network);assert.equal(response.status,200);
  assert.equal(response.headers.get('cache-control'),'no-store');assert.equal((await response.json()).access_token,userToken);
  assert(!JSON.stringify([...e.STATE.values]).includes(userToken));assert(!JSON.stringify([...e.STATE.values]).includes(refreshToken));
  assert.equal((await handle(request('/exchange',fields),e,network)).status,401);assert.equal(calls,1);
});
test('wrong verifier, forged callback, malformed body and expiry never reach GitHub',async()=> {
  const e=env();await setup(e);const fields=await session(e);let calls=0;
  const network:typeof fetch=async()=>{calls++;throw Error();};
  assert.equal((await handle(request('/exchange',{...fields,verifier:'z'.repeat(43)}),e,network)).status,401);
  assert.equal((await handle(request('/oauth/callback?state='+'z'.repeat(43)+'&code='+fields.code),e,network)).status,400);
  assert.equal((await handle(request('/exchange',{state:'x'.repeat(5000)}),e,network)).status,400);
  const saved=JSON.parse((await e.STATE.get('oauth:'+fields.state))!);saved.created=0;await e.STATE.put('oauth:'+fields.state,JSON.stringify(saved));
  assert.equal((await handle(request('/exchange',fields),e,network)).status,401);assert.equal(calls,0);
});
test('parallel exchange attempts consume the session once',async()=> {
  const e=env();await setup(e);const fields=await session(e);let calls=0;
  const network:typeof fetch=async()=>{calls++;return Response.json({access_token:userToken,token_type:'bearer'});};
  const results=await Promise.all([handle(request('/exchange',fields),e,network),handle(request('/exchange',fields),e,network)]);
  assert.deepEqual(results.map(r=>r.status).sort(),[200,401]);assert.equal(calls,1);
});
test('GitHub authorization failure exposes no upstream response or secret',async()=> {
  const e=env();await setup(e);const fields=await session(e);
  const response=await handle(request('/exchange',fields),e,async()=>Response.json({error:'bad_code',debug:appSecret}));
  assert.equal(response.status,401);assert(!JSON.stringify(await response.json()).includes(appSecret));
});

test('setup errors show a safe recovery page instead of raw JSON', async () => {
  for (const failure of ['rejected', 'network'] as const) {
    const e=env();
    const start=await handle(request('/setup'),e);
    const cookie=start.headers.get('set-cookie')!.split(';')[0];
    assert.match(start.headers.get('set-cookie')!, /Max-Age=3600/);
    const state=cookie.split('=')[1];
    const result=await handle(request('/setup/callback?state='+state+'&code='+'c'.repeat(40),undefined,cookie),e,async()=> {
      if(failure==='network') throw Error(appSecret);
      return Response.json({debug:appSecret},{status:422});
    });
    const text=await result.text();
    assert.match(text,/Restart GitHub setup/);assert(!text.includes(appSecret));
    assert.match(text, failure==='network' ? /Setup status: unavailable/ : /Setup status: conversion/);
    assert.equal(await e.STATE.get('app'),null);
  }
});

test('GitHub redirects are never followed or exposed to the phone', async()=> {
  const e=env();await setup(e);const fields=await session(e);
  const response=await handle(request('/exchange',fields),e,async(_url,options)=> {
    assert.equal(options?.redirect,'manual');
    return new Response(null,{status:302,headers:{Location:'https://attacker.example/?secret='+appSecret}});
  });
  assert.equal(response.status,401);assert.equal(response.headers.get('location'),null);
  assert(!JSON.stringify(await response.json()).includes(appSecret));
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Persistence } from '../src/persistence.mjs';
import { validMessage, githubExternalURL } from '../src/bridge.mjs';
const crypto = { isEncryptionAvailable: () => true, encryptString: value => Buffer.from([...Buffer.from(value)].map(v => v ^ 93)), decryptString: value => Buffer.from([...value].map(v => v ^ 93)).toString() };
function fixture(t, cipher = crypto) { const dir = mkdtempSync(join(tmpdir(), 'issues-storage-')); t.after(() => rmSync(dir, { recursive: true, force: true })); return new Persistence({ dir, crypto: cipher }); }
test('project caches reject mismatched identity and isolate projects', t => {
  const p = fixture(t); const a='https://github.com/users/demo/projects/1', b='https://github.com/users/demo/projects/2';
  p.saveCache(a,{ project:{url:a},issues:[{id:'A'}] });p.saveCache(b,{project:{url:b},issues:[{id:'B'}]});
  assert.equal(p.loadCache(a).issues[0].id,'A');assert.equal(p.loadCache(b).issues[0].id,'B');
  assert.throws(() => p.saveCache(a,{project:{url:b}}));p.removeCache(a);assert.equal(p.loadCache(a),null);assert.ok(p.loadCache(b));
});
test('credentials only persist encrypted and require an OS encryption provider', t => {
  const p=fixture(t);p.setToken('private-fixture-secret');assert.equal(p.getToken(),'private-fixture-secret');
  assert.ok(!readFileSync(join(p.dir,'credential.json'),'utf8').includes('private-fixture-secret'));
  p.saveSettings({token:'do-not-store',onlyMine:true});assert.deepEqual(p.loadSettings(),{onlyMine:true});
  p.deleteToken();assert.equal(p.hasToken(),false);
  const unavailable=fixture(t,{isEncryptionAvailable:()=>false});assert.throws(()=>unavailable.setToken('x'));assert.equal(unavailable.hasToken(),false);
});
test('IPC rejects privileged arbitrary actions and malformed payloads', () => {
  assert.equal(validMessage({action:'exec',cmd:'anything'}),false);
  assert.equal(validMessage({action:'connect',projectURL:'url',useCLI:'true'}),false);
  assert.equal(validMessage({action:'updateAssignees',id:'i',assigneeIDs:Array(11).fill('x')}),false);
  assert.equal(validMessage({action:'preference',key:'token',value:'no'}),false);
  assert.equal(validMessage({action:'createIssue',repository:'a/b',title:'x',body:'x'.repeat(65537)}),false);
  assert.equal(validMessage({action:'changeStatus',id:'i',optionID:''}),true);
  for (const url of ['file:///tmp/x','https://evil.example','https://github.com.evil.example','https://user:pass@github.com/x','https://github.com:8443/x']) assert.throws(()=>githubExternalURL(url));
  assert.equal(githubExternalURL('https://github.com/example/repo/issues/1'),'https://github.com/example/repo/issues/1');
});

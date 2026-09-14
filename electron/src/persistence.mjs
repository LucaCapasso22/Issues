import { mkdirSync, readFileSync, writeFileSync, renameSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';

export class Persistence {
  constructor({ dir, crypto }) {
    this.dir = dir;
    this.crypto = crypto;
    mkdirSync(join(dir, 'project-caches'), { recursive: true, mode: 0o700 });
  }
  read(name, fallback) {
    try { return JSON.parse(readFileSync(join(this.dir, name), 'utf8')); }
    catch (error) { if (error.code === 'ENOENT' || error instanceof SyntaxError) return fallback; throw error; }
  }
  write(name, value) {
    const target = join(this.dir, name);
    const temp = `${target}.${randomUUID()}.tmp`;
    try {
      writeFileSync(temp, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
      renameSync(temp, target);
    } finally { rmSync(temp, { force: true }); }
  }
  loadSettings() { return this.read('settings.json', {}); }
  saveSettings(settings) {
    const { token, password, accessToken, ...safe } = settings;
    this.write('settings.json', safe);
  }
  cacheName(url) { return `project-caches/${createHash('sha256').update(url).digest('hex')}.json`; }
  loadCache(url) {
    const entry = this.read(this.cacheName(url), null);
    return entry?.project?.url === url ? entry : null;
  }
  saveCache(url, snapshot) {
    if (snapshot?.project?.url !== url) throw new Error('Project cache identity does not match the selected project.');
    this.write(this.cacheName(url), snapshot);
  }
  removeCache(url) { rmSync(join(this.dir, this.cacheName(url)), { force: true }); }
  hasToken() { return existsSync(join(this.dir, 'credential.json')); }
  requireEncryption() {
    if (!this.crypto?.isEncryptionAvailable() || (process.platform === 'linux' && this.crypto.getSelectedStorageBackend?.() === 'basic_text')) {
      throw new Error('Secure credential storage is unavailable. Use GitHub CLI authentication instead.');
    }
  }
  getToken() {
    const value = this.read('credential.json', null);
    if (!value) return null;
    this.requireEncryption();
    try { return this.crypto.decryptString(Buffer.from(value.encrypted, 'base64')); }
    catch { throw new Error('The saved token could not be decrypted. Reconnect using GitHub CLI or save the token again.'); }
  }
  setToken(token) {
    this.requireEncryption();
    if (typeof token !== 'string' || !token.trim()) throw new Error('Enter a GitHub token.');
    this.write('credential.json', { version: 1, encrypted: this.crypto.encryptString(token.trim()).toString('base64') });
  }
  deleteToken() { rmSync(join(this.dir, 'credential.json'), { force: true }); }
  loadBounds(key) { return this.read('windows.json', {})[key] ?? null; }
  saveBounds(key, bounds) { this.write('windows.json', { ...this.read('windows.json', {}), [key]: bounds }); }
}

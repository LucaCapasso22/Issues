import { readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const files = readdirSync(new URL('../test/', import.meta.url)).filter(file => !file.startsWith("._") && file.endsWith('.test.mjs')).map(file => fileURLToPath(new URL(`../test/${file}`, import.meta.url)));
const result = spawnSync(process.execPath, ['--test', ...files], { stdio: 'inherit' });
process.exitCode = result.status ?? 1;

import { readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
for (const dir of ['src', 'renderer', 'scripts']) {
  for (const file of readdirSync(new URL(`../${dir}/`, import.meta.url)).filter(file => !file.startsWith("._") && /\.(mjs|cjs|js)$/.test(file))) {
    const result = spawnSync(process.execPath, ['--check', fileURLToPath(new URL(`../${dir}/${file}`, import.meta.url))], { stdio: 'inherit' });
    if (result.status !== 0) process.exit(result.status ?? 1);
  }
}
console.log('JavaScript syntax checks passed.');

import assert from 'node:assert/strict';
import fs from 'node:fs/promises';

// Evaluate the module with a stubbed shell; never contact AWS in this check.
const source = (await fs.readFile(new URL('./index.mjs', import.meta.url), 'utf8'))
  .replace(/^#!.*\n/, '')
  .replace(/^import .*;$/gm, '')
  .replaceAll('export ', '')
  .replace('import.meta.url', JSON.stringify(import.meta.url));
const calls = [];
const shell = async (strings) => {
  calls.push(strings.join(''));
  return { stdout: 'langfuse-v2\n' };
};
const { install, uninstall } = new Function('$', 'fileURLToPath', 'path', `${source}\nreturn {install, uninstall};`)(shell, () => '/test/index.mjs', { dirname: () => '/test' });
await assert.rejects(install(), /migration detected/);
await assert.rejects(uninstall(), /Refusing to delete/);
assert.equal(calls.length, 2);
assert(calls.every(command => command.startsWith('helm list')));
console.log('PASS: migrated releases block old install/uninstall before any write.');

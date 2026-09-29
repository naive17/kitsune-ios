// The commit-msg rule: "<type>: <message>" with a known type and at most ten
// words, checked on the subject line of the file git hands the hook.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { checkSubject, subjectOf, TYPES } from '../scripts/check-commit-msg.mjs';

for (const type of TYPES) assert.equal(checkSubject(`${type}: something small`), null);
assert.equal(checkSubject('update: one two three four five six seven eight nine ten'), null);
assert.match(checkSubject('update: one two three four five six seven eight nine ten eleven'), /11 words/);
assert.match(checkSubject('feature: new thing'), /not a commit type/);
assert.match(checkSubject('Update: capitalised type'), /<type>: <message>/);
assert.match(checkSubject('update:no space'), /<type>: <message>/);
assert.match(checkSubject('update: '), /<type>: <message>/);
assert.match(checkSubject('just a sentence'), /<type>: <message>/);
assert.equal(checkSubject("Merge branch 'topic'"), null);
assert.equal(checkSubject('Revert "update: something"'), null);
assert.equal(checkSubject('fixup! update: something'), null);

assert.equal(subjectOf('# Please enter the commit message\n\nfix: crash on exit\n\nbody\n'), 'fix: crash on exit');
assert.equal(subjectOf('\n\n'), '');

// The hook's own exit status on a real message file.
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'commit-msg-'));
const script = path.resolve(import.meta.dirname, '../scripts/check-commit-msg.mjs');
const hook = text => {
  fs.writeFileSync(path.join(dir, 'MSG'), text);
  return spawnSync(process.execPath, [script, path.join(dir, 'MSG')], { encoding: 'utf8' });
};
assert.equal(hook('docs: explain the setup steps\n\nThe body is free-form.\n').status, 0);
const refused = hook('Fixed some stuff\n');
assert.equal(refused.status, 1);
assert.match(refused.stderr, /commit refused/);
fs.rmSync(dir, { recursive: true });

console.log('commit-msg PASS: types, ten-word limit, git-written subjects, hook exit status');

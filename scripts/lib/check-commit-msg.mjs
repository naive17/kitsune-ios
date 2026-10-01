// The commit-msg hook (.husky/commit-msg): the subject is "<type>: <message>",
// with a type from TYPES and at most MAX_WORDS words of message. Subjects git
// writes itself (merges, reverts, fixup!/squash!/amend!) pass unchanged.
//   node scripts/lib/check-commit-msg.mjs <message file>
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

export const TYPES = ['add', 'update', 'fix', 'remove', 'docs'];
export const MAX_WORDS = 10;

// The subject is the first line that is neither empty nor a git comment.
export function subjectOf(text) {
  return text.split('\n').find(line => line.trim() && !line.startsWith('#'))?.trim() ?? '';
}

// Why the subject is refused, or null when it is fine.
export function checkSubject(subject) {
  if (/^(Merge |Revert "|fixup! |squash! |amend! )/.test(subject)) return null;
  const m = /^([a-z]+): (\S.*)$/.exec(subject);
  if (!m) return 'the subject must be "<type>: <message>"';
  if (!TYPES.includes(m[1])) return `"${m[1]}" is not a commit type`;
  const words = m[2].trim().split(/\s+/).length;
  if (words > MAX_WORDS) return `the message has ${words} words; at most ${MAX_WORDS}`;
  return null;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const subject = subjectOf(fs.readFileSync(process.argv[2], 'utf8'));
  const why = checkSubject(subject);
  if (why) {
    console.error(`commit refused: ${why}\n  got:      ${subject || '(empty)'}\n` +
                  `  expected: <type>: <message of at most ${MAX_WORDS} words>\n` +
                  `  types:    ${TYPES.join(', ')}\n  example:  update: faster Wine tree install`);
    process.exit(1);
  }
}

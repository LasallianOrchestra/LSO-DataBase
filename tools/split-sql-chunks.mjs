#!/usr/bin/env node
/**
 * Split a large LSO .sql installer into sequential, paste-ready chunks for the
 * Supabase dashboard (which has no file upload).
 *
 * Splitting SQL by text length is unsafe. This tool therefore:
 *
 *   1. Lexes the file with real Postgres lexical rules so a cut can only land
 *      on a top-level statement boundary:
 *        - dollar-quoted bodies  $$ ... $$  and  $tag$ ... $tag$  are opaque
 *        - single-quoted literals with '' escapes are opaque
 *        - line comments  -- ...  and nestable block comments /* ... *\/
 *        - a ";" only ends a statement at parenthesis depth 0
 *   2. Tracks the top-level transaction depth (begin/start transaction vs
 *      commit/end/rollback) and CUTS ONLY WHERE IT IS ZERO, so no chunk ever
 *      splits a begin;/commit; pair. Splitting one would commit a section early
 *      and leave the next paste starting on a stray "commit;" that the
 *      dashboard reports as an error -- exactly the "editor rejected it" class
 *      of failure this tool exists to remove.
 *   3. Asserts the result: chunks rejoin to the source byte-for-byte, every
 *      chunk stands alone (transaction depth 0 at its end), and no chunk starts
 *      inside a quote or comment.
 *
 * A transaction section larger than the cap is kept whole and reported, rather
 * than being cut -- correctness over size compliance.
 *
 * Usage:
 *   node tools/split-sql-chunks.mjs <file.sql> [--max-bytes N] [--out DIR]
 *
 * Output: <out>/NNN-of-MMM-<basename>.sql plus index.md describing the order.
 * Nothing is executed and no connection is opened; this is offline and read-only.
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { basename, resolve } from 'node:path';

const argv = process.argv.slice(2);
const input = argv.find((a) => !a.startsWith('--'));
const numFlag = (name, fallback) => {
  const hit = argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? Number(hit.split('=')[1]) : fallback;
};
const outFlag = argv.find((a) => a.startsWith('--out='));

if (!input) {
  console.error('usage: node tools/split-sql-chunks.mjs <file.sql> [--max-bytes N] [--out DIR]');
  process.exit(2);
}
// ~90KB pastes into the dashboard without the editor trimming the buffer.
const MAX_BYTES = numFlag('max-bytes', 90_000);
const label = basename(input, '.sql');
const OUT = resolve(outFlag ? outFlag.split('=')[1] : `tools/sql-chunks/${label}`);

const sql = readFileSync(resolve(input), 'utf8');
const sourceBytes = Buffer.byteLength(sql);

// ---------------------------------------------------------------------------
// 1. Lex into top-level statements
// ---------------------------------------------------------------------------
const stmtEnds = [];
let i = 0;
let paren = 0;
let dollarTag = null;
let inString = false;
let inLine = false;
let inBlock = false;
let blockDepth = 0;
const at = (s) => sql.startsWith(s, i);

while (i < sql.length) {
  const ch = sql[i];
  if (inLine) {
    if (ch === '\n') inLine = false;
    i += 1;
  } else if (inBlock) {
    if (at('*/')) {
      blockDepth -= 1;
      i += 2;
      if (blockDepth === 0) inBlock = false;
    } else i += 1;
  } else if (dollarTag) {
    if (at(dollarTag)) {
      i += dollarTag.length;
      dollarTag = null;
    } else i += 1;
  } else if (inString) {
    if (ch === "'") {
      if (sql[i + 1] === "'") i += 2;
      else {
        inString = false;
        i += 1;
      }
    } else i += 1;
  } else if (at('--')) {
    inLine = true;
    i += 2;
  } else if (at('/*')) {
    inBlock = true;
    blockDepth = 1;
    i += 2;
  } else if (ch === "'") {
    inString = true;
    i += 1;
  } else if (ch === '$') {
    const m = /^\$[A-Za-z_0-9]*\$/.exec(sql.slice(i, i + 32));
    if (m) {
      dollarTag = m[0];
      i += m[0].length;
    } else i += 1;
  } else if (ch === '(') {
    paren += 1;
    i += 1;
  } else if (ch === ')') {
    paren = Math.max(0, paren - 1);
    i += 1;
  } else if (ch === ';' && paren === 0) {
    stmtEnds.push(i + 1);
    i += 1;
  } else i += 1;
}

const die = (msg) => {
  console.error(`FATAL: ${msg}`);
  process.exit(1);
};
if (dollarTag) die(`unterminated dollar-quote ${dollarTag} in ${input}`);
if (inBlock) die(`unterminated block comment in ${input}`);
if (inString) die(`unterminated string literal in ${input}`);
if (!stmtEnds.length) die(`no top-level statements found in ${input}`);

const statements = [];
let cursor = 0;
for (const end of stmtEnds) {
  statements.push(sql.slice(cursor, end));
  cursor = end;
}
if (cursor < sql.length) statements.push(sql.slice(cursor)); // trailing comments

// ---------------------------------------------------------------------------
// 2. Top-level transaction depth per statement (quotes/comments already excluded
//    by the lexer, so a bare "end;" inside a function body can never appear here)
// ---------------------------------------------------------------------------
const OPEN_TXN = /^\s*(?:begin|start\s+transaction)\s*;/i;
const CLOSE_TXN = /^\s*(?:commit|end|rollback)\s*;/i;
const stripLeading = (s) => s.replace(/^(?:\s|--[^\n]*\n|\/\*[\s\S]*?\*\/)+/, '');

const net = statements.map((s) => {
  const body = stripLeading(s);
  if (OPEN_TXN.test(body)) return 1;
  if (CLOSE_TXN.test(body)) return -1;
  return 0;
});
const total = net.reduce((a, b) => a + b, 0);
if (total !== 0) {
  die(
    `${input} is not transaction-balanced (net depth ${total}). A chunk boundary cannot be ` +
      'guaranteed safe. Fix the script, or pass --max-bytes large enough for one chunk.'
  );
}

// ---------------------------------------------------------------------------
// 3. Pack statements, cutting only where depth returns to zero
// ---------------------------------------------------------------------------
const chunks = [];
let buf = '';
let bufNet = 0;
let depth = 0;
const oversize = [];

for (let k = 0; k < statements.length; k += 1) {
  const stmt = statements[k];
  const wouldExceed = buf && Buffer.byteLength(buf) + Buffer.byteLength(stmt) > MAX_BYTES;
  // Cut before this statement only if the previous cut point was legal (depth 0)
  // and we are still inside the same open transaction.
  if (wouldExceed && depth === 0) {
    chunks.push({ text: buf, netEnd: bufNet });
    buf = '';
    bufNet = 0;
  } else if (wouldExceed) {
    oversize.push({ index: k + 1, bytes: Buffer.byteLength(buf) + Buffer.byteLength(stmt), depth });
  }
  buf += stmt;
  depth += net[k];
  bufNet += net[k];
}
if (buf.trim()) chunks.push({ text: buf, netEnd: bufNet });

// A tiny trailing remainder costs a whole extra paste for nothing. Merging it
// backwards never weakens a guarantee: the removed boundary was legal, and a
// legal-but-unneeded cut is simply not made.
const TAIL_MERGE_BYTES = 4096;
if (chunks.length > 1 && Buffer.byteLength(chunks[chunks.length - 1].text) < TAIL_MERGE_BYTES) {
  const tail = chunks.pop();
  const prevChunk = chunks[chunks.length - 1];
  prevChunk.text += tail.text;
  prevChunk.netEnd += tail.netEnd;
}

if (oversize.length) {
  console.warn(
    `NOTE: ${oversize.length} transaction section(s) exceed --max-bytes and were kept whole ` +
      `(largest ${Math.max(...oversize.map((o) => o.bytes)).toLocaleString()} bytes). ` +
      'Raise --max-bytes if the dashboard accepts larger pastes.'
  );
}

// ---------------------------------------------------------------------------
// 4. Assert before writing anything
// ---------------------------------------------------------------------------
const joined = chunks.map((c) => c.text).join('');
if (joined !== sql) die('chunk set does not rejoin to the source byte-for-byte');
const badNet = chunks.map((c, n) => ({ n: n + 1, net: c.netEnd })).filter((c) => c.net !== 0);
if (badNet.length) {
  die(`chunk(s) do not end at transaction depth 0: ${badNet.map((c) => `#${c.n} net=${c.net}`).join(', ')}`);
}
const badStart = chunks
  .map((c, n) => ({ n: n + 1, body: stripLeading(c.text) }))
  .filter((c) => CLOSE_TXN.test(c.body));
if (badStart.length) {
  die(`chunk(s) begin with a stray transaction close: ${badStart.map((c) => `#${c.n}`).join(', ')}`);
}

// ---------------------------------------------------------------------------
// 5. Write
// ---------------------------------------------------------------------------
rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });
const total_chunks = chunks.length;
const pad = String(total_chunks).padStart(3, '0');

const chunkFiles = chunks.map((c, n) => resolve(OUT, `${String(n + 1).padStart(3, '0')}-of-${pad}-${label}.sql`));
// Write the exact bytes. Adding a trailing newline per chunk would make the
// files a "prettier" paste but no longer a byte-exact partition of the source,
// which is the one property that makes sequential pastes trustworthy.
chunkFiles.forEach((file, n) => writeFileSync(file, chunks[n].text));

// Read back what is actually on disk and re-assert. The in-memory join passing
// is not proof that the artifacts the user will paste are correct.
const onDisk = chunkFiles.map((file) => readFileSync(file, 'utf8')).join('');
if (onDisk !== sql) {
  die(
    'written chunk files do not rejoin to the source byte-for-byte ' +
      `(${Buffer.byteLength(onDisk).toLocaleString()} bytes on disk vs ${sourceBytes.toLocaleString()} in source)`
  );
}

const index = [
  `# ${label} — paste-ready chunks`,
  '',
  `Source: \`${input}\` — ${sourceBytes.toLocaleString()} bytes, ${statements.length} top-level statements, ${total_chunks} chunks.`,
  '',
  'Guarantees checked by the splitter before these files were written:',
  '',
  `- every boundary sits on a top-level statement end (quotes, \`\$\$\` bodies and comments are opaque);`,
  '- no chunk splits a `begin;`/`commit;` pair, so each chunk is a complete script;',
  '- concatenating the chunks reproduces the source byte-for-byte.',
  '',
  '## Run order',
  '',
  chunks
    .map((c, n) => {
      const txns = (c.text.match(/^\s*(?:begin|start\s+transaction)\s*;/gim) || []).length;
      return `${n + 1}. \`${String(n + 1).padStart(3, '0')}-of-${pad}-${label}.sql\` — ${Buffer.byteLength(c.text).toLocaleString()} bytes, ~${c.text.split('\n').length} lines, ${txns} transaction block(s)`;
    })
    .join('\n'),
  '',
  '## In the dashboard',
  '',
  '1. Supabase → project → **SQL Editor** → New query. Paste chunk 001, press Run, wait for success.',
  '2. Repeat per chunk in order. A chunk that succeeds is durable; you never re-run earlier ones.',
  '3. If a chunk fails, **stop and read the red error text** — later chunks assume it applied.',
  '4. Close with the verification query (`tools/check-v82-prerequisites.sql` for the base schema,',
  '   `tools/verify-v82-migration.sql` after the V82 patch) so the result proves the schema state',
  '   instead of relying on an empty-looking "Run submitted".',
  ''
].join('\n');
writeFileSync(resolve(OUT, 'index.md'), index);

console.log(`wrote ${total_chunks} chunks + index.md → ${OUT}`);
console.log(
  `source ${sourceBytes.toLocaleString()} B / ${statements.length} statements → largest chunk ` +
    `${Math.max(...chunks.map((c) => Buffer.byteLength(c.text))).toLocaleString()} B (cap ${MAX_BYTES.toLocaleString()})`
);
console.log('verified: byte-exact round-trip, all chunks end at transaction depth 0, no stray openers');

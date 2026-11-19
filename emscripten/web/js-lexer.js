/* js-lexer.js - a small tokenizer of JavaScript, for JavaScript cells and ,js
 *
 * Copyright (c) 2026, The CHICKEN Team
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following
 * conditions are met:
 *
 *   Redistributions of source code must retain the above copyright notice, this list of conditions and the following
 *     disclaimer.
 *   Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following
 *     disclaimer in the documentation and/or other materials provided with the distribution.
 *   Neither the name of the author nor the names of its contributors may be used to endorse or promote
 *     products derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
 * OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

/* UMD: a CommonJS module in node (tests, and repl-driver.js there), the
 * global ChickenJsLexer in a worker (importScripts, before
 * repl-driver.js) and in the page.  No DOM, no state: every function
 * is pure, and takes no global when it is called.
 *
 * The JavaScript of notebook cells and of the REPL's ,js runs in the
 * worker (webjs-pre.js), and the page shows it: both use this file.
 *
 *   tokens(src)      the tokens of SRC, {t, s, e, d}: type, range [s, e)
 *                    and the depth of brackets at its start (see below)
 *   rewrite(src)     {code, topAwait, incomplete}: SRC with its top-level
 *                    let, const and class declarations turned into var,
 *                    so that their names outlive the cell (see below)
 *   incomplete(src)  whether more lines may finish SRC: it ends inside
 *                    a bracket, a string, a template or a comment, and
 *                    no line ended a string in it (an error already)
 *   balance(src)     {depth, stray, mismatch, open, ok}, as
 *                    notebook-lib.js's balance of Scheme
 *   highlight(src)   [[kind, text], ...] whose texts make SRC, kind a
 *                    class of the page's (.syn-KIND) or ''
 *   frames(stack)    the frames of an Error's stack that are the user's
 *                    (cells, ,js lines, scripts of other sites), as
 *                    [[where, proc], ...], the innermost last
 *
 * The types of tokens: space, comment (flag open when unterminated),
 * string (bad when a line ends it, open when the input does), tpl (the
 * text of a template, open when the input ends in it), regex, number,
 * name (kw for a keyword, const for a constant such as true or this),
 * open and close (brackets; tpl for the ${ of a template and the } that
 * ends it) and punct (postfix for a ++ or -- after an operand on its
 * line).  A / is a regex when the token before it (spaces and comments
 * aside) cannot end an expression, by a heuristic: a } is taken for the
 * end of a block, so "if (x) /re/.test(s)" reads as a division, and a
 * postfix ++ or -- ends one, so "i++ / 2" does too.
 *
 * highlight shows a keyword that is a property name (after . or ?., or
 * a key before a : in braces, but a switch's default) as any name.
 *
 * rewrite turns, at the top level only (outside every bracket and
 * template), let into var and const into "var  " (two spaces: the
 * columns stay), and "class X ... {...}" at the start of a statement
 * into "var X = class X ... {...};".  Lines stay where they were.
 * Declarations in blocks, loops and functions are left alone, and so
 * is everything inside strings, templates, regexes and comments.
 * topAwait says that an await is at the top level, which no cell can
 * have (they are scripts, not modules). */

(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ChickenJsLexer = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const KEYWORDS = new Set(['await', 'break', 'case', 'catch', 'class', 'const', 'continue', 'debugger', 'default',
                            'delete', 'do', 'else', 'export', 'extends', 'finally', 'for', 'function', 'if',
                            'import', 'in', 'instanceof', 'let', 'new', 'of', 'return', 'static', 'switch',
                            'throw', 'try', 'typeof', 'var', 'void', 'while', 'with', 'yield', 'async', 'get', 'set']);
  const CONSTANTS = new Set(['true', 'false', 'null', 'undefined', 'NaN', 'Infinity', 'this', 'super']);
  // keywords after which an expression begins: a / there is a regex
  const BEFORE_EXPR = new Set(['return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void', 'throw',
                               'case', 'do', 'else', 'yield', 'await']);
  // keywords that are names in some places (a class may be called so)
  const CONTEXTUAL = new Set(['let', 'of', 'async', 'get', 'set', 'static']);
  const CLOSER = { ')': '(', ']': '[', '}': '{' };

  const SPACE = /\s+/y;
  const NAME = /#?[A-Za-z_$\u0080-\uffff][\w$\u0080-\uffff]*/y;
  const NUMBER = /(?:0[xX][\da-fA-F_]*|0[oO][0-7_]*|0[bB][01_]*|(?:\d[\d_]*(?:\.[\d_]*)?|\.\d[\d_]*)(?:[eE][+-]?[\d_]+)?)n?/y;
  const isLine = c => c === '\n' || c === '\r' || c === '\u2028' || c === '\u2029';
  const LINE = /[\n\r\u2028\u2029]/;

  // the tokens of SRC (each to EMIT, in order) -> the end state
  function scan(src, emit) {
    const n = src.length, stack = [];
    let i = 0, stray = 0, mismatch = 0, open = false, bad = false;
    let prev = null;                    // the last significant token
    const tok = (t, s, e, extra) => {
      const x = { t, s, e, d: stack.length };
      if (extra) Object.assign(x, extra);
      emit(x);
      if (t !== 'space' && t !== 'comment') prev = x;
      return x;
    };
    const sticky = (re, at) => { re.lastIndex = at; return re.exec(src) ? re.lastIndex : -1; };
    // template text from S (a backtick, or after the } that ends a
    // ${), read from J: up to a ${, or the closing backtick (included)
    function template(s, j) {
      for (;;) {
        if (j >= n) { open = true; tok('tpl', s, n, { open: true }); return n; }
        const c = src[j];
        if (c === '\\') j += 2;
        else if (c === '`') { tok('tpl', s, j + 1); return j + 1; }
        else if (c === '$' && src[j + 1] === '{') {
          if (j > s) tok('tpl', s, j);
          tok('open', j, j + 2, { tpl: true });
          stack.push('t');
          return j + 2;
        } else j++;
      }
    }
    function regexAllowed() {
      if (prev === null) return true;
      switch (prev.t) {
      case 'punct': return !prev.postfix;
      case 'open': return true;
      case 'close': return src[prev.s] === '}' && !prev.tpl;
      case 'name': return BEFORE_EXPR.has(src.slice(prev.s, prev.e));
      default: return false;
      }
    }
    // the end of the regex at S, or -1 when a line ends first
    function regex(s) {
      let j = s + 1, cls = false;
      for (;;) {
        if (j >= n || isLine(src[j])) return -1;
        const c = src[j];
        if (c === '\\') { j += 2; continue; }
        if (cls) { if (c === ']') cls = false; }
        else if (c === '[') cls = true;
        else if (c === '/') break;
        j++;
      }
      j++;
      while (j < n && /[A-Za-z]/.test(src[j])) j++;
      return j;
    }

    if (src.startsWith('#!')) {
      let j = 2;
      while (j < n && !isLine(src[j])) j++;
      tok('comment', 0, j);
      i = j;
    }
    while (i < n) {
      const c = src[i], c2 = src[i + 1];
      let j;
      if ((j = sticky(SPACE, i)) > i) { tok('space', i, j); i = j; continue; }
      if (c === '/' && c2 === '/') {
        j = i + 2;
        while (j < n && !isLine(src[j])) j++;
        tok('comment', i, j);
        i = j;
        continue;
      }
      if (c === '/' && c2 === '*') {
        j = src.indexOf('*/', i + 2);
        if (j < 0) { open = true; tok('comment', i, n, { open: true }); i = n; }
        else { tok('comment', i, j + 2); i = j + 2; }
        continue;
      }
      if (c === '"' || c === "'") {
        j = i + 1;
        let how = null;
        for (;;) {
          if (j >= n) { how = 'open'; break; }
          const d = src[j];
          if (d === '\\') j += src[j + 1] === '\r' && src[j + 2] === '\n' ? 3 : 2;
          else if (d === c) { j++; break; }
          else if (d === '\n' || d === '\r') { how = 'bad'; break; }
          else j++;
        }
        if (j > n) j = n;
        if (how === 'open') open = true; else if (how === 'bad') bad = true;
        tok('string', i, j, how ? { [how]: true } : null);
        i = j;
        continue;
      }
      if (c === '`') { i = template(i, i + 1); continue; }
      if (c === '/' && regexAllowed() && (j = regex(i)) > 0) { tok('regex', i, j); i = j; continue; }
      if ((c >= '0' && c <= '9') || (c === '.' && c2 >= '0' && c2 <= '9')) {
        j = sticky(NUMBER, i);
        tok('number', i, j);
        i = j;
        continue;
      }
      if ((j = sticky(NAME, i)) > i) {
        const w = src.slice(i, j);
        tok('name', i, j, KEYWORDS.has(w) ? { kw: true } : CONSTANTS.has(w) ? { const: true } : null);
        i = j;
        continue;
      }
      if (c === '(' || c === '[' || c === '{') {
        tok('open', i, i + 1);
        stack.push(c);
        i++;
        continue;
      }
      if (c === ')' || c === ']' || c === '}') {
        if (stack.length === 0) { stray++; tok('close', i, i + 1); i++; continue; }
        const top = stack[stack.length - 1];
        if (top === 't' && c === '}') {
          tok('close', i, i + 1, { tpl: true });
          stack.pop();
          i = template(i + 1, i + 1);
          continue;
        }
        if (top !== CLOSER[c]) mismatch++;
        tok('close', i, i + 1);
        stack.pop();
        i++;
        continue;
      }
      if ((c === '+' || c === '-') && c2 === c) {
        // postfix after an operand: no line between them (a line there
        // makes it the prefix of the next statement)
        tok('punct', i, i + 2, prev !== null && endsExpression(src, prev) && !LINE.test(src.slice(prev.e, i))
                                ? { postfix: true } : null);
        i += 2;
        continue;
      }
      j = src.startsWith('...', i) ? i + 3
        : (c === '=' && c2 === '>') || (c === '?' && c2 === '.' && !(src[i + 2] >= '0' && src[i + 2] <= '9')) ? i + 2
        : i + 1;
      tok('punct', i, j);
      i = j;
    }
    if (stack.includes('t')) open = true;
    return { depth: stack.length, stray, mismatch, open, bad };
  }

  function tokens(src) {
    const out = [];
    scan(String(src), t => { out[out.length] = t; });
    return out;
  }

  // an expression may end with the token: a line after it ends the
  // statement
  function endsExpression(src, t) {
    switch (t.t) {
    case 'name': return !BEFORE_EXPR.has(src.slice(t.s, t.e));
    case 'number': case 'string': case 'tpl': case 'regex': return true;
    case 'close': return src[t.s] === ')' || src[t.s] === ']';
    case 'punct': return t.postfix === true;
    default: return false;
    }
  }

  function rewrite(src) {
    src = String(src);
    const ts = [];
    const end = scan(src, t => { if (t.t !== 'space' && t.t !== 'comment') ts[ts.length] = t; });
    const text = t => src.slice(t.s, t.e);
    // the replacements: [start, end, text], in order
    const edits = [];
    let topAwait = false;
    for (let k = 0; k < ts.length; k++) {
      const t = ts[k];
      if (t.d !== 0 || t.t !== 'name') continue;
      const w = text(t), before = k > 0 ? ts[k - 1] : null, after = ts[k + 1];
      const member = before !== null && before.t === 'punct' && (text(before) === '.' || text(before) === '?.');
      if (w === 'await') { if (!member) topAwait = true; }
      else if (w === 'let' && !member && after &&
               (after.t === 'name' || (after.t === 'open' && !after.tpl && text(after) !== '('))) {
        edits[edits.length] = [t.s, t.e, 'var'];
      } else if (w === 'const' && !member) {
        edits[edits.length] = [t.s, t.e, 'var  '];
      } else if (w === 'class' && after && after.t === 'name' && (!after.kw || CONTEXTUAL.has(text(after))) &&
                 (before === null ||
                  (before.t === 'punct' && text(before) === ';') ||
                  (before.t === 'close' && text(before) === '}' && !before.tpl) ||
                  (LINE.test(src.slice(before.e, t.s)) && endsExpression(src, before)))) {
        // its body: the first { at the top level after it, to the }
        // that closes it
        let b = k + 1;
        while (b < ts.length && !(ts[b].t === 'open' && ts[b].d === 0 && text(ts[b]) === '{')) b++;
        let c = b + 1;
        while (c < ts.length && !(ts[c].t === 'close' && ts[c].d === 1)) c++;
        if (c < ts.length) {
          edits[edits.length] = [t.s, t.s, 'var ' + text(after) + ' = '];
          edits[edits.length] = [ts[c].e, ts[c].e, ';'];
          k = c;
        }
      }
    }
    let code = '', at = 0;
    for (const [s, e, r] of edits) { code += src.slice(at, s) + r; at = e; }
    code += src.slice(at);
    return { code, topAwait, incomplete: unfinished(end) };
  }

  // more lines may finish it: no string that a line ended (which no
  // more lines mend) and an open bracket, string, template or comment
  const unfinished = end => !end.bad && (end.open || end.depth > 0);

  function incomplete(src) { return unfinished(scan(String(src), () => {})); }

  // (a string that a line ended is open too: more lines do not mend
  // it, but it is no less unclosed)
  function balance(src) {
    const { depth, stray, mismatch, open, bad } = scan(String(src), () => {});
    const unclosed = open || bad;
    return { depth, stray, mismatch, open: unclosed, ok: !depth && !stray && !mismatch && !unclosed };
  }

  function kindOf(t) {
    switch (t.t) {
    case 'comment': return 'comment';
    case 'string': case 'tpl': case 'regex': return 'string';
    case 'number': return 'number';
    case 'name': return t.kw ? 'special' : t.const ? 'constant' : '';
    case 'open': case 'close': return t.tpl ? 'quote' : 'paren';
    default: return '';
    }
  }

  // whether the name SIG[K] (SIG: the significant tokens) is a property
  // name: after . or ?., or a key in braces (after { or , and before
  // :), but the default of a switch, "switch (x) { default:"
  function property(src, sig, k) {
    const text = t => (t ? src.slice(t.s, t.e) : null);
    const b = text(sig[k - 1]), a = text(sig[k + 1]);
    if (sig[k - 1] && sig[k - 1].t === 'punct' && (b === '.' || b === '?.')) return true;
    if (a !== ':' || sig[k + 1].t !== 'punct' || !sig[k - 1]) return false;
    if (sig[k - 1].t === 'punct') return b === ',';
    return sig[k - 1].t === 'open' && b === '{' && !sig[k - 1].tpl &&
      !(text(sig[k]) === 'default' && text(sig[k - 2]) === ')');
  }

  function highlight(src) {
    src = String(src);
    const ts = tokens(src), sig = ts.filter(t => t.t !== 'space' && t.t !== 'comment'), out = [];
    let kind = null, s = 0, k = 0;
    for (const t of ts) {
      let c = kindOf(t);
      if (t.t !== 'space' && t.t !== 'comment') {
        if (t.t === 'name' && c !== '' && property(src, sig, k)) c = '';
        k++;
      }
      if (c === kind) continue;
      if (kind !== null) out[out.length] = [kind, src.slice(s, t.s)];
      kind = c;
      s = t.s;
    }
    if (kind !== null) out[out.length] = [kind, src.slice(s)];
    return out;
  }

  // the page's own scripts, whose frames are the bridge's
  const OWN = new Set(['chicken-repl.js', 'repl-worker.js', 'repl-driver.js', 'js-lexer.js', 'compiler-worker.js']);
  const CELL = /^(?:In|js)\[\d+\]$/;
  const MAX_FRAMES = 50;

  // FILE:LINE:COL -> [file, line], or null
  function location(loc) {
    const m = /^(.*):(\d+):(\d+)$/.exec(loc);
    return m ? [m[1], m[2]] : null;
  }

  function frames(stack) {
    const lines = String(stack == null ? '' : stack).split('\n'), kept = [];
    for (let i = 0; i < lines.length && kept.length < MAX_FRAMES; i++) {
      const line = lines[i];
      let name, loc, m;
      if ((m = /^\s*at (?:(.*?) \((.*)\)|(.*))$/.exec(line))) {
        name = m[3] !== undefined ? '' : m[1];
        loc = m[3] !== undefined ? m[3] : m[2];
        const ev = loc.lastIndexOf(', ');
        if (/\beval at\b/.test(loc) && ev >= 0) loc = loc.slice(ev + 2);
      } else if ((m = /^([^@]*)@(.*)$/.exec(line))) {
        name = m[1];
        loc = m[2];
      } else continue;
      const fl = location(loc);
      if (!fl) continue;
      let where;
      if (CELL.test(fl[0])) where = fl[0] + ':' + fl[1];
      else if (/^(?:https?|blob):/.test(fl[0])) {
        const base = fl[0].replace(/[?#].*$/, '').replace(/^.*\//, '');
        if (OWN.has(base)) continue;
        where = base + ':' + fl[1];
      } else continue;
      let proc = name.replace(/^async /, '');
      if (proc === 'eval' || proc === 'global code' || proc === 'eval code') proc = '(top level)';
      else if (proc === '' || proc === 'Object.<anonymous>') proc = '(anonymous)';
      kept[kept.length] = [where, proc];
    }
    return kept.reverse();
  }

  return { tokens, rewrite, incomplete, balance, highlight, frames };
});

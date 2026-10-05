/* notebook-lib.js - pure helpers for the notebook tab (notebook.js)
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

/* UMD: a CommonJS module in node, the global ChickenNotebookLib in the
 * page.  No dependencies; the DOM is only touched through the document
 * passed in (renderMarkdown, sanitizeMarkup).
 *
 *   renderMarkdown(src, doc, idPrefix, ids?) -> DocumentFragment
 *   sanitizeMarkup(str, 'html'|'svg', idPrefix) -> DocumentFragment
 *   splitPercent(text) -> {title, cells}  toPercent(nb) -> string
 *   toJson(nb) -> string                  fromJson(text) -> {title, created,
 *                                           modified, cells, warnings}
 *   balance(text) -> {depth, ok, stray, open}
 *   splitForms(text) -> [string]          newId() -> string
 *
 * Untrusted markup is parsed inertly (DOMParser) and rebuilt element by
 * element from an allowlist; nothing is ever serialized back into
 * markup, and no innerHTML is used.  Markdown is built with
 * createElement and text nodes only. */

(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ChickenNotebookLib = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const SVG_NS = 'http://www.w3.org/2000/svg';
  const HTML_NS = 'http://www.w3.org/1999/xhtml';
  const XLINK_NS = 'http://www.w3.org/1999/xlink';

  // ---- URLs

  // a link target: http, https, mailto or a fragment; returns the URL to
  // use, or null.  The URL parser drops tabs and newlines, so
  // "jav&#x09;ascript:" is caught as javascript:.
  function safeHref(u) {
    if (typeof u !== 'string') return null;
    const t = u.trim();
    if (t.startsWith('#')) return /^#[^\s"'<>`]*$/.test(t) ? t : null;
    let url;
    try { url = new URL(t); } catch (e) { return null; }
    if (url.protocol !== 'http:' && url.protocol !== 'https:' && url.protocol !== 'mailto:') return null;
    return url.href;
  }
  const IMG_DATA = /^data:image\/(png|jpeg|gif|webp)(;[a-z0-9=._-]+)*;base64,/i;
  function safeImageSrc(u) {
    if (typeof u !== 'string') return null;
    const t = u.trim(), m = IMG_DATA.exec(t);
    if (!m) return null;
    const b64 = t.slice(m[0].length).replace(/\s+/g, '');
    return /^[A-Za-z0-9+/]*={0,2}$/.test(b64) ? m[0] + b64 : null;
  }
  function slug(s) {
    return String(s).toLowerCase().trim().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s+/g, '-').slice(0, 64) || 'section';
  }

  // ---- markdown (CommonMark-ish subset)

  // Time is linear in the source: no regular expression here may
  // backtrack over a long run (a page reload renders saved cells).

  function trimTail(s) {                 // trailing spaces and tabs
    let e = s.length;
    while (e > 0 && (s[e - 1] === ' ' || s[e - 1] === '\t')) e--;
    return s.slice(0, e);
  }

  const ESCAPABLE = /[!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~]/;

  // Linear in s: brackets are matched once (bracketPairs), a failed
  // search for an emphasis closer is not repeated (noCloser), and text
  // is flushed at each line end.
  function inline(doc, s, out, depth) {
    // out: a node to append to
    depth = depth || 0;
    if (depth > 32) { out.appendChild(doc.createTextNode(s)); return out; }
    let i = 0, text = '', pairs = null;
    const noCloser = {};
    const flush = () => { if (text) { out.appendChild(doc.createTextNode(text)); text = ''; } };
    const n = s.length;
    while (i < n) {
      const c = s[i];
      if (c === '\\' && i + 1 < n && ESCAPABLE.test(s[i + 1])) { text += s[i + 1]; i += 2; continue; }
      if (c === '\\' && s[i + 1] === '\n') { flush(); out.appendChild(doc.createElement('br')); i += 2; continue; }
      if (c === '\n') {
        // two trailing spaces: a hard break.  A text node per line keeps
        // the trailing spaces cheap to find.
        let e = text.length;
        while (e > 0 && text[e - 1] === ' ') e--;
        const hard = text.length - e >= 2;
        text = text.slice(0, e);
        if (hard) { flush(); out.appendChild(doc.createElement('br')); }
        else { text += '\n'; flush(); }
        i++;
        while (s[i] === ' ') i++;
        continue;
      }
      if (c === '`') {
        let j = i; while (s[j] === '`') j++;
        const ticks = s.slice(i, j);
        const end = s.indexOf(ticks, j);
        let e = end;
        while (e >= 0 && s[e + ticks.length] === '`') e = s.indexOf(ticks, e + ticks.length + 1);
        if (e >= 0) {
          flush();
          let code = s.slice(j, e).replace(/\n/g, ' ');
          if (code.length > 2 && code[0] === ' ' && code[code.length - 1] === ' ' && /[^ ]/.test(code))
            code = code.slice(1, -1);
          const el = doc.createElement('code');
          el.textContent = code;
          out.appendChild(el);
          i = e + ticks.length;
          continue;
        }
        text += ticks; i = j; continue;
      }
      if (c === '<') {
        const m = /^<((?:https?|mailto):[^\s<>]*)>/i.exec(s.slice(i));
        if (m) {
          const href = safeHref(m[1]);
          flush();
          if (href) out.appendChild(link(doc, href, m[1])); else out.appendChild(doc.createTextNode(m[1]));
          i += m[0].length;
          continue;
        }
      }
      if (c === 'h' && /^https?:\/\//.test(s.slice(i, i + 8)) && (i === 0 || /[\s(]/.test(s[i - 1]))) {
        const m = /^https?:\/\/[^\s<>]+/.exec(s.slice(i));
        let e = m[0].length;
        while (e > 0 && `.,;:!?'")]`.includes(m[0][e - 1])) e--;
        const u = m[0].slice(0, e), href = safeHref(u);
        if (href) { flush(); out.appendChild(link(doc, href, u)); } else text += u;
        i += u.length;
        continue;
      }
      if (c === '!' && s[i + 1] === '[') {
        const r = linkAt(s, i + 1, pairs || (pairs = bracketPairs(s)));
        if (r) {
          flush();
          const src = safeImageSrc(r.url);
          if (src) {
            const img = doc.createElement('img');
            img.src = src;
            img.alt = r.label;
            if (r.title) img.title = r.title;
            out.appendChild(img);
          } else {
            const sp = doc.createElement('span');
            sp.className = 'md-noimg';
            sp.textContent = (r.label || 'image') + ' (external image not loaded)';
            out.appendChild(sp);
          }
          i = r.end;
          continue;
        }
      }
      if (c === '[') {
        const r = linkAt(s, i, pairs || (pairs = bracketPairs(s)));
        if (r) {
          flush();
          const href = safeHref(r.url);
          if (href) {
            const a = link(doc, href, null);
            if (r.title) a.title = r.title;
            inline(doc, r.label, a, depth + 1);
            out.appendChild(a);
          } else {
            const sp = doc.createElement('span');
            inline(doc, r.label, sp, depth + 1);
            out.appendChild(sp);
          }
          i = r.end;
          continue;
        }
      }
      if (c === '*' || c === '_' || c === '~') {
        const r = emphasisAt(s, i, noCloser);
        if (r) {
          flush();
          const el = doc.createElement(r.tag);
          inline(doc, r.inner, el, depth + 1);
          out.appendChild(el);
          i = r.end;
          continue;
        }
      }
      text += c;
      i++;
    }
    flush();
    return out;
  }

  function link(doc, href, label) {
    const a = doc.createElement('a');
    a.setAttribute('href', href);
    if (!href.startsWith('#')) {
      a.setAttribute('rel', 'noopener noreferrer');
      a.setAttribute('target', '_blank');
    }
    if (label != null) a.textContent = label;
    return a;
  }

  // the end of the code span whose backticks start at s[i], or -1
  function codeSpanEnd(s, i) {
    let j = i; while (s[j] === '`') j++;
    const ticks = s.slice(i, j);
    let e = s.indexOf(ticks, j);
    while (e >= 0 && s[e + ticks.length] === '`') e = s.indexOf(ticks, e + ticks.length + 1);
    return e < 0 ? -1 : e + ticks.length;
  }

  // "[" index -> its "]" index, outside escapes and code spans
  function bracketPairs(s) {
    const pairs = new Map(), open = [];
    for (let j = 0; j < s.length; j++) {
      const c = s[j];
      if (c === '\\') { j++; continue; }
      if (c === '`') {
        const e = codeSpanEnd(s, j);
        if (e >= 0) j = e - 1; else while (s[j + 1] === '`') j++;
        continue;
      }
      if (c === '[') open.push(j);
      else if (c === ']' && open.length) pairs.set(open.pop(), j);
    }
    return pairs;
  }

  // [label](url "title") starting at s[i] === '['
  function linkAt(s, i, pairs) {
    const j = pairs.get(i);
    if (j === undefined || s[j + 1] !== '(') return null;
    const m = /^\(\s*(<[^<>\n]*>|[^\s()]*(?:\([^\s()]*\)[^\s()]*)*)(?:\s+("[^"]*"|'[^']*'))?\s*\)/.exec(s.slice(j + 1));
    if (!m) return null;
    let url = m[1];
    if (url.startsWith('<')) url = url.slice(1, -1);
    return { label: s.slice(i + 1, j), url, title: m[2] ? m[2].slice(1, -1) : '', end: j + 1 + m[0].length };
  }

  // noCloser[d]: a search for a closer d from there on found none
  function emphasisAt(s, i, noCloser) {
    const c = s[i];
    const dbl = s[i + 1] === c;
    if (c === '~' && !dbl) return null;
    const tryDelim = (d, tag) => {
      const after = s[i + d.length];
      if (!after || /\s/.test(after)) return null;
      // _ inside words is not emphasis
      if (c === '_' && i > 0 && /[\p{L}\p{N}]/u.test(s[i - 1])) return null;
      let k = i + d.length;
      if (noCloser[d] !== undefined && k >= noCloser[d]) return null;
      const from = k;
      while ((k = s.indexOf(d, k + 1)) > 0) {
        if (/\s/.test(s[k - 1]) || s[k - 1] === '\\') continue;
        if (d.length === 1 && s[k + 1] === c) {
          // "**" inside "*...*": skip the pair
          if (s[k - 1] !== c) { k++; continue; }
        }
        if (c === '_' && /[\p{L}\p{N}]/u.test(s[k + d.length] || '')) continue;
        return { tag, inner: s.slice(i + d.length, k), end: k + d.length };
      }
      noCloser[d] = from;
      return null;
    };
    if (c === '~') return tryDelim('~~', 'del');
    if (dbl) {
      const r = tryDelim(c + c, 'strong');
      if (r) return r;
    }
    return tryDelim(c, 'em');
  }

  // a fence line: [line, indent, fence, language] or null
  function fenceOf(l) {
    const m = /^( {0,3})(`{3,}|~{3,})(.*)$/.exec(l);
    return m && !m[3].includes('`') ? [l, m[1], m[2], /^\s*(\S*)/.exec(m[3])[1]] : null;
  }
  // an ATX heading: [line, hashes, text] or null
  function headingOf(l) {
    let i = 0;
    while (i < 3 && l[i] === ' ') i++;
    let j = i;
    while (l[j] === '#') j++;
    if (j === i || j - i > 6 || (j < l.length && l[j] !== ' ' && l[j] !== '\t')) return null;
    let t = trimTail(l.slice(j)).replace(/^[ \t]+/, '');
    let e = t.length;
    while (e > 0 && t[e - 1] === '#') e--;    // a closing sequence
    if (e === 0) t = '';
    else if (e < t.length && (t[e - 1] === ' ' || t[e - 1] === '\t')) t = trimTail(t.slice(0, e));
    return [l, l.slice(i, j), t];
  }
  const RE_HR = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
  const RE_LIST = /^( {0,3})([-*+]|\d{1,9}[.)])([ \t]+|$)(.*)$/;
  const RE_QUOTE = /^ {0,3}> ?/;
  const RE_TABLE_DELIM = /^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$/;     // on a trimmed line
  const isDelim = l => l.includes('-') && RE_TABLE_DELIM.test(l.trim());
  const blank = l => /^\s*$/.test(l);

  function splitRow(l) {
    let t = l.trim();
    if (t.startsWith('|')) t = t.slice(1);
    if (t.endsWith('|') && !t.endsWith('\\|')) t = t.slice(0, -1);
    const cells = [];
    let cur = '';
    for (let i = 0; i < t.length; i++) {
      if (t[i] === '\\' && t[i + 1] === '|') { cur += '|'; i++; }
      else if (t[i] === '|') { cells.push(cur.trim()); cur = ''; }
      else cur += t[i];
    }
    cells.push(cur.trim());
    return cells;
  }

  function startsBlock(l) {
    return headingOf(l) || fenceOf(l) || RE_HR.test(l) || RE_QUOTE.test(l) ||
      /^ {0,3}([-*+]|1[.)])[ \t]+\S/.test(l);
  }

  function blocks(doc, lines, out, prefix, ids, depth) {
    let i = 0;
    const n = lines.length;
    while (i < n) {
      const l = lines[i];
      if (blank(l)) { i++; continue; }
      let m;
      if ((m = fenceOf(l))) {
        const fence = m[2], ind = m[1].length;
        const body = [];
        i++;
        while (i < n && !new RegExp('^ {0,3}' + fence[0] + '{' + fence.length + ',}\\s*$').test(lines[i])) {
          body.push(lines[i].replace(new RegExp('^ {0,' + ind + '}'), ''));
          i++;
        }
        i++;
        const pre = doc.createElement('pre'), code = doc.createElement('code');
        if (m[3]) code.setAttribute('data-lang', m[3].slice(0, 32));
        code.textContent = body.join('\n');
        pre.appendChild(code);
        out.appendChild(pre);
        continue;
      }
      if ((m = headingOf(l))) {
        const h = doc.createElement('h' + m[1].length);
        const txt = m[2] || '';
        let id = prefix + slug(txt), k = 2;
        while (ids.has(id)) id = prefix + slug(txt) + '-' + k++;
        ids.add(id);
        h.id = id;
        inline(doc, txt, h);
        out.appendChild(h);
        i++;
        continue;
      }
      if (RE_HR.test(l)) { out.appendChild(doc.createElement('hr')); i++; continue; }
      if (RE_QUOTE.test(l)) {
        const body = [];
        while (i < n && (RE_QUOTE.test(lines[i]) || (!blank(lines[i]) && body.length && !startsBlock(lines[i])))) {
          body.push(lines[i].replace(RE_QUOTE, ''));
          i++;
        }
        const bq = doc.createElement('blockquote');
        if (depth < 16) blocks(doc, body, bq, prefix, ids, depth + 1);
        out.appendChild(bq);
        continue;
      }
      if ((m = RE_LIST.exec(l))) {
        const ordered = /\d/.test(m[2]);
        const list = doc.createElement(ordered ? 'ol' : 'ul');
        if (ordered && parseInt(m[2], 10) !== 1) list.setAttribute('start', String(parseInt(m[2], 10)));
        const baseInd = m[1].length;
        while (i < n) {
          const mm = RE_LIST.exec(lines[i]);
          if (!mm || mm[1].length !== baseInd || /\d/.test(mm[2]) !== ordered) break;
          const contentInd = mm[1].length + mm[2].length + Math.max(1, Math.min(4, mm[3].length));
          const body = [mm[4]];
          i++;
          let sawBlank = false;
          while (i < n) {
            const x = lines[i];
            if (blank(x)) { sawBlank = true; body.push(''); i++; continue; }
            const ind = x.length - x.trimStart().length;
            if (ind >= contentInd || (ind > baseInd && RE_LIST.test(x))) {
              body.push(x.slice(Math.min(ind, contentInd)));
              sawBlank = false;
              i++;
              continue;
            }
            if (!sawBlank && !startsBlock(x) && !RE_LIST.test(x)) { body.push(x.trim()); i++; continue; }
            break;
          }
          while (body.length && blank(body[body.length - 1])) body.pop();
          const li = doc.createElement('li');
          const tight = !body.some(blank);
          if (depth < 16) {
            if (tight && !body.slice(1).some(x => startsBlock(x) || RE_LIST.test(x) || /^ {4}/.test(x))) inline(doc, body.join('\n'), li);
            else {
              blocks(doc, body, li, prefix, ids, depth + 1);
              // tight lists: unwrap single paragraphs
              if (tight && li.firstChild && li.firstChild.nodeName === 'P') {
                const p = li.firstChild;
                while (p.firstChild) li.insertBefore(p.firstChild, p);
                li.removeChild(p);
              }
            }
          }
          list.appendChild(li);
          if (i < n && blank(lines[i - 1] || 'x') && !RE_LIST.test(lines[i])) break;
        }
        out.appendChild(list);
        continue;
      }
      if (/^ {4}/.test(l) || /^\t/.test(l)) {
        const body = [];
        while (i < n && (/^ {4}|^\t/.test(lines[i]) || (blank(lines[i]) && i + 1 < n && /^ {4}|^\t/.test(lines[i + 1])))) {
          body.push(lines[i].replace(/^( {4}|\t)/, ''));
          i++;
        }
        const pre = doc.createElement('pre'), code = doc.createElement('code');
        code.textContent = body.join('\n');
        pre.appendChild(code);
        out.appendChild(pre);
        continue;
      }
      if (l.includes('|') && i + 1 < n && isDelim(lines[i + 1])) {
        const head = splitRow(l);
        const aligns = splitRow(lines[i + 1]).map(d => /^:-+:$/.test(d) ? 'center' : /-:$/.test(d) ? 'right' : /^:/.test(d) ? 'left' : '');
        if (aligns.length === head.length) {
          i += 2;
          const table = doc.createElement('table'), thead = doc.createElement('thead'), tr = doc.createElement('tr');
          head.forEach((h, k) => {
            const th = doc.createElement('th');
            if (aligns[k]) th.style.textAlign = aligns[k];
            inline(doc, h, th);
            tr.appendChild(th);
          });
          thead.appendChild(tr);
          table.appendChild(thead);
          const tbody = doc.createElement('tbody');
          while (i < n && !blank(lines[i]) && lines[i].includes('|')) {
            const row = splitRow(lines[i]);
            const r = doc.createElement('tr');
            for (let k = 0; k < head.length; k++) {
              const td = doc.createElement('td');
              if (aligns[k]) td.style.textAlign = aligns[k];
              inline(doc, row[k] || '', td);
              r.appendChild(td);
            }
            tbody.appendChild(r);
            i++;
          }
          table.appendChild(tbody);
          const wrap = doc.createElement('div');
          wrap.className = 'md-table';
          wrap.appendChild(table);
          out.appendChild(wrap);
          continue;
        }
      }
      // paragraph
      const para = [];
      while (i < n && !blank(lines[i]) && !(para.length && startsBlock(lines[i])) &&
             !(para.length && lines[i].includes('|') && i + 1 < n && isDelim(lines[i + 1]))) {
        para.push(lines[i]);
        i++;
      }
      if (!para.length) { para.push(lines[i]); i++; }
      const p = doc.createElement('p');
      inline(doc, trimTail(para.join('\n').replace(/^ +/, '')), p);
      out.appendChild(p);
    }
  }

  // ids: heading ids taken (by other cells), and given to the new ones
  function renderMarkdown(src, doc, idPrefix, ids) {
    const frag = doc.createDocumentFragment();
    const prefix = idPrefix || '';
    const lines = String(src == null ? '' : src).replace(/\r\n?/g, '\n').split('\n');
    blocks(doc, lines, frag, prefix, ids || new Set(), 0);
    // "#slug" links go to the headings, whose ids carry the prefix
    for (const a of frag.querySelectorAll('a[href^="#"]'))
      a.setAttribute('href', '#' + prefix + a.getAttribute('href').slice(1));
    return frag;
  }

  // ---- markup sanitizer

  const HTML_OK = new Set(('a abbr b bdi bdo blockquote br caption cite code col colgroup dd del details dfn div dl dt em ' +
    'figcaption figure h1 h2 h3 h4 h5 h6 hr i img ins kbd li mark meter ol p pre progress q rp rt ruby s samp small ' +
    'span strong sub summary sup table tbody td tfoot th thead time tr u ul var wbr section article header footer ' +
    'aside nav main hgroup address center font big tt strike').split(' '));
  // dropped with everything inside
  const HTML_DROP = new Set(('script style template noscript iframe frame frameset object embed applet form input button ' +
    'select textarea option optgroup datalist output label fieldset legend dialog math link meta base title head ' +
    'audio video source track picture canvas map area portal slot noembed noframes xmp plaintext marquee svg:image').split(' '));
  const SVG_OK = new Set(('svg g defs symbol use path rect circle ellipse line polyline polygon text tspan textPath ' +
    'title desc linearGradient radialGradient stop clipPath mask pattern marker filter a switch ' +
    'feBlend feColorMatrix feComponentTransfer feComposite feDiffuseLighting feDisplacementMap feDistantLight ' +
    'feDropShadow feFlood feFuncA feFuncB feFuncG feFuncR feGaussianBlur feMerge feMergeNode feMorphology feOffset ' +
    'fePointLight feSpecularLighting feSpotLight feTile feTurbulence').split(' '));
  const HTML_ATTRS = {
    '*': ['title', 'lang', 'dir', 'id', 'style', 'role', 'align', 'width', 'height', 'hidden'],
    a: ['href'], img: ['src', 'alt'], td: ['colspan', 'rowspan', 'valign'], th: ['colspan', 'rowspan', 'scope', 'valign'],
    col: ['span'], colgroup: ['span'], ol: ['start', 'reversed', 'type'], ul: ['type'], li: ['value'],
    progress: ['value', 'max'], meter: ['value', 'min', 'max', 'low', 'high', 'optimum'], time: ['datetime'],
    details: ['open'], table: ['border', 'cellpadding', 'cellspacing'], font: ['color', 'size'], abbr: [], dfn: [],
  };
  const SVG_ATTRS = new Set(('id style x y x1 y1 x2 y2 cx cy r rx ry fx fy fr width height d points transform viewBox ' +
    'preserveAspectRatio fill fill-opacity fill-rule stroke stroke-width stroke-linecap stroke-linejoin ' +
    'stroke-dasharray stroke-dashoffset stroke-opacity stroke-miterlimit opacity color font-family font-size ' +
    'font-weight font-style font-variant text-anchor dominant-baseline alignment-baseline baseline-shift ' +
    'letter-spacing word-spacing text-decoration writing-mode dx dy rotate textLength lengthAdjust startOffset ' +
    'offset stop-color stop-opacity gradientUnits gradientTransform spreadMethod patternUnits patternContentUnits ' +
    'patternTransform clipPathUnits maskUnits maskContentUnits clip-path clip-rule mask marker-start marker-mid ' +
    'marker-end markerWidth markerHeight markerUnits refX refY orient filter filterUnits primitiveUnits in in2 ' +
    'result stdDeviation mode operator k1 k2 k3 k4 type tableValues slope intercept amplitude exponent ' +
    'baseFrequency numOctaves seed stitchTiles scale xChannelSelector yChannelSelector flood-color flood-opacity ' +
    'lighting-color radius surfaceScale diffuseConstant specularConstant specularExponent kernelUnitLength azimuth ' +
    'elevation pointsAtX pointsAtY pointsAtZ limitingConeAngle z display visibility overflow vector-effect ' +
    'shape-rendering text-rendering image-rendering paint-order pathLength version role systemLanguage ' +
    'aria-label aria-hidden aria-labelledby aria-describedby tabindex href').split(' '));
  const BAD_CSS = /url\s*\(|image-set|expression|@import|-moz-binding|behavior|javascript:|\\|<|>/i;

  function cleanStyle(v, prefix) {
    const keep = [];
    for (const decl of String(v).split(';')) {
      const d = decl.trim();
      if (!d || !/^[-a-zA-Z]+\s*:/.test(d)) continue;
      const fragOnly = d.replace(/url\(\s*(['"]?)#([\w.:-]+)\1\s*\)/g, (_, q, id) => 'URLFRAG' + id + 'URLFRAG');
      if (BAD_CSS.test(fragOnly)) continue;
      keep.push(fragOnly.replace(/URLFRAG([\w.:-]+)URLFRAG/g, (_, id) => 'url(#' + prefix + id + ')'));
    }
    return keep.join('; ');
  }
  const fixId = (prefix, id) => prefix + String(id).replace(/[^\w.:-]/g, '_').slice(0, 64);
  // the attributes that name ids: the markup's own, never the page's
  const ID_REFS = new Set(('aria-labelledby aria-describedby aria-owns aria-controls aria-activedescendant ' +
    'aria-details aria-flowto aria-errormessage').split(' '));

  function cleanAttr(el, name, value, svg, prefix) {
    // returns the value to set, or null to drop it
    if (/^on/i.test(name) || name === 'srcdoc' || name === 'formaction' || name === 'class' ||
        name.includes(':') && name !== 'xlink:href') return null;
    const v = String(value);
    if (name === 'style') { const s = cleanStyle(v, prefix); return s || null; }
    if (name === 'id') return fixId(prefix, v);
    // focusable or not, but never ahead of the page in the Tab order
    if (name === 'tabindex') return Number(v) < 0 ? '-1' : '0';
    if (ID_REFS.has(name))
      return v.split(/\s+/).filter(Boolean).map(x => fixId(prefix, x)).join(' ');
    if (name === 'href' || name === 'xlink:href') {
      const tag = el.localName;
      const h = safeHref(v);
      if (!h) return null;
      if (h.startsWith('#')) return '#' + fixId(prefix, h.slice(1));
      return tag === 'a' ? h : null;      // use, textPath, gradients: fragments only
    }
    if (name === 'src') return el.localName === 'img' && !svg ? safeImageSrc(v) : null;
    if (/url\s*\(/i.test(v)) {
      const m = /^\s*url\(\s*(['"]?)#([\w.:-]+)\1\s*\)\s*(.*)$/.exec(v);
      if (!m || /url\s*\(/i.test(m[3])) return null;
      return 'url(#' + fixId(prefix, m[2]) + ')' + (m[3] ? ' ' + m[3] : '');
    }
    if (/javascript:|data:|vbscript:/i.test(v.replace(/[\s\u0000-\u001f]/g, ''))) return null;
    return v;
  }

  function rebuild(doc, src, parent, prefix, depth) {
    if (depth > 64) return;
    for (let n = src.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 3 || n.nodeType === 4) {     // text, CDATA
        parent.appendChild(doc.createTextNode(n.nodeValue));
        continue;
      }
      if (n.nodeType !== 1) continue;
      const ns = n.namespaceURI;
      const svg = ns === SVG_NS;
      const tag = svg ? n.localName : String(n.localName).toLowerCase();
      let ok;
      if (svg) ok = SVG_OK.has(tag);
      else if (ns === HTML_NS || ns === null) ok = HTML_OK.has(tag) && !HTML_DROP.has(tag);
      else ok = false;
      if (!ok) {
        // unknown harmless wrappers keep their (sanitized) content
        const drop = svg || ns !== HTML_NS || HTML_DROP.has(tag) || /^(script|style|iframe|object|embed)$/i.test(tag);
        if (!drop) rebuild(doc, n, parent, prefix, depth + 1);
        continue;
      }
      const el = svg ? doc.createElementNS(SVG_NS, tag) : doc.createElement(tag);
      const allowed = svg ? null : new Set([...(HTML_ATTRS['*']), ...(HTML_ATTRS[tag] || [])]);
      for (const a of [...n.attributes]) {
        let name = a.namespaceURI === XLINK_NS && a.localName === 'href' ? 'xlink:href' : a.name;
        const lname = svg ? name : name.toLowerCase();
        const isAria = /^aria-[a-z]+$/.test(lname);
        if (svg ? !(SVG_ATTRS.has(lname) || isAria || lname === 'xlink:href') : !(allowed.has(lname) || isAria)) continue;
        const v = cleanAttr(n, lname, a.value, svg, prefix);
        if (v == null) continue;
        try { el.setAttribute(lname === 'xlink:href' ? 'href' : lname, v); } catch (e) { /* invalid name */ }
      }
      if (tag === 'a' && el.hasAttribute('href') && !el.getAttribute('href').startsWith('#')) {
        el.setAttribute('rel', 'noopener noreferrer');
        el.setAttribute('target', '_blank');
      }
      if (tag === 'img' && !el.hasAttribute('src')) {
        const alt = n.getAttribute('alt');
        if (alt) parent.appendChild(doc.createTextNode(alt));
        continue;
      }
      rebuild(doc, n, el, prefix, depth + 1);
      parent.appendChild(el);
    }
  }

  function sanitizeMarkup(str, kind, idPrefix, doc) {
    doc = doc || document;
    const prefix = idPrefix || '';
    const frag = doc.createDocumentFragment();
    const P = new (doc.defaultView && doc.defaultView.DOMParser || DOMParser)();
    if (kind === 'svg') {
      const d = P.parseFromString(String(str), 'image/svg+xml');
      if (d.getElementsByTagName('parsererror').length || !d.documentElement || d.documentElement.namespaceURI !== SVG_NS)
        throw new Error('the SVG is not well-formed XML');
      const holder = doc.createElementNS(SVG_NS, 'g');
      const wrap = d.createElement('x');      // so that rebuild sees the root as a child
      wrap.appendChild(d.documentElement);
      rebuild(doc, wrap, holder, prefix, 0);
      while (holder.firstChild) frag.appendChild(holder.firstChild);
      return frag;
    }
    const d = P.parseFromString('<!doctype html><html><head></head><body>' + String(str), 'text/html');
    rebuild(doc, d.body, frag, prefix, 0);
    return frag;
  }

  // ---- Scheme text scanning

  // Calls f(kind, i) for parens outside strings, comments and chars;
  // returns the scanner state at the end.
  function scan(text, f) {
    let depth = 0, stray = 0, inStr = false, inBar = false, block = 0;
    const n = text.length;
    for (let i = 0; i < n; i++) {
      const c = text[i];
      if (block) {
        if (c === '|' && text[i + 1] === '#') { block--; i++; }
        else if (c === '#' && text[i + 1] === '|') { block++; i++; }
        continue;
      }
      if (inStr) { if (c === '\\') i++; else if (c === '"') inStr = false; continue; }
      if (inBar) { if (c === '\\') i++; else if (c === '|') inBar = false; continue; }
      if (c === '"') inStr = true;
      else if (c === '|') inBar = true;
      else if (c === ';') { const j = text.indexOf('\n', i); i = j < 0 ? n : j - 1; if (f) f('comment', i); }
      else if (c === '#' && text[i + 1] === '|') { block = 1; i++; }
      else if (c === '#' && text[i + 1] === '\\') { i += 2; }
      else if (c === '(' || c === '[') { depth++; if (f) f('open', i); }
      else if (c === ')' || c === ']') { if (depth) depth--; else stray++; if (f) f('close', i); }
      else if (c === '\n' && f) f('newline', i, depth);
    }
    return { depth, stray, inStr: inStr || inBar, block: block > 0 };
  }

  function balance(text) {
    const s = scan(String(text || ''));
    return { depth: s.depth, stray: s.stray, open: s.inStr || s.block, ok: !s.depth && !s.stray && !s.inStr && !s.block };
  }

  // one string per blank-line separated group of top-level forms
  function splitForms(text) {
    const t = String(text).replace(/\r\n?/g, '\n');
    const out = [];
    let start = 0, lineStart = 0;
    scan(t, (kind, i, depth) => {
      if (kind !== 'newline' || depth) return;
      if (/^[ \t]*$/.test(t.slice(lineStart, i)) && t.slice(start, lineStart).trim()) {
        out.push(t.slice(start, lineStart));
        start = i + 1;
      }
      lineStart = i + 1;
    });
    const rest = t.slice(start);
    if (rest.trim()) out.push(rest);
    return out.map(trimBlankLines).filter(s => s.trim());
  }
  function trimBlankLines(s) { return s.replace(/^(?:[ \t]*\n)+/, '').replace(/(?:\n[ \t]*)+$/, '').replace(/[ \t]+$/, ''); }

  // ---- ids

  let idSeq = 0;
  function newId() {
    let r = '';
    try {
      const b = new Uint8Array(6);
      (globalThis.crypto || self.crypto).getRandomValues(b);
      for (const x of b) r += (x % 36).toString(36);
    } catch (e) { r = Math.random().toString(36).slice(2, 8); }
    return 'c' + r + (++idSeq).toString(36);
  }
  const ID_RE = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;

  // ---- .scm percent format

  const MARK = /^;;\s?%%(.*)$/;
  // a line of a cell that would read as a marker, or as such a line
  // escaped, is written with one more backslash after the ";;"
  const escapeMark = l => l.replace(/^(;;\s?)(\\*%%)/, '$1\\$2');
  const unescapeMark = l => l.replace(/^(;;\s?)\\(\\*%%)/, '$1$2');

  function splitPercent(text) {
    const lines = String(text).replace(/^﻿/, '').replace(/\r\n?/g, '\n').split('\n');
    let title = '';
    if (!lines.some(l => MARK.test(l))) {
      const cells = [];
      const forms = splitForms(lines.join('\n'));
      // a leading notebook header is not a cell
      if (forms.length && /^(;;[^\n]*\n?)+$/.test(forms[0] + '\n')) {
        const m = /^;; CHICKEN notebook: (.*)$/m.exec(forms[0]);
        if (m) { title = m[1].trim(); forms.shift(); }
      }
      for (const f of forms) cells.push({ id: newId(), type: 'code', source: f });
      return { title, cells };
    }
    const cells = [];
    let cur = null;
    const pre = [];
    const close = () => {
      if (!cur) return;
      let src = cur.lines;
      if (cur.type === 'markdown') src = src.map(l => l.replace(/^;; ?/, ''));
      cur.source = trimBlankLines(src.join('\n'));
      delete cur.lines;
      cells.push(cur);
    };
    for (const l of lines) {
      const m = MARK.exec(l);
      if (m) {
        close();
        cur = { id: newId(), type: /\[\s*markdown\s*\]/i.test(m[1]) ? 'markdown' : 'code', lines: [] };
        continue;
      }
      if (cur) cur.lines.push(unescapeMark(l)); else pre.push(l);
    }
    close();
    const head = pre.join('\n');
    const mt = /^;; CHICKEN notebook: (.*)$/m.exec(head);
    if (mt) title = mt[1].trim();
    const rest = trimBlankLines(pre.filter(l => !/^;; (-\*-.*-\*-|CHICKEN notebook: .*)$/.test(l)).join('\n'));
    if (rest.trim()) cells.unshift({ id: newId(), type: 'code', source: rest });
    return { title, cells };
  }

  function toPercent(nb) {
    const out = [';; -*- mode: scheme -*-', ';; CHICKEN notebook: ' + String(nb.title || 'Untitled').replace(/\n/g, ' '), ''];
    for (const c of nb.cells) {
      if (c.type === 'markdown') {
        out.push(';; %% [markdown]');
        for (const l of String(c.source).split('\n')) out.push(l ? escapeMark(';; ' + l) : ';;');
      } else {
        out.push(';; %%');
        out.push(String(c.source).split('\n').map(escapeMark).join('\n'));
      }
      out.push('');
    }
    return out.join('\n');
  }

  // ---- JSON format

  const MIMES = new Set(['text/plain', 'text/html', 'image/svg+xml', 'text/markdown',
                         'image/png', 'image/jpeg', 'image/gif', 'image/webp']);
  const LIMITS = { file: 5 * 1024 * 1024, cells: 5000, source: 1024 * 1024 };
  const str = (x, max) => typeof x === 'string' && x.length <= (max || Infinity);
  const strOrNull = x => x === null || x === undefined ? null : typeof x === 'string' ? x.slice(0, 4096) : null;

  function cleanError(e) {
    if (!e || typeof e !== 'object' || typeof e.text !== 'string') return null;
    const chain = Array.isArray(e.chain) ? e.chain.slice(0, 200).filter(f => f && typeof f === 'object' && typeof f.where === 'string')
      .map(f => ({ where: f.where.slice(0, 200), proc: strOrNull(f.proc), form: strOrNull(f.form) })) : [];
    return {
      text: e.text.slice(0, 65536),
      kind: Array.isArray(e.kind) ? e.kind.filter(k => typeof k === 'string').slice(0, 16).map(k => k.slice(0, 64)) : [],
      location: strOrNull(e.location),
      form: Number.isInteger(e.form) && e.form > 0 ? e.form : e.form === 'print' ? 'print' : null,
      line: Number.isInteger(e.line) && e.line > 0 ? e.line : null,
      chain,
    };
  }
  function cleanOutput(o) {
    if (!o || typeof o !== 'object') return null;
    switch (o.k) {
    case 'stream':
      return (o.name === 'stdout' || o.name === 'stderr' || o.name === 'stdin') && str(o.text)
        ? { k: 'stream', name: o.name, text: o.text } : null;
    case 'value':                       // text null: "; no values"
      return o.text === null || str(o.text) ? { k: 'value', text: o.text } : null;
    case 'note':
      return str(o.text, 4096) ? Object.assign({ k: 'note', text: o.text }, o.bad === true ? { bad: true } : {}) : null;
    case 'display':
      return MIMES.has(o.mime) && str(o.data) ? { k: 'display', mime: o.mime, data: o.data, id: typeof o.id === 'string' ? o.id.slice(0, 256) : null } : null;
    case 'error': { const e = cleanError(o.error); return e ? { k: 'error', error: e } : null; }
    default: return null;
    }
  }
  function cleanDate(x) { return typeof x === 'string' && x.length < 40 && !isNaN(Date.parse(x)) ? x : null; }

  // a code cell's status is saved when it did not succeed
  const FAILED = new Set(['error', 'interrupted']);

  function toJson(nb) {
    return JSON.stringify({
      format: 'chicken-notebook',
      version: 1,
      meta: { title: nb.title || 'Untitled', created: nb.created || null, modified: nb.modified || null,
              chicken: nb.chicken || null, arch: nb.arch || null },
      cells: nb.cells.map(c => {
        const o = { id: c.id, type: c.type, source: c.source };
        if (c.type === 'code' && Number.isInteger(c.count)) o.count = c.count;
        if (c.type === 'code' && FAILED.has(c.status)) o.status = c.status;
        if (c.outputs && c.outputs.length) o.outputs = c.outputs;
        return o;
      }),
    });
  }

  function fromJson(text) {
    if (typeof text !== 'string') throw new Error('not a notebook');
    if (text.length > LIMITS.file) throw new Error('the file is larger than 5 MB');
    let j;
    try { j = JSON.parse(text); } catch (e) { throw new Error('not valid JSON: ' + e.message); }
    if (!j || typeof j !== 'object' || j.format !== 'chicken-notebook' || !Array.isArray(j.cells))
      throw new Error('not a CHICKEN notebook (format "chicken-notebook" expected)');
    const warnings = [];
    if (typeof j.version === 'number' && j.version > 1)
      warnings.push('This notebook was saved by a newer version (format ' + j.version + '); it was imported as far as possible.');
    if (j.cells.length > LIMITS.cells) throw new Error('more than ' + LIMITS.cells + ' cells');
    const meta = j.meta && typeof j.meta === 'object' ? j.meta : {};
    const seen = new Set();
    const cells = [];
    let dropped = 0;
    for (const c of j.cells) {
      if (!c || typeof c !== 'object' || (c.type !== 'code' && c.type !== 'markdown') || !str(c.source, LIMITS.source)) { dropped++; continue; }
      let id = typeof c.id === 'string' && ID_RE.test(c.id) && !seen.has(c.id) ? c.id : newId();
      while (seen.has(id)) id = newId();
      seen.add(id);
      const cell = { id, type: c.type, source: c.source };
      if (c.type === 'code' && Number.isInteger(c.count) && c.count > 0 && c.count < 1e9) cell.count = c.count;
      if (c.type === 'code' && FAILED.has(c.status)) cell.status = c.status;
      if (Array.isArray(c.outputs)) {
        const outs = c.outputs.slice(0, 1000).map(cleanOutput).filter(Boolean);
        if (outs.length) cell.outputs = outs;
      }
      cells.push(cell);
    }
    if (dropped) warnings.push(dropped + ' invalid cell' + (dropped > 1 ? 's were' : ' was') + ' skipped.');
    return {
      title: typeof meta.title === 'string' ? meta.title.slice(0, 200) : '',
      created: cleanDate(meta.created), modified: cleanDate(meta.modified),
      cells, warnings,
    };
  }

  return { renderMarkdown, sanitizeMarkup, splitPercent, toPercent, toJson, fromJson, balance, splitForms,
           newId, safeHref, safeImageSrc, slug, LIMITS };
});

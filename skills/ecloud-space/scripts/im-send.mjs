#!/usr/bin/env node
/*
 * Send one message through the desktop client's web IM page.
 *
 * Prerequisite: the client is running with
 *   --remote-debugging-port=9222 --remote-allow-origins=*
 * and is logged in. This script drives the page with CDP/DOM only: no Windows
 * mouse or keyboard input is synthesized. It is intentionally limited to the
 * named chat and requires a unique message text from the caller.
 *
 * Research/opt-in helper for the ecloud-space skill.
 */
const PORT = process.env.CEF_PORT || '9222';

const args = process.argv.slice(2);
const arg = (name, fallback = null) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : fallback;
};
const has = (name) => args.includes(name);

const TO = arg('--to', '文件传输助手');
const TEXT = arg('--text', '');
const ALLOW_ANY = has('--allow-any-chat');
const DRY_RUN = has('--dry-run');
const LIST = has('--list');

if (!TEXT && !LIST) {
  console.error('usage: im-send.mjs (--to <chat name> --text <message> [--allow-any-chat] [--dry-run]) | --list');
  process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function listPages() {
  const res = await fetch(`http://127.0.0.1:${PORT}/json/list`);
  return res.json();
}

class Cdp {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.id = 0;
    this.pending = new Map();
    this.ready = new Promise((resolve, reject) => {
      this.ws.addEventListener('open', () => resolve());
      this.ws.addEventListener('error', reject);
    });
    this.ws.addEventListener('message', (ev) => {
      let msg;
      try { msg = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data)); } catch { return; }
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.error.message));
        else resolve(msg.result);
      }
    });
  }
  async send(method, params = {}, timeoutMs = 20000) {
    await this.ready;
    const id = this.id++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`timeout ${method}`));
        }
      }, timeoutMs);
    });
  }
}

async function main() {
  let pages;
  try {
    pages = await listPages();
  } catch (e) {
    console.error(JSON.stringify({ ok: false, reason: 'debug-port-unavailable', error: String(e) }));
    process.exit(3);
  }
  const page = pages.find((p) => p.type === 'page' && String(p.url).includes('#/im'));
  if (!page) {
    console.error(JSON.stringify({
      ok: false,
      reason: 'im-page-not-found',
      hint: 'Start the desktop client with --remote-debugging-port=9222 and log in.',
    }));
    process.exit(4);
  }

  const cdp = new Cdp(page.webSocketDebuggerUrl);
  // The first evaluate on a background CEF page can time out; warm up read-only.
  for (let i = 0; i < 3; i++) {
    try {
      await cdp.send('Runtime.evaluate', { expression: '1+1', returnByValue: true }, 12000);
      break;
    } catch {
      await sleep(700);
    }
  }

  if (LIST) {
    const expr = `(() => {
      const items = [...document.querySelectorAll('[id^="u"],[id^="g"]')].filter(e => /^[ug]\\d+$/.test(e.id));
      return items.map(e => {
        const n = e.querySelector('.ellipsis.c-dark');
        const text = (e.innerText || '').split('\\n').map(s => s.trim()).filter(Boolean);
        return {
          id: e.id,
          name: n ? n.textContent.trim() : null,
          preview: text.length > 1 ? text[text.length - 2] : null,
          selected: e.className.split(/\\s+/).some(c => c.startsWith('active')),
        };
      }).filter(x => x.name);
    })()`;
    let out = null;
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const r = await cdp.send('Runtime.evaluate', { expression: expr, returnByValue: true }, 15000);
        out = r.result?.value;
        break;
      } catch {
        await sleep(700);
      }
    }
    if (!out) {
      console.log(JSON.stringify({ ok: false, reason: 'list-timeout' }));
      process.exit(5);
    }
    console.log(JSON.stringify({ ok: true, chats: out }));
    process.exit(0);
  }

  const expression = `
(async () => {
  const name = ${JSON.stringify(TO)};
  const text = ${JSON.stringify(TEXT)};
  const allowAny = ${ALLOW_ANY ? 'true' : 'false'};
  const dryRun = ${DRY_RUN ? 'true' : 'false'};
  const wait = (ms) => new Promise(r => setTimeout(r, ms));
  window.__dshImSend = { started: true, at: Date.now(), state: 'started' };

  const items = [...document.querySelectorAll('[id^="u"],[id^="g"]')]
    .filter(e => /^[ug]\\d+$/.test(e.id));
  let item = items.find(e => {
    const n = e.querySelector('.ellipsis.c-dark');
    return n && n.textContent.trim() === name;
  });
  if (!item && name === '文件传输助手') item = document.getElementById('u19999');
  if (!item) { window.__dshImSend.state = 'chat-not-found'; return { ok:false, reason:'chat-not-found', chat:name }; }
  if (!allowAny && name !== '文件传输助手') {
    window.__dshImSend.state = 'not-allowed';
    return { ok:false, reason:'not-allowed', chat:name, hint:'pass --allow-any-chat after an explicit user request' };
  }

  item.click();
  await wait(900);
  const active = item.className.split(/\\s+/).some(c => c.startsWith('active'));
  const header = [...document.querySelectorAll('*')].find(e => {
    const r = e.getBoundingClientRect();
    return r.y < 60 && r.x > 280 && r.height > 0 && (e.textContent || '').trim() === name;
  });
  if (!active && !header) {
    window.__dshImSend.state = 'chat-not-selected';
    return { ok:false, reason:'chat-not-selected', chat:name, cls:item.className };
  }

  const ed = [...document.querySelectorAll('[contenteditable=true]')].find(e => {
    const r = e.getBoundingClientRect();
    return r.height > 0 && r.height < 120 && r.y > 0;
  });
  if (!ed) { window.__dshImSend.state = 'no-editor'; return { ok:false, reason:'no-editor', chat:name }; }

  ed.focus();
  ed.innerHTML = '';
  ed.dispatchEvent(new InputEvent('input', { bubbles:true, inputType:'deleteContentBackward' }));
  await wait(150);
  document.execCommand('insertText', false, text);
  await wait(250);
  const inserted = (ed.innerText || '').includes(text);
  if (!inserted) {
    window.__dshImSend.state = 'insert-failed';
    return { ok:false, reason:'insert-failed', chat:name, draft:ed.innerText };
  }
  if (dryRun) {
    ed.innerHTML = '';
    window.__dshImSend.state = 'dry-run';
    return { ok:true, dryRun:true, chat:name, header:!!header, active };
  }

  ed.dispatchEvent(new KeyboardEvent('keydown', {
    key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true, cancelable:true,
  }));
  await wait(1800);
  const draft = ed.innerText || '';
  const body = document.body.innerText;
  const ok = draft.trim() === '' && body.includes(text);
  window.__dshImSend.state = ok ? 'done' : 'uncertain';
  window.__dshImSend.draft = draft;
  return { ok, chat:name, text, draft, active, header:!!header };
})()
`;

  let result;
  try {
    const r = await cdp.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
      userGesture: true,
    }, 30000);
    result = r.result?.value;
  } catch (e) {
    // Do not retry a send: read the marker to see whether the page finished.
    let marker = null;
    try {
      const m = await cdp.send('Runtime.evaluate', {
        expression: 'window.__dshImSend || null',
        returnByValue: true,
      }, 8000);
      marker = m.result?.value;
    } catch { }
    console.log(JSON.stringify({ ok: false, reason: 'evaluate-timeout', error: String(e), marker }));
    process.exit(5);
  }
  console.log(JSON.stringify(result));
  if (!result || !result.ok) process.exit(6);
  process.exit(0);
}

main().catch((e) => {
  console.error(JSON.stringify({ ok: false, reason: 'unexpected', error: String(e) }));
  process.exit(1);
});

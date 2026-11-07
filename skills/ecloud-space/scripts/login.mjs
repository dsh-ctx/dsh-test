#!/usr/bin/env node
/*
 * Interactive login helper for the ecloud-space skill.
 *
 * Opens a dedicated Microsoft Edge profile, lets the human log in to
 * https://www.ecpan.cn/web/yunpan/, reads the session cookies through the
 * Chrome DevTools Protocol, and writes %USERPROFILE%\.dsh\ecloud\session.json.
 *
 * It never drives the Windows UI: the human uses the browser normally and this
 * script only talks to Edge's local debugging endpoint.
 */
import { spawn } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const HOME = os.homedir();
const DSH_DIR = path.join(HOME, '.dsh', 'ecloud');
const PROFILE_DIR = path.join(DSH_DIR, 'browser');
const SESSION_FILE = path.join(DSH_DIR, 'session.json');

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : fallback;
};
const has = (name) => args.includes(name);

const PORT = Number(flag('--port', '9333'));
const TIMEOUT_MS = Number(flag('--timeout', '600')) * 1000;
const START_URL = flag('--url', 'https://www.ecpan.cn/web/yunpan/');
const HEADLESS = has('--headless');
const KEEP_OPEN = has('--keep-open');

const EDGE_CANDIDATES = [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  process.env['PROGRAMFILES(X86)'] && path.join(process.env['PROGRAMFILES(X86)'], 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
  process.env.PROGRAMFILES && path.join(process.env.PROGRAMFILES, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
].filter(Boolean);

const EDGE = EDGE_CANDIDATES.find((p) => existsSync(p));
if (!EDGE) {
  console.error('Microsoft Edge not found. Install Edge, or use: ecloud.ps1 login -Cookie "<cookie>"');
  process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(...a);

async function httpJson(url, init) {
  const res = await fetch(url, init);
  if (!res.ok) throw new Error(`HTTP ${res.status} ${url}`);
  return res.json();
}

async function waitForVersion(deadline) {
  while (Date.now() < deadline) {
    try {
      return await httpJson(`http://127.0.0.1:${PORT}/json/version`);
    } catch {
      await sleep(300);
    }
  }
  return null;
}

class Cdp {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.nextId = 1;
    this.pending = new Map();
    this.closed = false;
    this._opened = new Promise((resolve, reject) => {
      this.ws.addEventListener('open', () => resolve());
      this.ws.addEventListener('error', (e) => reject(e));
    });
    this.ws.addEventListener('message', (ev) => {
      let msg;
      try { msg = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data)); } catch { return; }
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(`${msg.error.message || 'CDP error'} (${msg.error.code})`));
        else resolve(msg.result);
      }
    });
    this.ws.addEventListener('close', () => {
      this.closed = true;
      for (const { reject } of this.pending.values()) reject(new Error('CDP connection closed'));
      this.pending.clear();
    });
  }
  async open() { await this._opened; return this; }
  send(method, params = {}) {
    if (this.closed) return Promise.reject(new Error('CDP connection closed'));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`CDP timeout: ${method}`));
        }
      }, 15000);
    });
  }
  close() { try { this.ws.close(); } catch { } }
}

function cookieMap(cookies) {
  const m = new Map();
  for (const c of cookies) {
    const domain = c.domain || '';
    // Only the Ecpan host: avoid picking a same-named cookie from another site.
    if (!/(^|\.)ecpan\.cn$/i.test(domain)) continue;
    if (c.name && c.value) m.set(c.name, c.value);
  }
  return m;
}

function buildCookieString(map) {
  const order = ['sid', 'timeStamp', 'token', 'userId', 'orgId'];
  return order.filter((k) => map.has(k)).map((k) => `${k}=${map.get(k)}`).join('; ');
}

async function main() {
  await mkdir(PROFILE_DIR, { recursive: true });

  const deadline = Date.now() + TIMEOUT_MS;
  let version = await waitForVersion(2000);
  let child = null;

  if (!version) {
    const edgeArgs = [
      `--remote-debugging-port=${PORT}`,
      `--user-data-dir=${PROFILE_DIR}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-features=msEdgeSidebarV2,msEdgeWorkspaces',
      START_URL,
    ];
    if (HEADLESS) edgeArgs.unshift('--headless=new');
    log(`Launching Edge with profile: ${PROFILE_DIR}`);
    child = spawn(EDGE, edgeArgs, { stdio: 'ignore', windowsHide: !HEADLESS });
    version = await waitForVersion(Date.now() + 30000);
    if (!version) {
      if (child) child.kill();
      console.error('Edge debugging endpoint did not start. Close other Edge instances using this profile and retry.');
      process.exit(1);
    }
  } else {
    log('Reusing an existing Edge debugging endpoint on port ' + PORT);
  }

  // Find (or create) a page target.
  let targets = await httpJson(`http://127.0.0.1:${PORT}/json/list`);
  let page = targets.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
  if (!page) {
    try {
      page = await httpJson(`http://127.0.0.1:${PORT}/json/new?${encodeURIComponent(START_URL)}`, { method: 'PUT' });
    } catch {
      page = await httpJson(`http://127.0.0.1:${PORT}/json/new?${encodeURIComponent(START_URL)}`);
    }
  }
  if (!page || !page.webSocketDebuggerUrl) {
    console.error('No debuggable page target available.');
    process.exit(1);
  }

  const cdp = await new Cdp(page.webSocketDebuggerUrl).open();
  await cdp.send('Network.enable');
  await cdp.send('Page.enable');
  try { await cdp.send('Page.navigate', { url: START_URL }); } catch { }

  log('Log in to 移动云空间 in the Edge window (password / SMS / QR as available).');
  log('Waiting for the session cookies...');

  let best = new Map();
  let lastNotice = 0;
  while (Date.now() < deadline) {
    let cookies = [];
    try {
      const r = await cdp.send('Storage.getCookies', {});
      cookies = r.cookies || [];
    } catch {
      try {
        const r = await cdp.send('Network.getAllCookies', {});
        cookies = r.cookies || [];
      } catch { }
    }
    const map = cookieMap(cookies);
    if (map.size > best.size) best = map;
    const hasLogin = map.has('sid') && map.has('userId') && map.has('orgId');
    const hasIm = map.has('timeStamp') && map.has('token');
    if (hasLogin && (hasIm || Date.now() > deadline - (TIMEOUT_MS - 20000))) {
      const cookie = buildCookieString(map);
      if (!cookie.includes('sid=')) break;
      const session = {
        baseUrl: 'https://www.ecpan.cn',
        cookie,
        sid: map.get('sid') || null,
        timeStamp: map.get('timeStamp') || null,
        token: map.get('token') || null,
        userId: map.get('userId') || null,
        orgId: map.get('orgId') || null,
        usn: null,
        userName: null,
        im: Boolean(map.get('timeStamp') && map.get('token')),
        savedAt: new Date().toISOString(),
      };
      await mkdir(DSH_DIR, { recursive: true });
      await writeFile(SESSION_FILE, JSON.stringify(session, null, 2), { encoding: 'utf8' });
      log(`LOGIN_OK ${SESSION_FILE}`);
      log(`session: userId=${session.userId} orgId=${session.orgId} im=${session.im}`);
      if (!KEEP_OPEN) {
        try {
          const browser = await httpJson(`http://127.0.0.1:${PORT}/json/version`);
          if (browser.webSocketDebuggerUrl) {
            const b = await new Cdp(browser.webSocketDebuggerUrl).open();
            await b.send('Browser.close').catch(() => { });
            b.close();
          } else if (child) child.kill();
        } catch { if (child) child.kill(); }
      }
      cdp.close();
      process.exit(0);
    }
    if (Date.now() - lastNotice > 15000) {
      lastNotice = Date.now();
      log('Still waiting for login...');
    }
    await sleep(1500);
  }

  cdp.close();
  if (child && HEADLESS) child.kill();
  console.error('Login timed out. The Edge window is left open for a retry; rerun this command when ready.');
  process.exit(2);
}

main().catch((err) => {
  console.error('Login helper failed:', err?.message || err);
  process.exit(1);
});

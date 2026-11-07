---
name: ecloud-space
description: Access 中国移动「移动云空间」(Ecpan, www.ecpan.cn) on Windows without driving the Windows UI. Use for listing/creating folders in the personal cloud disk, reading account and quota information, and querying IM organizations. File transfer and chat stay in the desktop client.
---

# 移动云空间 (Ecpan) access

移动云空间 is China Mobile's enterprise collaboration product (`移动云空间`, app id `Ecpan`, online host
`https://www.ecpan.cn`). The desktop client at `C:\ProgramData\Ecloud\Ecpan` embeds the web drive and a native IM.
The web drive is served by ordinary JSON services; the IM chat in the client uses a private TCP protocol and an
encrypted local database, so it cannot be driven from the public HTTP API.

This skill uses **HTTP only**: it never sends mouse/keyboard input to Windows and never reads process memory.
It authenticates once with the browser session cookies, stores them in the user profile, and then calls the same
JSON endpoints the web app uses.

## Requirements

- Windows with PowerShell 7 (`pwsh`).
- Node.js 22+ only for the interactive `login` helper (it uses the built-in `WebSocket`).
- Microsoft Edge for the interactive login helper. A manual `-Cookie` import needs no browser automation.

## Session

The session file is `%USERPROFILE%\.dsh\ecloud\session.json`. It contains the `sid`, `timeStamp`, `token`, `userId`
and `orgId` cookies and is **sensitive**: never commit it, print it, or paste it into a ticket.

```powershell
# One-time interactive login (opens a dedicated Edge profile; log in there once).
pwsh -File scripts\ecloud.ps1 login

# Or import a cookie string copied from the browser DevTools (Cookies for .ecpan.cn).
pwsh -File scripts\ecloud.ps1 login -Cookie "sid=...; timeStamp=...; token=...; userId=...; orgId=..."

# Check whether the saved session is still valid.
pwsh -File scripts\ecloud.ps1 status
```

The interactive helper opens `https://www.ecpan.cn/web/yunpan/` in a separate Edge profile at
`%USERPROFILE%\.dsh\ecloud\browser`. Log in with the corporate account. When the `sid` and IM cookies appear, the
helper writes the session file and closes that browser. Re-run `login` when `status` reports an expired session.

## Commands

All commands print a short table; add `-Json` for machine-readable output.

```powershell
# Account, usn, organization and quota.
pwsh -File scripts\ecloud.ps1 whoami -Json

# List the personal disk root ("个人盘").
pwsh -File scripts\ecloud.ps1 ls

# List a sub-folder by path or just by name.
pwsh -File scripts\ecloud.ps1 ls -Path "个人盘\2026"

# Create an empty folder. Write operations need explicit confirmation from the user.
pwsh -File scripts\ecloud.ps1 mkdir -Path "个人盘" -Name "dsh-ecloud-skill-test" -Yes

# Return the IM organizations visible to the current account (read-only).
pwsh -File scripts\ecloud.ps1 im-orgs -Json

# Describe the local desktop client and its data directories (read-only).
pwsh -File scripts\ecloud.ps1 client-info
```

## Safety rules

1. Default to read-only operations (`status`, `whoami`, `ls`, `im-orgs`, `client-info`).
2. Run `mkdir` only after the user explicitly asks for a new folder; use a clear test name.
3. Do not upload, download, rename, move or delete files through this skill. Those endpoints exist in the web app but
   are not validated here, and the user has asked for no uncontrolled file transfer.
4. Never use the session for another person's disk or another organization. The session belongs to the account that
   logged in.
5. If a response is `SESSION_TIMEOUT`, ask the user to log in again; do not try to guess credentials.

## Messaging (desktop client only)

The web app exposes read-only IM queries (`/access/IMLogin/getValidOrgIds`,
`/access/Contacts/getOrgsName`) but **no public send/list-history API**. Sending a message and reading chat history
require the Windows client, whose IM runs over a private TCP connection and stores chats in SQLCipher databases under
`%APPDATA%\suyan\yunpan\data\<im-user-id>\`. This skill deliberately does not automate that client UI.

What the agent can do for messages:

- Report that messaging is client-only, and show the client path and account from `client-info`.
- Ask the user to use the client's **消息** view (the client keeps its login state).
- Do not synthesize clicks or keystrokes, do not scrape memory, and do not attempt to decrypt `welldone.db`.

If the user explicitly accepts Windows UI automation for messaging, that is a separate, opt-in helper and must be
reviewed as such; it is not part of this skill.

## Environment facts (verified on 2026-11-07)

| Item | Value |
|---|---|
| Web app | `https://www.ecpan.cn/web/yunpan/` |
| Web API base | `https://www.ecpan.cn` |
| Desktop client | `C:\ProgramData\Ecloud\Ecpan\Ecloud Cloud Ecpan Application.exe` |
| Client data root | `%APPDATA%\suyan\yunpan` |
| Client IM data | `%APPDATA%\suyan\yunpan\data\<im-user-id>\` (SQLCipher `welldone.db`, `contacts.db`, ...) |
| Enterprise | read `corpId` from `whoami`; do not hard-code it |
| Personal disk | diskType `1`; root folder name `个人盘`; root lookup `parentId=-1` |
| Test artifacts | `个人盘\dsh-ecloud-skill-test-*` (two empty folders created during verification) |

The account-specific values above are examples from the verification machine; read the current values from
`whoami` instead of hard-coding them.

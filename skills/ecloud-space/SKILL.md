---
name: ecloud-space
description: Access 中国移动「移动云空间」(Ecpan, www.ecpan.cn) on Windows without driving the Windows UI. Use for personal and group cloud disks: account/quota, list, create folders, upload/download small files, WPS view/edit links, and IM organization lookup. Chat itself stays in the desktop client.
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

# Personal disk: list the root ("个人盘") or a sub-folder.
pwsh -File scripts\ecloud.ps1 ls
pwsh -File scripts\ecloud.ps1 ls -Path "个人盘\2026"
pwsh -File scripts\ecloud.ps1 mkdir -Path "个人盘" -Name "dsh-ecloud-skill-test" -Yes

# Group spaces (diskType 2).
pwsh -File scripts\ecloud.ps1 groups
pwsh -File scripts\ecloud.ps1 group-ls -Group "temp-waicai"
pwsh -File scripts\ecloud.ps1 group-ls -Group "temp-waicai" -Path "some-folder"
pwsh -File scripts\ecloud.ps1 group-mkdir -Group "temp-waicai" -Path "some-folder" -Name "new-folder" -Yes

# Small-file transfer in a group (HTTP multipart, <= 5 MB).
pwsh -File scripts\ecloud.ps1 upload -Group "temp-waicai" -Path "some-folder" -File "C:\tmp\a.txt" -Yes
pwsh -File scripts\ecloud.ps1 download -Group "temp-waicai" -Path "some-folder\a.txt" -Out "C:\tmp\a.txt" -Yes

# WPS online view/edit link (the URL contains a short-lived token; do not log or share it).
pwsh -File scripts\ecloud.ps1 view-url -Group "temp-waicai" -Path "some-folder\a.txt"
pwsh -File scripts\ecloud.ps1 view-url -Group "temp-waicai" -Path "some-folder\a.txt" -Edit

# Read-only IM organization lookup and local client description.
pwsh -File scripts\ecloud.ps1 im-orgs -Json
pwsh -File scripts\ecloud.ps1 client-info
```

## Safety rules

1. Default to read-only operations (`status`, `whoami`, `ls`, `groups`, `group-ls`, `im-orgs`, `client-info`).
2. `mkdir`, `group-mkdir`, `upload` and `download` run only when the user explicitly asks for that operation, and
   require `-Yes`. Use a clear test name; do not touch groups or folders the user did not name.
3. `upload` is limited to files up to 5 MB because the chunked browser uploader is not reimplemented. Do not upload
   into a production group without an explicit instruction.
4. `view-url` returns a WPS URL containing a short-lived token. Give it to the user; do not paste it into tickets or
   logs. Opening it is a normal browser action, not Windows UI automation.
5. Never use the session for another person's disk or another organization. The session belongs to the account that
   logged in.
6. If a response is `SESSION_TIMEOUT`, ask the user to log in again; do not try to guess credentials.

## Messaging (desktop client only)

The web app exposes read-only IM queries (`/access/IMLogin/getValidOrgIds`,
`/access/Contacts/getOrgsName`) but **no public send/list-history API**. The native client's chat uses the AACE TCP
protocol (`Aace::tcp_client`, `MsgSender`) and SQLCipher databases under
`%APPDATA%\suyan\yunpan\data\<im-user-id>\`. The web-session POST to `/access/SingleChat/sendMsg` returns
`retcode=-90006` with `msgId=0`, so it does not deliver a message.

This skill deliberately does not automate the Windows client UI. What the agent can do for messages:

- Report that messaging is client-only, and show the client path and account from `client-info`.
- Ask the user to use the client's **消息** view (the client keeps its login state).
- Do not synthesize clicks or keystrokes, do not scrape process memory, and do not attempt to decrypt `welldone.db`.

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
| Group space | diskType `2`; list by `group:groupList`; root `parentId = groupId` |
| Test group | `temp-waicai` (groupId `516940`, created for verification; one member) |
| Test artifacts | `个人盘\dsh-ecloud-skill-test-*`; `temp-waicai\dsh-ecloud-skill-test` with two small `.txt` files and one empty sub-folder |

The account-specific values above are examples from the verification machine; read the current values from
`whoami` instead of hard-coding them.

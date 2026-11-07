---
name: ecloud-space
description: Access 中国移动「移动云空间」(Ecpan, www.ecpan.cn) on Windows without Windows mouse/keyboard input. Use for personal and group cloud disks (list, stat, folders, small-file upload/download, WPS view/edit links), IM organization lookup, and one-at-a-time chat send through the client's web IM page on a local debug port. A local policy allowlist and exact-target confirmations make writes and messages fail closed.
---

# 移动云空间 (Ecpan) access

移动云空间 is China Mobile's enterprise collaboration product (`移动云空间`, app id `Ecpan`, online host
`https://www.ecpan.cn`). The desktop client at `C:\ProgramData\Ecloud\Ecpan` embeds the web drive and a native IM.

**Security model:** writes and messages are deny-by-default. A local policy file lists the only group spaces and chat
recipients the skill may touch; every write also needs the exact target typed twice (`-ConfirmTarget`) and `-Yes`.
Public groups are refused, personal writes are limited to `个人盘`, and chat sends are one message at a time with a
cooldown. Read the policy before the first write/send.

## Requirements

- Windows with PowerShell 7 (`pwsh`).
- Node.js 22+ for the interactive `login` helper and the IM helpers (built-in `WebSocket`).
- Microsoft Edge for the interactive login helper. A manual `-Cookie` import needs no browser automation.

## Session

The session file is `%USERPROFILE%\.dsh\ecloud\session.json`. It contains the `sid`, `timeStamp`, `token`, `userId`
and `orgId` cookies and is **sensitive**: never commit it, print it, or paste it into a ticket.

```powershell
pwsh -File scripts\ecloud.ps1 login
pwsh -File scripts\ecloud.ps1 login -Cookie "sid=...; timeStamp=...; token=...; userId=...; orgId=..."
pwsh -File scripts\ecloud.ps1 status
```

## Policy (allowlist)

The policy lives at `%USERPROFILE%\.dsh\ecloud\policy.json`. Safe defaults:

| Key | Default | Meaning |
|---|---|---|
| `allowedGroups` | `["temp-waicai"]` | groups that may be listed/read |
| `allowedWriteGroups` | `["temp-waicai"]` | groups that may be modified |
| `allowPublicGroups` | `false` | public groups always refused when false |
| `allowPersonalWrites` | `true` | personal-disk upload/mkdir allowed |
| `requireConfirmTarget` | `true` | require exact `-ConfirmTarget` for writes/downloads |
| `allowedChats` | `["文件传输助手"]` | chats readable/sendable by default |
| `allowAnyChat` | `false` | whether policy permits adding other chats at all |
| `maxUploadMB` | `5` | single-shot upload limit |
| `maxMessageChars` | `2000` | chat message limit |
| `sendCooldownSeconds` | `3` | minimum gap between sends |

```powershell
pwsh -File scripts\ecloud.ps1 policy          # show effective policy and path
pwsh -File scripts\ecloud.ps1 policy -Init -Yes  # write safe defaults (only after user approval)
```

To work with another group or chat, the user must explicitly add its **exact name** to the policy; the agent must not
edit the policy on its own. A malformed policy fails closed.

## Commands

All commands print a short table; add `-Json` for machine-readable output.

```powershell
# Account, usn, organization and quota.
pwsh -File scripts\ecloud.ps1 whoami -Json

# Personal disk: list, metadata, create a folder (confirm the exact parent path).
pwsh -File scripts\ecloud.ps1 ls
pwsh -File scripts\ecloud.ps1 stat -Personal -Path "个人盘\2026"
pwsh -File scripts\ecloud.ps1 mkdir -Path "个人盘" -Name "test" -ConfirmTarget "个人盘" -Yes

# Group spaces: list metadata, read the allowed group, create a folder in it.
pwsh -File scripts\ecloud.ps1 groups
pwsh -File scripts\ecloud.ps1 group-ls -Group "temp-waicai"
pwsh -File scripts\ecloud.ps1 group-ls -Group "temp-waicai" -Path "some-folder"
pwsh -File scripts\ecloud.ps1 group-mkdir -Group "temp-waicai" -Path "some-folder" -Name "new-folder" `
    -ConfirmTarget "temp-waicai\some-folder" -Yes

# Small-file transfer (single multipart, <= policy maxUploadMB). Confirm the exact cloud path.
pwsh -File scripts\ecloud.ps1 upload -Personal -Path "个人盘\2026" -File "C:\tmp\a.txt" `
    -ConfirmTarget "个人盘\2026" -Yes
pwsh -File scripts\ecloud.ps1 upload -Group "temp-waicai" -Path "some-folder" -File "C:\tmp\a.txt" `
    -ConfirmTarget "temp-waicai\some-folder" -Yes
pwsh -File scripts\ecloud.ps1 download -Personal -Path "个人盘\2026\a.txt" -Out "C:\tmp\a.txt" `
    -ConfirmTarget "个人盘\2026\a.txt" -Yes
pwsh -File scripts\ecloud.ps1 download -Group "temp-waicai" -Path "some-folder\a.txt" -Out "C:\tmp\a.txt" `
    -ConfirmTarget "temp-waicai\some-folder\a.txt" -Yes

# WPS online view/edit link (contains a short-lived token; do not log or share it).
pwsh -File scripts\ecloud.ps1 view-url -Personal -Path "个人盘\2026\a.txt"
pwsh -File scripts\ecloud.ps1 view-url -Group "temp-waicai" -Path "some-folder\a.txt" -Edit

# Read-only IM organization lookup, chat list and local client status.
pwsh -File scripts\ecloud.ps1 im-orgs -Json
pwsh -File scripts\ecloud.ps1 msg-chats -Json
pwsh -File scripts\ecloud.ps1 client-debug-status
pwsh -File scripts\ecloud.ps1 client-info

# Code-based chat send: exact recipient twice, one message, cooldown.
pwsh -File scripts\ecloud.ps1 msg-send -To "文件传输助手" -ConfirmRecipient "文件传输助手" `
    -Text "test message" -DryRun
pwsh -File scripts\ecloud.ps1 msg-send -To "文件传输助手" -ConfirmRecipient "文件传输助手" `
    -Text "test message" -Yes
```

## Safety rules

1. Default to read-only operations (`status`, `whoami`, `ls`, `stat`, `groups`, `group-ls`, `im-orgs`, `msg-chats`,
   `client-info`, `client-debug-status`, `policy`).
2. Write/transfer/chat commands run only on an explicit user request, with `-Yes` and the exact target/recipient.
   `upload`/`download`/`mkdir`/`group-mkdir` require `-ConfirmTarget`; `msg-send` requires `-ConfirmRecipient` equal
   to `-To`. A mismatch is refused before any network call.
3. Groups not in the policy allowlist are refused, and public groups are refused while `allowPublicGroups` is false.
   Do not add a group or chat to the policy unless the user explicitly names it.
4. `upload` verifies that the file appears in the target folder; `download` verifies size and MD5 when available. If
   verification fails, do not retry blindly.
5. `view-url` returns a WPS URL containing a short-lived token. Give it only to the requesting user; do not put it in
   tickets or logs.
6. `msg-send` defaults to 文件传输助手, sends exactly one message, verifies the active chat/header and that the draft
   cleared, and refuses a second send within the cooldown. Do not send bulk messages, do not send to a colleague
   without an explicit instruction naming that chat, and do not send secrets.
7. Never use the session for another person's disk or another organization.

## Messaging (code-based, opt-in client debug port)

The native client's IM uses the AACE TCP protocol and SQLCipher databases; there is no public HTTP send API. The client
embeds a web IM page (`.../pc-local/pc-main/0.0.1/index.html?...&orgname=...#/im`) that calls the native bridge
(`s.call("chat","sendMessage", ...)`). With the client started with a local CEF debug port, `msg-send` drives that
page with CDP + DOM/JS: it opens the exact chat, inserts text into the editor, dispatches Enter, and verifies the
draft cleared and the text appears. It does **not** synthesize Windows mouse or keyboard input.

Prerequisite (per client launch):

```powershell
# Close the 移动云空间 client, then relaunch it with:
& 'C:\ProgramData\Ecloud\Ecpan\Ecloud Cloud Ecpan Application.exe' --remote-debugging-port=9222 --remote-allow-origins=*
# Log in (auto-login supported), then:
pwsh -File scripts\ecloud.ps1 client-debug-status   # available + imPage true
```

The debug port is local-only but powerful: any local process can control the client's web pages. Restart the client
normally after the messaging task to remove it. Chat history remains in the client UI; `msg-chats` lists visible chat
names for choosing a recipient, and this skill does not read message history.

Verified on 2026-11-07: two messages were sent to 文件传输助手 with no Windows mouse/keyboard input. The hardened
path was also tested for chat allowlist refusal, missing recipient confirmation, cooldown refusal, group allowlist
refusal and exact-target mismatch refusal.

## Environment facts (verified on 2026-11-07)

| Item | Value |
|---|---|
| Web app | `https://www.ecpan.cn/web/yunpan/` |
| Web API base | `https://www.ecpan.cn` |
| Desktop client | `C:\ProgramData\Ecloud\Ecpan\Ecloud Cloud Ecpan Application.exe` |
| Client data root | `%APPDATA%\suyan\yunpan` |
| Client IM data | `%APPDATA%\suyan\yunpan\data\<im-user-id>\` (SQLCipher `welldone.db`, ...) |
| Enterprise | read `corpId` from `whoami`; do not hard-code it |
| Personal disk | diskType `1`; root `个人盘`; upload also needs `appFileId = parentId` |
| Group space | diskType `2`; root `parentId = groupId`; policy allowlist applies |
| Test group | `temp-waicai` (groupId `516940`, one member) |
| Policy file | `%USERPROFILE%\.dsh\ecloud\policy.json` |
| Debug port | `9222` (local CEF; only while launched with `--remote-debugging-port=9222`) |
| Test artifacts | `个人盘\dsh-ecloud-skill-test-*`; `temp-waicai\dsh-ecloud-skill-test`; two chat test messages in 文件传输助手 |

The account-specific values above are examples from the verification machine; read the current values from
`whoami` instead of hard-coding them.

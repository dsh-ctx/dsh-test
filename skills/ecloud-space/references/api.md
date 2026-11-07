# ecloud-space — API notes

All endpoints below were verified on 2026-11-07 against `https://www.ecpan.cn` with a real corporate session.

## Session cookies

The web app and the IM gateway share these cookies for the logged-in account:

| Cookie | Meaning |
|---|---|
| `sid` | Web session id (drive, user info) |
| `timeStamp` | IM gateway timestamp |
| `token` | IM gateway token |
| `userId` | IM user id (numeric string, e.g. `<im-user-id>`) |
| `orgId` | Organization id (e.g. `<org-id>`) |

Send them as a normal `Cookie` header. `/webadmin/*` additionally accepts `X-Skydrive-Sid: <sid>`, but the
commands here do not call those endpoints. Responses use JSON; `Content-Type: application/json` is required for
`/drive/service/*`; an empty body gives `JSON_PARSE_EXCEPTION` even for reads.

## Security policy

`%USERPROFILE%\.dsh\ecloud\policy.json` is the write/read allowlist. Defaults used when it is absent (and written by
`policy -Init`):

```json
{
  "allowedGroups": ["temp-waicai"],
  "allowedWriteGroups": ["temp-waicai"],
  "allowPublicGroups": false,
  "allowPersonalWrites": true,
  "requireConfirmTarget": true,
  "allowedChats": ["文件传输助手"],
  "allowAnyChat": false,
  "maxUploadMB": 5,
  "maxMessageChars": 2000,
  "sendCooldownSeconds": 3
}
```

- Group read/write commands check the allowlist and refuse `isPublic=1` groups while `allowPublicGroups=false`.
- Every write/download/upload needs `-ConfirmTarget` exactly equal to the canonical path
  (`个人盘\...` or `<group>\...`); `-Yes` is also required.
- `msg-send` needs `-ConfirmRecipient` equal to `-To`; non-file-assistant chats additionally need
  `-AllowAnyChat` **and** `allowAnyChat=true` plus the exact chat in `allowedChats`.
- A malformed policy file fails closed. The agent must not edit the policy without an explicit user instruction.

## Drive

Base: `https://www.ecpan.cn`.

### Account info

```
POST /drive/service/disk/search.do?func=disk:userInfo
Content-Type: application/json

{}
```

Returns `{ code: "S_OK", var: { userName, usn, corpId, privateStorageQuota, ... } }`.

### List a folder

```
POST /drive/service/disk/search.do?func=disk:search
Content-Type: application/json

{
  "diskType": 1,
  "status": 1,
  "orderField": "create_date",
  "orderBy": "desc",
  "usn": <usn>,
  "parentId": "<folder appFileId>",
  "pageSize": 100,
  "reqPage": 1,
  "picHeight": 72,
  "picThumbnail": 1,
  "picWidth": 72
}
```

Do **not** send `"fileType": "1"` for a normal folder listing: it filters out files and was the cause of a false
"uploaded file is not visible" check. The personal-root lookup (`parentId=-1`) does use `fileType:"1"` to find the
`个人盘` folder. Listings paginate on `var.pageCount`; the CLI fetches up to 10 pages (100 items each).

### Create an empty folder

```
POST /drive/service/common/file.do?func=common:createFolder
Content-Type: application/json

{
  "comeFrom": 0,
  "creatorUsn": 0,
  "diskType": 1,
  "fileName": "dsh-ecloud-skill-test",
  "groupId": "",
  "parentId": "<personal-root-appFileId>"
}
```

Returns `{ code: "S_OK", errorCode: "<new name>", var: "<new appFileId>" }`.

### Group spaces

```
POST /drive/service/group/group?func=group:groupList
Content-Type: application/json

# find a group by name
{"diskType":2,"isGroup":1,"pageSize":100,"picHeight":72,"picThumbnail":1,"picWidth":72,
 "reqPage":1,"searchType":0,"isGroupMembers":false,"groupName":"<name>"}

# list the group root or a sub-folder
{"createdByUsn":<group.createdByUsn>,"diskType":2,"isGroup":1,
 "orderBy":"desc","orderField":"modify_date","pageSize":100,
 "parentId":"<groupId or folder appFileId>","picHeight":72,"picThumbnail":1,"picWidth":72,
 "reqPage":1,"isGroupMembers":false}
```

The search-by-name result identifies the root with `groupId`; the root folder view uses
`parentId = groupId`. Use the group's `createdByUsn` for listings. Verified in `temp-waicai`
(groupId `516940`): root listing, sub-folder listing, and `common:createFolder` with
`{"comeFrom":0,"creatorUsn":<group.createdByUsn>,"diskType":2,"fileName":"...","groupId":"516940","parentId":"..."}`.

### Upload a small file (personal or group)

Use **multipart** against `onestfile.do`; a JSON body returns `JSON_PARSE_EXCEPTION`.

```
POST /drive/service/common/onestfile.do?func=common:onestUpload
Content-Type: multipart/form-data

file=<file bytes>
appFileId=<target folder appFileId>     # required for personal uploads
parentId=<target folder appFileId; groupId for the group root>
diskType=1|2
groupId=<"" for personal, groupId for group>
fileName=<name>
fileSize=<bytes>
fileMd5=<lower-case hex MD5>
uploadType=1
comeFrom=0
newFlag=1
model=0
usn=<current usn>
creatorUsn=<usn for personal, group.createdByUsn for group>
fileType=2
filePath=<target folder filePath, or "/">
```

For a personal upload the response contains the new file object with `appFileId`, `filePath`
(`个人盘\...`) and `groupId` set to the personal root. Omitting `appFileId` can make the server accept the
request without creating the file. After the upload the CLI lists the target folder and refuses to report success
if the new file is not visible.

Returns `{code:"S_OK", var:{appFileId, dfsFileId, fileName, fileSize, fileMd5, version, ...}}`.
The browser uploader chunks files above 5 MB and calls `common:completeUpload`; this CLI only does the single
multipart request and therefore caps at 5 MB.

### Download

```
POST /drive/service/common/file.do?func=common:download
Content-Type: application/json

{
  "comeFrom": 0, "corpId": <corpId>, "creatorUsn": <file.createdByUsn>,
  "diskType": 1|2, "downSource": 1,
  "fileIdList": [{"appFileId":"...","fileSize":...,"fileVersion":...,"rootUsn":...,
                  "fileType":2,"fileName":"...","diskType":1|2,"groupId":""|"<groupId>"}],
  "fileName":"...", "groupId":""|"<groupId>", "isIp":0, "isDownload":1
}
```

Response `var.downloadUrl` is an HTTP URL containing the `sid`; download it promptly and do not log the URL.
The CLI verifies the local size and MD5 when the API returns them. Verified for personal and group files
(53/64 bytes, MD5 matched) and for an empty group folder (a 160-byte zip).

### WPS online view/edit link

```
POST /api/v1/edit/cloudp/wps/url/getViewUrl
Content-Type: application/json

{
  "downloadUrl": "<var.downloadUrl from common:download>",
  "fileId": "<file appFileId>",
  "fileName": "a.txt",
  "fileType": "txt",
  "usn": <usn>,
  "permission": "1111111111",
  "isWrite": 0,
  "creater": "<userName>",
  "localType": 0
}
```

Set `isWrite` to `1` for the edit link. The response uses `code: "0010200001"` and
`content.url` / `content.token`, not the `S_OK` shape. The URL contains a short-lived token; treat it as a
credential and give it only to the user who asked for the file.

Personal files use the same endpoint with `downloadUrl` from the personal-disk download and `permission`
`1111111111` when the listing has no permission value. Verified for both personal and group files.

### Not implemented

| Function | Endpoint | Reason |
|---|---|---|
| Delete | `common:deleteFile` / `common:newDeleteFile` | Destructive; not requested in the test group |
| Rename | `common:rename` | Not needed for the verification |
| Move/copy | `common:mvOrCp` / `common:newMvOrCp` | Not needed for the verification |
| Search | `disk:searchIndex` | Not needed for the verification |
| Chunked upload (`>5 MB`) | `common:upload` + `common:completeUpload` | Requires the browser worker's chunk protocol |

## Web IM page and code-based send

The client exposes a web IM page in its CEF:

```
https://www.ecpan.cn/pc-local/pc-main/0.0.1/index.html?orgid=<orgId>&orgname=<orgName>#/im
```

Start the client with a local debug port to inspect it:

```
Ecloud Cloud Ecpan Application.exe --remote-debugging-port=9222 --remote-allow-origins=*
```

`GET http://127.0.0.1:9222/json/list` then contains the `#/im` page (plus drive, contacts, workbench,
meeting, notification pages). The page is React 16 + Redux and calls the native bridge for chat; it is not a pure
HTTP client. Sending through the page is code-driven: CDP `Runtime.evaluate` clicks the chat item,
inserts text into the contenteditable editor, and dispatches an Enter `keydown`. The editor's React `onKeyDown`
handler calls `onSendMsg`, which calls the native bridge (`s.call("chat","sendMessage", ...)`) and clears the draft.

Useful DOM facts:

| Item | Selector / value |
|---|---|
| 文件传输助手 chat item | `#u19999` (class gains `active-...` when selected) |
| Chat name in the list | `.ellipsis.c-dark` inside an item whose id matches `^[ug]\d+$` |
| Conversation header | element at `y < 60`, `x > 280` whose text equals the chat name |
| Message editor | visible `[contenteditable=true]` with `0 < height < 120` |
| Send trigger | `keydown` Enter on the editor (button `disabled` may stay true because the app model is not updated by `execCommand`) |

`scripts/im-send.mjs` implements this, defaults to 文件传输助手, requires an exact chat name and an explicit
`--allow-any-chat` for anything else, supports `--dry-run` and `--list` (chat names/IDs for `msg-chats`), and
verifies that the draft clears and the text appears in the page. It does not send in bulk and does not read
history. The debug port is local-only but powerful; close it by restarting the client normally after use.

The CLI adds the policy layer on top: a chat must be in `allowedChats` (or `allowAnyChat=true` plus
`-AllowAnyChat`), `-ConfirmRecipient` must exactly equal `-To`, `-Yes` is required, the message is length/control
character checked, and a 3-second cooldown file (`%USERPROFILE%\.dsh\ecloud\last-send.json`) blocks rapid repeats.
No retry is performed after a send.

Verified on 2026-11-07: two test messages were sent to 文件传输助手 with this path, no Windows mouse/keyboard input.
The hardened guards were tested separately (chat not allowlisted, missing recipient confirmation, cooldown, group
allowlist, target mismatch); no extra messages were sent for those tests.

## IM (read-only HTTP)

Base: `https://www.ecpan.cn`, same cookies.

```
POST /access/IMLogin/getValidOrgIds
{"uid":"<userId>","orgType":-1}

POST /access/Contacts/getOrgsName
{"orgIds":[11111111, 22222222]}
```

Successful responses are `{"retcode":0,"errmsg":"处理成功","data":...}`. `retcode=-90006` means the IM token is
missing or expired; `retcode=100` with empty `validOrgIds` means the account has no other IM organization.

The chat itself is **not** available over the public HTTP API. The native client uses the AACE custom TCP protocol
(`Aace::tcp_client`, `MsgSender`, `SndPkgNode`; observed on `36.134.88.78:13003`), SQLCipher databases under
`%APPDATA%\suyan\yunpan\data\<userId>\` (`welldone.db`, `contacts.db`, `group.db`, ...), and SDK methods such as
`getChatList`, `getSingleMsg`, `sendMsg`. Probe requests to `/access/SingleChat/sendMsg` and
`/webaace/SingleChat/sendMsg` returned `retcode=-90006, errmsg="无效的请求"` with `msgId=0` (no message delivered),
so the web session is not sufficient for HTTP chat. Use the web IM page via the client debug port (above) for a
code-based send.

## Login

The interactive helper opens `https://www.ecpan.cn/web/yunpan/` in a dedicated Edge profile and reads
`Storage.getCookies` through CDP. It needs only `sid`, `userId`, `orgId` for drive commands; `timeStamp` and
`token` are needed for `im-orgs`. A manual cookie import (`login -Cookie "..."`) skips the browser.

The session file `%USERPROFILE%\.dsh\ecloud\session.json` contains these cookies in plain text. Treat it as a
credential: do not commit, print or paste it into tickets.

## Observed environment

| Item | Value |
|---|---|
| Client install | `C:\ProgramData\Ecloud\Ecpan\Ecloud Cloud Ecpan Application.exe` |
| Client version | `5.10.28` (`app.dat`) |
| Client data | `%APPDATA%\suyan\yunpan` |
| Policy file | `%USERPROFILE%\.dsh\ecloud\policy.json` |
| Debug port | `9222` local CEF (`--remote-debugging-port=9222 --remote-allow-origins=*`) |
| Edge (for login) | `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe` |
| Node | v26.7.0, global `WebSocket` available |

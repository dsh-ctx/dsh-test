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
  "fileType": "1",
  "status": 1,
  "orderField": "create_date",
  "orderBy": "desc",
  "usn": <usn>,
  "parentId": "<personal-root-appFileId>",
  "pageSize": 100,
  "reqPage": 1,
  "picHeight": 72,
  "picThumbnail": 1,
  "picWidth": 72
}
```

`parentId = -1` lists the personal-space roots; the entry named `个人盘` is the personal disk. Use its
`appFileId` as the parent for the root contents. `fileType` is `1` for folders and files in the listing.

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

### Upload a small file to a group

Use **multipart** against `onestfile.do`; a JSON body returns `JSON_PARSE_EXCEPTION`.

```
POST /drive/service/common/onestfile.do?func=common:onestUpload
Content-Type: multipart/form-data

file=<file bytes>
parentId=<target folder appFileId; groupId for the root>
diskType=2
groupId=<groupId>
fileName=<name>
fileSize=<bytes>
fileMd5=<lower-case hex MD5>
uploadType=1
comeFrom=0
newFlag=1
model=0
usn=<current usn>
creatorUsn=<group.createdByUsn>
fileType=2
filePath=<parent filePath, or "/">
```

Returns `{code:"S_OK", var:{appFileId, dfsFileId, fileName, fileSize, fileMd5, version, ...}}`.
The browser uploader chunks files above 5 MB and calls `common:completeUpload`; this CLI only does the single
multipart request and therefore caps at 5 MB.

### Download

```
POST /drive/service/common/file.do?func=common:download
Content-Type: application/json

{
  "comeFrom": 0, "corpId": <corpId>, "creatorUsn": <file.createdByUsn>,
  "diskType": 2, "downSource": 1,
  "fileIdList": [{"appFileId":"...","fileSize":...,"fileVersion":...,"rootUsn":...,
                  "fileType":2,"fileName":"...","diskType":2,"groupId":"..."}],
  "fileName":"...", "groupId":"...", "isIp":0, "isDownload":1
}
```

Response `var.downloadUrl` is an HTTP URL containing the `sid`; download it promptly and do not log the URL.
Verified for a group file (64 bytes, MD5 matched) and for an empty group folder (a 160-byte zip).

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

### Not implemented

| Function | Endpoint | Reason |
|---|---|---|
| Delete | `common:deleteFile` / `common:newDeleteFile` | Destructive; not requested in the test group |
| Rename | `common:rename` | Not needed for the verification |
| Move/copy | `common:mvOrCp` / `common:newMvOrCp` | Not needed for the verification |
| Search | `disk:searchIndex` | Not needed for the verification |
| Chunked upload (`>5 MB`) | `common:upload` + `common:completeUpload` | Requires the browser worker's chunk protocol |

## IM (read-only)

Base: `https://www.ecpan.cn`, same cookies.

```
POST /access/IMLogin/getValidOrgIds
{"uid":"<userId>","orgType":-1}

POST /access/Contacts/getOrgsName
{"orgIds":[11111111, 22222222]}
```

Successful responses are `{"retcode":0,"errmsg":"处理成功","data":...}`. `retcode=-90006` means the IM token is
missing or expired; `retcode=100` with empty `validOrgIds` means the account has no other IM organization.

The chat itself is **not** available here. The native client uses
`C:\ProgramData\Ecloud\Ecpan\Ecloud Cloud Ecpan Application.exe` with the AACE custom TCP protocol
(`Aace::tcp_client`, `MsgSender`, `SndPkgNode`; observed on `36.134.88.78:13003`), SQLCipher databases under
`%APPDATA%\suyan\yunpan\data\<userId>\` (`welldone.db`, `contacts.db`, `group.db`, ...), and SDK methods such as
`getChatList`, `getSingleMsg`, `sendMsg`. Probe requests to `/access/SingleChat/sendMsg` and
`/webaace/SingleChat/sendMsg` returned `retcode=-90006, errmsg="无效的请求"` with `msgId=0` (no message delivered),
so the web session is not sufficient for chat. `webaace` calls from the client use `Cookie` and an
`Authorization` value that appears to be a per-request signature; reusing the web cookies does not satisfy it.

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
| Edge (for login) | `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe` |
| Node | v26.7.0, global `WebSocket` available |

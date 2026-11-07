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

### Endpoints known but not included in the CLI

These exist in the web bundle and are useful for a future, explicitly reviewed file-transfer command:

| Function | Endpoint |
|---|---|
| Upload | `POST /drive/service/common/file.do?func=common:upload` (multipart) |
| Download | `POST /drive/service/common/file.do?func=common:download` |
| Delete | `POST /drive/service/common/file.do?func=common:deleteFile` |
| Rename | `POST /drive/service/common/file.do?func=common:rename` |
| Move/copy | `POST /drive/service/common/file.do?func=common:mvOrCp` |
| Search | `POST /drive/service/disk/search.do?func=disk:searchIndex` |

They were deliberately not exercised because the ticket forbids uncontrolled upload/download/delete tests.

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
`C:\ProgramData\Ecloud\Ecpan\Ecloud Cloud Ecpan Application.exe` with a private TCP connection (observed on
`36.134.88.78:13003`), SQLCipher databases under `%APPDATA%\suyan\yunpan\data\<userId>\`
(`welldone.db`, `contacts.db`, `group.db`, ...), and SDK methods such as `getChatList`, `getSingleMsg`,
`sendMsg`. Probe requests to `/access/SingleChat/sendMsg` and `/webaace/SingleChat/sendMsg` returned
`retcode=-90006, errmsg="无效的请求"` with `msgId=0` (no message delivered), so the web session is not sufficient
for chat.

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

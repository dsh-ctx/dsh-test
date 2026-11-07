#requires -Version 7.0
<#
.SYNOPSIS
  Read-mostly HTTP access to 中国移动「移动云空间」(Ecpan).

.DESCRIPTION
  Uses the same JSON endpoints as https://www.ecpan.cn/web/yunpan/. It never sends
  Windows UI input and never reads process memory. The session (browser cookies) is
  stored at %USERPROFILE%\.dsh\ecloud\session.json and must not be committed.

.EXAMPLE
  pwsh -File ecloud.ps1 login

.EXAMPLE
  pwsh -File ecloud.ps1 whoami -Json

.EXAMPLE
  pwsh -File ecloud.ps1 ls -Path "个人盘\2026"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('login', 'status', 'whoami', 'ls', 'mkdir', 'groups', 'group-ls', 'group-mkdir', 'upload', 'download', 'view-url', 'im-orgs', 'client-info')]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Path = '',

    [string]$Name,
    [string]$Group,
    [string]$File,
    [string]$Out,
    [string]$RemoteName,
    [string]$Cookie,
    [string]$BaseUrl = 'https://www.ecpan.cn',
    [switch]$Yes,
    [switch]$Edit,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$script:BaseUrl = $BaseUrl.TrimEnd('/')
$script:SessionPath = Join-Path $env:USERPROFILE '.dsh\ecloud\session.json'
$script:Session = $null
$script:UserInfo = $null

function Write-Info([string]$Text) {
    if (-not $Json) { Write-Output $Text }
}

function Save-Session([hashtable]$Data) {
    $dir = Split-Path -Parent $script:SessionPath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:SessionPath -Encoding utf8
    # Keep the secret readable only by the current user where the ACL allows it.
    try {
        $acl = Get-Acl -LiteralPath $script:SessionPath
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $script:SessionPath -AclObject $acl
    } catch { }
}

function Get-Session {
    if ($script:Session) { return $script:Session }
    if (-not (Test-Path -LiteralPath $script:SessionPath)) {
        throw "No saved session. Run: ecloud.ps1 login"
    }
    $script:Session = Get-Content -LiteralPath $script:SessionPath -Raw -Encoding utf8 | ConvertFrom-Json
    if (-not $script:Session.cookie) { throw 'Session file has no cookie. Run: ecloud.ps1 login' }
    return $script:Session
}

function Parse-CookieString([string]$Text) {
    $map = @{}
    foreach ($part in $Text.Split(';')) {
        $p = $part.Trim()
        if (-not $p) { continue }
        $i = $p.IndexOf('=')
        if ($i -le 0) { continue }
        $map[$p.Substring(0, $i).Trim()] = $p.Substring($i + 1).Trim()
    }
    return $map
}

function Invoke-EcloudApi {
    param(
        [Parameter(Mandatory = $true)][string]$ApiPath,
        $Body = @{},
        [ValidateSet('Get', 'Post')][string]$Method = 'Post',
        [switch]$Im
    )
    $s = Get-Session
    $headers = @{
        'Cookie' = $s.cookie
        'Accept' = 'application/json, text/plain, */*'
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/84.0.4147.89 Safari/537.36'
    }
    $url = $script:BaseUrl + $ApiPath
    try {
        if ($Method -eq 'Get') {
            $r = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec 30
        } else {
            $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
            $headers['Content-Type'] = 'application/json'
            $r = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $json -TimeoutSec 30
        }
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $text = $reader.ReadToEnd()
            throw "HTTP $([int]$resp.StatusCode) from $ApiPath : $text"
        }
        throw
    }
    if ($null -ne $r.retcode) {
        if ([int]$r.retcode -ne 0) {
            throw "IM API $ApiPath failed: retcode=$($r.retcode) $($r.errmsg)"
        }
    } elseif ($null -ne $r.code) {
        if ($r.code -ne 'S_OK') {
            $summary = if ($r.summary) { $r.summary } else { $r.errorCode }
            throw "Ecpan API $ApiPath failed: $($r.code) $summary"
        }
    }
    return $r
}

function Get-UserInfo {
    if ($script:UserInfo) { return $script:UserInfo }
    $r = Invoke-EcloudApi -ApiPath '/drive/service/disk/search.do?func=disk:userInfo' -Body @{}
    $script:UserInfo = $r.var
    return $script:UserInfo
}

function Get-PersonalRoot {
    $u = Get-UserInfo
    $body = @{
        diskType = 1; fileType = '1'; status = 1
        orderField = 'create_date'; orderBy = 'asc'
        usn = $u.usn; parentId = -1; pageSize = 20; reqPage = 1
        picHeight = 72; picThumbnail = 1; picWidth = 72
    }
    $r = Invoke-EcloudApi -ApiPath '/drive/service/disk/search.do?func=disk:search' -Body $body
    $root = @($r.var.resultList) | Where-Object { $_.fileName -eq '个人盘' } | Select-Object -First 1
    if (-not $root) { $root = @($r.var.resultList) | Where-Object { $_.fileType -eq 1 } | Select-Object -First 1 }
    if (-not $root) { throw 'Cannot locate the personal disk root (个人盘).' }
    return $root
}

function List-Children([string]$ParentId) {
    $u = Get-UserInfo
    $body = @{
        diskType = 1; fileType = '1'; status = 1
        orderField = 'create_date'; orderBy = 'desc'
        usn = $u.usn; parentId = $ParentId; pageSize = 100; reqPage = 1
        picHeight = 72; picThumbnail = 1; picWidth = 72
    }
    $r = Invoke-EcloudApi -ApiPath '/drive/service/disk/search.do?func=disk:search' -Body $body
    return @($r.var.resultList)
}

function Resolve-Folder([string]$FolderPath) {
    $root = Get-PersonalRoot
    $clean = ($FolderPath -replace '/', '\').Trim('\')
    if (-not $clean -or $clean -eq '个人盘' -or $clean -eq '个人空间') { return $root }
    $segments = $clean.Split('\') | Where-Object { $_ -and $_ -ne '个人盘' -and $_ -ne '个人空间' }
    $current = $root
    foreach ($segment in $segments) {
        $children = List-Children $current.appFileId
        $next = $children | Where-Object { $_.fileName -eq $segment -and $_.fileType -eq 1 } | Select-Object -First 1
        if (-not $next) { throw "Folder not found: $segment (under $($current.fileName))" }
        $current = $next
    }
    return $current
}

function Get-Group([string]$GroupName) {
    if (-not $GroupName) { throw 'This command requires -Group <group name>.' }
    $body = @{
        diskType = 2; isGroup = 1; pageSize = 100
        picHeight = 72; picThumbnail = 1; picWidth = 72
        reqPage = 1; searchType = 0; isGroupMembers = $false
        groupName = $GroupName
    }
    $r = Invoke-EcloudApi -ApiPath '/drive/service/group/group?func=group:groupList' -Body $body
    $g = @($r.var.resultList) | Where-Object { $_.groupName -eq $GroupName } | Select-Object -First 1
    if (-not $g) { throw "Group not found: $GroupName" }
    # The group-list search result identifies the root by groupId; the root folder
    # view (parentId=groupId) also carries appFileId. Normalize both shapes.
    $g | Add-Member -NotePropertyName appFileId -NotePropertyValue ([string]$g.groupId) -Force
    $g | Add-Member -NotePropertyName fileName -NotePropertyValue $g.groupName -Force
    $g | Add-Member -NotePropertyName fileType -NotePropertyValue 1 -Force
    if (-not $g.PSObject.Properties['filePath']) {
        $g | Add-Member -NotePropertyName filePath -NotePropertyValue "群组空间\$($g.groupName)" -Force
    }
    return $g
}

function Get-GroupDirId($FolderOrGroup) {
    if ($FolderOrGroup.appFileId) { return [string]$FolderOrGroup.appFileId }
    return [string]$FolderOrGroup.groupId
}

function List-GroupChildren($GroupInfo, [string]$ParentId) {
    $body = @{
        createdByUsn = $GroupInfo.createdByUsn
        diskType = 2; isGroup = 1
        orderBy = 'desc'; orderField = 'modify_date'
        pageSize = 100
        parentId = $ParentId
        picHeight = 72; picThumbnail = 1; picWidth = 72
        reqPage = 1; isGroupMembers = $false
    }
    $r = Invoke-EcloudApi -ApiPath '/drive/service/group/group?func=group:groupList' -Body $body
    return @($r.var.resultList | Where-Object { $_.fileName -or $_.groupName })
}

function Resolve-GroupFolder($GroupInfo, [string]$FolderPath) {
    $clean = ($FolderPath -replace '/', '\').Trim('\')
    $current = $GroupInfo
    if (-not $clean) { return $current }
    foreach ($segment in $clean.Split('\')) {
        if (-not $segment) { continue }
        $children = List-GroupChildren $GroupInfo (Get-GroupDirId $current)
        $next = $children | Where-Object { $_.fileName -eq $segment -and $_.fileType -eq 1 } | Select-Object -First 1
        if (-not $next) { throw "Group folder not found: $segment (under $($current.fileName))" }
        $current = $next
    }
    return $current
}

function Resolve-GroupFile($GroupInfo, [string]$FilePath) {
    $clean = ($FilePath -replace '/', '\').Trim('\')
    if (-not $clean) { throw 'download requires -Path <folder/file>.' }
    $parts = @($clean.Split('\') | Where-Object { $_ })
    if ($parts.Count -lt 1) { throw 'download requires -Path <folder/file>.' }
    $fileName = $parts[-1]
    $folderPath = if ($parts.Count -gt 1) { ($parts[0..($parts.Count - 2)] -join '\') } else { '' }
    $parent = Resolve-GroupFolder $GroupInfo $folderPath
    $children = List-GroupChildren $GroupInfo (Get-GroupDirId $parent)
    $file = $children | Where-Object { $_.fileName -eq $fileName -and $_.fileType -ne 1 } | Select-Object -First 1
    if (-not $file) { throw "Group file not found: $fileName (under $($parent.fileName))" }
    return [pscustomobject]@{ file = $file; parent = $parent }
}

function Get-GroupDownloadUrl($GroupInfo, $FileInfo) {
    $u = Get-UserInfo
    $body = @{
        comeFrom = 0; corpId = $u.corpId
        creatorUsn = $FileInfo.createdByUsn
        diskType = 2; downSource = 1
        fileIdList = @(@{
            appFileId = $FileInfo.appFileId; fileSize = $FileInfo.fileSize
            fileVersion = $FileInfo.version; rootUsn = $FileInfo.rootUsn
            fileType = $FileInfo.fileType; fileName = $FileInfo.fileName
            diskType = 2; groupId = $GroupInfo.groupId
        })
        fileName = $FileInfo.fileName; groupId = $GroupInfo.groupId
        isIp = 0; isDownload = 1
    }
    $r = Invoke-EcloudApi -ApiPath '/drive/service/common/file.do?func=common:download' -Body $body
    $url = $r.var.downloadUrl
    if (-not $url) { throw 'Download URL missing from response.' }
    return $url
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:N1} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Assert-Confirmed([string]$What) {
    if (-not $Yes) {
        throw "Refusing to $What without -Yes. Ask the user first, then re-run with -Yes."
    }
}

function Show-Table($Rows, [string[]]$Columns) {
    if ($Json) { $Rows | ConvertTo-Json -Depth 6; return }
    $Rows | Select-Object $Columns | Format-Table -AutoSize | Out-String -Width 240 | Write-Output
}

function Connect-Login {
    if ($Cookie) {
        $map = Parse-CookieString $Cookie
        foreach ($required in 'sid', 'userId', 'orgId') {
            if (-not $map.ContainsKey($required)) { throw "Cookie string is missing '$required'." }
        }
        $data = @{
            baseUrl = $script:BaseUrl
            cookie = ($map.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
            sid = $map['sid']; timeStamp = $map['timeStamp']; token = $map['token']
            userId = $map['userId']; orgId = $map['orgId']
            usn = $null; userName = $null
            im = [bool]($map['timeStamp'] -and $map['token'])
            savedAt = (Get-Date).ToString('o')
        }
        Save-Session $data
        Write-Info "Session saved to $script:SessionPath"
        return
    }

    $helper = Join-Path $PSScriptRoot 'login.mjs'
    if (-not (Test-Path -LiteralPath $helper)) { throw "Login helper not found: $helper" }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Node.js is required for interactive login; or pass -Cookie.' }
    Write-Info 'Opening a dedicated Edge window. Log in to 移动云空间 there; the window closes after the session is captured.'
    & node $helper
    if ($LASTEXITCODE -ne 0) { throw "Interactive login did not complete (exit $LASTEXITCODE)." }
    if (-not (Test-Path -LiteralPath $script:SessionPath)) { throw 'Login helper did not write a session file.' }
    $script:Session = $null
    $s = Get-Session
    if (-not $s.usn) { try { $null = Get-UserInfo } catch { } }
}

$exitCode = 0
try {
    switch ($Command) {
        'login' {
            Connect-Login
            $s = Get-Session
            $u = Get-UserInfo
            Save-Session @{
                baseUrl = $s.baseUrl; cookie = $s.cookie; sid = $s.sid
                timeStamp = $s.timeStamp; token = $s.token; userId = $s.userId
                orgId = $s.orgId; usn = $u.usn; userName = $u.userName
                im = [bool]($s.timeStamp -and $s.token); savedAt = $s.savedAt
            }
            Write-Info "Logged in as $($u.userName) (usn $($u.usn))."
        }
        'status' {
            $s = Get-Session
            $u = Get-UserInfo
            if ($Json) {
                [pscustomobject]@{
                    ok = $true; baseUrl = $s.baseUrl; userName = $u.userName; usn = $u.usn
                    corpId = $u.corpId; userId = $s.userId; orgId = $s.orgId
                    hasImCookies = [bool]($s.timeStamp -and $s.token); savedAt = $s.savedAt
                } | ConvertTo-Json -Depth 4
            } else {
                Write-Output "Session OK: $($u.userName) (usn $($u.usn)), corp $($u.corpId)."
                Write-Output "IM cookies present: $([bool]($s.timeStamp -and $s.token)); saved: $($s.savedAt)"
            }
        }
        'whoami' {
            $s = Get-Session
            $u = Get-UserInfo
            if ($Json) { $u | ConvertTo-Json -Depth 6; break }
            Write-Output "User:      $($u.userName) (usn $($u.usn))"
            Write-Output "Corp:      $($u.corpId)"
            Write-Output "Private:   $(Format-Size ([long]$u.privateStorageQuota)) quota"
            Write-Output "IM user:   $($s.userId)"
            Write-Output "Saved at:  $($s.savedAt)"
        }
        'ls' {
            $p = if ($Path) { $Path } else { '个人盘' }
            $folder = Resolve-Folder $p
            $children = List-Children $folder.appFileId
            if ($Json) {
                [pscustomobject]@{
                    folder = $folder.fileName; folderId = $folder.appFileId
                    items = @($children | ForEach-Object {
                        [pscustomobject]@{
                            name = $_.fileName; type = if ($_.fileType -eq 1) { 'folder' } else { 'file' }
                            size = [long]$_.fileSize; modified = $_.modifyDate
                            id = $_.appFileId; parentId = $_.parentId
                        }
                    })
                } | ConvertTo-Json -Depth 6
                break
            }
            $rows = @($children | ForEach-Object {
                [pscustomobject]@{
                    Type = if ($_.fileType -eq 1) { 'DIR' } else { 'FILE' }
                    Name = $_.fileName
                    Size = if ($_.fileType -eq 1) { '' } else { Format-Size ([long]$_.fileSize) }
                    Modified = $_.modifyDate
                    Id = $_.appFileId
                }
            })
            Write-Output "Folder: $($folder.fileName)  ($($rows.Count) item(s))"
            Show-Table $rows @('Type', 'Name', 'Size', 'Modified', 'Id')
        }
        'mkdir' {
            Assert-Confirmed "create a folder"
            if (-not $Name) { throw 'mkdir requires -Name <folder>.' }
            if ($Name -match '[\\/:*?"<>|]') { throw 'Folder name contains invalid characters.' }
            $p = if ($Path) { $Path } else { '个人盘' }
            $parent = Resolve-Folder $p
            $body = @{
                comeFrom = 0; creatorUsn = 0; diskType = 1
                fileName = $Name; groupId = ''; parentId = $parent.appFileId
            }
            $r = Invoke-EcloudApi -ApiPath '/drive/service/common/file.do?func=common:createFolder' -Body $body
            if ($Json) {
                [pscustomobject]@{ created = $Name; parent = $parent.fileName; parentId = $parent.appFileId; id = $r.var } |
                    ConvertTo-Json -Depth 4
            } else {
                Write-Output "Created folder '$Name' under '$($parent.fileName)'. Id: $($r.var)"
            }
        }
        'groups' {
            $body = @{
                diskType = 2; isGroup = 1; pageSize = 100
                picHeight = 72; picThumbnail = 1; picWidth = 72
                reqPage = 1; searchType = 0; isGroupMembers = $false
            }
            $r = Invoke-EcloudApi -ApiPath '/drive/service/group/group?func=group:groupList' -Body $body
            $groups = @($r.var.resultList)
            if ($Json) {
                [pscustomobject]@{
                    groups = @($groups | ForEach-Object {
                        [pscustomobject]@{
                            groupId = $_.groupId; name = $_.groupName; members = $_.memberCount
                            files = $_.fileCount; createdByUsn = $_.createdByUsn; createdBy = $_.createdByName
                        }
                    })
                } | ConvertTo-Json -Depth 5
                break
            }
            $rows = @($groups | ForEach-Object {
                [pscustomobject]@{
                    GroupId = $_.groupId; Name = $_.groupName; Members = $_.memberCount
                    Files = $_.fileCount; CreatedBy = $_.createdByName
                }
            })
            $rows | Format-Table -AutoSize | Out-String -Width 240 | Write-Output
        }
        'group-ls' {
            $g = Get-Group $Group
            $folder = Resolve-GroupFolder $g $Path
            $children = List-GroupChildren $g (Get-GroupDirId $folder)
            if ($Json) {
                [pscustomobject]@{
                    group = $g.groupName; groupId = $g.groupId
                    folder = $folder.fileName; folderId = $folder.appFileId
                    items = @($children | ForEach-Object {
                        [pscustomobject]@{
                            name = $_.fileName; type = if ($_.fileType -eq 1) { 'folder' } else { 'file' }
                            size = [long]$_.fileSize; modified = $_.modifyDate
                            id = $_.appFileId; parentId = $_.parentId
                        }
                    })
                } | ConvertTo-Json -Depth 6
                break
            }
            $rows = @($children | ForEach-Object {
                [pscustomobject]@{
                    Type = if ($_.fileType -eq 1) { 'DIR' } else { 'FILE' }
                    Name = $_.fileName
                    Size = if ($_.fileType -eq 1) { '' } else { Format-Size ([long]$_.fileSize) }
                    Modified = $_.modifyDate
                    Id = $_.appFileId
                }
            })
            $folderLabel = if ($folder.fileName) { $folder.fileName } else { $folder.groupName }
            Write-Output "Group: $($g.groupName) / $folderLabel  ($($rows.Count) item(s))"
            Show-Table $rows @('Type', 'Name', 'Size', 'Modified', 'Id')
        }
        'group-mkdir' {
            Assert-Confirmed "create a group folder"
            if (-not $Name) { throw 'group-mkdir requires -Name <folder>.' }
            if ($Name -match '[\\/:*?"<>|]') { throw 'Folder name contains invalid characters.' }
            $g = Get-Group $Group
            $parent = Resolve-GroupFolder $g $Path
            $body = @{
                comeFrom = 0; creatorUsn = $g.createdByUsn; diskType = 2
                fileName = $Name; groupId = $g.groupId; parentId = (Get-GroupDirId $parent)
            }
            $r = Invoke-EcloudApi -ApiPath '/drive/service/common/file.do?func=common:createFolder' -Body $body
            if ($Json) {
                [pscustomobject]@{
                    group = $g.groupName; created = $Name; parent = $parent.fileName
                    parentId = $parent.appFileId; id = $r.var
                } | ConvertTo-Json -Depth 4
            } else {
                Write-Output "Created group folder '$Name' under '$($parent.fileName)'. Id: $($r.var)"
            }
        }
        'upload' {
            Assert-Confirmed "upload a file"
            if (-not $File) { throw 'upload requires -File <local path>.' }
            if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "Local file not found: $File" }
            $item = Get-Item -LiteralPath $File
            if ($item.Length -gt 5MB) { throw 'Files over 5 MB need the chunked web uploader; this CLI handles small files only.' }
            $g = Get-Group $Group
            $parent = Resolve-GroupFolder $g $Path
            $u = Get-UserInfo
            $s = Get-Session
            $md5 = (Get-FileHash -LiteralPath $item.FullName -Algorithm MD5).Hash.ToLowerInvariant()
            $remoteName = if ($RemoteName) { $RemoteName } else { $item.Name }
            $form = @{
                file = $item
                parentId = (Get-GroupDirId $parent)
                diskType = '2'
                groupId = [string]$g.groupId
                fileName = $remoteName
                fileSize = [string]$item.Length
                fileMd5 = $md5
                uploadType = '1'
                comeFrom = '0'
                newFlag = '1'
                model = '0'
                usn = [string]$u.usn
                creatorUsn = [string]$g.createdByUsn
                fileType = '2'
                filePath = if ($parent.filePath) { $parent.filePath } else { '/' }
            }
            $headers = @{ Cookie = $s.cookie; Accept = 'application/json, text/plain, */*' }
            $r = Invoke-RestMethod -Uri "$($script:BaseUrl)/drive/service/common/onestfile.do?func=common:onestUpload" `
                -Method Post -Headers $headers -Form $form -TimeoutSec 180
            if ($r.code -ne 'S_OK') { throw "Upload failed: $($r.code) $($r.summary)" }
            $created = $r.var
            if ($Json) {
                [pscustomobject]@{
                    uploaded = $true; group = $g.groupName; parent = $parent.fileName
                    name = $created.fileName; id = $created.appFileId; size = $created.uploadSize
                    md5 = $created.fileMd5
                } | ConvertTo-Json -Depth 4
            } else {
                Write-Output "Uploaded '$($created.fileName)' to '$($g.groupName) / $($parent.fileName)'. Id: $($created.appFileId)"
            }
        }
        'download' {
            Assert-Confirmed "download a file"
            if (-not $Out) { throw 'download requires -Out <local path>.' }
            $g = Get-Group $Group
            $res = Resolve-GroupFile $g $Path
            $f = $res.file
            $url = Get-GroupDownloadUrl $g $f
            $fullOut = [IO.Path]::GetFullPath($Out)
            $dir = Split-Path -Parent $fullOut
            if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            Invoke-WebRequest -Uri $url -OutFile $fullOut -TimeoutSec 180
            $got = Get-Item -LiteralPath $fullOut
            if ($Json) {
                [pscustomobject]@{
                    downloaded = $true; group = $g.groupName; name = $f.fileName
                    out = $fullOut; bytes = $got.Length
                } | ConvertTo-Json -Depth 4
            } else {
                Write-Output "Downloaded '$($f.fileName)' from '$($g.groupName)' to $fullOut ($($got.Length) bytes)."
            }
        }
        'view-url' {
            $g = Get-Group $Group
            $res = Resolve-GroupFile $g $Path
            $f = $res.file
            $u = Get-UserInfo
            $s = Get-Session
            $dl = Get-GroupDownloadUrl $g $f
            $ext = [IO.Path]::GetExtension($f.fileName).TrimStart('.').ToLowerInvariant()
            $body = @{
                downloadUrl = $dl
                fileId = $f.appFileId
                fileName = $f.fileName
                fileType = $ext
                usn = $u.usn
                permission = $f.permission
                isWrite = if ($Edit) { 1 } else { 0 }
                creater = $u.userName
                localType = 0
            } | ConvertTo-Json -Depth 4 -Compress
            $headers = @{
                Cookie = $s.cookie
                'Content-Type' = 'application/json'
                Accept = 'application/json, text/plain, */*'
            }
            $r = Invoke-RestMethod -Uri "$($script:BaseUrl)/api/v1/edit/cloudp/wps/url/getViewUrl" `
                -Method Post -Headers $headers -Body $body -TimeoutSec 30
            $url = $r.content.url
            if (-not $url) {
                throw "WPS URL not returned: code=$($r.code) message=$($r.message) hint=$($r.hint)"
            }
            if ($Json) {
                [pscustomobject]@{
                    group = $g.groupName; name = $f.fileName; edit = [bool]$Edit
                    url = $url; token = $r.content.token
                } | ConvertTo-Json -Depth 4
            } else {
                Write-Output "WPS $([bool]$Edit ? 'edit' : 'view') URL for '$($f.fileName)': $url"
            }
        }
        'im-orgs' {
            $s = Get-Session
            if (-not ($s.timeStamp -and $s.token)) { throw 'Session has no IM cookies (timeStamp/token). Re-run login.' }
            if (-not $s.userId -or -not $s.orgId) { throw 'Session has no IM user/org id. Re-run login.' }
            $ids = Invoke-EcloudApi -ApiPath '/access/IMLogin/getValidOrgIds' -Im -Body @{
                uid = [string]$s.userId; orgType = -1
            }
            $valid = @($ids.data.validOrgIds)
            $names = $null
            if ($valid.Count -gt 0) {
                $nr = Invoke-EcloudApi -ApiPath '/access/Contacts/getOrgsName' -Im -Body @{ orgIds = $valid }
                $names = $nr.data.orgNames
            }
            if ($Json) {
                [pscustomobject]@{
                    organizations = @($valid | ForEach-Object {
                        $orgId = $_
                        $orgName = $null
                        if ($names) {
                            $prop = $names.PSObject.Properties | Where-Object { $_.Name -eq [string]$orgId } | Select-Object -First 1
                            if ($prop) { $orgName = $prop.Value }
                        }
                        [pscustomobject]@{ orgId = $orgId; name = $orgName }
                    })
                } | ConvertTo-Json -Depth 4
            } else {
                $valid | ForEach-Object {
                    $orgId = $_
                    $orgName = $null
                    if ($names) {
                        $prop = $names.PSObject.Properties | Where-Object { $_.Name -eq [string]$orgId } | Select-Object -First 1
                        if ($prop) { $orgName = $prop.Value }
                    }
                    Write-Output ("{0}  {1}" -f $orgId, $orgName)
                }
            }
        }
        'client-info' {
            $exe = 'C:\ProgramData\Ecloud\Ecpan\Ecloud Cloud Ecpan Application.exe'
            $data = Join-Path $env:APPDATA 'suyan\yunpan'
            $proc = Get-Process -Name 'Ecloud Cloud Ecpan Application' -ErrorAction SilentlyContinue |
                Sort-Object StartTime | Select-Object -First 1
            $info = [pscustomobject]@{
                installed = (Test-Path -LiteralPath $exe)
                executable = $exe
                running = [bool]$proc
                pid = if ($proc) { $proc.Id } else { $null }
                dataRoot = $data
                dataRootExists = (Test-Path -LiteralPath $data)
                imDataRoot = if (Test-Path -LiteralPath (Join-Path $data 'data')) {
                    Get-ChildItem -LiteralPath (Join-Path $data 'data') -Directory -ErrorAction SilentlyContinue |
                        Select-Object -First 1 -ExpandProperty FullName
                } else { $null }
                sessionSaved = (Test-Path -LiteralPath $script:SessionPath)
                messaging = 'Desktop-client native IM only; no public HTTP send/list API.'
            }
            if ($Json) { $info | ConvertTo-Json -Depth 4 } else { $info | Format-List | Out-String -Width 240 | Write-Output }
        }
    }
} catch {
    $exitCode = 1
    if ($Json) {
        [pscustomobject]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Depth 3
    } else {
        Write-Error $_.Exception.Message
    }
}
exit $exitCode

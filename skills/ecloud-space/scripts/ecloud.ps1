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
    [ValidateSet('login', 'status', 'whoami', 'ls', 'mkdir', 'stat', 'groups', 'group-ls', 'group-mkdir', 'upload', 'download', 'view-url', 'msg-send', 'msg-chats', 'client-debug-status', 'im-orgs', 'client-info', 'policy')]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Path = '',

    [string]$Name,
    [string]$Group,
    [string]$File,
    [string]$Out,
    [string]$RemoteName,
    [string]$To = '文件传输助手',
    [string]$Text,
    [string]$ConfirmTarget,
    [string]$ConfirmRecipient,
    [string]$Cookie,
    [string]$BaseUrl = 'https://www.ecpan.cn',
    [switch]$Yes,
    [switch]$Edit,
    [switch]$DryRun,
    [switch]$AllowAnyChat,
    [switch]$Personal,
    [switch]$Init,
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

$script:PolicyPath = Join-Path $env:USERPROFILE '.dsh\ecloud\policy.json'
$script:Policy = $null

function Get-Policy {
    if ($script:Policy) { return $script:Policy }
    $defaults = [ordered]@{
        allowedGroups        = @('temp-waicai')
        allowedWriteGroups   = @('temp-waicai')
        allowPublicGroups    = $false
        allowPersonalWrites  = $true
        requireConfirmTarget = $true
        allowedChats         = @('文件传输助手')
        allowAnyChat         = $false
        maxUploadMB          = 5
        maxMessageChars      = 2000
        sendCooldownSeconds  = 3
    }
    $p = @{}
    foreach ($k in $defaults.Keys) { $p[$k] = $defaults[$k] }
    if (Test-Path -LiteralPath $script:PolicyPath) {
        try {
            $o = Get-Content -LiteralPath $script:PolicyPath -Raw -Encoding utf8 | ConvertFrom-Json
        } catch {
            throw "Policy file is invalid: $($script:PolicyPath). Refusing to run. Fix or remove it."
        }
        foreach ($k in $defaults.Keys) {
            $prop = $o.PSObject.Properties[$k]
            if ($prop) { $p[$k] = $prop.Value }
        }
    }
    $p['_path'] = $script:PolicyPath
    $script:Policy = $p
    return $p
}

function Assert-GroupPolicy($GroupInfo, [switch]$Write) {
    $p = Get-Policy
    $name = [string]$GroupInfo.groupName
    $list = if ($Write) { @($p.allowedWriteGroups) } else { @($p.allowedGroups) }
    if ($list -notcontains $name) {
        $mode = if ($Write) { 'write' } else { 'read' }
        throw "Group '$name' is not in the skill's $mode allowlist. Add it to $($p._path) only after an explicit user instruction."
    }
    if ([int]$GroupInfo.isPublic -eq 1 -and -not [bool]$p.allowPublicGroups) {
        throw "Refusing group '$name': it is public and allowPublicGroups is false."
    }
    if ([int]$GroupInfo.diskType -eq 3) {
        throw 'Enterprise space (diskType 3) is read-only/unsupported by this skill.'
    }
}

function Assert-PersonalWrite {
    $p = Get-Policy
    if (-not [bool]$p.allowPersonalWrites) { throw "Personal writes are disabled by $($p._path)." }
}

function Get-CanonicalPath($GroupInfo, [string]$FolderPath) {
    $clean = ($FolderPath -replace '/', '\').Trim('\')
    if ($GroupInfo) {
        $prefix = [string]$GroupInfo.groupName
        if ($clean -eq $prefix) { $clean = '' }
        elseif ($clean.StartsWith($prefix + '\')) { $clean = $clean.Substring($prefix.Length + 1) }
        if ($clean) { return "$prefix\$clean" }
        return $prefix
    }
    $clean = $clean -replace '^(个人盘|个人空间)\\?', ''
    if ($clean) { return "个人盘\$clean" }
    return '个人盘'
}

function Assert-BareName([string]$Value, [string]$What) {
    if (-not $Value) { throw "$What is required." }
    if ($Value -eq '.' -or $Value -eq '..' -or $Value -match '[\\/:*?"<>|]') {
        throw "$What contains invalid characters or a path separator: '$Value'."
    }
}

function Assert-ConfirmTarget([string]$Expected, [string]$Given, [string]$Operation) {
    $p = Get-Policy
    if ([bool]$p.requireConfirmTarget -and $Given -ne $Expected) {
        throw "Refusing to $Operation '$Expected'. Pass -ConfirmTarget '$Expected' exactly."
    }
}

function Assert-ChatPolicy([string]$Chat, [string]$Confirm, [switch]$AllowAny) {
    $p = Get-Policy
    $allowed = @($p.allowedChats)
    if ($allowed -notcontains $Chat) {
        if (-not [bool]$p.allowAnyChat) {
            throw "Chat '$Chat' is not allowlisted. Add it to $($p._path) only after an explicit user instruction."
        }
        if (-not $AllowAny) {
            throw "Chat '$Chat' needs -AllowAnyChat and -ConfirmRecipient '$Chat'."
        }
    }
    if ($Confirm -ne $Chat) {
        throw "Refusing to send: pass -ConfirmRecipient '$Chat' exactly (twice-checked recipient)."
    }
}

function Assert-SendCooldown {
    $p = Get-Policy
    $cooldownPath = Join-Path $env:USERPROFILE '.dsh\ecloud\last-send.json'
    if (Test-Path -LiteralPath $cooldownPath) {
        try {
            $last = Get-Content -LiteralPath $cooldownPath -Raw -Encoding utf8 | ConvertFrom-Json
            $seconds = ((Get-Date) - [datetime]$last.at).TotalSeconds
            if ($seconds -lt [double]$p.sendCooldownSeconds) {
                throw "Refusing to send again within $($p.sendCooldownSeconds) seconds (last send at $($last.at))."
            }
        } catch [System.Management.Automation.RuntimeException] {
            throw
        } catch {
            # A malformed cooldown file must not allow a rapid resend.
            throw "Send cooldown file is malformed: $cooldownPath. Refusing to send."
        }
    }
}

function Set-SendCooldown([string]$Chat) {
    $dir = Join-Path $env:USERPROFILE '.dsh\ecloud'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    @{ at = (Get-Date).ToString('o'); to = $Chat } |
        ConvertTo-Json -Compress |
        Set-Content -LiteralPath (Join-Path $dir 'last-send.json') -Encoding utf8
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
        [switch]$Im,
        [int]$Retry = 0
    )
    $s = Get-Session
    $headers = @{
        'Cookie' = $s.cookie
        'Accept' = 'application/json, text/plain, */*'
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/84.0.4147.89 Safari/537.36'
    }
    $url = $script:BaseUrl + $ApiPath
    $r = $null
    for ($attempt = 0; ; $attempt++) {
        try {
            if ($Method -eq 'Get') {
                $r = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec 30
            } else {
                $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
                $headers['Content-Type'] = 'application/json'
                $r = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $json -TimeoutSec 30
            }
            break
        } catch {
            $resp = $_.Exception.Response
            $status = 0
            if ($resp) { try { $status = [int]$resp.StatusCode } catch { } }
            $message = [string]$_.Exception.Message
            $transient = ($status -in @(502, 503, 504)) -or ($message -match 'timed out|timeout|temporarily|remotely closed|connection')
            if ($attempt -lt $Retry -and $transient) {
                Start-Sleep -Milliseconds (400 * ($attempt + 1))
                continue
            }
            $text = $_.ErrorDetails.Message
            if (-not $text -and $resp) {
                try { $text = $resp.Content.ReadAsStringAsync().Result } catch { }
            }
            if ($status) { throw "HTTP $status from $ApiPath : $text" }
            throw
        }
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
    $r = Invoke-EcloudApi -ApiPath '/drive/service/disk/search.do?func=disk:userInfo' -Body @{} -Retry 2
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
    $r = Invoke-EcloudApi -ApiPath '/drive/service/disk/search.do?func=disk:search' -Body $body -Retry 2
    $root = @($r.var.resultList) | Where-Object { $_.fileName -eq '个人盘' } | Select-Object -First 1
    if (-not $root) { $root = @($r.var.resultList) | Where-Object { $_.fileType -eq 1 } | Select-Object -First 1 }
    if (-not $root) { throw 'Cannot locate the personal disk root (个人盘).' }
    return $root
}

function List-Children([string]$ParentId) {
    $u = Get-UserInfo
    $all = @()
    $page = 1
    $pageCount = 1
    do {
        $body = @{
            diskType = 1; status = 1
            orderField = 'create_date'; orderBy = 'desc'
            usn = $u.usn; parentId = $ParentId; pageSize = 100; reqPage = $page
            picHeight = 72; picThumbnail = 1; picWidth = 72
        }
        $r = Invoke-EcloudApi -ApiPath '/drive/service/disk/search.do?func=disk:search' -Body $body -Retry 2
        $all += @($r.var.resultList)
        if ($null -ne $r.var.pageCount) { $pageCount = [int]$r.var.pageCount }
        $page++
    } while ($page -le $pageCount -and $page -le 10)
    return $all
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
    $r = Invoke-EcloudApi -ApiPath '/drive/service/group/group?func=group:groupList' -Body $body -Retry 2
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
    $all = @()
    $page = 1
    $pageCount = 1
    do {
        $body = @{
            createdByUsn = $GroupInfo.createdByUsn
            diskType = 2; isGroup = 1
            orderBy = 'desc'; orderField = 'modify_date'
            pageSize = 100
            parentId = $ParentId
            picHeight = 72; picThumbnail = 1; picWidth = 72
            reqPage = $page; isGroupMembers = $false
        }
        $r = Invoke-EcloudApi -ApiPath '/drive/service/group/group?func=group:groupList' -Body $body -Retry 2
        $all += @($r.var.resultList | Where-Object { $_.fileName -or $_.groupName })
        if ($null -ne $r.var.pageCount) { $pageCount = [int]$r.var.pageCount }
        $page++
    } while ($page -le $pageCount -and $page -le 10)
    return $all
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

function Resolve-PersonalFile([string]$FilePath) {
    $clean = ($FilePath -replace '/', '\').Trim('\')
    $parts = @($clean.Split('\') | Where-Object { $_ })
    if ($parts.Count -lt 1) { throw 'A file path is required.' }
    if ($parts[0] -eq '个人盘' -or $parts[0] -eq '个人空间') { $parts = @($parts | Select-Object -Skip 1) }
    if ($parts.Count -lt 1) { throw 'A file path is required.' }
    $fileName = $parts[-1]
    $folderPath = if ($parts.Count -gt 1) { ($parts[0..($parts.Count - 2)] -join '\') } else { '' }
    $parent = Resolve-Folder $folderPath
    $children = List-Children $parent.appFileId
    $file = $children | Where-Object { $_.fileName -eq $fileName -and $_.fileType -ne 1 } | Select-Object -First 1
    if (-not $file) { throw "Personal file not found: $fileName (under $($parent.fileName))" }
    return [pscustomobject]@{ file = $file; parent = $parent }
}

function Resolve-PersonalItem([string]$ItemPath) {
    $clean = ($ItemPath -replace '/', '\').Trim('\')
    $parts = @($clean.Split('\') | Where-Object { $_ })
    if ($parts.Count -lt 1) { return (Get-PersonalRoot) }
    if ($parts[0] -eq '个人盘' -or $parts[0] -eq '个人空间') { $parts = @($parts | Select-Object -Skip 1) }
    if ($parts.Count -lt 1) { return (Get-PersonalRoot) }
    $parentPath = if ($parts.Count -gt 1) { ($parts[0..($parts.Count - 2)] -join '\') } else { '' }
    $parent = Resolve-Folder $parentPath
    $children = List-Children $parent.appFileId
    $item = $children | Where-Object { $_.fileName -eq $parts[-1] } | Select-Object -First 1
    if (-not $item) { throw "Personal item not found: $($parts[-1]) (under $($parent.fileName))" }
    return $item
}

function Get-DownloadUrl($FileInfo, [int]$DiskType, [string]$GroupId) {
    $u = Get-UserInfo
    $body = @{
        comeFrom = 0; corpId = $u.corpId
        creatorUsn = $FileInfo.createdByUsn
        diskType = $DiskType; downSource = 1
        fileIdList = @(@{
            appFileId = $FileInfo.appFileId; fileSize = $FileInfo.fileSize
            fileVersion = $FileInfo.version; rootUsn = $FileInfo.rootUsn
            fileType = $FileInfo.fileType; fileName = $FileInfo.fileName
            diskType = $DiskType; groupId = $GroupId
        })
        fileName = $FileInfo.fileName; groupId = $GroupId
        isIp = 0; isDownload = 1
    }
    $r = Invoke-EcloudApi -ApiPath '/drive/service/common/file.do?func=common:download' -Body $body -Retry 2
    $url = $r.var.downloadUrl
    if (-not $url) { throw 'Download URL missing from response.' }
    return $url
}

function Get-CefImStatus {
    $result = [pscustomobject]@{
        available = $false; pages = 0; imPage = $false; url = $null; error = $null
    }
    try {
        $raw = Invoke-WebRequest -Uri 'http://127.0.0.1:9222/json/list' -UseBasicParsing -TimeoutSec 3
        $parsed = $raw.Content | ConvertFrom-Json
        $list = @($parsed)
        $im = $list | Where-Object { $_.type -eq 'page' -and ([string]$_.url) -like '*#/im*' } | Select-Object -First 1
        $result.available = $true
        $result.pages = $list.Count
        $result.imPage = [bool]$im
        if ($im) { $result.url = [string]$im.url }
    } catch {
        $result.error = $_.Exception.Message
    }
    return $result
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
            Assert-PersonalWrite
            Assert-Confirmed "create a folder"
            Assert-BareName $Name 'Folder name'
            $p = if ($Path) { $Path } else { '个人盘' }
            $parent = Resolve-Folder $p
            Assert-ConfirmTarget (Get-CanonicalPath $null $p) $ConfirmTarget 'create a folder in'
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
            Assert-GroupPolicy $g
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
            Assert-BareName $Name 'Folder name'
            $g = Get-Group $Group
            Assert-GroupPolicy $g $true
            $parent = Resolve-GroupFolder $g $Path
            Assert-ConfirmTarget (Get-CanonicalPath $g $Path) $ConfirmTarget 'create a folder in'
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
            if ($Personal -and $Group) { throw 'Choose -Group <name> or -Personal, not both.' }
            if (-not $Personal -and -not $Group) { throw 'upload requires -Group <name> or -Personal.' }
            if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "Local file not found: $File" }
            $item = Get-Item -LiteralPath $File
            $p = Get-Policy
            if ($item.Length -gt ([double]$p.maxUploadMB * 1MB)) {
                throw "File is larger than the policy limit of $($p.maxUploadMB) MB; the chunked uploader is not implemented."
            }
            $u = Get-UserInfo
            $s = Get-Session
            if ($Personal) {
                Assert-PersonalWrite
                $folderPath = if ($Path) { $Path } else { '' }
                $parent = Resolve-Folder $folderPath
                Assert-ConfirmTarget (Get-CanonicalPath $null $folderPath) $ConfirmTarget 'upload into'
                $diskType = 1
                $groupId = ''
                $creatorUsn = $u.usn
                $parentId = $parent.appFileId
                $filePath = $parent.filePath
                $space = 'personal'
                $groupName = $null
            } else {
                $g = Get-Group $Group
                Assert-GroupPolicy $g $true
                $parent = Resolve-GroupFolder $g $Path
                Assert-ConfirmTarget (Get-CanonicalPath $g $Path) $ConfirmTarget 'upload into'
                $diskType = 2
                $groupId = [string]$g.groupId
                $creatorUsn = $g.createdByUsn
                $parentId = Get-GroupDirId $parent
                $filePath = $parent.filePath
                $space = 'group'
                $groupName = $g.groupName
            }
            $md5 = (Get-FileHash -LiteralPath $item.FullName -Algorithm MD5).Hash.ToLowerInvariant()
            $remoteName = if ($RemoteName) { $RemoteName } else { $item.Name }
            Assert-BareName $remoteName 'Remote file name'
            $form = @{
                file = $item
                appFileId = [string]$parentId
                parentId = [string]$parentId
                diskType = [string]$diskType
                groupId = [string]$groupId
                fileName = $remoteName
                fileSize = [string]$item.Length
                fileMd5 = $md5
                uploadType = '1'
                comeFrom = '0'
                newFlag = '1'
                model = '0'
                usn = [string]$u.usn
                creatorUsn = [string]$creatorUsn
                fileType = '2'
                filePath = if ($filePath) { $filePath } else { '/' }
            }
            $headers = @{ Cookie = $s.cookie; Accept = 'application/json, text/plain, */*' }
            $r = Invoke-RestMethod -Uri "$($script:BaseUrl)/drive/service/common/onestfile.do?func=common:onestUpload" `
                -Method Post -Headers $headers -Form $form -TimeoutSec 180
            if ($r.code -ne 'S_OK') { throw "Upload failed: $($r.code) $($r.summary)" }
            $created = $r.var
            $children = if ($Personal) { List-Children $parent.appFileId } else { List-GroupChildren $g (Get-GroupDirId $parent) }
            $found = $children | Where-Object { $_.appFileId -eq $created.appFileId -or $_.fileName -eq $created.fileName } | Select-Object -First 1
            if (-not $found) {
                throw "Upload reported success but '$remoteName' is not visible in the target folder; do not retry blindly."
            }
            if ($Json) {
                [pscustomobject]@{
                    uploaded = $true; space = $space; group = $groupName; parent = $parent.fileName
                    name = $created.fileName; id = $created.appFileId; size = $created.uploadSize
                    md5 = $created.fileMd5
                } | ConvertTo-Json -Depth 4
            } else {
                $where = if ($groupName) { "$groupName / $($parent.fileName)" } else { "个人盘 / $($parent.fileName)" }
                Write-Output "Uploaded '$($created.fileName)' to '$where'. Id: $($created.appFileId)"
            }
        }
        'download' {
            Assert-Confirmed "download a file"
            if (-not $Out) { throw 'download requires -Out <local path>.' }
            if ($Personal -and $Group) { throw 'Choose -Group <name> or -Personal, not both.' }
            if (-not $Personal -and -not $Group) { throw 'download requires -Group <name> or -Personal.' }
            if ($Personal) {
                $res = Resolve-PersonalFile $Path
                $f = $res.file
                $diskType = 1
                $groupId = ''
                $label = '个人盘'
                Assert-ConfirmTarget (Get-CanonicalPath $null $Path) $ConfirmTarget 'download'
            } else {
                $g = Get-Group $Group
                Assert-GroupPolicy $g
                $res = Resolve-GroupFile $g $Path
                $f = $res.file
                $diskType = 2
                $groupId = [string]$g.groupId
                $label = $g.groupName
                Assert-ConfirmTarget (Get-CanonicalPath $g $Path) $ConfirmTarget 'download'
            }
            $url = Get-DownloadUrl $f $diskType $groupId
            $fullOut = [IO.Path]::GetFullPath($Out)
            $dir = Split-Path -Parent $fullOut
            if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            Invoke-WebRequest -Uri $url -OutFile $fullOut -TimeoutSec 180
            $got = Get-Item -LiteralPath $fullOut
            if ([long]$f.fileSize -gt 0 -and $got.Length -ne [long]$f.fileSize) {
                throw "Downloaded size mismatch: expected $($f.fileSize), got $($got.Length). File: $fullOut"
            }
            if ($f.fileMd5 -and ([string]$f.fileMd5).Length -eq 32) {
                $localMd5 = (Get-FileHash -LiteralPath $fullOut -Algorithm MD5).Hash.ToLowerInvariant()
                if ($localMd5 -ne ([string]$f.fileMd5).ToLowerInvariant()) {
                    throw "Downloaded MD5 mismatch: expected $($f.fileMd5), got $localMd5. File: $fullOut"
                }
            }
            if ($Json) {
                [pscustomobject]@{
                    downloaded = $true; space = if ($Personal) { 'personal' } else { 'group' }
                    group = if ($Personal) { $null } else { $g.groupName }; name = $f.fileName
                    out = $fullOut; bytes = $got.Length
                } | ConvertTo-Json -Depth 4
            } else {
                Write-Output "Downloaded '$($f.fileName)' from '$label' to $fullOut ($($got.Length) bytes)."
            }
        }
        'view-url' {
            if ($Personal -and $Group) { throw 'Choose -Group <name> or -Personal, not both.' }
            if ($Personal) {
                $res = Resolve-PersonalFile $Path
                $f = $res.file
                $diskType = 1
                $groupId = ''
                $space = 'personal'
                $label = '个人盘'
                $permission = if ($f.permission) { [string]$f.permission } else { '1111111111' }
            } else {
                $g = Get-Group $Group
                Assert-GroupPolicy $g
                $res = Resolve-GroupFile $g $Path
                $f = $res.file
                $diskType = 2
                $groupId = [string]$g.groupId
                $space = 'group'
                $label = $g.groupName
                $permission = [string]$f.permission
            }
            $u = Get-UserInfo
            $s = Get-Session
            $dl = Get-DownloadUrl $f $diskType $groupId
            $ext = [IO.Path]::GetExtension($f.fileName).TrimStart('.').ToLowerInvariant()
            $body = @{
                downloadUrl = $dl
                fileId = $f.appFileId
                fileName = $f.fileName
                fileType = $ext
                usn = $u.usn
                permission = $permission
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
                    space = $space; group = if ($Personal) { $null } else { $g.groupName }
                    name = $f.fileName; edit = [bool]$Edit; url = $url; token = $r.content.token
                } | ConvertTo-Json -Depth 4
            } else {
                Write-Output "WPS $([bool]$Edit ? 'edit' : 'view') URL for '$label' / '$($f.fileName)': $url"
            }
        }
        'msg-send' {
            $p = Get-Policy
            $msg = if ($Text) { $Text.Trim() } else { '' }
            if (-not $msg) { throw 'msg-send requires a non-empty -Text.' }
            if ($msg.Length -gt [int]$p.maxMessageChars) {
                throw "Message is longer than the policy limit of $($p.maxMessageChars) characters."
            }
            if ($msg -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { throw 'Message contains control characters.' }
            Assert-ChatPolicy $To $ConfirmRecipient -AllowAny:$AllowAnyChat
            if (-not $DryRun) {
                Assert-Confirmed "send a message"
                Assert-SendCooldown
            }
            $helper = Join-Path $PSScriptRoot 'im-send.mjs'
            if (-not (Test-Path -LiteralPath $helper)) { throw "IM send helper not found: $helper" }
            if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Node.js is required for msg-send.' }
            $nodeArgs = @($helper, '--to', $To, '--text', $msg)
            if ($To -ne '文件传输助手') { $nodeArgs += '--allow-any-chat' }
            if ($DryRun) { $nodeArgs += '--dry-run' }
            $output = & node @nodeArgs 2>&1
            $code = $LASTEXITCODE
            $raw = ($output | Out-String).Trim()
            if ($Json) {
                Write-Output $raw
            } else {
                try {
                    $o = $raw | ConvertFrom-Json
                    if ($o.ok) {
                        if ($o.dryRun) { Write-Output "Dry run OK: '$($o.chat)' is open and the editor accepts text." }
                        else { Write-Output "Sent to '$($o.chat)': $msg" }
                    } else {
                        Write-Output "Not sent: $($o.reason) $($o.hint)"
                    }
                } catch {
                    Write-Output $raw
                }
            }
            if ($code -ne 0) { throw "msg-send failed (exit $code): $raw" }
            if (-not $DryRun) { Set-SendCooldown $To }
        }
        'msg-chats' {
            $helper = Join-Path $PSScriptRoot 'im-send.mjs'
            if (-not (Test-Path -LiteralPath $helper)) { throw "IM helper not found: $helper" }
            if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Node.js is required for msg-chats.' }
            $output = & node $helper --list 2>&1
            $code = $LASTEXITCODE
            $raw = ($output | Out-String).Trim()
            if ($Json) {
                Write-Output $raw
            } else {
                try {
                    $o = $raw | ConvertFrom-Json
                    if ($o.ok) {
                        $o.chats | ForEach-Object { Write-Output ("{0}  {1}" -f $_.id, $_.name) }
                    } else { Write-Output "Not available: $($o.reason) $($o.hint)" }
                } catch { Write-Output $raw }
            }
            if ($code -ne 0) { throw "msg-chats failed (exit $code): $raw" }
        }
        'stat' {
            if ($Personal -and $Group) { throw 'Choose -Group <name> or -Personal, not both.' }
            if ($Personal -or -not $Group) {
                $item = Resolve-PersonalItem $Path
                $space = 'personal'
                $groupName = $null
                $label = Get-CanonicalPath $null $Path
            } else {
                $g = Get-Group $Group
                Assert-GroupPolicy $g
                try {
                    $item = Resolve-GroupFolder $g $Path
                } catch {
                    $res = Resolve-GroupFile $g $Path
                    $item = $res.file
                }
                $space = 'group'
                $groupName = $g.groupName
                $label = Get-CanonicalPath $g $Path
            }
            $type = if ([int]$item.fileType -eq 1) { 'folder' } else { 'file' }
            $info = [pscustomobject]@{
                space = $space; group = $groupName; path = $label
                name = $item.fileName; type = $type
                size = [long]$item.fileSize; modified = $item.modifyDate
                id = $item.appFileId; parentId = $item.parentId
                version = $item.version; md5 = $item.fileMd5; permission = $item.permission
            }
            if ($Json) { $info | ConvertTo-Json -Depth 4 } else { $info | Format-List | Out-String -Width 240 | Write-Output }
        }
        'policy' {
            $p = Get-Policy
            if ($Init) {
                Assert-Confirmed 'write the policy file'
                $defaults = [ordered]@{
                    allowedGroups        = @('temp-waicai')
                    allowedWriteGroups   = @('temp-waicai')
                    allowPublicGroups    = $false
                    allowPersonalWrites  = $true
                    requireConfirmTarget = $true
                    allowedChats         = @('文件传输助手')
                    allowAnyChat         = $false
                    maxUploadMB          = 5
                    maxMessageChars      = 2000
                    sendCooldownSeconds  = 3
                }
                $dir = Split-Path -Parent $p._path
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                $defaults | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $p._path -Encoding utf8
            }
            $show = [ordered]@{}
            foreach ($k in $p.Keys) { if ($k -ne '_path') { $show[$k] = $p[$k] } }
            if ($Json) {
                [pscustomobject]@{ path = $p._path; policy = $show } | ConvertTo-Json -Depth 6
            } else {
                Write-Output "Policy file: $($p._path)"
                foreach ($k in $show.Keys) {
                    $v = $show[$k]
                    if ($v -is [array]) { $v = $v -join ', ' }
                    Write-Output ("  {0}: {1}" -f $k, $v)
                }
            }
        }
        'client-debug-status' {
            $st = Get-CefImStatus
            if ($Json) {
                $st | ConvertTo-Json -Depth 3
            } else {
                Write-Output "CEF debug port 9222 available: $($st.available)"
                Write-Output "IM page ready: $($st.imPage)  (pages: $($st.pages))"
                if (-not $st.imPage) {
                    Write-Output 'Start the desktop client with --remote-debugging-port=9222 --remote-allow-origins=* and log in.'
                }
            }
        }
        'im-orgs' {
            $s = Get-Session
            if (-not ($s.timeStamp -and $s.token)) { throw 'Session has no IM cookies (timeStamp/token). Re-run login.' }
            if (-not $s.userId -or -not $s.orgId) { throw 'Session has no IM user/org id. Re-run login.' }
            $ids = Invoke-EcloudApi -ApiPath '/access/IMLogin/getValidOrgIds' -Im -Body @{
                uid = [string]$s.userId; orgType = -1
            } -Retry 2
            $valid = @($ids.data.validOrgIds)
            $names = $null
            if ($valid.Count -gt 0) {
                $nr = Invoke-EcloudApi -ApiPath '/access/Contacts/getOrgsName' -Im -Body @{ orgIds = $valid } -Retry 2
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
            $cef = Get-CefImStatus
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
                cefDebugPort = 9222
                cefDebugAvailable = $cef.available
                imPageAvailable = $cef.imPage
                messaging = 'Code-based send via the client web IM page when the CEF debug port is enabled; otherwise the native client.'
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

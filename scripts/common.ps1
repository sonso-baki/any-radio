$Version = "0.1.0"

$RootDir    = Split-Path $PSScriptRoot -Parent
$ConfigDir  = Join-Path $RootDir "config"
$LangDir    = Join-Path $RootDir "lang"
$ConfigPath = Join-Path $ConfigDir "streams.json"
$LangFile   = Join-Path $ConfigDir "lang.txt"
$LogPath    = Join-Path $ConfigDir "any-radio.log"
$FfmpegErrPath = Join-Path $ConfigDir "ffmpeg-error.log"
$Mp3CachePath = Join-Path $ConfigDir "direct-mp3-cache.json"
$FFmpegPathCache = Join-Path $ConfigDir "ffmpeg-path.txt"
$RadioPath = "/radio.mp3"

$script:DirectMp3Cache = $null

$script:CacheTtlDays = 7
$script:LogMaxBytes = 1MB

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Get-SafeUrl($url) {
    if ([string]::IsNullOrWhiteSpace($url)) { return "" }
    return [regex]::Replace($url, '(?<=//)[^/@]+@', '***:***@')
}

function Write-Utf8NoBom($path, $text) {
    try {
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($path, $text, $enc)
        return $true
    } catch {
        Write-Log "ERROR" "Write-Utf8NoBom failed for $($path): $($_.Exception.Message)"
        return $false
    }
}

function Get-SafeSiiText($s) {
    if ($null -eq $s) { return "" }
    $t = [string]$s
    $t = $t.Trim()
    $t = $t.Replace('|', '¦')
    $t = $t.Replace('"', "'")
    $t = $t.Replace('\', '/')
    return $t
}

function ConvertTo-SiiLine($url, $name, $genre, $lang, $bitrate, $fav) {
    $safeName = Get-SafeSiiText $name
    $safeGenre = Get-SafeSiiText $genre
    $safeLang = Get-SafeSiiText $lang
    $safeBitrate = Get-SafeSiiText $bitrate
    $safeFav = Get-SafeSiiText $fav
    return ($url + "|" + $safeName + "|" + $safeGenre + "|" + $safeLang + "|" + $safeBitrate + "|" + $safeFav)
}

function Rotate-LogIfNeeded($path) {
    try {
        if (-not (Test-Path $path)) { return }
        $len = (Get-Item $path).Length
        if ($len -lt $script:LogMaxBytes) { return }
        $max = 5
        $slot = 0
        for ($i = 1; $i -le $max; $i++) {
            if (-not (Test-Path "$path.$i")) { $slot = $i; break }
        }
        if ($slot -eq 0) {
            $oldest = "$path.$max"
            if (Test-Path $oldest) { Remove-Item $oldest -Force -ErrorAction SilentlyContinue }
            for ($i = $max - 1; $i -ge 1; $i--) {
                $from = "$path.$i"
                $to = "$path.$($i + 1)"
                if (Test-Path $from) { Move-Item $from $to -Force -ErrorAction SilentlyContinue }
            }
            $slot = 1
        }
        Move-Item $path "$path.$slot" -Force -ErrorAction SilentlyContinue
    } catch {}
}

function Write-Log($level, $msg) {
    try {
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        Rotate-LogIfNeeded $LogPath
        $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $level, $msg
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($LogPath, $line + "`r`n", $enc)
    } catch {}
}

function Show-Error($msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    Write-Log "ERROR" $msg
}

function Get-GameName($Game) {
    if ($Game -eq "ats") { return "ATS" }
    return "ETS2"
}

function Show-Header($Title, $Game) {
    Clear-Host
    $name = Get-GameName $Game
    Write-Host "=== $Title ($name) $Version ===" -ForegroundColor Cyan
    Write-Host ""
}

function Find-Vlc {
    $c = @("$env:ProgramFiles\VideoLAN\VLC\vlc.exe", "${env:ProgramFiles(x86)}\VideoLAN\VLC\vlc.exe")
    foreach ($p in $c) { if (Test-Path $p) { return $p } }
    $rp = @("HKLM:\SOFTWARE\VideoLAN\VLC", "HKLM:\SOFTWARE\WOW6432Node\VideoLAN\VLC", "HKCU:\SOFTWARE\VideoLAN\VLC")
    foreach ($r in $rp) {
        if (Test-Path $r) {
            $d = (Get-ItemProperty $r -ErrorAction SilentlyContinue).InstallDir
            if ($d) { $e = Join-Path $d "vlc.exe"; if (Test-Path $e) { return $e } }
        }
    }
    $w = (& where.exe vlc 2>$null) | Select-Object -First 1
    if ($w -and (Test-Path $w)) { return $w }
    $l = Join-Path $PSScriptRoot "vlc.exe"
    if (Test-Path $l) { return $l }
    return $null
}

function Get-FFmpegCandidates {
    $c = @()
    $w = (& where.exe ffmpeg 2>$null) | Select-Object -First 1
    if ($w) { $c += $w }
    $c += (Join-Path $PSScriptRoot "ffmpeg.exe")
    $c += (Join-Path $PSScriptRoot "ffmpeg\bin\ffmpeg.exe")
    $c += "C:\ffmpeg\bin\ffmpeg.exe"
    $c += "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe"
    $c += "${env:ProgramFiles(x86)}\ffmpeg\bin\ffmpeg.exe"
    $c += "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg*\ffmpeg-*\bin\ffmpeg.exe"
    $c += "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\*ffmpeg*\*\bin\ffmpeg.exe"
    $c += "C:\ProgramData\chocolatey\bin\ffmpeg.exe"
    $c += "C:\ProgramData\chocolatey\lib\ffmpeg\tools\ffmpeg\bin\ffmpeg.exe"
    $c += "$env:USERPROFILE\scoop\shims\ffmpeg.exe"
    $c += "$env:USERPROFILE\scoop\apps\ffmpeg\current\bin\ffmpeg.exe"
    $c += "$env:LOCALAPPDATA\Programs\ffmpeg\bin\ffmpeg.exe"
    return $c
}

function Find-FFmpeg {
    foreach ($p in (Get-FFmpegCandidates)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($p -match '[\*\?]') {
            $found = Get-ChildItem -Path $p -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found -and (Test-Path $found.FullName)) { return $found.FullName }
        } else {
            if (Test-Path $p) { return $p }
        }
    }
    return $null
}

function Test-FFmpegEncoders($path) {
    if (-not $path -or -not (Test-Path $path)) { return $false }
    try {
        $tmp = [System.IO.Path]::GetTempFileName()
        $p = Start-Process -FilePath $path -ArgumentList @("-hide_banner","-encoders") -NoNewWindow -Wait -RedirectStandardOutput $tmp -RedirectStandardError "$tmp.err" -PassThru
        $out = ""
        if (Test-Path $tmp) { $out += [System.IO.File]::ReadAllText($tmp) }
        if (Test-Path "$tmp.err") { $out += [System.IO.File]::ReadAllText("$tmp.err") }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Remove-Item "$tmp.err" -Force -ErrorAction SilentlyContinue
        return ($out -match 'libmp3lame')
    } catch {
        return $false
    }
}

function Get-CachedFFmpegPath {
    if (-not (Test-Path $FFmpegPathCache)) { return $null }
    try {
        $p = (Get-Content $FFmpegPathCache -Raw).Trim()
        if ($p -and (Test-Path $p)) { return $p }
    } catch {}
    return $null
}

function Find-FFmpegFull {
    $cached = Get-CachedFFmpegPath
    if ($cached) { return $cached }
    $seen = @()
    foreach ($p in (Get-FFmpegCandidates)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $resolved = @()
        if ($p -match '[\*\?]') {
            $resolved = @(Get-ChildItem -Path $p -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        } else {
            if (Test-Path $p) { $resolved = @($p) }
        }
        foreach ($r in $resolved) {
            if ($seen -contains $r) { continue }
            $seen += $r
            if (Test-FFmpegEncoders $r) {
                try { Set-Content -Path $FFmpegPathCache -Value $r -Encoding UTF8 -NoNewline } catch {}
                return $r
            }
        }
    }
    return $null
}

function Install-FFmpeg {
    $winget = (& where.exe winget 2>$null) | Select-Object -First 1
    if (-not $winget) { Write-Host $L.WingetNotFound; return $false }
    Write-Host $L.InstallFFmpeg -ForegroundColor Yellow
        Start-Process -FilePath $winget -ArgumentList "install", "Gyan.FFmpeg", "--accept-package-agreements", "--accept-source-agreements" -Wait -NoNewWindow
    if (Test-Path $FFmpegPathCache) { Remove-Item $FFmpegPathCache -Force -ErrorAction SilentlyContinue }
    $ff = Find-FFmpegFull
    if ($ff) { Write-Host "$($L.FFmpegInstalled): $ff" -ForegroundColor Green; return $true }
    else { Write-Host $L.FFmpegFailed -ForegroundColor Red; return $false }
}

function Find-Game($Game) {
    $steamPath = $null
    $reg = "HKCU:\Software\Valve\Steam"
    if (Test-Path $reg) { $steamPath = (Get-ItemProperty $reg -ErrorAction SilentlyContinue).SteamPath }
    $libs = @()
    if ($steamPath) {
        $libs += $steamPath
        $vdf = Join-Path $steamPath "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            $raw = Get-Content $vdf -Raw
            [regex]::Matches($raw, '"path"\s+"([^"]+)"') | ForEach-Object { $libs += ($_.Groups[1].Value -replace '\\\\', '\') }
        }
    }
    $libs += "${env:ProgramFiles(x86)}\Steam"
    $libs += "$env:ProgramFiles\Steam"
    if ($Game -eq "ats") { $rel = "steamapps\common\American Truck Simulator\bin\win_x64"; $exe = "amtrucks.exe" }
    elseif ($Game -eq "ets2") { $rel = "steamapps\common\Euro Truck Simulator 2\bin\win_x64"; $exe = "eurotrucks2.exe" }
    else { return $null }
    foreach ($l in $libs) {
        if (-not $l) { continue }
        $d = Join-Path $l $rel
        $e = Join-Path $d $exe
        if (Test-Path $e) { return $d }
    }
    $local = Join-Path $PSScriptRoot "..\..\..\..\..\$rel"
    if (Test-Path (Join-Path $local $exe)) { return (Resolve-Path $local).Path }
    return $null
}

function Get-SiiPath($Game) {
    if ($Game -eq "ats")  { return Join-Path $env:USERPROFILE "Documents\American Truck Simulator\live_streams.sii" }
    if ($Game -eq "ets2") { return Join-Path $env:USERPROFILE "Documents\Euro Truck Simulator 2\live_streams.sii" }
    return $null
}

function Backup-Sii($path) {
    $b1 = "$path.bak1"
    $b2 = "$path.bak2"
    $b3 = "$path.bak3"
    if (Test-Path $b2) { try { Copy-Item $b2 $b1 -Force -ErrorAction Stop } catch { Write-Log "WARN" "Backup-Sii: cannot copy to $b1" } }
    if (Test-Path $b3) { try { Copy-Item $b3 $b2 -Force -ErrorAction Stop } catch { Write-Log "WARN" "Backup-Sii: cannot copy to $b2" } }
    try { Copy-Item $path $b3 -Force -ErrorAction Stop } catch { Write-Log "WARN" "Backup-Sii: cannot copy to $b3" }
}

function Test-ProxyUrl($url) {
    if ([string]::IsNullOrWhiteSpace($url)) { return $false }
    return ($url -match '^http://127\.0\.0\.1:\d+/')
}

function Test-LocalUrl($url) {
    if ([string]::IsNullOrWhiteSpace($url)) { return $false }
    try {
        $u = [System.Uri]$url
    } catch {
        return $false
    }
    if ($null -eq $u -or [string]::IsNullOrWhiteSpace($u.Host)) { return $false }
    $h = $u.Host.ToLowerInvariant()
    if ($h -eq "localhost") { return $true }
    if ($h -eq "127.0.0.1" -or $h -eq "0.0.0.0") { return $true }
    if ($h -eq "[::1]" -or $h -eq "::1") { return $true }
    if ($h -match '^127\.') { return $true }
    return $false
}

function Get-PortFromProxyUrl($url) {
    if ([string]::IsNullOrWhiteSpace($url)) { return 0 }
    $m = [regex]::Match($url, '^http://127\.0\.0\.1:(\d+)/')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

function Read-Sii($Game) {
    $path = Get-SiiPath $Game
    if (-not (Test-Path $path)) { return $null }
    $raw = Get-Content $path -Raw
    if ([string]::IsNullOrEmpty($raw)) { return $null }
    $countMatch = [regex]::Match($raw, '(?m)^stream_data:\s*(\d+)')
    $count = if ($countMatch.Success) { [int]$countMatch.Groups[1].Value } else { 0 }
    $items = @()
    [regex]::Matches($raw, 'stream_data\[(\d+)\]:\s*"([^"]+)"') | ForEach-Object {
        $idx = [int]$_.Groups[1].Value
        $content = $_.Groups[2].Value
        $parts = $content -split '\|'
        $items += [PSCustomObject]@{
            Index   = $idx
            Raw     = $content
            Url     = $parts[0]
            Name    = if ($parts.Count -gt 1) { $parts[1] } else { "" }
            Genre   = if ($parts.Count -gt 2) { $parts[2] } else { "" }
            Lang    = if ($parts.Count -gt 3) { $parts[3] } else { "" }
            Bitrate = if ($parts.Count -gt 4) { $parts[4] } else { "" }
            Fav     = if ($parts.Count -gt 5) { $parts[5] } else { "" }
        }
    }
    return [PSCustomObject]@{ Path = $path; Count = $count; Items = $items; Raw = $raw }
}

function Get-StreamsFromSii($Game) {
    $sii = Read-Sii $Game
    if (-not $sii) { return @() }
    $list = @()
    foreach ($it in $sii.Items) {
        $url = $it.Url
        $port = Get-PortFromProxyUrl $url
        $list += [PSCustomObject]@{
            url = $url; port = $port; name = $it.Name
            genre = $it.Genre; lang = $it.Lang; bitrate = $it.Bitrate; fav = $it.Fav
            isProxy = (Test-ProxyUrl $url)
        }
    }
    return $list
}

function Sync-IndexFromSii($Game, $cfg) {
    if (-not $cfg -or -not $cfg.streams) { return 0 }
    $sii = Read-Sii $Game
    if (-not $sii) { return 0 }
    $byName = @{}
    foreach ($it in $sii.Items) {
        if ($it.Name) { $byName[$it.Name] = [int]$it.Index }
    }
    $changed = 0
    foreach ($s in $cfg.streams) {
        $newIdx = -1
        if ($s.name -and $byName.ContainsKey($s.name)) { $newIdx = $byName[$s.name] }
        $oldIdx = -1
        if ($s.PSObject.Properties['index'] -and $null -ne $s.index) { $oldIdx = [int]$s.index }
        if ($oldIdx -ne $newIdx) {
            $s | Add-Member -NotePropertyName index -NotePropertyValue $newIdx -Force
            $changed++
        }
    }
    if ($changed -gt 0) {
        $cfg.streams = @($cfg.streams | Sort-Object @{ Expression = { if ($_.PSObject.Properties['index'] -and $_.index -ge 0) { [int]$_.index } else { [int]::MaxValue } } }, @{ Expression = { $_.name } })
    }
    return $changed
}

function Add-SiiLine($Game, $rawLine) {
    $path = Get-SiiPath $Game
    if (-not (Test-Path $path)) { return $false }
    try {
        $raw = Get-Content $path -Raw
        if ([string]::IsNullOrEmpty($raw)) { return $false }
        $countMatch = [regex]::Match($raw, '(?m)^stream_data:\s*(\d+)')
        if (-not $countMatch.Success) { return $false }
        $oldCount = [int]$countMatch.Groups[1].Value
        $matches = [regex]::Matches($raw, 'stream_data\[(\d+)\]:\s*"([^"]+)"')
        if ($matches.Count -eq 0) { $insertAfter = $countMatch.Index + $countMatch.Length }
        else { $last = $matches[$matches.Count - 1]; $insertAfter = $last.Index + $last.Length }
        Backup-Sii $path
        $parts = $rawLine -split '\|'
        if ($parts.Count -ge 1) {
            $safeParts = @($parts[0])
            for ($i = 1; $i -lt $parts.Count; $i++) { $safeParts += (Get-SafeSiiText $parts[$i]) }
            $safeLine = $safeParts -join '|'
        } else {
            $safeLine = $rawLine
        }
        $newLine = "`r`nstream_data[$oldCount]: `"$safeLine`""
        $raw = $raw.Substring(0, $insertAfter) + $newLine + $raw.Substring($insertAfter)
        $raw = [regex]::Replace($raw, '(?m)^stream_data:\s*\d+', "stream_data: $($oldCount + 1)", 1)
        $raw = [regex]::Replace($raw, '"\s*\}', "`r`n}`r`n")
        if (-not (Write-Utf8NoBom $path $raw)) { throw "Write failed" }
        Write-Log "INFO" "Add-SiiLine ok: $(Get-SafeUrl $safeLine)"
        return $true
    } catch {
        Write-Log "ERROR" "Add-SiiLine failed: $($_.Exception.Message)"
        return $false
    }
}

function Remove-SiiLine($Game, $url) {
    $path = Get-SiiPath $Game
    if (-not (Test-Path $path)) { return $false }
    try {
        $raw = Get-Content $path -Raw
        if ([string]::IsNullOrEmpty($raw)) { return $false }
        $pattern = 'stream_data\[(\d+)\]:\s*"([^"]+)"'
        $matches = [regex]::Matches($raw, $pattern)
        $toRemove = $null
        foreach ($m in $matches) {
            $content = $m.Groups[2].Value
            $parts = $content -split '\|'
            if ($parts[0] -eq $url) { $toRemove = $m; break }
        }
        if (-not $toRemove) { return $false }
        Backup-Sii $path
        $raw = $raw.Remove($toRemove.Index, $toRemove.Length)
        $remaining = [regex]::Matches($raw, $pattern)
        $list = @()
        foreach ($m in $remaining) { $list += [PSCustomObject]@{ Index = $m.Index; Length = $m.Length; Content = $m.Groups[2].Value } }
        for ($k = $list.Count - 1; $k -ge 0; $k--) {
            $item = $list[$k]
            $newLine = "stream_data[$k]: `"$($item.Content)`""
            $raw = $raw.Substring(0, $item.Index) + $newLine + $raw.Substring($item.Index + $item.Length)
        }
        $raw = [regex]::Replace($raw, '(?m)^stream_data:\s*\d+', "stream_data: $($list.Count)", 1)
        if (-not (Write-Utf8NoBom $path $raw)) { throw "Write failed" }
        Write-Log "INFO" "Remove-SiiLine ok: $(Get-SafeUrl $url)"
        return $true
    } catch {
        Write-Log "ERROR" "Remove-SiiLine failed: $($_.Exception.Message)"
        return $false
    }
}

function Update-SiiLine($Game, $oldName, $siiUrl, $newName, $genre, $lang, $bitrate, $fav) {
    $path = Get-SiiPath $Game
    if (-not (Test-Path $path)) {
        Write-Log "WARN" "Update-SiiLine: sii not found at $path"
        return $false
    }
    try {
        $raw = Get-Content $path -Raw
        if ([string]::IsNullOrEmpty($raw)) {
            Write-Log "WARN" "Update-SiiLine: sii empty"
            return $false
        }
        $pattern = 'stream_data\[(\d+)\]:\s*"([^"]+)"'
        $matches = [regex]::Matches($raw, $pattern)
        $target = $null
        foreach ($m in $matches) {
            $content = $m.Groups[2].Value
            $parts = $content -split '\|'
            $name = if ($parts.Count -gt 1) { $parts[1] } else { "" }
            if ($name -eq $oldName) { $target = $m; break }
        }
        if (-not $target) {
            Write-Log "WARN" "Update-SiiLine: name not found [$oldName], trying by URL"
            foreach ($m in $matches) {
                $content = $m.Groups[2].Value
                $parts = $content -split '\|'
                if ($parts[0] -eq $siiUrl) { $target = $m; break }
            }
        }
        if (-not $target) {
            Write-Log "WARN" "Update-SiiLine: oldName/url not found [$oldName]"
            return $false
        }
        $newContent = ConvertTo-SiiLine $siiUrl $newName $genre $lang $bitrate $fav
        Backup-Sii $path
        $raw = $raw.Substring(0, $target.Index) + ('stream_data[' + $target.Groups[1].Value + ']: "' + $newContent + '"') + $raw.Substring($target.Index + $target.Length)
        if (-not (Write-Utf8NoBom $path $raw)) { throw "Write failed" }
        Write-Log "INFO" "Update-SiiLine ok: [$oldName] -> [$newName]"
        return $true
    } catch {
        Write-Log "ERROR" "Update-SiiLine failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-SiiUrlForStream($s) {
    $p = 0
    if ($s.PSObject.Properties['port'] -and $s.port) { $p = [int]$s.port }
    if ($p -gt 0) { return "http://127.0.0.1:$p$RadioPath" }
    return $s.url
}

function Rewrite-Sii($Game, $cfg, $mode) {
    $path = Get-SiiPath $Game
    if (-not (Test-Path $path)) {
        Write-Log "WARN" "Rewrite-Sii: sii not found at $path"
        return $null
    }
    try {
        $lines = @()
        $existingNames = @{}
        if ($mode -eq "append") {
            $sii = Read-Sii $Game
            if ($sii) {
                foreach ($it in ($sii.Items | Sort-Object Index)) {
                    $lines += $it.Raw
                    if ($it.Name) { $existingNames[$it.Name] = $true }
                }
            }
        }
        $added = 0
        $skippedDup = 0
        foreach ($s in $cfg.streams) {
            if ($mode -eq "append" -and $s.name -and $existingNames.ContainsKey($s.name)) { $skippedDup++; continue }
            $siiUrl = Get-SiiUrlForStream $s
            $line = ConvertTo-SiiLine $siiUrl $s.name $s.genre $s.lang $s.bitrate $s.fav
            $lines += $line
            $added++
            if ($s.name) { $existingNames[$s.name] = $true }
        }
        Backup-Sii $path
        $raw = Get-Content $path -Raw
        $nameless = "_nameless.27e.08c9.8ac8"
        $nm = [regex]::Match($raw, 'live_stream_def\s*:\s*(_nameless\.[0-9a-fA-F.]+)')
        if ($nm.Success) { $nameless = $nm.Groups[1].Value }
        $head = "SiiNunit`r`n{`r`nlive_stream_def : $nameless {`r`nstream_data: $($lines.Count)`r`n"
        $body = ""
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $body += "stream_data[$i]: `"$($lines[$i])`"`r`n"
        }
        $tail = "}`r`n}`r`n"
        $out = $head + $body + $tail
        if (-not (Write-Utf8NoBom $path $out)) { throw "Write failed" }
        Write-Log "INFO" "Rewrite-Sii ($mode): total $($lines.Count), added $added, skipped dup $skippedDup"
        return [PSCustomObject]@{ Total = $lines.Count; Added = $added; SkippedDup = $skippedDup }
    } catch {
        Write-Log "ERROR" "Rewrite-Sii failed: $($_.Exception.Message)"
        return $null
    }
}

function Get-CacheAndLogsInfo($Game) {
    $items = @()
    $total = 0
    $targets = @(
        @{ Path = $Mp3CachePath; Kind = "cache" }
    )
    for ($i = 1; $i -le 5; $i++) {
        $targets += @{ Path = "$LogPath.$i"; Kind = "log_old" }
        $targets += @{ Path = "$FfmpegErrPath.$i"; Kind = "log_old" }
    }
    $targets += @{ Path = $LogPath; Kind = "log_cur" }
    $targets += @{ Path = $FfmpegErrPath; Kind = "log_cur" }
    $siiPath = Get-SiiPath $Game
    if ($siiPath) {
        $targets += @{ Path = "$siiPath.bak1"; Kind = "bak" }
        $targets += @{ Path = "$siiPath.bak2"; Kind = "bak" }
    }
    $targets += @{ Path = (Join-Path $ConfigDir "streams-export.json"); Kind = "export" }
    foreach ($t in $targets) {
        if (Test-Path $t.Path) {
            $len = 0
            try { $len = (Get-Item $t.Path).Length } catch {}
            $items += [PSCustomObject]@{ Path = $t.Path; Kind = $t.Kind; Size = $len }
            $total += $len
        }
    }
    return [PSCustomObject]@{ Items = $items; TotalBytes = $total }
}

function Clear-CacheAndLogs($Game, $skipCurrentLogs) {
    $info = Get-CacheAndLogsInfo $Game
    $deleted = 0
    $skipped = 0
    $freed = 0
    foreach ($it in $info.Items) {
        if ($skipCurrentLogs -and $it.Kind -eq "log_cur") { $skipped++; continue }
        try {
            Remove-Item $it.Path -Force -ErrorAction Stop
            $deleted++
            $freed += $it.Size
        } catch {
            $skipped++
            Write-Log "WARN" "Clear-CacheAndLogs: failed to delete $($it.Path): $($_.Exception.Message)"
        }
    }
    $script:DirectMp3Cache = $null
    Write-Log "INFO" "Clear-CacheAndLogs: deleted $deleted, skipped $skipped, freed $freed bytes"
    return [PSCustomObject]@{ Deleted = $deleted; Skipped = $skipped; Freed = $freed }
}

function Test-PortFree($port) {
    if ($port -le 0) { return $false }
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $client.ConnectAsync("127.0.0.1", $port)
        if ($task.Wait(200)) {
            $client.Close()
            return $false
        }
        $client.Close()
        return $true
    } catch {
        return $true
    }
}

function Get-FreePort($cfg, $start = 18084, $end = 20000) {
    $used = @()
    if ($cfg -and $cfg.streams) {
        $used = @($cfg.streams | ForEach-Object { if ($_.PSObject.Properties['port'] -and $_.port) { [int]$_.port } } | Where-Object { $_ -gt 0 })
    }
    for ($p = [int]$start; $p -le [int]$end; $p++) {
        if (($used -notcontains $p) -and (Test-PortFree $p)) { return $p }
    }
    return $null
}

function Test-Url($url) {
    if ([string]::IsNullOrWhiteSpace($url)) { return $false }
    if ($url -match '\s') { return $false }
    if (Test-LocalUrl $url) { return $false }
    try {
        $u = [System.Uri]$url
        if ($u.Scheme -ne "http") { return $false }
        if ([string]::IsNullOrWhiteSpace($u.Host)) { return $false }
        return $true
    } catch {
        return $false
    }
}

function Test-Keyword($value, $keywords) {
    if ($null -eq $value) { return $false }
    $s = ("$value").Trim()
    if ($s.Length -eq 0) { return $false }
    $s = $s.Normalize([System.Text.NormalizationForm]::FormC)
    $s = [regex]::Replace($s, '[\u200B-\u200D\uFEFF]', '')
    if ($s.Length -eq 0) { return $false }
    $low = $s.ToLowerInvariant()
    foreach ($k in $keywords) {
        if ($low -eq $k.ToLowerInvariant()) { return $true }
    }
    return $false
}

function Read-UrlInput($L) {
    $res = [PSCustomObject]@{ Ok = $false; Back = $false; Url = ""; Error = ""; Replaced = $false }
    $url = Read-Host $L.Url
    $url = "$url".Trim()
    if (Test-Keyword $url $L.BackKeywords) { $res.Back = $true; return $res }
    if (-not $url) { Write-Host $L.UrlRequired -ForegroundColor Red; $res.Error = "empty"; return $res }
    if (Test-LocalUrl $url) { Write-Host $L.UrlLocal -ForegroundColor Red; $res.Error = "local"; return $res }
    if ($url -match '^https://') {
        $alt = $url -replace '^https://', 'http://'
        if (-not (Test-Url $alt)) { Write-Host $L.UrlInvalid -ForegroundColor Red; $res.Error = "invalid"; return $res }
        Write-Host $L.UrlHttpsAsk -ForegroundColor Yellow
        $ha = Read-Host "$($L.YN)"
        if (Test-Keyword $ha $L.BackKeywords) { $res.Back = $true; return $res }
        if (-not (Test-Keyword $ha $L.YesKeywords)) {
            if (Test-Keyword $ha $L.NoKeywords) { Write-Host $L.Cancelled -ForegroundColor Yellow; $res.Error = "cancelled"; return $res }
            Write-Host $L.InvalidChoice -ForegroundColor Red; $res.Error = "invalid"; return $res
        }
        $url = $alt
        Write-Host "$($L.ImportHttpsReplaced) $alt" -ForegroundColor Yellow
        $res.Replaced = $true
    } elseif (-not (Test-Url $url)) {
        if ($url -match '^http://') { Write-Host $L.UrlIncomplete -ForegroundColor Red }
        else { Write-Host $L.UrlInvalid -ForegroundColor Red }
        $res.Error = "invalid"
        return $res
    }
    $res.Ok = $true
    $res.Url = $url
    return $res
}

function Read-TranscodeAnswer($L) {
    $res = [PSCustomObject]@{ Ok = $false; Back = $false; Value = $null }
    $tc = Read-Host $L.Transcode
    if (Test-Keyword $tc $L.BackKeywords) { $res.Back = $true; return $res }
    if (Test-Keyword $tc $L.YesKeywords) { $res.Ok = $true; $res.Value = $true; return $res }
    if (Test-Keyword $tc $L.NoKeywords) { $res.Ok = $true; $res.Value = $false; return $res }
    Write-Host $L.InvalidChoice -ForegroundColor Red
    return $res
}

function Parse-IndexListStrict($raw, $count) {
    $res = [PSCustomObject]@{ Ok = $false; Error = ""; Indexes = @(); BadIndexes = @() }
    $s = "$raw".Trim()
    if ($s -eq "") { $res.Error = "format"; return $res }
    if ($s -eq "all") {
        if ($count -le 0) { $res.Error = "empty"; return $res }
        $res.Ok = $true
        $res.Indexes = @(0..($count - 1))
        return $res
    }
    if ($s -notmatch '^\s*\d+\s*(-\s*\d+\s*)?(,\s*\d+\s*(-\s*\d+\s*)?)*$') {
        $res.Error = "format"
        return $res
    }
    $result = @()
    $bad = @()
    foreach ($part in ($s -split ',')) {
        $p = $part.Trim()
        if ($p -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
            for ($i = $a; $i -le $b; $i++) {
                if ($i -lt 0 -or $i -ge $count) { $bad += $i } else { $result += $i }
            }
        } elseif ($p -match '^\d+$') {
            $i = [int]$p
            if ($i -lt 0 -or $i -ge $count) { $bad += $i } else { $result += $i }
        }
    }
    if ($bad.Count -gt 0) {
        $res.Error = "range"
        $res.BadIndexes = @($bad | Sort-Object -Unique)
        return $res
    }
    $res.Ok = $true
    $res.Indexes = @($result | Sort-Object -Unique)
    return $res
}

function Format-IndexList($indexes) {
    if (-not $indexes -or $indexes.Count -eq 0) { return "" }
    $sorted = @($indexes | Sort-Object -Unique)
    $parts = @()
    $start = $sorted[0]
    $prev = $sorted[0]
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $cur = $sorted[$i]
        if ($cur -eq $prev + 1) {
            $prev = $cur
        } else {
            if ($start -eq $prev) { $parts += "[$start]" }
            else { $parts += "[$start-$prev]" }
            $start = $cur
            $prev = $cur
        }
    }
    if ($start -eq $prev) { $parts += "[$start]" }
    else { $parts += "[$start-$prev]" }
    return ($parts -join ", ")
}

function Load-Mp3Cache {
    if ($null -ne $script:DirectMp3Cache) { return }
    $script:DirectMp3Cache = @{}
    if (-not (Test-Path $Mp3CachePath)) { return }
    try {
        $raw = Get-Content $Mp3CachePath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $obj = $raw | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) {
            $v = $p.Value
            if ($v -is [bool]) {
                $script:DirectMp3Cache[$p.Name] = [PSCustomObject]@{ direct = [bool]$v; ts = [datetime]::MinValue }
            } elseif ($v -and $v.PSObject.Properties['direct']) {
                $ts = [datetime]::MinValue
                if ($v.PSObject.Properties['ts'] -and $v.ts) {
                    try { $ts = [datetime]::Parse([string]$v.ts) } catch { $ts = [datetime]::MinValue }
                }
                $script:DirectMp3Cache[$p.Name] = [PSCustomObject]@{ direct = [bool]$v.direct; ts = $ts }
            }
        }
    } catch {
        $script:DirectMp3Cache = @{}
    }
}

function Save-Mp3Cache {
    try {
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        $obj = [PSCustomObject]@{}
        foreach ($k in $script:DirectMp3Cache.Keys) {
            $e = $script:DirectMp3Cache[$k]
            $val = [PSCustomObject]@{ direct = [bool]$e.direct; ts = $e.ts.ToString("o") }
            $obj | Add-Member -NotePropertyName $k -NotePropertyValue $val -Force
        }
        $json = $obj | ConvertTo-Json -Depth 3
        Write-Utf8NoBom $Mp3CachePath $json | Out-Null
    } catch {}
}

function Test-DirectStreamContentType($url) {
    $headers = $null
    try {
        $resp = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        $headers = $resp.Headers
    } catch {
        $headers = $null
    }
    if (-not $headers) {
        try {
            $resp = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 2 -UseBasicParsing -Headers @{ Range = "bytes=0-0" } -ErrorAction Stop
            $headers = $resp.Headers
        } catch {
            return $false
        }
    }
    $ct = ""
    if ($headers -is [System.Collections.IDictionary]) {
        foreach ($k in $headers.Keys) {
            if ($k -ieq "Content-Type") { $ct = [string]$headers[$k]; break }
        }
    } elseif ($headers) {
        $ct = [string]($headers["Content-Type"])
    }
    if ([string]::IsNullOrWhiteSpace($ct)) { return $false }
    $ct = $ct.ToLowerInvariant()
    return ($ct -match 'audio/(mpeg|mp3|x-mpeg|mpeg3|ogg|opus)')
}

function Test-DirectStream($url) {
    if ([string]::IsNullOrWhiteSpace($url)) { return $false }
    if (-not (Test-Url $url)) { return $false }
    if (Test-ProxyUrl $url) { return $false }
    if (Test-LocalUrl $url) { return $false }
    Load-Mp3Cache
    if ($script:DirectMp3Cache.ContainsKey($url)) {
        $e = $script:DirectMp3Cache[$url]
        if ($e.ts -ne [datetime]::MinValue -and ((Get-Date) - $e.ts).TotalDays -lt $script:CacheTtlDays) {
            return $e.direct
        }
    }
    if ($url -match '\.(mp3|ogg)(\?|$)') {
        $script:DirectMp3Cache[$url] = [PSCustomObject]@{ direct = $true; ts = Get-Date }
        Save-Mp3Cache
        return $true
    }
    $res = Test-DirectStreamContentType $url
    $script:DirectMp3Cache[$url] = [PSCustomObject]@{ direct = $res; ts = Get-Date }
    Save-Mp3Cache
    Write-Log "INFO" "DirectStream check: $(Get-SafeUrl $url) -> $res"
    return $res
}

function Start-SingleProxy($backend, $url, $port, $vlcPath, $ffmpegPath) {
    $safeUrl = $url -replace '"', '%22'
    if ($backend -eq "vlc") {
        $args = @("--demux=avformat","--qt-start-minimized","--qt-notification=0","--sout-keep","--repeat","--http-user-agent=Mozilla/5.0",$safeUrl,"--sout=#transcode{acodec=mp3,ab=128,samplerate=44100,channels=2}:std{access=http,mux=mp3,dst=:$port$RadioPath}")
        return Start-Process -FilePath $vlcPath -ArgumentList $args -PassThru
    } else {
        $ffArgs = @("-reconnect","1","-reconnect_streamed","1","-reconnect_delay_max","5","-i",$safeUrl,"-c:a","libmp3lame","-b:a","128k","-ar","44100","-ac","2","-f","mp3","-listen","1","http://127.0.0.1:$port$RadioPath")
        $probeErr = Join-Path $ConfigDir "ffmpeg-probe.log"
        return Start-Process -FilePath $ffmpegPath -ArgumentList $ffArgs -PassThru -WindowStyle Hidden -RedirectStandardError $probeErr
    }
}

function Test-BackendForStream($backend, $url, $port, $vlcPath, $ffmpegPath, $timeoutSec = 3) {
    if ($port -le 0) { return "skip" }
    if ($backend -eq "vlc" -and -not $vlcPath) { return "missing" }
    if ($backend -eq "ffmpeg" -and -not $ffmpegPath) { return "missing" }
    if (-not (Test-PortFree $port)) { return "fail" }
    $p = $null
    try {
        $p = Start-SingleProxy $backend $url $port $vlcPath $ffmpegPath
    } catch {
        return "fail"
    }
    $ok = $false
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        if ($p -and $p.HasExited) { break }
        if (-not (Test-PortFree $port)) { $ok = $true; break }
    }
    if ($p -and -not $p.HasExited) {
        try { $p.CloseMainWindow() | Out-Null } catch {}
        if (-not $p.WaitForExit(1500)) { try { $p.Kill() } catch {} }
    }
    Start-Sleep -Milliseconds 300
    if ($ok) { return "ok" }
    return "fail"
}

function Test-BackendsForStreams($streams, $vlcPath, $ffmpegPath) {
    $results = @()
    foreach ($s in $streams) {
        $port = 0
        if ($s.PSObject.Properties['port'] -and $s.port) { $port = [int]$s.port }
        if ($port -le 0) { continue }
        $r = [PSCustomObject]@{ Name = $s.name; Url = $s.url; Port = $port; Vlc = "skip"; Ffmpeg = "skip"; Recommend = "" }
        if ($vlcPath) {
            $r.Vlc = Test-BackendForStream "vlc" $s.url $port $vlcPath $ffmpegPath
        } else { $r.Vlc = "missing" }
        if ($ffmpegPath) {
            $r.Ffmpeg = Test-BackendForStream "ffmpeg" $s.url $port $vlcPath $ffmpegPath
        } else { $r.Ffmpeg = "missing" }
        if ($r.Vlc -eq "ok" -and $r.Ffmpeg -eq "ok") { $r.Recommend = "ffmpeg" }
        elseif ($r.Ffmpeg -eq "ok") { $r.Recommend = "ffmpeg" }
        elseif ($r.Vlc -eq "ok") { $r.Recommend = "vlc" }
        else { $r.Recommend = "none" }
        $results += $r
    }
    return $results
}

function Load-Config {
    if (-not (Test-Path $ConfigPath)) {
        return [PSCustomObject]@{ backend = "auto"; streams = @() }
    }
    try {
        $raw = Get-Content $ConfigPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
            return [PSCustomObject]@{ backend = "auto"; streams = @() }
        }
        $cfg = $raw | ConvertFrom-Json
        if (-not $cfg.backend) { $cfg | Add-Member -NotePropertyName backend -NotePropertyValue "auto" -Force }
        if ($null -eq $cfg.streams) { $cfg | Add-Member -NotePropertyName streams -NotePropertyValue @() -Force }
        return $cfg
    } catch {
        Show-Error "config/streams.json is corrupted: $($_.Exception.Message)"
        return $null
    }
}

function Save-Config($cfg) {
    $json = $cfg | ConvertTo-Json -Depth 5
    Write-Utf8NoBom $ConfigPath $json | Out-Null
    Write-Log "INFO" "Config saved"
}

function Get-StreamAudit($Game, $cfg) {
    $result = [PSCustomObject]@{
        OnlyCfg = @()
        OnlySii = @()
        Matched = @()
        TotalCfg = 0
        TotalSii = 0
        MissingIndex = @()
    }
    if (-not $cfg) { return $result }
    $cfgList = @($cfg.streams)
    $result.TotalCfg = $cfgList.Count
    $siiList = @(Get-StreamsFromSii $Game)
    $result.TotalSii = $siiList.Count
    foreach ($c in $cfgList) {
        if (-not $c.PSObject.Properties['index'] -or $c.index -lt 0) {
            $result.MissingIndex += [PSCustomObject]@{ Name = $c.name; Url = $c.url }
        }
    }
    if ($siiList.Count -eq 0) {
        foreach ($c in $cfgList) { $result.OnlyCfg += [PSCustomObject]@{ Name = $c.name; Url = $c.url; Port = 0; Reason = "no_sii" } }
        return $result
    }
    $cfgNameCount = @{}
    foreach ($c in $cfgList) {
        if (-not $cfgNameCount.ContainsKey($c.name)) { $cfgNameCount[$c.name] = 0 }
        $cfgNameCount[$c.name]++
    }
    $seenCfgNames = @{}
    foreach ($c in $cfgList) {
        if ($seenCfgNames.ContainsKey($c.name)) { continue }
        $seenCfgNames[$c.name] = $true
        $s = @($siiList | Where-Object { $_.name -eq $c.name }) | Select-Object -First 1
        if (-not $s) {
            $reason = if ($cfgNameCount[$c.name] -gt 1) { "dup_in_cfg" } else { "missing_in_sii" }
            $result.OnlyCfg += [PSCustomObject]@{ Name = $c.name; Url = $c.url; Port = 0; Reason = $reason }
            continue
        }
        $diffs = @()
        $cPort = 0
        if ($c.PSObject.Properties['port'] -and $c.port) { $cPort = [int]$c.port }
        if ($cPort -gt 0) {
            if (-not $s.isProxy) {
                $diffs += [PSCustomObject]@{ Field = "proxy"; Cfg = "http://127.0.0.1:$cPort/radio.mp3"; Sii = $s.url }
            } elseif ($cPort -ne [int]$s.port) {
                $diffs += [PSCustomObject]@{ Field = "port"; Cfg = [string]$cPort; Sii = [string]$s.port }
            }
        } else {
            if ($s.url -ne $c.url) {
                $diffs += [PSCustomObject]@{ Field = "url"; Cfg = $c.url; Sii = $s.url }
            }
        }
        if ([string]$c.genre -ne [string]$s.genre) { $diffs += [PSCustomObject]@{ Field = "genre"; Cfg = [string]$c.genre; Sii = [string]$s.genre } }
        if ([string]$c.lang -ne [string]$s.lang) { $diffs += [PSCustomObject]@{ Field = "lang"; Cfg = [string]$c.lang; Sii = [string]$s.lang } }
        if ([string]$c.bitrate -ne [string]$s.bitrate) { $diffs += [PSCustomObject]@{ Field = "bitrate"; Cfg = [string]$c.bitrate; Sii = [string]$s.bitrate } }
        if ([string]$c.fav -ne [string]$s.fav) { $diffs += [PSCustomObject]@{ Field = "fav"; Cfg = [string]$c.fav; Sii = [string]$s.fav } }
        if ($diffs.Count -gt 0) {
            $result.Matched += [PSCustomObject]@{ Name = $c.name; Diffs = $diffs }
        }
    }
    $siiNameCount = @{}
    foreach ($s in $siiList) {
        if (-not $siiNameCount.ContainsKey($s.name)) { $siiNameCount[$s.name] = 0 }
        $siiNameCount[$s.name]++
    }
    $seenSiiNames = @{}
    foreach ($s in $siiList) {
        if ($seenSiiNames.ContainsKey($s.name)) { continue }
        $seenSiiNames[$s.name] = $true
        if (-not $seenCfgNames.ContainsKey($s.name)) {
            $reason = if ($siiNameCount[$s.name] -gt 1) { "dup_in_sii" } else { "missing_in_cfg" }
            $result.OnlySii += [PSCustomObject]@{ Name = $s.name; Url = $s.url; Port = [int]$s.port; Reason = $reason }
        }
    }
    return $result
}

function Test-GameRunning($Game) {
    if ($Game -eq "ats") { $p = Get-Process -Name "amtrucks" -ErrorAction SilentlyContinue }
    else { $p = Get-Process -Name "eurotrucks2" -ErrorAction SilentlyContinue }
    return ($null -ne $p)
}

function Read-M3uStations($path) {
    $list = @()
    $lines = @()
    try {
        $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
    } catch {
        return $list
    }
    $pendingName = ""
    $pendingGenre = ""
    foreach ($raw in $lines) {
        $line = "$raw".Trim()
        if ($line -eq "") { continue }
        if ($line.StartsWith("#EXTINF")) {
            $pendingName = ""
            $pendingGenre = ""
            $gm = [regex]::Match($line, 'group-title="([^"]*)"')
            if ($gm.Success) { $pendingGenre = $gm.Groups[1].Value.Trim() }
            $comma = $line.LastIndexOf(',')
            if ($comma -ge 0 -and $comma -lt ($line.Length - 1)) {
                $pendingName = $line.Substring($comma + 1).Trim()
            }
            continue
        }
        if ($line.StartsWith("#")) { continue }
        if ($line -match '^https?://') {
            if ([string]::IsNullOrWhiteSpace($pendingName)) { $pendingName = $line }
            $list += [PSCustomObject]@{ Url = $line; Name = $pendingName; Genre = $pendingGenre; Lang = ""; Bitrate = ""; Fav = ""; Port = 0; Backend = "" }
            $pendingName = ""
            $pendingGenre = ""
        }
    }
    return $list
}

function Read-ImportSource($path, $isM3u) {
    if ($isM3u) {
        return @(Read-M3uStations $path)
    }
    $items = @()
    try {
        $raw = Get-Content $path -Raw
        $data = $raw | ConvertFrom-Json
        if (-not $data.streams) { return @() }
        foreach ($s in $data.streams) {
            if (-not $s.url) { continue }
            $n = ""; if ($s.name) { $n = [string]$s.name }
            $g = ""; if ($s.genre) { $g = [string]$s.genre }
            $lg = "RU"; if ($s.lang) { $lg = [string]$s.lang }
            $br = "128"; if ($s.bitrate) { $br = [string]$s.bitrate }
            $fv = "0"; if ($s.fav) { $fv = [string]$s.fav }
            $p = 0; if ($s.port) { $p = [int]$s.port }
            $be = ""; if ($s.backend -eq "vlc" -or $s.backend -eq "ffmpeg") { $be = [string]$s.backend }
            $items += [PSCustomObject]@{ Url = [string]$s.url; Name = $n; Genre = $g; Lang = $lg; Bitrate = $br; Fav = $fv; Port = $p; Backend = $be }
        }
    } catch {
        return @()
    }
    return $items
}

function Process-ImportItems($rawItems) {
    $newList = @()
    $skipped = 0
    $skippedLocal = 0
    $skippedProxy = 0
    $skippedDup = 0
    $httpsReplaced = 0
    $httpsSkipped = 0
    $proxied = 0
    $skippedIdx = @()
    $httpsSkippedIdx = @()
    $dupIdx = @()
    $localIdx = @()
    $proxyIdx = @()
    $seen = @{}
    $n = 0
    foreach ($it in $rawItems) {
        $n++
        $u = $it.Url
        if ([string]::IsNullOrWhiteSpace($u)) { $skipped++; continue }
        if (Test-LocalUrl $u) { $skippedLocal++; $localIdx += $n; continue }
        if (Test-ProxyUrl $u) { $skippedProxy++; $proxyIdx += $n; continue }
        if ($u -match '^https://') {
            $alt = $u -replace '^https://', 'http://'
            if (Test-Url $alt) { $u = $alt; $httpsReplaced++ }
            else { $httpsSkipped++; $httpsSkippedIdx += $n; continue }
        } elseif (-not (Test-Url $u)) {
            $skipped++; $skippedIdx += $n; continue
        }
        if ($seen.ContainsKey($u)) { $skippedDup++; $dupIdx += $n; continue }
        $seen[$u] = $true
        $nm = ""
        if ($it.PSObject.Properties['Name'] -and $it.Name) { $nm = [string]$it.Name }
        if ([string]::IsNullOrWhiteSpace($nm)) { $nm = $u }
        $g = ""
        if ($it.PSObject.Properties['Genre'] -and $it.Genre) { $g = [string]$it.Genre }
        $lg = "RU"
        if ($it.PSObject.Properties['Lang'] -and $it.Lang) { $lg = [string]$it.Lang }
        $br = "128"
        if ($it.PSObject.Properties['Bitrate'] -and $it.Bitrate) { $br = [string]$it.Bitrate }
        $fv = "0"
        if ($it.PSObject.Properties['Fav'] -and $it.Fav) { $fv = [string]$it.Fav }
        $obj = [PSCustomObject]@{ url = $u; name = $nm; genre = $g; lang = $lg; bitrate = $br; fav = $fv }

        $isDirect = $false
        if ($u -match '\.(mp3|ogg)(\?|$)') { $isDirect = $true }
        else { $isDirect = Test-DirectStream $u }
        if (-not $isDirect) {
            $p = 0
            if ($it.PSObject.Properties['Port'] -and $it.Port -gt 0) { $p = [int]$it.Port }
            $taken = @($newList | ForEach-Object { if ($_.PSObject.Properties['port'] -and $_.port) { [int]$_.port } } | Where-Object { $_ -gt 0 })
            if ($p -gt 0 -and ($taken -notcontains $p) -and (Test-PortFree $p)) {
                $obj | Add-Member -NotePropertyName port -NotePropertyValue $p -Force
            } else {
                $newP = Get-FreePort ([PSCustomObject]@{ streams = $newList }) 18084 20000
                if ($newP) { $obj | Add-Member -NotePropertyName port -NotePropertyValue $newP -Force; $proxied++ }
            }
        }
        if ($it.PSObject.Properties['Backend'] -and ($it.Backend -eq "vlc" -or $it.Backend -eq "ffmpeg")) {
            $obj | Add-Member -NotePropertyName backend -NotePropertyValue $it.Backend -Force
        }
        $newList += $obj
    }
    return [PSCustomObject]@{
        Streams          = $newList
        Skipped          = $skipped
        SkippedIdx       = $skippedIdx
        SkippedLocal     = $skippedLocal
        SkippedLocalIdx  = $localIdx
        SkippedProxy     = $skippedProxy
        SkippedProxyIdx  = $proxyIdx
        SkippedDup       = $skippedDup
        SkippedDupIdx    = $dupIdx
        HttpsReplaced    = $httpsReplaced
        HttpsSkipped     = $httpsSkipped
        HttpsSkippedIdx  = $httpsSkippedIdx
        Proxied          = $proxied
    }
}

function Merge-ImportStreams($cfg, $newList, $addMode) {
    if ($addMode) {
        $existingUrls = @{}
        foreach ($s in $cfg.streams) { if ($s.url) { $existingUrls[$s.url] = $true } }
        $toAdd = @()
        $dupInCfg = 0
        foreach ($s in $newList) {
            if ($existingUrls.ContainsKey($s.url)) { $dupInCfg++; continue }
            $toAdd += $s
        }
        $cfg.streams += $toAdd
        return [PSCustomObject]@{ Streams = $cfg.streams; AddedCount = $toAdd.Count; DupInCfg = $dupInCfg }
    } else {
        $cfg.streams = $newList
        return [PSCustomObject]@{ Streams = $cfg.streams; AddedCount = $newList.Count; DupInCfg = 0 }
    }
}

function Build-ExportList($game, $cfg, $mode) {
    $cfgList = @($cfg.streams)
    $siiAll = @(Get-StreamsFromSii $game)
    $siiDirect = @($siiAll | Where-Object { -not $_.isProxy })
    $exportList = @()
    if ($mode -eq "1") {
        foreach ($s in $cfgList) {
            $obj = [PSCustomObject]@{ url = $s.url; name = $s.name; genre = $s.genre; lang = $s.lang; bitrate = $s.bitrate; fav = $s.fav }
            if ($s.PSObject.Properties['port'] -and $s.port) { $obj | Add-Member -NotePropertyName port -NotePropertyValue ([int]$s.port) -Force }
            if ($s.PSObject.Properties['backend'] -and $s.backend) { $obj | Add-Member -NotePropertyName backend -NotePropertyValue ([string]$s.backend) -Force }
            $exportList += $obj
        }
    } elseif ($mode -eq "2") {
        foreach ($s in $siiDirect) {
            $obj = [PSCustomObject]@{ url = $s.url; name = $s.name; genre = $s.genre; lang = $s.lang; bitrate = $s.bitrate; fav = $s.fav }
            $exportList += $obj
        }
    } else {
        $seen = @()
        foreach ($s in $cfgList) {
            if ($seen -notcontains $s.url) {
                $seen += $s.url
                $obj = [PSCustomObject]@{ url = $s.url; name = $s.name; genre = $s.genre; lang = $s.lang; bitrate = $s.bitrate; fav = $s.fav }
                if ($s.PSObject.Properties['port'] -and $s.port) { $obj | Add-Member -NotePropertyName port -NotePropertyValue ([int]$s.port) -Force }
                if ($s.PSObject.Properties['backend'] -and $s.backend) { $obj | Add-Member -NotePropertyName backend -NotePropertyValue ([string]$s.backend) -Force }
                $exportList += $obj
            }
        }
        foreach ($s in $siiDirect) {
            if ($seen -notcontains $s.url) {
                $seen += $s.url
                $obj = [PSCustomObject]@{ url = $s.url; name = $s.name; genre = $s.genre; lang = $s.lang; bitrate = $s.bitrate; fav = $s.fav }
                $exportList += $obj
            }
        }
    }
    return $exportList
}

function Write-ExportFile($path, $cfg, $exportList) {
    try {
        $out = [PSCustomObject]@{ version = $Version; backend = $cfg.backend; streams = $exportList }
        $json = $out | ConvertTo-Json -Depth 5
        Write-Utf8NoBom $path $json | Out-Null
        Write-Log "INFO" "Exported $($exportList.Count) streams to $path"
        return $true
    } catch {
        Write-Log "ERROR" "Write-ExportFile failed: $($_.Exception.Message)"
        return $false
    }
}

$script:NativeRuntimeCode = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class ProxySpec
{
    public string Backend;
    public string Url;
    public int Port;
    public string FileName;
    public string Arguments;
    public bool IsFfmpeg;
}

public class ProxyRuntime
{
    private const uint WAIT_TIMEOUT = 0x00000102;
    private const uint WAIT_FAILED = 0xFFFFFFFF;
    private const int MAXIMUM_WAIT_OBJECTS = 64;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForMultipleObjects(uint nCount, IntPtr[] lpHandles, bool bWaitAll, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    private class Entry
    {
        public Process Proc;
        public ProxySpec Spec;
    }

    private readonly List<Entry> _entries = new List<Entry>();
    private readonly object _lock = new object();
    private readonly string _errFile;
    private IntPtr _gameHandle = IntPtr.Zero;
    private volatile bool _gameExited = false;
    private volatile bool _stop = false;
    private readonly ManualResetEvent _stopEvent = new ManualResetEvent(false);
    private readonly ManualResetEvent _gameExitEvent = new ManualResetEvent(false);
    private Thread _thread;
    private readonly object _errLock = new object();

    public ProxyRuntime(string errFile)
    {
        _errFile = errFile;
    }

    public void AddGame(IntPtr hProcess)
    {
        _gameHandle = hProcess;
    }

    public void AddProxy(ProxySpec spec)
    {
        var p = StartProxyProcess(spec);
        if (p != null)
        {
            var e = new Entry { Proc = p, Spec = spec };
            lock (_lock) { _entries.Add(e); }
            PumpStderr(p);
        }
    }

    private Process StartProxyProcess(ProxySpec spec)
    {
        try
        {
            if (spec.IsFfmpeg)
            {
                var psi = new ProcessStartInfo
                {
                    FileName = spec.FileName,
                    Arguments = spec.Arguments,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardError = true
                };
                return Process.Start(psi);
            }
            else
            {
                var psi = new ProcessStartInfo
                {
                    FileName = spec.FileName,
                    Arguments = spec.Arguments,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                return Process.Start(psi);
            }
        }
        catch
        {
            return null;
        }
    }

    private void PumpStderr(Process p)
    {
        if (!p.StartInfo.RedirectStandardError) return;
        var t = new Thread(() =>
        {
            try
            {
                var sr = p.StandardError;
                while (true)
                {
                    string line = sr.ReadLine();
                    if (line == null) break;
                    lock (_errLock)
                    {
                        try
                        {
                            using (var sw = new StreamWriter(_errFile, true, new UTF8Encoding(false)))
                            {
                                sw.WriteLine(line);
                            }
                        }
                        catch { }
                    }
                }
            }
            catch { }
        });
        t.IsBackground = true;
        t.Start();
    }

    public void Start()
    {
        _thread = new Thread(Run);
        _thread.IsBackground = true;
        _thread.Start();
    }

    public void WaitForGameExit()
    {
        _gameExitEvent.WaitOne();
    }

    public void Stop()
    {
        _stop = true;
        _stopEvent.Set();
        _gameExitEvent.Set();
        try { if (_thread != null) _thread.Join(3000); } catch { }
        lock (_lock)
        {
            foreach (var e in _entries)
            {
                try
                {
                    if (!e.Proc.HasExited) e.Proc.Kill();
                }
                catch { }
            }
            _entries.Clear();
        }
        try
        {
            if (_gameHandle != IntPtr.Zero) CloseHandle(_gameHandle);
        }
        catch { }
        _gameHandle = IntPtr.Zero;
    }

    private void Run()
    {
        while (!_stop)
        {
            var handles = new List<IntPtr>();
            lock (_lock)
            {
                if (_gameHandle != IntPtr.Zero) handles.Add(_gameHandle);
                foreach (var e in _entries)
                {
                    try
                    {
                        if (e.Proc.HasExited) continue;
                        handles.Add(e.Proc.Handle);
                    }
                    catch { }
                }
            }
            if (handles.Count == 0)
            {
                Thread.Sleep(50);
                continue;
            }
            var arr = new IntPtr[handles.Count + 1];
            for (int i = 0; i < handles.Count; i++) arr[i] = handles[i];
            arr[handles.Count] = _stopEvent.SafeWaitHandle.DangerousGetHandle();
            uint n = (uint)arr.Length;
            if (n > MAXIMUM_WAIT_OBJECTS) n = MAXIMUM_WAIT_OBJECTS;
            uint res = WaitForMultipleObjects(n, arr, false, 0xFFFFFFFF);
            if (res == WAIT_FAILED) { Thread.Sleep(100); continue; }
            if (res == WAIT_TIMEOUT) continue;
            int idx = (int)res;
            if (idx == handles.Count)
            {
                if (_stop) return;
                continue;
            }
            IntPtr signaled = handles[idx];
            if (signaled == _gameHandle)
            {
                _gameExited = true;
                _gameExitEvent.Set();
                return;
            }
            Entry dead = null;
            lock (_lock)
            {
                foreach (var e in _entries)
                {
                    try
                    {
                        if (e.Proc.Handle == signaled) { dead = e; break; }
                    }
                    catch { }
                }
                if (dead != null) _entries.Remove(dead);
            }
            if (dead == null) continue;
            if (_gameExited) continue;
            Thread.Sleep(150);
            var newProc = StartProxyProcess(dead.Spec);
            if (newProc != null)
            {
                var ne = new Entry { Proc = newProc, Spec = dead.Spec };
                lock (_lock) { _entries.Add(ne); }
                PumpStderr(newProc);
            }
        }
    }
}
'@

function Get-ProxySpecsForStreams($backend, $streams, $vlcPath, $ffmpegPath) {
    $specs = @()
    foreach ($s in $streams) {
        $url = $s.url
        $port = 0
        if ($s.PSObject.Properties['port'] -and $s.port) { $port = [int]$s.port }
        if ($port -le 0) { continue }
        $stationBackend = ""
        if ($s.PSObject.Properties['backend'] -and $s.backend) { $stationBackend = [string]$s.backend }
        $useBackend = ""
        if ($backend -eq "auto") {
            if ($stationBackend -eq "vlc" -or $stationBackend -eq "ffmpeg") {
                $useBackend = $stationBackend
                if ($useBackend -eq "vlc" -and -not $vlcPath) {
                    if ($ffmpegPath) { $useBackend = "ffmpeg" } else { continue }
                }
                if ($useBackend -eq "ffmpeg" -and -not $ffmpegPath) {
                    if ($vlcPath) { $useBackend = "vlc" } else { continue }
                }
            } else {
                if ($ffmpegPath) { $useBackend = "ffmpeg" }
                elseif ($vlcPath) { $useBackend = "vlc" }
                else { continue }
            }
        } else {
            $useBackend = $backend
        }
        if ($useBackend -eq "vlc" -and -not $vlcPath) { continue }
        if ($useBackend -eq "ffmpeg" -and -not $ffmpegPath) { continue }
        if (-not (Test-PortFree $port)) { continue }

        $safeUrl = $url -replace '"', '%22'
        $spec = New-Object ProxySpec
        $spec.Backend = $useBackend
        $spec.Url = $url
        $spec.Port = $port
        if ($useBackend -eq "vlc") {
            $spec.IsFfmpeg = $false
            $spec.FileName = $vlcPath
            $vlcArgs = @("--demux=avformat","--qt-start-minimized","--qt-notification=0","--sout-keep","--repeat","--http-user-agent=Mozilla/5.0",$safeUrl,"--sout=#transcode{acodec=mp3,ab=128,samplerate=44100,channels=2}:std{access=http,mux=mp3,dst=:$port$RadioPath}")
            $spec.Arguments = ($vlcArgs | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } }) -join ' '
        } else {
            $spec.IsFfmpeg = $true
            $spec.FileName = $ffmpegPath
            $ffArgs = @("-reconnect","1","-reconnect_streamed","1","-reconnect_delay_max","5","-i",$safeUrl,"-c:a","libmp3lame","-b:a","128k","-ar","44100","-ac","2","-f","mp3","-listen","1","http://127.0.0.1:$port$RadioPath")
            $spec.Arguments = ($ffArgs | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } }) -join ' '
        }
        $specs += $spec
    }
    return $specs
}

function Start-GameWithRadio($Game) {
    if (-not (Test-Path $ConfigPath)) { Show-Error "streams.json not found. Run Settings.cmd first."; return 1 }
    if (Test-GameRunning $Game) {
        if ($Game -eq "ats") { Show-Error "American Truck Simulator is already running. Close it first." }
        else { Show-Error "Euro Truck Simulator 2 is already running. Close it first." }
        return 1
    }
    $config = Load-Config
    if (-not $config) { return 1 }
    $backend = $config.backend
    $streams = $config.streams
    if (-not $streams -or $streams.Count -eq 0) { Show-Error "No streams configured. Run Settings.cmd."; return 1 }

    foreach ($s in $streams) {
        $p = 0
        if ($s.PSObject.Properties['port'] -and $s.port) { $p = [int]$s.port }
        if ($p -le 0) { continue }
        if (-not (Test-PortFree $p)) {
            Show-Error "Port $p is busy. Close the previous VLC/FFmpeg or change the port."
            return 1
        }
    }

    Rotate-LogIfNeeded $LogPath
    Rotate-LogIfNeeded $FfmpegErrPath

    $VlcPath = $null; $FFmpegPath = $null
    if ($backend -eq "vlc") {
        $VlcPath = Find-Vlc
        if (-not $VlcPath) { Show-Error "VLC not found."; return 1 }
    } elseif ($backend -eq "ffmpeg") {
        $FFmpegPath = Find-FFmpegFull
        if (-not $FFmpegPath) {
            $any = Find-FFmpeg
            if ($any) {
                Show-Error "FFmpeg found at $any but it has no libmp3lame encoder. Install a full build (e.g. from https://www.gyan.dev/ffmpeg/builds/)."
            } else {
                Show-Error "FFmpeg not found."
            }
            return 1
        }
        Write-Log "INFO" "FFmpeg (full) found: $FFmpegPath"
    } elseif ($backend -eq "auto") {
        $VlcPath = Find-Vlc
        $FFmpegPath = Find-FFmpegFull
        if (-not $VlcPath -and -not $FFmpegPath) { Show-Error "Neither VLC nor FFmpeg found."; return 1 }
    } else {
        Show-Error "Unknown backend: $backend."; return 1
    }

    $GameDir = Find-Game $Game
    if (-not $GameDir) {
        if ($Game -eq "ats") { Show-Error "American Truck Simulator not found." }
        else { Show-Error "Euro Truck Simulator 2 not found." }
        return 1
    }

    $exe = if ($Game -eq "ats") { "amtrucks.exe" } else { "eurotrucks2.exe" }

    $code = @'
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHELLEXECUTEINFO {
        public int cbSize; public uint fMask; public IntPtr hwnd;
        public string lpVerb; public string lpFile; public string lpParameters; public string lpDirectory;
        public int nShow; public IntPtr hInstApp; public IntPtr lpIDList; public string lpClass;
        public IntPtr hkeyClass; public uint dwHotKey; public IntPtr hIcon; public IntPtr hProcess;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool ShellExecuteEx(ref SHELLEXECUTEINFO lpExecInfo);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
}
'@
    Add-Type -TypeDefinition $code -Language CSharp -IgnoreWarnings
    Add-Type -TypeDefinition $script:NativeRuntimeCode -Language CSharp -IgnoreWarnings -ErrorAction Stop

    $specs = Get-ProxySpecsForStreams $backend $streams $VlcPath $FFmpegPath
    $rt = New-Object ProxyRuntime $FfmpegErrPath
    foreach ($spec in $specs) {
        Write-Log "INFO" "Stream proxy started: $($spec.Backend) $(Get-SafeUrl $spec.Url) -> :$($spec.Port)"
        $rt.AddProxy($spec)
    }

    $sei = New-Object Win32+SHELLEXECUTEINFO
    $sei.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($sei)
    $sei.fMask = 0x00000040
    $sei.lpVerb = "open"
    $sei.lpFile = $exe
    $sei.lpDirectory = $GameDir
    $sei.nShow = 1

    if (-not [Win32]::ShellExecuteEx([ref]$sei)) {
        if ($Game -eq "ats") { Show-Error "Failed to launch American Truck Simulator." }
        else { Show-Error "Failed to launch Euro Truck Simulator 2." }
        $rt.Stop()
        return 1
    }

    Write-Log "INFO" "Game launched: $exe ($GameDir)"
    $rt.AddGame($sei.hProcess)
    $rt.Start()
    $rt.WaitForGameExit()
    $rt.Stop()
    Write-Log "INFO" "Game exited, proxy stopped"
    return 0
}
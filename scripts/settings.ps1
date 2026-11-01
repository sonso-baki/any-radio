$commonPath = Join-Path $PSScriptRoot "common.ps1"
if (-not (Test-Path $commonPath)) {
    Write-Host "ERROR: common.ps1 not found ($commonPath)" -ForegroundColor Red
    Write-Host "Re-extract the archive so that scripts/common.ps1 exists." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}
. $commonPath

if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }

function Get-SystemLang {
    $ruLangs = @(
        "ru","uk","be","kk","ky","uz","tg","tk","az","hy","ka",
        "lv","lt","et","ab","os","tt","ba","cv","udm","kv","myv",
        "sah","bua","tyv","xal","krc","kbd","ce","inh","lez","av","dar","lbe"
    )
    try {
        $ui = (Get-UICulture).TwoLetterISOLanguageName
        if ($ruLangs -contains $ui) { return "ru" }
    } catch {}
    return "en"
}

function Test-FileHasBom($path) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return $true }
        return $false
    } catch {
        return $false
    }
}

function Fix-FileBom($path) {
    try {
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $enc = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($path, $text, $enc)
        return $true
    } catch {
        return $false
    }
}

function Get-LangKeys($path) {
    try {
        $tmp = $null
        $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $script = [scriptblock]::Create($content + "`n; `$tmp = `$L")
        & $script | Out-Null
        if ($tmp -is [hashtable]) { return @($tmp.Keys) }
        return @()
    } catch {
        return @()
    }
}

function Load-Lang {
    $code = $null
    if (Test-Path $LangFile) {
        $code = (Get-Content $LangFile -Raw).Trim()
        if ($code -ne "ru" -and $code -ne "en") { $code = $null }
    }
    if (-not $code) {
        $code = Get-SystemLang
        Set-Content -Path $LangFile -Value $code -Encoding UTF8 -NoNewline
    }
    $langPath = Join-Path $LangDir "$code.ps1"
    if (-not (Test-Path $langPath)) {
        Write-Host "ERROR: lang file not found: $langPath" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    $bomFixed = $false
    if (-not (Test-FileHasBom $langPath)) {
        if (Fix-FileBom $langPath) { $bomFixed = $true }
        else { Write-Host "WARN: failed to add UTF-8 BOM to $langPath" -ForegroundColor Yellow }
    }
    $L = $null
    . $langPath
    if ($null -eq $L) {
        Write-Host "ERROR: lang file $langPath did not define `$L" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    if (-not ($L -is [hashtable]) -and -not ($L -is [System.Collections.IDictionary])) {
        Write-Host "ERROR: lang file $langPath produced $($L.GetType().FullName), expected hashtable" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    $global:L = $L
    if (-not $global:L.Contains("ChooseGame")) {
        Write-Host "ERROR: lang file $langPath did not define `$L.ChooseGame" -ForegroundColor Red
        Write-Host "Loaded keys: $(($global:L.Keys | Sort-Object) -join ', ')" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    $enPath = Join-Path $LangDir "en.ps1"
    if (Test-Path $enPath) {
        $enKeys = Get-LangKeys $enPath
        $missing = @()
        foreach ($k in $enKeys) {
            if (-not $global:L.Contains($k)) { $missing += $k }
        }
        if ($missing.Count -gt 0) {
            Write-Log "WARN" "Lang '$code' missing keys: $($missing -join ', ')"
            Write-Host "WARN: lang '$code' missing $($missing.Count) key(s): $($missing -join ', ')" -ForegroundColor Yellow
        }
    }
    if ($bomFixed) {
        Write-Host $L.LangBomFixed -ForegroundColor Green
        Start-Sleep -Milliseconds 700
    }
    return $code
}

$currentLang = Load-Lang

function Save-Lang($code) { Set-Content -Path $LangFile -Value $code -Encoding UTF8 -NoNewline }


function Pause-Menu {
    Write-Host ""
    Write-Host $L.PressEnter -ForegroundColor DarkGray
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::Enter) { break }
    }
}

function Get-AvailableGames {
    $list = @()
    if (Find-Game "ats")  { $list += [PSCustomObject]@{ Code = "ats";  Name = "American Truck Simulator (ATS)" } }
    if (Find-Game "ets2") { $list += [PSCustomObject]@{ Code = "ets2"; Name = "Euro Truck Simulator 2 (ETS2)" } }
    return $list
}

function Get-SteamCommand($Game) {
    $exe = if ($Game -eq "ats") { "ats_radio.ps1" } else { "ets2_radio.ps1" }
    $scriptPath = Join-Path $PSScriptRoot $exe
    return "C:\Windows\System32\conhost.exe --headless C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" & rem %command%"
}

function Get-MenuItems($gamesCount) {
    $items = @()
    $items += [PSCustomObject]@{ Action = "backend";   Text = $L.MenuBackend }
    $items += [PSCustomObject]@{ Action = "add";       Text = $L.MenuAdd }
    $items += [PSCustomObject]@{ Action = "remove";    Text = $L.MenuRemove }
    $items += [PSCustomObject]@{ Action = "list";      Text = $L.MenuList }
    $items += [PSCustomObject]@{ Action = "ffmpeg";    Text = $L.MenuInstallFfmpeg }
    $items += [PSCustomObject]@{ Action = "steamcmd";  Text = $L.MenuSteamCmd }
    $items += [PSCustomObject]@{ Action = "lang";      Text = $L.MenuLang }
    $items += [PSCustomObject]@{ Action = "import";    Text = $L.MenuImport }
    $items += [PSCustomObject]@{ Action = "export";    Text = $L.MenuExport }
    $items += [PSCustomObject]@{ Action = "audit";     Text = $L.MenuAudit }
    if ($gamesCount -gt 1) {
        $items += [PSCustomObject]@{ Action = "games";  Text = $L.MenuBackToGames }
    }
    $items += [PSCustomObject]@{ Action = "clear";     Text = $L.MenuClear }
    $items += [PSCustomObject]@{ Action = "exit";      Text = $L.MenuExit }
    return $items
}

function Screen-GameSelect($games) {
    Clear-Host
    Write-Host "=== $($L.Title) $Version ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host $L.SelectGame
    $i = 1
    foreach ($g in $games) {
        Write-Host ("{0}. {1}" -f $i, $g.Name)
        $i++
    }
    Write-Host ""
}

function Screen-Menu($Game, $Items) {
    Show-Header $L.Title $Game
    Write-Host "$($L.Backend): $($config.backend)"
    Write-Host "$($L.StreamsInConfig): $($config.streams.Count)"
    Write-Host ""
    $i = 1
    foreach ($it in $Items) {
        Write-Host ("{0}. {1}" -f $i, $it.Text)
        $i++
    }
    Write-Host ""
}

function Screen-Backend($Game) {
    Show-Header $L.ChangeBackend $Game
    Write-Host "$($L.Current): $($config.backend)"
    Write-Host ""
    Write-Host $L.BackendVlc
    Write-Host $L.BackendFfmpeg
    Write-Host $L.BackendAuto
    Write-Host ""
}

function Screen-Add($Game) {
    Show-Header $L.AddStream $Game
    Write-Host $L.MenuAddHint -ForegroundColor DarkGray
    $curProxies = @($config.streams | Where-Object { $_.PSObject.Properties['port'] -and [int]$_.port -gt 0 }).Count
    $slots = 63 - $curProxies
    if ($slots -le 0) {
        Write-Host $L.ProxySlotsNone -ForegroundColor Yellow
    } else {
        Write-Host ($L.ProxySlotsLeft -f $slots) -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Screen-Remove($Game) {
    Show-Header $L.RemoveStream $Game
}

function Screen-Lang {
    Clear-Host
    Write-Host "=== $($L.ChangeLang) ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "$($L.CurrentLang): $($L.LangRu) / $($L.LangEn)"
    Write-Host ""
    Write-Host "1. $($L.LangRu)"
    Write-Host "2. $($L.LangEn)"
    Write-Host ""
}

function Screen-FFmpeg($Game) {
    Show-Header $L.MenuInstallFfmpeg $Game
    $existing = Find-FFmpegFull
    if ($existing) {
        Write-Host "$($L.FFmpegInstalled): $existing" -ForegroundColor Green
    } else {
        $any = Find-FFmpeg
        if ($any) { Write-Host "$($L.FFmpegNoLame): $any" -ForegroundColor Yellow }
        else { Write-Host $L.FfmpegNotFound -ForegroundColor Yellow }
    }
    Write-Host ""
    if ($existing) {
        Write-Host "1. $($L.MenuRunWinget)"
    } else {
        Write-Host "1. $($L.MenuInstallFfmpeg)"
    }
    Write-Host ""
}
function Screen-SteamCmd($Game) {
    Show-Header $L.SteamCmdTitle $Game
    $cmd = Get-SteamCommand $Game
    Write-Host $cmd -ForegroundColor Cyan
    Write-Host ""
    Write-Host $L.SteamCmdHint -ForegroundColor DarkGray
    Write-Host ""
    Write-Host $L.SteamCmdCopyHint -ForegroundColor DarkGray
    Write-Host ""
}

function Screen-List($Game) {
    Show-Header $L.ListStreams $Game
    $configCount = $config.streams.Count
    $sii = Read-Sii $Game
    $siiCount = if ($sii) { $sii.Items.Count } else { 0 }
    Write-Host "$($L.ConfigHeader) $configCount $($L.Stations)" -ForegroundColor Yellow
    if ($configCount -eq 0) {
        Write-Host "  $($L.Empty)" -ForegroundColor DarkGray
    } else {
        $i = 0
        foreach ($s in $config.streams) {
            $p = 0
            if ($s.PSObject.Properties['port'] -and $s.port) { $p = [int]$s.port }
            $be = ""
            if ($s.PSObject.Properties['backend'] -and $s.backend) { $be = " [$($s.backend)]" }
            $link = if ($p -gt 0) { "http://127.0.0.1:$p$RadioPath" } else { $s.url }
            Write-Host ("  [{0}] {1}{2}" -f $i, $s.name, $be)
            Write-Host ("       $($L.Source): $(Get-SafeUrl $s.url)") -ForegroundColor DarkGray
            Write-Host ("       $($L.Link):   {0}" -f $link) -ForegroundColor Cyan
            $extra = @()
            $extra += "proxy: $($p -gt 0)"
            if ($s.genre) { $extra += "genre: $($s.genre)" }
            if ($s.lang) { $extra += "lang: $($s.lang)" }
            if ($s.bitrate) { $extra += "bitrate: $($s.bitrate)" }
            if ($s.fav) { $extra += "fav: $($s.fav)" }
            Write-Host ("       " + ($extra -join "  ")) -ForegroundColor DarkGray
            $i++
        }
    }
    Write-Host ""
    Write-Host "$($L.SiiHeader) $siiCount $($L.Stations)" -ForegroundColor Yellow
    if (-not $sii) {
        Write-Host "  $($L.NotFound)" -ForegroundColor DarkGray
    } elseif ($siiCount -eq 0) {
        Write-Host "  $($L.Empty)" -ForegroundColor DarkGray
    } else {
        foreach ($it in $sii.Items | Sort-Object Index) {
            Write-Host ("  [{0}] {1}" -f $it.Index, $it.Name)
            Write-Host ("       $($L.UrlLabel):  $(Get-SafeUrl $it.Url)") -ForegroundColor Cyan
            $extra = @()
            if ($it.Genre) { $extra += "genre: $($it.Genre)" }
            if ($it.Lang) { $extra += "lang: $($it.Lang)" }
            if ($it.Bitrate) { $extra += "bitrate: $($it.Bitrate)" }
            if ($it.Fav) { $extra += "fav: $($it.Fav)" }
            if ($extra.Count -gt 0) { Write-Host ("       " + ($extra -join "  ")) -ForegroundColor DarkGray }
        }
    }
    Write-Host ""
    Write-Host $L.Commands -ForegroundColor DarkGray
    Write-Host "  $($L.CmdE)" -ForegroundColor DarkGray
    Write-Host "  $($L.CmdCopy)" -ForegroundColor DarkGray
    Write-Host "  $($L.CmdSearchHint)" -ForegroundColor DarkGray
    Write-Host "  $($L.CmdOpenLink)" -ForegroundColor DarkGray
    Write-Host ""
}

function Screen-Export($Game) {
    Show-Header $L.ExportStreams $Game
    $cfgList = @($config.streams)
    $siiAll = @(Get-StreamsFromSii $Game)
    $siiDirect = @($siiAll | Where-Object { -not $_.isProxy })
    $siiProxy = @($siiAll | Where-Object { $_.isProxy })
    $allUrls = @()
    foreach ($s in $cfgList) { if ($s.url -and ($allUrls -notcontains $s.url)) { $allUrls += $s.url } }
    foreach ($s in $siiDirect) { if ($s.url -and ($allUrls -notcontains $s.url)) { $allUrls += $s.url } }
    if ($allUrls.Count -eq 0) {
        Write-Host $L.Empty -ForegroundColor DarkGray
        Write-Host ""
        return $false
    }
    $i = 0
    foreach ($u in $allUrls) {
        $c = $cfgList | Where-Object { $_.url -eq $u } | Select-Object -First 1
        $s = $siiDirect | Where-Object { $_.url -eq $u } | Select-Object -First 1
        $mark = if ($c -and $s) { "[both]" } elseif ($c) { "[cfg] " } else { "[sii] " }
        $name = if ($c) { $c.name } elseif ($s) { $s.name } else { "" }
        $port = 0
        if ($c -and $c.PSObject.Properties['port'] -and $c.port) { $port = [int]$c.port }
        $portStr = if ($port -gt 0) { " [port $port]" } else { "" }
        Write-Host ("  [{0}] {1} {2} - {3}{4}" -f $i, $mark, $name, (Get-SafeUrl $u), $portStr)
        $i++
    }
    if ($siiProxy.Count -gt 0) {
        Write-Host ""
        Write-Host ("$($L.ProxyMark): $($siiProxy.Count)") -ForegroundColor DarkGray
        foreach ($s in $siiProxy) {
            Write-Host ("  [proxy] {0} - {1}" -f $s.name, (Get-SafeUrl $s.url)) -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host $L.ExportChoose -ForegroundColor DarkGray
    Write-Host $L.ExportCfg -ForegroundColor DarkGray
    if ($siiDirect.Count -gt 0) { Write-Host $L.ExportSii -ForegroundColor DarkGray }
    else { Write-Host $L.SiiNoDirect -ForegroundColor DarkGray }
    Write-Host $L.ExportBoth -ForegroundColor DarkGray
    Write-Host ""
    return $true
}

function Set-Backend($Game, $name) {
    if ($config.backend -eq $name) {
        if ($name -eq "vlc") { Write-Host $L.BackendAlreadyVlc -ForegroundColor Yellow }
        elseif ($name -eq "ffmpeg") { Write-Host $L.BackendAlreadyFfmpeg -ForegroundColor Yellow }
        else { Write-Host $L.BackendAlreadyAuto -ForegroundColor Yellow }
        Pause-Menu
        return
    }
    if ($name -eq "vlc") {
        $path = Find-Vlc
        if ($path) { $config.backend = "vlc"; Save-Config $config; Write-Host $L.BackendSetVlc -ForegroundColor Green; Write-Host "VLC: $path" -ForegroundColor DarkGray }
        else { Write-Host $L.VlcNotFound -ForegroundColor Red }
    } elseif ($name -eq "ffmpeg") {
        $path = Find-FFmpegFull
        if ($path) { $config.backend = "ffmpeg"; Save-Config $config; Write-Host $L.BackendSetFfmpeg -ForegroundColor Green; Write-Host "FFmpeg: $path" -ForegroundColor DarkGray }
        else {
            $any = Find-FFmpeg
            if ($any) { Write-Host "$($L.FFmpegNoLame): $any" -ForegroundColor Red }
            else { Write-Host $L.FfmpegNotFound -ForegroundColor Red }
        }
    } elseif ($name -eq "auto") {
        $config.backend = "auto"
        Save-Config $config
        Write-Host $L.BackendSetAuto -ForegroundColor Green
        Write-Host $L.CheckAsk -ForegroundColor Yellow
        $ans = Read-Host "$($L.YN)"
        if (Test-Keyword $ans $L.YesKeywords) {
            $vlc = Find-Vlc
            $ff = Find-FFmpegFull
            if (-not $vlc -and -not $ff) { Write-Host $L.CheckNoBackends -ForegroundColor Red; Pause-Menu; return }
            Write-Host $L.CheckRunning -ForegroundColor Yellow
            $results = @()
            $total = @($config.streams | Where-Object { $_.PSObject.Properties['port'] -and [int]$_.port -gt 0 }).Count
            $idx = 0
            foreach ($s in $config.streams) {
                $p = 0
                if ($s.PSObject.Properties['port'] -and $s.port) { $p = [int]$s.port }
                if ($p -le 0) { continue }
                $idx++
                $pct = if ($total -gt 0) { [math]::Round(($idx / $total) * 100) } else { 100 }
                Write-Host ("`r" + ($L.CheckProgress -f $idx, $total, $pct)) -NoNewline -ForegroundColor DarkGray
                $r = [PSCustomObject]@{ Name = $s.name; Url = $s.url; Port = $p; Vlc = "skip"; Ffmpeg = "skip"; Recommend = "" }
                if ($vlc) { $r.Vlc = Test-BackendForStream "vlc" $s.url $p $vlc $ff } else { $r.Vlc = "missing" }
                if ($ff) { $r.Ffmpeg = Test-BackendForStream "ffmpeg" $s.url $p $vlc $ff } else { $r.Ffmpeg = "missing" }
                if ($r.Vlc -eq "ok" -and $r.Ffmpeg -eq "ok") { $r.Recommend = "ffmpeg" }
                elseif ($r.Ffmpeg -eq "ok") { $r.Recommend = "ffmpeg" }
                elseif ($r.Vlc -eq "ok") { $r.Recommend = "vlc" }
                else { $r.Recommend = "none" }
                $results += $r
            }
            Write-Host ""
            if ($results.Count -eq 0) { Write-Host $L.CheckNoProxy -ForegroundColor DarkGray; Pause-Menu; return }
            Write-Host ""
            foreach ($r in $results) {
                $rec = $r.Recommend
                if ($rec -eq "none" -and -not $vlc -and -not $ff) { $rec = $L.NoBackendAssigned }
                Write-Host ("  {0}  vlc={1}  ffmpeg={2}  -> {3}" -f $r.Name, $r.Vlc, $r.Ffmpeg, $rec)
            }
            Write-Host ""
            Write-Host $L.CheckSave -ForegroundColor Yellow
            $ans2 = Read-Host "$($L.YN)"
            if (Test-Keyword $ans2 $L.YesKeywords) {
                foreach ($s in $config.streams) {
                    $p = 0
                    if ($s.PSObject.Properties['port'] -and $s.port) { $p = [int]$s.port }
                    if ($p -le 0) { continue }
                    $r = $results | Where-Object { $_.Name -eq $s.name } | Select-Object -First 1
                    if ($r) {
                        if ($r.Recommend -eq "vlc" -or $r.Recommend -eq "ffmpeg") {
                            $s | Add-Member -NotePropertyName backend -NotePropertyValue $r.Recommend -Force
                        } elseif ($r.Recommend -eq "none") {
                            if ($s.PSObject.Properties['backend']) { $s.PSObject.Properties.Remove('backend') }
                        }
                    }
                }
                Save-Config $config
                Write-Host $L.CheckSaved -ForegroundColor Green
            }
        }
    }
    Pause-Menu
}

function Edit-Stream($game, $index) {
    $st = $config.streams[$index]
    $isProxy = ($st.PSObject.Properties['port'] -and [int]$st.port -gt 0)
    $oldName = $st.name
    $oldSiiUrl = ""
if ($isProxy) { $oldSiiUrl = "http://127.0.0.1:$($st.port)$RadioPath" } else { $oldSiiUrl = $st.url }
    $curUrl = $st.url
    $curName = $st.name
    $curGenre = if ($st.genre) { $st.genre } else { "" }
    $curLang = if ($st.lang) { $st.lang } else { "" }
    $curBitrate = if ($st.bitrate) { $st.bitrate } else { "" }
    $curFav = if ($st.fav) { $st.fav } else { "" }
    $curBackend = if ($st.PSObject.Properties['backend'] -and $st.backend) { [string]$st.backend } else { "auto" }
    $curProxy = $isProxy
    $curPort = 0
    if ($isProxy) { $curPort = [int]$st.port }
    $dirty = $false
    while ($true) {
        Clear-Host
        Write-Host "=== $($L.EditStream) ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host ("  1. $($L.EditName): $curName")
        Write-Host ("  2. $($L.EditProxy): $curProxy")
        Write-Host ("  3. $($L.EditUrl): $(Get-SafeUrl $curUrl)")
        Write-Host ("  4. $($L.EditGenre): $curGenre")
        Write-Host ("  5. $($L.EditLang): $curLang")
        Write-Host ("  6. $($L.EditBitrate): $curBitrate")
        Write-Host ("  7. $($L.EditFav): $curFav")
        if ($curProxy) {
            Write-Host ("  8. $($L.EditPort): $curPort")
            Write-Host ("  9. $($L.EditBackend): $curBackend")
        }
        Write-Host ""
        $c = Read-Host $L.Choose
        $c = "$c".Trim()
        if (Test-Keyword $c $L.BackKeywords) { break }
        if ($c -eq "1") {
            $v = Read-Host $L.EditName
            $v = "$v".Trim()
            if (Test-Keyword $v $L.BackKeywords) { continue }
            if (-not $v) { Write-Host $L.RenameEmpty -ForegroundColor Red; Start-Sleep -Seconds 1; continue }
            $dup = $false
            for ($j = 0; $j -lt $config.streams.Count; $j++) {
                if ($j -ne $index -and $config.streams[$j].name -eq $v) { $dup = $true; break }
            }
            if ($dup) { Write-Host $L.RenameDuplicate -ForegroundColor Red; Start-Sleep -Seconds 1; continue }
            $curName = $v
            $dirty = $true
        } elseif ($c -eq "2") {
            Write-Host $L.EditProxyAsk -ForegroundColor Yellow
            $v = Read-Host $L.YN
            if (Test-Keyword $v $L.BackKeywords) { continue }
            if (Test-Keyword $v $L.YesKeywords) {
                if (-not $curProxy) {
                    $newP = Get-FreePort $config 18084 20000
                    if (-not $newP) { Write-Host $L.PortBusy -ForegroundColor Red; Start-Sleep -Seconds 2; continue }
                    $curProxy = $true
                    $curPort = $newP
                    Write-Host "$($L.PortLabel): $newP" -ForegroundColor DarkGray
                }
            } elseif (Test-Keyword $v $L.NoKeywords) {
                $curProxy = $false
                $curPort = 0
            } else {
                Write-Host $L.InvalidChoice -ForegroundColor Red
                Start-Sleep -Seconds 1
                continue
            }
            $dirty = $true
        } elseif ($c -eq "3") {
            $v = Read-Host $L.EditUrl
            $v = "$v".Trim()
            if (Test-Keyword $v $L.BackKeywords) { continue }
            if (Test-LocalUrl $v) { Write-Host $L.UrlLocal -ForegroundColor Red; Start-Sleep -Seconds 2; continue }
            if ($v -match '^https://') {
                $alt = $v -replace '^https://', 'http://'
                if (-not (Test-Url $alt)) {
                    Write-Host $L.UrlInvalid -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    continue
                }
                Write-Host $L.UrlHttpsAsk -ForegroundColor Yellow
                $ha = Read-Host "$($L.YN)"
                if (-not (Test-Keyword $ha $L.YesKeywords)) { continue }
                $v = $alt
                Write-Host "$($L.ImportHttpsReplaced) $alt" -ForegroundColor Yellow
            } elseif (-not (Test-Url $v)) {
                if ($v -match '^http://') { Write-Host $L.UrlIncomplete -ForegroundColor Red }
                else { Write-Host $L.UrlInvalid -ForegroundColor Red }
                Start-Sleep -Seconds 2
                continue
            }
            $busyName = $null
            for ($j = 0; $j -lt $config.streams.Count; $j++) {
                if ($j -ne $index -and $config.streams[$j].url -eq $v) { $busyName = $config.streams[$j].name; break }
            }
            if ($busyName) { Write-Host ($L.UrlBusy -f $busyName) -ForegroundColor Red; Start-Sleep -Seconds 2; continue }
            $curUrl = $v
            $dirty = $true
        } elseif ($c -eq "4") {
            $v = Read-Host $L.EditGenre
            $v = "$v".Trim()
            if (Test-Keyword $v $L.BackKeywords) { continue }
            $curGenre = $v
            $dirty = $true
        } elseif ($c -eq "5") {
            $v = Read-Host $L.EditLang
            $v = "$v".Trim()
            if (Test-Keyword $v $L.BackKeywords) { continue }
            $curLang = $v
            $dirty = $true
        } elseif ($c -eq "6") {
            $v = Read-Host $L.EditBitrate
            $v = "$v".Trim()
            if (Test-Keyword $v $L.BackKeywords) { continue }
            $curBitrate = $v
            $dirty = $true
        } elseif ($c -eq "7") {
            $v = Read-Host $L.EditFav
            $v = "$v".Trim()
            if (Test-Keyword $v $L.BackKeywords) { continue }
            if ($v -ne "0" -and $v -ne "1") { Write-Host $L.FavInvalid -ForegroundColor Red; Start-Sleep -Seconds 1; continue }
            $curFav = $v
            $dirty = $true
        } elseif ($c -eq "8") {
            if (-not $curProxy) {
                Write-Host $L.InvalidChoice -ForegroundColor Red
                Start-Sleep -Seconds 1
                continue
            }
            $v = Read-Host $L.EditPort
            $v = "$v".Trim()
            if (Test-Keyword $v $L.BackKeywords) { continue }
            $pv = 0
            if (-not [int]::TryParse($v, [ref]$pv) -or $pv -lt 1 -or $pv -gt 65535) {
                Write-Host $L.PortInvalid -ForegroundColor Red
                Start-Sleep -Seconds 2
                continue
            }
            $busyName = $null
            for ($j = 0; $j -lt $config.streams.Count; $j++) {
                if ($j -ne $index -and $config.streams[$j].PSObject.Properties['port'] -and [int]$config.streams[$j].port -eq $pv) {
                    $busyName = $config.streams[$j].name
                    break
                }
            }
            if ($busyName) { Write-Host ($L.PortBusyStation -f $busyName) -ForegroundColor Red; Start-Sleep -Seconds 2; continue }
            if (-not (Test-PortFree $pv)) { Write-Host $L.PortBusy -ForegroundColor Red; Start-Sleep -Seconds 2; continue }
            $curPort = $pv
            $dirty = $true
        } elseif ($c -eq "9") {
            if (-not $curProxy) {
                Write-Host $L.InvalidChoice -ForegroundColor Red
                Start-Sleep -Seconds 1
                continue
            }
            Write-Host ""
            Write-Host $L.BackendStationVlc
            Write-Host $L.BackendStationFfmpeg
            Write-Host $L.BackendStationAuto
            $bc = Read-Host $L.Choose
            $bc = "$bc".Trim()
            if (Test-Keyword $bc $L.BackKeywords) { continue }
            if ($bc -eq "1") { $curBackend = "vlc"; $dirty = $true }
            elseif ($bc -eq "2") { $curBackend = "ffmpeg"; $dirty = $true }
            elseif ($bc -eq "3") { $curBackend = "auto"; $dirty = $true }
        } else {
            Write-Host $L.InvalidChoice -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }
    }
    if (-not $dirty) { return }
    $st.name = $curName
    $st.url = $curUrl
    $st.genre = $curGenre
    $st.lang = $curLang
    $st.bitrate = $curBitrate
    $st.fav = $curFav
    if ($curProxy -and $curPort -gt 0) {
        $st | Add-Member -NotePropertyName port -NotePropertyValue $curPort -Force
    } else {
        if ($st.PSObject.Properties['port']) { $st.PSObject.Properties.Remove('port') }
    }
    if ($curBackend -eq "auto") {
        if ($st.PSObject.Properties['backend']) { $st.PSObject.Properties.Remove('backend') }
    } else {
        $st | Add-Member -NotePropertyName backend -NotePropertyValue $curBackend -Force
    }
    Save-Config $config
    $newSiiUrl = ""
if ($curProxy -and $curPort -gt 0) { $newSiiUrl = "http://127.0.0.1:$curPort$RadioPath" } else { $newSiiUrl = $curUrl }
    $sii = Read-Sii $game
    if ($sii) {
        if (Update-SiiLine $game $oldName $newSiiUrl $curName $curGenre $curLang $curBitrate $curFav) {
            Write-Host $L.EditSaved -ForegroundColor Green
        } else {
            Write-Host $L.RenameFailed -ForegroundColor Yellow
        }
    } else {
        Write-Host $L.EditSaved -ForegroundColor Green
    }
    $changed = Sync-IndexFromSii $game $config
    if ($changed -gt 0) { Save-Config $config }
}

function Screen-Audit($Game) {
    Show-Header $L.Audit $Game
    $changed = Sync-IndexFromSii $Game $config
    if ($changed -gt 0) { Save-Config $config }
    $audit = Get-StreamAudit $Game $config
    Write-Host "$($L.AuditCfgCount): $($audit.TotalCfg)  $($L.AuditSiiCount): $($audit.TotalSii)" -ForegroundColor Cyan
    Write-Host ""
    if ($audit.MissingIndex.Count -gt 0) {
        Write-Host "$($L.AuditMissingIndex): $($audit.MissingIndex.Count)" -ForegroundColor Yellow
        foreach ($x in $audit.MissingIndex) {
            Write-Host ("  - {0}" -f $x.Name) -ForegroundColor DarkGray
        }
        Write-Host ""
    }
    if ($audit.TotalCfg -eq 0 -and $audit.TotalSii -eq 0) {
        Write-Host $L.AuditEmpty -ForegroundColor DarkGray
        Write-Host ""
        return
    }
    if ($audit.OnlyCfg.Count -eq 0 -and $audit.OnlySii.Count -eq 0 -and $audit.Matched.Count -eq 0) {
        Write-Host $L.AuditOk -ForegroundColor Green
        Write-Host ""
        return
    }
    if ($audit.OnlyCfg.Count -gt 0) {
        Write-Host "$($L.AuditOnlyCfg): $($audit.OnlyCfg.Count)" -ForegroundColor Yellow
        foreach ($x in $audit.OnlyCfg) {
            $reason = switch ($x.Reason) {
                "missing_in_sii" { $L.AuditReasonMissingInSii }
                "no_sii" { $L.AuditReasonNoSii }
                "dup_in_cfg" { $L.AuditReasonDupCfg }
                default { $x.Reason }
            }
            Write-Host ("  - {0} [{1}]" -f $x.Name, $reason) -ForegroundColor DarkGray
        }
        Write-Host ""
    }
    if ($audit.OnlySii.Count -gt 0) {
        Write-Host "$($L.AuditOnlySii): $($audit.OnlySii.Count)" -ForegroundColor Yellow
        foreach ($x in $audit.OnlySii) {
            $reason = switch ($x.Reason) {
                "missing_in_cfg" { $L.AuditReasonMissingInCfg }
                "dup_in_sii" { $L.AuditReasonDupSii }
                default { $x.Reason }
            }
            Write-Host ("  - {0} [{1}]" -f $x.Name, $reason) -ForegroundColor DarkGray
        }
        Write-Host ""
    }
    if ($audit.Matched.Count -gt 0) {
        Write-Host "$($L.AuditDiffs): $($audit.Matched.Count)" -ForegroundColor Yellow
        foreach ($m in $audit.Matched) {
            Write-Host ("  - {0}" -f $m.Name)
            foreach ($d in $m.Diffs) {
                Write-Host ("      {0}: cfg=[{1}] sii=[{2}]" -f $d.Field, $d.Cfg, $d.Sii) -ForegroundColor DarkGray
            }
        }
        Write-Host ""
    }
    Write-Host $L.AuditRewriteAsk -ForegroundColor Yellow
    $ans = Read-Host "$($L.YN)"
    if (Test-Keyword $ans $L.BackKeywords) { return }
    if (-not (Test-Keyword $ans $L.YesKeywords)) { return }
    Write-Host ""
    Write-Host $L.AuditRewriteMode -ForegroundColor Yellow
    Write-Host $L.AuditRewriteFull
    Write-Host $L.AuditRewriteAppend
    $modeSel = Read-Host $L.Choose
    $modeSel = "$modeSel".Trim()
    if (Test-Keyword $modeSel $L.BackKeywords) { return }
    if ($modeSel -ne "1" -and $modeSel -ne "2") { Write-Host $L.InvalidChoice -ForegroundColor Red; return }
    $mode = if ($modeSel -eq "1") { "full" } else { "append" }
    $res = Rewrite-Sii $Game $config $mode
    if ($res) {
        Write-Host "$($L.AuditRewriteDone): $($res.Total)" -ForegroundColor Green
        if ($res.Added -gt 0) { Write-Host "$($L.AuditRewriteAdded): $($res.Added)" -ForegroundColor DarkGray }
        if ($res.SkippedDup -gt 0) { Write-Host "$($L.AuditRewriteSkipped): $($res.SkippedDup)" -ForegroundColor DarkGray }
    } else {
        Write-Host $L.AuditRewriteFailed -ForegroundColor Red
    }
    Write-Host ""
}

function Screen-Clear($Game) {
    Show-Header $L.ClearTitle $Game
    $info = Get-CacheAndLogsInfo $Game
    $gameRunning = Test-GameRunning $Game
        if ($info.Items.Count -eq 0) {
        Write-Host $L.ClearNothing -ForegroundColor DarkGray
        Write-Host ""
        return $false
    }
    Write-Host $L.ClearList -ForegroundColor Yellow
    foreach ($it in $info.Items) {
        $sizeStr = "{0:N0} B" -f $it.Size
        $tag = switch ($it.Kind) {
            "cache" { "[cache]" }
            "log_old" { "[log old]" }
            "log_cur" { "[log cur]" }
            "bak" { "[backup]" }
            "export" { "[export]" }
            default { "" }
        }
        Write-Host ("  {0} {1}  {2}" -f $tag, $it.Path, $sizeStr) -ForegroundColor DarkGray
    }
    if ($gameRunning) {
        Write-Host ""
        Write-Host $L.ClearCurrentLogsSkip -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host $L.ClearAsk -ForegroundColor Yellow
    $ans = Read-Host "$($L.YN)"
    if (Test-Keyword $ans $L.BackKeywords) { return $false }
        if (-not (Test-Keyword $ans $L.YesKeywords)) { Write-Host $L.Cancelled -ForegroundColor Yellow; return $false }
    $res = Clear-CacheAndLogs $Game $gameRunning
    Write-Host ""
    Write-Host "$($L.ClearDone) $($res.Deleted)" -ForegroundColor Green
    if ($res.Freed -gt 0) { Write-Host "$($L.ClearFreed) $($res.Freed)" -ForegroundColor DarkGray }
    if ($res.Skipped -gt 0) { Write-Host "$($L.ClearSkipped) $($res.Skipped)" -ForegroundColor DarkGray }
    Write-Host ""
    return $true
}

$config = Load-Config
if (-not $config) { Read-Host "Press Enter to exit"; exit 1 }
if (-not (Test-Path $ConfigPath)) { Save-Config $config }

:gameLoop while ($true) {
    $games = Get-AvailableGames
    if ($games.Count -eq 0) {
        Clear-Host
        Write-Host "=== $($L.Title) $Version ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host $L.NoGamesFound -ForegroundColor Red
        Write-Host ""
        [void](Read-Host $L.PressEnter)
        break gameLoop
    }
    if ($games.Count -eq 1) {
        $game = $games[0].Code
    } else {
        Screen-GameSelect $games
        $g = Read-Host $L.ChooseGame
        $g = "$g".Trim()
        $idx = 0
        if (-not [int]::TryParse($g, [ref]$idx) -or $idx -lt 1 -or $idx -gt $games.Count) {
            Write-Host $L.InvalidGame -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue gameLoop
        }
        $game = $games[$idx - 1].Code
    }
    $gameName = Get-GameName $game
    $synced = Sync-IndexFromSii $game $config
    if ($synced -gt 0) { Save-Config $config }

    :menuLoop while ($true) {
        $items = Get-MenuItems $games.Count
        Screen-Menu $game $items
        $choice = Read-Host $L.ChooseMenu
        $choice = "$choice".Trim()
        $n = 0
        if (-not [int]::TryParse($choice, [ref]$n) -or $n -lt 1 -or $n -gt $items.Count) {
            Write-Host $L.InvalidChoice -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue menuLoop
        }
        $action = $items[$n - 1].Action
        switch ($action) {
            "backend" {
                :backendLoop while ($true) {
                    Screen-Backend $game
                    $b = Read-Host $L.Choose
                    $b = "$b".Trim()
                    if (Test-Keyword $b $L.BackKeywords) { break backendLoop }
                    if ($b -eq "1") { Set-Backend $game "vlc"; break backendLoop }
                    elseif ($b -eq "2") { Set-Backend $game "ffmpeg"; break backendLoop }
                    elseif ($b -eq "3") { Set-Backend $game "auto"; break backendLoop }
                    elseif ($b -match '^\d+$') {
                        Write-Host ($L.BackendBadIndex -f $b) -ForegroundColor Red
                        Start-Sleep -Milliseconds 1400
                    } else {
                        Write-Host $L.BackendBadFormat -ForegroundColor Red
                        Start-Sleep -Milliseconds 1400
                    }
                }
                continue menuLoop
            }
            "add" {
                if (Test-GameRunning $game) { Screen-Add $game; Write-Host "$gameName $($L.GameRunning)" -ForegroundColor Red; Pause-Menu; continue menuLoop }
                :addLoop while ($true) {
                    Screen-Add $game
                    $urlRes = Read-UrlInput $L
                    if ($urlRes.Back) { break addLoop }
                    if (-not $urlRes.Ok) { Start-Sleep -Milliseconds 1400; continue addLoop }
                    $url = $urlRes.Url
                    if ($urlRes.Replaced) {
                        Start-Sleep -Milliseconds 1400
                        Clear-Host
                        Screen-Add $game
                    }
                    Write-Host $L.CheckingStream -ForegroundColor DarkGray
                    $looksDirect = Test-DirectStream $url
                    Clear-Host
                    Screen-Add $game
                    if ($looksDirect) { Write-Host $L.TranscodeHintDirect -ForegroundColor DarkGray }
                    $tcRes = Read-TranscodeAnswer $L
                    if ($tcRes.Back) { break addLoop }
                    if (-not $tcRes.Ok) { Start-Sleep -Milliseconds 1400; continue addLoop }
                    $needsTranscode = $tcRes.Value
                    $portInt = 0
                    if ($needsTranscode) {
                        $curProxies = @($config.streams | Where-Object { $_.PSObject.Properties['port'] -and [int]$_.port -gt 0 }).Count
                        if ($curProxies -ge 63) {
                            Write-Host ($L.TooManyProxies -f $curProxies, 1) -ForegroundColor Red
                            Pause-Menu
                            continue addLoop
                        }
                        $portInt = Get-FreePort $config 18084 20000
                        if (-not $portInt) { Write-Host $L.PortBusy -ForegroundColor Red; Start-Sleep -Milliseconds 1400; continue addLoop }
                        Write-Host "$($L.PortLabel): $portInt $($L.PortAuto)" -ForegroundColor DarkGray
                    } else {
                        Write-Host "$($L.DirectMp3)" -ForegroundColor DarkGray
                    }
                    $name = $null
                    while ($true) {
                        $name = Read-Host $L.Name
                        $name = "$name".Trim()
                        if (Test-Keyword $name $L.BackKeywords) { break addLoop }
                        if (-not $name) { Write-Host $L.NameRequired -ForegroundColor Red; Start-Sleep -Milliseconds 1400; continue addLoop }
                        break
                    }
                    $genre = Read-Host $L.Genre
                    $genre = "$genre".Trim()
                    if (Test-Keyword $genre $L.BackKeywords) { break addLoop }
                    if (-not $genre) { $genre = "" }
                    $lang = Read-Host $L.StreamLang
                    $lang = "$lang".Trim()
                    if (Test-Keyword $lang $L.BackKeywords) { break addLoop }
                    if (-not $lang) { $lang = "RU" }
                    $bitrate = Read-Host $L.Bitrate
                    $bitrate = "$bitrate".Trim()
                    if (Test-Keyword $bitrate $L.BackKeywords) { break addLoop }
                    if (-not $bitrate) { $bitrate = "128" }
                    $fav = Read-Host $L.Fav
                    $fav = "$fav".Trim()
                    if (Test-Keyword $fav $L.BackKeywords) { break addLoop }
                    if (-not $fav) { $fav = "0" }
                    $maxIdx = -1
                    foreach ($s2 in $config.streams) {
                        if ($s2.PSObject.Properties['index'] -and $null -ne $s2.index) {
                            $iv = [int]$s2.index
                            if ($iv -gt $maxIdx) { $maxIdx = $iv }
                        }
                    }
                    $newStream = [PSCustomObject]@{ url = $url; name = $name; genre = $genre; lang = $lang; bitrate = $bitrate; fav = $fav; index = ($maxIdx + 1) }
                    if ($needsTranscode) { $newStream | Add-Member -NotePropertyName port -NotePropertyValue $portInt -Force }
                    $config.streams += $newStream
                    Save-Config $config
                    $sii = Read-Sii $game
                    if ($sii) {
                        if ($needsTranscode) {
                            $siiUrl = "http://127.0.0.1:$portInt/radio.mp3"
                        } else {
                            $siiUrl = $url
                        }
                        $newRaw = $siiUrl + "|" + $name + "|" + $genre + "|" + $lang + "|" + $bitrate + "|" + $fav
                        if (Add-SiiLine $game $newRaw) { Write-Host $L.AddedToBoth -ForegroundColor Green } else { Write-Host $L.AddedOnlyConfig -ForegroundColor Yellow }
                    } else { Write-Host $L.AddedNoSii -ForegroundColor Yellow }
                    Sync-IndexFromSii $game $config | Out-Null
                    Save-Config $config
                    Start-Sleep -Milliseconds 1400
                }
                continue menuLoop
            }
            "remove" {
                if (Test-GameRunning $game) { Screen-Remove $game; Write-Host "$gameName $($L.GameRunning)" -ForegroundColor Red; Pause-Menu; continue menuLoop }
                if ($config.streams.Count -eq 0) { Screen-Remove $game; Write-Host $L.NoStreamsInConfig -ForegroundColor Yellow; Pause-Menu; continue menuLoop }
                :removeLoop while ($true) {
                    if ($config.streams.Count -eq 0) {
                        Write-Host $L.NoStreamsInConfig -ForegroundColor Yellow
                        Pause-Menu
                        break removeLoop
                    }
                    Screen-Remove $game
                    $i = 0
                    foreach ($s in $config.streams) {
                        $p = 0
                        if ($s.PSObject.Properties['port'] -and $s.port) { $p = [int]$s.port }
                        $portSuffix = if ($p -gt 0) { " - port $p" } else { "" }
                        Write-Host ("  [{0}] {1} - {2}{3}" -f $i, $s.name, (Get-SafeUrl $s.url), $portSuffix)
                        $i++
                    }
                    Write-Host ""
                    Write-Host $L.RemoveMultipleHint -ForegroundColor DarkGray
                    Write-Host ""
                    $idx2 = Read-Host $L.IndexToRemove
                    $idx2 = "$idx2".Trim()
                    if (Test-Keyword $idx2 $L.BackKeywords) { break removeLoop }
                    if (-not $idx2) { Write-Host $L.Cancelled -ForegroundColor Yellow; Start-Sleep -Milliseconds 1400; continue removeLoop }
                    if ($L.AllKeywords -contains $idx2.ToLower()) { $idx2 = "all" }
                    $parsedRes = Parse-IndexListStrict $idx2 $config.streams.Count
                    if (-not $parsedRes.Ok) {
                        if ($parsedRes.Error -eq "empty") {
                            Write-Host $L.NoStreamsInConfig -ForegroundColor Yellow
                        } elseif ($parsedRes.Error -eq "format") {
                            Write-Host $L.RemoveBadFormat -ForegroundColor Red
                        } else {
                            $maxIdx = $config.streams.Count - 1
                            Write-Host ($L.RemoveBadIndex -f ($parsedRes.BadIndexes -join ', '), $maxIdx) -ForegroundColor Red
                        }
                        Start-Sleep -Milliseconds 1400
                        continue removeLoop
                    }
                    $parsed = $parsedRes.Indexes
                    $names = @()
                    foreach ($k in $parsed) { $names += $config.streams[$k].name }
                    Write-Host ""
                    Write-Host "$($L.ConfirmRemove) $($parsed.Count) $($L.Stations)" -ForegroundColor Yellow
                    foreach ($nm in $names) { Write-Host "  - $nm" -ForegroundColor DarkGray }
                    $confirm = Read-Host "$($L.ConfirmRemove) $($L.YN)"
                    if (Test-Keyword $confirm $L.BackKeywords) { continue removeLoop }
                    if (-not (Test-Keyword $confirm $L.YesKeywords)) { Write-Host $L.Cancelled -ForegroundColor Yellow; Start-Sleep -Milliseconds 1400; continue removeLoop }

                    $sii = Read-Sii $game
                    $siiUrls = @()
                    if ($sii) {
                        foreach ($k in $parsed) {
                            $siiUrls += (Get-SiiUrlForStream $config.streams[$k])
                        }
                    }

                    $config.streams = @($config.streams | Where-Object { $parsed -notcontains [array]::IndexOf($config.streams, $_) })
                    Save-Config $config

                    if ($sii -and $siiUrls.Count -gt 0) {
                        $ok = 0
                        foreach ($u in $siiUrls) {
                            if (Remove-SiiLine $game $u) { $ok++ }
                        }
                        if ($ok -eq $siiUrls.Count) { Write-Host $L.RemovedBoth -ForegroundColor Green }
                        else { Write-Host $L.RemovedOnlyConfig -ForegroundColor Yellow }
                    } elseif ($sii) {
                        Write-Host $L.RemovedBoth -ForegroundColor Green
                    } else {
                        Write-Host $L.RemovedNoSii -ForegroundColor Yellow
                    }
                    Sync-IndexFromSii $game $config | Out-Null
                    Save-Config $config
                    Start-Sleep -Milliseconds 1400
                    continue removeLoop
                }
                continue menuLoop
            }
            "list" {
                $leaveList = $false
                :listLoop while (-not $leaveList) {
                    Screen-List $game
                    $line = $null
                    while ($true) {
                        while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
                        Write-Host "$($L.CmdPrompt): " -NoNewline -ForegroundColor DarkGray
                        [Console]::Out.Flush()
                        $raw = Read-Host
                        $t = "$raw".Trim()
                        if (Test-Keyword $t $L.BackKeywords) { $leaveList = $true; break }
                        if (-not $t) { continue }
                        $line = $t
                        break
                    }
                    if ($leaveList) { break }
                    if ($line -match '^[gGзЗ]\s*(\d+)$') {
                        $ei = [int]$Matches[1]
                        if ($ei -lt 0 -or $ei -ge $config.streams.Count) {
                            Write-Host "$($L.InvalidIndex) ($($L.ConfigCount): $($config.streams.Count))" -ForegroundColor Red
                            Pause-Menu
                            continue
                        }
                        Edit-Stream $game $ei
                        continue
                    }
                    if ($line -match '^[kKкК]\s*(\d+)$') {
                        $ci = [int]$Matches[1]
                        if ($ci -lt 0 -or $ci -ge $config.streams.Count) {
                            Write-Host "$($L.InvalidIndex) ($($L.ConfigCount): $($config.streams.Count))" -ForegroundColor Red
                            Pause-Menu
                            continue
                        }
                        $copyUrl = $config.streams[$ci].url
                        if ([string]::IsNullOrWhiteSpace($copyUrl)) {
                            Write-Host $L.CmdCopyEmpty -ForegroundColor Yellow
                            Pause-Menu
                            continue
                        }
                        if (-not (Test-Url $copyUrl)) {
                            Write-Host $L.CmdCopyInvalid -ForegroundColor Yellow
                            Pause-Menu
                            continue
                        }
                        try {
                            Set-Clipboard -Value $copyUrl
                            Write-Host $L.CmdCopied -ForegroundColor Green
                        } catch {
                            Write-Host ($L.CmdCopyFailed -f $_.Exception.Message) -ForegroundColor Red
                        }
                        Pause-Menu
                        continue
                    }
                    if ($line -eq "з" -or $line -eq "З" -or $line -eq "g" -or $line -eq "G" -or
                        $line -eq "к" -or $line -eq "К" -or $line -eq "k" -or $line -eq "K") {
                        Write-Host $L.NeedIndex -ForegroundColor Yellow
                        Pause-Menu
                        continue
                    }
                    $found = $null
                    for ($j = 0; $j -lt $config.streams.Count; $j++) {
                        if ($config.streams[$j].name -and $config.streams[$j].name.ToLowerInvariant().Contains($line.ToLowerInvariant())) {
                            $found = $j
                            break
                        }
                    }
                    if ($found -ne $null) {
                        Write-Host ""
                        Write-Host ($L.StationFound -f $found) -ForegroundColor Green
                        Pause-Menu
                        continue
                    } else {
                        Write-Host $L.StationNotFound -ForegroundColor Yellow
                        Pause-Menu
                        continue
                    }
                }
                continue menuLoop
            }
                        "ffmpeg" {
                :ffmpegLoop while ($true) {
                    Screen-FFmpeg $game
                    $ff = Read-Host $L.Choose
                    $ff = "$ff".Trim()
                    if (Test-Keyword $ff $L.BackKeywords) { break ffmpegLoop }
                    if ($ff -eq "1") {
                        Install-FFmpeg | Out-Null
                        Pause-Menu
                        break ffmpegLoop
                    }
                    Write-Host $L.InvalidChoice -ForegroundColor Red
                    Start-Sleep -Milliseconds 1400
                }
                continue menuLoop
            }

"steamcmd" {
                :steamcmdLoop while ($true) {
                    Screen-SteamCmd $game
                    $sc = Read-Host $L.Choose
                    $sc = "$sc".Trim()
                    if (Test-Keyword $sc $L.BackKeywords) { break steamcmdLoop }
                    if ($sc -eq "к" -or $sc -eq "К" -or $sc -eq "k" -or $sc -eq "K") {
                        $cmd = Get-SteamCommand $game
                        try {
                            Set-Clipboard -Value $cmd
                            Write-Host $L.CmdCopied -ForegroundColor Green
                        } catch {
                            Write-Host ($L.CmdCopyFailed -f $_.Exception.Message) -ForegroundColor Red
                        }
                        Pause-Menu
                        continue steamcmdLoop
                    }
                    Write-Host $L.InvalidChoice -ForegroundColor Red
                    Start-Sleep -Milliseconds 1400
                }
                continue menuLoop
            }

            "lang" {
                :langLoop while ($true) {
                    Screen-Lang
                    $lc = Read-Host $L.Choose
                    $lc = "$lc".Trim()
                    if (Test-Keyword $lc $L.BackKeywords) { break langLoop }
                    if ($lc -eq "1") {
                        if ($currentLang -eq "ru") {
                            Write-Host $L.LangAlreadyRu -ForegroundColor Yellow
                            Start-Sleep -Milliseconds 1400
                            break langLoop
                        }
                        Save-Lang "ru"
                        $currentLang = Load-Lang
                        Write-Host $L.LangChanged -ForegroundColor Green
                        Start-Sleep -Milliseconds 1400
                        break langLoop
                    } elseif ($lc -eq "2") {
                        if ($currentLang -eq "en") {
                            Write-Host $L.LangAlreadyEn -ForegroundColor Yellow
                            Start-Sleep -Milliseconds 1400
                            break langLoop
                        }
                        Save-Lang "en"
                        $currentLang = Load-Lang
                        Write-Host $L.LangChanged -ForegroundColor Green
                        Start-Sleep -Milliseconds 1400
                        break langLoop
                    } else {
                        Write-Host $L.InvalidChoice -ForegroundColor Red
                        Start-Sleep -Milliseconds 1400
                    }
                }
                continue menuLoop
            }
            "import" {
                :importLoop while ($true) {
                    Clear-Host
                    Write-Host "=== $($L.ImportStreams) ===" -ForegroundColor Cyan
                    Write-Host ""
                    $curProxies = @($config.streams | Where-Object { $_.PSObject.Properties['port'] -and [int]$_.port -gt 0 }).Count
                    $slots = 63 - $curProxies
                    if ($slots -le 0) {
                        Write-Host $L.ProxySlotsNone -ForegroundColor Yellow
                    } else {
                        Write-Host ($L.ProxySlotsLeft -f $slots) -ForegroundColor DarkGray
                    }
                    $default = Join-Path $ConfigDir "streams-export.json"
                    Write-Host "$($L.ImportPathHint) $default" -ForegroundColor DarkGray
                    $path = Read-Host $L.ImportPath
                    $path = "$path".Trim()
                    if (Test-Keyword $path $L.BackKeywords) { break importLoop }
                    if (-not $path) { $path = $default }
                    if (-not (Test-Path $path)) {
                        Write-Host ($L.ImportFileNotFound -f $path) -ForegroundColor Red
                        Start-Sleep -Milliseconds 1400
                        continue importLoop
                    }

                    $isM3u = $false
                    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
                    if ($ext -eq ".m3u" -or $ext -eq ".m3u8") { $isM3u = $true }
                    elseif ($ext -ne ".json") {
                        Write-Host $L.ImportTypeAsk -ForegroundColor Yellow
                        $ty = Read-Host $L.Choose
                        $ty = "$ty".Trim().ToLowerInvariant()
                        if ($ty -eq "m" -or $ty -eq "м") { $isM3u = $true }
                        elseif ($ty -eq "j" -or $ty -eq "ж") { $isM3u = $false }
                        else {
                            Write-Host $L.ImportBadType -ForegroundColor Red
                            Start-Sleep -Milliseconds 1400
                            continue importLoop
                        }
                    }

                    $rawItems = @(Read-ImportSource $path $isM3u)
                    if ($rawItems.Count -eq 0) {
                        Write-Host $L.ImportFileEmpty -ForegroundColor Red
                        Start-Sleep -Milliseconds 1400
                        continue importLoop
                    }

                    Write-Host ""
                    Write-Host $L.ImportCheckWarning -ForegroundColor DarkGray
                    $res = Process-ImportItems $rawItems
                    if ($res.Streams.Count -eq 0) {
                        Write-Host $L.ImportFileEmpty -ForegroundColor Red
                        Start-Sleep -Milliseconds 1400
                        continue importLoop
                    }

                    Write-Host ""
                    Write-Host "$($L.Imported) $($res.Streams.Count)" -ForegroundColor Green
                    if ($res.Skipped -gt 0) {
                        $msg = "$($L.Skipped) $($res.Skipped) " + (Format-IndexList $res.SkippedIdx)
                        Write-Host $msg -ForegroundColor Yellow
                    }
                    if ($res.SkippedDup -gt 0) {
                        $msg = ($L.ImportSkippedDup -f $res.SkippedDup) + " " + (Format-IndexList $res.SkippedDupIdx)
                        Write-Host $msg -ForegroundColor Yellow
                    }
                    if ($res.SkippedLocal -gt 0) {
                        $msg = ($L.SkippedLocal -f (Format-IndexList $res.SkippedLocalIdx))
                        Write-Host $msg -ForegroundColor Yellow
                    }
                    if ($res.SkippedProxy -gt 0) {
                        $msg = ($L.SkippedProxy -f (Format-IndexList $res.SkippedProxyIdx))
                        Write-Host $msg -ForegroundColor Yellow
                    }
                    if ($res.HttpsSkipped -gt 0) {
                        $msg = "$($L.ImportHttpsSkipped) " + (Format-IndexList $res.HttpsSkippedIdx)
                        Write-Host $msg -ForegroundColor Yellow
                    }
                    if ($res.HttpsReplaced -gt 0) { Write-Host "$($L.ImportHttpsReplaced) $($res.HttpsReplaced)" -ForegroundColor Yellow }
                    if ($res.Proxied -gt 0) { Write-Host "$($L.ImportProxied) $($res.Proxied)" -ForegroundColor Yellow }
                    Write-Host ""
                    Write-Host $L.ImportModeAsk -ForegroundColor Yellow
                    $modeAns = Read-Host "$($L.YN)"
                    if (Test-Keyword $modeAns $L.BackKeywords) { continue importLoop }
                    if (Test-Keyword $modeAns $L.YesKeywords) { $addMode = $true }
                    elseif (Test-Keyword $modeAns $L.NoKeywords) { $addMode = $false }
                    else {
                        Write-Host $L.ImportBadMode -ForegroundColor Red
                        Start-Sleep -Milliseconds 1400
                        continue importLoop
                    }
                    if ($addMode) {
                        $curProxies = @($config.streams | Where-Object { $_.PSObject.Properties['port'] -and [int]$_.port -gt 0 }).Count
                        $newProxyCount = @($res.Streams | Where-Object { $_.PSObject.Properties['port'] -and [int]$_.port -gt 0 }).Count
                        if ($curProxies + $newProxyCount -gt 63) {
                            Write-Host ($L.TooManyProxies -f $curProxies, $newProxyCount) -ForegroundColor Red
                            Pause-Menu
                            continue importLoop
                        }
                    }
                    $merged = Merge-ImportStreams $config $res.Streams $addMode
                    $config.streams = $merged.Streams
                    if ($addMode) {
                        Write-Host "$($L.Imported) $($merged.AddedCount)" -ForegroundColor Green
                        if ($merged.DupInCfg -gt 0) { Write-Host "$($L.Skipped) $($merged.DupInCfg) (in config)" -ForegroundColor Yellow }
                    }
                    Save-Config $config
                    Sync-IndexFromSii $game $config | Out-Null
                    Save-Config $config
                    Pause-Menu
                    break importLoop
                }
                continue menuLoop
            }
            "export" {
                $exportCancelled = $false
                $sel = $null
                while ($true) {
                    Clear-Host
                    $ok = Screen-Export $game
                    if (-not $ok) { Pause-Menu; $exportCancelled = $true; break }
                    $sel = Read-Host $L.Choose
                    $sel = "$sel".Trim()
                    if (Test-Keyword $sel $L.BackKeywords) { $exportCancelled = $true; break }
                    if ($sel -eq "1" -or $sel -eq "2" -or $sel -eq "3") { break }
                    Write-Host $L.InvalidChoice -ForegroundColor Red
                    Start-Sleep -Milliseconds 1400
                }
                if ($exportCancelled) { continue menuLoop }
                $exportList = @(Build-ExportList $game $config $sel)
                if ($exportList.Count -eq 0) { Write-Host $L.Empty -ForegroundColor DarkGray; Pause-Menu; continue menuLoop }
                $default = Join-Path $ConfigDir "streams-export.json"
                Clear-Host
                Write-Host "=== $($L.ExportStreams) ===" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "$($L.ExportPathHint) $default" -ForegroundColor DarkGray
                $path = $null
                $writeOk = $false
                while (-not $writeOk) {
                    $path = Read-Host $L.ExportPath
                    $path = "$path".Trim()
                    if (Test-Keyword $path $L.BackKeywords) { break }
                    if (-not $path) { $path = $default }
                    if (-not (Test-Path $path)) { $writeOk = $true; break }
                    Write-Host ""
                    Write-Host "$($L.ExportFileExists) $path" -ForegroundColor Yellow
                    Write-Host $L.ExportOverwriteAsk -ForegroundColor Yellow
                    $ow = Read-Host "$($L.YN)"
                    if (Test-Keyword $ow $L.BackKeywords) { break }
                    if (Test-Keyword $ow $L.YesKeywords) { $writeOk = $true; break }
                    if (Test-Keyword $ow $L.NoKeywords) { Write-Host ""; continue }
                    Write-Host $L.InvalidChoice -ForegroundColor Red
                    Start-Sleep -Milliseconds 1400
                }
                if (-not $writeOk) { continue menuLoop }
                if (Write-ExportFile $path $config $exportList) {
                    Write-Host "$($L.Exported): $path ($($exportList.Count))" -ForegroundColor Green
                } else {
                    Write-Host ($L.ExportWriteFailed -f $path) -ForegroundColor Red
                }
                Pause-Menu
                continue menuLoop
            }
            "audit" { Screen-Audit $game; Pause-Menu; continue menuLoop }
            "games" { break menuLoop }
            "clear" {
                $needPause = Screen-Clear $game
                if ($needPause) { Pause-Menu }
                continue menuLoop
            }
            "exit" { break gameLoop }
            default { Write-Host $L.InvalidChoice -ForegroundColor Red; Start-Sleep -Milliseconds 1400 }
        }
    }
}
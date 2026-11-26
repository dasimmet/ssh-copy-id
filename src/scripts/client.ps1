if ($env:SCI_TRACE -eq '1') {
    Set-PSDebug -Trace 1
}

$ErrorActionPreference = 'Continue'

$prog = if ($env:SCI_PROG) { $env:SCI_PROG } else { 'ssh-copy-id' }
$remoteHost = $env:SCI_HOST
$targetPath = if ($env:SCI_TARGET_PATH) { $env:SCI_TARGET_PATH } else { '.ssh/authorized_keys' }
$force = ($env:SCI_FORCE -eq '1')
$dryRun = ($env:SCI_DRY_RUN -eq '1')
$sftpMode = ($env:SCI_SFTP -eq '1')
$idMode = if ($env:SCI_IDENTITY_MODE) { $env:SCI_IDENTITY_MODE } else { 'none' }
$idFile = $env:SCI_IDENTITY_FILE
$port = $env:SCI_PORT
$config = $env:SCI_CONFIG
$optCount = 0
if ($env:SCI_OPT_COUNT) { [void][int]::TryParse($env:SCI_OPT_COUNT, [ref]$optCount) }
$tmpDir = $env:SCI_TMP_DIR

if (-not $remoteHost) {
    [Console]::Error.WriteLine("$prog`: ERROR: missing hostname")
    exit 1
}
if (-not $tmpDir) {
    [Console]::Error.WriteLine("$prog`: ERROR: SCI_TMP_DIR is required")
    exit 1
}

$isWin = ($env:OS -eq 'Windows_NT') -or ($PSVersionTable.Platform -eq 'Win32NT') -or (-not $PSVersionTable.ContainsKey('Platform'))
if ($isWin) {
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { $HOME }
} else {
    $homeDir = if ($env:HOME) { $env:HOME } else { $HOME }
}

function Expand-TildePath([string]$p) {
    if ($p -eq '~') { return $homeDir }
    if ($p.StartsWith('~/') -or $p.StartsWith('~\')) {
        return Join-Path $homeDir $p.Substring(2)
    }
    return $p
}

function Find-DefaultIdFile {
    $sshDir = Join-Path $homeDir '.ssh'
    if (-not (Test-Path -LiteralPath $sshDir -PathType Container)) { return $null }
    $cand = Get-ChildItem -LiteralPath $sshDir -Filter 'id*.pub' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*-cert.pub' } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($cand) { return $cand.FullName }
    return $null
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$allKeys = New-Object System.Collections.Generic.List[string]
$sourceLabel = ''
$singleDiskFile = $null

function Load-KeysFromFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        [Console]::Error.WriteLine("$prog`: ERROR: failed to open ID file '$path': No such file")
        exit 1
    }
    $script:sourceLabel = $path
    $lines = [System.IO.File]::ReadAllLines($path)
    foreach ($line in $lines) {
        $t = $line.TrimEnd("`r", "`n").Trim()
        if ($t.Length -eq 0 -or $t.StartsWith('#')) { continue }
        $script:allKeys.Add($line.TrimEnd("`r", "`n"))
    }
    if ($script:allKeys.Count -eq 0) {
        [Console]::Error.WriteLine("$prog`: ERROR: No identities found in $path")
        exit 1
    }
    if ($script:allKeys.Count -eq 1) {
        $script:singleDiskFile = $path
    }
}

if ($idMode -eq 'file') {
    $resolved = Expand-TildePath $idFile
    if (-not $resolved.EndsWith('.pub')) { $resolved += '.pub' }
    Load-KeysFromFile $resolved
} elseif ($idMode -eq 'default') {
    $defFile = Find-DefaultIdFile
    if (-not $defFile) {
        [Console]::Error.WriteLine("$prog`: ERROR: No identities found")
        exit 1
    }
    Load-KeysFromFile $defFile
} else {
    $agentLines = & ssh-add -L 2>$null
    if ($LASTEXITCODE -eq 0 -and $agentLines) {
        foreach ($line in $agentLines) {
            $s = "$line".TrimEnd("`r", "`n")
            $t = $s.Trim()
            if ($t.Length -eq 0 -or $t.StartsWith('#') -or $t -like '*The agent has no identities*') { continue }
            $allKeys.Add($s)
        }
        if ($allKeys.Count -gt 0) {
            $sourceLabel = 'ssh-add -L'
        }
    }
    if (-not $sourceLabel) {
        $defFile = Find-DefaultIdFile
        if (-not $defFile) {
            [Console]::Error.WriteLine("$prog`: ERROR: No identities found")
            exit 1
        }
        Load-KeysFromFile $defFile
    }
}

$sshOpts = New-Object System.Collections.Generic.List[string]
$sftpOpts = New-Object System.Collections.Generic.List[string]
$rawOpts = New-Object System.Collections.Generic.List[string]

if ($port) {
    $sshOpts.Add('-p'); $sshOpts.Add($port)
    $sftpOpts.Add('-P'); $sftpOpts.Add($port)
}
if ($config) {
    $sshOpts.Add('-F'); $sshOpts.Add($config)
    $sftpOpts.Add('-F'); $sftpOpts.Add($config)
}
for ($i = 0; $i -lt $optCount; $i++) {
    $val = [Environment]::GetEnvironmentVariable("SCI_OPT_$i")
    if ($null -ne $val) {
        $rawOpts.Add($val)
        $sshOpts.Add('-o'); $sshOpts.Add($val)
        $sftpOpts.Add('-o'); $sftpOpts.Add($val)
    }
}

function Quote-Win32Arg([string]$a) {
    if ($a.Length -eq 0) { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    for ($i = 0; $i -lt $a.Length; $i++) {
        $c = $a[$i]
        if ($c -eq '\') {
            $bs++
        } elseif ($c -eq '"') {
            [void]$sb.Append('\', $bs * 2 + 1)
            [void]$sb.Append('"')
            $bs = 0
        } else {
            if ($bs -gt 0) { [void]$sb.Append('\', $bs); $bs = 0 }
            [void]$sb.Append($c)
        }
    }
    if ($bs -gt 0) { [void]$sb.Append('\', $bs * 2) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-ToolWithStdin([string]$exe, [string[]]$argList, [string]$stdinText) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = ($null -ne $stdinText)
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($psi.PSObject.Properties['ArgumentList']) {
        foreach ($a in $argList) { [void]$psi.ArgumentList.Add($a) }
    } else {
        $quoted = @()
        foreach ($a in $argList) { $quoted += (Quote-Win32Arg $a) }
        $psi.Arguments = ($quoted -join ' ')
    }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    if ($null -ne $stdinText) {
        $bytes = $utf8NoBom.GetBytes($stdinText)
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $proc.StandardInput.BaseStream.Close()
    }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Stdout = $outTask.Result
        Stderr = $errTask.Result
    }
}

$newKeys = New-Object System.Collections.Generic.List[string]
[Console]::Error.WriteLine("$prog`: INFO: Source of key(s) to be installed: `"$sourceLabel`"")

if ($force) {
    foreach ($k in $allKeys) { $newKeys.Add($k) }
} else {
    [Console]::Error.WriteLine("$prog`: INFO: attempting to log in with the new key(s), to filter out any that are already installed")
    $idx = 0
    foreach ($k in $allKeys) {
        if ($singleDiskFile -and $idx -eq 0) {
            $probeFile = $singleDiskFile
        } else {
            $probeFile = Join-Path $tmpDir "check_$idx.pub"
            [System.IO.File]::WriteAllText($probeFile, ($k + "`n"), $utf8NoBom)
        }
        $idx++

        $probeArgs = New-Object System.Collections.Generic.List[string]
        foreach ($a in $sshOpts) { $probeArgs.Add($a) }
        $probeArgs.Add('-i'); $probeArgs.Add($probeFile)
        $probeArgs.Add('-o'); $probeArgs.Add('PreferredAuthentications=publickey')
        $probeArgs.Add('-o'); $probeArgs.Add('IdentitiesOnly=yes')
        $probeArgs.Add($remoteHost)
        $probeArgs.Add('exit')

        $res = Invoke-ToolWithStdin 'ssh' $probeArgs.ToArray() $null
        if ($res.ExitCode -eq 0) { continue }
        $combined = ($res.Stdout + "`n" + $res.Stderr)
        if ($combined -match '(?i)Permission denied|No more authentication methods|Authentication failed') {
            $newKeys.Add($k)
        } else {
            if ($res.Stderr) { [Console]::Error.Write($res.Stderr) }
            if ($res.Stdout) { [Console]::Error.Write($res.Stdout) }
            exit 1
        }
    }
}

if ($newKeys.Count -eq 0) {
    [Console]::Error.WriteLine("$prog`: INFO: All keys were skipped because they already exist on the remote system.")
    [Console]::Error.WriteLine("`t`t(If you think this is wrong, you may want to use the -f option)")
    exit 0
}

if ($dryRun) {
    [Console]::Error.WriteLine("$prog`: INFO: $($newKeys.Count) key(s) remain to be installed -- if you are prompted now it is to install the new keys")
    foreach ($k in $newKeys) {
        [Console]::Out.WriteLine($k)
    }
    exit 0
}

[Console]::Error.WriteLine("$prog`: INFO: $($newKeys.Count) key(s) remain to be installed -- if you are prompted now it is to install the new keys")

function Write-Summary {
    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine("Number of key(s) added: $($newKeys.Count)")
    [Console]::Out.WriteLine("")
    $cmdLine = 'Now try logging into the machine, with:   "ssh'
    if ($port) { $cmdLine += " -p '$port'" }
    if ($config) { $cmdLine += " -F '$config'" }
    foreach ($o in $rawOpts) { $cmdLine += " -o '$o'" }
    $cmdLine += " '$remoteHost'`""
    [Console]::Out.WriteLine($cmdLine)
    [Console]::Out.WriteLine("and check to make sure that only the key(s) you wanted were added.")
    [Console]::Out.WriteLine("")
}

if ($sftpMode) {
    $dlFile = (Join-Path $tmpDir 'remote_authorized_keys').Replace('\', '/')
    $ulFile = (Join-Path $tmpDir 'upload_authorized_keys').Replace('\', '/')
    $dlArgs = New-Object System.Collections.Generic.List[string]
    foreach ($a in $sftpOpts) { $dlArgs.Add($a) }
    $dlArgs.Add($remoteHost)

    $getRes = Invoke-ToolWithStdin 'sftp' $dlArgs.ToArray() ("-get `"$targetPath`" `"$dlFile`"`n")
    if ($getRes.ExitCode -ne 0) {
        if ($getRes.Stderr) { [Console]::Error.Write($getRes.Stderr) }
        exit $getRes.ExitCode
    }

    $existing = ''
    if (Test-Path -LiteralPath $dlFile) {
        $existing = [System.IO.File]::ReadAllText($dlFile, $utf8NoBom)
        if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) {
            $existing += "`n"
        }
    }

    $existingSet = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($existing.Length -gt 0) {
        foreach ($line in ($existing -split "`r?`n")) {
            if ($line.Length -gt 0) { [void]$existingSet.Add($line) }
        }
    }

    $toAdd = New-Object System.Collections.Generic.List[string]
    foreach ($k in $newKeys) {
        if ($force -or (-not $existingSet.Contains($k))) {
            $toAdd.Add($k)
            [void]$existingSet.Add($k)
        }
    }
    $finalContent = $existing
    if ($toAdd.Count -gt 0) {
        $finalContent += ($toAdd -join "`n") + "`n"
    }
    [System.IO.File]::WriteAllText($ulFile, $finalContent, $utf8NoBom)

    $normTarget = $targetPath.Replace('\', '/')
    $lastSlash = $normTarget.LastIndexOf('/')
    $batch = ""
    if ($lastSlash -gt 0) {
        $parentDir = $normTarget.Substring(0, $lastSlash)
        $batch += "-mkdir `"$parentDir`"`n"
        $batch += "-chmod 700 `"$parentDir`"`n"
    }
    $batch += "put `"$ulFile`" `"$normTarget`"`n"
    $batch += "-chmod 600 `"$normTarget`"`n"

    $putRes = Invoke-ToolWithStdin 'sftp' $dlArgs.ToArray() $batch
    if ($putRes.ExitCode -ne 0) {
        if ($putRes.Stderr) { [Console]::Error.Write($putRes.Stderr) }
        exit $putRes.ExitCode
    }

    Write-Summary
    exit 0
}

$posixCmd = 'exec sh -c '\''cd && umask 077 && IFS= read -r t && case "$t" in "~/"*) t="$HOME/${t#~/}";; "~") t="$HOME";; esac && d=$(dirname "$t") && mkdir -p "$d" && if [ -s "$t" ] && [ -n "$(tail -c 1 "$t")" ]; then echo >> "$t"; fi && cat >> "$t" && if command -v restorecon >/dev/null 2>&1; then restorecon -F "$d" "$t" >/dev/null 2>&1 || true; fi'\'''
$payload = $targetPath + "`n" + ($newKeys -join "`n") + "`n"

$runArgs = New-Object System.Collections.Generic.List[string]
foreach ($a in $sshOpts) { $runArgs.Add($a) }
$runArgs.Add($remoteHost)
$runArgs.Add($posixCmd)

$res = Invoke-ToolWithStdin 'ssh' $runArgs.ToArray() $payload
if ($res.ExitCode -eq 0) {
    Write-Summary
    exit 0
}

$errText = $res.Stdout + "`n" + $res.Stderr
if ($errText -match "(?i)'exec' is not recognized|'sh' is not recognized|The term 'exec' is not recognized|The term 'sh' is not recognized|CommandNotFoundException") {
    $escTarget = $targetPath.Replace("'", "''")
    $keyLiterals = @()
    foreach ($k in $newKeys) {
        $keyLiterals += ("'" + $k.Replace("'", "''") + "'")
    }
    $psRemote = @(
        "& {",
        "  `$ErrorActionPreference = 'Stop'",
        "  `$t = '$escTarget'",
        "  `$keys = @(" + ($keyLiterals -join ", ") + ")",
        "  `$h = if (`$env:USERPROFILE) { `$env:USERPROFILE } else { `$HOME }",
        "  if (`$t -eq '~') { `$t = `$h }",
        "  elseif (`$t -like '~/*' -or `$t -like '~\*') { `$t = Join-Path `$h `$t.Substring(2) }",
        "  elseif (-not [System.IO.Path]::IsPathRooted(`$t)) { `$t = Join-Path `$h `$t }",
        "  `$d = Split-Path -Parent `$t",
        "  if (`$d -and -not (Test-Path -LiteralPath `$d)) { New-Item -ItemType Directory -Force -Path `$d | Out-Null }",
        "  `$enc = New-Object System.Text.UTF8Encoding(`$false)",
        "  `$ex = ''",
        "  if (Test-Path -LiteralPath `$t) { `$ex = [System.IO.File]::ReadAllText(`$t, `$enc) }",
        "  if (`$ex.Length -gt 0 -and -not `$ex.EndsWith(`"`n`")) { `$ex += `"`n`" }",
        "  [System.IO.File]::WriteAllText(`$t, (`$ex + (`$keys -join `"`n`") + `"`n`"), `$enc)",
        "}"
    ) -join "`n"
    $psRemote += "`n"

    $winArgs = New-Object System.Collections.Generic.List[string]
    foreach ($a in $sshOpts) { $winArgs.Add($a) }
    $winArgs.Add($remoteHost)
    $winArgs.Add('powershell -NoProfile -NonInteractive -Command -')

    $winRes = Invoke-ToolWithStdin 'ssh' $winArgs.ToArray() $psRemote
    if ($winRes.ExitCode -eq 0) {
        Write-Summary
        exit 0
    }
    if ($winRes.Stderr) { [Console]::Error.Write($winRes.Stderr) }
    if ($winRes.Stdout) { [Console]::Error.Write($winRes.Stdout) }
    exit 1
}

if ($errText -match '(?i)unknown keyword') {
    $dsaSent = 0
    foreach ($k in $newKeys) {
        if ($k.StartsWith('ssh-dss ')) {
            $parts = $k.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
            if ($parts.Length -ge 2) {
                $nsArgs = New-Object System.Collections.Generic.List[string]
                foreach ($a in $sshOpts) { $nsArgs.Add($a) }
                $nsArgs.Add($remoteHost)
                $nsArgs.Add("set ssh pka-dsa key $($parts[1])")
                $nsRes = Invoke-ToolWithStdin 'ssh' $nsArgs.ToArray() $null
                if ($nsRes.ExitCode -ne 0) {
                    if ($nsRes.Stderr) { [Console]::Error.Write($nsRes.Stderr) }
                    exit 1
                }
                $dsaSent++
            }
        }
    }
    if ($dsaSent -gt 0) {
        $saveArgs = New-Object System.Collections.Generic.List[string]
        foreach ($a in $sshOpts) { $saveArgs.Add($a) }
        $saveArgs.Add($remoteHost)
        $saveArgs.Add('save')
        [void](Invoke-ToolWithStdin 'ssh' $saveArgs.ToArray() $null)
        Write-Summary
        exit 0
    }
}

if ($res.Stderr) { [Console]::Error.Write($res.Stderr) }
if ($res.Stdout) { [Console]::Error.Write($res.Stdout) }
exit 1

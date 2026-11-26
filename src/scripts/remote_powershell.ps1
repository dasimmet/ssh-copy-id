$ErrorActionPreference = 'Stop'
$h = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
if ($t -eq '~') { $t = $h }
elseif ($t -like '~/*' -or $t -like '~\*') { $t = Join-Path $h $t.Substring(2) }
elseif (-not [System.IO.Path]::IsPathRooted($t)) { $t = Join-Path $h $t }
$d = Split-Path -Parent $t
if ($d -and -not (Test-Path -LiteralPath $d)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
$enc = New-Object System.Text.UTF8Encoding($false)
$ex = ''
if (Test-Path -LiteralPath $t) {
    $ex = [System.IO.File]::ReadAllText($t, $enc)
}
if ($ex.Length -gt 0 -and -not $ex.EndsWith("`n")) {
    $ex += "`n"
}
[System.IO.File]::WriteAllText($t, ($ex + ($keys -join "`n") + "`n"), $enc)

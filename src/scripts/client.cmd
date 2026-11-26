@echo off
setlocal DisableDelayedExpansion

if "%SCI_TRACE%"=="1" echo on

set "PROG=%SCI_PROG%"
if "%PROG%"=="" set "PROG=ssh-copy-id"
set "HOST=%SCI_HOST%"
set "TARGET_PATH=%SCI_TARGET_PATH%"
if "%TARGET_PATH%"=="" set "TARGET_PATH=.ssh/authorized_keys"
set "FORCE=%SCI_FORCE%"
if "%FORCE%"=="" set "FORCE=0"
set "DRY_RUN=%SCI_DRY_RUN%"
if "%DRY_RUN%"=="" set "DRY_RUN=0"
set "SFTP_MODE=%SCI_SFTP%"
if "%SFTP_MODE%"=="" set "SFTP_MODE=0"
set "ID_MODE=%SCI_IDENTITY_MODE%"
if "%ID_MODE%"=="" set "ID_MODE=none"
set "ID_FILE=%SCI_IDENTITY_FILE%"
set "PORT=%SCI_PORT%"
set "CONFIG=%SCI_CONFIG%"
set "OPT_COUNT=%SCI_OPT_COUNT%"
if "%OPT_COUNT%"=="" set "OPT_COUNT=0"
set "TMP_DIR=%SCI_TMP_DIR%"

if "%HOST%"=="" (
    >&2 echo %PROG%: ERROR: missing hostname
    exit /b 1
)
if "%TMP_DIR%"=="" (
    >&2 echo %PROG%: ERROR: SCI_TMP_DIR is required
    exit /b 1
)

if defined USERPROFILE (
    set "HOME_DIR=%USERPROFILE%"
) else (
    set "HOME_DIR=%HOME%"
)

set "ALL_KEYS_FILE=%TMP_DIR%\all_keys.pub"
type nul > "%ALL_KEYS_FILE%"
set "SOURCE_LABEL="
set "SINGLE_DISK_FILE="
set /a KEY_COUNT=0

if /i "%ID_MODE%"=="file" (
    call :expand_tilde "%ID_FILE%" RESOLVED_ID
    call :ensure_pub_ext "%RESOLVED_ID%" RESOLVED_PUB
    call :load_keys_file "%RESOLVED_PUB%"
    if errorlevel 1 exit /b 1
) else if /i "%ID_MODE%"=="default" (
    call :find_default_id DEF_FILE
    if errorlevel 1 (
        >&2 echo %PROG%: ERROR: No identities found
        exit /b 1
    )
    call :load_keys_file "%DEF_FILE%"
    if errorlevel 1 exit /b 1
) else (
    ssh-add -L > "%TMP_DIR%\agent_raw.pub" 2>nul
    if not errorlevel 1 (
        for %%A in ("%TMP_DIR%\agent_raw.pub") do if %%~zA gtr 0 (
            for /f "usebackq delims=" %%L in ("%TMP_DIR%\agent_raw.pub") do (
                call :append_key_line "%%L"
            )
        )
    )
    if %KEY_COUNT% gtr 0 (
        set "SOURCE_LABEL=ssh-add -L"
    ) else (
        call :find_default_id DEF_FILE
        if errorlevel 1 (
            >&2 echo %PROG%: ERROR: No identities found
            exit /b 1
        )
        call :load_keys_file "%DEF_FILE%"
        if errorlevel 1 exit /b 1
    )
)

set "SSH_ARGS="
set "SFTP_ARGS="
if not "%PORT%"=="" (
    set "SSH_ARGS=%SSH_ARGS% -p "%PORT%""
    set "SFTP_ARGS=%SFTP_ARGS% -P "%PORT%""
)
if not "%CONFIG%"=="" (
    set "SSH_ARGS=%SSH_ARGS% -F "%CONFIG%""
    set "SFTP_ARGS=%SFTP_ARGS% -F "%CONFIG%""
)
if %OPT_COUNT% gtr 0 (
    setlocal EnableDelayedExpansion
    set /a MAX_IDX=%OPT_COUNT%-1
    for /l %%I in (0,1,!MAX_IDX!) do (
        set "OVAL=!SCI_OPT_%%I!"
        set "SSH_ARGS=!SSH_ARGS! -o "!OVAL!""
        set "SFTP_ARGS=!SFTP_ARGS! -o "!OVAL!""
    )
    for /f "delims=" %%S in ("!SSH_ARGS!") do (
        for /f "delims=" %%F in ("!SFTP_ARGS!") do (
            endlocal
            set "SSH_ARGS=%%S"
            set "SFTP_ARGS=%%F"
        )
    )
)

set "NEW_KEYS_FILE=%TMP_DIR%\new_keys.pub"
type nul > "%NEW_KEYS_FILE%"
set /a NEW_COUNT=0

>&2 echo %PROG%: INFO: Source of key(s) to be installed: "%SOURCE_LABEL%"

if "%FORCE%"=="1" (
    copy /y "%ALL_KEYS_FILE%" "%NEW_KEYS_FILE%" >nul
    set /a NEW_COUNT=%KEY_COUNT%
) else (
    >&2 echo %PROG%: INFO: attempting to log in with the new key^(s^), to filter out any that are already installed
    set /a PROBE_IDX=0
    for /f "usebackq delims=" %%K in ("%ALL_KEYS_FILE%") do (
        call :probe_one_key "%%K"
        if errorlevel 2 exit /b 1
    )
)

if %NEW_COUNT% equ 0 (
    >&2 echo %PROG%: INFO: All keys were skipped because they already exist on the remote system.
    >&2 echo 		^(If you think this is wrong, you may want to use the -f option^)
    exit /b 0
)

if "%DRY_RUN%"=="1" (
    >&2 echo %PROG%: INFO: %NEW_COUNT% key^(s^) remain to be installed -- if you are prompted now it is to install the new keys
    type "%NEW_KEYS_FILE%"
    exit /b 0
)

>&2 echo %PROG%: INFO: %NEW_COUNT% key^(s^) remain to be installed -- if you are prompted now it is to install the new keys

if "%SFTP_MODE%"=="1" goto :do_sftp

set "PAYLOAD_CRLF=%TMP_DIR%\payload_crlf.txt"
set "PAYLOAD_LF=%TMP_DIR%\payload_lf.txt"
(
    echo %TARGET_PATH%
    type "%NEW_KEYS_FILE%"
) > "%PAYLOAD_CRLF%"
call :to_lf "%PAYLOAD_CRLF%" "%PAYLOAD_LF%"

set "SSH_ERR=%TMP_DIR%\ssh_err.txt"
set POSIX_CMD=exec sh -c 'cd ^&^& umask 077 ^&^& IFS= read -r t ^&^& case "$t" in "~/"*) t="$HOME/${t#~/}";; "~") t="$HOME";; esac ^&^& d=$(dirname "$t") ^&^& mkdir -p "$d" ^&^& if [ -s "$t" ] ^&^& [ -n "$(tail -c 1 "$t")" ]; then echo ^>^> "$t"; fi ^&^& cat ^>^> "$t" ^&^& if command -v restorecon ^>/dev/null 2^>^&1; then restorecon -F "$d" "$t" ^>/dev/null 2^>^&1 ^|^| true; fi'

ssh %SSH_ARGS% "%HOST%" "%POSIX_CMD:"=\"%" < "%PAYLOAD_LF%" 2>"%SSH_ERR%"
if not errorlevel 1 (
    call :print_summary
    exit /b 0
)

findstr /i /c:"'exec' is not recognized" /c:"'sh' is not recognized" /c:"The term 'exec' is not recognized" /c:"The term 'sh' is not recognized" /c:"CommandNotFoundException" "%SSH_ERR%" >nul 2>&1
if not errorlevel 1 (
    set "WIN_PS_CRLF=%TMP_DIR%\win_install_crlf.ps1"
    set "WIN_PS=%TMP_DIR%\win_install.ps1"
    set "ESC_TARGET=%TARGET_PATH:'=''%"
    (
        echo ^& {
        echo   $ErrorActionPreference = 'Stop'
        echo   $t = '%ESC_TARGET%'
        echo   $keys = @(
        for /f "usebackq delims=" %%K in ("%NEW_KEYS_FILE%") do (
            echo     '%%K'
        )
        echo   ^)
        echo   $h = if ($env:USERPROFILE^) { $env:USERPROFILE } else { $HOME }
        echo   if ($t -eq '~'^) { $t = $h }
        echo   elseif ($t -like '~/*' -or $t -like '~\*'^) { $t = Join-Path $h $t.Substring(2^) }
        echo   elseif (-not [System.IO.Path]::IsPathRooted($t^)^) { $t = Join-Path $h $t }
        echo   $d = Split-Path -Parent $t
        echo   if ($d -and -not (Test-Path -LiteralPath $d^)^) { New-Item -ItemType Directory -Force -Path $d ^| Out-Null }
        echo   $enc = New-Object System.Text.UTF8Encoding($false^)
        echo   $ex = ''
        echo   if (Test-Path -LiteralPath $t^) { $ex = [System.IO.File]::ReadAllText($t, $enc^) }
        echo   if ($ex.Length -gt 0 -and -not $ex.EndsWith("`n"^)^) { $ex += "`n" }
        echo   [System.IO.File]::WriteAllText($t, ($ex + ($keys -join "`n"^) + "`n"^), $enc^)
        echo }
    ) > "%WIN_PS_CRLF%"
    call :to_lf "%WIN_PS_CRLF%" "%WIN_PS%"
    ssh %SSH_ARGS% "%HOST%" "powershell -NoProfile -NonInteractive -Command -" < "%WIN_PS%" 2>"%SSH_ERR%"
    if not errorlevel 1 (
        call :print_summary
        exit /b 0
    )
)

findstr /i /c:"unknown keyword" "%SSH_ERR%" >nul 2>&1
if not errorlevel 1 (
    set /a DSA_SENT=0
    for /f "usebackq tokens=1,2" %%A in ("%NEW_KEYS_FILE%") do (
        if "%%A"=="ssh-dss" (
            ssh %SSH_ARGS% "%HOST%" "set ssh pka-dsa key %%B" >nul 2>"%SSH_ERR%"
            if errorlevel 1 (
                >&2 type "%SSH_ERR%"
                exit /b 1
            )
            set /a DSA_SENT+=1
        )
    )
    if %DSA_SENT% gtr 0 (
        ssh %SSH_ARGS% "%HOST%" "save" >nul 2>"%SSH_ERR%"
        call :print_summary
        exit /b 0
    )
)

>&2 type "%SSH_ERR%"
exit /b 1

:do_sftp
set "DL_FILE=%TMP_DIR%\remote_authorized_keys"
set "UL_FILE=%TMP_DIR%\upload_authorized_keys"
set "DL_SFTP=%DL_FILE:\=/%"
set "UL_SFTP=%UL_FILE:\=/%"
set "SFTP_ERR=%TMP_DIR%\sftp_err.txt"
set "SFTP_GET_CRLF=%TMP_DIR%\sftp_get_crlf.txt"
set "SFTP_GET_LF=%TMP_DIR%\sftp_get_lf.txt"
(
    echo -get "%TARGET_PATH%" "%DL_SFTP%"
) > "%SFTP_GET_CRLF%"
call :to_lf "%SFTP_GET_CRLF%" "%SFTP_GET_LF%"

sftp %SFTP_ARGS% "%HOST%" < "%SFTP_GET_LF%" >nul 2>"%SFTP_ERR%"
if errorlevel 1 (
    >&2 type "%SFTP_ERR%"
    exit /b 1
)

type nul > "%UL_FILE%"
set "UL_CRLF=%TMP_DIR%\ul_crlf.txt"
type nul > "%UL_CRLF%"
if exist "%DL_FILE%" (
    for %%A in ("%DL_FILE%") do if %%~zA gtr 0 (
        copy /y "%DL_FILE%" "%UL_CRLF%" >nul
    )
)

for /f "usebackq delims=" %%K in ("%NEW_KEYS_FILE%") do (
    if "%FORCE%"=="1" (
        echo %%K>> "%UL_CRLF%"
    ) else (
        findstr /x /c:"%%K" "%UL_CRLF%" >nul 2>&1
        if errorlevel 1 echo %%K>> "%UL_CRLF%"
    )
)
call :to_lf "%UL_CRLF%" "%UL_FILE%"

set "NORM_TARGET=%TARGET_PATH:\=/%"
set "SFTP_PUT_CRLF=%TMP_DIR%\sftp_put_crlf.txt"
set "SFTP_PUT_LF=%TMP_DIR%\sftp_put_lf.txt"
call :dirname_slash "%NORM_TARGET%" PARENT_DIR
(
    if not "%PARENT_DIR%"=="" if not "%PARENT_DIR%"=="." if not "%PARENT_DIR%"=="/" (
        echo -mkdir "%PARENT_DIR%"
        echo -chmod 700 "%PARENT_DIR%"
    )
    echo put "%UL_SFTP%" "%NORM_TARGET%"
    echo -chmod 600 "%NORM_TARGET%"
) > "%SFTP_PUT_CRLF%"
call :to_lf "%SFTP_PUT_CRLF%" "%SFTP_PUT_LF%"

sftp %SFTP_ARGS% "%HOST%" < "%SFTP_PUT_LF%" >nul 2>"%SFTP_ERR%"
if errorlevel 1 (
    >&2 type "%SFTP_ERR%"
    exit /b 1
)

call :print_summary
exit /b 0

:dirname_slash
set "DN_IN=%~1"
set "DN_OUT="
:dn_loop
for /f "tokens=1* delims=/" %%A in ("%DN_IN%") do (
    if not "%%B"=="" (
        if defined DN_OUT (
            set "DN_OUT=%DN_OUT%/%%A"
        ) else (
            set "DN_OUT=%%A"
        )
        set "DN_IN=%%B"
        goto :dn_loop
    )
)
set "%~2=%DN_OUT%"
exit /b 0

:expand_tilde
set "IN_P=%~1"
if "%IN_P%"=="~" (
    set "%~2=%HOME_DIR%"
    exit /b 0
)
if "%IN_P:~0,2%"=="~/" (
    set "%~2=%HOME_DIR%\%IN_P:~2%"
    exit /b 0
)
if "%IN_P:~0,2%"=="~\" (
    set "%~2=%HOME_DIR%\%IN_P:~2%"
    exit /b 0
)
set "%~2=%IN_P%"
exit /b 0

:ensure_pub_ext
set "EP_IN=%~1"
if /i "%EP_IN:~-4%"==".pub" (
    set "%~2=%EP_IN%"
) else (
    set "%~2=%EP_IN%.pub"
)
exit /b 0

:find_default_id
set "FOUND_ID="
for /f "delims=" %%F in ('dir /b /o-d /a-d "%HOME_DIR%\.ssh\id*.pub" 2^>nul') do (
    echo %%F | findstr /i /v /e "-cert.pub" >nul
    if not errorlevel 1 if not defined FOUND_ID (
        set "FOUND_ID=%HOME_DIR%\.ssh\%%F"
    )
)
if not defined FOUND_ID exit /b 1
set "%~1=%FOUND_ID%"
exit /b 0

:load_keys_file
set "LF_PATH=%~1"
if not exist "%LF_PATH%" (
    >&2 echo %PROG%: ERROR: failed to open ID file '%LF_PATH%': No such file
    exit /b 1
)
set "SOURCE_LABEL=%LF_PATH%"
for /f "usebackq delims=" %%L in ("%LF_PATH%") do (
    call :append_key_line "%%L"
)
if %KEY_COUNT% equ 0 (
    >&2 echo %PROG%: ERROR: No identities found in %LF_PATH%
    exit /b 1
)
if %KEY_COUNT% equ 1 (
    set "SINGLE_DISK_FILE=%LF_PATH%"
)
exit /b 0

:append_key_line
set "KL=%~1"
if "%KL%"=="" exit /b 0
if "%KL:~0,1%"=="#" exit /b 0
echo %KL% | findstr /i /c:"The agent has no identities" >nul 2>&1
if not errorlevel 1 exit /b 0
echo %KL%>> "%ALL_KEYS_FILE%"
set /a KEY_COUNT+=1
exit /b 0

:probe_one_key
set "PK_VAL=%~1"
if defined SINGLE_DISK_FILE if %PROBE_IDX% equ 0 (
    set "PROBE_FILE=%SINGLE_DISK_FILE%"
) else (
    set "PROBE_FILE=%TMP_DIR%\check_%PROBE_IDX%.pub"
    echo %PK_VAL%> "%TMP_DIR%\check_%PROBE_IDX%.pub"
)
set /a PROBE_IDX+=1

set "PROBE_OUT=%TMP_DIR%\probe_out.txt"
ssh %SSH_ARGS% -i "%PROBE_FILE%" -o PreferredAuthentications=publickey -o IdentitiesOnly=yes "%HOST%" exit >"%PROBE_OUT%" 2>&1
if not errorlevel 1 exit /b 0

findstr /i /c:"Permission denied" /c:"No more authentication methods" /c:"Authentication failed" "%PROBE_OUT%" >nul 2>&1
if not errorlevel 1 (
    echo %PK_VAL%>> "%NEW_KEYS_FILE%"
    set /a NEW_COUNT+=1
    exit /b 0
)
>&2 type "%PROBE_OUT%"
exit /b 2

:to_lf
where powershell >nul 2>&1
if not errorlevel 1 (
    powershell -NoProfile -NonInteractive -Command "$c=[IO.File]::ReadAllText('%~1'); [IO.File]::WriteAllText('%~2', $c.Replace(\"`r`n\", \"`n\"), (New-Object System.Text.UTF8Encoding($false)))"
    exit /b 0
)
copy /y "%~1" "%~2" >nul
exit /b 0

:print_summary
echo.
echo Number of key^(s^) added: %NEW_COUNT%
echo.
set "DISP=Now try logging into the machine, with:   "ssh"
if not "%PORT%"=="" set "DISP=%DISP% -p '%PORT%'"
if not "%CONFIG%"=="" set "DISP=%DISP% -F '%CONFIG%'"
if %OPT_COUNT% gtr 0 (
    setlocal EnableDelayedExpansion
    set /a MAX_S=%OPT_COUNT%-1
    for /l %%I in (0,1,!MAX_S!) do (
        set "DISP=!DISP! -o '!SCI_OPT_%%I!'"
    )
    for /f "delims=" %%D in ("!DISP!") do (
        endlocal
        set "DISP=%%D"
    )
)
echo %DISP% '%HOST%'"
echo and check to make sure that only the key^(s^) you wanted were added.
echo.
exit /b 0

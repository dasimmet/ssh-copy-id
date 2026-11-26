if test "$SCI_TRACE" = "1"
    set -g fish_trace 1
end

set -l PROG (test -n "$SCI_PROG"; and echo "$SCI_PROG"; or echo "ssh-copy-id")
set -l HOST "$SCI_HOST"
set -l TARGET_PATH (test -n "$SCI_TARGET_PATH"; and echo "$SCI_TARGET_PATH"; or echo ".ssh/authorized_keys")
set -l FORCE (test -n "$SCI_FORCE"; and echo "$SCI_FORCE"; or echo "0")
set -l DRY_RUN (test -n "$SCI_DRY_RUN"; and echo "$SCI_DRY_RUN"; or echo "0")
set -l SFTP_MODE (test -n "$SCI_SFTP"; and echo "$SCI_SFTP"; or echo "0")
set -l ID_MODE (test -n "$SCI_IDENTITY_MODE"; and echo "$SCI_IDENTITY_MODE"; or echo "none")
set -l ID_FILE "$SCI_IDENTITY_FILE"
set -l PORT "$SCI_PORT"
set -l CONFIG "$SCI_CONFIG"
set -l OPT_COUNT (test -n "$SCI_OPT_COUNT"; and echo "$SCI_OPT_COUNT"; or echo "0")
set -l TMP_DIR "$SCI_TMP_DIR"

if test -z "$HOST"
    echo "$PROG: ERROR: missing hostname" >&2
    exit 1
end

if test -z "$TMP_DIR"
    echo "$PROG: ERROR: SCI_TMP_DIR is required" >&2
    exit 1
end

set -l HOME_DIR "$HOME"
if test -z "$HOME_DIR"
    set HOME_DIR (cd; and pwd)
end

function _sci_expand_tilde --argument-names p home_dir
    if test "$p" = "~"
        echo "$home_dir"
    else if string match -q "~/*" -- "$p"
        echo "$home_dir/"(string sub -s 3 -- "$p")
    else if string match -q "~\\*" -- "$p"
        echo "$home_dir/"(string sub -s 3 -- "$p")
    else
        echo "$p"
    end
end

function _sci_find_default_id --argument-names home_dir
    for f in (ls -t "$home_dir"/.ssh/id*.pub 2>/dev/null)
        test -f "$f"; or continue
        if string match -q "*-cert.pub" -- "$f"
            continue
        end
        echo "$f"
        return 0
    end
    return 1
end

set -l ALL_KEYS
set -l SOURCE_LABEL ""
set -l SINGLE_DISK_FILE ""

function _sci_load_keys --no-scope-shadowing --argument-names src_file
    if not test -f "$src_file"; or not test -r "$src_file"
        echo "$PROG: ERROR: failed to open ID file '$src_file': No such file" >&2
        exit 1
    end
    set SOURCE_LABEL "$src_file"
    while read -l line
        set line (string replace -a \r "" -- "$line")
        set -l trimmed (string trim -- "$line")
        if test -z "$trimmed"; or string match -q "#*" -- "$trimmed"
            continue
        end
        set -a ALL_KEYS "$line"
    end < "$src_file"
    if test (count $ALL_KEYS) -eq 0
        echo "$PROG: ERROR: No identities found in $src_file" >&2
        exit 1
    end
    if test (count $ALL_KEYS) -eq 1
        set SINGLE_DISK_FILE "$src_file"
    end
end

if test "$ID_MODE" = "file"
    set -l resolved (_sci_expand_tilde "$ID_FILE" "$HOME_DIR")
    if not string match -q "*.pub" -- "$resolved"
        set resolved "$resolved.pub"
    end
    _sci_load_keys "$resolved"
else if test "$ID_MODE" = "default"
    set -l def_file (_sci_find_default_id "$HOME_DIR")
    if test $status -ne 0; or test -z "$def_file"
        echo "$PROG: ERROR: No identities found" >&2
        exit 1
    end
    _sci_load_keys "$def_file"
else
    set -l agent_lines (ssh-add -L 2>/dev/null)
    if test $status -eq 0
        for line in $agent_lines
            set line (string replace -a \r "" -- "$line")
            set -l trimmed (string trim -- "$line")
            if test -z "$trimmed"; or string match -q "#*" -- "$trimmed"; or string match -q "*The agent has no identities*" -- "$trimmed"
                continue
            end
            set -a ALL_KEYS "$line"
        end
        if test (count $ALL_KEYS) -gt 0
            set SOURCE_LABEL "ssh-add -L"
        end
    end
    if test -z "$SOURCE_LABEL"
        set -l def_file (_sci_find_default_id "$HOME_DIR")
        if test $status -ne 0; or test -z "$def_file"
            echo "$PROG: ERROR: No identities found" >&2
            exit 1
        end
        _sci_load_keys "$def_file"
    end
end

set -l ssh_args
set -l sftp_args
if test -n "$PORT"
    set -a ssh_args -p "$PORT"
    set -a sftp_args -P "$PORT"
end
if test -n "$CONFIG"
    set -a ssh_args -F "$CONFIG"
    set -a sftp_args -F "$CONFIG"
end
if test "$OPT_COUNT" -gt 0
    for idx in (seq 0 (math "$OPT_COUNT - 1"))
        set -l vname "SCI_OPT_$idx"
        set -l opt_val $$vname
        set -a ssh_args -o "$opt_val"
        set -a sftp_args -o "$opt_val"
    end
end

set -l NEW_KEYS
echo "$PROG: INFO: Source of key(s) to be installed: \"$SOURCE_LABEL\"" >&2

if test "$FORCE" = "1"
    set NEW_KEYS $ALL_KEYS
else
    echo "$PROG: INFO: attempting to log in with the new key(s), to filter out any that are already installed" >&2
    set -l idx 0
    for key in $ALL_KEYS
        set -l probe_file ""
        if test -n "$SINGLE_DISK_FILE"; and test "$idx" -eq 0
            set probe_file "$SINGLE_DISK_FILE"
        else
            set probe_file "$TMP_DIR/check_$idx.pub"
            printf '%s\n' "$key" > "$probe_file"
        end
        set idx (math "$idx + 1")

        set -l probe_err (ssh $ssh_args -i "$probe_file" -o PreferredAuthentications=publickey -o IdentitiesOnly=yes "$HOST" exit 2>&1 | string collect)
        set -l rc $status
        if test "$rc" -eq 0
            continue
        end
        if string match -q -i -r 'Permission denied|No more authentication methods|Authentication failed' -- "$probe_err"
            set -a NEW_KEYS "$key"
        else
            printf '%s\n' "$probe_err" >&2
            exit 1
        end
    end
end

set -l NEW_COUNT (count $NEW_KEYS)
if test "$NEW_COUNT" -eq 0
    echo "$PROG: INFO: All keys were skipped because they already exist on the remote system." >&2
    printf '\t\t(If you think this is wrong, you may want to use the -f option)\n' >&2
    exit 0
end

if test "$DRY_RUN" = "1"
    echo "$PROG: INFO: $NEW_COUNT key(s) remain to be installed -- if you are prompted now it is to install the new keys" >&2
    for k in $NEW_KEYS
        printf '%s\n' "$k"
    end
    exit 0
end

echo "$PROG: INFO: $NEW_COUNT key(s) remain to be installed -- if you are prompted now it is to install the new keys" >&2

function _sci_print_summary --no-scope-shadowing
    printf '\nNumber of key(s) added: %s\n\n' "$NEW_COUNT"
    printf 'Now try logging into the machine, with:   "ssh'
    if test -n "$PORT"
        printf " -p '%s'" "$PORT"
    end
    if test -n "$CONFIG"
        printf " -F '%s'" "$CONFIG"
    end
    if test "$OPT_COUNT" -gt 0
        for idx in (seq 0 (math "$OPT_COUNT - 1"))
            set -l vname "SCI_OPT_$idx"
            printf " -o '%s'" "$$vname"
        end
    end
    printf " '%s'\"\n" "$HOST"
    printf 'and check to make sure that only the key(s) you wanted were added.\n\n'
end

if test "$SFTP_MODE" = "1"
    set -l DL_FILE "$TMP_DIR/remote_authorized_keys"
    set -l UL_FILE "$TMP_DIR/upload_authorized_keys"

    printf -- '-get "%s" "%s"\n' "$TARGET_PATH" "$DL_FILE" | sftp $sftp_args "$HOST" >/dev/null 2>"$TMP_DIR/sftp_err"
    set -l rc $status
    if test "$rc" -ne 0
        cat "$TMP_DIR/sftp_err" >&2
        exit "$rc"
    end

    printf '' > "$UL_FILE"
    if test -f "$DL_FILE"; and test -s "$DL_FILE"
        cat "$DL_FILE" > "$UL_FILE"
        if test -n (tail -c 1 "$UL_FILE" | string collect)
            printf '\n' >> "$UL_FILE"
        end
    end

    for k in $NEW_KEYS
        if test "$FORCE" = "1"; or not grep -Fxq "$k" "$UL_FILE" 2>/dev/null
            printf '%s\n' "$k" >> "$UL_FILE"
        end
    end

    set -l parent_dir (dirname "$TARGET_PATH")
    begin
        if test "$parent_dir" != "."; and test "$parent_dir" != "/"
            printf -- '-mkdir "%s"\n' "$parent_dir"
            printf -- '-chmod 700 "%s"\n' "$parent_dir"
        end
        printf 'put "%s" "%s"\n' "$UL_FILE" "$TARGET_PATH"
        printf -- '-chmod 600 "%s"\n' "$TARGET_PATH"
    end | sftp $sftp_args "$HOST" >/dev/null 2>"$TMP_DIR/sftp_err"
    set rc $status
    if test "$rc" -ne 0
        cat "$TMP_DIR/sftp_err" >&2
        exit "$rc"
    end

    _sci_print_summary
    exit 0
end

set -l PAYLOAD "$TMP_DIR/posix_payload"
begin
    printf '%s\n' "$TARGET_PATH"
    for k in $NEW_KEYS
        printf '%s\n' "$k"
    end
end > "$PAYLOAD"

set -l REMOTE_SH_CMD 'exec sh -c '\''cd && umask 077 && IFS= read -r t && case "$t" in "~/"*) t="$HOME/${t#~/}";; "~") t="$HOME";; esac && d=$(dirname "$t") && mkdir -p "$d" && if [ -s "$t" ] && [ -n "$(tail -c 1 "$t")" ]; then echo >> "$t"; fi && cat >> "$t" && if command -v restorecon >/dev/null 2>&1; then restorecon -F "$d" "$t" >/dev/null 2>&1 || true; fi'\'''

set -l SSH_ERR "$TMP_DIR/ssh_err"
ssh $ssh_args "$HOST" "$REMOTE_SH_CMD" < "$PAYLOAD" 2>"$SSH_ERR"
set -l rc $status
if test "$rc" -eq 0
    _sci_print_summary
    exit 0
end

set -l err_text (cat "$SSH_ERR" | string collect)
if string match -q -i -r "'exec' is not recognized|'sh' is not recognized|The term 'exec' is not recognized|The term 'sh' is not recognized|CommandNotFoundException" -- "$err_text"
    set -l WIN_PS "$TMP_DIR/win_install.ps1"
    set -l esc_target (string replace -a "'" "''" -- "$TARGET_PATH")
    begin
        echo "& {"
        echo "  \$ErrorActionPreference = 'Stop'"
        echo "  \$t = '$esc_target'"
        echo "  \$keys = @("
        set -l first 1
        for k in $NEW_KEYS
            set -l ek (string replace -a "'" "''" -- "$k")
            if test "$first" -eq 1
                echo "    '$ek'"
                set first 0
            else
                echo "    ,'$ek'"
            end
        end
        echo "  )"
        echo '  $h = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }'
        echo '  if ($t -eq '\''~'\'') { $t = $h }'
        echo '  elseif ($t -like '\''~/*'\'' -or $t -like '\''~\*'\'') { $t = Join-Path $h $t.Substring(2) }'
        echo '  elseif (-not [System.IO.Path]::IsPathRooted($t)) { $t = Join-Path $h $t }'
        echo '  $d = Split-Path -Parent $t'
        echo '  if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }'
        echo '  $enc = New-Object System.Text.UTF8Encoding($false)'
        echo '  $ex = '\'''\'''
        echo '  if (Test-Path -LiteralPath $t) { $ex = [System.IO.File]::ReadAllText($t, $enc) }'
        echo '  if ($ex.Length -gt 0 -and -not $ex.EndsWith("`n")) { $ex += "`n" }'
        echo '  [System.IO.File]::WriteAllText($t, ($ex + ($keys -join "`n") + "`n"), $enc)'
        echo "}"
    end > "$WIN_PS"

    ssh $ssh_args "$HOST" "powershell -NoProfile -NonInteractive -Command -" < "$WIN_PS" 2>"$SSH_ERR"
    set rc $status
    if test "$rc" -eq 0
        _sci_print_summary
        exit 0
    fi
end

if string match -q -i "*unknown keyword*" -- "$err_text"
    set -l dsa_sent 0
    for k in $NEW_KEYS
        if string match -q "ssh-dss *" -- "$k"
            set -l parts (string split -n " " -- "$k")
            set -l blob "$parts[2]"
            ssh $ssh_args "$HOST" "set ssh pka-dsa key $blob" >/dev/null 2>"$SSH_ERR"
            if test $status -ne 0
                cat "$SSH_ERR" >&2
                exit 1
            end
            set dsa_sent (math "$dsa_sent + 1")
        end
    end
    if test "$dsa_sent" -gt 0
        ssh $ssh_args "$HOST" "save" >/dev/null 2>"$SSH_ERR"
        _sci_print_summary
        exit 0
    end
end

cat "$SSH_ERR" >&2
exit 1

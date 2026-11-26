#!/bin/sh
set -u

if [ "${SCI_TRACE:-0}" = "1" ]; then
    set -x
fi

PROG="${SCI_PROG:-ssh-copy-id}"
HOST="${SCI_HOST:-}"
TARGET_PATH="${SCI_TARGET_PATH:-.ssh/authorized_keys}"
FORCE="${SCI_FORCE:-0}"
DRY_RUN="${SCI_DRY_RUN:-0}"
SFTP_MODE="${SCI_SFTP:-0}"
ID_MODE="${SCI_IDENTITY_MODE:-none}"
ID_FILE="${SCI_IDENTITY_FILE:-}"
PORT="${SCI_PORT:-}"
CONFIG="${SCI_CONFIG:-}"
OPT_COUNT="${SCI_OPT_COUNT:-0}"
TMP_DIR="${SCI_TMP_DIR:?SCI_TMP_DIR is required}"

if [ -z "$HOST" ]; then
    printf '%s: ERROR: missing hostname\n' "$PROG" >&2
    exit 1
fi

HOME_DIR="${HOME:-}"
if [ -z "$HOME_DIR" ]; then
    HOME_DIR=$(cd && pwd)
fi

expand_tilde() {
    case "$1" in
        "~") printf '%s\n' "$HOME_DIR" ;;
        "~/"*) printf '%s/%s\n' "$HOME_DIR" "${1#~/}" ;;
        "~\\"*) printf '%s/%s\n' "$HOME_DIR" "${1#~\}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

find_default_id_file() {
    best=""
    for f in $(ls -t "$HOME_DIR"/.ssh/id*.pub 2>/dev/null); do
        [ -f "$f" ] || continue
        case "$f" in
            *-cert.pub) continue ;;
        esac
        best="$f"
        break
    done
    if [ -z "$best" ]; then
        return 1
    fi
    printf '%s\n' "$best"
}

ALL_KEYS_FILE="$TMP_DIR/all_keys.pub"
: > "$ALL_KEYS_FILE"
SOURCE_LABEL=""
SINGLE_DISK_FILE=""

load_keys_from_file() {
    src_file="$1"
    if [ ! -f "$src_file" ] || [ ! -r "$src_file" ]; then
        printf '%s: ERROR: failed to open ID file '\''%s'\'': No such file\n' "$PROG" "$src_file" >&2
        exit 1
    fi
    SOURCE_LABEL="$src_file"
    count=0
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | tr -d '\r')
        case "$line" in
            ""|\#*) continue ;;
        esac
        printf '%s\n' "$line" >> "$ALL_KEYS_FILE"
        count=$((count + 1))
    done < "$src_file"
    if [ "$count" -eq 0 ]; then
        printf '%s: ERROR: No identities found in %s\n' "$PROG" "$src_file" >&2
        exit 1
    fi
    if [ "$count" -eq 1 ]; then
        SINGLE_DISK_FILE="$src_file"
    fi
}

if [ "$ID_MODE" = "file" ]; then
    resolved=$(expand_tilde "$ID_FILE")
    case "$resolved" in
        *.pub) ;;
        *) resolved="${resolved}.pub" ;;
    esac
    load_keys_from_file "$resolved"
elif [ "$ID_MODE" = "default" ]; then
    def_file=$(find_default_id_file) || {
        printf '%s: ERROR: No identities found\n' "$PROG" >&2
        exit 1
    }
    load_keys_from_file "$def_file"
else
    AGENT_OUT="$TMP_DIR/agent_keys.pub"
    if ssh-add -L > "$AGENT_OUT" 2>/dev/null && [ -s "$AGENT_OUT" ]; then
        count=0
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(printf '%s' "$line" | tr -d '\r')
            case "$line" in
                ""|\#*|*"The agent has no identities"*) continue ;;
            esac
            printf '%s\n' "$line" >> "$ALL_KEYS_FILE"
            count=$((count + 1))
        done < "$AGENT_OUT"
        if [ "$count" -gt 0 ]; then
            SOURCE_LABEL="ssh-add -L"
        fi
    fi
    if [ -z "$SOURCE_LABEL" ]; then
        def_file=$(find_default_id_file) || {
            printf '%s: ERROR: No identities found\n' "$PROG" >&2
            exit 1
        }
        load_keys_from_file "$def_file"
    fi
fi

set --
if [ -n "$PORT" ]; then
    set -- "$@" -p "$PORT"
fi
if [ -n "$CONFIG" ]; then
    set -- "$@" -F "$CONFIG"
fi
opt_idx=0
while [ "$opt_idx" -lt "$OPT_COUNT" ]; do
    eval 'opt_val=$SCI_OPT_'"$opt_idx"
    set -- "$@" -o "$opt_val"
    opt_idx=$((opt_idx + 1))
done

NEW_KEYS_FILE="$TMP_DIR/new_keys.pub"
: > "$NEW_KEYS_FILE"
NEW_COUNT=0

printf '%s: INFO: Source of key(s) to be installed: "%s"\n' "$PROG" "$SOURCE_LABEL" >&2

if [ "$FORCE" = "1" ]; then
    cp "$ALL_KEYS_FILE" "$NEW_KEYS_FILE"
    NEW_COUNT=$(wc -l < "$NEW_KEYS_FILE" | tr -d ' ')
else
    printf '%s: INFO: attempting to log in with the new key(s), to filter out any that are already installed\n' "$PROG" >&2

    idx=0
    while IFS= read -r key || [ -n "$key" ]; do
        [ -n "$key" ] || continue
        if [ -n "$SINGLE_DISK_FILE" ] && [ "$idx" -eq 0 ]; then
            probe_file="$SINGLE_DISK_FILE"
        else
            probe_file="$TMP_DIR/check_${idx}.pub"
            printf '%s\n' "$key" > "$probe_file"
        fi
        idx=$((idx + 1))

        probe_err=$(ssh "$@" -i "$probe_file" -o PreferredAuthentications=publickey -o IdentitiesOnly=yes "$HOST" exit 2>&1)
        rc=$?
        if [ "$rc" -eq 0 ]; then
            continue
        fi
        if printf '%s\n' "$probe_err" | grep -qiE 'Permission denied|No more authentication methods|Authentication failed'; then
            printf '%s\n' "$key" >> "$NEW_KEYS_FILE"
            NEW_COUNT=$((NEW_COUNT + 1))
        else
            printf '%s\n' "$probe_err" >&2
            exit 1
        fi
    done < "$ALL_KEYS_FILE"
fi

if [ "$NEW_COUNT" -eq 0 ]; then
    printf '%s: INFO: All keys were skipped because they already exist on the remote system.\n' "$PROG" >&2
    printf '\t\t(If you think this is wrong, you may want to use the -f option)\n' >&2
    exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
    printf '%s: INFO: %s key(s) remain to be installed -- if you are prompted now it is to install the new keys\n' "$PROG" "$NEW_COUNT" >&2
    cat "$NEW_KEYS_FILE"
    exit 0
fi

printf '%s: INFO: %s key(s) remain to be installed -- if you are prompted now it is to install the new keys\n' "$PROG" "$NEW_COUNT" >&2

print_summary() {
    printf '\nNumber of key(s) added: %s\n\n' "$NEW_COUNT"
    printf 'Now try logging into the machine, with:   "ssh'
    if [ -n "$PORT" ]; then
        printf ' -p '\''%s'\''' "$PORT"
    fi
    if [ -n "$CONFIG" ]; then
        printf ' -F '\''%s'\''' "$CONFIG"
    fi
    s_idx=0
    while [ "$s_idx" -lt "$OPT_COUNT" ]; do
        eval 's_opt=$SCI_OPT_'"$s_idx"
        printf ' -o '\''%s'\''' "$s_opt"
        s_idx=$((s_idx + 1))
    done
    printf ' '\''%s'\''"\n' "$HOST"
    printf 'and check to make sure that only the key(s) you wanted were added.\n\n'
}

if [ "$SFTP_MODE" = "1" ]; then
    set --
    if [ -n "$PORT" ]; then
        set -- "$@" -P "$PORT"
    fi
    if [ -n "$CONFIG" ]; then
        set -- "$@" -F "$CONFIG"
    fi
    opt_idx=0
    while [ "$opt_idx" -lt "$OPT_COUNT" ]; do
        eval 'opt_val=$SCI_OPT_'"$opt_idx"
        set -- "$@" -o "$opt_val"
        opt_idx=$((opt_idx + 1))
    done

    DL_FILE="$TMP_DIR/remote_authorized_keys"
    UL_FILE="$TMP_DIR/upload_authorized_keys"

    sftp "$@" "$HOST" >/dev/null 2>"$TMP_DIR/sftp_err" <<EOF
-get "$TARGET_PATH" "$DL_FILE"
EOF
    rc=$?
    if [ "$rc" -ne 0 ]; then
        cat "$TMP_DIR/sftp_err" >&2
        exit "$rc"
    fi

    : > "$UL_FILE"
    if [ -f "$DL_FILE" ] && [ -s "$DL_FILE" ]; then
        cat "$DL_FILE" > "$UL_FILE"
        if [ -n "$(tail -c 1 "$UL_FILE")" ]; then
            printf '\n' >> "$UL_FILE"
        fi
    fi

    if [ "$FORCE" = "1" ]; then
        cat "$NEW_KEYS_FILE" >> "$UL_FILE"
    else
        while IFS= read -r k || [ -n "$k" ]; do
            [ -n "$k" ] || continue
            if ! grep -Fxq "$k" "$UL_FILE" 2>/dev/null; then
                printf '%s\n' "$k" >> "$UL_FILE"
            fi
        done < "$NEW_KEYS_FILE"
    fi

    parent_dir=$(dirname "$TARGET_PATH")
    {
        if [ "$parent_dir" != "." ] && [ "$parent_dir" != "/" ]; then
            printf -- '-mkdir "%s"\n' "$parent_dir"
            printf -- '-chmod 700 "%s"\n' "$parent_dir"
        fi
        printf 'put "%s" "%s"\n' "$UL_FILE" "$TARGET_PATH"
        printf -- '-chmod 600 "%s"\n' "$TARGET_PATH"
    } | sftp "$@" "$HOST" >/dev/null 2>"$TMP_DIR/sftp_err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        cat "$TMP_DIR/sftp_err" >&2
        exit "$rc"
    fi

    print_summary
    exit 0
fi

PAYLOAD="$TMP_DIR/posix_payload"
{
    printf '%s\n' "$TARGET_PATH"
    cat "$NEW_KEYS_FILE"
} > "$PAYLOAD"

REMOTE_SH_CMD='exec sh -c '\''cd && umask 077 && IFS= read -r t && case "$t" in "~/"*) t="$HOME/${t#~/}";; "~") t="$HOME";; esac && d=$(dirname "$t") && mkdir -p "$d" && if [ -s "$t" ] && [ -n "$(tail -c 1 "$t")" ]; then echo >> "$t"; fi && cat >> "$t" && if command -v restorecon >/dev/null 2>&1; then restorecon -F "$d" "$t" >/dev/null 2>&1 || true; fi'\'''

SSH_ERR="$TMP_DIR/ssh_err"
ssh "$@" "$HOST" "$REMOTE_SH_CMD" < "$PAYLOAD" 2>"$SSH_ERR"
rc=$?
if [ "$rc" -eq 0 ]; then
    print_summary
    exit 0
fi

if grep -qiE "'exec' is not recognized|'sh' is not recognized|The term 'exec' is not recognized|The term 'sh' is not recognized|CommandNotFoundException" "$SSH_ERR"; then
    WIN_PS="$TMP_DIR/win_install.ps1"
    esc_target=$(printf '%s' "$TARGET_PATH" | sed "s/'/''/g")
    {
        printf '& {\n'
        printf '  $ErrorActionPreference = '\''Stop'\''\n'
        printf '  $t = '\''%s'\''\n' "$esc_target"
        printf '  $keys = @(\n'
        first=1
        while IFS= read -r k || [ -n "$k" ]; do
            [ -n "$k" ] || continue
            ek=$(printf '%s' "$k" | sed "s/'/''/g")
            if [ "$first" -eq 1 ]; then
                printf '    '\''%s'\''\n' "$ek"
                first=0
            else
                printf '    ,'\''%s'\''\n' "$ek"
            fi
        done < "$NEW_KEYS_FILE"
        printf '  )\n'
        printf '  $h = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }\n'
        printf '  if ($t -eq '\''~'\'') { $t = $h }\n'
        printf '  elseif ($t -like '\''~/*'\'' -or $t -like '\''~\\*'\'') { $t = Join-Path $h $t.Substring(2) }\n'
        printf '  elseif (-not [System.IO.Path]::IsPathRooted($t)) { $t = Join-Path $h $t }\n'
        printf '  $d = Split-Path -Parent $t\n'
        printf '  if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }\n'
        printf '  $enc = New-Object System.Text.UTF8Encoding($false)\n'
        printf '  $ex = '\'''\''\n'
        printf '  if (Test-Path -LiteralPath $t) { $ex = [System.IO.File]::ReadAllText($t, $enc) }\n'
        printf '  if ($ex.Length -gt 0 -and -not $ex.EndsWith("`n")) { $ex += "`n" }\n'
        printf '  [System.IO.File]::WriteAllText($t, ($ex + ($keys -join "`n") + "`n"), $enc)\n'
        printf '}\n'
    } > "$WIN_PS"

    ssh "$@" "$HOST" "powershell -NoProfile -NonInteractive -Command -" < "$WIN_PS" 2>"$SSH_ERR"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        print_summary
        exit 0
    fi
fi

if grep -qi 'unknown keyword' "$SSH_ERR"; then
    dsa_sent=0
    while IFS= read -r k || [ -n "$k" ]; do
        [ -n "$k" ] || continue
        case "$k" in
            ssh-dss\ *)
                blob=$(printf '%s\n' "$k" | awk '{print $2}')
                ssh "$@" "$HOST" "set ssh pka-dsa key $blob" >/dev/null 2>"$SSH_ERR" || {
                    cat "$SSH_ERR" >&2
                    exit 1
                }
                dsa_sent=$((dsa_sent + 1))
                ;;
        esac
    done < "$NEW_KEYS_FILE"
    if [ "$dsa_sent" -gt 0 ]; then
        ssh "$@" "$HOST" "save" >/dev/null 2>"$SSH_ERR" || true
        print_summary
        exit 0
    fi
fi

cat "$SSH_ERR" >&2
exit 1

#!/usr/bin/env zsh
set -u

if [[ "${SCI_TRACE:-0}" == "1" ]]; then
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

if [[ -z "$HOST" ]]; then
    print -u2 -- "$PROG: ERROR: missing hostname"
    exit 1
fi

HOME_DIR="${HOME:-}"
if [[ -z "$HOME_DIR" ]]; then
    HOME_DIR=$(cd && pwd)
fi

expand_tilde() {
    case "$1" in
        "~") print -r -- "$HOME_DIR" ;;
        "~/"*) print -r -- "$HOME_DIR/${1#~/}" ;;
        "~\\"*) print -r -- "$HOME_DIR/${1#~\}" ;;
        *) print -r -- "$1" ;;
    esac
}

find_default_id_file() {
    local -a candidates
    candidates=("$HOME_DIR"/.ssh/id*.pub(N.om))
    local f
    for f in "${candidates[@]}"; do
        if [[ "$f" == *-cert.pub ]]; then
            continue
        fi
        print -r -- "$f"
        return 0
    done
    return 1
}

typeset -a ALL_KEYS
ALL_KEYS=()
SOURCE_LABEL=""
SINGLE_DISK_FILE=""

load_keys_from_file() {
    local src_file="$1"
    if [[ ! -f "$src_file" || ! -r "$src_file" ]]; then
        print -u2 -- "$PROG: ERROR: failed to open ID file '$src_file': No such file"
        exit 1
    fi
    SOURCE_LABEL="$src_file"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        ALL_KEYS+=("$line")
    done < "$src_file"
    if (( ${#ALL_KEYS} == 0 )); then
        print -u2 -- "$PROG: ERROR: No identities found in $src_file"
        exit 1
    fi
    if (( ${#ALL_KEYS} == 1 )); then
        SINGLE_DISK_FILE="$src_file"
    fi
}

if [[ "$ID_MODE" == "file" ]]; then
    resolved=$(expand_tilde "$ID_FILE")
    [[ "$resolved" == *.pub ]] || resolved="${resolved}.pub"
    load_keys_from_file "$resolved"
elif [[ "$ID_MODE" == "default" ]]; then
    def_file=$(find_default_id_file) || {
        print -u2 -- "$PROG: ERROR: No identities found"
        exit 1
    }
    load_keys_from_file "$def_file"
else
    agent_out=$(ssh-add -L 2>/dev/null)
    if (( $? == 0 )) && [[ -n "$agent_out" ]]; then
        local line
        for line in "${(@f)agent_out}"; do
            line="${line//$'\r'/}"
            [[ -z "$line" || "$line" == \#* || "$line" == *"The agent has no identities"* ]] && continue
            ALL_KEYS+=("$line")
        done
        if (( ${#ALL_KEYS} > 0 )); then
            SOURCE_LABEL="ssh-add -L"
        fi
    fi
    if [[ -z "$SOURCE_LABEL" ]]; then
        def_file=$(find_default_id_file) || {
            print -u2 -- "$PROG: ERROR: No identities found"
            exit 1
        }
        load_keys_from_file "$def_file"
    fi
fi

typeset -a ssh_args sftp_args
ssh_args=()
sftp_args=()
if [[ -n "$PORT" ]]; then
    ssh_args+=(-p "$PORT")
    sftp_args+=(-P "$PORT")
fi
if [[ -n "$CONFIG" ]]; then
    ssh_args+=(-F "$CONFIG")
    sftp_args+=(-F "$CONFIG")
fi
integer opt_idx=0
while (( opt_idx < OPT_COUNT )); do
    local varname="SCI_OPT_${opt_idx}"
    local opt_val="${(P)varname}"
    ssh_args+=(-o "$opt_val")
    sftp_args+=(-o "$opt_val")
    (( opt_idx++ ))
done

typeset -a NEW_KEYS
NEW_KEYS=()

print -u2 -- "$PROG: INFO: Source of key(s) to be installed: \"$SOURCE_LABEL\""

if [[ "$FORCE" == "1" ]]; then
    NEW_KEYS=("${ALL_KEYS[@]}")
else
    print -u2 -- "$PROG: INFO: attempting to log in with the new key(s), to filter out any that are already installed"
    integer idx=0
    local key probe_file probe_err rc
    for key in "${ALL_KEYS[@]}"; do
        if [[ -n "$SINGLE_DISK_FILE" ]] && (( idx == 0 )); then
            probe_file="$SINGLE_DISK_FILE"
        else
            probe_file="$TMP_DIR/check_${idx}.pub"
            print -r -- "$key" > "$probe_file"
        fi
        (( idx++ ))

        probe_err=$(ssh "${ssh_args[@]}" -i "$probe_file" -o PreferredAuthentications=publickey -o IdentitiesOnly=yes "$HOST" exit 2>&1)
        rc=$?
        if (( rc == 0 )); then
            continue
        fi
        if print -r -- "$probe_err" | grep -qiE 'Permission denied|No more authentication methods|Authentication failed'; then
            NEW_KEYS+=("$key")
        else
            print -u2 -r -- "$probe_err"
            exit 1
        fi
    done
fi

integer NEW_COUNT=${#NEW_KEYS}
if (( NEW_COUNT == 0 )); then
    print -u2 -- "$PROG: INFO: All keys were skipped because they already exist on the remote system."
    print -u2 -- $'\t\t(If you think this is wrong, you may want to use the -f option)'
    exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
    print -u2 -- "$PROG: INFO: $NEW_COUNT key(s) remain to be installed -- if you are prompted now it is to install the new keys"
    printf '%s\n' "${NEW_KEYS[@]}"
    exit 0
fi

print -u2 -- "$PROG: INFO: $NEW_COUNT key(s) remain to be installed -- if you are prompted now it is to install the new keys"

print_summary() {
    printf '\nNumber of key(s) added: %s\n\n' "$NEW_COUNT"
    printf 'Now try logging into the machine, with:   "ssh'
    if [[ -n "$PORT" ]]; then
        printf " -p '%s'" "$PORT"
    fi
    if [[ -n "$CONFIG" ]]; then
        printf " -F '%s'" "$CONFIG"
    fi
    integer s_idx=0
    while (( s_idx < OPT_COUNT )); do
        local vname="SCI_OPT_${s_idx}"
        printf " -o '%s'" "${(P)vname}"
        (( s_idx++ ))
    done
    printf " '%s'\"\n" "$HOST"
    printf 'and check to make sure that only the key(s) you wanted were added.\n\n'
}

if [[ "$SFTP_MODE" == "1" ]]; then
    DL_FILE="$TMP_DIR/remote_authorized_keys"
    UL_FILE="$TMP_DIR/upload_authorized_keys"

    sftp "${sftp_args[@]}" "$HOST" >/dev/null 2>"$TMP_DIR/sftp_err" <<EOF
-get "$TARGET_PATH" "$DL_FILE"
EOF
    rc=$?
    if (( rc != 0 )); then
        cat "$TMP_DIR/sftp_err" >&2
        exit "$rc"
    fi

    : > "$UL_FILE"
    if [[ -f "$DL_FILE" && -s "$DL_FILE" ]]; then
        cat "$DL_FILE" > "$UL_FILE"
        if [[ -n "$(tail -c 1 "$UL_FILE")" ]]; then
            printf '\n' >> "$UL_FILE"
        fi
    fi

    local k
    for k in "${NEW_KEYS[@]}"; do
        if [[ "$FORCE" == "1" ]] || ! grep -Fxq "$k" "$UL_FILE" 2>/dev/null; then
            print -r -- "$k" >> "$UL_FILE"
        fi
    done

    parent_dir="${TARGET_PATH:h}"
    {
        if [[ "$parent_dir" != "." && "$parent_dir" != "/" ]]; then
            printf -- '-mkdir "%s"\n' "$parent_dir"
            printf -- '-chmod 700 "%s"\n' "$parent_dir"
        fi
        printf 'put "%s" "%s"\n' "$UL_FILE" "$TARGET_PATH"
        printf -- '-chmod 600 "%s"\n' "$TARGET_PATH"
    } | sftp "${sftp_args[@]}" "$HOST" >/dev/null 2>"$TMP_DIR/sftp_err"
    rc=$?
    if (( rc != 0 )); then
        cat "$TMP_DIR/sftp_err" >&2
        exit "$rc"
    fi

    print_summary
    exit 0
fi

PAYLOAD="$TMP_DIR/posix_payload"
{
    print -r -- "$TARGET_PATH"
    printf '%s\n' "${NEW_KEYS[@]}"
} > "$PAYLOAD"

REMOTE_SH_CMD='exec sh -c '\''cd && umask 077 && IFS= read -r t && case "$t" in "~/"*) t="$HOME/${t#~/}";; "~") t="$HOME";; esac && d=$(dirname "$t") && mkdir -p "$d" && if [ -s "$t" ] && [ -n "$(tail -c 1 "$t")" ]; then echo >> "$t"; fi && cat >> "$t" && if command -v restorecon >/dev/null 2>&1; then restorecon -F "$d" "$t" >/dev/null 2>&1 || true; fi'\'''

SSH_ERR="$TMP_DIR/ssh_err"
ssh "${ssh_args[@]}" "$HOST" "$REMOTE_SH_CMD" < "$PAYLOAD" 2>"$SSH_ERR"
rc=$?
if (( rc == 0 )); then
    print_summary
    exit 0
fi

if grep -qiE "'exec' is not recognized|'sh' is not recognized|The term 'exec' is not recognized|The term 'sh' is not recognized|CommandNotFoundException" "$SSH_ERR"; then
    WIN_PS="$TMP_DIR/win_install.ps1"
    esc_target="${TARGET_PATH//\'/\'\'}"
    {
        print -r -- "& {"
        print -r -- "  \$ErrorActionPreference = 'Stop'"
        print -r -- "  \$t = '$esc_target'"
        print -r -- "  \$keys = @("
        local first=1 k ek
        for k in "${NEW_KEYS[@]}"; do
            ek="${k//\'/\'\'}"
            if (( first )); then
                print -r -- "    '$ek'"
                first=0
            else
                print -r -- "    ,'$ek'"
            fi
        done
        print -r -- "  )"
        print -r -- '  $h = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }'
        print -r -- '  if ($t -eq '\''~'\'') { $t = $h }'
        print -r -- '  elseif ($t -like '\''~/*'\'' -or $t -like '\''~\*'\'') { $t = Join-Path $h $t.Substring(2) }'
        print -r -- '  elseif (-not [System.IO.Path]::IsPathRooted($t)) { $t = Join-Path $h $t }'
        print -r -- '  $d = Split-Path -Parent $t'
        print -r -- '  if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }'
        print -r -- '  $enc = New-Object System.Text.UTF8Encoding($false)'
        print -r -- '  $ex = '\'''\'''
        print -r -- '  if (Test-Path -LiteralPath $t) { $ex = [System.IO.File]::ReadAllText($t, $enc) }'
        print -r -- '  if ($ex.Length -gt 0 -and -not $ex.EndsWith("`n")) { $ex += "`n" }'
        print -r -- '  [System.IO.File]::WriteAllText($t, ($ex + ($keys -join "`n") + "`n"), $enc)'
        print -r -- "}"
    } > "$WIN_PS"

    ssh "${ssh_args[@]}" "$HOST" "powershell -NoProfile -NonInteractive -Command -" < "$WIN_PS" 2>"$SSH_ERR"
    rc=$?
    if (( rc == 0 )); then
        print_summary
        exit 0
    fi
fi

if grep -qi 'unknown keyword' "$SSH_ERR"; then
    integer dsa_sent=0
    local k blob
    for k in "${NEW_KEYS[@]}"; do
        if [[ "$k" == ssh-dss\ * ]]; then
            blob="${${=k}[2]}"
            ssh "${ssh_args[@]}" "$HOST" "set ssh pka-dsa key $blob" >/dev/null 2>"$SSH_ERR" || {
                cat "$SSH_ERR" >&2
                exit 1
            }
            (( dsa_sent++ ))
        fi
    done
    if (( dsa_sent > 0 )); then
        ssh "${ssh_args[@]}" "$HOST" "save" >/dev/null 2>"$SSH_ERR" || true
        print_summary
        exit 0
    fi
fi

cat "$SSH_ERR" >&2
exit 1

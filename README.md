# ssh-copy-id

A cross-platform Zig implementation of [`ssh-copy-id(1)`](https://man7.org/linux/man-pages/man1/ssh-copy-id.1.html) that uses the system `ssh`, `ssh-add`, and `sftp` commands and embeds remote-side installation scripts for multiple target shells and operating systems.

## Features

- **Cross-platform native binary**: Built with Zig (`0.17.1+`) using `std.process` and `std.Io`; works across Windows, Linux, macOS, FreeBSD, OpenBSD, NetBSD, and other Zig-supported targets without running shell scripts locally.
- **Compatible CLI**: Implements standard Linux `ssh-copy-id(1)` flags and behavior:
  - `-i [identity_file]` — Install keys from `identity_file` (appends `.pub` if omitted), or use `default_ID_file` (`~/.ssh/id*.pub`, newest non-certificate file) when `identity_file` is omitted. Without `-i`, queries `ssh-add -L` first and falls back to `default_ID_file`.
  - `-f` — Force mode: skip checking whether keys are already installed on the remote host.
  - `-n` — Dry-run: print keys that would be installed without modifying the remote host.
  - `-s` — SFTP mode: download, update, and upload the remote `authorized_keys` file via `sftp`.
  - `-x` — Debug trace: print `ssh-add`, `ssh`, and `sftp` invocations to `stderr`.
  - `-t target_path` — Remote path to update (defaults to `.ssh/authorized_keys`).
  - `-p port` — Remote SSH/SFTP port (`-p` for `ssh`, `-P` for `sftp`).
  - `-F ssh_config` — Pass SSH configuration file through to `ssh`/`sftp`.
  - `-o ssh_option` — Pass SSH option through to `ssh`/`sftp` (repeatable).
  - `-h`, `-?`, `--help` — Print usage and option summary.
  - `--version` — Print embedded version string.
  - `--remote-shell <shell>` — Override remote target detection (`auto`, `sh`, `bash`, `zsh`, `fish`, `powershell`, `pwsh`, `cmd`, `netscreen`).
- **Compiled-in embedded remote scripts** (`@embedFile`):
  - [remote_posix.sh](src/scripts/remote_posix.sh) — POSIX `sh` script (`sh`, `dash`, `ash`, `bash`, `ksh`, plus `zsh`/`fish`/`csh` via `exec sh -c`), handles `~/` expansion, `umask 077`, trailing newline normalization, and SELinux `restorecon`.
  - [remote_zsh.zsh](src/scripts/remote_zsh.zsh) — Zsh-native remote script.
  - [remote_fish.fish](src/scripts/remote_fish.fish) — Fish-native remote script.
  - [remote_powershell.ps1](src/scripts/remote_powershell.ps1) — PowerShell remote script for Windows OpenSSH (`powershell.exe` 5.1 / `pwsh` 7+), writes UTF-8 without BOM.
  - [remote_cmd.cmd](src/scripts/remote_cmd.cmd) — Windows `cmd.exe` fallback template.
  - [remote_netscreen.txt](src/scripts/remote_netscreen.txt) — NetScreen ScreenOS (`set ssh pka-dsa key ...` / `save`) command template.

## Installation

Installers and platform-specific instructions are available on the [project site](https://dasimmet.github.io/ssh-copy-id/) (they download the latest release or fall back to the latest `main` build bundled with the site, and work with or without administrative privileges):

```sh
# Linux, macOS, and BSD (installs to ~/.local/bin by default when non-root)
curl -fsSL https://dasimmet.github.io/ssh-copy-id/install.sh | sh
```

```powershell
# Windows PowerShell (installs to %LOCALAPPDATA%\Programs\ssh-copy-id\bin by default when non-admin)
irm https://dasimmet.github.io/ssh-copy-id/install.ps1 | iex
```

## Building

Requires Zig `0.17.1` (matching `build.zig.zon`):

```sh
zig build
```

The binary is installed to `zig-out/bin/ssh-copy-id` (`zig-out/bin/ssh-copy-id.exe` on Windows). Pass `-Dversion-string=<version>` to override the embedded Git version string.

### Cross-compiling

```sh
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-linux-musl
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-freebsd
zig build -Dtarget=x86_64-openbsd
zig build -Dtarget=x86_64-netbsd
zig build -Dtarget=x86_64-windows
```

## Usage

```sh
ssh-copy-id [-h|-?|-f|-n|-s|-x] [-i [identity_file]] [-t target_path] [-F ssh_config] [[-o ssh_option] ...] [-p port] [user@]hostname
```

Examples:

```sh
# Install default or ssh-agent key(s) on a Linux/macOS/BSD/Windows host
ssh-copy-id user@example.com

# Install a specific key on a custom port
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 2222 user@example.com

# Dry-run without modifying the remote server
ssh-copy-id -n -i ~/.ssh/id_ed25519 user@example.com

# Install via SFTP when remote shell execution is restricted
ssh-copy-id -s user@example.com
```

## Testing

Run the unit test suite:

```sh
zig build test
```

## License

MIT — see [LICENSE](LICENSE).

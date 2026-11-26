const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

pub const usage_text =
    "Usage: ssh-copy-id [-h|-?|-f|-n|-s|-x] [-i [identity_file]] [-t target_path] [-F ssh_config] [[-o ssh_option] ...] [-p port] [user@]hostname\n";

pub const help_text =
    usage_text ++
    "\n" ++
    "Options:\n" ++
    "  -f                Forced mode: do not check if keys are already installed\n" ++
    "  -n                Dry-run: print keys that would be installed\n" ++
    "  -s                SFTP mode: install keys using sftp instead of remote shell\n" ++
    "  -x                Debug mode: enable shell command tracing\n" ++
    "  -i [identity]     Use only key(s) in identity_file (appends .pub if missing),\n" ++
    "                    or default_ID_file when identity_file is omitted\n" ++
    "  -t target_path    Remote authorized_keys path (default: .ssh/authorized_keys)\n" ++
    "  -F ssh_config     Pass configuration file to ssh/sftp\n" ++
    "  -o ssh_option     Pass option to ssh/sftp (repeatable)\n" ++
    "  -p port           Connect to specified port on the remote host\n" ++
    "  -h, -?            Print this help summary\n" ++
    "  --shell <shell>   Select client shell (sh, bash, zsh, fish, pwsh, powershell, cmd)\n";

pub const ShellKind = enum {
    sh,
    bash,
    zsh,
    fish,
    pwsh,
    powershell,
    cmd,

    pub fn parse(raw: []const u8) ?ShellKind {
        const base = pathBasename(raw);
        var buf: [32]u8 = undefined;
        if (base.len == 0 or base.len > buf.len) return null;
        for (base, 0..) |c, idx| {
            buf[idx] = std.ascii.toLower(c);
        }
        var name: []const u8 = buf[0..base.len];
        if (std.mem.endsWith(u8, name, ".exe")) {
            name = name[0 .. name.len - 4];
        }
        if (std.mem.eql(u8, name, "sh") or std.mem.eql(u8, name, "dash") or std.mem.eql(u8, name, "ash") or std.mem.eql(u8, name, "ksh")) {
            return .sh;
        }
        if (std.mem.eql(u8, name, "bash")) return .bash;
        if (std.mem.eql(u8, name, "zsh")) return .zsh;
        if (std.mem.eql(u8, name, "fish")) return .fish;
        if (std.mem.eql(u8, name, "pwsh")) return .pwsh;
        if (std.mem.eql(u8, name, "powershell")) return .powershell;
        if (std.mem.eql(u8, name, "cmd")) return .cmd;
        return null;
    }

    pub fn embeddedScript(self: ShellKind) []const u8 {
        return switch (self) {
            .sh, .bash => @embedFile("scripts/client.sh"),
            .zsh => @embedFile("scripts/client.zsh"),
            .fish => @embedFile("scripts/client.fish"),
            .pwsh, .powershell => @embedFile("scripts/client.ps1"),
            .cmd => @embedFile("scripts/client.cmd"),
        };
    }

    pub fn scriptFileName(self: ShellKind) []const u8 {
        return switch (self) {
            .sh, .bash => "ssh-copy-id.sh",
            .zsh => "ssh-copy-id.zsh",
            .fish => "ssh-copy-id.fish",
            .pwsh, .powershell => "ssh-copy-id.ps1",
            .cmd => "ssh-copy-id.cmd",
        };
    }

    pub fn executableName(self: ShellKind) []const u8 {
        return switch (self) {
            .sh => if (builtin.os.tag == .windows) "sh.exe" else "sh",
            .bash => if (builtin.os.tag == .windows) "bash.exe" else "bash",
            .zsh => if (builtin.os.tag == .windows) "zsh.exe" else "zsh",
            .fish => if (builtin.os.tag == .windows) "fish.exe" else "fish",
            .pwsh => if (builtin.os.tag == .windows) "pwsh.exe" else "pwsh",
            .powershell => if (builtin.os.tag == .windows) "powershell.exe" else "pwsh",
            .cmd => "cmd.exe",
        };
    }
};

pub const IdentityMode = enum {
    none,
    default_file,
    explicit_file,
};

pub const CliOptions = struct {
    prog_name: []const u8 = "ssh-copy-id",
    force: bool = false,
    dry_run: bool = false,
    sftp: bool = false,
    trace: bool = false,
    identity_mode: IdentityMode = .none,
    identity_file: ?[]const u8 = null,
    target_path: []const u8 = ".ssh/authorized_keys",
    port: ?[]const u8 = null,
    config_file: ?[]const u8 = null,
    ssh_options: []const []const u8 = &.{},
    host: ?[]const u8 = null,
    shell_override: ?ShellKind = null,
};

pub const ParseOutcome = union(enum) {
    help: void,
    ok: CliOptions,
    err: []const u8,
};

pub fn pathBasename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) {
        end -= 1;
    }
    var i = end;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') {
            return path[i + 1 .. end];
        }
    }
    return path[0..end];
}

pub fn parseArgs(allocator: Allocator, args: []const []const u8) Allocator.Error!ParseOutcome {
    var opts: CliOptions = .{};
    if (args.len > 0 and args[0].len > 0) {
        opts.prog_name = pathBasename(args[0]);
    }

    var ssh_opts: std.ArrayList([]const u8) = .empty;
    defer ssh_opts.deinit(allocator);

    var end_of_opts = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!end_of_opts and std.mem.eql(u8, arg, "--")) {
            end_of_opts = true;
            continue;
        }
        if (!end_of_opts and std.mem.eql(u8, arg, "--help")) {
            return .help;
        }
        if (!end_of_opts and std.mem.eql(u8, arg, "--shell")) {
            if (i + 1 >= args.len) {
                return .{ .err = "option '--shell' requires an argument" };
            }
            i += 1;
            opts.shell_override = ShellKind.parse(args[i]) orelse {
                return .{ .err = try std.fmt.allocPrint(allocator, "unsupported shell '{s}'", .{args[i]}) };
            };
            continue;
        }
        if (!end_of_opts and std.mem.startsWith(u8, arg, "--shell=")) {
            const val = arg["--shell=".len..];
            opts.shell_override = ShellKind.parse(val) orelse {
                return .{ .err = try std.fmt.allocPrint(allocator, "unsupported shell '{s}'", .{val}) };
            };
            continue;
        }
        if (!end_of_opts and arg.len > 1 and arg[0] == '-') {
            if (arg[1] == '-') {
                return .{ .err = try std.fmt.allocPrint(allocator, "unknown option '{s}'", .{arg}) };
            }
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const flag = arg[j];
                switch (flag) {
                    'h', '?' => return .help,
                    'f' => opts.force = true,
                    'n' => opts.dry_run = true,
                    's' => opts.sftp = true,
                    'x' => opts.trace = true,
                    't', 'p', 'F', 'o' => {
                        const val: []const u8 = if (j + 1 < arg.len) blk: {
                            const rest = arg[j + 1 ..];
                            j = arg.len - 1;
                            break :blk rest;
                        } else if (i + 1 < args.len) blk: {
                            i += 1;
                            break :blk args[i];
                        } else {
                            return .{ .err = try std.fmt.allocPrint(allocator, "option '-{c}' requires an argument", .{flag}) };
                        };
                        switch (flag) {
                            't' => opts.target_path = val,
                            'p' => opts.port = val,
                            'F' => opts.config_file = val,
                            'o' => try ssh_opts.append(allocator, val),
                            else => unreachable,
                        }
                    },
                    'i' => {
                        if (j + 1 < arg.len) {
                            opts.identity_mode = .explicit_file;
                            opts.identity_file = arg[j + 1 ..];
                            j = arg.len - 1;
                        } else if (i + 1 < args.len and !isFlagArg(args[i + 1]) and (opts.host != null or i + 2 < args.len)) {
                            i += 1;
                            opts.identity_mode = .explicit_file;
                            opts.identity_file = args[i];
                        } else {
                            opts.identity_mode = .default_file;
                            opts.identity_file = null;
                        }
                    },
                    else => {
                        return .{ .err = try std.fmt.allocPrint(allocator, "illegal option -- {c}", .{flag}) };
                    },
                }
            }
            continue;
        }

        if (opts.host != null) {
            return .{ .err = try std.fmt.allocPrint(allocator, "unexpected extra argument '{s}'", .{arg}) };
        }
        opts.host = arg;
    }

    if (opts.host == null) {
        return .{ .err = "missing hostname" };
    }

    opts.ssh_options = try ssh_opts.toOwnedSlice(allocator);
    return .{ .ok = opts };
}

fn isFlagArg(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

pub fn buildChildEnviron(
    allocator: Allocator,
    base: *const Environ.Map,
    opts: CliOptions,
    tmp_dir: []const u8,
) Allocator.Error!Environ.Map {
    var env = try base.clone(allocator);
    errdefer env.deinit();

    try env.put("SCI_PROG", opts.prog_name);
    try env.put("SCI_HOST", opts.host.?);
    try env.put("SCI_TARGET_PATH", opts.target_path);
    try env.put("SCI_FORCE", if (opts.force) "1" else "0");
    try env.put("SCI_DRY_RUN", if (opts.dry_run) "1" else "0");
    try env.put("SCI_SFTP", if (opts.sftp) "1" else "0");
    try env.put("SCI_TRACE", if (opts.trace) "1" else "0");
    try env.put("SCI_TMP_DIR", tmp_dir);

    const id_mode_str = switch (opts.identity_mode) {
        .none => "none",
        .default_file => "default",
        .explicit_file => "file",
    };
    try env.put("SCI_IDENTITY_MODE", id_mode_str);
    if (opts.identity_file) |f| {
        try env.put("SCI_IDENTITY_FILE", f);
    } else {
        _ = env.swapRemove("SCI_IDENTITY_FILE");
    }

    if (opts.port) |p| {
        try env.put("SCI_PORT", p);
    } else {
        _ = env.swapRemove("SCI_PORT");
    }

    if (opts.config_file) |c| {
        try env.put("SCI_CONFIG", c);
    } else {
        _ = env.swapRemove("SCI_CONFIG");
    }

    var count_buf: [32]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{opts.ssh_options.len}) catch unreachable;
    try env.put("SCI_OPT_COUNT", count_str);

    for (opts.ssh_options, 0..) |opt_val, idx| {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "SCI_OPT_{d}", .{idx}) catch unreachable;
        try env.put(key, opt_val);
    }

    return env;
}

pub const ShellInvocation = struct {
    kind: ShellKind,
    exe_path: []const u8,
};

pub fn resolveShell(
    allocator: Allocator,
    io: Io,
    environ_map: *const Environ.Map,
    override: ?ShellKind,
) Allocator.Error!ShellInvocation {
    if (override) |kind| {
        if (findShellExecutable(allocator, io, environ_map, kind)) |exe| {
            return .{ .kind = kind, .exe_path = exe };
        }
        return .{ .kind = kind, .exe_path = kind.executableName() };
    }

    if (environ_map.get("SSH_COPY_ID_SHELL")) |env_shell| {
        if (ShellKind.parse(env_shell)) |kind| {
            if (findShellExecutable(allocator, io, environ_map, kind)) |exe| {
                return .{ .kind = kind, .exe_path = exe };
            }
            return .{ .kind = kind, .exe_path = kind.executableName() };
        }
    }

    if (comptime builtin.os.tag == .windows) {
        if (detectWindowsAncestorShell(allocator)) |kind| {
            if (findShellExecutable(allocator, io, environ_map, kind)) |exe| {
                return .{ .kind = kind, .exe_path = exe };
            }
        }
        if (environ_map.get("MSYSTEM") != null) {
            if (findShellExecutable(allocator, io, environ_map, .bash)) |exe| {
                return .{ .kind = .bash, .exe_path = exe };
            }
        }
        if (findShellExecutable(allocator, io, environ_map, .pwsh)) |exe| {
            return .{ .kind = .pwsh, .exe_path = exe };
        }
        if (findShellExecutable(allocator, io, environ_map, .powershell)) |exe| {
            return .{ .kind = .powershell, .exe_path = exe };
        }
        if (environ_map.get("COMSPEC")) |comspec| {
            if (comspec.len > 0) {
                return .{ .kind = .cmd, .exe_path = try allocator.dupe(u8, comspec) };
            }
        }
        return .{ .kind = .cmd, .exe_path = "cmd.exe" };
    } else {
        if (environ_map.get("SHELL")) |user_shell| {
            if (ShellKind.parse(user_shell)) |kind| {
                if (std.fs.path.isAbsolute(user_shell)) {
                    if (fileExists(io, user_shell)) {
                        return .{ .kind = kind, .exe_path = try allocator.dupe(u8, user_shell) };
                    }
                }
                if (findShellExecutable(allocator, io, environ_map, kind)) |exe| {
                    return .{ .kind = kind, .exe_path = exe };
                }
            }
        }
        if (fileExists(io, "/bin/sh")) {
            return .{ .kind = .sh, .exe_path = "/bin/sh" };
        }
        return .{ .kind = .sh, .exe_path = "sh" };
    }
}

pub fn buildShellArgv(
    kind: ShellKind,
    exe_path: []const u8,
    script_path: []const u8,
    out_buf: *[6][]const u8,
) []const []const u8 {
    return switch (kind) {
        .powershell, .pwsh => blk: {
            out_buf[0] = exe_path;
            out_buf[1] = "-NoProfile";
            out_buf[2] = "-ExecutionPolicy";
            out_buf[3] = "Bypass";
            out_buf[4] = "-File";
            out_buf[5] = script_path;
            break :blk out_buf[0..6];
        },
        .cmd => blk: {
            out_buf[0] = exe_path;
            out_buf[1] = "/D";
            out_buf[2] = "/C";
            out_buf[3] = script_path;
            break :blk out_buf[0..4];
        },
        .sh, .bash, .zsh, .fish => blk: {
            out_buf[0] = exe_path;
            out_buf[1] = script_path;
            break :blk out_buf[0..2];
        },
    };
}

fn findShellExecutable(
    allocator: Allocator,
    io: Io,
    environ_map: *const Environ.Map,
    kind: ShellKind,
) ?[]const u8 {
    if (kind == .cmd) {
        if (environ_map.get("COMSPEC")) |comspec| {
            if (comspec.len > 0 and fileExists(io, comspec)) {
                return allocator.dupe(u8, comspec) catch null;
            }
        }
    }
    return findInPath(allocator, io, environ_map, kind.executableName());
}

pub fn findInPath(
    allocator: Allocator,
    io: Io,
    environ_map: *const Environ.Map,
    exe_name: []const u8,
) ?[]const u8 {
    const path_val = environ_map.get("PATH") orelse return null;
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.splitScalar(u8, path_val, sep);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        // Skip WindowsApps alias sh/bash stubs on Windows unless explicitly present
        if (comptime builtin.os.tag == .windows) {
            if ((std.mem.eql(u8, exe_name, "bash.exe") or std.mem.eql(u8, exe_name, "sh.exe")) and
                containsIgnoreCase(dir, "\\WindowsApps"))
            {
                continue;
            }
        }
        const candidate = std.fs.path.join(allocator, &.{ dir, exe_name }) catch return null;
        if (fileExists(io, candidate)) {
            return candidate;
        }
        allocator.free(candidate);
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn fileExists(io: Io, path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    Io.Dir.accessAbsolute(io, path, .{ .read = true }) catch return false;
    return true;
}

const WinProcessApi = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const PROCESS_QUERY_LIMITED_INFORMATION: windows.DWORD = 0x1000;

    extern "kernel32" fn OpenProcess(
        dwDesiredAccess: windows.DWORD,
        bInheritHandle: windows.BOOL,
        dwProcessId: windows.DWORD,
    ) callconv(.winapi) ?windows.HANDLE;
} else struct {};

fn detectWindowsAncestorShell(allocator: Allocator) ?ShellKind {
    if (comptime builtin.os.tag != .windows) return null;
    const windows = std.os.windows;

    var pid: windows.DWORD = windows.GetCurrentProcessId();
    var depth: usize = 0;
    while (depth < 6) : (depth += 1) {
        const handle = if (depth == 0)
            windows.GetCurrentProcess()
        else
            WinProcessApi.OpenProcess(WinProcessApi.PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, pid) orelse return null;
        defer if (depth != 0) {
            _ = windows.ntdll.NtClose(handle);
        };

        if (depth > 0) {
            var name_buf: [2048]u8 align(@alignOf(windows.UNICODE_STRING)) = undefined;
            var ret_len: windows.ULONG = 0;
            const status = windows.ntdll.NtQueryInformationProcess(
                handle,
                .ImageFileNameWin32,
                &name_buf,
                name_buf.len,
                &ret_len,
            );
            if (status == .SUCCESS) {
                const us: *const windows.UNICODE_STRING = @ptrCast(@alignCast(&name_buf));
                if (us.Buffer) |buf_ptr| {
                    const char_len = us.Length / 2;
                    const wtf16 = buf_ptr[0..char_len];
                    if (std.unicode.wtf16LeToWtf8Alloc(allocator, wtf16)) |utf8_path| {
                        defer allocator.free(utf8_path);
                        if (ShellKind.parse(utf8_path)) |kind| {
                            return kind;
                        }
                    } else |_| {}
                }
            }
        }

        var basic: windows.PROCESS.BASIC_INFORMATION = undefined;
        var basic_len: windows.ULONG = 0;
        const basic_status = windows.ntdll.NtQueryInformationProcess(
            handle,
            .BasicInformation,
            &basic,
            @sizeOf(windows.PROCESS.BASIC_INFORMATION),
            &basic_len,
        );
        if (basic_status != .SUCCESS) return null;
        const parent_pid: windows.DWORD = @truncate(basic.InheritedFromUniqueProcessId);
        if (parent_pid == 0 or parent_pid == pid) return null;
        pid = parent_pid;
    }
    return null;
}

pub fn getTempRoot(environ_map: *const Environ.Map) []const u8 {
    if (comptime builtin.os.tag == .windows) {
        if (environ_map.get("TMP")) |p| if (p.len > 0) return p;
        if (environ_map.get("TEMP")) |p| if (p.len > 0) return p;
        if (environ_map.get("LOCALAPPDATA")) |p| if (p.len > 0) return p;
        return "C:\\Windows\\Temp";
    } else {
        if (environ_map.get("TMPDIR")) |p| if (p.len > 0) return p;
        return "/tmp";
    }
}

pub fn createUniqueTempDir(allocator: Allocator, io: Io, environ_map: *const Environ.Map) ![]const u8 {
    const base = getTempRoot(environ_map);
    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
    const dir_name = try std.fmt.allocPrint(allocator, "ssh-copy-id-{s}", .{&hex});
    defer allocator.free(dir_name);

    const full_path = try std.fs.path.join(allocator, &.{ base, dir_name });
    errdefer allocator.free(full_path);

    const perms: Io.Dir.Permissions = if (comptime std.posix.mode_t != u0)
        .fromMode(0o700)
    else
        .default_dir;
    try Io.Dir.createDirAbsolute(io, full_path, perms);
    return full_path;
}

// ---------------- Unit Tests ----------------

test "ShellKind.parse recognizes shells, paths, and .exe" {
    try std.testing.expectEqual(@as(?ShellKind, .sh), ShellKind.parse("sh"));
    try std.testing.expectEqual(@as(?ShellKind, .sh), ShellKind.parse("/bin/dash"));
    try std.testing.expectEqual(@as(?ShellKind, .bash), ShellKind.parse("/usr/bin/bash"));
    try std.testing.expectEqual(@as(?ShellKind, .zsh), ShellKind.parse("/bin/zsh"));
    try std.testing.expectEqual(@as(?ShellKind, .fish), ShellKind.parse("/usr/local/bin/fish"));
    try std.testing.expectEqual(@as(?ShellKind, .pwsh), ShellKind.parse("C:\\Program Files\\PowerShell\\7\\pwsh.exe"));
    try std.testing.expectEqual(@as(?ShellKind, .powershell), ShellKind.parse("powershell.EXE"));
    try std.testing.expectEqual(@as(?ShellKind, .cmd), ShellKind.parse("C:\\Windows\\System32\\cmd.exe"));
    try std.testing.expectEqual(@as(?ShellKind, null), ShellKind.parse("nushell"));
}

test "embedded scripts are compiled in and non-empty" {
    inline for (std.meta.fields(ShellKind)) |f| {
        const kind: ShellKind = @enumFromInt(f.value);
        try std.testing.expect(kind.embeddedScript().len > 100);
        try std.testing.expect(kind.scriptFileName().len > 0);
    }
}

test "parseArgs basic flags and ssh options" {
    const gpa = std.testing.allocator;
    const args = &[_][]const u8{
        "ssh-copy-id",
        "-fnxs",
        "-p",
        "2222",
        "-F",
        "/tmp/ssh_cfg",
        "-o",
        "StrictHostKeyChecking=no",
        "-oUserKnownHostsFile=/dev/null",
        "-t",
        ".ssh/custom_keys",
        "alice@example.com",
    };
    const res = try parseArgs(gpa, args);
    switch (res) {
        .ok => |opts| {
            defer gpa.free(opts.ssh_options);
            try std.testing.expect(opts.force);
            try std.testing.expect(opts.dry_run);
            try std.testing.expect(opts.sftp);
            try std.testing.expect(opts.trace);
            try std.testing.expectEqualStrings("2222", opts.port.?);
            try std.testing.expectEqualStrings("/tmp/ssh_cfg", opts.config_file.?);
            try std.testing.expectEqualStrings(".ssh/custom_keys", opts.target_path);
            try std.testing.expectEqualStrings("alice@example.com", opts.host.?);
            try std.testing.expectEqual(@as(usize, 2), opts.ssh_options.len);
            try std.testing.expectEqualStrings("StrictHostKeyChecking=no", opts.ssh_options[0]);
            try std.testing.expectEqualStrings("UserKnownHostsFile=/dev/null", opts.ssh_options[1]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseArgs handles optional -i argument edge cases" {
    const gpa = std.testing.allocator;

    // -i followed immediately by host -> default_file
    {
        const res = try parseArgs(gpa, &.{ "ssh-copy-id", "-i", "user@host" });
        switch (res) {
            .ok => |opts| {
                defer gpa.free(opts.ssh_options);
                try std.testing.expectEqual(IdentityMode.default_file, opts.identity_mode);
                try std.testing.expectEqual(@as(?[]const u8, null), opts.identity_file);
                try std.testing.expectEqualStrings("user@host", opts.host.?);
            },
            else => return error.TestUnexpectedResult,
        }
    }

    // -i followed by another flag -> default_file
    {
        const res = try parseArgs(gpa, &.{ "ssh-copy-id", "-i", "-f", "user@host" });
        switch (res) {
            .ok => |opts| {
                defer gpa.free(opts.ssh_options);
                try std.testing.expectEqual(IdentityMode.default_file, opts.identity_mode);
                try std.testing.expect(opts.force);
                try std.testing.expectEqualStrings("user@host", opts.host.?);
            },
            else => return error.TestUnexpectedResult,
        }
    }

    // -i with explicit file and host -> explicit_file
    {
        const res = try parseArgs(gpa, &.{ "ssh-copy-id", "-i", "~/.ssh/id_ed25519", "user@host" });
        switch (res) {
            .ok => |opts| {
                defer gpa.free(opts.ssh_options);
                try std.testing.expectEqual(IdentityMode.explicit_file, opts.identity_mode);
                try std.testing.expectEqualStrings("~/.ssh/id_ed25519", opts.identity_file.?);
                try std.testing.expectEqualStrings("user@host", opts.host.?);
            },
            else => return error.TestUnexpectedResult,
        }
    }

    // -i after host -> explicit_file
    {
        const res = try parseArgs(gpa, &.{ "ssh-copy-id", "user@host", "-i", "mykey" });
        switch (res) {
            .ok => |opts| {
                defer gpa.free(opts.ssh_options);
                try std.testing.expectEqual(IdentityMode.explicit_file, opts.identity_mode);
                try std.testing.expectEqualStrings("mykey", opts.identity_file.?);
                try std.testing.expectEqualStrings("user@host", opts.host.?);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "parseArgs handles -h, -?, and errors" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(ParseOutcome.help, try parseArgs(gpa, &.{ "ssh-copy-id", "-h" }));
    try std.testing.expectEqual(ParseOutcome.help, try parseArgs(gpa, &.{ "ssh-copy-id", "-?" }));
    try std.testing.expectEqual(ParseOutcome.help, try parseArgs(gpa, &.{ "ssh-copy-id", "--help" }));

    const missing = try parseArgs(gpa, &.{"ssh-copy-id"});
    switch (missing) {
        .err => |msg| try std.testing.expectEqualStrings("missing hostname", msg),
        else => return error.TestUnexpectedResult,
    }
}

test "buildChildEnviron populates SCI_* variables" {
    const gpa = std.testing.allocator;
    var base: Environ.Map = .init(gpa);
    defer base.deinit();
    try base.put("PATH", "/usr/bin");

    const opts: CliOptions = .{
        .prog_name = "ssh-copy-id",
        .force = true,
        .dry_run = true,
        .sftp = false,
        .trace = true,
        .identity_mode = .explicit_file,
        .identity_file = "/home/u/.ssh/id_ed25519",
        .target_path = ".ssh/authorized_keys",
        .port = "2200",
        .ssh_options = &.{ "StrictHostKeyChecking=no", "Compression=yes" },
        .host = "bob@server",
    };

    var child_env = try buildChildEnviron(gpa, &base, opts, "/tmp/sci-123");
    defer child_env.deinit();

    try std.testing.expectEqualStrings("bob@server", child_env.get("SCI_HOST").?);
    try std.testing.expectEqualStrings("1", child_env.get("SCI_FORCE").?);
    try std.testing.expectEqualStrings("1", child_env.get("SCI_DRY_RUN").?);
    try std.testing.expectEqualStrings("0", child_env.get("SCI_SFTP").?);
    try std.testing.expectEqualStrings("1", child_env.get("SCI_TRACE").?);
    try std.testing.expectEqualStrings("2200", child_env.get("SCI_PORT").?);
    try std.testing.expectEqualStrings("2", child_env.get("SCI_OPT_COUNT").?);
    try std.testing.expectEqualStrings("StrictHostKeyChecking=no", child_env.get("SCI_OPT_0").?);
    try std.testing.expectEqualStrings("Compression=yes", child_env.get("SCI_OPT_1").?);
    try std.testing.expectEqualStrings("/tmp/sci-123", child_env.get("SCI_TMP_DIR").?);
}

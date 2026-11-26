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
    "  -f                   Forced mode: do not check if keys are already installed\n" ++
    "  -n                   Dry-run: print keys that would be installed\n" ++
    "  -s                   SFTP mode: install keys using sftp instead of remote shell\n" ++
    "  -x                   Debug mode: trace ssh/sftp/ssh-add commands\n" ++
    "  -i [identity_file]   Use only key(s) in identity_file (appends .pub if missing),\n" ++
    "                       or default_ID_file when identity_file is omitted\n" ++
    "  -t target_path       Remote authorized_keys path (default: .ssh/authorized_keys)\n" ++
    "  -F ssh_config        Pass configuration file to ssh/sftp\n" ++
    "  -o ssh_option        Pass option to ssh/sftp (repeatable)\n" ++
    "  -p port              Connect to specified port on the remote host\n" ++
    "  -h, -?               Print this help summary\n" ++
    "  --remote-shell <s>   Force remote shell (auto, sh, bash, zsh, fish, powershell, pwsh, cmd, netscreen)\n";

pub const RemoteShell = enum {
    auto,
    sh,
    bash,
    zsh,
    fish,
    powershell,
    pwsh,
    cmd,
    netscreen,

    pub fn parse(raw: []const u8) ?RemoteShell {
        var buf: [32]u8 = undefined;
        if (raw.len == 0 or raw.len > buf.len) return null;
        for (raw, 0..) |c, idx| {
            buf[idx] = std.ascii.toLower(c);
        }
        const s = buf[0..raw.len];
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "sh") or std.mem.eql(u8, s, "posix") or std.mem.eql(u8, s, "dash") or std.mem.eql(u8, s, "ash") or std.mem.eql(u8, s, "ksh")) return .sh;
        if (std.mem.eql(u8, s, "bash")) return .bash;
        if (std.mem.eql(u8, s, "zsh")) return .zsh;
        if (std.mem.eql(u8, s, "fish")) return .fish;
        if (std.mem.eql(u8, s, "powershell")) return .powershell;
        if (std.mem.eql(u8, s, "pwsh")) return .pwsh;
        if (std.mem.eql(u8, s, "cmd")) return .cmd;
        if (std.mem.eql(u8, s, "netscreen")) return .netscreen;
        return null;
    }

    pub fn embeddedScript(self: RemoteShell) []const u8 {
        return switch (self) {
            .auto, .sh, .bash => @embedFile("scripts/remote_posix.sh"),
            .zsh => @embedFile("scripts/remote_zsh.zsh"),
            .fish => @embedFile("scripts/remote_fish.fish"),
            .powershell, .pwsh => @embedFile("scripts/remote_powershell.ps1"),
            .cmd => @embedFile("scripts/remote_cmd.cmd"),
            .netscreen => @embedFile("scripts/remote_netscreen.txt"),
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
    remote_shell: RemoteShell = .auto,
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

fn isFlagArg(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
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
        if (!end_of_opts and std.mem.eql(u8, arg, "--remote-shell")) {
            if (i + 1 >= args.len) {
                return .{ .err = "option '--remote-shell' requires an argument" };
            }
            i += 1;
            opts.remote_shell = RemoteShell.parse(args[i]) orelse {
                return .{ .err = try std.fmt.allocPrint(allocator, "unsupported remote shell '{s}'", .{args[i]}) };
            };
            continue;
        }
        if (!end_of_opts and std.mem.startsWith(u8, arg, "--remote-shell=")) {
            const val = arg["--remote-shell=".len..];
            opts.remote_shell = RemoteShell.parse(val) orelse {
                return .{ .err = try std.fmt.allocPrint(allocator, "unsupported remote shell '{s}'", .{val}) };
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

pub fn getHomeDir(environ_map: *const Environ.Map) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) {
        if (environ_map.get("USERPROFILE")) |p| if (p.len > 0) return p;
        if (environ_map.get("HOME")) |p| if (p.len > 0) return p;
        return null;
    } else {
        if (environ_map.get("HOME")) |p| if (p.len > 0) return p;
        return null;
    }
}

pub fn expandTilde(allocator: Allocator, environ_map: *const Environ.Map, path: []const u8) Allocator.Error![]const u8 {
    const home = getHomeDir(environ_map) orelse return allocator.dupe(u8, path);
    if (std.mem.eql(u8, path, "~")) {
        return allocator.dupe(u8, home);
    }
    if (std.mem.startsWith(u8, path, "~/") or std.mem.startsWith(u8, path, "~\\")) {
        return std.fs.path.join(allocator, &.{ home, path[2..] });
    }
    return allocator.dupe(u8, path);
}

pub fn ensurePubSuffix(allocator: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (std.mem.endsWith(u8, path, ".pub")) {
        return allocator.dupe(u8, path);
    }
    return std.fmt.allocPrint(allocator, "{s}.pub", .{path});
}

pub fn parseKeyLines(allocator: Allocator, content: []const u8) Allocator.Error![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r \t");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.indexOf(u8, trimmed, "The agent has no identities") != null) continue;
        try list.append(allocator, try allocator.dupe(u8, line));
    }

    return list.toOwnedSlice(allocator);
}

pub fn isDefaultIdCandidate(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "id") and
        std.mem.endsWith(u8, name, ".pub") and
        !std.mem.endsWith(u8, name, "-cert.pub");
}

pub fn findDefaultIdFile(allocator: Allocator, io: Io, environ_map: *const Environ.Map) !?[]const u8 {
    const home = getHomeDir(environ_map) orelse return null;
    const ssh_dir_path = try std.fs.path.join(allocator, &.{ home, ".ssh" });
    defer allocator.free(ssh_dir_path);

    var ssh_dir = Io.Dir.openDirAbsolute(io, ssh_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer ssh_dir.close(io);

    var best_name: ?[]const u8 = null;
    defer if (best_name) |b| allocator.free(b);
    var best_mtime: i96 = std.math.minInt(i96);

    var it = ssh_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!isDefaultIdCandidate(entry.name)) continue;

        var f = ssh_dir.openFile(io, entry.name, .{}) catch continue;
        defer f.close(io);
        const st = f.stat(io) catch continue;
        if (st.kind != .file) continue;

        if (best_name == null or st.mtime.nanoseconds > best_mtime) {
            if (best_name) |old| allocator.free(old);
            best_name = try allocator.dupe(u8, entry.name);
            best_mtime = st.mtime.nanoseconds;
        }
    }

    const chosen = best_name orelse return null;
    return try std.fs.path.join(allocator, &.{ ssh_dir_path, chosen });
}

pub fn buildPosixRemoteCommand(allocator: Allocator, shell: RemoteShell) Allocator.Error![]const u8 {
    const body = std.mem.trim(u8, shell.embeddedScript(), " \t\r\n");
    return switch (shell) {
        .auto, .sh, .bash => std.fmt.allocPrint(allocator, "exec sh -c '{s}'", .{body}),
        .zsh => std.fmt.allocPrint(allocator, "exec zsh -c '{s}'", .{body}),
        .fish => std.fmt.allocPrint(allocator, "exec fish -c '{s}'", .{body}),
        else => unreachable,
    };
}

pub fn buildPosixStdinPayload(allocator: Allocator, target_path: []const u8, keys: []const []const u8) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, target_path);
    try buf.append(allocator, '\n');
    for (keys) |k| {
        try buf.appendSlice(allocator, k);
        try buf.append(allocator, '\n');
    }
    return buf.toOwnedSlice(allocator);
}

fn appendPsSingleQuoted(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
}

pub fn buildPowerShellRemoteScript(allocator: Allocator, target_path: []const u8, keys: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "& {\n$t = ");
    try appendPsSingleQuoted(allocator, &out, target_path);
    try out.appendSlice(allocator, "\n$keys = @(");
    for (keys, 0..) |k, idx| {
        if (idx > 0) try out.appendSlice(allocator, ", ");
        try appendPsSingleQuoted(allocator, &out, k);
    }
    try out.appendSlice(allocator, ")\n");
    try out.appendSlice(allocator, RemoteShell.powershell.embeddedScript());
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

fn appendCmdEscapedEcho(allocator: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |c| {
        switch (c) {
            '^', '&', '|', '<', '>', '(', ')' => {
                try out.append(allocator, '^');
                try out.append(allocator, c);
            },
            else => try out.append(allocator, c),
        }
    }
}

pub fn buildCmdRemoteCommand(allocator: Allocator, target_path: []const u8, keys: []const []const u8) Allocator.Error![]u8 {
    var win_target: std.ArrayList(u8) = .empty;
    defer win_target.deinit(allocator);

    var rest = target_path;
    if (std.mem.eql(u8, target_path, "~")) {
        try win_target.appendSlice(allocator, "%USERPROFILE%");
        rest = "";
    } else if (std.mem.startsWith(u8, target_path, "~/") or std.mem.startsWith(u8, target_path, "~\\")) {
        try win_target.appendSlice(allocator, "%USERPROFILE%\\");
        rest = target_path[2..];
    }
    for (rest) |c| {
        try win_target.append(allocator, if (c == '/') '\\' else c);
    }

    const target_str = win_target.items;
    const last_sep = std.mem.lastIndexOfScalar(u8, target_str, '\\');
    const dir_str = if (last_sep) |pos| target_str[0..pos] else "";

    var echo_keys: std.ArrayList(u8) = .empty;
    defer echo_keys.deinit(allocator);
    for (keys, 0..) |k, idx| {
        if (idx > 0) try echo_keys.appendSlice(allocator, " & ");
        try echo_keys.appendSlice(allocator, "echo ");
        try appendCmdEscapedEcho(allocator, &echo_keys, k);
    }

    const tmpl = std.mem.trim(u8, RemoteShell.cmd.embeddedScript(), " \t\r\n");
    var single_line: std.ArrayList(u8) = .empty;
    defer single_line.deinit(allocator);
    var lit = std.mem.splitScalar(u8, tmpl, '\n');
    var first = true;
    while (lit.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, "\r");
        if (line.len == 0) continue;
        if (!first) try single_line.appendSlice(allocator, " && ");
        first = false;
        try single_line.appendSlice(allocator, line);
    }

    const step1 = try std.mem.replaceOwned(u8, allocator, single_line.items, "{DIR}", dir_str);
    defer allocator.free(step1);
    const step2 = try std.mem.replaceOwned(u8, allocator, step1, "{ECHO_KEYS}", echo_keys.items);
    defer allocator.free(step2);
    return std.mem.replaceOwned(u8, allocator, step2, "{TARGET}", target_str);
}

pub fn buildNetScreenCommands(allocator: Allocator, keys: []const []const u8) Allocator.Error![][]const u8 {
    const tmpl = RemoteShell.netscreen.embeddedScript();
    var cmds: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (cmds.items) |c| allocator.free(c);
        cmds.deinit(allocator);
    }

    var key_tmpl: []const u8 = "set ssh pka-dsa key {KEY}";
    var save_cmd: []const u8 = "save";
    var line_it = std.mem.splitScalar(u8, tmpl, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r \t");
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "{KEY}") != null) {
            key_tmpl = line;
        } else {
            save_cmd = line;
        }
    }

    for (keys) |k| {
        if (!std.mem.startsWith(u8, k, "ssh-dss ")) continue;
        var tok_it = std.mem.tokenizeAny(u8, k, " \t");
        _ = tok_it.next();
        const blob = tok_it.next() orelse continue;
        const cmd = try std.mem.replaceOwned(u8, allocator, key_tmpl, "{KEY}", blob);
        try cmds.append(allocator, cmd);
    }
    if (cmds.items.len > 0) {
        try cmds.append(allocator, try allocator.dupe(u8, save_cmd));
    }
    return cmds.toOwnedSlice(allocator);
}

pub fn mergeAuthorizedKeys(
    allocator: Allocator,
    existing: []const u8,
    new_keys: []const []const u8,
    force: bool,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    if (existing.len > 0) {
        try out.appendSlice(allocator, existing);
        if (existing[existing.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        var it = std.mem.splitScalar(u8, existing, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len > 0) {
                try seen.put(allocator, line, {});
            }
        }
    }

    for (new_keys) |k| {
        if (!force and seen.contains(k)) continue;
        try out.appendSlice(allocator, k);
        try out.append(allocator, '\n');
        try seen.put(allocator, k, {});
    }

    return out.toOwnedSlice(allocator);
}

pub fn isAuthFailureOutput(output: []const u8) bool {
    return containsIgnoreCase(output, "Permission denied") or
        containsIgnoreCase(output, "No more authentication methods") or
        containsIgnoreCase(output, "Authentication failed");
}

pub fn detectRemoteFallback(err_output: []const u8) ?RemoteShell {
    if (containsIgnoreCase(err_output, "The term 'exec' is not recognized") or
        containsIgnoreCase(err_output, "The term 'sh' is not recognized") or
        containsIgnoreCase(err_output, "CommandNotFoundException"))
    {
        return .powershell;
    }
    if (containsIgnoreCase(err_output, "'exec' is not recognized") or
        containsIgnoreCase(err_output, "'sh' is not recognized"))
    {
        return .cmd;
    }
    if (containsIgnoreCase(err_output, "unknown keyword")) {
        return .netscreen;
    }
    if (containsIgnoreCase(err_output, "sh: command not found") or
        containsIgnoreCase(err_output, "sh: not found"))
    {
        return .fish;
    }
    return null;
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
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

    const perms: Io.Dir.Permissions = if (comptime builtin.os.tag != .windows and std.posix.mode_t != u0)
        Io.Dir.Permissions.fromMode(0o700)
    else
        .default_dir;
    try Io.Dir.createDirAbsolute(io, full_path, perms);
    return full_path;
}

// ---------------- Unit Tests ----------------

test "RemoteShell.parse and embedded scripts" {
    try std.testing.expectEqual(@as(?RemoteShell, .auto), RemoteShell.parse("auto"));
    try std.testing.expectEqual(@as(?RemoteShell, .sh), RemoteShell.parse("SH"));
    try std.testing.expectEqual(@as(?RemoteShell, .zsh), RemoteShell.parse("zsh"));
    try std.testing.expectEqual(@as(?RemoteShell, .fish), RemoteShell.parse("fish"));
    try std.testing.expectEqual(@as(?RemoteShell, .powershell), RemoteShell.parse("powershell"));
    try std.testing.expectEqual(@as(?RemoteShell, .pwsh), RemoteShell.parse("pwsh"));
    try std.testing.expectEqual(@as(?RemoteShell, .cmd), RemoteShell.parse("cmd"));
    try std.testing.expectEqual(@as(?RemoteShell, .netscreen), RemoteShell.parse("netscreen"));
    try std.testing.expectEqual(@as(?RemoteShell, null), RemoteShell.parse("invalid"));

    inline for (std.enums.values(RemoteShell)) |kind| {
        try std.testing.expect(kind.embeddedScript().len > 10);
    }
}

test "POSIX/zsh/fish embedded remote commands contain no single quotes or backslashes" {
    inline for ([_]RemoteShell{ .sh, .zsh, .fish }) |kind| {
        const body = kind.embeddedScript();
        try std.testing.expect(std.mem.indexOfScalar(u8, body, '\'') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, body, '\\') == null);
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

test "remote script builders format payloads correctly" {
    const gpa = std.testing.allocator;

    const ps = try buildPowerShellRemoteScript(gpa, ".ssh/authorized_keys", &.{"ssh-ed25519 AAAA user's@host"});
    defer gpa.free(ps);
    try std.testing.expect(std.mem.indexOf(u8, ps, "$t = '.ssh/authorized_keys'") != null);
    try std.testing.expect(std.mem.indexOf(u8, ps, "'ssh-ed25519 AAAA user''s@host'") != null);
    try std.testing.expect(std.mem.indexOf(u8, ps, "UTF8Encoding($false)") != null);

    const cmd = try buildCmdRemoteCommand(gpa, ".ssh/authorized_keys", &.{"ssh-ed25519 AAAA u@h"});
    defer gpa.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "mkdir \".ssh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "(echo ssh-ed25519 AAAA u@h)>> \".ssh\\authorized_keys\"") != null);

    const ns = try buildNetScreenCommands(gpa, &.{ "ssh-ed25519 AAAA u@h", "ssh-dss BBBB dsa@h" });
    defer {
        for (ns) |c| gpa.free(c);
        gpa.free(ns);
    }
    try std.testing.expectEqual(@as(usize, 2), ns.len);
    try std.testing.expectEqualStrings("set ssh pka-dsa key BBBB", ns[0]);
    try std.testing.expectEqualStrings("save", ns[1]);
}

test "mergeAuthorizedKeys appends and deduplicates with LF" {
    const gpa = std.testing.allocator;
    const merged = try mergeAuthorizedKeys(gpa, "ssh-rsa AAAA old", &.{ "ssh-rsa AAAA old", "ssh-ed25519 BBBB new" }, false);
    defer gpa.free(merged);
    try std.testing.expectEqualStrings("ssh-rsa AAAA old\nssh-ed25519 BBBB new\n", merged);
}

test "detectRemoteFallback identifies Windows CMD, PowerShell, and NetScreen" {
    try std.testing.expectEqual(@as(?RemoteShell, .cmd), detectRemoteFallback("'exec' is not recognized as an internal or external command"));
    try std.testing.expectEqual(@as(?RemoteShell, .powershell), detectRemoteFallback("exec : The term 'exec' is not recognized as the name of a cmdlet"));
    try std.testing.expectEqual(@as(?RemoteShell, .netscreen), detectRemoteFallback("unknown keyword sh"));
    try std.testing.expectEqual(@as(?RemoteShell, null), detectRemoteFallback("Permission denied (publickey)."));
}

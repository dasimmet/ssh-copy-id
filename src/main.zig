const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sci = @import("ssh_copy_id");
const build_options = @import("build_options");

const KeyDiscovery = struct {
    keys: [][]const u8,
    source_label: []const u8,
    single_disk_file: ?[]const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    const parsed = try sci.parseArgs(arena, args);
    const opts = switch (parsed) {
        .help => {
            try writeStdout(io, sci.help_text);
            return 0;
        },
        .version => {
            try writeStdout(io, "ssh-copy-id " ++ build_options.version ++ "\n");
            return 0;
        },
        .err => |msg| {
            const prog = if (args.len > 0 and args[0].len > 0) sci.pathBasename(args[0]) else "ssh-copy-id";
            try printStderr(io, arena, "{s}: ERROR: {s}\n{s}", .{ prog, msg, sci.usage_text });
            return 1;
        },
        .ok => |o| o,
    };

    const host = opts.host.?;

    const discovered = discoverKeys(arena, io, init.environ_map, opts) catch |err| switch (err) {
        error.NoIdentities => {
            try printStderr(io, arena, "{s}: ERROR: No identities found\n", .{opts.prog_name});
            return 1;
        },
        error.IdentityOpenFailed => return 1,
        else => return err,
    };

    try printStderr(io, arena, "{s}: INFO: Source of key(s) to be installed: \"{s}\"\n", .{
        opts.prog_name,
        discovered.source_label,
    });

    const tmp_dir_path = try sci.createUniqueTempDir(arena, io, init.environ_map);
    defer cleanupTempDir(io, tmp_dir_path);

    const new_keys = if (opts.force)
        discovered.keys
    else
        filterInstalledKeys(arena, io, opts, discovered, tmp_dir_path) catch |err| switch (err) {
            error.SshProbeFailed => return 1,
            else => return err,
        };

    if (new_keys.len == 0) {
        try printStderr(
            io,
            arena,
            "{s}: INFO: All keys were skipped because they already exist on the remote system.\n\t\t(If you think this is wrong, you may want to use the -f option)\n",
            .{opts.prog_name},
        );
        return 0;
    }

    try printStderr(
        io,
        arena,
        "{s}: INFO: {d} key(s) remain to be installed -- if you are prompted now it is to install the new keys\n",
        .{ opts.prog_name, new_keys.len },
    );

    if (opts.dry_run) {
        var out_buf: std.ArrayList(u8) = .empty;
        for (new_keys) |k| {
            try out_buf.appendSlice(arena, k);
            try out_buf.append(arena, '\n');
        }
        try writeStdout(io, out_buf.items);
        return 0;
    }

    const ok = if (opts.sftp)
        try installViaSftp(arena, io, opts, new_keys, tmp_dir_path)
    else
        try installViaSsh(arena, io, opts, new_keys);

    if (!ok) return 1;

    try printSummary(io, arena, opts, host, new_keys.len);
    return 0;
}

fn discoverKeys(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    opts: sci.CliOptions,
) !KeyDiscovery {
    switch (opts.identity_mode) {
        .explicit_file => {
            const expanded = try sci.expandTilde(arena, environ_map, opts.identity_file.?);
            const pub_path = try sci.ensurePubSuffix(arena, expanded);
            return loadKeysFromFile(arena, io, opts.prog_name, pub_path);
        },
        .default_file => {
            const def_path = (try sci.findDefaultIdFile(arena, io, environ_map)) orelse return error.NoIdentities;
            return loadKeysFromFile(arena, io, opts.prog_name, def_path);
        },
        .none => {
            if (try querySshAgent(arena, io, opts.trace)) |agent_keys| {
                return .{
                    .keys = agent_keys,
                    .source_label = "ssh-add -L",
                    .single_disk_file = null,
                };
            }
            const def_path = (try sci.findDefaultIdFile(arena, io, environ_map)) orelse return error.NoIdentities;
            return loadKeysFromFile(arena, io, opts.prog_name, def_path);
        },
    }
}

fn querySshAgent(arena: Allocator, io: Io, trace: bool) !?[][]const u8 {
    const argv = &[_][]const u8{ "ssh-add", "-L" };
    if (trace) try traceArgv(io, arena, argv);

    const res = std.process.run(arena, io, .{
        .argv = argv,
    }) catch return null;
    if (!res.term.success()) return null;

    const keys = try sci.parseKeyLines(arena, res.stdout);
    if (keys.len == 0) return null;
    return keys;
}

fn loadKeysFromFile(
    arena: Allocator,
    io: Io,
    prog_name: []const u8,
    path: []const u8,
) !KeyDiscovery {
    const file = openPath(io, path) catch {
        try printStderr(io, arena, "{s}: ERROR: failed to open ID file '{s}': No such file\n", .{ prog_name, path });
        return error.IdentityOpenFailed;
    };
    defer file.close(io);

    const st = try file.stat(io);
    const max_bytes: usize = @intCast(@min(st.size + 4096, 1024 * 1024));
    var reader = file.reader(io, &.{});
    const content = try readAllAlloc(&reader, arena, max_bytes);

    const keys = try sci.parseKeyLines(arena, content);
    if (keys.len == 0) {
        try printStderr(io, arena, "{s}: ERROR: No identities found in {s}\n", .{ prog_name, path });
        return error.IdentityOpenFailed;
    }

    return .{
        .keys = keys,
        .source_label = path,
        .single_disk_file = if (keys.len == 1) path else null,
    };
}

fn openPath(io: Io, path: []const u8) !Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return Io.Dir.openFileAbsolute(io, path, .{});
    }
    return Io.Dir.cwd().openFile(io, path, .{});
}

fn readAllAlloc(file_reader: *Io.File.Reader, allocator: Allocator, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = file_reader.interface.readSliceShort(&chunk) catch |err| switch (err) {
            error.ReadFailed => return file_reader.err.?,
        };
        if (n == 0) break;
        if (out.items.len + n > limit) return error.StreamTooLong;
        try out.appendSlice(allocator, chunk[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

fn filterInstalledKeys(
    arena: Allocator,
    io: Io,
    opts: sci.CliOptions,
    discovered: KeyDiscovery,
    tmp_dir_path: []const u8,
) ![]const []const u8 {
    try printStderr(
        io,
        arena,
        "{s}: INFO: attempting to log in with the new key(s), to filter out any that are already installed\n",
        .{opts.prog_name},
    );

    var tmp_dir = try Io.Dir.openDirAbsolute(io, tmp_dir_path, .{});
    defer tmp_dir.close(io);

    var remaining: std.ArrayList([]const u8) = .empty;

    for (discovered.keys, 0..) |key, idx| {
        const probe_file = if (discovered.single_disk_file != null and idx == 0)
            discovered.single_disk_file.?
        else blk: {
            const fname = try std.fmt.allocPrint(arena, "check_{d}.pub", .{idx});
            const data = try std.fmt.allocPrint(arena, "{s}\n", .{key});
            try tmp_dir.writeFile(io, .{ .sub_path = fname, .data = data });
            break :blk try std.fs.path.join(arena, &.{ tmp_dir_path, fname });
        };

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, "ssh");
        try appendSshCommonOpts(&argv, arena, opts, false);
        try argv.appendSlice(arena, &.{
            "-i",
            probe_file,
            "-o",
            "PreferredAuthentications=publickey",
            "-o",
            "IdentitiesOnly=yes",
            opts.host.?,
            "exit",
        });

        const res = try runCommandInheritStdin(arena, io, argv.items, null, opts.trace);
        if (res.term.success()) continue;

        const combined = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ res.stdout, res.stderr });
        if (sci.isAuthFailureOutput(combined)) {
            try remaining.append(arena, key);
        } else {
            if (res.stderr.len > 0) try writeStderr(io, res.stderr);
            if (res.stdout.len > 0) try writeStderr(io, res.stdout);
            return error.SshProbeFailed;
        }
    }

    return remaining.toOwnedSlice(arena);
}

fn installViaSsh(
    arena: Allocator,
    io: Io,
    opts: sci.CliOptions,
    keys: []const []const u8,
) !bool {
    switch (opts.remote_shell) {
        .auto => {
            const posix_cmd = try sci.buildPosixRemoteCommand(arena, .sh);
            const payload = try sci.buildPosixStdinPayload(arena, opts.target_path, keys);
            const res = try runSshCommand(arena, io, opts, posix_cmd, payload);
            if (res.term.success()) return true;

            const err_text = if (res.stderr.len > 0) res.stderr else res.stdout;
            if (sci.detectRemoteFallback(err_text)) |fallback| {
                switch (fallback) {
                    .powershell, .cmd => {
                        if (try tryInstallWindowsPowerShell(arena, io, opts, keys)) |win_err| {
                            if (fallback == .cmd and sci.containsIgnoreCase(win_err, "'powershell' is not recognized")) {
                                return try installWindowsCmd(arena, io, opts, keys);
                            }
                            try writeStderr(io, win_err);
                            return false;
                        }
                        return true;
                    },
                    .netscreen => return installNetScreen(arena, io, opts, keys),
                    .fish => {
                        const fish_cmd = try sci.buildPosixRemoteCommand(arena, .fish);
                        const fish_res = try runSshCommand(arena, io, opts, fish_cmd, payload);
                        if (fish_res.term.success()) return true;
                        try writeCombinedError(io, fish_res);
                        return false;
                    },
                    else => {},
                }
            }
            try writeCombinedError(io, res);
            return false;
        },
        .sh, .bash, .zsh, .fish => {
            const cmd = try sci.buildPosixRemoteCommand(arena, opts.remote_shell);
            const payload = try sci.buildPosixStdinPayload(arena, opts.target_path, keys);
            const res = try runSshCommand(arena, io, opts, cmd, payload);
            if (res.term.success()) return true;
            try writeCombinedError(io, res);
            return false;
        },
        .powershell, .pwsh => {
            const ps_exe = if (opts.remote_shell == .pwsh) "pwsh" else "powershell";
            const remote_cmd = try std.fmt.allocPrint(arena, "{s} -NoProfile -NonInteractive -Command -", .{ps_exe});
            const ps_script = try sci.buildPowerShellRemoteScript(arena, opts.target_path, keys);
            const res = try runSshCommand(arena, io, opts, remote_cmd, ps_script);
            if (res.term.success()) return true;
            try writeCombinedError(io, res);
            return false;
        },
        .cmd => return installWindowsCmd(arena, io, opts, keys),
        .netscreen => return installNetScreen(arena, io, opts, keys),
    }
}

fn tryInstallWindowsPowerShell(
    arena: Allocator,
    io: Io,
    opts: sci.CliOptions,
    keys: []const []const u8,
) !?[]const u8 {
    const ps_script = try sci.buildPowerShellRemoteScript(arena, opts.target_path, keys);
    const res = try runSshCommand(arena, io, opts, "powershell -NoProfile -NonInteractive -Command -", ps_script);
    if (res.term.success()) return null;

    const err_text = if (res.stderr.len > 0) res.stderr else res.stdout;
    if (sci.containsIgnoreCase(err_text, "'powershell' is not recognized") or
        sci.containsIgnoreCase(err_text, "The term 'powershell' is not recognized"))
    {
        const pwsh_res = try runSshCommand(arena, io, opts, "pwsh -NoProfile -NonInteractive -Command -", ps_script);
        if (pwsh_res.term.success()) return null;
        return if (pwsh_res.stderr.len > 0) pwsh_res.stderr else pwsh_res.stdout;
    }
    return err_text;
}

fn installWindowsCmd(
    arena: Allocator,
    io: Io,
    opts: sci.CliOptions,
    keys: []const []const u8,
) !bool {
    const cmd_str = try sci.buildCmdRemoteCommand(arena, opts.target_path, keys);
    const res = try runSshCommand(arena, io, opts, cmd_str, null);
    if (res.term.success()) return true;
    try writeCombinedError(io, res);
    return false;
}

fn installNetScreen(
    arena: Allocator,
    io: Io,
    opts: sci.CliOptions,
    keys: []const []const u8,
) !bool {
    const cmds = try sci.buildNetScreenCommands(arena, keys);
    if (cmds.len == 0) {
        try printStderr(io, arena, "{s}: ERROR: NetScreen targets only support ssh-dss keys\n", .{opts.prog_name});
        return false;
    }
    for (cmds) |cmd| {
        const res = try runSshCommand(arena, io, opts, cmd, null);
        if (!res.term.success()) {
            try writeCombinedError(io, res);
            return false;
        }
    }
    return true;
}

fn installViaSftp(
    arena: Allocator,
    io: Io,
    opts: sci.CliOptions,
    keys: []const []const u8,
    tmp_dir_path: []const u8,
) !bool {
    const dl_path_raw = try std.fs.path.join(arena, &.{ tmp_dir_path, "remote_authorized_keys" });
    const ul_path_raw = try std.fs.path.join(arena, &.{ tmp_dir_path, "upload_authorized_keys" });
    const dl_path = try normalizeSlashes(arena, dl_path_raw);
    const ul_path = try normalizeSlashes(arena, ul_path_raw);
    const target_norm = try normalizeSlashes(arena, opts.target_path);

    var sftp_argv: std.ArrayList([]const u8) = .empty;
    try sftp_argv.append(arena, "sftp");
    try appendSshCommonOpts(&sftp_argv, arena, opts, true);
    try sftp_argv.append(arena, opts.host.?);

    const get_batch = try std.fmt.allocPrint(arena, "-get \"{s}\" \"{s}\"\n", .{ target_norm, dl_path });
    const get_res = try runCommandInheritStdin(arena, io, sftp_argv.items, get_batch, opts.trace);
    if (!get_res.term.success()) {
        try writeCombinedError(io, get_res);
        return false;
    }

    var existing: []const u8 = "";
    if (Io.Dir.openFileAbsolute(io, dl_path_raw, .{})) |dl_file| {
        defer dl_file.close(io);
        var reader = dl_file.reader(io, &.{});
        existing = readAllAlloc(&reader, arena, 1024 * 1024) catch "";
    } else |_| {}

    const merged = try sci.mergeAuthorizedKeys(arena, existing, keys, opts.force);
    var tmp_dir = try Io.Dir.openDirAbsolute(io, tmp_dir_path, .{});
    defer tmp_dir.close(io);
    try tmp_dir.writeFile(io, .{ .sub_path = "upload_authorized_keys", .data = merged });

    var put_batch: std.ArrayList(u8) = .empty;
    if (std.mem.lastIndexOfScalar(u8, target_norm, '/')) |slash| {
        const parent = target_norm[0..slash];
        if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
            try put_batch.appendSlice(arena, try std.fmt.allocPrint(arena, "-mkdir \"{s}\"\n-chmod 700 \"{s}\"\n", .{ parent, parent }));
        }
    }
    try put_batch.appendSlice(arena, try std.fmt.allocPrint(arena, "put \"{s}\" \"{s}\"\n-chmod 600 \"{s}\"\n", .{ ul_path, target_norm, target_norm }));

    const put_res = try runCommandInheritStdin(arena, io, sftp_argv.items, put_batch.items, opts.trace);
    if (!put_res.term.success()) {
        try writeCombinedError(io, put_res);
        return false;
    }
    return true;
}

fn normalizeSlashes(allocator: Allocator, path: []const u8) ![]u8 {
    const dup = try allocator.dupe(u8, path);
    for (dup) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return dup;
}

fn runSshCommand(
    arena: Allocator,
    io: Io,
    opts: sci.CliOptions,
    remote_cmd: []const u8,
    stdin_payload: ?[]const u8,
) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "ssh");
    try appendSshCommonOpts(&argv, arena, opts, false);
    try argv.append(arena, opts.host.?);
    try argv.append(arena, remote_cmd);
    return runCommandInheritStdin(arena, io, argv.items, stdin_payload, opts.trace);
}

fn appendSshCommonOpts(
    argv: *std.ArrayList([]const u8),
    arena: Allocator,
    opts: sci.CliOptions,
    is_sftp: bool,
) !void {
    if (opts.port) |p| {
        try argv.append(arena, if (is_sftp) "-P" else "-p");
        try argv.append(arena, p);
    }
    if (opts.config_file) |cfg| {
        try argv.append(arena, "-F");
        try argv.append(arena, cfg);
    }
    for (opts.ssh_options) |o| {
        try argv.append(arena, "-o");
        try argv.append(arena, o);
    }
}

fn runCommandInheritStdin(
    arena: Allocator,
    io: Io,
    argv: []const []const u8,
    stdin_payload: ?[]const u8,
    trace: bool,
) !std.process.RunResult {
    if (trace) try traceArgv(io, arena, argv);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (stdin_payload != null) .pipe else .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    if (stdin_payload) |payload| {
        if (child.stdin) |*sin| {
            sin.writeStreamingAll(io, payload) catch {};
            sin.close(io);
            child.stdin = null;
        }
    }

    var multi_buf: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(arena, io, multi_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const out_slice = try multi_reader.toOwnedSlice(0);
    const err_slice = try multi_reader.toOwnedSlice(1);
    return .{
        .term = term,
        .stdout = out_slice,
        .stderr = err_slice,
    };
}

fn traceArgv(io: Io, arena: Allocator, argv: []const []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "+");
    for (argv) |a| {
        try buf.append(arena, ' ');
        try buf.appendSlice(arena, a);
    }
    try buf.append(arena, '\n');
    try writeStderr(io, buf.items);
}

fn printSummary(
    io: Io,
    arena: Allocator,
    opts: sci.CliOptions,
    host: []const u8,
    added_count: usize,
) !void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\nNumber of key(s) added: {d}\n\nNow try logging into the machine, with:   \"ssh", .{added_count}));
    if (opts.port) |p| {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, " -p '{s}'", .{p}));
    }
    if (opts.config_file) |cfg| {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, " -F '{s}'", .{cfg}));
    }
    for (opts.ssh_options) |o| {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, " -o '{s}'", .{o}));
    }
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, " '{s}'\"\nand check to make sure that only the key(s) you wanted were added.\n\n", .{host}));
    try writeStdout(io, out.items);
}

fn writeCombinedError(io: Io, res: std.process.RunResult) !void {
    if (res.stderr.len > 0) try writeStderr(io, res.stderr);
    if (res.stdout.len > 0) try writeStderr(io, res.stdout);
}

fn cleanupTempDir(io: Io, abs_path: []const u8) void {
    const parent = std.fs.path.dirname(abs_path) orelse return;
    const base = std.fs.path.basename(abs_path);
    var parent_dir = Io.Dir.openDirAbsolute(io, parent, .{}) catch return;
    defer parent_dir.close(io);
    parent_dir.deleteTree(io, base) catch {};
}

fn writeStdout(io: Io, text: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var fw: Io.File.Writer = .init(.stdout(), io, &buf);
    try fw.interface.writeAll(text);
    try fw.interface.flush();
}

fn writeStderr(io: Io, text: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var fw: Io.File.Writer = .init(.stderr(), io, &buf);
    try fw.interface.writeAll(text);
    try fw.interface.flush();
}

fn printStderr(io: Io, allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    try writeStderr(io, msg);
}

test "main module builds cleanly" {
    _ = sci;
}


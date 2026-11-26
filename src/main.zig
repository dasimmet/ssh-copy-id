const std = @import("std");
const Io = std.Io;
const sci = @import("ssh_copy_id");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    const parsed = try sci.parseArgs(arena, args);
    const opts = switch (parsed) {
        .help => {
            try writeAllStdout(io, sci.help_text);
            return 0;
        },
        .err => |msg| {
            const prog = if (args.len > 0 and args[0].len > 0) sci.pathBasename(args[0]) else "ssh-copy-id";
            try printStderr(io, arena, "{s}: ERROR: {s}\n{s}", .{ prog, msg, sci.usage_text });
            return 1;
        },
        .ok => |o| o,
    };

    const shell_inv = try sci.resolveShell(arena, io, init.environ_map, opts.shell_override);

    const tmp_dir_path = try sci.createUniqueTempDir(arena, io, init.environ_map);
    defer cleanupTempDir(io, tmp_dir_path);

    var tmp_dir = try Io.Dir.openDirAbsolute(io, tmp_dir_path, .{});
    defer tmp_dir.close(io);

    const script_name = shell_inv.kind.scriptFileName();
    const script_perms: Io.File.Permissions = if (comptime std.posix.mode_t != u0)
        .fromMode(0o700)
    else
        .default_file;

    try tmp_dir.writeFile(io, .{
        .sub_path = script_name,
        .data = shell_inv.kind.embeddedScript(),
        .flags = .{ .permissions = script_perms },
    });

    const script_path = try std.fs.path.join(arena, &.{ tmp_dir_path, script_name });
    var child_env = try sci.buildChildEnviron(arena, init.environ_map, opts, tmp_dir_path);
    defer child_env.deinit();

    var argv_buf: [6][]const u8 = undefined;
    const argv = sci.buildShellArgv(shell_inv.kind, shell_inv.exe_path, script_path, &argv_buf);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &child_env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        try printStderr(io, arena, "{s}: ERROR: failed to launch shell '{s}': {s}\n", .{
            opts.prog_name,
            shell_inv.exe_path,
            @errorName(err),
        });
        return 1;
    };

    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        .signal => 1,
        .stopped => 1,
        .unknown => 1,
    };
}

fn cleanupTempDir(io: Io, abs_path: []const u8) void {
    const parent = std.fs.path.dirname(abs_path) orelse return;
    const base = std.fs.path.basename(abs_path);
    var parent_dir = Io.Dir.openDirAbsolute(io, parent, .{}) catch return;
    defer parent_dir.close(io);
    parent_dir.deleteTree(io, base) catch {};
}

fn writeAllStdout(io: Io, text: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var fw: Io.File.Writer = .init(.stdout(), io, &buf);
    try fw.interface.writeAll(text);
    try fw.interface.flush();
}

fn printStderr(io: Io, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    var buf: [1024]u8 = undefined;
    var fw: Io.File.Writer = .init(.stderr(), io, &buf);
    try fw.interface.writeAll(msg);
    try fw.interface.flush();
}

test "main module builds cleanly" {
    _ = sci;
}

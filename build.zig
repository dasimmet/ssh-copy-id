const std = @import("std");
const manifest = @import("build.zig.zon");

fn resolveVersion(b: *std.Build) ![]const u8 {
    if (b.option([]const u8, "version-string", "Override version string")) |v| {
        return v;
    }
    const base_version = manifest.version;
    const run_opts: std.Build.RunOptions = .{
        .stderr_behavior = .ignore,
        .cwd = .{ .dir = b.root.root_dir.handle },
    };

    switch (b.runFallible(&.{
        "git", "describe", "--match", "*.*.*", "--tags", "--abbrev=9",
    }, run_opts)) {
        .success => |stdout| {
            const raw = std.mem.trim(u8, stdout, " \n\r");
            const normalized = if (std.mem.startsWith(u8, raw, "v")) raw[1..] else raw;

            if (std.mem.lastIndexOfScalar(u8, normalized, '-')) |hash_dash| {
                const hash_part = normalized[hash_dash + 1 ..];
                const before_hash = normalized[0..hash_dash];
                if (hash_part.len > 1 and hash_part[0] == 'g') {
                    if (std.mem.lastIndexOfScalar(u8, before_hash, '-')) |height_dash| {
                        const commit_height = before_hash[height_dash + 1 ..];
                        const tagged_ancestor = before_hash[0..height_dash];
                        if (isAllDigits(commit_height)) {
                            const ancestor_sem = std.SemanticVersion.parse(tagged_ancestor) catch null;
                            const base_sem = std.SemanticVersion.parse(base_version) catch null;
                            const dev_base = if (ancestor_sem != null and base_sem != null and
                                ancestor_sem.?.order(base_sem.?) == .lt)
                                base_version
                            else
                                tagged_ancestor;
                            return b.fmt("{s}-dev.{s}+{s}", .{ dev_base, commit_height, hash_part[1..] });
                        }
                    }
                }
            }
            return normalized;
        },
        else => {},
    }

    const rev_res = b.runFallible(&.{
        "git", "rev-parse", "--short=9", "HEAD",
    }, run_opts);
    if (rev_res == .success) {
        const short_hash = std.mem.trim(u8, rev_res.success, " \n\r");
        const count_res = b.runFallible(&.{
            "git", "rev-list", "--count", "HEAD",
        }, run_opts);
        if (count_res == .success) {
            const commit_height = std.mem.trim(u8, count_res.success, " \n\r");
            return b.fmt("{s}-dev.{s}+{s}", .{ base_version, commit_height, short_hash });
        }
        return b.fmt("{s}-dev+{s}", .{ base_version, short_hash });
    }

    return base_version;
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = try resolveVersion(b);
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const mod = b.addModule("ssh_copy_id", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "ssh-copy-id",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "ssh_copy_id", .module = mod },
            },
        }),
    });
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run ssh-copy-id");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}


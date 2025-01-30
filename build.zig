const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
    });

    const raylib_artifact = raylib_dep.artifact("raylib");

    const gen_exports_exe = b.addExecutable(.{
        .name = "gen_exports",
        .root_source_file = b.path("gen_exports.zig"),
        .optimize = optimize,
        .target = target,
    });

    const gen_level_exports = b.addRunArtifact(gen_exports_exe);
    gen_level_exports.addDirectoryArg(b.path("levels"));
    const levels_file = gen_level_exports.addOutputFileArg("levels.zig");

    //const levels = try std.fs.cwd().openDir("levels", .{});
    //var walker = try levels.walk(b.allocator);
    //defer walker.deinit();
    //while (try walker.next()) |e| {
    //    if (e.kind != .file) continue;
    //    if (!std.mem.endsWith(u8, e.basename, ".zig")) continue;
    //}

    const exe = b.addExecutable(.{
        .name = "slet",
        .root_source_file = b.path("main.zig"),
        .optimize = optimize,
        .target = target,
    });
    exe.step.dependOn(&b.addInstallFile(levels_file, "levels.zig").step);
    exe.linkLibrary(raylib_artifact);

    const runa = b.addRunArtifact(exe);
    const runnner = b.step("run", "run the game");
    runnner.dependOn(&runa.step);

    b.installArtifact(exe);

    const tester = b.step("test", "run tests");
    tester.dependOn(&exe.step);
}

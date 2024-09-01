const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
        .linux_display_backend = .Both,
    });

    const raylib_artifact = raylib_dep.artifact("raylib");

    const exe = b.addExecutable(.{
        .name = "slet",
        .root_source_file = b.path("main.zig"),
        .optimize = optimize,
        .target = target,
    });
    exe.linkLibrary(raylib_artifact);

    const runa = b.addRunArtifact(exe);
    const runnner = b.step("run", "run the game");
    runnner.dependOn(&runa.step);

    b.installArtifact(exe);

    const tester = b.step("test", "run tests");
    tester.dependOn(&exe.step);
}

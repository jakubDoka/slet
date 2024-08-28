const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib-zig", .{
        .target = target,
        .optimize = optimize,
    });

    const raylib = raylib_dep.module("raylib");
    const rlgl = raylib_dep.module("rlgl");
    const raylib_artifact = raylib_dep.artifact("raylib");

    const exe = b.addExecutable(.{
        .name = "slet",
        .root_source_file = b.path("main.zig"),
        .optimize = optimize,
        .target = target,
    });
    exe.linkLibC();
    exe.linkLibrary(raylib_artifact);
    exe.root_module.addImport("raylib", raylib);
    exe.root_module.addImport("rlgl", rlgl);

    const runa = b.addRunArtifact(exe);
    const runnner = b.step("run", "run the game");
    runnner.dependOn(&runa.step);

    b.installArtifact(exe);

    const tester = b.step("test", "run tests");
    tester.dependOn(&exe.step);
}

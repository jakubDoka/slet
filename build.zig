const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
        .linux_display_backend = .X11,
        .config = @as([]const u8, "-Draylib_USE_STATIC_LIBS"),
    });

    const raylib_linux_dep = b.dependency("raylib", .{
        .target = b.graph.host,
        .optimize = .Debug,
    });

    const raylib_artifact = raylib_dep.artifact("raylib");
    raylib_artifact.addLibraryPath(b.path("assets/lib"));
    raylib_artifact.addIncludePath(b.path("assets/include"));
    const raylib_linux_artifact = raylib_linux_dep.artifact("raylib");

    const gen_exports_exe = b.addExecutable(.{
        .name = "gen_exports",
        .root_source_file = b.path("gen_exports.zig"),
        .optimize = .Debug,
        .target = b.graph.host,
    });

    const gen_level_exports = b.addRunArtifact(gen_exports_exe);
    gen_level_exports.addDirectoryArg(b.path("levels"));
    gen_level_exports.has_side_effects = true;
    const levels_file = gen_level_exports.addOutputFileArg("levels.zig");

    const gen_sprite_sheet_exe = b.addExecutable(.{
        .name = "gen_sheet",
        .root_source_file = b.path("gen_sheet.zig"),
        .optimize = .Debug,
        .target = b.graph.host,
    });
    gen_sprite_sheet_exe.linkLibrary(raylib_linux_artifact);

    const gen_sprite_sheet = b.addRunArtifact(gen_sprite_sheet_exe);
    gen_sprite_sheet.addDirectoryArg(b.path("assets/textures"));
    gen_sprite_sheet.has_side_effects = true;
    const sheet_image_file = gen_sprite_sheet.addOutputFileArg("sheet_image.png");
    const sheet_frames_file = gen_sprite_sheet.addOutputFileArg("sheet_frames.zig");

    const exe = b.addExecutable(.{
        .name = "slet",
        .root_source_file = b.path("main.zig"),
        .optimize = optimize,
        .target = target,
    });

    exe.step.dependOn(&b.addInstallFile(levels_file, "levels.zig").step);
    exe.step.dependOn(&b.addInstallFile(sheet_image_file, "sheet_image.png").step);
    exe.step.dependOn(&b.addInstallFile(sheet_frames_file, "sheet_frames.zig").step);
    exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/" });
    //exe.addIncludePath(.{ .cwd_relative = "/usr/include/" });
    exe.linkLibrary(raylib_artifact);

    const runa = b.addRunArtifact(exe);
    const runnner = b.step("run", "run the game");
    runnner.dependOn(&runa.step);

    b.installArtifact(exe);

    const tester = b.step("test", "run tests");
    tester.dependOn(&exe.step);
}

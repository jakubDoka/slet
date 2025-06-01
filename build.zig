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
    raylib_artifact.addLibraryPath(b.path("src/assets/lib"));
    raylib_artifact.addIncludePath(b.path("src/assets/include"));
    const raylib_linux_artifact = raylib_linux_dep.artifact("raylib");

    const rl = b.createModule(.{
        .root_source_file = b.path("src/rl.zig"),
        .target = target,
        .optimize = optimize,
    });

    const resources = b.createModule(.{
        .root_source_file = b.path("src/resources.zig"),
        .target = target,
        .optimize = optimize,
    });
    resources.addImport("rl", rl);

    const gen_sprite_sheet_exe = b.addExecutable(.{
        .name = "gen_sheet",
        .root_source_file = b.path("scripts/gen_sheet.zig"),
        .optimize = .Debug,
        .target = b.graph.host,
    });
    gen_sprite_sheet_exe.linkLibrary(raylib_linux_artifact);
    gen_sprite_sheet_exe.root_module.addImport("resources", resources);
    gen_sprite_sheet_exe.root_module.addImport("rl", rl);

    const gen_sprite_sheet = b.addRunArtifact(gen_sprite_sheet_exe);
    gen_sprite_sheet.addDirectoryArg(b.path("src/assets/textures"));
    gen_sprite_sheet.has_side_effects = true;
    const sheet_image_file = gen_sprite_sheet.addOutputFileArg("sheet_image.png");
    const sheet_frames_file = gen_sprite_sheet.addOutputFileArg("sheet_frames.zig");

    const exe = b.addExecutable(.{
        .name = "slet",
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
    });

    exe.root_module.addImport("rl", rl);
    exe.root_module.addImport("resources", resources);
    exe.root_module.addAnonymousImport("sheet_frames", .{
        .root_source_file = sheet_frames_file,
        .imports = &.{.{ .name = "rl", .module = rl }},
    });
    exe.root_module.addAnonymousImport("sheet_image", .{ .root_source_file = sheet_image_file });

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

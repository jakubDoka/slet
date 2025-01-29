pub const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
    @cInclude("rlgl.h");
});

const std = @import("std");
const ecs = @import("ecs.zig");
const vec = @import("vec.zig");
const engine = @import("engine.zig");
const assets = @import("assets.zig");

const Id = ecs.Id;
const Vec = vec.T;
const Quad = @import("QuadTree.zig");
const Level1 = @import("Level1.zig");

pub fn main() !void {
    rl.SetConfigFlags(rl.FLAG_FULLSCREEN_MODE);
    rl.SetTargetFPS(60);

    rl.InitWindow(0, 0, "slet");
    defer rl.CloseWindow();

    var alloc = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.c_allocator,
    };
    defer _ = alloc.deinit();

    //var ent = ecs.World(Spec.Ents){ .gpa = alloc.allocator() };
    //const foo = ent.add(.player, .{});
    //_ = foo; // autofix

    var level = engine.level(Level1, alloc.allocator());
    defer level.deinit();
    level.run();
}

pub inline fn tof(value: anytype) f32 {
    return @floatFromInt(value);
}

pub fn divToFloat(a: anytype, b: @TypeOf(a)) f32 {
    return @as(f32, @floatFromInt(a)) / @as(f32, @floatFromInt(b));
}

pub fn fcolor(r: f32, g: f32, b: f32) rl.Color {
    return .{
        .r = @intFromFloat(r * 255),
        .g = @intFromFloat(g * 255),
        .b = @intFromFloat(b * 255),
        .a = 255,
    };
}

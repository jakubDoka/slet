const std = @import("std");
const rl = @import("raylib");
const ecs = @import("ecs.zig");
const QuadTree = @import("QuadTree.zig");
const Game = @import("Game.zig");
//const resources = @import("resources.zig");

pub fn main() !void {
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = alloc.deinit();

    const alc = alloc.allocator();

    var game = Game{};
    defer game.deinit(alc);

    try game.initStateForNow(alc);

    const screenWidth = 800;
    const screenHeight = 600;

    rl.setConfigFlags(.{ .window_resizable = true });
    rl.setTargetFPS(60);

    rl.initWindow(screenWidth, screenHeight, "slet");
    defer rl.closeWindow();

    while (!rl.windowShouldClose()) {
        try game.update(alc);
        try game.input(alc);
        try game.draw(alc);
    }
}

test {
    //std.testing.refAllDeclsRecursive(resources);
}

// raylib-zig (c) Nikolas Wipper 2023

const std = @import("std");
const rl = @import("raylib");
const ecs = @import("ecs.zig");
const QuadTree = @import("QuadTree.zig");
const Game = @import("Game.zig");

pub fn main() !void {
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = alloc.deinit();

    const alc = alloc.allocator();

    var game = Game{};
    defer game.deinit(alc);

    try game.initStateForNow(alc);

    const screenWidth = 800;
    const screenHeight = 450;

    rl.initWindow(screenWidth, screenHeight, "slet");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    while (!rl.windowShouldClose()) {
        try game.update(alc);
        game.input();
        try game.draw(alc);
    }
}

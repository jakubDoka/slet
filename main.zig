const std = @import("std");
const rl = @import("raylib");
const Game = @import("Game.zig");

pub fn main() !void {
    rl.setConfigFlags(.{ .fullscreen_mode = true });
    rl.setTargetFPS(60);

    rl.initWindow(800, 600, "slet");
    defer rl.closeWindow();

    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = alloc.deinit();

    var game = try Game.init(alloc.allocator());
    defer game.deinit();

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        try game.input();
        try game.update();
        try game.draw();
    }
}

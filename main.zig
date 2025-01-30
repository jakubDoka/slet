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
const levels = @import("zig-out/levels.zig");

const Id = ecs.Id;
const Vec = vec.T;
const Quad = @import("QuadTree.zig");

const UiTextures = struct {};

const State = union(enum) {
    Levels: void,
    Playing: Level,
};

pub fn main() !void {
    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
    rl.SetTargetFPS(60);

    rl.InitWindow(800, 600, "slet");
    defer rl.CloseWindow();

    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = alloc.deinit();

    var state = State{ .Levels = {} };

    b: while (!rl.WindowShouldClose()) switch (state) {
        .Levels => {
            rl.BeginDrawing();
            defer rl.EndDrawing();
            rl.ClearBackground(rl.BLACK);
            const mouse_pos = vec.fromRl(rl.GetMousePosition());
            var cursor = vec.splat(10);
            const font_size, const padding, const margin, const spacing = .{ 25, 10, 10, 2 };
            for (Level.list) |l| {
                const text_size = vec.fromRl(rl.MeasureTextEx(rl.GetFontDefault(), l.name, font_size, spacing));
                const size = text_size + vec.splat(padding * 2);
                const text_pos = cursor + vec.splat(padding);

                var color = rl.GRAY;
                if (@reduce(.And, mouse_pos >= cursor) and @reduce(.And, mouse_pos <= cursor + size)) {
                    if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
                        state = .{ .Playing = l };
                        continue :b;
                    } else {
                        color = rl.BROWN;
                    }
                }

                rl.DrawRectangleV(vec.asRl(cursor), vec.asRl(size), color);
                rl.DrawTextEx(rl.GetFontDefault(), l.name, vec.asRl(text_pos), font_size, spacing, rl.WHITE);
                cursor[0] += size[0] + margin;
            }
        },
        .Playing => |l| {
            l.run(alloc.allocator());
            // reset rl.WindowShouldClose
            rl.BeginDrawing();
            rl.EndDrawing();
            state = .{ .Levels = {} };
        },
    };
}

const Level = struct {
    name: [:0]const u8,
    run: *const fn (std.mem.Allocator) void,

    const order = .{
        "Deflector",
        "DodgeGun",
    };

    const list = b: {
        const decls = @typeInfo(levels).Struct.decls;
        std.debug.assert(decls.len == order.len);

        var mem: [decls.len]Level = undefined;
        for (order, &mem) |dname, *l| {
            const name = n: {
                var buf: [64]u8 = undefined;
                var i = 0;
                for (dname) |c| {
                    if (std.ascii.isUpper(c) and i != 0) {
                        buf[i] = ' ';
                        i += 1;
                    }
                    buf[i] = std.ascii.toLower(c);
                    i += 1;
                }
                buf[i] = 0;
                break :n buf[0..i] ++ "";
            };

            l.* = .{
                .name = name,
                .run = struct {
                    fn run(gpa: std.mem.Allocator) void {
                        var level = engine.level(@field(levels, dname), gpa);
                        defer level.deinit();
                        level.run();
                    }
                }.run,
            };
        }

        break :b mem;
    };
};

const rl = @import("rl.zig").rl;
const std = @import("std");
const ecs = @import("ecs.zig");
const vec = @import("vec.zig");
const engine = @import("engine.zig");
const levels = @import("zig-out/levels.zig");
pub const frames = @import("zig-out/sheet_frames.zig");

const Id = ecs.Id;
const Vec = vec.T;
const Quad = @import("QuadTree.zig");

const UiTextures = struct {};

const State = union(enum) {
    Levels: void,
    Playing: *Level,
};

pub var sheet: rl.Texture2D = undefined;

pub fn main() !void {
    const SaveData = [Level.list.len]struct { no_hit: bool, best_time: u32 };
    b: {
        const save_file = std.fs.cwd().readFileAlloc(std.heap.page_allocator, "slet_scores.json", 1024 * 20) catch break :b;
        const save_data = std.json.parseFromSliceLeaky(
            SaveData,
            std.heap.page_allocator,
            save_file,
            .{},
        ) catch break :b;
        for (save_data, &Level.list) |s, *l| {
            l.no_hit = s.no_hit;
            l.best_time = s.best_time;
        }
    }

    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
    rl.SetTargetFPS(60);

    rl.InitWindow(800, 600, "slet");
    defer rl.CloseWindow();

    const sheet_data = @embedFile("zig-out/sheet_image.png");
    const sheet_image = rl.LoadImageFromMemory(".png", sheet_data.ptr, @intCast(sheet_data.len));
    sheet = rl.LoadTextureFromImage(sheet_image);

    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = alloc.deinit();

    var state = State{ .Levels = {} };

    b: while (!rl.WindowShouldClose()) switch (state) {
        .Levels => {
            rl.BeginDrawing();
            defer rl.EndDrawing();
            rl.ClearBackground(rl.BLACK);
            const mouse_pos = vec.fromRl(rl.GetMousePosition());
            const font_size, const padding, const margin, const spacing = .{ 25, 10, 10, 2 };
            var cursor = vec.splat(10);
            var buf: [128]u8 = undefined;
            for (&Level.list) |*l| {
                var allc = std.heap.FixedBufferAllocator.init(&buf);
                _ = std.fmt.allocPrint(allc.allocator(), "{s}", .{l.name}) catch undefined;
                if (l.best_time != std.math.maxInt(u32))
                    _ = std.fmt.allocPrint(allc.allocator(), " {d}.{d}", .{ l.best_time / 1000, l.best_time % 1000 }) catch undefined;
                allc.buffer[allc.end_index] = 0;
                const name = allc.buffer[0..allc.end_index :0];

                const text_size = vec.fromRl(rl.MeasureTextEx(rl.GetFontDefault(), name, font_size, spacing));
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
                color = rl.WHITE;
                if (l.no_hit) color = rl.GOLD;
                rl.DrawTextEx(rl.GetFontDefault(), name, vec.asRl(text_pos), font_size, spacing, color);
                cursor[0] += size[0] + margin;
            }
        },
        .Playing => |l| {
            l.run(alloc.allocator(), l);

            // reset rl.WindowShouldClose
            rl.BeginDrawing();
            rl.EndDrawing();
            state = .{ .Levels = {} };
        },
    };

    var save_data: SaveData = undefined;
    for (&save_data, Level.list) |*s, l| {
        s.* = .{ .no_hit = l.no_hit, .best_time = l.best_time };
    }

    var save_file = std.fs.cwd().createFile("slet_scores.json", .{}) catch unreachable;
    std.json.stringify(save_data, .{}, save_file.writer()) catch unreachable;
}

pub const Level = struct {
    name: [:0]const u8,
    run: *const fn (std.mem.Allocator, *Level) void,
    no_hit: bool = false,
    best_time: u32 = std.math.maxInt(u32),

    const order = .{
        "Deflector",
        "DodgeGun",
    };

    var list = b: {
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
                    fn run(gpa: std.mem.Allocator, lvl_data: *Level) void {
                        var level = engine.level(@field(levels, dname), gpa, lvl_data);
                        defer level.deinit();
                        level.run();
                    }
                }.run,
            };
        }

        break :b mem;
    };
};

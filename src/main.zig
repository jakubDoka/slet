const rl = @import("rl").rl;
const std = @import("std");
const ecs = @import("ecs.zig");
const vec = @import("vec.zig");
const engine = @import("engine.zig");
pub const frames = @import("sheet_frames");

const Id = ecs.Id;
const Vec = vec.T;
const Quad = @import("QuadTree.zig");

const UiTextures = struct {};

const State = union(enum) {
    Levels: void,
    Playing: *Level,
};

pub var sheet: rl.Texture2D = undefined;
pub var font: rl.Font = undefined;

pub fn main() !void {
    loadGameData();

    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
    rl.SetTargetFPS(61);

    rl.InitWindow(1800, 1000, "slet");
    defer rl.CloseWindow();

    const sheet_data = @embedFile("sheet_image");
    const sheet_image = rl.LoadImageFromMemory(".png", sheet_data.ptr, @intCast(sheet_data.len));
    sheet = rl.LoadTextureFromImage(sheet_image);

    const font_data = @embedFile("assets/fonts/slkscr.ttf");
    font = rl.LoadFontFromMemory(".ttf", font_data.ptr, @intCast(font_data.len), 32, null, 95);

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
            const win_width: f32 = @floatFromInt(rl.GetScreenWidth());
            for (&Level.list) |*l| {
                var allc = std.heap.FixedBufferAllocator.init(&buf);
                _ = std.fmt.allocPrint(allc.allocator(), "{s}", .{l.name}) catch undefined;
                if (l.data.best_time != std.math.maxInt(u32))
                    _ = std.fmt.allocPrint(allc.allocator(), " {d}.{d}", .{ l.data.best_time / 1000, l.data.best_time % 1000 }) catch undefined;
                allc.buffer[allc.end_index] = 0;
                const name = allc.buffer[0..allc.end_index :0];

                const text_size = vec.fromRl(rl.MeasureTextEx(font, name, font_size, spacing));
                const size = text_size + vec.splat(padding * 2);

                if (cursor[0] + size[0] > win_width) {
                    cursor[0] = 10;
                    cursor[1] += size[1] + padding;
                }

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
                if (l.data.no_hit) color = rl.GOLD;
                rl.DrawTextEx(font, name, vec.asRl(text_pos), font_size, spacing, color);
                cursor[0] += size[0] + margin;
            }
        },
        .Playing => |l| {
            l.run(alloc.allocator(), &l.data);

            // reset rl.WindowShouldClose
            rl.BeginDrawing();
            rl.EndDrawing();
            state = .{ .Levels = {} };
        },
    };

    saveGameData();
}

pub const SaveData = struct {
    no_hit: bool = false,
    best_time: u32 = std.math.maxInt(u32),
};

fn loadGameData() void {
    const save_file = std.fs.cwd().readFileAlloc(std.heap.page_allocator, "slet_scores.json", 1024 * 20) catch return;
    const save_data = std.json.parseFromSliceLeaky(
        [Level.list.len]SaveData,
        std.heap.page_allocator,
        save_file,
        .{},
    ) catch return;
    for (save_data, &Level.list) |s, *l| {
        l.data = s;
    }
}

fn saveGameData() void {
    var save_data: [Level.list.len]SaveData = undefined;
    for (&save_data, Level.list) |*s, l| {
        s.* = l.data;
    }

    var save_file = std.fs.cwd().createFile("slet_scores.json", .{}) catch unreachable;
    std.json.stringify(save_data, .{}, save_file.writer()) catch unreachable;
}

pub const Level = struct {
    name: [:0]const u8,
    run: *const fn (std.mem.Allocator, *SaveData) void,
    data: SaveData = .{},

    const order = [_]type{
        @import("levels/Deflector.zig"),
        @import("levels/Ambush.zig"),
        @import("levels/DodgeGun.zig"),
        @import("levels/Covardice.zig"),
        @import("levels/Toreador.zig"),
    };

    var list = b: {
        var mem: [order.len]Level = undefined;
        for (order, &mem) |level_struct, *l| {
            const dname = @typeName(level_struct)["levels.".len..];
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
                    fn run(gpa: std.mem.Allocator, lvl_data: *SaveData) void {
                        var level = engine.level(level_struct, gpa, lvl_data);
                        defer level.deinit();
                        level.run();
                    }
                }.run,
            };
        }

        break :b mem;
    };
};

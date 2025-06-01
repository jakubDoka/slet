const std = @import("std");
const resources = @import("resources");
const rl = @import("rl").rl;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    const dir = args[1];
    const sheet_out = args[2];
    const frames_out = args[3];

    const levels = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    var names = std.ArrayList([:0]const u8).init(arena);
    var images = std.ArrayList(rl.Image).init(arena);
    var walker = try levels.walk(arena);
    defer walker.deinit();
    while (try walker.next()) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.basename, ".png")) continue;
        try names.append(try arena.dupeZ(u8, e.basename[0 .. e.basename.len - 4]));
        const canon = try levels.readFileAlloc(arena, e.basename, 1024 * 12);
        try images.append(rl.LoadImageFromMemory(".png", canon.ptr, @intCast(canon.len)));
    }

    const shadow_res = 32;
    var img = rl.GenImageColor(shadow_res, shadow_res, .{});
    const center = rl.Vector2{ .x = shadow_res / 2, .y = shadow_res / 2 };

    for (0..shadow_res) |x| for (0..shadow_res) |y| {
        const pos = rl.Vector2{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
        const dist = @max(1 - std.math.pow(f32, rl.Vector2Distance(center, pos) / (shadow_res / 2), 3), 0);
        rl.ImageDrawPixel(&img, @intCast(x), @intCast(y), rl.ColorAlpha(rl.BLACK, dist));
    };

    try images.append(img);
    try names.append("shadow");

    const frames = try arena.alloc(resources.sprites.Frame, images.items.len);
    const image = try resources.sprites.pack(arena, images.items, frames, 128);

    var size: c_int = undefined;
    const sheet_data = rl.ExportImageToMemory(image, ".png", &size)[0..@intCast(size)];

    try std.fs.cwd().writeFile(.{ .sub_path = sheet_out, .data = sheet_data });

    var out_file = try std.fs.cwd().createFile(frames_out, .{});
    defer out_file.close();
    const writer = out_file.writer();

    try writer.print("const rl = @import(\"rl\").rl;\n", .{});
    for (names.items, frames) |n, f| {
        const rect = f.r.f;
        try writer.print(
            "pub const {s} = rl.Rectangle{{ .x = {d}, .y = {d}, .width = {d}, .height = {d} }};\n",
            .{ n, rect.x, rect.y, rect.width, rect.height },
        );
    }
}

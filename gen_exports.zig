const std = @import("std");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    const dir = args[1];
    const out = args[2];

    var out_file = try std.fs.cwd().createFile(out, .{});
    defer out_file.close();
    const writer = out_file.writer();

    const levels = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    var walker = try levels.walk(arena);
    defer walker.deinit();
    while (try walker.next()) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.basename, ".zig")) continue;
        try writer.print("pub const {s} = @import(\"../levels/{s}\");\n", .{ e.basename[0 .. e.basename.len - ".zig".len], e.basename });
    }
}

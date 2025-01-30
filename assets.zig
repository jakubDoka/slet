const std = @import("std");
const resources = @import("resources.zig");
const rl = @import("main.zig").rl;

pub const Frame = rl.Rectangle;

pub fn initTextures(self: anytype, gpa: std.mem.Allocator, sheet_size: u32) !rl.Texture2D {
    const info = @typeInfo(@TypeOf(self.*)).Struct;
    var images: [info.fields.len]rl.Image = undefined;
    inline for (info.fields, &images) |field, *i| {
        const data = @embedFile("assets/" ++ field.name ++ ".png");
        i.* = rl.LoadImageFromMemory(".png", data, data.len);
    }

    defer for (images) |i| rl.UnloadImage(i);

    var frames: [info.fields.len]resources.sprites.Frame = undefined;
    const sheet = try resources.sprites.pack(gpa, &images, &frames, sheet_size);

    const frame_view: *[info.fields.len]Frame = @ptrCast(self);

    for (frame_view, frames) |*d, f| d.* = f.r.f;

    return sheet;
}

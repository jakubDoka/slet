const rl = @import("raylib");
const std = @import("std");

pub const SpriteSheet = struct {
    texture: rl.Texture2D,
    frames: []TexturePacker.Frame,

    pub fn init(alc: std.mem.Allocator, textures: []const rl.Image) !SpriteSheet {
        const big_enough = 1 << 12;
        var texture = rl.Image.genColor(big_enough, big_enough, rl.Color.blank);
        defer texture.unload();

        var packer = try TexturePacker.init(alc, big_enough);
        defer packer.deinit(alc);

        var frames = try alc.alloc(TexturePacker.Frame, textures.len);
        errdefer alc.free(frames);

        for (frames, textures) |*frame, tex|
            frame.* = .{ .width = @intCast(tex.width), .height = @intCast(tex.height) };

        try packer.pack(frames);

        for (frames, textures) |*frame, tex| {
            const src = rl.Rectangle{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(frame.width),
                .height = @floatFromInt(frame.height),
            };
            const dest = rl.Rectangle{
                .x = @floatFromInt(frame.x),
                .y = @floatFromInt(frame.y),
                .width = @floatFromInt(frame.width),
                .height = @floatFromInt(frame.height),
            };
            texture.drawImage(tex, src, dest, rl.Color.white);
        }

        return SpriteSheet{
            .texture = rl.Texture.fromImage(texture),
            .frames = frames,
        };
    }

    pub fn deinit(self: *SpriteSheet, alc: std.mem.Allocator) void {
        alc.free(self.frames);
        self.texture.unload();
        self.* = undefined;
    }
};

pub const TexturePacker = struct {
    pub const Frame = struct {
        x: u32 = undefined,
        y: u32 = undefined,
        width: u32,
        height: u32,
        id: u32 = undefined,

        fn byArea(_: void, a: Frame, b: Frame) bool {
            return (b.width * b.height) < (a.width * a.height);
        }

        fn byId(_: void, a: Frame, b: Frame) bool {
            return a.id < b.id;
        }
    };

    taken_set: std.DynamicBitSetUnmanaged,
    size: usize,

    pub fn init(gpa: std.mem.Allocator, size: usize) !TexturePacker {
        return TexturePacker{
            .size = size,
            .taken_set = try std.DynamicBitSetUnmanaged.initEmpty(gpa, size * size),
        };
    }

    pub fn deinit(self: *TexturePacker, gpa: std.mem.Allocator) void {
        self.taken_set.deinit(gpa);
        self.* = undefined;
    }

    pub fn pack(self: *TexturePacker, frames: []Frame) !void {
        for (frames, 0..) |*frame, i| frame.id = @intCast(i);
        std.sort.pdq(Frame, frames, {}, Frame.byArea);
        defer std.sort.pdq(Frame, frames, {}, Frame.byId);

        m: for (frames) |*frame| {
            var iter = self.taken_set.iterator(.{ .kind = .unset });
            o: while (iter.next()) |pos| {
                const x = pos % self.size;
                const y = pos / self.size;

                if (x + frame.width > self.size or y + frame.height > self.size) continue :o;

                for ([_]usize{ y, y + frame.height - 1 }) |dy| for (x..x + frame.width) |dx| {
                    if (self.taken_set.isSet(dx + dy * self.size)) continue :o;
                };
                for ([_]usize{ x, x + frame.width - 1 }) |dx| for (y..y + frame.height) |dy| {
                    if (self.taken_set.isSet(dx + dy * self.size)) continue :o;
                };

                frame.x = @intCast(x);
                frame.y = @intCast(y);
                for (y..y + frame.height) |dy| {
                    self.taken_set.setRangeValue(.{
                        .start = x + dy * self.size,
                        .end = x + frame.width + dy * self.size,
                    }, true);
                }

                continue :m;
            }

            return error.OutOfMemory;
        }

        self.taken_set.setRangeValue(.{
            .start = 0,
            .end = self.taken_set.bit_length,
        }, false);
    }
};

test {
    const alc = std.testing.allocator;
    var packer = try TexturePacker.init(alc, 512);
    defer packer.deinit(alc);

    var frames = [_]TexturePacker.Frame{
        .{ .width = 256, .height = 256 },
        .{ .width = 256, .height = 256 },
        .{ .width = 256, .height = 256 },
        .{ .width = 128, .height = 128 },
        .{ .width = 128, .height = 128 },
        .{ .width = 128, .height = 128 },
        .{ .width = 128, .height = 128 },
    };

    try packer.pack(&frames);

    rl.initWindow(0, 0, "");
    defer rl.closeWindow();

    var image_1 = rl.Image.genColor(256, 256, rl.Color.red);
    defer image_1.unload();
    var image_2 = rl.Image.genColor(128, 128, rl.Color.green);
    defer image_2.unload();
    var image_3 = rl.Image.genColor(64, 64, rl.Color.blue);
    defer image_3.unload();
    var image_4 = rl.Image.genColor(32, 32, rl.Color.yellow);
    defer image_4.unload();

    var sheet = try SpriteSheet.init(alc, &.{
        image_1,
        image_2,
        image_3,
        image_4,
    });
    defer sheet.deinit(alc);
}

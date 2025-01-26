pub const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
    @cInclude("rlgl.h");
});

pub fn main() !void {
    try @import("Game.zig").run();
}

pub inline fn tof(value: anytype) f32 {
    return @floatFromInt(value);
}

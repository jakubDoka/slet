gpa: std.mem.Allocator,
world: World = .{},
player: Id,
player_sprite: rl.Texture2D,

const std = @import("std");
const rl = @import("raylib");
const World = @import("ecs.zig").World(comps);
const Quad = @import("QuadTree.zig");
const Game = @This();
const Id = World.Id;

const comps = struct {
    pub const Stats = struct {
        fric: f32 = 0.1,
    };
    pub const Pos = struct { rl.Vector2 };
    pub const Vel = struct { rl.Vector2 };
    pub const Rot = struct { f32 };
};

pub fn init(gpa: std.mem.Allocator) !Game {
    var world = World{};
    return .{
        .player_sprite = rl.loadTexture("player.png"),
        .player = try world.create(gpa, .{
            comps.Stats{},
            comps.Pos{rl.Vector2.init(100, 100)},
            comps.Vel{rl.Vector2.zero()},
        }),
        .gpa = gpa,
        .world = world,
    };
}

pub fn deinit(self: *Game) void {
    self.world.deinit(self.gpa);
    rl.unloadTexture(self.player_sprite);
}

pub fn update(self: *Game) !void {
    _ = self; // autofix
}

pub fn draw(self: *Game) !void {
    {
        const player = self.world.selectOne(self.player, struct { pos: comps.Pos, vel: comps.Vel }) orelse return;
        const scale = 5.0;
        const dir = angleOf(rl.getMousePosition().subtract(player.pos[0]));
        drawCenteredTexture(self.player_sprite, player.pos[0], dir, scale);
    }

    rl.clearBackground(rl.Color.black);
}

inline fn drawCenteredTexture(texture: rl.Texture2D, pos: rl.Vector2, rot: f32, scale: f32) void {
    const real_width = tof(texture.width) * scale;
    const real_height = tof(texture.height) * scale;
    rl.drawTexturePro(
        texture,
        rl.Rectangle.init(0, 0, tof(texture.width), tof(texture.height)),
        rl.Rectangle.init(pos.x, pos.y, real_width, real_height),
        rl.Vector2.init(real_width / 2, real_height / 2),
        rot / std.math.tau * 360,
        rl.Color.white,
    );
}

inline fn angleOf(v: rl.Vector2) f32 {
    return std.math.atan2(v.y, v.x);
}

inline fn tof(value: anytype) f32 {
    return @floatFromInt(value);
}
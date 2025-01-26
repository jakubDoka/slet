const vec = @import("vec.zig");
const Vec = vec.T;
const Game = @import("Game.zig");
const rl = @import("main.zig").rl;
const assets = @import("assets.zig");
const cms = Game.cms;
const std = @import("std");
const ParticleStats = assets.ParticleStats;

pub const SideSpread = struct {
    pub const duration = 160;
    pub const cooldown = 1200;

    left: bool,
    after_image: assets.AssetRef(assets.ParticleStats) = .{ .name = "after_image" },

    proj_timer: u32 = 0,
    proj_counter: u32 = 0,

    face: Vec = undefined,
    boost_psr: cms.Psr = undefined,
    pos: Vec = undefined,

    const speed_boost = 3000.0;
    const bullet_count = 10;
    const proj_latency = duration / bullet_count;
    const target_angle = 0.5;
    const muzzle_distance = 30;
    const target_distance = 200;

    pub fn init(self: *@This(), game: *Game) !void {
        const base = game.world.selectOne(game.player, struct { cms.Pos }).?;
        self.face = vec.norm(game.mousePos() - base.pos[0]);
        self.boost_psr = .{ .stats = self.after_image.value };
        self.pos = base.pos[0];
    }

    pub fn drawCrossHare(self: *@This(), game: *Game, loaded: bool) !void {
        const playr = game.world.get(game.player).?;
        const bs = playr.select(struct { cms.Stt, cms.Vel, cms.Pos }).?;
        const face_ang = vec.ang(game.mousePos() - bs.pos[0]);
        const target_dir: f32 = std.math.pi * target_angle;
        const sign: f32 = if (self.left) -1 else 1;
        const target_point = bs.pos[0] + vec.rad(face_ang + target_dir * sign, target_distance);
        var color = rl.SKYBLUE;
        if (!loaded) color.a = 128;
        rl.DrawCircleV(vec.asRl(target_point), 5, color);
    }

    pub fn poll(self: *@This(), game: *Game) !void {
        const playr = game.world.get(game.player).?;
        const bs = playr.select(struct { cms.Stt, cms.Vel, cms.Pos }).?;
        const stt = bs.stt[0];

        const trust = self.face * vec.splat(speed_boost * rl.GetFrameTime());
        bs.vel[0] += trust;
        const face_ang = vec.ang(self.face);

        try game.runPsr(bs, &self.boost_psr, face_ang, playr);

        if (game.timer(&self.proj_timer, proj_latency)) {
            const sign: f32 = if (self.left) -1 else 1;

            const side = std.math.pi - (std.math.pi / @as(f32, proj_latency)) * @as(f32, @floatFromInt(self.proj_counter));
            const vface = bs.pos[0] + vec.rad(face_ang + side * sign, muzzle_distance);

            const target_dir: f32 = std.math.pi * target_angle;
            const target_point = self.pos + vec.rad(face_ang + target_dir * sign, target_distance);
            const tface = vec.norm(target_point - vface);

            try game.createBullet(
                stt.bullet.?.value,
                bs.stt[0],
                vface,
                bs.vel[0] * vec.splat(0.2),
                tface,
            );

            self.proj_counter += 1;
        }
    }
};

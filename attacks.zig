const vec = @import("vec.zig");
const Vec = vec.T;
const Game = @import("Game.zig");
const rl = @import("main.zig").rl;
const assets = @import("assets.zig");
const cms = Game.Ents;
const std = @import("std");
const ParticleStats = assets.ParticleStats;

//pub const HomingBurst = struct {
//    pub const duration = 100;
//    pub const cooldown = 800;
//
//    left: bool = false,
//    after_image: assets.AssetRef(assets.ParticleStats) = .{ .name = "after_image" },
//
//    proj_timer: u32 = 0,
//    proj_counter: u32 = 0,
//
//    boost_psr: cms.Psr = undefined,
//    face: Vec = undefined,
//
//    const recoil = 7000.0;
//    const bullet_count = 10;
//    const proj_latency = duration / bullet_count;
//    const target_angle = 0.5;
//    const muzzle_distance = 30;
//    const target_distance = 150;
//
//    pub fn init(self: *@This(), game: *Game) !void {
//        const base = game.world.selectOne(game.player, struct { cms.Pos, cms.Stt }).?;
//        self.boost_psr = .{ .stats = self.after_image.value };
//
//        const stt = base.stt[0];
//        const pos = base.pos[0];
//
//        const face = vec.norm(game.mousePos() - pos);
//        self.face = face;
//        //const sign: f32 = if (self.left) -1 else 1;
//        const dir = vec.ang(face);
//
//        for (0..bullet_count) |_| {
//            const spreadf = std.math.pi * 0.2;
//            const tdir = dir - spreadf + game.prng.random().float(f32) * spreadf * 2;
//            const tface = vec.unit(tdir);
//            const spread = std.math.pi * 0.2;
//            const vdir = dir - spread + game.prng.random().float(f32) * spread * 2;
//            const vface = pos + vec.rad(vdir, 20 + game.prng.random().float(f32) * 20);
//
//            const bull = try game.createBullet(
//                stt.bullet.?.value,
//                stt,
//                vface,
//                vec.zero,
//                tface,
//            );
//            try game.world.addComp(game.gpa, bull, cms.Hom{});
//        }
//    }
//
//    pub fn crossHarePos(self: *@This(), game: *Game) Vec {
//        _ = self; // autofix
//        const playr = game.world.get(game.player).?;
//        const bs = playr.select(struct { cms.Stt, cms.Vel, cms.Pos }).?;
//        const face_ang = vec.ang(game.mousePos() - bs.pos[0]);
//        const target_dir: f32 = std.math.pi * target_angle;
//        _ = target_dir; // autofix
//        //const sign: f32 = if (self.left) -1 else 1;
//        return bs.pos[0] + vec.rad(face_ang, target_distance);
//    }
//
//    pub fn poll(self: *@This(), game: *Game) !void {
//        const playr = game.world.get(game.player).?;
//        const bs = playr.select(struct { cms.Stt, cms.Vel, cms.Pos }).?;
//        const face_ang = vec.ang(bs.vel[0]);
//        try game.runPsr(bs, &self.boost_psr, face_ang, playr);
//
//        const sign: f32 = if (self.left) -1 else 1;
//        _ = sign; // autofix
//        const dir = vec.ang(self.face); // + std.math.pi / 2.0 * sign;
//        const inpuls = vec.rad(dir, recoil * rl.GetFrameTime());
//        const vbase = game.world.selectOne(game.player, struct { cms.Vel }).?;
//        vbase.vel[0] -= inpuls;
//    }
//};
//
//pub const SideSpread = struct {
//    pub const duration = 160;
//    pub const cooldown = 1200;
//
//    left: bool,
//    after_image: assets.AssetRef(assets.ParticleStats) = .{ .name = "after_image" },
//
//    proj_timer: u32 = 0,
//    proj_counter: u32 = 0,
//
//    face: Vec = undefined,
//    boost_psr: cms.Psr = undefined,
//    pos: Vec = undefined,
//
//    const speed_boost = 3000.0;
//    const bullet_count = 10;
//    const proj_latency = duration / bullet_count;
//    const target_angle = 0.5;
//    const muzzle_distance = 30;
//    const target_distance = 200;
//
//    pub fn init(self: *@This(), game: *Game) !void {
//        const base = game.world.selectOne(game.player, struct { cms.Pos }).?;
//        self.face = vec.norm(game.mousePos() - base.pos[0]);
//        self.boost_psr = .{ .stats = self.after_image.value };
//        self.pos = base.pos[0];
//    }
//
//    pub fn crossHarePos(self: *@This(), game: *Game) Vec {
//        const playr = game.world.get(game.player).?;
//        const bs = playr.select(struct { cms.Stt, cms.Vel, cms.Pos }).?;
//        const face_ang = vec.ang(game.mousePos() - bs.pos[0]);
//        const target_dir: f32 = std.math.pi * target_angle;
//        const sign: f32 = if (self.left) -1 else 1;
//        return bs.pos[0] + vec.rad(face_ang + target_dir * sign, target_distance);
//    }
//
//    pub fn poll(self: *@This(), game: *Game) !void {
//        const playr = game.world.get(game.player).?;
//        const bs = playr.select(struct { cms.Stt, cms.Vel, cms.Pos }).?;
//        const stt = bs.stt[0];
//
//        const trust = self.face * vec.splat(speed_boost * rl.GetFrameTime());
//        bs.vel[0] += trust;
//        const face_ang = vec.ang(self.face);
//
//        try game.runPsr(bs, &self.boost_psr, face_ang, playr);
//
//        if (game.timer(&self.proj_timer, proj_latency)) {
//            const sign: f32 = if (self.left) -1 else 1;
//
//            const side = std.math.pi - (std.math.pi / @as(f32, proj_latency)) * @as(f32, @floatFromInt(self.proj_counter));
//            const vface = bs.pos[0] + vec.rad(face_ang + side * sign, muzzle_distance);
//
//            const target_dir: f32 = std.math.pi * target_angle;
//            const target_point = self.pos + vec.rad(face_ang + target_dir * sign, target_distance);
//            const tface = vec.norm(target_point - vface);
//
//            _ = try game.createBullet(
//                stt.bullet.?.value,
//                bs.stt[0],
//                vface,
//                bs.vel[0] * vec.splat(0.2),
//                tface,
//            );
//
//            self.proj_counter += 1;
//        }
//    }
//};

const std = @import("std");
const resources = @import("resources.zig");
const rl = @import("main.zig").rl;
const attacks = @import("attacks.zig");
const vec = @import("vec.zig");
const assets = @import("assets.zig");
const Game = @import("Game.zig");

const Attack = assets.Attack;
const Vec = vec.T;
const Stats = assets.Stats;
const ParticleStats = assets.ParticleStats;
const Frame = assets.Frame;
const cms = Game.cms;

pub const DodgeGun = struct {
    attacks: struct {
        key_s: attacks.HomingBurst = .{},
        //key_d: attacks.HomingBurst = .{ .left = false },
    } = .{},
    textures: struct {
        player: Frame,
        enemy: Frame,
        bullet: Frame,
        turret: Frame,
        turret_cannon: Frame,
        enemy_bullet: Frame,
        meteor: Frame,
        key_a: Frame,
        key_d: Frame,
    } = undefined,
    stats: struct {
        player: Stats = .{
            .fric = 1,
            .speed = 700,
            .size = 15,
            .max_health = 100,
            .texture = .{ .name = "player" },
            .bullet = .{ .name = "bullet" },
            .trail = .{ .name = "fire" },
        },
        enemy: Stats = .{
            .size = 40,
            .sight = 900,
            .damage = 10,
            .team = 1,
            .fric = 100,
            .max_health = 300,
            .reload = 1000,
            .texture = .{ .name = "turret" },
            .cannon_texture = .{ .name = "turret_cannon" },
            .bullet = .{ .name = "enemy_bullet" },
        },
        bullet: Stats = .{
            .speed = 500,
            .fric = 4,
            .size = 7,
            .damage = 10,
            .lifetime = 700,
            .sight = 150,
            .trail = .{ .name = "bullet_trail" },
            .texture = .{ .implicit = {} },
        },
        enemy_bullet: Stats = .{
            .speed = 900,
            .team = 1,
            .fric = 0,
            .size = 20,
            .damage = 25,
            .lifetime = 1000,
            .texture = .{ .name = "enemy_bullet" },
            .trail = .{ .name = "enemy_fire" },
            .explosion = .{ .name = "enemy_bullet_explosion" },
        },
        after_image: Stats = .{
            .fric = 10,
            .size = 15,
            .fade = true,
            .lifetime = 400,
            .color = rl.WHITE,
            .texture = .{ .name = "player" },
        },
    } = .{},
    particles: struct {
        enemy_bullet_explosion: ParticleStats = .{
            .init_vel = 500,
            .init_vel_variation = 200,
            .offset = .after,
            .lifetime_variation = 60,
            .batch = 10,
            .particle = .{ .value = &.{
                .fric = 10,
                .size = 50,
                .lifetime = 200,
                .color = rl.ORANGE,
            } },
        },
        fire: ParticleStats = .{
            .init_vel = 100,
            .offset = .after,
            .lifetime_variation = 40,
            .batch = 3,
            .particle = .{ .value = &.{
                .fric = 4,
                .size = 10,
                .lifetime = 100,
                .color = rl.SKYBLUE,
            } },
        },
        enemy_fire: ParticleStats = .{
            .init_vel = 70,
            .offset = .after,
            .lifetime_variation = 40,
            .batch = 2,
            .particle = .{ .value = &.{
                .fric = 4,
                .size = 10,
                .lifetime = 200,
                .color = rl.ORANGE,
            } },
        },
        bullet_trail: ParticleStats = .{
            .spawn_rate = 32,
            .particle = .{ .value = &.{
                .fric = 1,
                .size = 8,
                .fade = false,
                .lifetime = 500,
                .color = rl.SKYBLUE,
            } },
        },
        after_image: ParticleStats = .{
            .spawn_rate = 32,
            .particle = .{ .implicit = {} },
        },
    } = .{},

    pub fn mount(self: *const @This(), game: *Game) !void {
        game.player = try game.world.create(game.gpa, .{
            cms.Stt{&self.stats.player},
            cms.Pos{.{ 0, 0 }},
            cms.Vel{vec.zero},
            try game.createPhy(.{ 0, 0 }, self.stats.player.size),
            cms.Hlt{ .points = self.stats.player.max_health },
        });

        const turests = [_]Vec{.{ 1000, 1000 }};
        for (turests) |pos| {
            _ = try game.world.create(game.gpa, .{
                cms.Stt{&self.stats.enemy},
                cms.Pos{pos + Vec{ 200, 200 }},
                cms.Vel{vec.zero},
                cms.Trt{},
                try game.createPhy(pos, self.stats.enemy.size),
                cms.Nmy{},
                cms.Hlt{ .points = self.stats.enemy.max_health },
            });
        }
    }
};

pub const BattleShip = struct {
    attacks: struct {
        key_a: attacks.SideSpread = .{ .left = true },
        key_d: attacks.SideSpread = .{ .left = false },
    } = .{},
    textures: struct {
        player: Frame,
        enemy: Frame,
        bullet: Frame,
        key_a: Frame,
        key_d: Frame,
    } = undefined,
    stats: struct {
        player: Stats = .{
            .fric = 1,
            .speed = 700,
            .size = 15,
            .max_health = 100,
            .texture = .{ .name = "player" },
            .bullet = .{ .name = "bullet" },
            .trail = .{ .name = "fire" },
        },
        enemy: Stats = .{
            .fric = 1,
            .speed = 800,
            .size = 15,
            .sight = 100000,
            .damage = 10,
            .team = 1,
            .max_health = 100,
            .texture = .{ .name = "enemy" },
            .trail = .{ .name = "enemy_fire" },
        },
        bullet: Stats = .{
            .speed = 600,
            .fric = 0,
            .size = 5,
            .damage = 10,
            .trail = .{ .name = "bullet_trail" },
            .texture = .{ .implicit = {} },
        },
        after_image: Stats = .{
            .fric = 10,
            .size = 15,
            .fade = true,
            .lifetime = 400,
            .color = rl.WHITE,
            .texture = .{ .name = "player" },
        },
    } = .{},
    particles: struct {
        fire: ParticleStats = .{
            .init_vel = 100,
            .offset = .after,
            .lifetime_variation = 40,
            .batch = 3,
            .particle = .{ .value = &.{
                .fric = 4,
                .size = 10,
                .lifetime = 100,
                .color = rl.SKYBLUE,
            } },
        },
        enemy_fire: ParticleStats = .{
            .init_vel = 70,
            .offset = .after,
            .lifetime_variation = 40,
            .batch = 2,
            .particle = .{ .value = &.{
                .fric = 4,
                .size = 10,
                .lifetime = 200,
                .color = rl.ORANGE,
            } },
        },
        bullet_trail: ParticleStats = .{
            .particle = .{ .value = &.{
                .fric = 1,
                .size = 7,
                .fade = false,
                .lifetime = 300,
                .color = rl.SKYBLUE,
            } },
        },
        after_image: ParticleStats = .{
            .spawn_rate = 36,
            .particle = .{ .implicit = {} },
        },
    } = .{},

    pub fn mount(self: *const @This(), game: *Game) !void {
        game.player = try game.world.create(game.gpa, .{
            cms.Stt{&self.stats.player},
            cms.Pos{.{ 0, 0 }},
            cms.Vel{vec.zero},
            try game.createPhy(.{ 0, 0 }, self.stats.player.size),
            cms.Hlt{ .points = self.stats.player.max_health },
        });

        const spacing = 50;
        const square = 10;
        for (0..square) |i| {
            for (0..square) |j| {
                const pos = Vec{ spacing * @as(f32, @floatFromInt(i + 1)), spacing * @as(f32, @floatFromInt(j + 1)) };
                _ = try game.world.create(game.gpa, .{
                    cms.Stt{&self.stats.enemy},
                    cms.Pos{pos + Vec{ 200, 200 }},
                    cms.Vel{vec.zero},
                    try game.createPhy(pos, self.stats.enemy.size),
                    cms.Nmy{},
                    cms.Hlt{ .points = self.stats.enemy.max_health },
                    cms.Psr{ .stats = &self.particles.enemy_fire },
                });
            }
        }
    }
};

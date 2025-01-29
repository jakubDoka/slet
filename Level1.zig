textures: struct {
    player: assets.Frame,
    turret: assets.Frame,
    turret_cannon: assets.Frame,
    enemy_bullet: assets.Frame,
    bullet: assets.Frame,
} = undefined,

const std = @import("std");
const ecs = @import("ecs.zig");
const vec = @import("vec.zig");
const engine = @import("engine.zig");
const assets = @import("assets.zig");
const rl = main.rl;
const main = @import("main.zig");

const Id = ecs.Id;
const Vec = vec.T;
const Quad = @import("QuadTree.zig");
const Self = @This();
const Engine = engine.Level(Self);
const World = ecs.World(Ents);

pub const world_size_pow = 20;
pub const hit_tween_duration = 100;

const dirs = [_]Vec{ .{ 0, -1 }, .{ -1, 0 }, .{ 0, 1 }, .{ 1, 0 } };
const keys = [_]c_int{ rl.KEY_W, rl.KEY_A, rl.KEY_S, rl.KEY_D };

pub const Ents = union(enum) {
    player: Player,
    fire_particle: FireParticle,
    turret: Turret,
    bullet: Bullet,
    enemy_bullet: EnemyBullet,
};

pub const Player = struct {
    pub const friction: f32 = 1;
    pub const max_health: u32 = 100;
    pub const size: f32 = 20;
    pub const speed: f32 = 700;
    pub const team: u32 = 0;
    pub const damage: u32 = 0;
    pub const reload: u32 = 600;

    id: Id = undefined,
    pos: Vec = vec.zero,
    vel: Vec = vec.zero,
    health: Engine.Hralth = .{ .points = max_health },
    phys: Engine.Phy = .{},
    reload: u32 = 0,
    attack: ?struct {
        face: Vec,
    } = null,

    pub fn draw(self: *@This(), game: *Engine) void {
        const dir = game.mousePos() - self.pos;
        const ang = vec.ang(dir);

        var boost_dir = vec.zero;
        for (dirs, keys) |d, k| {
            if (rl.IsKeyDown(k)) boost_dir += d;
        }

        if (boost_dir[0] != 0 or boost_dir[1] != 0) for (dirs) |d| {
            const rotated_dir = vec.unit(vec.ang(d) + ang);
            const offset = vec.angBetween(boost_dir, rotated_dir);
            if (offset >= std.math.pi / 2.5) continue;

            const emit_pos = self.pos + rotated_dir * vec.splat(-size * 0.8);
            const intensity = 15 * (1 - std.math.pow(f32, offset / (std.math.pi / 2.0), 2));

            for (0..3) |_| {
                _ = game.world.add(.fire_particle, .{
                    .pos = emit_pos + self.vel * vec.splat(rl.GetFrameTime()),
                    .vel = vec.unit(game.prng.random().float(f32) * std.math.tau) *
                        vec.splat(100) + rotated_dir * -vec.splat(150),
                    .live_until = game.time + 100 - game.prng.random().int(u32) % 40,
                    .size = intensity,
                    .color = rl.SKYBLUE,
                });
            }
        };

        const tone = self.health.draw(self, game);
        const color = main.fcolor(1, tone, tone);
        game.drawCenteredTexture(game.spec.textures.player, self.pos, ang, size, color);
    }

    pub fn input(self: *@This(), game: *Engine) void {
        {
            var dir = vec.zero;
            for (dirs, keys) |d, k| {
                if (rl.IsKeyDown(k)) dir += d;
            }
            self.vel += vec.norm(dir) * vec.splat(speed * rl.GetFrameTime());
        }

        if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT) and game.timer(&self.reload, reload)) {
            const face = vec.norm(game.mousePos() - self.pos);
            self.attack = .{ .face = face };
            //const sign: f32 = if (self.left) -1 else 1;
            const dir = vec.ang(face);

            for (0..10) |_| {
                const spreadf = std.math.pi * 0.2;
                const tdir = dir - spreadf + game.prng.random().float(f32) * spreadf * 2;
                const spread = std.math.pi * 0.2;
                const vdir = dir - spread + game.prng.random().float(f32) * spread * 2;

                const bull = game.world.add(.bullet, .{
                    .pos = self.pos + vec.rad(vdir, 20 + game.prng.random().float(f32) * 20),
                    .vel = vec.rad(tdir, Bullet.speed),
                    .live_until = game.time + Bullet.lifetime,
                });
                game.initPhy(bull, .bullet);
            }

            self.vel -= face * vec.splat(400);
        }
    }
};

pub const FireParticle = struct {
    pub const friction: f32 = 4;

    id: Id = undefined,
    pos: Vec,
    vel: Vec,
    live_until: u32,
    lifetime: u32 = 100,
    size: f32,
    particle: void = {},
    color: rl.Color,

    pub fn draw(self: *@This(), game: *Engine) void {
        const rate = main.divToFloat(game.timeRem(self.live_until) orelse 0, self.lifetime);
        const color = rl.ColorAlpha(self.color, rate);
        rl.DrawCircleV(vec.asRl(self.pos), self.size * rate, color);
    }
};

pub const Turret = struct {
    pub const friction: f32 = 1;
    pub const max_health: u32 = 300;
    pub const size: f32 = 40;
    pub const team: u32 = 1;
    pub const damage: u32 = 10;
    pub const sight: f32 = 1000;
    pub const reload: u32 = 800;

    id: Id = undefined,
    pos: Vec,
    vel: Vec = vec.zero,
    health: Engine.Hralth = .{ .points = max_health },
    phys: Engine.Phy = .{},
    turret: Engine.Turret = .{},

    pub fn draw(self: *@This(), game: *Engine) void {
        const tone = self.health.draw(self, game);
        const color = main.fcolor(1, tone, tone);
        game.drawCenteredTexture(game.spec.textures.turret, self.pos, 0, size, color);
        game.drawCenteredTexture(game.spec.textures.turret_cannon, self.pos, self.turret.rot, size, color);
    }

    pub fn update(self: *@This(), game: *Engine) void {
        self.turret.update(self, game);
    }
};

pub const Bullet = struct {
    pub const speed: f32 = 500;
    pub const friction: f32 = 3;
    pub const size: f32 = 7;
    pub const team: u32 = 0;
    pub const damage: u32 = 10;
    pub const sight: f32 = 150;
    pub const lifetime: u32 = 1000;

    id: Id = undefined,
    pos: Vec,
    vel: Vec,
    phys: Engine.Phy = .{},
    live_until: u32,
    target: Id = Id.invalid,

    pub fn draw(self: *@This(), game: *Engine) void {
        const emit_pos = self.pos + vec.norm(self.vel) * vec.splat(-size * 0.8);

        _ = game.world.add(.fire_particle, .{
            .pos = emit_pos + self.vel * vec.splat(rl.GetFrameTime()),
            .vel = vec.zero,
            .lifetime = 300,
            .live_until = game.time + 300,
            .size = size,
            .color = rl.SKYBLUE,
        });
        game.drawCenteredTexture(game.spec.textures.bullet, self.pos, vec.ang(self.vel), size, rl.WHITE);
    }

    pub fn update(self: *@This(), game: *Engine) void {
        const delta = rl.GetFrameTime();

        if (self.target != Id.invalid) if (game.world.field(self.target, .pos)) |target| b: {
            const pos = target.*;

            if (vec.dist(pos, self.pos) > sight) {
                break :b;
            }

            //if (target.get(cms.Vel)) |vel| {
            //    const speed = tr.stt[0].speed;
            //    const tvel = vel[0];
            //    pos = predictTarget(tr.pos[0], pos, tvel, speed) orelse {
            //        break :b;
            //    };
            //}

            const dir = vec.norm(pos - self.pos);
            self.vel += dir * vec.splat(speed * 2 * delta);
            return;
        };
        self.target = game.findEnemy(self) orelse Id.invalid;
    }

    pub fn onCollision(self: *@This(), game: *Engine, other: Id) void {
        _ = self; // autofix
        const health = game.world.field(other, .health) orelse return;
        health.points -|= damage;
        health.hit_tween = game.time + hit_tween_duration;
        if (health.points == 0) game.queueDelete(other);
    }
};

pub const EnemyBullet = struct {
    pub const speed: f32 = 900;
    pub const friction: f32 = 0;
    pub const size: f32 = 20;
    pub const team: u32 = 1;
    pub const damage: u32 = 25;
    pub const lifetime: u32 = 1000;

    id: Id = undefined,
    pos: Vec,
    vel: Vec,
    phys: Engine.Phy = .{},
    live_until: u32,

    pub fn draw(self: *@This(), game: *Engine) void {
        const emit_pos = self.pos + vec.norm(self.vel) * vec.splat(-size * 0.8);
        const intensity = 15;

        for (0..3) |_| {
            _ = game.world.add(.fire_particle, .{
                .pos = emit_pos + self.vel * vec.splat(rl.GetFrameTime()),
                .vel = vec.unit(game.prng.random().float(f32) * std.math.tau) *
                    vec.splat(100),
                .live_until = game.time + 100 - game.prng.random().int(u32) % 40,
                .size = intensity,
                .color = rl.ORANGE,
            });
        }

        game.drawCenteredTexture(game.spec.textures.enemy_bullet, self.pos, vec.ang(self.vel), size, rl.WHITE);
    }

    pub fn onCollision(self: *@This(), game: *Engine, other: Id) void {
        const health = game.world.field(other, .health) orelse return;
        health.points -|= damage;
        health.hit_tween = game.time + hit_tween_duration;
        if (health.points == 0) game.queueDelete(other);
        game.queueDelete(self.id);
    }

    pub fn onDelete(self: *@This(), game: *Engine) void {
        for (0..10) |_| {
            _ = game.world.add(.fire_particle, .{
                .pos = self.pos + self.vel * vec.splat(-rl.GetFrameTime()),
                .vel = vec.unit(game.prng.random().float(f32) * std.math.tau) *
                    vec.splat(200),
                .live_until = game.time + 200 - game.prng.random().int(u32) % 80,
                .size = 15,
                .color = rl.ORANGE,
            });
        }
    }
};

pub fn init(self: *Engine) void {
    self.sheet = assets.initTextures(&self.spec.textures, self.gpa, 128) catch unreachable;

    self.player = self.world.add(.player, .{});
    self.initPhy(self.player, .player);

    const trt = self.world.add(.turret, .{ .pos = .{ 800, 800 } });
    self.initPhy(trt, .turret);
}

pub fn input(self: *Engine) void {
    const base = self.world.get(self.player, .player) orelse return;
    base.input(self);
}

pub fn drawWorld(self: *Engine) void {
    rl.DrawLine(0, 0, 0, 10000, rl.WHITE);
    self.drawParticles();
    self.drawVisibleEntities();
}

pub fn update(self: *Engine) void {
    const player = self.world.get(self.player, .player) orelse return;
    self.handleCircleCollisions();
    self.updatePhysics();
    self.folowWithCamera(player.pos);
    self.killTemporaryEnts();
}

const std = @import("std");
const ecs = @import("../ecs.zig");
const vec = @import("../vec.zig");
const engine = @import("../engine.zig");
const rl = @import("rl").rl;
const textures = @import("sheet_frames");

const Id = ecs.Id;
const Vec = vec.T;
const Quad = @import("../QuadTree.zig");
const Self = @This();
const Engine = engine.Level(Self);
const World = ecs.World(engine.PackEnts(Self));

pub const world_size_pow = 12;
pub const hit_tween_duration = 100;
pub const time_limit = 1000 * 9;
pub const tile_sheet = [_]rl.Rectangle{
    textures.tile_full,
};

pub const weng_tiles = [_]rl.Rectangle{
    textures.tile_corner,
    textures.tile_side,
};

const keys = [_]c_int{ rl.KEY_W, rl.KEY_A, rl.KEY_S, rl.KEY_D };

const blue: rl.Color = @bitCast(std.mem.nativeToBig(u32, 0x59d2fdFF));
const red: rl.Color = @bitCast(std.mem.nativeToBig(u32, 0xE3654AFF));

pub const Player = struct {
    pub const friction: f32 = 1;
    pub const max_health: u32 = 100;
    pub const size: f32 = 20;
    pub const speed: f32 = 700;
    pub const team: u32 = 0;
    pub const damage: u32 = 0;
    pub const reload: u32 = 500;
    pub const color = blue;

    id: Id = undefined,
    pos: Vec = vec.zero,
    vel: Vec = vec.zero,
    health: Engine.Health = .{ .points = max_health },
    phys: Engine.Phy = .{},
    reload_timer: u32,

    pub fn draw(self: *@This(), game: *Engine) void {
        const dir = game.mousePos() - self.pos;
        game.drawCenteredTexture(textures.shadow, self.pos - vec.norm(dir) * vec.splat(5), 0, size * 1.1, rl.WHITE);
        const ang = vec.ang(dir);

        var boost_dir = vec.zero;
        for (vec.dirs, keys) |d, k| {
            if (rl.IsKeyDown(k)) boost_dir += d;
        }

        if (boost_dir[0] != 0 or boost_dir[1] != 0) for (vec.dirs) |d| {
            const rotated_dir = vec.unit(vec.ang(d) + ang);
            const offset = vec.angBetween(boost_dir, rotated_dir);
            if (offset >= std.math.pi / 2.5) continue;

            const emit_pos = self.pos + rotated_dir * vec.splat(-size * 0.8);
            const intensity = 15 * (1 - std.math.pow(f32, offset / (std.math.pi / 2.0), 2));

            for (0..3) |_| {
                _ = game.world.add(FireParticle{
                    .pos = emit_pos + self.vel * vec.splat(rl.GetFrameTime()),
                    .vel = vec.unit(game.prng.random().float(f32) * std.math.tau) *
                        vec.splat(100) + rotated_dir * -vec.splat(150),
                    .live_until = game.time + 100 - game.prng.random().int(u32) % 40,
                    .size = intensity,
                    .color = blue,
                });
            }
        };

        const tone = self.health.draw(self, game);
        const col = vec.fcolor(1, tone, tone);
        game.drawCenteredTexture(textures.player, self.pos, ang, size, col);
    }

    pub fn input(self: *@This(), game: *Engine) void {
        {
            var dir = vec.zero;
            for (vec.dirs, keys) |d, k| {
                if (rl.IsKeyDown(k)) dir += d;
            }
            self.vel += vec.norm(dir) * vec.splat(speed * rl.GetFrameTime());
        }

        if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT) and game.timer(&self.reload_timer, reload)) {
            const face = vec.norm(game.mousePos() - self.pos);
            const dir = vec.ang(face);

            for (0..10) |_| {
                const spreadf = std.math.pi * 0.2;
                const tdir = dir - spreadf + game.prng.random().float(f32) * spreadf * 2;
                const spread = std.math.pi * 0.2;
                const vdir = dir - spread + game.prng.random().float(f32) * spread * 2;

                const bull = game.world.add(Bullet{
                    .pos = self.pos + vec.rad(vdir, game.prng.random().float(f32) * 20),
                    .vel = vec.rad(tdir, Bullet.speed),
                    .live_until = game.time + Bullet.lifetime,
                });
                game.initPhy(bull, Bullet);
            }

            self.vel -= face * vec.splat(400);
        }

        if (game.timeRem(self.reload_timer)) |r| if (r > (reload - AfterImage.lifetime) and (r / 16) % 2 == 0) {
            const face = vec.norm(game.mousePos() - self.pos);
            const dir = vec.ang(face);
            _ = game.world.add(AfterImage{
                .pos = self.pos,
                .rot = dir,
                .live_until = game.time + AfterImage.lifetime,
            });
        };
    }
};

pub const AfterImage = struct {
    pub const lifetime = 150;

    id: Id = undefined,
    pos: Vec,
    rot: f32,
    live_until: u32,
    particle: void = {},

    pub fn draw(self: *@This(), game: *Engine) void {
        const rate = vec.divToFloat(game.timeRem(self.live_until) orelse 0, lifetime);
        const color = rl.ColorAlpha(rl.WHITE, rate);
        game.drawCenteredTexture(textures.player, self.pos, self.rot, Player.size, color);
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
        const rate = vec.divToFloat(game.timeRem(self.live_until) orelse 0, self.lifetime);
        const color = rl.ColorAlpha(self.color, rate);
        rl.DrawCircleV(vec.asRl(self.pos), self.size * rate, color);
    }
};

pub const Covard = struct {
    pub const friction: f32 = 1;
    pub const max_health: u32 = 300;
    pub const size: f32 = 50;
    pub const team: u32 = 1;
    pub const damage: u32 = 10;
    pub const sight: f32 = 1000;
    pub const reload: u32 = 800;
    pub const turret_speed: f32 = std.math.tau;
    pub const color = red;

    const distancing = 350;

    id: Id = undefined,
    pos: Vec,
    vel: Vec = vec.zero,
    health: Engine.Health = .{ .points = max_health },
    phys: Engine.Phy = .{},
    indicated_enemy: void = {},

    pub fn draw(self: *@This(), game: *Engine) void {
        const tone = self.health.draw(self, game);
        const col = vec.fcolor(1, tone, tone);

        game.drawCenteredTexture(textures.shadow, self.pos, 0, size * 1.2, rl.WHITE);
        game.drawCenteredTexture(textures.turret, self.pos, 0, size, col);
    }

    pub fn update(self: *@This(), game: *Engine) void {
        const pl = game.world.get(game.player, Player) orelse return;

        const target_pos = pl.pos + vec.norm(self.pos - pl.pos) * vec.splat(distancing);
        const distance = vec.dist(self.pos, pl.pos);
        const intensity = 1 - @min(1, std.math.pow(f32, (distance / distancing), 2));

        self.vel += vec.norm(target_pos - self.pos) * vec.splat(intensity * 1000 * rl.GetFrameTime());
    }

    pub fn onDelete(self: *@This(), game: *Engine) void {
        for (0..25) |_| {
            _ = game.world.add(FireParticle{
                .pos = self.pos + vec.unit(game.prng.random().float(f32) * std.math.tau) *
                    vec.splat(20) + self.vel * vec.splat(-rl.GetFrameTime()),
                .vel = vec.unit(game.prng.random().float(f32) * std.math.tau) *
                    vec.splat(500),
                .lifetime = 300,
                .live_until = game.time + 400 - game.prng.random().int(u32) % 80,
                .size = 25,
                .color = red,
            });
        }
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

        _ = game.world.add(FireParticle{
            .pos = emit_pos + self.vel * vec.splat(rl.GetFrameTime()),
            .vel = vec.zero,
            .lifetime = 300,
            .live_until = game.time + 300,
            .size = size,
            .color = blue,
        });
    }

    pub fn update(self: *@This(), game: *Engine) void {
        const delta = rl.GetFrameTime();

        if (self.target != Id.invalid) if (game.world.field(self.target, .pos)) |target| b: {
            const pos = target.*;

            if (vec.dist(pos, self.pos) > sight) {
                break :b;
            }

            const dir = vec.norm(pos - self.pos);
            self.vel += dir * vec.splat(speed * 2 * delta);
            return;
        };
        self.target = game.findEnemy(self, null) orelse Id.invalid;
    }

    pub fn onCollision(self: *@This(), game: *Engine, other: Id) void {
        const health: *Engine.Health = game.world.field(other, .health) orelse return;
        _ = health.takeDamage(self, other, game);
        self.vel *= vec.splat(1.2);
    }
};

pub fn init(self: *Engine) void {
    const s = Engine.TileMap.stride;
    for (1..s - 1) |y| for (1..s - 1) |x| {
        const coff = 1 - vec.dist(.{ vec.tof(x), vec.tof(y) }, .{ s / 2, s / 2 }) / (s / 2);
        if (self.prng.random().float(f32) < coff) self.tile_map.set(x, y, 0);
    };

    const ws = (s / 2) * Engine.TileMap.tile_size;
    self.player = self.world.add(Player{ .pos = .{ ws - 850, ws }, .reload_timer = self.time + 100 });
    self.initPhy(self.player, Player);

    const trt = self.world.add(Covard{ .pos = .{ ws, ws } });
    self.initPhy(trt, Covard);
}

pub fn input(self: *Engine) void {
    const base = self.world.get(self.player, Player) orelse return;
    base.input(self);
}

pub fn drawWorld(self: *Engine) void {
    self.drawParticles();
    self.drawVisibleEntities();
    self.drawReloadIndicators();
    self.drawOffScreenEnemyIndicators();
}

pub fn update(self: *Engine) bool {
    const player = self.world.get(self.player, Player) orelse return false;
    self.handleCircleCollisions();
    self.updatePhysics();
    self.folowWithCamera(player.pos, 0.49);
    self.killTemporaryEnts();

    return self.world.ents.covard.items.len == 0;
}

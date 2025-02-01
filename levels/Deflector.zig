const std = @import("std");
const ecs = @import("../ecs.zig");
const vec = @import("../vec.zig");
const engine = @import("../engine.zig");
const rl = @import("../rl.zig").rl;
const textures = @import("../zig-out/sheet_frames.zig");

const Id = ecs.Id;
const Vec = vec.T;
const Quad = @import("../QuadTree.zig");
const Self = @This();
const Engine = engine.Level(Self);
const World = ecs.World(engine.PackEnts(Self));

pub const world_size_pow = 12;
pub const hit_tween_duration = 100;
pub const time_limit = 1000 * 20;
pub const tile_sheet = [_]rl.Rectangle{
    textures.tile_full,
};

pub const weng_tiles = [_]rl.Rectangle{
    textures.tile_corner,
    textures.tile_side,
};

const keys = [_]c_int{ rl.KEY_W, rl.KEY_A, rl.KEY_S, rl.KEY_D };

const blue: rl.Color = @bitCast(std.mem.nativeToBig(u32, 0x59d2fdFF));
const red: rl.Color = rl.ORANGE; //@bitCast(std.mem.nativeToBig(u32, 0xE3654AFF));
const sub_reload = 120;
const charge_count = 4;

pub const Player = struct {
    pub const friction: f32 = 1;
    pub const max_health: u32 = 100;
    pub const size: f32 = 20;
    pub const speed: f32 = 700;
    pub const team: u32 = 0;
    pub const damage: u32 = 0;
    pub const reload: u32 = 1200;
    pub const color = blue;

    id: Id = undefined,
    pos: Vec = vec.zero,
    vel: Vec = vec.zero,
    health: Engine.Health = .{ .points = max_health },
    phys: Engine.Phy = .{},
    reload_timer: u32,
    charges: u32 = 0,
    sub_reload: u32 = 0,

    pub fn draw(self: *@This(), game: *Engine) void {
        const dir = game.mousePos() - self.pos;
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
            self.charges = charge_count;
        }

        if (self.charges != 0 and game.timer(&self.sub_reload, sub_reload)) {
            const face = vec.norm(game.mousePos() - self.pos);
            const dir = vec.ang(face);
            self.charges -= 1;
            const bull = game.world.add(Bullet{
                .pos = self.pos + vec.rad(dir, game.prng.random().float(f32) * 20),
                .vel = vec.rad(dir, Bullet.speed),
                .live_until = game.time + Bullet.lifetime,
            });
            game.initPhy(bull, Bullet);
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

pub const Turret = struct {
    pub const friction: f32 = 1;
    pub const max_health: u32 = 400;
    pub const size: f32 = 40;
    pub const team: u32 = 1;
    pub const damage: u32 = 10;
    pub const sight: f32 = 700;
    pub const turret_speed: f32 = std.math.tau;
    pub const reload: u32 = Player.reload * 2;
    pub const color = red;
    pub const Bullet = Self.EnemyBullet;

    id: Id = undefined,
    pos: Vec,
    vel: Vec = vec.zero,
    health: Engine.Health = .{ .points = max_health },
    phys: Engine.Phy = .{},
    reload_timer: u32 = 0,
    sub_reload: u32 = 0,
    charges: u32 = 0,
    indicated_enemy: void = {},

    pub fn draw(self: *@This(), game: *Engine) void {
        const tone = self.health.draw(self, game);
        const col = vec.fcolor(1, tone, tone);
        game.drawCenteredTexture(textures.shadow, self.pos, 0, size * 1.2, rl.WHITE);
        game.drawCenteredTexture(textures.turret, self.pos, 0, size, col);
    }

    pub fn update(self: *@This(), game: *Engine) void {
        const target = game.findEnemy(self) orelse return;
        if (game.timer(&self.reload_timer, reload)) {
            self.charges += charge_count;
        }

        if (self.charges != 0 and game.timer(&self.sub_reload, sub_reload)) {
            self.charges -= 1;
            const target_pos = game.world.field(target, .pos).?.*;
            const dir = vec.ang(self.pos - target_pos); // behind us
            const spread = std.math.pi / 2.0;
            const final_dir = dir + -spread / 2.0 + (spread / @as(f32, charge_count - 1)) * vec.tof(self.charges);
            const bull = game.world.add(EnemyBullet{
                .pos = self.pos + vec.rad(final_dir, size),
                .vel = vec.rad(final_dir, EnemyBullet.speed),
                .target = target,
                .boot_time = game.time,
            });
            game.initPhy(bull, EnemyBullet);
        }
    }
};

pub const Bullet = struct {
    pub const speed: f32 = 500;
    pub const friction: f32 = 0;
    pub const size: f32 = 10;
    pub const team: u32 = 0;
    pub const damage: u32 = 25;
    pub const lifetime: u32 = 1000;

    id: Id = undefined,
    pos: Vec,
    vel: Vec,
    phys: Engine.Phy = .{},
    live_until: u32,

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

    pub fn onCollision(self: *@This(), game: *Engine, other: Id) void {
        const health: *Engine.Health = game.world.field(other, .health) orelse return;
        _ = health.takeDamage(self, other, game);
        game.queueDelete(self.id);
    }
};

pub const EnemyBullet = struct {
    pub const speed: f32 = 300;
    pub const friction: f32 = 0;
    pub const size: f32 = 20;
    pub const team: u32 = 1;
    pub const damage: u32 = 50;
    pub const max_health: u32 = 1;

    id: Id = undefined,
    pos: Vec,
    vel: Vec,
    phys: Engine.Phy = .{},
    health: Engine.Health = .{ .points = max_health },
    target: Id,
    boot_time: u32,

    pub fn draw(self: *@This(), game: *Engine) void {
        const emit_pos = self.pos + vec.norm(self.vel) * vec.splat(-size * 0.8);
        const coff = self.getCoff(game);
        const intensity = 10 * (coff + 0.4);

        for (0..3) |_| {
            _ = game.world.add(FireParticle{
                .pos = emit_pos + self.vel * vec.splat(rl.GetFrameTime()),
                .vel = vec.unit(game.prng.random().float(f32) * std.math.tau) *
                    vec.splat(100),
                .live_until = game.time + 100 + @as(u32, @intFromFloat(40 * coff)) - game.prng.random().int(u32) % 40,
                .size = intensity,
                .color = red,
            });
        }

        game.drawCenteredTexture(textures.enemy_bullet, self.pos, vec.ang(self.vel), size, rl.WHITE);
    }

    pub fn update(self: *@This(), game: *Engine) void {
        const delta = rl.GetFrameTime();
        const target_pos = game.world.field(self.target, .pos).?.*;
        const coff = self.getCoff(game);
        self.vel += vec.norm(target_pos - self.pos) * vec.splat(speed * 30 * coff * delta);
        self.vel *= vec.splat(1 - 6 * coff * delta);
    }

    fn getCoff(self: *@This(), game: *Engine) f32 {
        const efficiency = @min(game.timeRem(self.boot_time + 2000) orelse 0, 1400);
        return std.math.pow(f32, 1 - vec.divToFloat(efficiency, 1400), 3);
    }

    pub fn onCollision(self: *@This(), game: *Engine, other: Id) void {
        const health: *Engine.Health = game.world.field(other, .health) orelse return;
        _ = health.takeDamage(self, other, game);
        game.queueDelete(self.id);
    }

    pub fn onDelete(self: *@This(), game: *Engine) void {
        for (0..20) |_| {
            _ = game.world.add(FireParticle{
                .pos = self.pos + self.vel * vec.splat(-rl.GetFrameTime()),
                .vel = vec.unit(game.prng.random().float(f32) * std.math.tau) *
                    vec.splat(300),
                .live_until = game.time + 240 - game.prng.random().int(u32) % 100,
                .size = 20,
                .color = red,
            });
        }
    }
};

pub fn init(self: *Engine) void {
    for (1..Engine.TileMap.stride - 1) |y| for (1..Engine.TileMap.stride - 1) |x| {
        if (self.prng.random().int(u2) == 0) {
            self.tile_map.set(x, y, 0);
        }
    };

    self.player = self.world.add(Player{ .pos = .{ 1000, 1000 }, .reload_timer = self.time + 100 });
    self.initPhy(self.player, Player);

    const trt = self.world.add(Turret{ .pos = .{ 1800, 1000 } });
    self.initPhy(trt, Turret);
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

    return self.world.ents.turret.items.len == 0 and
        self.world.ents.enemy_bullet.items.len == 0;
}

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
    pub const max_health: u32 = 200;
    pub const size: f32 = 20;
    pub const speed: f32 = 700;
    pub const team: u32 = 0;
    pub const damage: u32 = 50;
    pub const reload: u32 = 500;
    pub const color = blue;
    pub const sheeld_thickness: f32 = 20;

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

            self.vel += face * vec.splat(700);
            const shi = game.world.add(Shield{
                .pos = self.pos,
                .vel = self.vel,
                .follow = self.id,
                .live_until = game.time + 400,
            });
            game.initPhy(shi, Shield);
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

pub const Shield = struct {
    pub const friction: f32 = 1;
    pub const max_health: u32 = 200;
    pub const size: f32 = Player.size + 5;
    pub const speed: f32 = 700;
    pub const team: u32 = 0;
    pub const damage: u32 = 50;
    pub const reload: u32 = 500;
    pub const color = blue;

    id: Id = undefined,
    pos: Vec,
    vel: Vec,
    phys: Engine.Phy = .{},
    live_until: u32,
    follow: Id,

    pub fn draw(self: *@This(), game: *Engine) void {
        const dir = game.mousePos() - self.pos;
        const ang = vec.ang(dir);

        const spread = std.math.pi;
        for (0..10) |_| {
            const off = spread / 2.0 - game.prng.random().float(f32) * spread;
            const emit_pos = self.pos + vec.rad(ang + off, size);

            _ = game.world.add(FireParticle{
                .pos = emit_pos + self.vel * vec.splat(rl.GetFrameTime()),
                .vel = vec.unit(game.prng.random().float(f32) * std.math.tau) *
                    vec.splat(100),
                .live_until = game.time + 200,
                .lifetime = 200,
                .size = 10,
                .color = blue,
            });
        }
    }

    pub fn update(self: *@This(), game: *Engine) void {
        const player = game.world.get(self.follow, Player) orelse return;
        self.pos = player.pos;
        self.vel = player.vel;
    }

    pub fn onCollision(self: *@This(), game: *Engine, other: Id) void {
        const health: *Engine.Health = game.world.field(other, .health) orelse return;
        _ = health.takeDamage(self, other, game);
        if (game.world.get(self.follow, Player)) |p| p.vel = self.vel;
        //game.queueDelete(self.id);
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
    pub const max_health: u32 = 300;
    pub const size: f32 = 50;
    pub const team: u32 = 1;
    pub const damage: u32 = 10;
    pub const sight: f32 = 1000;
    pub const reload: u32 = 1000;
    pub const turret_speed: f32 = std.math.tau;
    pub const color = red;
    pub const Bullet = Self.EnemyBullet;
    pub const charge_count: u32 = 4;

    id: Id = undefined,
    pos: Vec,
    vel: Vec = vec.zero,
    health: Engine.Health = .{ .points = max_health },
    phys: Engine.Phy = .{},
    turret: Engine.Turret = .{},
    indicated_enemy: void = {},
    sub_reload: u32 = 0,
    charges: u32 = 0,
    n: f32 = 1,

    pub fn draw(self: *@This(), game: *Engine) void {
        const tone = self.health.draw(self, game);
        const col = vec.fcolor(1, tone, tone);

        game.drawCenteredTexture(textures.shadow, self.pos, 0, size * 1.2, rl.WHITE);
        game.drawCenteredTexture(textures.turret, self.pos, 0, size, col);
        game.drawCenteredTexture(textures.shadow, self.pos, 0, size * 1.1, rl.WHITE);
        game.drawCenteredTexture(textures.turret_cannon, self.pos, self.turret.rot, size, col);
    }

    pub fn update(self: *@This(), game: *Engine) void {
        if (self.turret.update(self, game)) {
            self.charges += charge_count;
            self.n *= -1;
        }

        if (self.charges != 0 and game.timer(&self.sub_reload, 50)) {
            //const offset = @as(f32, @floatFromInt(charge_count - self.charges)) * 30;
            self.charges -= 1;
            const bull = game.world.add(EnemyBullet{
                .pos = self.pos + vec.rad(self.turret.rot, size), //+ vec.rad(self.turret.rot + std.math.pi * 0.5 * self.n, offset),
                .vel = self.vel + vec.rad(self.turret.rot, EnemyBullet.speed),
                .live_until = game.time + EnemyBullet.lifetime,
            });
            game.initPhy(bull, EnemyBullet);
        }
    }
};

pub const EnemyBullet = struct {
    pub const speed: f32 = 900;
    pub const friction: f32 = 0;
    pub const size: f32 = 20;
    pub const team: u32 = 2;
    pub const damage: u32 = 50;
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
            _ = game.world.add(FireParticle{
                .pos = emit_pos + self.vel * vec.splat(rl.GetFrameTime()),
                .vel = vec.unit(game.prng.random().float(f32) * std.math.tau) *
                    vec.splat(100),
                .live_until = game.time + 100 - game.prng.random().int(u32) % 40,
                .size = intensity,
                .color = red,
            });
        }

        game.drawCenteredTexture(textures.enemy_bullet, self.pos, vec.ang(self.vel), size, rl.WHITE);
    }

    pub fn onCollision(self: *@This(), game: *Engine, other: Id) void {
        const health: *Engine.Health = game.world.field(other, .health) orelse return;
        _ = health.takeDamage(self, other, game);
        if (game.world.field(other, .reload_timer)) |t| t.* = game.time + World.cnst(other, .reload);
        game.queueDelete(self.id);
    }

    pub fn onDelete(self: *@This(), game: *Engine) void {
        for (0..10) |_| {
            _ = game.world.add(FireParticle{
                .pos = self.pos + self.vel * vec.splat(-rl.GetFrameTime()),
                .vel = vec.unit(game.prng.random().float(f32) * std.math.tau) *
                    vec.splat(200),
                .live_until = game.time + 200 - game.prng.random().int(u32) % 80,
                .size = 15,
                .color = red,
            });
        }
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

    const trt = self.world.add(Turret{ .pos = .{ ws, ws } });
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

    return self.world.ents.turret.items.len == 0;
}

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
stat_arena: std.heap.ArenaAllocator,

world: World = .{},
quad: Quad,

time: u32 = 0,
prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),

player: Id,
player_reload: u32 = 0,
player_boost: u32 = 0,
camera: rl.Camera2D,

sheet: rl.Texture2D,
textures: Textures,
stats: BuiltinStats = .{},
particles: BuiltinParticles = .{},

const std = @import("std");
const resources = @import("resources.zig");
const rl = @import("main.zig").rl;
const vec = @import("vec.zig");
const Vec = vec.T;
const World = @import("ecs.zig").World(cms);
const Quad = @import("QuadTree.zig");
const Game = @This();
const Id = World.Id;

const Textures = struct {
    player: Frame,
    enemy: Frame,
    bullet: Frame,
    fire: Frame,
    turret_cannon: Frame,
    turret: Frame,

    const Frame = resources.sprites.Frame;
    const info = @typeInfo(Textures).Struct;

    fn init(self: *Textures, gpa: std.mem.Allocator) !rl.Texture2D {
        var images: [info.fields.len]rl.Image = undefined;
        inline for (info.fields, &images) |field, *i| {
            const data = @embedFile("assets/" ++ field.name ++ ".png");
            i.* = rl.LoadImageFromMemory(".png", data, data.len);
        }

        const frames: *[info.fields.len]Frame = @ptrCast(self);
        return try resources.sprites.pack(gpa, &images, frames, 32);
    }
};

const BuiltinStats = struct {
    player: Stats = .{
        .fric = 1,
        .size = 15,
        .max_health = 100,
    },
    enemy: Stats = .{
        .fric = 1,
        .size = 15,
        .sight = 1000,
        .damage = 10,
        .team = 1,
        .max_health = 100,
    },
    turret: Stats = .{
        .fric = 10,
        .size = 30,
        .sight = 400,
        .team = 0,
        .max_health = 300,
        .reload = 300,
        .bullet = &.{
            .fric = 0,
            .speed = 1000,
            .size = 10,
            .team = 0,
            .damage = 10,
        },
    },
    bullet: Stats = .{
        .speed = 600,
        .fric = 0,
        .size = 5,
        .damage = 10,
    },
    fire: Stats = .{
        .fric = 4,
        .size = 10,
        .lifetime = 100,
        .color = rl.SKYBLUE,
    },
    enemy_fire: Stats = .{
        .fric = 4,
        .size = 10,
        .lifetime = 200,
        .color = rl.ORANGE,
    },
    bullet_trail: Stats = .{
        .fric = 1,
        .size = 7,
        .fade = false,
        .lifetime = 300,
        .color = rl.SKYBLUE,
    },
    boost_explosion: Stats = .{
        .fric = 10,
        .size = 20,
        .fade = true,
        .lifetime = 1000,
        .color = rl.SKYBLUE,
    },

    fn fillTextures(self: *BuiltinStats, textures: *const Textures) void {
        inline for (@typeInfo(Textures).Struct.fields) |field| {
            if (@hasField(BuiltinStats, field.name)) {
                @field(self, field.name).texture = &@field(textures, field.name);
            }

            if (comptime std.mem.endsWith(u8, field.name, "_cannon")) {
                @field(self, field.name[0 .. field.name.len - "_cannon".len]).cannon_texture =
                    &@field(textures, field.name);
            }
        }
    }
};

const Stats = struct {
    fric: f32 = 0,
    speed: f32 = 0,
    cannon_speed: f32 = 0,
    size: f32 = 0,

    lifetime: u32 = 0,
    fade: bool = true,
    color: rl.Color = rl.WHITE,
    texture: ?*const Textures.Frame = null,
    cannon_texture: ?*const Textures.Frame = null,

    team: u32 = 0,
    max_health: u32 = 0,
    damage: u32 = 0,
    sight: f32 = 0,
    reload: u32 = 0,
    bullet: ?*const Stats = null,

    fn mass(self: *const @This()) f32 {
        return std.math.pow(f32, self.size, 2) * std.math.pi;
    }

    fn scale(self: *const @This()) f32 {
        std.debug.assert(self.texture.?.r.f.width == self.texture.?.r.f.height);
        return self.size / (self.texture.?.r.f.width / 2);
    }
};

const BuiltinParticles = struct {
    fire: ParticleStats = .{
        .init_vel = 100,
        .offset = .after,
        .lifetime_variation = 40,
        .batch = 3,
    },
    enemy_fire: ParticleStats = .{
        .init_vel = 70,
        .offset = .after,
        .lifetime_variation = 40,
        .batch = 2,
    },
    bullet_trail: ParticleStats = .{},
    boost_explosion: ParticleStats = .{
        .init_vel = 1000,
        .offset = .after,
        .lifetime_variation = 100,
    },

    fn fillStats(self: *BuiltinParticles, stats: *const BuiltinStats) void {
        inline for (@typeInfo(BuiltinStats).Struct.fields) |field| {
            if (@hasField(BuiltinParticles, field.name)) {
                @field(self, field.name).particle = &@field(stats, field.name);
            }
        }
    }
};

const ParticleStats = struct {
    init_vel: f32 = 0,
    offset: enum { after, center } = .center,
    lifetime_variation: u32 = 1,
    spawn_rate: u32 = 0,
    batch: u32 = 1,
    particle: *const Stats = undefined,
};

const cms = struct {
    pub const Stt = struct { *const Stats };
    pub const Pos = struct { Vec };
    pub const Vel = struct { Vec };
    pub const Rot = struct { f32 };
    pub const Phy = struct {
        coll_id: u32 = std.math.maxInt(u32),
        quad: Quad.Id,
    };
    pub const Tmp = struct { u32 };
    pub const Nmy = struct {};
    pub const Hlt = struct {
        points: u32,
        hit_tween: u32 = 0,
    };
    pub const Prt = struct {};
    pub const Psr = struct {
        stats: *const ParticleStats,
        reload: u32 = 0,
    };
    pub const Trt = struct {
        rot: f32 = 0,
        reload: u32 = 0,
        target: Id = .{},
    };
};

const player_acc = 700.0;
const hit_tween_duration = 300;
const player_reload_time = 300;
const player_boost_rechagre = 300;

pub fn run() !void {
    rl.SetConfigFlags(rl.FLAG_FULLSCREEN_MODE);
    rl.SetTargetFPS(60);

    rl.InitWindow(0, 0, "slet");
    defer rl.CloseWindow();

    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = alloc.deinit();

    var self = try Game.init(alloc.allocator());
    defer self.deinit();

    self.stats.fillTextures(&self.textures);
    self.particles.fillStats(&self.stats);

    while (!rl.WindowShouldClose()) {
        self.player = try self.world.create(self.gpa, .{
            cms.Stt{&self.stats.player},
            cms.Pos{.{ 0, 0 }},
            cms.Vel{vec.zero},
            try self.createPhy(.{ 0, 0 }, self.stats.player.size),
            cms.Hlt{ .points = self.stats.player.max_health },
        });

        const spacing = 50;
        for (0..10) |i| {
            for (0..10) |j| {
                const pos = Vec{ spacing * @as(f32, @floatFromInt(i + 1)), spacing * @as(f32, @floatFromInt(j + 1)) };
                _ = try self.world.create(self.gpa, .{
                    cms.Stt{&self.stats.enemy},
                    cms.Pos{pos + Vec{ 200, 200 }},
                    cms.Vel{vec.zero},
                    try self.createPhy(pos, self.stats.enemy.size),
                    cms.Nmy{},
                    cms.Hlt{ .points = self.stats.enemy.max_health },
                    cms.Psr{ .stats = &self.particles.enemy_fire },
                });
            }
        }

        while (!rl.WindowShouldClose() and self.world.get(self.player) != null) {
            std.debug.assert(self.arena.reset(.retain_capacity));
            self.time = @intFromFloat(rl.GetTime() * 1000);

            try self.update();
            try self.input();

            rl.BeginDrawing();
            defer rl.EndDrawing();
            try self.draw();
        }

        try self.reset();
    }
}

fn init(gpa: std.mem.Allocator) !Game {
    var textures: Textures = undefined;
    return .{
        .sheet = try Textures.init(&textures, gpa),
        .textures = textures,

        .player = undefined,
        .camera = .{ .zoom = 1, .offset = .{ .x = 400, .y = 300 } },

        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .stat_arena = std.heap.ArenaAllocator.init(gpa),
        .world = .{},
        .quad = try Quad.init(gpa, 20),
    };
}

fn deinit(self: *Game) void {
    self.arena.deinit();
    self.stat_arena.deinit();
    self.world.deinit(self.gpa);
    self.quad.deinit(self.gpa);
}

fn reset(self: *Game) !void {
    self.world.deinit(self.gpa);
    self.quad.deinit(self.gpa);
    self.world = .{};
    self.quad = try Quad.init(self.gpa, 20);
}

fn createStats(self: *Game, stats: Stats) !cms.Stt {
    const alloc = try self.stat_arena.allocator().create(Stats);
    alloc.* = stats;
    return cms.Stt{alloc};
}

fn createPhy(self: *Game, pos: Vec, size: f32) !cms.Phy {
    return cms.Phy{ .quad = try self.quad.insert(
        self.gpa,
        vec.asInt(pos),
        @intFromFloat(size),
        self.world.nextId().toRaw(),
    ) };
}

fn input(self: *Game) !void {
    b: {
        const player = self.world.get(self.player) orelse break :b;
        const base = player.select(struct { cms.Stt, cms.Vel, cms.Pos }).?;

        const face = vec.norm(self.mousePos() - base.pos[0]);

        if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_RIGHT) and
            self.timer(&self.player_reload, player_reload_time))
        {
            try self.createBullet(
                &self.stats.bullet,
                base.stt[0],
                &self.particles.bullet_trail,
                base.pos[0],
                base.vel[0],
                face,
            );
        }

        self.camera.target = vec.asRl(base.pos[0]);
        self.camera.offset = .{
            .x = @floatFromInt(@divFloor(rl.GetScreenWidth(), 2)),
            .y = @floatFromInt(@divFloor(rl.GetScreenHeight(), 2)),
        };

        if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
            const trust = face * vec.splat(player_acc * rl.GetFrameTime());
            base.vel[0] += trust;

            try self.world.addComp(self.gpa, self.player, cms.Psr{ .stats = &self.particles.fire });
        } else {
            _ = try self.world.removeComp(self.gpa, self.player, cms.Psr);
        }

        const Attack = struct {
            start: u32,
            proj_timer: u32 = 0,
            left: bool,
            proj_counter: u32 = 5,
            face: Vec,
            boost_psr: cms.Psr,

            const speed_boost = 4000.0;
            const duration = 200;
            const cooldown = 400;
            const proj_latency = 10;

            var singleton: ?@This() = null;

            fn poll(slf: *@This(), game: *Game, bs: @TypeOf(base)) !bool {
                if (game.time > slf.start + duration) return true;

                const trust = slf.face * vec.splat(speed_boost * rl.GetFrameTime());
                bs.vel[0] += trust;
                const face_ang = vec.ang(slf.face);
                const playr = game.world.get(game.player).?;

                try game.runPsr(bs, &slf.boost_psr, face_ang, playr);

                if (game.timer(&slf.proj_timer, proj_latency)) {
                    var side = @as(f32, @floatFromInt(slf.proj_counter));
                    if (slf.left) side *= -1;
                    const pface = vec.rad(face_ang + std.math.pi / 30.0 * side, 1);
                    try game.createBullet(
                        &game.stats.bullet,
                        bs.stt[0],
                        &game.particles.bullet_trail,
                        bs.pos[0] + pface * vec.splat(30),
                        bs.vel[0] * vec.splat(0.2),
                        pface,
                    );

                    slf.proj_counter += 1;
                }

                //const face_ang = vec.ang(face);
                //const stats = self.particles.boost_explosion;
                //for (0..100) |_| {
                //    _ = try self.world.create(self.gpa, .{
                //        cms.Stt{stats.particle},
                //        cms.Pos{base.pos[0] + vec.unit(face_ang + (std.math.pi * 0.75) + self.prng.random().float(f32) * (std.math.pi / 2.0)) * vec.splat(10 + self.prng.random().float(f32) * 50)},
                //        cms.Vel{vec.unit(self.prng.random().float(f32) * std.math.tau) * vec.splat(100)},
                //        cms.Tmp{self.time + stats.particle.lifetime - self.prng.random().int(u32) % stats.lifetime_variation},
                //        cms.Prt{},
                //    });
                //}

                //for (5..15) |i| {
                //    const pface = vec.rad(face_ang + std.math.phi / 20.0 * @as(f32, @floatFromInt(i)), 1);
                //    try self.createBullet(
                //        &self.stats.bullet,
                //        base.stt[0],
                //        &self.particles.bullet_trail,
                //        base.pos[0] + pface * vec.splat(100),
                //        base.vel[0] * vec.splat(0.2),
                //        pface,
                //    );

                //    const kface = vec.rad(face_ang + std.math.phi / 20.0 * -@as(f32, @floatFromInt(i)), 1);
                //    try self.createBullet(
                //        &self.stats.bullet,
                //        base.stt[0],
                //        &self.particles.bullet_trail,
                //        base.pos[0] + kface * vec.splat(100),
                //        base.vel[0] * vec.splat(0.2),
                //        kface,
                //    );
                //}
                return false;
            }
        };

        if (Attack.singleton) |*at| {
            if (try at.poll(self, base)) {
                Attack.singleton = null;
            }
        }

        if ((rl.IsKeyDown(rl.KEY_D) or rl.IsKeyDown(rl.KEY_A)) and self.timer(&self.player_boost, Attack.cooldown)) {
            Attack.singleton = .{
                .left = rl.IsKeyDown(rl.KEY_A),
                .start = self.time,
                .face = face,
                .boost_psr = cms.Psr{ .stats = &self.particles.boost_explosion },
            };
        }
    }
}

fn createBullet(self: *Game, stats: *const Stats, from: *const Stats, trail: ?*const ParticleStats, origin: Vec, vel: Vec, dir: Vec) !void {
    const pos = dir * vec.splat(from.size + stats.size) + origin;
    if (trail) |tr| {
        _ = try self.world.create(self.gpa, .{
            cms.Stt{stats},
            cms.Pos{pos},
            cms.Vel{dir * vec.splat(stats.speed) + vel},
            try self.createPhy(pos, stats.size),
            cms.Tmp{self.time + 1000},
            cms.Psr{ .stats = tr },
        });
    } else {
        _ = try self.world.create(self.gpa, .{
            cms.Stt{stats},
            cms.Pos{pos},
            cms.Vel{dir * vec.splat(stats.speed) + vel},
            try self.createPhy(pos, stats.size),
            cms.Tmp{self.time + 1000},
        });
    }
}

fn mousePos(self: *Game) Vec {
    return vec.fromRl(rl.GetScreenToWorld2D(rl.GetMousePosition(), self.camera));
}

fn update(self: *Game) !void {
    const delta = rl.GetFrameTime();

    var to_delete = std.ArrayList(Id).init(self.arena.allocator());
    {
        var tmps = self.world.select(struct { cms.Tmp, Id });
        while (tmps.next()) |pb| {
            if (pb.tmp[0] < self.time) try to_delete.append(pb.id.*);
        }
    }

    {
        var quds = self.world.select(struct { Id, cms.Stt, cms.Pos, cms.Vel, cms.Phy });
        while (quds.next()) |qds| {
            const pos = vec.asInt(qds.pos[0] + qds.vel[0] * vec.splat(0.5));
            const size: i32 = @intFromFloat(qds.stt[0].size * 2 + vec.len(qds.vel[0]));
            try self.quad.update(self.gpa, &qds.phy.quad, pos, size, qds.id.toRaw());
        }
    }

    {
        const Q = struct { Id, cms.Vel, cms.Pos, cms.Stt, cms.Phy };
        var pbodies = self.world.select(Q);

        var collisions = std.ArrayList(struct { a: Id, b: Id, t: f32 }).init(self.arena.allocator());

        while (pbodies.next()) |pb| {
            const pos = vec.asInt(pb.pos[0] + pb.vel[0] * vec.splat(0.5));
            const size: i32 = @intFromFloat(pb.stt[0].size * 2 + vec.len(pb.vel[0]));
            const bb = .{ pos[0] - size, pos[1] - size, pos[0] + size, pos[1] + size };

            var query = self.quad.queryIter(bb, pb.phy.quad);
            while (query.next()) |qid| o: for (self.quad.entities(qid)) |id| {
                if (id == @as(u64, @bitCast(pb.id.*))) continue;
                const opb = self.world.selectOne(@bitCast(id), Q).?;

                const g = pb.stt[0].size + opb.stt[0].size;

                const dist = vec.dist2(pb.pos[0], opb.pos[0]);
                if (g * g > dist) {
                    if (pb.stt[0].size > opb.stt[0].size) {
                        opb.pos[0] = pb.pos[0] + vec.norm(opb.pos[0] - pb.pos[0]) * vec.splat(g);
                    } else {
                        pb.pos[0] = opb.pos[0] + vec.norm(pb.pos[0] - opb.pos[0]) * vec.splat(g);
                    }
                }

                const d = opb.pos[0] - pb.pos[0];
                const dv = opb.vel[0] - pb.vel[0];

                const a = vec.dot(dv, dv);
                const b = 2 * vec.dot(dv, d);
                const c = vec.dot(d, d) - g * g;

                const disc = b * b - 4 * a * c;
                if (disc <= 0) continue;

                const t1 = (-b + std.math.sqrt(disc)) / (2 * a);
                const t2 = (-b - std.math.sqrt(disc)) / (2 * a);
                const t = @min(t1, t2);

                if (t < 0 or t > delta) continue;

                inline for (.{ pb, opb }) |p| {
                    if (p.phy.coll_id != std.math.maxInt(u32))
                        if (collisions.items[p.phy.coll_id].t > t) {
                            collisions.items[p.phy.coll_id].t = delta;
                        } else continue :o;
                }

                pb.phy.coll_id = @intCast(collisions.items.len);
                opb.phy.coll_id = @intCast(collisions.items.len);

                try collisions.append(.{ .a = pb.id.*, .b = opb.id.*, .t = t });
            };
        }

        for (collisions.items) |col| {
            const a = self.world.get(col.a).?;
            const b = self.world.get(col.b).?;
            const pb = a.select(Q).?;
            const opb = b.select(Q).?;

            pb.phy.coll_id = std.math.maxInt(u32);
            opb.phy.coll_id = std.math.maxInt(u32);

            if (col.t == delta) continue;

            pb.pos[0] += pb.vel[0] * vec.splat(col.t);
            opb.pos[0] += opb.vel[0] * vec.splat(col.t);

            const dist = vec.dist(pb.pos[0], opb.pos[0]);

            {
                const mass = pb.stt[0].mass();
                const amass = opb.stt[0].mass();

                const norm = (opb.pos[0] - pb.pos[0]) / vec.splat(dist);
                const p = 2 * (vec.dot(pb.vel[0], norm) - vec.dot(opb.vel[0], norm)) / (mass + amass);

                inline for (.{ pb, opb }, .{ -amass, mass }) |c, m| {
                    c.vel[0] += vec.splat(p * m) * norm;
                    c.pos[0] += c.vel[0] * vec.splat(delta - col.t);
                    c.pos[0] -= c.vel[0] * vec.splat(delta);
                }
            }

            inline for (.{ pb, opb }, .{ opb, pb }, .{ b, a }, .{ col.b, col.a }) |p, q, e, i|
                if (p.stt[0].damage > 0 and p.stt[0].team != q.stt[0].team) if (e.get(cms.Hlt)) |hlt| {
                    hlt.points -|= p.stt[0].damage;
                    if (hlt.points == 0) try to_delete.append(i);
                    hlt.hit_tween = self.time + hit_tween_duration;
                };
        }
    }

    {
        var trts = self.world.select(struct { cms.Trt, cms.Pos, cms.Stt });
        while (trts.next()) |tr| {
            if (self.world.get(tr.trt.target)) |target| b: {
                var pos = (target.get(cms.Pos) orelse break :b)[0];

                if (vec.dist(pos, tr.pos[0]) > tr.stt[0].sight) {
                    break :b;
                }

                if (target.get(cms.Vel)) |vel| {
                    const speed = tr.stt[0].bullet.?.speed;
                    const tvel = vel[0];
                    pos = predictTarget(tr.pos[0], pos, tvel, speed) orelse {
                        break :b;
                    };
                }

                const dir = vec.norm(pos - tr.pos[0]);
                tr.trt.rot = vec.ang(dir);

                if (self.timer(&tr.trt.reload, tr.stt[0].reload)) {
                    try self.createBullet(tr.stt[0].bullet.?, tr.stt[0], null, tr.pos[0], vec.zero, dir);
                }

                continue;
            }
            tr.trt.target = .{};

            const pos = vec.asInt(tr.pos[0]);
            const size: i32 = @intFromFloat(tr.stt[0].sight);
            const bds = .{ pos[0] - size, pos[1] - size, pos[0] + size, pos[1] + size };
            var iter = self.quad.queryIter(bds, 0);
            o: while (iter.next()) |quid| for (self.quad.entities(quid)) |rid| {
                const id: Id = @bitCast(rid);
                const target = self.world.get(id) orelse continue;
                const ls = target.select(struct { cms.Stt, cms.Pos }) orelse continue;
                if (ls.stt[0].team == tr.stt[0].team) continue;
                if (vec.dist(ls.pos[0], tr.pos[0]) > tr.stt[0].sight) continue;
                tr.trt.target = id;
                break :o;
            };
        }
    }

    b: {
        const player = self.world.selectOne(self.player, struct { cms.Pos }) orelse break :b;
        var nmies = self.world.select(struct { cms.Pos, cms.Nmy, cms.Vel, cms.Stt });
        while (nmies.next()) |nm| {
            if (vec.dist(nm.pos[0], player.pos[0]) > nm.stt[0].sight) continue;
            nm.vel[0] += vec.norm(player.pos[0] - nm.pos[0]) * vec.splat(400 * delta);
        }
    }

    {
        var bodies = self.world.select(struct { cms.Vel, cms.Pos, cms.Stt });
        while (bodies.next()) |ent| {
            ent.pos[0] += ent.vel[0] * vec.splat(delta);
            ent.vel[0] *= vec.splat(1 - ent.stt[0].fric * delta);
        }
    }

    for (to_delete.items) |id| {
        const e = self.world.get(id).?;
        if (e.get(cms.Phy)) |phy|
            self.quad.remove(
                self.gpa,
                phy.quad,
                @bitCast(id),
            );
        // TODO: explode
        std.debug.assert(self.world.remove(id));
    }
}

fn draw(self: *Game) !void {
    rl.ClearBackground(rl.BLACK);

    rl.BeginMode2D(self.camera);
    rl.DrawLine(0, 0, 0, 10000, rl.WHITE);

    {
        var iter = self.world.select(struct { cms.Prt, cms.Pos, cms.Stt, cms.Tmp });
        while (iter.next()) |pt| {
            const rate = divToFloat(self.timeRem(pt.tmp[0]) orelse 0, pt.stt[0].lifetime);
            const color = if (pt.stt[0].fade) rl.ColorAlpha(pt.stt[0].color, rate) else pt.stt[0].color;
            rl.DrawCircleV(vec.asRl(pt.pos[0]), pt.stt[0].size * rate, color);
        }
    }

    {
        const player = self.world.selectOne(self.player, struct { cms.Pos }) orelse return;
        const width = @divFloor(rl.GetScreenWidth(), 2);
        const height = @divFloor(rl.GetScreenHeight(), 2);
        const cx, const cy = vec.asInt(player.pos[0]);
        const bounds: [4]i32 = .{ cx - width, cy - height, cx + width, cy + height };

        var iter = self.quad.queryIter(bounds, 0);
        while (iter.next()) |quid| for (self.quad.entities(quid)) |uid| {
            const id: Id = @bitCast(uid);
            const pb = self.world.get(id).?;

            const base = pb.select(struct { cms.Pos, cms.Stt }).?;

            const rot = if (std.meta.eql(id, self.player))
                vec.ang(self.mousePos() - base.pos[0])
            else if (pb.get(cms.Vel)) |vel| vec.ang(vel[0]) else 0.0;

            var tone: f32 = 1;
            var health_bar_perc: f32 = 0;
            if (pb.get(cms.Hlt)) |hlt| {
                if (self.timeRem(hlt.hit_tween)) |n| {
                    tone -= divToFloat(n, hit_tween_duration);
                }

                if (hlt.points != base.stt[0].max_health) {
                    health_bar_perc = divToFloat(hlt.points, base.stt[0].max_health);
                }
            }

            if (base.stt[0].texture) |tx| {
                self.drawCenteredTexture(tx, base.pos[0], rot, base.stt[0].scale(), fcolor(1, tone, tone));
                if (health_bar_perc != 0) {
                    const end = 360 * health_bar_perc;
                    const size = base.stt[0].size;
                    rl.DrawRing(vec.asRl(base.pos[0]), size + 5, size + 8, 0.0, end, 50, rl.GREEN);
                }
            } else {
                rl.DrawCircleV(vec.asRl(base.pos[0]), base.stt[0].size, rl.RED);
            }

            if (pb.get(cms.Trt)) |trt| b: {
                const tex = base.stt[0].cannon_texture orelse break :b;
                self.drawCenteredTexture(tex, base.pos[0], trt.rot, base.stt[0].scale(), fcolor(1, tone, tone));
            }

            if (pb.get(cms.Psr)) |psr| try self.runPsr(base, psr, rot, pb);
        };
    }

    rl.EndMode2D();

    rl.DrawFPS(20, 20);
}

fn runPsr(self: *Game, base: anytype, psr: *cms.Psr, rot: f32, pb: World.Entity) !void {
    if (!self.timer(&psr.reload, psr.stats.spawn_rate)) return;

    const face = vec.unit(rot);
    const offset = switch (psr.stats.offset) {
        .center => vec.zero,
        .after => face * vec.splat(-base.stt[0].size - if (psr.stats.particle.size > base.stt[0].size) psr.stats.particle.size else 0),
    };

    const vel = if (pb.get(cms.Vel)) |vel| vel[0] else vec.zero;

    for (0..psr.stats.batch) |_| {
        _ = try self.world.create(self.gpa, .{
            cms.Stt{psr.stats.particle},
            cms.Pos{base.pos[0] + offset + vel * vec.splat(rl.GetFrameTime())},
            cms.Vel{vec.unit(self.prng.random().float(f32) * std.math.tau) * vec.splat(psr.stats.init_vel)},
            cms.Tmp{self.time + psr.stats.particle.lifetime - self.prng.random().int(u32) % psr.stats.lifetime_variation},
            cms.Prt{},
        });
    }
}

fn timer(self: *Game, time: *u32, duration: u32) bool {
    if (time.* > self.time) return false;
    time.* = self.time + duration;
    return true;
}

fn timeRem(self: *Game, time: u32) ?u32 {
    return std.math.sub(u32, time, self.time) catch null;
}

fn divToFloat(a: anytype, b: @TypeOf(a)) f32 {
    return @as(f32, @floatFromInt(a)) / @as(f32, @floatFromInt(b));
}

fn fcolor(r: f32, g: f32, b: f32) rl.Color {
    return .{
        .r = @intFromFloat(r * 255),
        .g = @intFromFloat(g * 255),
        .b = @intFromFloat(b * 255),
        .a = 255,
    };
}

fn predictTarget(turret: Vec, target: Vec, target_vel: Vec, bullet_speed: f32) ?Vec {
    const rel = target - turret;
    const a = vec.dot(target_vel, target_vel) - bullet_speed * bullet_speed;
    if (a == 0) return target;
    const b = 2 * vec.dot(target_vel, rel);
    const c = vec.dot(rel, rel);
    const d = b * b - 4 * a * c;
    if (d < 0) return null;
    const t = (-b - std.math.sqrt(d)) / (2 * a);
    return target + target_vel * vec.splat(t);
}

inline fn drawCenteredTexture(self: *Game, texture: *const Textures.Frame, pos: Vec, rot: f32, scale: f32, color: rl.Color) void {
    const real_width = texture.r.f.width * scale;
    const real_height = texture.r.f.height * scale;
    const dst = .{ .x = pos[0], .y = pos[1], .width = real_width, .height = real_height };
    const origin = .{ .x = real_width / 2, .y = real_height / 2 };
    rl.DrawTexturePro(self.sheet, texture.r.f, dst, origin, rot / std.math.tau * 360, color);
}

inline fn tof(value: anytype) f32 {
    return @floatFromInt(value);
}

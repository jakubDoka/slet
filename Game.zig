gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
stat_arena: std.heap.ArenaAllocator,

world: World = .{},
quad: Quad,

time: u32 = 0,
prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),

player: Id,
player_reload: u32 = 0,
camera: rl.Camera2D,

textures: Textures,
stats: BuiltinStats = .{},

const std = @import("std");
const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
    @cInclude("rlgl.h");
});
const vec = @import("vec.zig");
const Vec = vec.T;
const World = @import("ecs.zig").World(cms);
const Quad = @import("QuadTree.zig");
const Game = @This();
const Id = World.Id;

const Textures = struct {
    player: rl.Texture2D,
    meteor: rl.Texture2D,
    bullet: rl.Texture2D,
    fire: rl.Texture2D,

    fn init() Textures {
        var tex: Textures = undefined;
        inline for (@typeInfo(@TypeOf(tex)).Struct.fields) |field| {
            @field(tex, field.name) = rl.LoadTexture("assets/" ++ field.name ++ ".png");
        }
        return tex;
    }

    fn deinit(self: *Textures) void {
        inline for (@typeInfo(Textures).Struct.fields) |field| {
            rl.UnloadTexture(@field(self, field.name));
        }
    }
};

const BuiltinStats = struct {
    player: Stats = .{
        .fric = 1,
        .size = 15,
        .max_health = 100,
    },
    meteor: Stats = .{
        .fric = 1,
        .size = 20,
        .sight = 1000,
        .damage = 10,
        .team = 1,
        .max_health = 100,
    },
    bullet: Stats = .{
        .fric = 0.5,
        .size = 5,
        .damage = 10,
    },
    fire: Stats = .{
        .fric = 4,
        .size = 10,
    },

    fn fillTextures(self: *BuiltinStats, textures: *const Textures) void {
        inline for (@typeInfo(Textures).Struct.fields) |field| {
            if (@hasField(BuiltinStats, field.name)) {
                @field(self, field.name).texture = &@field(textures, field.name);
            }
        }
    }
};

const Stats = struct {
    fric: f32 = 0,
    acc: f32 = 0,
    size: f32 = 0,
    sight: f32 = 0,
    damage: u32 = 0,
    team: u32 = 0,
    max_health: u32 = 0,
    texture: ?*const rl.Texture2D = null,

    fn mass(self: *const @This()) f32 {
        return std.math.pow(f32, self.size, 2) * std.math.pi;
    }

    fn scale(self: *const @This()) f32 {
        std.debug.assert(self.texture.?.width == self.texture.?.height);
        return self.size / @as(f32, @floatFromInt(@divFloor(self.texture.?.width, 2)));
    }
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
};

const player_acc = 700.0;
const hit_tween_duration = 300;
const player_reload_time = 300;

pub fn run() !void {
    rl.SetTargetFPS(60);

    rl.InitWindow(800, 600, "slet");
    defer rl.CloseWindow();

    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = alloc.deinit();
    var self = try Game.init(alloc.allocator());
    defer self.deinit();

    self.stats.fillTextures(&self.textures);

    self.player = try self.world.create(self.gpa, .{
        cms.Stt{&self.stats.player},
        cms.Pos{.{ 0, 0 }},
        cms.Vel{vec.zero},
        try self.createPhy(.{ 0, 0 }, self.stats.player.size),
        cms.Hlt{ .points = self.stats.player.max_health },
    });

    for (0..4) |i| {
        for (0..4) |j| {
            const pos = .{ 80 * @as(f32, @floatFromInt(i + 1)), 80 * @as(f32, @floatFromInt(j + 1)) };
            _ = try self.world.create(self.gpa, .{
                cms.Stt{&self.stats.meteor},
                cms.Pos{pos},
                cms.Vel{vec.zero},
                try self.createPhy(pos, self.stats.meteor.size),
                cms.Nmy{},
                cms.Hlt{ .points = self.stats.meteor.max_health },
            });
        }
    }

    while (!rl.WindowShouldClose()) {
        std.debug.assert(self.arena.reset(.retain_capacity));
        self.time = @intFromFloat(rl.GetTime() * 1000);

        try self.update();
        try self.input();

        rl.BeginDrawing();
        defer rl.EndDrawing();
        try self.draw();
    }
}

fn init(gpa: std.mem.Allocator) !Game {
    return .{
        .textures = Textures.init(),

        .player = undefined,
        .camera = .{ .zoom = 1.5, .offset = .{ .x = 400, .y = 300 } },

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

    self.textures.deinit();
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
        const player = self.world.selectOne(
            self.player,
            struct { cms.Stt, cms.Vel, cms.Pos },
        ) orelse break :b;

        const face = vec.norm(self.mousePos() - player.pos[0]);

        if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
            const trust = face * vec.splat(player_acc * rl.GetFrameTime());
            player.vel[0] += trust;

            _ = try self.world.create(self.gpa, .{
                cms.Stt{&self.stats.fire},
                cms.Pos{player.pos[0] - face * vec.splat(player.stt[0].size)},
                cms.Vel{vec.unit(self.prng.random().float(f32) * std.math.tau) * vec.splat(100)},
                cms.Tmp{self.time + 100 - self.prng.random().int(u32) % 40},
                cms.Prt{},
            });
        }

        if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_RIGHT) and
            self.timer(&self.player_reload, player_reload_time))
        {
            const pos = face * vec.splat(player.stt[0].size + 10) + player.pos[0];
            const vel = face * vec.splat(1000);
            _ = try self.world.create(self.gpa, .{
                cms.Stt{&self.stats.bullet},
                cms.Pos{pos},
                cms.Vel{vel},
                try self.createPhy(pos, self.stats.bullet.size),
                cms.Tmp{self.time + 1000},
            });
        }

        self.camera.target = vec.asRl(player.pos[0]);
        self.camera.offset = .{
            .x = @floatFromInt(@divFloor(rl.GetScreenWidth(), 2)),
            .y = @floatFromInt(@divFloor(rl.GetScreenHeight(), 2)),
        };
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
        if (self.world.selectOne(id, struct { cms.Phy })) |n|
            self.quad.remove(n.phy.quad, @bitCast(id));
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
            const rate = divToFloat(self.timeRem(pt.tmp[0]) orelse 0, 100);
            rl.DrawCircleV(vec.asRl(pt.pos[0]), pt.stt[0].size * rate, rl.ColorAlpha(rl.ORANGE, rate));
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

            const rot = if (std.meta.eql(id, self.player)) vec.ang(self.mousePos() - base.pos[0]) else 0;

            if (base.stt[0].texture) |tx| {
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
                drawCenteredTexture(tx.*, base.pos[0], rot, base.stt[0].scale(), fcolor(1, tone, tone));
                if (health_bar_perc != 0) {
                    const end = 360 * health_bar_perc;
                    const size = base.stt[0].size;
                    rl.DrawRing(vec.asRl(base.pos[0]), size + 5, size + 8, 0.0, end, 50, rl.GREEN);
                }
            } else {
                rl.DrawCircleV(vec.asRl(base.pos[0]), base.stt[0].size, rl.RED);
            }
        };
    }

    rl.EndMode2D();

    rl.DrawFPS(20, 20);
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

inline fn drawCenteredTexture(texture: rl.Texture2D, pos: Vec, rot: f32, scale: f32, color: rl.Color) void {
    const real_width = tof(texture.width) * scale;
    const real_height = tof(texture.height) * scale;
    rl.DrawTexturePro(
        texture,
        rl.Rectangle{ .x = 0, .y = 0, .width = tof(texture.width), .height = tof(texture.height) },
        rl.Rectangle{ .x = pos[0], .y = pos[1], .width = real_width, .height = real_height },
        rl.Vector2{ .x = real_width / 2, .y = real_height / 2 },
        rot / std.math.tau * 360,
        color,
    );
}

inline fn tof(value: anytype) f32 {
    return @floatFromInt(value);
}

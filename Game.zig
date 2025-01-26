gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
stat_arena: std.heap.ArenaAllocator,

world: World = .{},
quad: Quad,

time: u32 = 0,
prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),

player: Id,
player_reload: u32 = 0,
player_attacks: [max_attacks]Attack = .{Attack.none} ** max_attacks,
camera: rl.Camera2D,

const std = @import("std");
const resources = @import("resources.zig");
const rl = @import("main.zig").rl;
const attacks = @import("attacks.zig");
const assets = @import("assets.zig");
const vec = @import("vec.zig");
const levels = @import("levels.zig");

const Vec = vec.T;
const World = @import("ecs.zig").World(cms);
const Quad = @import("QuadTree.zig");
const Game = @This();
const Id = World.Id;
const Attack = assets.Attack;
const Stats = assets.Stats;
const ParticleStats = assets.ParticleStats;
const tof = @import("main.zig").tof;

pub const cms = struct {
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
    pub const Prt = struct { face: f32 = 0.0 };
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

var sheet: rl.Texture2D = undefined;

const hit_tween_duration = 100;
const player_reload_time = 300;
const max_attacks = 4;

pub fn run() !void {
    rl.SetConfigFlags(rl.FLAG_FULLSCREEN_MODE);
    rl.SetTargetFPS(60);

    rl.InitWindow(0, 0, "slet");
    defer rl.CloseWindow();

    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = alloc.deinit();

    var level_vl: assets.Level = undefined;
    var level = &level_vl;
    try level.init(levels.Level1, &sheet, alloc.allocator());

    var self = try Game.init(alloc.allocator());
    defer self.deinit();

    while (!rl.WindowShouldClose()) {
        try level.mount(&self);

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
    return .{
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

pub fn reset(self: *Game) !void {
    self.world.deinit(self.gpa);
    self.quad.deinit(self.gpa);
    self.world = .{};
    self.quad = try Quad.init(self.gpa, 20);
    self.player_attacks = .{Attack.none} ** max_attacks;
}

fn createStats(self: *Game, stts: Stats) !cms.Stt {
    const alloc = try self.stat_arena.allocator().create(Stats);
    alloc.* = stts;
    return cms.Stt{alloc};
}

pub fn createPhy(self: *Game, pos: Vec, size: f32) !cms.Phy {
    return cms.Phy{ .quad = try self.quad.insert(
        self.gpa,
        vec.asInt(pos),
        @intFromFloat(size),
        self.world.nextId().toRaw(),
    ) };
}

fn input(self: *Game) !void {
    const player = self.world.get(self.player) orelse return;
    const base = player.select(struct { cms.Stt, cms.Vel, cms.Pos }).?;

    const face = vec.norm(self.mousePos() - base.pos[0]);
    const stt = base.stt[0];

    if (base.stt[0].bullet) |b|
        if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_RIGHT) and
            self.timer(&self.player_reload, player_reload_time))
        {
            try self.createBullet(
                b.value,
                base.stt[0],
                base.pos[0],
                base.vel[0],
                face,
            );
        };

    self.camera.target = vec.asRl(base.pos[0]);
    self.camera.offset = .{
        .x = tof(@divFloor(rl.GetScreenWidth(), 2)),
        .y = tof(@divFloor(rl.GetScreenHeight(), 2)),
    };

    if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
        const trust = face * vec.splat(stt.speed * rl.GetFrameTime());
        base.vel[0] += trust;

        if (stt.trail) |t| {
            try self.world.addComp(self.gpa, self.player, cms.Psr{ .stats = t.value });
        }
    } else {
        _ = try self.world.removeComp(self.gpa, self.player, cms.Psr);
    }

    const screen_height = rl.GetScreenHeight();

    for (&self.player_attacks, 0..) |*at, i| {
        if (at.trigger == rl.KEY_NULL) break;

        const key_scale = 2;
        const key_size = 32 * key_scale;
        const padding = 8;

        var frame_color = rl.WHITE;
        var charge_color = rl.SKYBLUE;

        if (!rl.IsKeyDown(at.trigger)) {
            frame_color = rl.GRAY;
            charge_color.a = 128;
        }

        const frame_pos = Vec{
            tof(i * (key_size + padding) + padding),
            tof(screen_height - key_size - padding),
        };

        rl.DrawRectangleV(
            vec.asRl(frame_pos + vec.splat(2)),
            vec.asRl(Vec{ key_size, tof(key_size) * at.progress(self) } - vec.splat(4)),
            charge_color,
        );

        drawTexture(&at.texture, frame_pos, key_scale, frame_color);

        try at.tryTrigger(self);
    }
}

pub fn createBullet(self: *Game, stts: *const Stats, from: *const Stats, origin: Vec, vel: Vec, dir: Vec) !void {
    const pos = dir * vec.splat(from.size + stts.size) + origin;
    if (stts.trail) |tr| {
        _ = try self.world.create(self.gpa, .{
            cms.Stt{stts},
            cms.Pos{pos},
            cms.Vel{dir * vec.splat(stts.speed) + vel},
            try self.createPhy(pos, stts.size),
            cms.Tmp{self.time + 1000},
            cms.Psr{ .stats = tr.value },
        });
    } else {
        _ = try self.world.create(self.gpa, .{
            cms.Stt{stts},
            cms.Pos{pos},
            cms.Vel{dir * vec.splat(stts.speed) + vel},
            try self.createPhy(pos, stts.size),
            cms.Tmp{self.time + 1000},
        });
    }
}

pub fn mousePos(self: *Game) Vec {
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

                if (opb.stt[0].team == pb.stt[0].team and pb.stt[0].max_health == 0 and opb.stt[0].max_health == 0) continue;

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
                    const speed = tr.stt[0].bullet.?.value.speed;
                    const tvel = vel[0];
                    pos = predictTarget(tr.pos[0], pos, tvel, speed) orelse {
                        break :b;
                    };
                }

                const dir = vec.norm(pos - tr.pos[0]);
                tr.trt.rot = vec.ang(dir);

                if (self.timer(&tr.trt.reload, tr.stt[0].reload)) {
                    try self.createBullet(tr.stt[0].bullet.?.value, tr.stt[0], tr.pos[0], vec.zero, dir);
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
            nm.vel[0] += vec.norm(player.pos[0] - nm.pos[0]) * vec.splat(nm.stt[0].speed * delta);
        }

        for (&self.player_attacks) |*at| if (at.trigger != rl.KEY_NULL) {
            try at.tryPoll(self);
        };
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
            if (pt.stt[0].texture) |t| {
                drawCenteredTexture(t.value, pt.pos[0], pt.prt.face, pt.stt[0].scale(), color);
            } else {
                rl.DrawCircleV(vec.asRl(pt.pos[0]), pt.stt[0].size * rate, color);
            }
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
                drawCenteredTexture(tx.value, base.pos[0], rot, base.stt[0].scale(), fcolor(1, tone, tone));
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
                drawCenteredTexture(tex.value, base.pos[0], trt.rot, base.stt[0].scale(), fcolor(1, tone, tone));
            }

            if (pb.get(cms.Psr)) |psr| try self.runPsr(base, psr, rot, pb);
        };

        for (&self.player_attacks) |*at| if (at.trigger != rl.KEY_NULL) {
            const pos = at.crossHarePos(self);
            var color = rl.SKYBLUE;
            if (at.progress(self) != 1) color.a = 128;
            rl.DrawCircleV(vec.asRl(pos), 5, color);
        };

        const pos = player.pos[0];
        const tl = vec.fromRl(rl.GetScreenToWorld2D(vec.asRl(vec.zero), self.camera));
        const r = tof(rl.GetScreenWidth());
        const b = tof(rl.GetScreenHeight());
        const br = vec.fromRl(rl.GetScreenToWorld2D(vec.asRl(.{ r, b }), self.camera));
        const radius = 20;
        const font_size = 14;

        var dots = std.ArrayList(struct { Vec, usize }).init(self.arena.allocator());
        var nmys = self.world.select(struct { cms.Pos, cms.Nmy });
        while (nmys.next()) |el| {
            const point =
                intersect(0, el.pos[0], pos, tl[1], tl[0], br[0]) orelse
                intersect(0, el.pos[0], pos, br[1], tl[0], br[0]) orelse
                intersect(1, el.pos[0], pos, tl[0], tl[1], br[1]) orelse
                intersect(1, el.pos[0], pos, br[0], tl[1], br[1]);

            if (point) |p| {
                for (dots.items) |*op| {
                    const diameter = radius * 2;
                    if (vec.dist2(op[0], p) < tof(diameter * diameter)) {
                        op[1] += 1;
                        break;
                    }
                } else try dots.append(.{ p, 1 });
            }
        }

        var buf: [10]u8 = undefined;
        for (dots.items) |*p| {
            var allc = std.heap.FixedBufferAllocator.init(&buf);
            const num = try std.fmt.allocPrintZ(allc.allocator(), "{d}", .{p[1]});
            const text_size = vec.fromRl(rl.MeasureTextEx(rl.GetFontDefault(), num, font_size, 0)) * vec.splat(0.5);
            const clamp_size = text_size + vec.splat(4);
            p[0] = std.math.clamp(p[0], tl + clamp_size, br - clamp_size);
            rl.DrawCircleV(vec.asRl(p[0]), tof(radius), rl.RED);
            const point = vec.asInt(p[0] - text_size);
            rl.DrawText(num, point[0], point[1], font_size, rl.WHITE);
        }
    }

    rl.EndMode2D();

    rl.DrawFPS(20, 20);
}

pub fn runPsr(self: *Game, base: anytype, psr: *cms.Psr, rot: f32, pb: World.Entity) !void {
    if (!self.timer(&psr.reload, psr.stats.spawn_rate)) return;

    const face = vec.unit(rot);
    const offset = switch (psr.stats.offset) {
        .center => vec.zero,
        .after => face * vec.splat(-base.stt[0].size - if (psr.stats.particle.value.size > base.stt[0].size) psr.stats.particle.value.size else 0),
    };

    const vel = if (pb.get(cms.Vel)) |vel| vel[0] else vec.zero;

    for (0..psr.stats.batch) |_| {
        _ = try self.world.create(self.gpa, .{
            cms.Stt{psr.stats.particle.value},
            cms.Pos{base.pos[0] + offset + vel * vec.splat(rl.GetFrameTime())},
            cms.Vel{vec.unit(self.prng.random().float(f32) * std.math.tau) * vec.splat(psr.stats.init_vel)},
            cms.Tmp{self.time + psr.stats.particle.value.lifetime - self.prng.random().int(u32) % psr.stats.lifetime_variation},
            cms.Prt{ .face = rot },
        });
    }
}

pub fn timer(self: *Game, time: *u32, duration: u32) bool {
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

fn intersect(comptime xd: usize, a: Vec, b: Vec, y: f32, mx: f32, xx: f32) ?Vec {
    const yd = 1 - xd;

    if ((a[yd] > y) == (b[yd] > y)) return null;

    const cof = (y - b[yd]) / (a[yd] - b[yd]);

    const x = (a[xd] - b[xd]) * cof + b[xd];

    if (x > xx or mx > x) return null;

    var res = vec.zero;
    res[xd] = x;
    res[yd] = y;
    return res;
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

inline fn drawTexture(texture: *const assets.Frame, pos: Vec, scale: f32, color: rl.Color) void {
    const real_width = texture.r.f.width * scale;
    const real_height = texture.r.f.height * scale;
    const dst = .{ .x = pos[0], .y = pos[1], .width = real_width, .height = real_height };
    const origin = .{ .x = 0, .y = 0 };
    rl.DrawTexturePro(sheet, texture.r.f, dst, origin, 0, color);
}

inline fn drawCenteredTexture(texture: *const assets.Frame, pos: Vec, rot: f32, scale: f32, color: rl.Color) void {
    const real_width = texture.r.f.width * scale;
    const real_height = texture.r.f.height * scale;
    const dst = .{ .x = pos[0], .y = pos[1], .width = real_width, .height = real_height };
    const origin = .{ .x = real_width / 2, .y = real_height / 2 };
    rl.DrawTexturePro(sheet, texture.r.f, dst, origin, rot / std.math.tau * 360, color);
}

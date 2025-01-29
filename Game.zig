gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
stat_arena: std.heap.ArenaAllocator,

world: World,
quad: Quad,

time: u32 = 0,
prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),

player: Id,
player_reload: u32 = 0,
//player_attacks: [max_attacks]Attack = .{Attack.none} ** max_attacks,
bindings: [max_attacks]c_int = .{ rl.KEY_S, rl.KEY_D, rl.KEY_NULL, rl.KEY_NULL },
camera: rl.Camera2D,

const std = @import("std");
const resources = @import("resources.zig");
const rl = @import("main.zig").rl;
const attacks = @import("attacks.zig");
const assets = @import("assets.zig");
const vec = @import("vec.zig");
const levels = @import("levels.zig");

const Vec = vec.T;
const World = @import("ecs.zig").World(Ents);
const Quad = @import("QuadTree.zig");
const Game = @This();
const Id = @import("ecs.zig").Id;
//const Attack = assets.Attack;
const Stats = assets.Stats;
const ParticleStats = assets.ParticleStats;
const tof = @import("main.zig").tof;

pub const Ents = union(enum) {
    player: struct {
        pub const friction: f32 = 2;
        pub const max_health: u32 = 100;
        pub const size: f32 = 20;
        pub const speed: f32 = 700;

        id: Id = undefined,
        pos: Vec = vec.zero,
        vel: Vec = vec.zero,
        health: Hlt = .{ .points = max_health },
        phys: Phy = .{},

        pub fn draw(self: *@This()) void {
            _ = self; // autofix
        }
    },

    pub const Hlt = struct {
        points: u32,
        hit_tween: u32 = 0,
    };

    pub const Phy = struct {
        coll_id: u32 = std.math.maxInt(u32),
        quad: Quad.Id = undefined,
    };

    // pub const Stt = struct { *const Stats };
    // pub const Pos = struct { Vec };
    // pub const Vel = struct { Vec };
    // pub const Rot = struct { f32 };
    // pub const Tmp = struct { u32 };
    // pub const Nmy = struct {};
    // pub const Hom = struct {
    //     target: Id = .{},
    // };
    // pub const Prt = struct { face: f32 = 0.0 };
    // pub const Psr = struct {
    //     stats: *const ParticleStats,
    //     reload: u32 = 0,
    //     dir: ?ParticleStats.Dir = null,
    // };
    // pub const Trt = struct {
    //     rot: f32 = 0,
    //     reload: u32 = 0,
    //     target: Id = .{},
    // };
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

    //  var level_vl: assets.Level = undefined;
    //  var level = &level_vl;
    //  try level.init(levels.DodgeGun, &sheet, alloc.allocator());

    //var self = try level(Spec, alloc.allocator());
    //defer self.deinit();

    //self.player = self.world.add(.player, .{});
    //try self.initPhy(self.player, .player);

    //while (!rl.WindowShouldClose()) {
    //    //     try level.mount(&self);

    //    while (!rl.WindowShouldClose() and self.world.get(self.player, .player) != null) {
    //        std.debug.assert(self.arena.reset(.retain_capacity));
    //        self.time = @intFromFloat(rl.GetTime() * 1000);

    //        try self.update();
    //        try self.input();

    //        rl.BeginDrawing();
    //        defer rl.EndDrawing();
    //        try self.draw();
    //    }

    //    try self.reset();
    //}
}

fn init(gpa: std.mem.Allocator) !Game {
    return .{
        .player = undefined,
        .camera = .{ .zoom = 1, .offset = .{ .x = 400, .y = 300 } },

        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .stat_arena = std.heap.ArenaAllocator.init(gpa),
        .world = .{ .gpa = gpa },
        .quad = try Quad.init(gpa, 20),
    };
}

fn deinit(self: *Game) void {
    self.arena.deinit();
    self.stat_arena.deinit();
    self.world.deinit();
    self.quad.deinit(self.gpa);
}

pub fn reset(self: *Game) !void {
    self.world.deinit();
    self.quad.deinit(self.gpa);
    self.world = .{ .gpa = self.gpa };
    self.quad = try Quad.init(self.gpa, 20);
    //self.player_attacks = .{Attack.none} ** max_attacks;
}

fn createStats(self: *Game, stts: Stats) !Ents.Stt {
    const alloc = try self.stat_arena.allocator().create(Stats);
    alloc.* = stts;
    return Ents.Stt{alloc};
}

pub fn initPhy(self: *Game, id: Id, comptime tag: anytype) !void {
    const ent = self.world.get(id, tag).?;
    ent.phys.quad = try self.quad.insert(
        self.gpa,
        vec.asInt(ent.pos),
        @intFromFloat(World.cnst(id, .size)),
        @intFromEnum(id),
    );
}

fn input(self: *Game) !void {
    const base = self.world.get(self.player, .player) orelse return;
    {
        const face = vec.norm(self.mousePos() - base.pos);
        _ = face; // autofix

        //if (base.stt[0].bullet) |b|
        //    if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_RIGHT) and
        //        self.timer(&self.player_reload, player_reload_time))
        //    {
        //        _ = try self.createBullet(
        //            b.value,
        //            base.stt[0],
        //            base.pos[0],
        //            base.vel[0],
        //            face,
        //        );
        //    };

        self.camera.target = vec.asRl(std.math.lerp(base.pos, vec.fromRl(self.camera.target), vec.splat(0.4)));
        self.camera.offset = .{
            .x = tof(@divFloor(rl.GetScreenWidth(), 2)),
            .y = tof(@divFloor(rl.GetScreenHeight(), 2)),
        };

        const dirs = [_]Vec{ .{ 0, -1 }, .{ -1, 0 }, .{ 0, 1 }, .{ 1, 0 } };
        const keys = [_]c_int{ rl.KEY_W, rl.KEY_A, rl.KEY_S, rl.KEY_D };

        var dir = vec.zero;
        for (dirs, keys) |d, k| {
            if (rl.IsKeyDown(k)) dir += d;
        }
        base.vel += vec.norm(dir) * vec.splat(@TypeOf(base.*).speed * rl.GetFrameTime());

        const screen_height = rl.GetScreenHeight();
        _ = screen_height; // autofix

        //for (&self.player_attacks, 0..) |*at, i| {
        //    if (at.isNone()) break;

        //    const key_scale = 2;
        //    const key_size = 32 * key_scale;
        //    const padding = 8;

        //    var frame_color = rl.WHITE;
        //    var charge_color = rl.SKYBLUE;

        //    if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
        //        try at.tryTrigger(self);
        //    } else {
        //        frame_color = rl.GRAY;
        //        charge_color.a = 128;
        //    }

        //    const frame_pos = Vec{
        //        tof(i * (key_size + padding) + padding),
        //        tof(screen_height - key_size - padding),
        //    };

        //    rl.DrawRectangleV(
        //        vec.asRl(frame_pos + vec.splat(2)),
        //        vec.asRl(Vec{ key_size, tof(key_size) * at.progress(self) } - vec.splat(4)),
        //        charge_color,
        //    );

        //    const text = [_]u8{ @intCast(self.bindings[i]), 0 };

        //    const pnt = vec.asInt(frame_pos + vec.splat(8));
        //    rl.DrawText(&text, pnt[0], pnt[1], 30, frame_color);

        //    //drawTexture(&at.texture, frame_pos, key_scale, frame_color);

        //}
    }
}

pub fn createBullet(self: *Game, stts: *const Stats, from: *const Stats, origin: Vec, vel: Vec, dir: Vec) !Id {
    const pos = dir * vec.splat(from.size + stts.size) + origin;
    if (stts.trail) |tr| {
        return try self.world.create(self.gpa, .{
            Ents.Stt{stts},
            Ents.Pos{pos},
            Ents.Vel{dir * vec.splat(stts.speed) + vel},
            try self.createPhy(pos, stts.size),
            Ents.Tmp{self.time + stts.lifetime},
            Ents.Psr{ .stats = tr.value },
        });
    } else {
        return try self.world.create(self.gpa, .{
            Ents.Stt{stts},
            Ents.Pos{pos},
            Ents.Vel{dir * vec.splat(stts.speed) + vel},
            try self.createPhy(pos, stts.size),
            Ents.Tmp{self.time + 1000},
        });
    }
}

pub fn mousePos(self: *Game) Vec {
    return vec.fromRl(rl.GetScreenToWorld2D(rl.GetMousePosition(), self.camera));
}

fn update(self: *Game) !void {
    const delta = rl.GetFrameTime();

    var to_delete = std.ArrayList(Id).init(self.arena.allocator());
    if (false) {
        var tmps = self.world.select(struct { Ents.Tmp, Id });
        while (tmps.next()) |pb| {
            if (pb.tmp[0] < self.time) try to_delete.append(pb.id.*);
        }
    }

    if (false) {
        var quds = self.world.select(struct { Id, Ents.Stt, Ents.Pos, Ents.Vel, Ents.Phy });
        while (quds.next()) |qds| {
            const pos = vec.asInt(qds.pos[0] + qds.vel[0] * vec.splat(0.5));
            const size: i32 = @intFromFloat(qds.stt[0].size * 2 + vec.len(qds.vel[0]));
            try self.quad.update(self.gpa, &qds.phy.quad, pos, size, qds.id.toRaw());
        }
    }

    if (false) {
        const Q = struct { Id, Ents.Vel, Ents.Pos, Ents.Stt, Ents.Phy };
        var pbodies = self.world.select(Q);

        var collisions = std.ArrayList(struct { a: Id, b: Id, t: f32 }).init(self.arena.allocator());

        while (pbodies.next()) |pb| {
            const pos = vec.asInt(pb.pos[0] + pb.vel[0] * vec.splat(0.5));
            const size: i32 = @intFromFloat(pb.stt[0].size * 2 + vec.len(pb.vel[0]));
            const bb = .{ pos[0] - size, pos[1] - size, pos[0] + size, pos[1] + size };

            var query = self.quad.queryIter(bb, pb.phy.quad);
            while (query.next()) |qid| o: for (self.quad.entities(qid)) |id| {
                if (id == @as(u64, @bitCast(pb.id.*))) continue;
                const opb = self.world.selectOne(@bitCast(id), Q) orelse continue;

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

            inline for (.{ pb, opb }, .{ opb, pb }, .{ b, a }, .{ col.b, col.a }) |p, q, e, i| {
                var apprnded = false;
                if (p.stt[0].damage > 0 and p.stt[0].team != q.stt[0].team) if (e.get(Ents.Hlt)) |hlt| {
                    hlt.points -|= p.stt[0].damage;
                    if (hlt.points == 0) try to_delete.append(i);
                    hlt.hit_tween = self.time + hit_tween_duration;
                    apprnded = true;
                };

                if (q.stt[0].explosion != null and !apprnded and p.stt[0].max_health != 0) {
                    try to_delete.append(i);
                }
            }
        }
    }

    if (false) {
        var trts = self.world.select(struct { Ents.Trt, Ents.Pos, Ents.Stt });
        while (trts.next()) |tr| {
            if (self.world.get(tr.trt.target)) |target| b: {
                var pos = (target.get(Ents.Pos) orelse break :b)[0];

                if (vec.dist(pos, tr.pos[0]) > tr.stt[0].sight) {
                    break :b;
                }

                if (target.get(Ents.Vel)) |vel| {
                    const speed = tr.stt[0].bullet.?.value.speed;
                    const tvel = vel[0];
                    pos = predictTarget(tr.pos[0], pos, tvel, speed) orelse {
                        break :b;
                    };
                }

                const dir = vec.norm(pos - tr.pos[0]);
                tr.trt.rot = vec.ang(dir);

                if (self.timer(&tr.trt.reload, tr.stt[0].reload)) {
                    _ = try self.createBullet(tr.stt[0].bullet.?.value, tr.stt[0], tr.pos[0], vec.zero, dir);
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
                const ls = target.select(struct { Ents.Stt, Ents.Pos }) orelse continue;
                if (ls.stt[0].team == tr.stt[0].team) continue;
                if (vec.dist(ls.pos[0], tr.pos[0]) > tr.stt[0].sight) continue;
                tr.trt.target = id;
                break :o;
            };
        }
    }

    if (false) {
        var trts = self.world.select(struct { Ents.Pos, Ents.Stt, Ents.Hom, Ents.Vel });
        while (trts.next()) |hb| {
            if (self.world.get(hb.hom.target)) |target| b: {
                const pos = (target.get(Ents.Pos) orelse break :b)[0];

                if (vec.dist(pos, hb.pos[0]) > hb.stt[0].sight) {
                    break :b;
                }

                //if (target.get(cms.Vel)) |vel| {
                //    const speed = tr.stt[0].speed;
                //    const tvel = vel[0];
                //    pos = predictTarget(tr.pos[0], pos, tvel, speed) orelse {
                //        break :b;
                //    };
                //}

                const dir = vec.norm(pos - hb.pos[0]);
                hb.vel[0] += dir * vec.splat(hb.stt[0].speed * 2 * delta);
                continue;
            }
            hb.hom.target = .{};

            const pos = vec.asInt(hb.pos[0]);
            const size: i32 = @intFromFloat(hb.stt[0].sight);
            const bds = .{ pos[0] - size, pos[1] - size, pos[0] + size, pos[1] + size };
            var iter = self.quad.queryIter(bds, 0);
            o: while (iter.next()) |quid| for (self.quad.entities(quid)) |rid| {
                const id: Id = @bitCast(rid);
                const target = self.world.get(id) orelse continue;
                const ls = target.select(struct { Ents.Stt, Ents.Pos }) orelse continue;
                if (ls.stt[0].team == hb.stt[0].team) continue;
                if (vec.dist(ls.pos[0], hb.pos[0]) > hb.stt[0].sight) continue;
                hb.hom.target = id;
                break :o;
            };
        }
    }

    if (false) b: {
        const player = self.world.selectOne(self.player, struct { Ents.Pos }) orelse break :b;
        var nmies = self.world.select(struct { Ents.Pos, Ents.Nmy, Ents.Vel, Ents.Stt });
        while (nmies.next()) |nm| {
            if (vec.dist(nm.pos[0], player.pos[0]) > nm.stt[0].sight) continue;
            nm.vel[0] += vec.norm(player.pos[0] - nm.pos[0]) * vec.splat(nm.stt[0].speed * delta);
        }

        for (&self.player_attacks) |*at| if (!at.isNone()) {
            try at.tryPoll(self);
        };
    }

    {
        inline for (self.world.slct(enum { pos, vel })) |s| for (s) |*ent| {
            ent.pos += ent.vel * vec.splat(delta);
            ent.vel *= vec.splat(1 - @TypeOf(ent.*).friction * delta);
        };
    }

    for (to_delete.items) |id| {
        //const e = self.world.get(id) orelse continue;
        //if (e.get(Ents.Phy)) |phy|
        //    self.quad.remove(
        //        self.gpa,
        //        phy.quad,
        //        @bitCast(id),
        //    );
        //if (e.select(struct { Ents.Stt, Ents.Pos })) |sel| if (sel.stt[0].explosion) |ex| {
        //    _ = try self.world.create(self.gpa, .{
        //        Ents.Stt{&.{}},
        //        Ents.Psr{ .stats = ex.value },
        //        Ents.Tmp{self.time + 30},
        //        try self.createPhy(sel.pos[0], 10),
        //        sel.pos.*,
        //    });
        //};
        //// TODO: explode
        std.debug.assert(self.world.remove(id));
    }
}

fn draw(self: *Game) !void {
    rl.ClearBackground(rl.BLACK);

    rl.BeginMode2D(self.camera);
    rl.DrawLine(0, 0, 0, 10000, rl.WHITE);

    if (false) {
        var iter = self.world.select(struct { Ents.Prt, Ents.Pos, Ents.Stt, Ents.Tmp });
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

    draw_stuff_on_screen: {
        const player = self.world.get(self.player, .player) orelse break :draw_stuff_on_screen;
        const width = @divFloor(rl.GetScreenWidth(), 2);
        const height = @divFloor(rl.GetScreenHeight(), 2);
        const cx, const cy = vec.asInt(player.pos);
        const bounds: [4]i32 = .{ cx - width, cy - height, cx + width, cy + height };

        var iter = self.quad.queryIter(bounds, 0);
        while (iter.next()) |quid| for (self.quad.entities(quid)) |uid| {
            const id: Id = @enumFromInt(uid);

            if (self.world.invoke(id, .draw, .{}) == null) {
                rl.DrawCircleV(vec.asRl(self.world.field(id, .pos).?.*), World.cnst(id, .size), rl.RED);
            }

            // const rot = if (id == self.player)
            //     vec.ang(self.mousePos() - base)
            // else if (self.world.field(id, .vel)) |vel| vec.ang(vel.*) else 0.0;

            // var tone: f32 = 1;
            // var health_bar_perc: f32 = 0;
            // if (self.world.field(id, .health)) |hlt| {
            //     if (self.timeRem(hlt.hit_tween)) |n| {
            //         tone -= divToFloat(n, hit_tween_duration);
            //     }

            //     if (hlt.points != World.cnst(id, .max_health)) {
            //         health_bar_perc = divToFloat(hlt.points, World.cnst(id, .max_health));
            //     }
            // }

            // if (base.stt[0].texture) |tx| {
            //     drawCenteredTexture(tx.value, base.pos[0], rot, base.stt[0].scale(), fcolor(1, tone, tone));
            //     if (health_bar_perc != 0) {
            //         const end = 360 * health_bar_perc;
            //         const size = base.stt[0].size;
            //         rl.DrawRing(vec.asRl(base.pos[0]), size + 5, size + 8, 0.0, end, 50, rl.GREEN);
            //     }
            // } else {
            //     rl.DrawCircleV(vec.asRl(base.pos[0]), base.stt[0].size, rl.RED);
            // }

            //if (self.world.field(id, .)) |trt| b: {
            //    const tex = base.stt[0].cannon_texture orelse break :b;
            //    drawCenteredTexture(tex.value, base.pos[0], trt.rot, base.stt[0].scale(), fcolor(1, tone, tone));
            //}

            //if (pb.get(Ents.Psr)) |psr| try self.runPsr(base, psr, rot, pb);
        };

        if (false) {
            for (&self.player_attacks, 0..) |*at, i| if (!at.isNone()) {
                const pos = at.crossHarePos(self);
                var color = rl.SKYBLUE;
                if (at.progress(self) != 1) color.a = 128;
                var radius: f32 = 5;
                if (rl.IsKeyDown(self.bindings[i])) radius *= 2;
                rl.DrawCircleV(vec.asRl(pos), radius, color);
            };

            const pos = player.pos[0];
            const tl = vec.fromRl(rl.GetScreenToWorld2D(vec.asRl(vec.zero), self.camera));
            const r = tof(rl.GetScreenWidth());
            const b = tof(rl.GetScreenHeight());
            const br = vec.fromRl(rl.GetScreenToWorld2D(vec.asRl(.{ r, b }), self.camera));
            const radius = 20;
            const font_size = 14;

            var dots = std.ArrayList(struct { Vec, usize }).init(self.arena.allocator());
            var nmys = self.world.select(struct { Ents.Pos, Ents.Nmy });
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
    }

    rl.EndMode2D();

    rl.DrawFPS(20, 20);
}

pub fn runPsr(self: *Game, base: anytype, psr: *Ents.Psr, rot: f32, pb: World.Entity) !void {
    if (!self.timer(&psr.reload, psr.stats.spawn_rate)) return;

    const face = vec.unit(rot);
    const gap = -base.stt[0].size - if (psr.stats.particle.value.size > base.stt[0].size) psr.stats.particle.value.size else 0;
    const offset = switch (psr.dir orelse psr.stats.offset) {
        .center => vec.zero,
        .after => face,
        .before => -face,
        .left => vec.orth(face),
        .right => -vec.orth(face),
    } * vec.splat(gap);

    const vel = if (pb.get(Ents.Vel)) |vel| vel[0] else vec.zero;

    for (0..psr.stats.batch) |_| {
        _ = try self.world.create(self.gpa, .{
            Ents.Stt{psr.stats.particle.value},
            Ents.Pos{base.pos[0] + offset + vel * vec.splat(rl.GetFrameTime())},
            Ents.Vel{vec.unit(self.prng.random().float(f32) * std.math.tau) *
                vec.splat(psr.stats.init_vel - psr.stats.init_vel_variation * self.prng.random().float(f32))},
            Ents.Tmp{self.time + psr.stats.particle.value.lifetime - self.prng.random().int(u32) % psr.stats.lifetime_variation},
            Ents.Prt{ .face = rot },
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

fn drawTexture(texture: *const assets.Frame, pos: Vec, scale: f32, color: rl.Color) void {
    const real_width = texture.r.f.width * scale;
    const real_height = texture.r.f.height * scale;
    const dst = .{ .x = pos[0], .y = pos[1], .width = real_width, .height = real_height };
    const origin = .{ .x = 0, .y = 0 };
    rl.DrawTexturePro(sheet, texture.r.f, dst, origin, 0, color);
}

fn drawCenteredTexture(texture: *const assets.Frame, pos: Vec, rot: f32, scale: f32, color: rl.Color) void {
    const real_width = texture.r.f.width * scale;
    const real_height = texture.r.f.height * scale;
    const dst = .{ .x = pos[0], .y = pos[1], .width = real_width, .height = real_height };
    const origin = .{ .x = real_width / 2, .y = real_height / 2 };
    rl.DrawTexturePro(sheet, texture.r.f, dst, origin, rot / std.math.tau * 360, color);
}

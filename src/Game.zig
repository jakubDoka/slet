const std = @import("std");
const ecs = @import("ecs.zig");
const rl = @import("raylib");
const Quad = @import("QuadTree.zig");
const vec = @import("vec.zig");
const comps = @import("comps.zig");

const Game = @This();
const Vec = vec.T;
const Team = comps.Team;

const rlVec = rl.Vector2.init;

const Ent = union(enum) {
    const Kind = std.meta.Tag(Ent);

    const Player = struct {
        controlling: EntId,
        selected: ?EntId = null,
        placement: ?EntId = null,
    };

    const Enemy = struct {
        controlling: EntId,
    };

    const segment_comps: comps.Entity = &.{
        comps.Positioned,
        comps.Segment,
        comps.StaticMovement,
        comps.InQuad,
        comps.Alive,
        comps.ViwableStats,
    };
    const core_segment_comps: comps.Entity = segment_comps ++ .{comps.Core};
    const head_segment_comps: comps.Entity = segment_comps ++ .{comps.Moving};
    const turret_comps: comps.Entity = &.{
        comps.Positioned,
        comps.Turret,
        comps.InQuad,
        comps.Alive,
        comps.ViwableStats,
    };
    const bullet_comps: comps.Entity = &.{
        comps.Positioned,
        comps.Temporary,
        comps.Moving,
        comps.InQuad,
        comps.Harmful,
    };

    const Segment = comps.MergeComps(segment_comps);
    const CoreSegment = comps.MergeComps(core_segment_comps);
    const HeadSegment = comps.MergeComps(head_segment_comps);
    const Turret = comps.MergeComps(turret_comps);
    const Bullet = comps.MergeComps(bullet_comps);

    Segment: Segment,
    CoreSegment: CoreSegment,
    HeadSegment: HeadSegment,
    Player: Player,
    Turret: Turret,
    Bullet: Bullet,

    fn isSegmentKind(kind: Kind) bool {
        return switch (kind) {
            inline else => |t| comptime std.mem.endsWith(u8, @tagName(t), "Segment"),
        };
    }
};

const World = ecs.World(Ent);
const EntId = ecs.Id;

world: World = .{},
teams: Team.Store = .{},
query_buffer: std.ArrayListUnmanaged(u64) = .{},
ent_id_buffer: std.ArrayListUnmanaged(EntId) = .{},
rng: std.rand.Xoroshiro128 = std.rand.Xoroshiro128.init(0),
delta: f32 = 0.16,
time_millis: u32 = 0,
camera_target: Vec = .{ 0.0, 0.0 },

pub fn deinit(self: *Game, alc: std.mem.Allocator) void {
    self.world.deinit(alc);
    self.teams.deinit(alc);
    self.query_buffer.deinit(alc);
    self.ent_id_buffer.deinit(alc);
    self.* = undefined;
}

pub fn initStateForNow(self: *Game, alc: std.mem.Allocator) !void {
    const player_team = try self.teams.add(alc, try Team.init(alc));

    var prev_segment: ?EntId = null;
    for (0..9) |_| {
        if (prev_segment) |ps|
            self.world.queryOne(ps, struct { prev: ?EntId }).?.prev.* = self.world.nextId();
        prev_segment = try self.world.add(alc, .{ .Segment = try comps.initEnt(
            Ent.segment_comps,
            self.world.nextId(),
            &.{
                .radius = 20,
                .max_health = 20,
            },
            .{
                .pos = .{ 200, 200 },
                .team = player_team,
                .teams = &self.teams,
                .alc = alc,
                .next = prev_segment,
            },
        ) });
    }

    if (prev_segment) |ps|
        self.world.queryOne(ps, struct { prev: ?EntId }).?.prev.* = self.world.nextId();
    prev_segment = try self.world.add(alc, .{ .CoreSegment = try comps.initEnt(
        Ent.core_segment_comps,
        self.world.nextId(),
        &.{
            .radius = 50,
            .max_health = 300,
        },
        .{
            .pos = .{ 200, 200 },
            .team = player_team,
            .teams = &self.teams,
            .alc = alc,
            .next = prev_segment,
        },
    ) });

    if (prev_segment) |ps|
        self.world.queryOne(ps, struct { prev: ?EntId }).?.prev.* = self.world.nextId();
    const head = try self.world.add(alc, .{ .HeadSegment = try comps.initEnt(
        Ent.head_segment_comps,
        self.world.nextId(),
        &.{
            .radius = 20,
            .accel = 700,
            .friction = 0.02,
            .max_health = 30,
        },
        .{
            .pos = .{ 100, 100 },
            .team = player_team,
            .teams = &self.teams,
            .alc = alc,
            .next = prev_segment,
        },
    ) });
    _ = try self.world.add(alc, .{ .Player = .{ .controlling = head } });

    const enemy_team = try self.teams.add(alc, try Team.init(alc));

    const area = 1;

    for (0..1) |_| {
        _ = try self.world.add(alc, .{ .Turret = try comps.initEnt(
            Ent.turret_comps,
            self.world.nextId(),
            &.{
                .radius = 20,
                .range = 500,
                .reload_time = 300,
                .max_health = 10,
            },
            .{
                .pos = .{
                    randFloat(self.rng.random(), -area, area),
                    randFloat(self.rng.random(), -area, area),
                },
                .team = enemy_team,
                .teams = &self.teams,
                .alc = alc,
            },
        ) });
    }
}

pub fn update(self: *Game, alc: std.mem.Allocator) !void {
    self.delta = rl.getFrameTime();
    self.time_millis = @intFromFloat(1000.0 * rl.getTime());

    try self.dealDamage(alc);
    try self.killTemporary(alc);
    self.move();
    try self.updateQuads(alc);
    try self.updateTurrets(alc);
}

fn dealDamage(self: *Game, alc: std.mem.Allocator) !void {
    var iter = self.world.query(comps.MergeComps(&.{ comps.Harmful, comps.Positioned, comps.InQuad }));
    self.ent_id_buffer.items.len = 0;
    while (iter.next()) |h| {
        if (h.next_hit_after.* > self.time_millis) continue;

        const bounds = comps.InQuad.bounds(h.pos.*, h.radius);
        for (try self.queryTeams(alc, .{ .Except = h.team.* }, bounds)) |id| {
            const Q = comps.MergeComps(&.{ comps.Positioned, comps.InQuad, comps.Alive, comps.ViwableStats });
            const ent = self.world.queryOne(id, Q) orelse continue;

            const min_dist = h.radius + ent.radius;
            if (vec.dist2(h.pos.*, ent.pos.*) > min_dist * min_dist) continue;
            ent.health.* -|= h.damage;
            ent.show_stats_until.* = self.time_millis + 1000;

            if (ent.health.* == 0) {
                if (try self.handleKill(alc, id)) try self.ent_id_buffer.append(alc, id);
            }

            if (h.cooldown == 0) try self.ent_id_buffer.append(alc, h.back_ref) else {
                h.next_hit_after.* = self.time_millis + h.cooldown;
            }

            break;
        }
    }
    self.removeIdBufferEnts();
}

fn handleKill(self: *Game, alc: std.mem.Allocator, hit: EntId) !bool {
    return switch (self.world.getPtr(hit).?) {
        .HeadSegment => |s| b: {
            var cursor = s.next.*;

            var segment_count: u32 = 0;
            while (cursor) |c| if (self.world.queryOne(c, struct { next: ?EntId })) |n| {
                segment_count += 1;
                cursor = n.next.*;
            } else unreachable;

            const damage = std.math.divCeil(u32, s.stats.*.max_health, segment_count) catch
                break :b true;

            cursor = s.next.*;
            while (cursor) |c| if (self.world.queryOne(c, struct {
                next: ?EntId,
                vel: Vec,
                health: u32,
                show_stats_until: u32,
            })) |n| {
                const prev_health = n.health.*;
                n.health.* -|= damage;
                s.health.* += prev_health - n.health.*;
                n.show_stats_until.* = self.time_millis + 1000;
                if (s.health.* >= s.stats.*.max_health) {
                    s.health.* = s.stats.*.max_health;
                    break;
                }
                if (n.health.* == 0) try self.ent_id_buffer.append(alc, c);
                cursor = n.next.*;
            } else unreachable;

            break :b false;
        },
        else => true,
    };
}

fn killTemporary(self: *Game, alc: std.mem.Allocator) !void {
    var iter = self.world.query(comps.Temporary);
    self.ent_id_buffer.items.len = 0;
    while (iter.next()) |e| if (e.ttl.* < self.time_millis) {
        try self.ent_id_buffer.append(alc, e.back_ref);
    };
    self.removeIdBufferEnts();
}

fn removeIdBufferEnts(self: *Game) void {
    for (self.ent_id_buffer.items) |id|
        if (self.world.remove(id)) |e| self.cleanEnt(id, e);
}

fn cleanEnt(self: *Game, id: EntId, ent: Ent) void {
    if (comps.queryEnt(ent, comps.InQuad)) |b| {
        self.teams.get(b.team).quad.remove(b.quad_id, id.toRaw());
    }

    if (comps.queryEnt(ent, comps.Segment)) |s| {
        comps.Segment.removeOwned(&self.world, s.prev, s.next);
    }
}

fn move(self: *Game) void {
    {
        var iter = self.world.query(Ent.HeadSegment);
        while (iter.next()) |u| {
            var prev_vel = u.vel.* * vec.splat(self.delta);
            var prev_pos = u.pos.* - vec.rad(u.rot.*, u.radius) + prev_vel;
            u.rot.* = calcNextRotation(prev_vel, u.rot.*, u.radius * 2.0);
            var current = u.next.*;
            while (current) |next| if (self.world.queryOne(next, Ent.Segment)) |n| {
                const snap_ratio = 1.1;
                var diff = prev_pos - n.pos.* - vec.rad(n.rot.*, n.radius);
                if (vec.len2(diff) > vec.len2(prev_vel) * snap_ratio) {
                    diff = vec.clamp(diff, u.accel / u.friction * self.delta * self.delta);
                }

                n.rot.* = calcNextRotation(diff, n.rot.*, n.radius * 2.0);
                n.pos.* += diff;
                n.vel.* = diff / vec.splat(@max(self.delta, 0.001));
                prev_vel = diff;
                prev_pos = n.pos.* - vec.rad(n.rot.*, n.radius);
                current = n.next.*;
            } else unreachable;
        }
    }

    {
        var iter = self.world.query(comps.MergeComps(&.{ comps.Positioned, comps.Moving }));
        while (iter.next()) |u| {
            u.pos.* += u.vel.* * vec.splat(self.delta);
            u.vel.* -= (u.vel.* * vec.splat(@min(u.friction * self.delta * 60.0, 1.0)));
        }
    }
}

fn updateTurrets(self: *Game, alc: std.mem.Allocator) !void {
    var iter = self.world.query(Ent.Turret);
    while (iter.next()) |t| {
        const rangeSq = t.range * t.range;
        if (t.target.*) |target| b: {
            const tar = self.world.queryOne(target, struct { pos: Vec }) orelse {
                t.target.* = null;
                break :b;
            };

            if (vec.dist2(t.pos.*, tar.pos.*) > rangeSq) {
                t.target.* = null;
                break :b;
            }

            if (t.reload_until.* > self.time_millis) continue;

            const predicted = if (self.world.queryOne(target, struct { vel: Vec })) |tvel|
                predictTarget(t.pos.*, tar.pos.*, tvel.vel.*, 1000) orelse continue
            else
                tar.pos.*;

            _ = try self.world.add(alc, .{ .Bullet = try comps.initEnt(
                Ent.bullet_comps,
                self.world.nextId(),
                &.{
                    .friction = 0.0,
                    .accel = 0.0,
                    .ttl = 1000,
                    .radius = 5,
                    .damage = 1,
                },
                .{
                    .pos = t.pos.*,
                    .vel = vec.normalize(predicted - t.pos.*).? * vec.splat(1000),
                    .team = t.team.*,
                    .teams = &self.teams,
                    .alc = alc,
                    .time_millis = self.time_millis,
                },
            ) });

            t.reload_until.* = self.time_millis + t.reload_time;

            continue;
        }

        var closest: f32 = std.math.floatMax(f32);
        var closest_id: ?EntId = null;

        const bounds = [_]i32{
            @intFromFloat(t.pos[0] - t.range),
            @intFromFloat(t.pos[1] - t.range),
            @intFromFloat(t.pos[0] + t.range),
            @intFromFloat(t.pos[1] + t.range),
        };
        for (try self.queryTeams(alc, .{ .Except = t.team.* }, bounds)) |id| {
            const ent = self.world.queryOne(id, struct { pos: Vec, health: u32 }) orelse continue;
            const dist = vec.dist2(t.pos.*, ent.pos.*);
            if (dist < closest) {
                closest = dist;
                closest_id = id;
            }
        }

        if (closest < rangeSq) if (closest_id) |ci| {
            t.target.* = ci;
        };
    }
}

fn dbg(t: anytype) @TypeOf(t) {
    std.debug.print("{any}\n", .{t});
    return t;
}

fn updateQuads(self: *Game, alc: std.mem.Allocator) !void {
    var iter = self.world.query(comps.MergeComps(&.{ comps.Positioned, comps.InQuad }));
    while (iter.next()) |e| {
        try self.teams.get(e.team.*).quad.update(
            alc,
            &e.quad_id.*,
            vec.asInt(e.pos.*),
            @intFromFloat(e.radius),
            e.back_ref.toRaw(),
        );
    }
}

pub fn draw(self: *Game, alc: std.mem.Allocator) !void {
    rl.beginDrawing();
    defer rl.endDrawing();

    rl.clearBackground(rl.Color.black);

    const camera = self.deriveCamera();
    camera.begin();

    const mouse = mouseWorldPos(camera);
    const bounds = viewportBounds(camera);

    drawQuadTree(&self.teams.get(0).quad, 0);

    var visible = try self.queryTeams(alc, .All, viewportIntBounds(bounds));
    var retain_index: u32 = 0;
    const Q = comps.MergeComps(&.{ comps.Positioned, comps.InQuad });
    for (visible) |id| {
        const ent = self.world.queryOne(id, Q) orelse continue;
        const view_range = ent.radius * 2.0;
        if (bounds[0] > ent.pos[0] + view_range or
            bounds[2] < ent.pos[0] - view_range or
            bounds[1] > ent.pos[1] + view_range or
            bounds[3] < ent.pos[1] - view_range) continue;

        visible[retain_index] = id;
        retain_index += 1;
    }
    visible.len = retain_index;

    inline for (.{
        drawGroundLayer,
        drawLowAirLayer,
        drawAirLayer,
        drawBulletLayer,
        drawStateLayer,
    }) |f| {
        for (visible) |id| f(self, self.world.get(id) orelse continue);
    }

    var iter = self.world.query(Ent.Player);
    while (iter.next()) |p| if (p.selected.*) |s| if (self.world.queryOne(
        s,
        comps.MergeComps(&.{ comps.Positioned, comps.InQuad }),
    )) |ent| {
        rl.drawLineV(vec.asRl(ent.pos.*), vec.asRl(mouse), rl.Color.yellow);
    };

    camera.end();

    rl.drawFPS(10, 10);
}

fn drawQuadTree(q: *Quad, from: Quad.Id) void {
    const node = q.quads.items[from];
    const radius = q.radius >> node.depth;

    const x = node.pos[0];
    const y = node.pos[1];

    if (node.children != Quad.invalid_id) {
        rl.drawLine(x, y - radius, x, y + radius, rl.Color.red);
        rl.drawLine(x - radius, y, x + radius, y, rl.Color.red);

        for (node.children..node.children + 4) |child|
            drawQuadTree(q, @intCast(child));
    }
}

fn drawGroundLayer(self: *Game, ent: Ent) void {
    switch (ent) {
        .Turret => |t| {
            rl.drawCircleV(vec.asRl(t.pos), t.stats.radius, rl.Color.blue);
            if (t.target) |target| if (self.world.queryOne(target, struct { pos: Vec })) |tar| {
                rl.drawLineV(vec.asRl(t.pos), vec.asRl(tar.pos.*), rl.Color.blue);
            };
        },
        else => {},
    }
}

fn drawBulletLayer(self: *Game, ent: Ent) void {
    _ = self;
    switch (ent) {
        .Bullet => |b| {
            rl.drawCircleV(vec.asRl(b.pos), 5, rl.Color.white);
        },
        else => {},
    }
}

fn drawLowAirLayer(self: *Game, ent: Ent) void {
    _ = self;

    if (comps.queryEnt(ent, Ent.Segment)) |s| rl.drawCircleV(
        vec.asRl(s.pos - vec.rad(s.rot, s.radius)),
        10,
        rl.Color.yellow,
    );
}

fn drawAirLayer(self: *Game, ent: Ent) void {
    _ = self;
    if (comps.queryEnt(ent, Ent.CoreSegment)) |s| {
        rl.drawCircleV(vec.asRl(s.pos), s.radius, rl.Color.purple);
    } else if (comps.queryEnt(ent, Ent.Segment)) |s|
        rl.drawCircleV(vec.asRl(s.pos), s.radius, rl.Color.red);
}

fn drawStateLayer(self: *Game, ent: Ent) void {
    const HealthQuery = comps.MergeComps(&.{ comps.Alive, comps.Positioned, comps.InQuad, comps.ViwableStats });
    if (comps.queryEnt(ent, HealthQuery)) |s| if (s.show_stats_until > self.time_millis) {
        const health_perc = toF32(s.health) / toF32(s.max_health);
        rl.drawRing(
            vec.asRl(s.pos),
            s.radius + 2,
            s.radius + 5,
            0,
            health_perc * 360,
            @intFromFloat(s.radius * 2),
            rl.Color.green,
        );
    };

    const ReloadQuery = comps.MergeComps(&.{ comps.Turret, comps.Positioned, comps.InQuad, comps.ViwableStats });
    if (comps.queryEnt(ent, ReloadQuery)) |t| if (t.show_stats_until > self.time_millis and
        t.reload_until > self.time_millis)
    {
        const reload_perc = 1.0 - toF32(t.reload_until - self.time_millis) / toF32(t.reload_time);
        rl.drawRing(
            vec.asRl(t.pos),
            t.radius + 5,
            t.radius + 8,
            0,
            reload_perc * 360,
            @intFromFloat(t.radius * 2),
            rl.Color.red,
        );
    };
}

fn deriveCamera(self: *Game) rl.Camera2D {
    return .{
        .offset = vec.asRl(screenSize() * vec.splat(0.5)),
        .target = vec.asRl(self.camera_target),
        .rotation = 0.0,
        .zoom = 1.0,
    };
}

pub fn input(self: *Game, alc: std.mem.Allocator) !void {
    try self.controlPlayers(alc);
}

fn controlPlayers(self: *Game, alc: std.mem.Allocator) !void {
    var players = self.world.query(Ent.Player);
    while (players.next()) |p| {
        switch (self.world.getPtr(p.controlling.*) orelse continue) {
            .HeadSegment => |h| {
                var dir = vec.splat(0.0);
                if (rl.isKeyDown(.key_a)) dir[0] -= 1.0;
                if (rl.isKeyDown(.key_d)) dir[0] += 1.0;
                if (rl.isKeyDown(.key_w)) dir[1] -= 1.0;
                if (rl.isKeyDown(.key_s)) dir[1] += 1.0;

                dir = (vec.normalize(dir) orelse .{ 0, 0 }) * vec.splat(h.stats.*.accel) * vec.splat(self.delta);

                h.vel.* += dir;

                self.camera_target = h.pos.*;

                const cam = self.deriveCamera();
                const mouse = mouseWorldPos(cam);
                const bounds = comps.InQuad.bounds(mouse, 0);
                const Q = comps.MergeComps(&.{ comps.Positioned, comps.InQuad });

                const hovered = for (try self.queryTeams(alc, .{ .Only = h.team.* }, bounds)) |id| {
                    const ent = self.world.queryOne(id, Q) orelse continue;
                    if (vec.dist2(mouse, ent.pos.*) < ent.radius * ent.radius) break id;
                } else null;

                if (hovered) |hov| if (self.world.queryOne(hov, struct { show_stats_until: u32 })) |s| {
                    s.show_stats_until.* = self.time_millis + 1000;
                };

                if (rl.isMouseButtonPressed(.mouse_button_left)) {
                    p.selected.* = hovered;
                }

                if (p.selected.* != null) if (hovered) |other| {
                    p.placement.* = other;
                };

                if (rl.isMouseButtonReleased(.mouse_button_left)) b: {
                    const selected_unw = p.selected.* orelse break :b;
                    const placement_unw = p.placement.*.?;

                    const sel_eq_pla = std.meta.eql(selected_unw, placement_unw);

                    var selected_kind = self.world.kindOf(selected_unw) orelse break :b;
                    const placement_kind = self.world.kindOf(placement_unw).?;

                    if (selected_kind == .Segment and sel_eq_pla) {
                        comps.Segment.remove(&self.world, selected_unw);

                        const selected = self.world.get(selected_unw).?.Segment;
                        std.debug.assert(try self.world.exchange(alc, selected_unw, .{ .Turret = .{
                            .pos = selected.pos,
                            .team = selected.team,
                            .quad_id = selected.quad_id,
                            .health = selected.health,
                            .stats = &.{
                                .radius = 20,
                                .range = 500,
                                .reload_time = 300,
                                .max_health = 20,
                            },
                        } }));

                        break :b;
                    }

                    if (selected_kind == .Turret and (placement_kind == .Segment or sel_eq_pla)) {
                        const selected = self.world.get(selected_unw).?.Turret;
                        std.debug.assert(try self.world.exchange(alc, selected_unw, .{ .Segment = .{
                            .pos = selected.pos,
                            .team = selected.team,
                            .quad_id = selected.quad_id,
                            .health = selected.health,
                            .prev = null,
                            .next = null,
                            .stats = &.{
                                .radius = 20,
                                .max_health = 20,
                            },
                        } }));

                        comps.Segment.insert(&self.world, p.controlling.*, selected_unw);
                        selected_kind = .Segment;
                    }

                    if ((selected_kind == .Segment or selected_kind == .CoreSegment) and
                        (placement_kind == .Segment or placement_kind == .HeadSegment or
                        placement_kind == .CoreSegment) and
                        !sel_eq_pla)
                    {
                        comps.Segment.remove(&self.world, selected_unw);
                        comps.Segment.insert(&self.world, placement_unw, selected_unw);
                        break :b;
                    }
                }

                if (rl.isMouseButtonReleased(.mouse_button_left)) {
                    p.selected.* = null;
                    p.placement.* = null;
                }
            },
            else => {},
        }
    }
}

fn randFloat(rng: std.rand.Random, min: f32, max: f32) f32 {
    return min + rng.float(f32) * (max - min);
}

fn randRadVec(rng: std.rand.Random, max: f32) Vec {
    return vec.rad(randFloat(rng, 0, 2 * std.math.pi), max);
}

pub fn queryTeams(self: *Game, alc: std.mem.Allocator, tf: Team.Filter, bounds: [4]i32) ![]EntId {
    self.query_buffer.items.len = 0;
    var buff = self.query_buffer.toManaged(alc);

    switch (tf) {
        .All => for (self.teams.slots.items) |*team| try team.quad.query(bounds, &buff, 0),
        .Only => |t| try self.teams.get(t).quad.query(bounds, &buff, 0),
        .Except => |t| {
            for (self.teams.slots.items[0..t]) |*team| try team.quad.query(bounds, &buff, 0);
            for (self.teams.slots.items[t + 1 ..]) |*team| try team.quad.query(bounds, &buff, 0);
        },
    }

    self.query_buffer = buff.moveToUnmanaged();
    return @ptrCast(self.query_buffer.items);
}

fn calcNextRotation(step: Vec, prev_rot: f32, base: f32) f32 {
    std.debug.assert(base > 0.0);
    const base_unit = vec.unit(prev_rot);
    const proj = vec.proj(step, base_unit) orelse vec.zero;
    const a = vec.dist(step, proj);
    const side = std.math.sign(vec.dot(vec.orth(base_unit), step));
    return side * std.math.atan(a / base) + prev_rot;
}

fn screenSize() Vec {
    return .{
        @floatFromInt(rl.getScreenWidth()),
        @floatFromInt(rl.getScreenHeight()),
    };
}

fn viewportBounds(camera: rl.Camera2D) [4]f32 {
    const top_left = rl.getScreenToWorld2D(rlVec(0.0, 0.0), camera);
    const bottom_right = rl.getScreenToWorld2D(vec.asRl(screenSize()), camera);
    return .{ top_left.x, top_left.y, bottom_right.x, bottom_right.y };
}

fn viewportIntBounds(bounds: [4]f32) [4]i32 {
    var int_bounds: [4]i32 = undefined;
    for (bounds, &int_bounds) |f, *i| i.* = @intFromFloat(f);
    return int_bounds;
}

fn mouseWorldPos(cam: rl.Camera2D) Vec {
    return @bitCast(rl.getScreenToWorld2D(rl.getMousePosition(), cam));
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

fn toF32(v: anytype) f32 {
    return @floatFromInt(v);
}

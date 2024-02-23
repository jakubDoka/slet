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

const Ent = union(enum) {
    const Player = struct {
        controlling: EntId,
    };

    const segment_comps: comps.Entity = &.{
        comps.Positioned,
        comps.Segment,
        comps.InQuad,
    };
    const head_segment_comps: comps.Entity = segment_comps ++ .{comps.Moving};
    const turret_comps: comps.Entity = &.{
        comps.Positioned,
        comps.Turret,
        comps.InQuad,
    };
    const bullet_comps: comps.Entity = &.{
        comps.Positioned,
        comps.Temporary,
        comps.Moving,
    };

    const Segment = comps.MergeComps(segment_comps);
    const HeadSegment = comps.MergeComps(head_segment_comps);
    const Turret = comps.MergeComps(turret_comps);
    const Bullet = comps.MergeComps(bullet_comps);

    Player: Player,
    Turret: Turret,
    Segment: Segment,
    HeadSegment: HeadSegment,
    Bullet: Bullet,
};

const World = ecs.World(Ent);
const EntId = ecs.Id;

world: World = .{},
teams: Team.Store = .{},
query_buffer: std.ArrayListUnmanaged(u64) = .{},
rng: std.rand.Xoroshiro128 = std.rand.Xoroshiro128.init(0),
delta: f32 = 0.16,
time_millis: u32 = 0,
camera_target: Vec = .{ 0.0, 0.0 },

pub fn deinit(self: *Game, alc: std.mem.Allocator) void {
    self.world.deinit(alc);
    self.teams.deinit(alc);
    self.query_buffer.deinit(alc);
    self.* = undefined;
}

pub fn initStateForNow(self: *Game, alc: std.mem.Allocator) !void {
    const player_team = try self.teams.add(alc, try Team.init(alc));

    var prev_segment: ?EntId = null;
    for (0..9999) |_| {
        prev_segment = try self.world.add(alc, .{ .Segment = try comps.initEnt(
            Ent.segment_comps,
            self.world.nextId(),
            &.{
                .base = 40,
                .radius = 20,
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

    const head = try self.world.add(alc, .{ .HeadSegment = try comps.initEnt(
        Ent.head_segment_comps,
        self.world.nextId(),
        &.{
            .base = 40,
            .radius = 20,
            .accel = 4000,
            .friction = 0.01,
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

    for (0..10000) |_| {
        _ = try self.world.add(alc, .{ .Turret = try comps.initEnt(
            Ent.turret_comps,
            self.world.nextId(),
            &.{
                .radius = 20,
                .range = 300,
                .reload_time = 200,
            },
            .{
                .pos = .{
                    randFloat(self.rng.random(), -10000, 10000),
                    randFloat(self.rng.random(), -10000, 10000),
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

    self.move();
    try self.updateQuads(alc);
    try self.updateTurrets(alc);
}

fn move(self: *Game) void {
    {
        var iter = self.world.query(Ent.HeadSegment);
        while (iter.next()) |u| {
            var prev_pos = u.pos.* - vec.rad(u.rot.*, u.base) + u.vel.* * vec.splat(self.delta);
            u.rot.* = calcNextRotation(u.vel.* * vec.splat(self.delta), u.rot.*, u.base);
            var current = u.next.*;
            while (current) |next| if (self.world.queryOne(next, Ent.Segment)) |n| {
                const diff = prev_pos - n.pos.*;
                //const diff = n.pos.* - prev_pos; // fun stuff
                n.rot.* = calcNextRotation(diff, n.rot.*, n.base);
                n.pos.* = prev_pos;
                prev_pos -= vec.rad(n.rot.*, n.base);
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

            if (t.reload_until.* > self.time_millis) break :b;

            _ = try self.world.add(alc, .{ .Bullet = try comps.initEnt(
                Ent.bullet_comps,
                self.world.nextId(),
                &.{
                    .friction = 0.0,
                    .accel = 0.0,
                    .ttl = 1000,
                },
                .{
                    .pos = t.pos.*,
                    .vel = vec.normalize(tar.pos.* - t.pos.*).? * vec.splat(1000),
                },
            ) });

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
            const ent = self.world.queryOne(id, struct { pos: Vec }) orelse continue;
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

    const bounds = viewportBounds(camera);

    drawQuadTree(&self.teams.get(1).quad, 0);

    for (try self.queryTeams(alc, .All, viewportIntBounds(bounds))) |id| {
        if (self.world.queryOne(id, struct { pos: Vec })) |ent|
            if (bounds[0] <= ent.pos[0] and ent.pos[0] <= bounds[2] and
                bounds[1] <= ent.pos[1] and ent.pos[1] <= bounds[3])
                self.drawEntity(id);
    }

    camera.end();

    rl.drawFPS(10, 10);
}

fn drawQuadTree(q: *Quad, from: Quad.Id) void {
    const node = q.quads.items[from];
    const radius = q.radius >> node.depth;

    const x = node.pos[0];
    const y = node.pos[1];

    rl.drawLine(x, y - radius, x, y + radius, rl.Color.red);
    rl.drawLine(x - radius, y, x + radius, y, rl.Color.red);

    if (node.children != Quad.invalid_id) {
        for (node.children..node.children + 4) |child|
            drawQuadTree(q, @intCast(child));
    }
}

fn drawEntity(self: *Game, id: EntId) void {
    switch (self.world.get(id) orelse return) {
        .Turret => |t| {
            rl.drawCircleV(vec.asRl(t.pos), t.stats.radius, rl.Color.blue);
            if (t.target) |target| if (self.world.queryOne(target, struct { pos: Vec })) |tar| {
                rl.drawLineV(vec.asRl(t.pos), vec.asRl(tar.pos.*), rl.Color.blue);
            };
        },
        .Segment => |s| {
            rl.drawCircleV(vec.asRl(s.pos - vec.rad(s.rot, s.stats.base * 0.5)), s.stats.radius, rl.Color.red);
        },
        .HeadSegment => |s| {
            rl.drawCircleV(vec.asRl(s.pos - vec.rad(s.rot, s.stats.base * 0.5)), s.stats.radius, rl.Color.green);
        },
        .Bullet => |b| {
            rl.drawCircleV(vec.asRl(b.pos), 5, rl.Color.white);
        },
        else => {},
    }
}

fn deriveCamera(self: *Game) rl.Camera2D {
    return .{
        .offset = vec.asRl(screenSize() * vec.splat(0.5)),
        .target = vec.asRl(self.camera_target),
        .rotation = 0.0,
        .zoom = 1.0,
    };
}

pub fn input(self: *Game) void {
    self.controlPlayers();
}

fn controlPlayers(self: *Game) void {
    const accel = 1000.0;

    var players = self.world.query(Ent.Player);
    while (players.next()) |p| {
        switch (self.world.getPtr(p.controlling.*) orelse continue) {
            .HeadSegment => |u| {
                var dir = vec.splat(0.0);
                if (rl.isKeyDown(.key_a)) dir[0] -= 1.0;
                if (rl.isKeyDown(.key_d)) dir[0] += 1.0;
                if (rl.isKeyDown(.key_w)) dir[1] -= 1.0;
                if (rl.isKeyDown(.key_s)) dir[1] += 1.0;
                dir = (vec.normalize(dir) orelse .{ 0, 0 }) * vec.splat(accel) * vec.splat(self.delta);

                u.vel.* += dir;

                self.camera_target = u.pos.*;
            },
            else => {},
        }
    }
}

fn randFloat(rng: std.rand.Random, min: f32, max: f32) f32 {
    return min + rng.float(f32) * (max - min);
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

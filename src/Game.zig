const std = @import("std");
const World = @import("ecs.zig");
const ecs = World;
const rl = @import("raylib");
const Quad = @import("QuadTree.zig");
const vec = @import("vec.zig");

const Game = @This();
const Vec = vec.T;

const rlVec = rl.Vector2.init;

const EntId = ecs.Id;

pub const Team = struct {
    pub const invalid_id = std.math.maxInt(Id);

    pub const Id = u32;

    pub const Filter = union(enum) {
        All,
        Only: Id,
        Except: Id,
    };

    pub const Store = struct {
        slots: std.ArrayListUnmanaged(Team) = .{},

        pub fn deinit(self: *Store, alc: std.mem.Allocator) void {
            self.clear(alc);
            self.slots.deinit(alc);
            self.* = undefined;
        }

        pub fn add(self: *Store, alc: std.mem.Allocator, team: Team) !Id {
            try self.slots.append(alc, team);
            return @intCast(self.slots.items.len - 1);
        }

        pub fn get(self: *Store, id: Id) *Team {
            return &self.slots.items[id];
        }

        pub fn clear(self: *Store, alc: std.mem.Allocator) void {
            for (self.slots.items) |*slot| slot.deinit(alc);
            self.slots.items.len = 0;
        }
    };

    quad: Quad = .{ .radius = 0 },

    pub fn init(alc: std.mem.Allocator) !Team {
        return .{ .quad = try Quad.init(alc, 1 << 14) };
    }

    pub fn deinit(self: *Team, alc: std.mem.Allocator) void {
        self.quad.deinit(alc);
        self.* = undefined;
    }
};

pub const Player = struct {
    selected: ?ecs.Id = null,
    placement: ?ecs.Id = null,
};

pub const Enemy = struct {
    target: ?ecs.Id = null,
    ms: MovementStage = .Follow,

    pub const MovementStage = enum {
        Follow,
        Frozen,
        TurnAround,
    };
};

// STATS are used for every entity but only part of them is used in each case
pub const Stats = struct {
    radius: f32 = 20,
    max_health: u32 = 10,
    accel: f32 = 0.0,
    friction: f32 = 0.0,
    innacuraci: f32 = 0.0,
    damage: u32 = 1,
    damage_cooldown: u32 = 0,
    ttl: u32 = 1000,
    range: f32 = 500,
    reload_time: u32 = 300,
    slot_offsets: []const Vec = &.{.{ 0, 0 }},

    fn bulletRange(self: *const Stats) f32 {
        return @floatFromInt(self.ttl * 1000);
    }
};

pub const InQuad = struct {
    quad_id: Quad.Id = 0,
    team: Team.Id,

    pub fn bounds(pos: Vec, radius: f32) [4]i32 {
        return [_]i32{
            @intFromFloat(pos[0] - radius),
            @intFromFloat(pos[1] - radius),
            @intFromFloat(pos[0] + radius),
            @intFromFloat(pos[1] + radius),
        };
    }
};

pub const Alive = struct {
    health: u32,

    pub fn init(stats: *const Stats) @This() {
        return .{ .health = stats.max_health };
    }
};

pub const Moving = struct {
    vel: Vec = vec.zero,
};

pub const StaticMovement = struct {
    vel: Vec = vec.zero,
};

pub const Harmful = struct {
    next_hit_after: u32 = 0,
};

pub const Temporary = struct {
    ttl: u32,
};

pub const Positioned = struct {
    pos: Vec,
};

pub const Turret = struct {
    target: ?ecs.Id = null,
    reload_until: u32 = 0,
};

pub const Mountable = struct {
    base: ecs.Id,
    slot: u32 = 0,
};

pub const Segment = struct {
    rot: f32 = 0,
    next: ecs.Id,
    prev: ecs.Id,

    pub fn remove(world: *World, target: ecs.Id) void {
        const selected = world.get(target).?.get(Segment) orelse unreachable;
        removeOwned(world, selected.prev, selected.next);
    }

    pub fn removeOwned(world: *World, prev: ecs.Id, next: ecs.Id) void {
        world.get(prev).?.get(Segment).?.next = next;
        world.get(next).?.get(Segment).?.prev = prev;
    }

    pub fn insert(world: *World, after: ecs.Id, target: ecs.Id) void {
        const selected = world.get(target).?.get(Segment).?;
        const placement = world.get(after).?.get(Segment).?;
        const after_placement = world.get(placement.next).?.get(Segment).?;
        selected.prev = after;
        selected.next = placement.next;
        after_placement.prev = target;
        placement.next = target;
    }
};

pub const Core = struct {};
pub const Head = struct {};

pub const ViwableStats = struct {
    show_stats_until: u32 = 0,

    pub fn trigger(value: *u32, time: u32) void {
        value.* = time + 1000;
    }
};

const LeveScaling = struct {
    difficulty: u32 = 0,
    pace: u32 = 100000,
    base_tiemout: u32 = 3000,
    next_enemy_at: u32 = 0,

    pub fn spawnEnemy(self: *LeveScaling, time: u32) bool {
        if (time < self.next_enemy_at) return false;
        const factor = time / self.pace;
        const timeout = self.base_tiemout / (factor + 1 + self.difficulty);
        self.next_enemy_at = time + timeout;
        return true;
    }
};

ls: LeveScaling = .{
    .base_tiemout = 0,
},
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
    const pos = .{ 200, 200 };
    const player_team = try self.teams.add(alc, try Team.init(alc));

    const head_stats = Stats{ .radius = 20, .accel = 700, .friction = 0.02, .max_health = 5 };
    const head = try self.world.create(alc, .{
        &head_stats,
        Head{},
        self.newSegment(),
        Alive{ .health = head_stats.max_health },
        try self.newInQuad(alc, &head_stats, pos, player_team),
        Positioned{ .pos = pos },
        Moving{},
        ViwableStats{},
        Player{},
    });

    for (0..100) |_| {
        const stats = Stats{
            .radius = 20,
            .max_health = 20,
            .reload_time = 2,
            .innacuraci = 0.1,
            .range = 1000,
        };
        const segment = try self.world.create(alc, .{
            &stats,
            self.newSegment(),
            Alive{ .health = stats.max_health },
            try self.newInQuad(alc, &stats, pos, player_team),
            Moving{},
            Positioned{ .pos = pos },
            ViwableStats{},
            Turret{},
        });
        Segment.insert(&self.world, head, segment);
    }

    const core_stats = Stats{
        .radius = 50,
        .max_health = 300,
        .reload_time = 1000,
        .range = 500,
    };
    const core_segment = try self.world.create(alc, .{
        &core_stats,
        self.newSegment(),
        Alive{ .health = core_stats.max_health },
        try self.newInQuad(alc, &core_stats, pos, player_team),
        Positioned{ .pos = pos },
        Moving{},
        Core{},
        ViwableStats{},
    });
    Segment.insert(&self.world, head, core_segment);

    var cursor = head;
    while (!std.meta.eql(cursor, head)) if (self.world.selectOne(cursor, struct { seg: Segment })) |n| {
        const next = self.world.selectOne(n.seg.next, struct { seg: Segment }).?;
        std.debug.assert(std.meta.eql(next.seg.prev, cursor));
        cursor = n.seg.next;
    } else unreachable;

    const enemy_team = try self.teams.add(alc, try Team.init(alc));
    const area = 1;
    for (0..1) |_| {
        const turret_stats = Stats{ .radius = 20, .range = 500, .reload_time = 300, .max_health = 10 };
        const tpos = .{
            randFloat(self.rng.random(), -area, area),
            randFloat(self.rng.random(), -area, area),
        };
        _ = try self.world.create(alc, .{
            &turret_stats,
            Turret{ .reload_until = 0, .target = null },
            Alive{ .health = turret_stats.max_health },
            try self.newInQuad(alc, &turret_stats, tpos, enemy_team),
            Positioned{ .pos = tpos },
            ViwableStats{},
        });
    }
}

pub fn newSegment(self: *Game) Segment {
    return .{ .next = self.world.nextId(), .prev = self.world.nextId() };
}

pub fn newInQuad(self: *Game, alc: std.mem.Allocator, stats: *const Stats, pos: Vec, team: Team.Id) !InQuad {
    return .{
        .quad_id = try self.teams.get(team).quad
            .insert(alc, vec.asInt(pos), @intFromFloat(stats.radius), self.world.nextId().toRaw()),
        .team = team,
    };
}

pub fn update(self: *Game, alc: std.mem.Allocator) !void {
    self.delta = @max(rl.getFrameTime(), 0.000001);
    self.time_millis = @intFromFloat(1000.0 * rl.getTime());

    try self.spawnEnemies(alc);
    try self.dealDamage(alc);
    try self.killTemporary(alc);
    self.moveSegments();
    self.move();
    try self.updateQuads(alc);
    try self.updateTurrets(alc);
    try self.controlEnemies(alc);
}

fn spawnEnemies(self: *Game, alc: std.mem.Allocator) !void {
    if (!self.ls.spawnEnemy(self.time_millis)) return;

    // for now
    const enemy_team = 1;

    var cores = self.world.select(struct {
        core: Core,
        id: EntId,
        posi: Positioned,
        iq: InQuad,
        stats: *const Stats,
    });

    const core = cores.next().?;
    std.debug.assert(cores.next() == null);

    const random_pos_on_circle = b: {
        const core_pos = core.posi.pos;
        const some_radius = 3000;
        const angle = randFloat(self.rng.random(), 0, 2 * std.math.pi);
        break :b vec.rad(angle, some_radius) + core_pos;
    };

    const stats = Stats{ .radius = 20, .max_health = 10, .accel = 1000, .friction = 0.02, .damage_cooldown = 100 };
    const head = try self.world.create(alc, .{
        &stats,
        self.newSegment(),
        Alive{ .health = stats.max_health },
        try self.newInQuad(alc, &stats, random_pos_on_circle, enemy_team),
        Positioned{ .pos = random_pos_on_circle },
        Moving{},
        ViwableStats{},
        Enemy{ .target = core.id.* },
        Head{},
    });

    for (0..10) |_| {
        const segment = try self.world.create(alc, .{
            &stats,
            self.newSegment(),
            Alive{ .health = stats.max_health },
            try self.newInQuad(alc, &stats, random_pos_on_circle, enemy_team),
            Moving{},
            Positioned{ .pos = random_pos_on_circle },
            //ViwableStats{},
            Harmful{},
        });
        Segment.insert(&self.world, head, segment);
    }
}

fn controlEnemies(self: *Game, alc: std.mem.Allocator) !void {
    _ = alc;
    var iter = self.world.select(struct {
        enemy: Enemy,
        posi: Positioned,
        mov: Moving,
        iq: InQuad,
        stats: *const Stats,
    });
    while (iter.next()) |e| {
        const tar = self.world.selectOne(e.enemy.target.?, struct { posi: Positioned }).?;
        const diff = tar.posi.pos - e.posi.pos;
        const dir = switch (e.enemy.ms) {
            .Follow => diff,
            .Frozen => e.mov.vel,
            .TurnAround => vec.orth(tar.posi.pos - e.posi.pos),
        };

        const norm_dir = vec.normalize(dir) orelse vec.zero;
        const accel = norm_dir * vec.splat(e.stats.*.accel);
        e.mov.vel += accel * vec.splat(self.delta);

        const dist = vec.len(diff);
        e.enemy.ms = switch (e.enemy.ms) {
            .Follow => if (dist < 30) .Frozen else .Follow,
            .Frozen => if (dist > 300) .TurnAround else .Frozen,
            .TurnAround => if (vec.angBetween(diff, e.mov.vel) < std.math.pi * 0.8) .Follow else .TurnAround,
        };
    }
}

fn dealDamage(self: *Game, alc: std.mem.Allocator) !void {
    var iter = self.world.select(struct {
        id: EntId,
        hfl: Harmful,
        posi: Positioned,
        iq: InQuad,
        stats: *const Stats,
    });
    self.ent_id_buffer.items.len = 0;
    while (iter.next()) |h| {
        const stats = h.stats.*;
        if (h.hfl.next_hit_after > self.time_millis) continue;

        const bounds = InQuad.bounds(h.posi.pos, stats.radius);
        for (try self.queryTeams(alc, .{ .Except = h.iq.team }, bounds)) |id| {
            const ent = self.world.selectOne(id, struct {
                posi: Positioned,
                iq: InQuad,
                ali: Alive,
                vs: ViwableStats,
                stats: *const Stats,
            }) orelse continue;

            const min_dist = stats.radius + ent.stats.*.radius;
            if (vec.dist2(h.posi.pos, ent.posi.pos) > min_dist * min_dist) continue;
            ent.ali.health -|= stats.damage;
            ent.vs.show_stats_until = self.time_millis + 1000;

            if (ent.ali.health == 0) {
                if (try self.handleKill(alc, id)) try self.ent_id_buffer.append(alc, id);
            }

            if (stats.damage_cooldown == 0) try self.ent_id_buffer.append(alc, h.id.*) else {
                h.hfl.next_hit_after = self.time_millis + stats.damage_cooldown;
            }

            break;
        }
    }
    try self.removeIdBufferEnts();
}

fn handleKill(self: *Game, alc: std.mem.Allocator, hit: EntId) !bool {
    if (self.world.selectOne(hit, struct {
        id: EntId,
        head: Head,
        seg: Segment,
        ali: Alive,
        stats: *const Stats,
    })) |ent| {
        var cursor = ent.seg.next;
        var segment_count: u32 = 0;
        while (!std.meta.eql(cursor, ent.id.*)) if (self.world.selectOne(
            cursor,
            struct { seg: Segment },
        )) |n| {
            segment_count += 1;
            cursor = n.seg.next;
        } else unreachable;

        const damage = std.math.divCeil(u32, ent.stats.*.max_health, segment_count) catch return true;

        cursor = ent.seg.next;
        while (!std.meta.eql(cursor, ent.id.*)) if (self.world.selectOne(cursor, struct {
            id: EntId,
            seg: Segment,
            mov: Moving,
            ali: Alive,
        })) |n| {
            const prev_health = n.ali.health;
            n.ali.health -|= damage;
            ent.ali.health += prev_health - n.ali.health;
            if (self.world.selectOne(n.id.*, struct { vs: ViwableStats })) |v|
                v.vs.show_stats_until = self.time_millis + 1000;
            if (ent.ali.health >= ent.stats.*.max_health) {
                ent.ali.health = ent.stats.*.max_health;
                break;
            }
            if (n.ali.health == 0) try self.ent_id_buffer.append(alc, cursor);
            cursor = n.seg.next;
        } else unreachable;

        return false;
    }

    return true;
}

fn killTemporary(self: *Game, alc: std.mem.Allocator) !void {
    var iter = self.world.select(struct { id: EntId, temp: Temporary });
    self.ent_id_buffer.items.len = 0;
    while (iter.next()) |e| if (e.temp.ttl < self.time_millis) {
        try self.ent_id_buffer.append(alc, e.id.*);
    };
    try self.removeIdBufferEnts();
}

fn removeIdBufferEnts(self: *Game) !void {
    for (self.ent_id_buffer.items) |id| try self.deinitEnt(id);
}

fn deinitEnt(self: *Game, id: EntId) !void {
    const ent = self.world.get(id) orelse return;

    if (ent.get(InQuad)) |iq| self.teams.get(iq.team).quad.remove(iq.quad_id, id.toRaw());
    if (ent.get(Segment)) |s| Segment.removeOwned(&self.world, s.prev, s.next);

    try self.world.remove(id);
}

fn moveSegments(self: *Game) void {
    var iter = self.world.select(struct {
        head: Head,
        id: EntId,
        posi: Positioned,
        mov: Moving,
        seg: Segment,
        stats: *const Stats,
    });
    while (iter.next()) |u| {
        const prev_vel = u.mov.vel * vec.splat(self.delta);
        var prev_pos = u.posi.pos - vec.rad(u.seg.rot, u.stats.*.radius) + prev_vel;
        u.seg.rot = calcNextRotation(prev_vel, u.seg.rot, u.stats.*.radius * 2.0);
        var current = u.seg.next;
        while (!std.meta.eql(current, u.id.*)) if (self.world.selectOne(current, struct {
            posi: Positioned,
            mov: Moving,
            seg: Segment,
            stats: *const Stats,
        })) |n| {
            const snap_ratio = 1.1;
            var diff = prev_pos - n.posi.pos - vec.rad(n.seg.rot, n.stats.*.radius);
            if (vec.len2(diff) > vec.len2(prev_vel) * snap_ratio) {
                diff = vec.clamp(diff, u.stats.*.accel / u.stats.*.friction * self.delta * self.delta);
            }

            n.seg.rot = calcNextRotation(diff, n.seg.rot, n.stats.*.radius * 2.0);
            n.mov.vel = diff / vec.splat(self.delta);
            prev_pos = n.posi.pos + diff - vec.rad(n.seg.rot, n.stats.*.radius);
            current = n.seg.next;
        } else unreachable;
    }
}

fn move(self: *Game) void {
    var iter = self.world.select(struct { posi: Positioned, mov: Moving, stats: *const Stats });
    while (iter.next()) |u| {
        u.posi.pos += u.mov.vel * vec.splat(self.delta);
        u.mov.vel -= (u.mov.vel * vec.splat(@min(u.stats.*.friction * self.delta * 60.0, 1.0)));
    }
}

fn updateTurrets(self: *Game, alc: std.mem.Allocator) !void {
    var iter = self.world.select(struct {
        posi: Positioned,
        tur: Turret,
        stats: *const Stats,
        iq: InQuad,
    });
    while (iter.next()) |t| {
        const stats = t.stats.*;
        const rangeSq = stats.range * stats.range;
        if (t.tur.target) |target| b: {
            const tar = self.world.get(target) orelse break :b;
            const tar_posi = tar.get(Positioned) orelse break :b;
            if (vec.dist2(t.posi.pos, tar_posi.pos) > rangeSq) break :b;
            if (t.tur.reload_until > self.time_millis) break :b;

            const bullet_stats = Stats{ .radius = 5, .damage = 1, .damage_cooldown = 1, .ttl = 1000, .accel = 1000 };

            const predicted = if (tar.get(Moving)) |mov|
                predictTarget(t.posi.pos, tar_posi.pos, mov.vel, bullet_stats.accel) orelse break :b
            else
                tar_posi.pos;

            // if (vec.dist2(t.posi.pos, predicted) > sqr(bullet_stats.bulletRange())) break :b;

            const innacuracy_offset = randRadVec(self.rng.random(), stats.innacuraci);
            _ = try self.world.create(alc, .{
                &bullet_stats,
                Harmful{},
                Temporary{ .ttl = self.time_millis + bullet_stats.ttl },
                Moving{ .vel = (vec.normalize(predicted - t.posi.pos).? + innacuracy_offset) *
                    vec.splat(bullet_stats.accel) },
                try self.newInQuad(alc, &bullet_stats, t.posi.pos, t.iq.team),
                Positioned{ .pos = t.posi.pos },
            });

            t.tur.reload_until = self.time_millis + stats.reload_time;
        }
        t.tur.target = null;

        var closest: f32 = std.math.floatMax(f32);
        var closest_id: ?EntId = null;

        const bounds = [_]i32{
            @intFromFloat(t.posi.pos[0] - stats.range),
            @intFromFloat(t.posi.pos[1] - stats.range),
            @intFromFloat(t.posi.pos[0] + stats.range),
            @intFromFloat(t.posi.pos[1] + stats.range),
        };
        for (try self.queryTeams(alc, .{ .Except = t.iq.team }, bounds)) |id| {
            const ent = self.world.selectOne(id, struct { posi: Positioned, ali: Alive }) orelse continue;
            const dist = vec.dist2(t.posi.pos, ent.posi.pos);
            if (dist < closest) {
                closest = dist;
                closest_id = id;
            }
        }

        if (closest < rangeSq) if (closest_id) |ci| {
            t.tur.target = ci;
        };
    }
}

fn dbg(t: anytype) @TypeOf(t) {
    std.debug.print("{any}\n", .{t});
    return t;
}

fn updateQuads(self: *Game, alc: std.mem.Allocator) !void {
    var iter = self.world.select(struct { id: EntId, iq: InQuad, posi: Positioned, stats: *const Stats });
    while (iter.next()) |e| {
        try self.teams.get(e.iq.team).quad.update(
            alc,
            &e.iq.quad_id,
            vec.asInt(e.posi.pos),
            @intFromFloat(e.stats.*.radius),
            e.id.toRaw(),
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
    for (visible) |id| {
        const ent = self.world.selectOne(id, struct { posi: Positioned, stats: *const Stats }) orelse continue;
        const view_range = ent.stats.*.radius * 2.0;
        if (bounds[0] > ent.posi.pos[0] + view_range or
            bounds[2] < ent.posi.pos[0] - view_range or
            bounds[1] > ent.posi.pos[1] + view_range or
            bounds[3] < ent.posi.pos[1] - view_range) continue;

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

    var iter = self.world.select(struct { pl: Player });
    while (iter.next()) |p| if (p.pl.selected) |s| if (self.world.selectOne(
        s,
        struct { posi: Positioned },
    )) |ent| {
        rl.drawLineV(vec.asRl(ent.posi.pos), vec.asRl(mouse), rl.Color.yellow);
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

fn drawGroundLayer(self: *Game, ent: ecs.Entity) void {
    if (ent.select(struct { tur: Turret, posi: Positioned, stats: *const Stats })) |t| {
        rl.drawCircleV(vec.asRl(t.posi.pos), t.stats.*.radius, rl.Color.blue);
        if (t.tur.target) |target| if (self.world.selectOne(
            target,
            struct { posi: Positioned },
        )) |tar| {
            rl.drawLineV(vec.asRl(t.posi.pos), vec.asRl(tar.posi.pos), rl.Color.blue);
        };
    }
}

fn drawLowAirLayer(self: *Game, ent: ecs.Entity) void {
    _ = self;

    if (ent.select(struct { posi: Positioned, seg: Segment, stats: *const Stats })) |s| rl.drawCircleV(
        vec.asRl(s.posi.pos - vec.rad(s.seg.rot, s.stats.*.radius)),
        10,
        rl.Color.yellow,
    );
}

fn drawAirLayer(self: *Game, ent: ecs.Entity) void {
    _ = self;
    if (ent.get(Harmful) != null) return;
    if (ent.select(struct { posi: Positioned, stats: *const Stats })) |s| {
        const is_core = ent.get(Core) != null;
        const color = if (is_core) rl.Color.purple else rl.Color.red;
        rl.drawCircleV(vec.asRl(s.posi.pos), s.stats.*.radius, color);
    }
}

fn drawBulletLayer(self: *Game, ent: ecs.Entity) void {
    _ = self;
    if (ent.select(struct { posi: Positioned, stats: *const Stats, hfl: Harmful })) |s| {
        rl.drawCircleV(vec.asRl(s.posi.pos), s.stats.*.radius, rl.Color.white);
    }
}

fn drawStateLayer(self: *Game, ent: ecs.Entity) void {
    const base = ent.select(struct {
        posi: Positioned,
        stats: *const Stats,
        vs: ViwableStats,
    }) orelse return;
    if (base.vs.show_stats_until <= self.time_millis) return;
    const stats = base.stats.*;

    if (ent.get(Alive)) |a| {
        const health_perc = toF32(a.health) / toF32(stats.max_health);
        rl.drawRing(
            vec.asRl(base.posi.pos),
            stats.radius + 2,
            stats.radius + 5,
            0,
            health_perc * 360,
            @intFromFloat(stats.radius * 2),
            rl.Color.green,
        );
    }

    if (ent.get(Turret)) |t| if (t.reload_until > self.time_millis) {
        const reload_perc = 1.0 - toF32(t.reload_until - self.time_millis) / toF32(stats.reload_time);
        rl.drawRing(
            vec.asRl(base.posi.pos),
            stats.radius + 5,
            stats.radius + 8,
            0,
            reload_perc * 360,
            @intFromFloat(stats.radius * 2),
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
    var players = self.world.select(struct {
        pl: Player,
        id: EntId,
        posi: Positioned,
        iq: InQuad,
        stats: *const Stats,
    });
    while (players.next()) |p| {
        const contr = self.world.get(p.id.*) orelse continue;
        const stats = p.stats.*;

        self.camera_target = p.posi.pos;

        if (contr.get(Moving)) |m| m.vel += wasdInput() * vec.splat(stats.accel) * vec.splat(self.delta);

        const cam = self.deriveCamera();
        const mouse = mouseWorldPos(cam);
        const bounds = InQuad.bounds(mouse, 0);

        const hovered = for (try self.queryTeams(alc, .{ .Only = p.iq.team }, bounds)) |id| {
            const ent = self.world.get(id) orelse continue;
            const ent_base = ent.select(struct { posi: Positioned, stats: *const Stats }) orelse continue;
            if (vec.dist2(mouse, ent_base.posi.pos) < sqr(ent_base.stats.*.radius))
                break ent;
        } else null;
        const hovered_id = if (hovered) |h| h.id() else null;

        if (hovered) |h| if (h.select(struct { vs: ViwableStats })) |s| {
            s.vs.show_stats_until = self.time_millis + 1000;
        };

        if (rl.isMouseButtonPressed(.mouse_button_left)) {
            p.pl.selected = hovered_id;
        }

        if (p.pl.selected != null) if (hovered) |other| {
            p.pl.placement = other.id();
        };

        defer if (rl.isMouseButtonReleased(.mouse_button_left)) {
            p.pl.selected = null;
            p.pl.placement = null;
        };

        if (!rl.isMouseButtonReleased(.mouse_button_left)) continue;

        const selected = p.pl.selected orelse continue;
        const placement = p.pl.placement orelse continue;
        const sel_eq_pla = std.meta.eql(selected, placement);
        var selected_ent = self.world.get(selected) orelse continue;
        const placement_ent = self.world.get(placement) orelse continue;

        if (sel_eq_pla) if (!selected_ent.has(Head)) if (try self.world.removeComps(
            alc,
            selected,
            struct { seg: Segment, mov: Moving },
        )) |s| {
            Segment.removeOwned(&self.world, s.seg.prev, s.seg.next);
            continue;
        };

        if (!selected_ent.has(Segment) and placement_ent.has(Segment)) {
            try self.world.addComps(alc, selected, .{ self.newSegment(), Moving{} });
            Segment.insert(&self.world, p.id.*, selected);
            selected_ent = self.world.get(selected).?;
        }

        if (!sel_eq_pla and
            placement_ent.has(Segment) and
            !selected_ent.has(Head) and
            selected_ent.has(Segment))
        {
            Segment.remove(&self.world, selected);
            Segment.insert(&self.world, placement, selected);
            continue;
        }
    }
}

fn wasdInput() Vec {
    var dir = vec.splat(0.0);
    if (rl.isKeyDown(.key_a)) dir[0] -= 1.0;
    if (rl.isKeyDown(.key_d)) dir[0] += 1.0;
    if (rl.isKeyDown(.key_w)) dir[1] -= 1.0;
    if (rl.isKeyDown(.key_s)) dir[1] += 1.0;
    return vec.normalize(dir) orelse .{ 0, 0 };
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

fn sqr(v: f32) f32 {
    return v * v;
}

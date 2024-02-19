const std = @import("std");
const ecs = @import("ecs.zig");
const rl = @import("raylib");
const Quad = @import("QuadTree.zig");

const Game = @This();

const Pos = @Vector(2, i32);

fn posDistSqr(a: Pos, b: Pos) i32 {
    const d = a - b;

    return @reduce(.Add, d * d);
}

fn posToRlVec2(pos: Pos) rl.Vector2 {
    return .{ .x = @floatFromInt(pos[0]), .y = @floatFromInt(pos[1]) };
}

fn rlVec2ToPos(vec: rl.Vector2) Pos {
    return .{ @intFromFloat(vec.x), @intFromFloat(vec.y) };
}

const EntKind = enum {
    Player,
    Unit,
    Turret,
};

const Ent = union(EntKind) {
    const Player = struct {
        controlling: EntId,
    };

    const Unit = struct {
        pos: Pos,
        circle: u32,
        membership: Team.Membership,
    };

    const Turret = struct {
        pos: Pos,
        circle: u32,
        range: i32,
        target: ?EntId,
        membership: Team.Membership,
    };

    Player: Player,
    Unit: Unit,
    Turret: Turret,
};

const World = ecs.World(Ent);
const EntId = ecs.EntId(EntKind);

const Team = struct {
    const invalid_id = std.math.maxInt(Id);

    const Id = u32;

    const Filter = union(enum) {
        All,
        Only: Id,
        Except: Id,
    };

    const Membership = struct {
        team: Id,
        quad: Quad.Id,
    };

    const Store = struct {
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
        return .{ .quad = try Quad.init(alc, 1 << 20) };
    }

    pub fn deinit(self: *Team, alc: std.mem.Allocator) void {
        self.quad.deinit(alc);
        self.* = undefined;
    }
};

world: World = .{},
teams: Team.Store = .{},
query_buffer: std.ArrayListUnmanaged(u64) = .{},
rng: std.rand.Xoroshiro128 = std.rand.Xoroshiro128.init(0),
delta: f32 = 0.0,
camera_target: Pos = .{ 0, 0 },

pub fn deinit(self: *Game, alc: std.mem.Allocator) void {
    self.world.deinit(alc);
    self.teams.deinit(alc);
    self.query_buffer.deinit(alc);
    self.* = undefined;
}

pub fn initStateForNow(self: *Game, alc: std.mem.Allocator) !void {
    const player_team = try self.teams.add(alc, try Team.init(alc));
    const quad = &self.teams.get(player_team).quad;

    const player_unit = try self.world.add(alc, .{ .Unit = .{
        .pos = .{ 0, 0 },
        .circle = 20,
        .membership = .{
            .team = player_team,
            .quad = try quad.insert(alc, .{ 0, 0 }, 20, self.world.nextId(.Unit).toRaw()),
        },
    } });
    _ = try self.world.add(alc, .{ .Player = .{ .controlling = player_unit } });

    const enemy_team = try self.teams.add(alc, try Team.init(alc));
    const enemy_quad = &self.teams.get(enemy_team).quad;

    for (0..10000) |_| {
        const pos = .{
            self.rng.random().intRangeAtMost(i32, -10000, 10000),
            self.rng.random().intRangeAtMost(i32, -10000, 10000),
        };
        _ = try self.world.add(alc, .{ .Turret = .{
            .pos = pos,
            .circle = 20,
            .range = 300,
            .target = null,
            .membership = .{
                .team = enemy_team,
                .quad = try enemy_quad.insert(alc, pos, 20, self.world.nextId(.Turret).toRaw()),
            },
        } });
    }
}

pub fn update(self: *Game, alc: std.mem.Allocator) !void {
    self.delta = rl.getFrameTime();

    try self.updateQuads(alc);
    try self.updateTurrets(alc);
}

pub fn draw(self: *Game, alc: std.mem.Allocator) !void {
    rl.beginDrawing();
    defer rl.endDrawing();

    rl.clearBackground(rl.Color.white);

    const camera = self.deriveCamera();
    camera.begin();
    defer camera.end();

    const bounds = viewportBounds(camera);

    drawQuadTree(&self.teams.get(1).quad, 0);

    for (try self.queryTeams(alc, .All, bounds)) |id| {
        if (self.world.selectOne(id, struct { pos: Pos })) |ent|
            if (bounds[0] <= ent.pos[0] and ent.pos[0] <= bounds[2] and
                bounds[1] <= ent.pos[1] and ent.pos[1] <= bounds[3])
                self.drawEntity(id);
    }
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

fn viewportBounds(camera: rl.Camera2D) [4]i32 {
    const top_left = rlVec2ToPos(rl.getScreenToWorld2D(
        rl.Vector2.init(0.0, 0.0),
        camera,
    ));
    const bottom_right = rlVec2ToPos(rl.getScreenToWorld2D(
        posToRlVec2(.{ rl.getScreenWidth(), rl.getScreenHeight() }),
        camera,
    ));

    return .{ top_left[0], top_left[1], bottom_right[0], bottom_right[1] };
}

pub fn input(self: *Game) void {
    self.controlPlayers();
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

fn deriveCamera(self: *Game) rl.Camera2D {
    const target = posToRlVec2(self.camera_target);
    return .{
        .offset = .{
            .x = @floatFromInt(rl.getScreenWidth() >> 1),
            .y = @floatFromInt(rl.getScreenHeight() >> 1),
        },
        .target = target,
        .rotation = 0.0,
        .zoom = 1.0,
    };
}

fn controlPlayers(self: *Game) void {
    const speed = 300.0;

    var players = self.world.select(Ent.Player);
    while (players.next()) |p| {
        switch (self.world.get(p.ent.controlling.*) orelse continue) {
            .Unit => |u| {
                // TODO: diagonal speed is higher
                if (rl.isKeyDown(.key_a)) u.pos[0] -= @intFromFloat(speed * self.delta);
                if (rl.isKeyDown(.key_d)) u.pos[0] += @intFromFloat(speed * self.delta);
                if (rl.isKeyDown(.key_w)) u.pos[1] -= @intFromFloat(speed * self.delta);
                if (rl.isKeyDown(.key_s)) u.pos[1] += @intFromFloat(speed * self.delta);

                self.camera_target = u.pos.*;
            },
            else => {},
        }
    }
}

fn updateTurrets(self: *Game, alc: std.mem.Allocator) !void {
    var iter = self.world.select(Ent.Turret);
    while (iter.next()) |t| {
        const rangeSq = t.ent.range.* * t.ent.range.*;
        if (t.ent.target.*) |target|
            if (self.world.selectOne(target, struct { pos: Pos })) |tar|
                if (posDistSqr(t.ent.pos.*, tar.pos.*) > rangeSq) {
                    t.ent.target.* = null;
                } else continue;

        var closest: i32 = std.math.maxInt(i32);
        var closest_id: ?EntId = null;

        const bounds = .{
            t.ent.pos[0] - t.ent.range.*,
            t.ent.pos[1] - t.ent.range.*,
            t.ent.pos[0] + t.ent.range.*,
            t.ent.pos[1] + t.ent.range.*,
        };
        for (try self.queryTeams(alc, .{ .Except = t.ent.membership.team }, bounds)) |id| {
            const ent = self.world.selectOne(id, struct { pos: Pos }) orelse continue;
            const dist = posDistSqr(t.ent.pos.*, ent.pos.*);
            if (dist < closest) {
                closest = dist;
                closest_id = id;
            }
        }

        if (closest < rangeSq) if (closest_id) |ci| {
            t.ent.target.* = ci;
        };
    }
}

fn updateQuads(self: *Game, alc: std.mem.Allocator) !void {
    var iter = self.world.select(struct { membership: Team.Membership, circle: u32, pos: Pos });
    while (iter.next()) |e| {
        try self.teams.get(e.ent.membership.team).quad.update(
            alc,
            &e.ent.membership.quad,
            @bitCast(e.ent.pos.*),
            @intCast(e.ent.circle.*),
            e.id.toRaw(),
        );
    }
}

fn drawEntity(self: *Game, id: EntId) void {
    switch (self.world.get(id) orelse return) {
        .Unit => |u| {
            rl.drawCircle(u.pos[0], u.pos[1], @floatFromInt(u.circle.*), rl.Color.red);
        },
        .Turret => |t| {
            rl.drawCircle(t.pos[0], t.pos[1], @floatFromInt(t.circle.*), rl.Color.blue);
            if (t.target.*) |target| if (self.world.selectOne(target, struct { pos: Pos })) |tar| {
                rl.drawLine(t.pos[0], t.pos[1], tar.pos[0], tar.pos[1], rl.Color.blue);
            };
        },
        else => {},
    }
}

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
world: World = .{},
quad: Quad,
player: Id,
camera: rl.Camera2D,

player_sprite: rl.Texture2D,

const std = @import("std");
const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
    @cInclude("rlgl.h");
});
const vec = @import("vec.zig");
const Vec = vec.T;
const World = @import("ecs.zig").World(comps);
const Quad = @import("QuadTree.zig");
const Game = @This();
const Id = World.Id;

const comps = struct {
    pub const Stats = struct { *const struct {
        fric: f32 = 0,
        size: f32 = 15,

        pub fn mass(self: *const @This()) f32 {
            return std.math.pow(f32, self.size, 2) * std.math.pi;
        }
    } };
    pub const Pos = struct { Vec };
    pub const Vel = struct { Vec };
    pub const Rot = struct { f32 };
    pub const Phy = struct { coll_id: u32 = std.math.maxInt(u32), quad: Quad.Id };
    pub const Tmp = struct { f32 };
};

const Particle = extern struct {
    pos: Vec,
    vel: Vec,
    lifetime: f32,
    _padd: f32 = undefined,
};

const max_particles = 64;

pub fn run() !void {
    rl.SetTargetFPS(360);

    rl.InitWindow(800, 600, "slet");
    defer rl.CloseWindow();

    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = alloc.deinit();
    var self = try Game.init(alloc.allocator());
    defer self.deinit();

    for (0..100) |i| {
        for (0..100) |j| {
            const pos = .{ 20 * @as(f32, @floatFromInt(i + 1)), 20 * @as(f32, @floatFromInt(j + 1)) };
            _ = try self.world.create(self.gpa, .{
                comps.Stats{&.{
                    .fric = 1,
                    .size = 1,
                }},
                comps.Pos{pos},
                comps.Vel{vec.zero},
                comps.Phy{ .quad = try self.quad.insert(self.gpa, vec.asInt(pos), 15, self.world.nextId().toRaw()) },
            });
        }
    }

    while (!rl.WindowShouldClose()) {
        std.debug.assert(self.arena.reset(.retain_capacity));

        try self.update();
        try self.input();

        rl.BeginDrawing();
        defer rl.EndDrawing();
        try self.draw();
    }
}

fn init(gpa: std.mem.Allocator) !Game {
    var world = World{};
    var quad = try Quad.init(gpa, 20);

    return .{
        .player_sprite = rl.LoadTexture("assets/player.png"),

        .player = try world.create(gpa, .{
            comps.Stats{&.{ .fric = 1 }},
            comps.Pos{.{ 0, 0 }},
            comps.Vel{vec.zero},
            comps.Phy{ .quad = try quad.insert(gpa, .{ 0, 0 }, 15, world.nextId().toRaw()) },
        }),
        .camera = rl.Camera2D{ .zoom = 1.0, .offset = .{ .x = 400, .y = 300 } },

        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .world = world,
        .quad = quad,
    };
}

fn deinit(self: *Game) void {
    self.world.deinit(self.gpa);
    self.quad.deinit(self.gpa);
    self.arena.deinit();
    rl.UnloadTexture(self.player_sprite);
}

fn input(self: *Game) !void {
    b: {
        const player = self.world.selectOne(self.player, struct {
            stats: comps.Stats,
            vel: comps.Vel,
            pos: comps.Pos,
        }) orelse break :b;

        const face = vec.norm(self.mousePos() - player.pos[0]);

        if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
            const acc = 700.0;
            const trust = face * vec.splat(acc * rl.GetFrameTime());
            player.vel[0] += trust;
        }

        if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_RIGHT)) {
            const pos = face * -vec.splat(player.stats[0].size + 10) + player.pos[0];
            const vel = face * -vec.splat(1000);
            _ = try self.world.create(self.gpa, .{
                comps.Stats{&.{ .fric = 5, .size = 3 }},
                comps.Pos{pos},
                comps.Vel{vel},
                comps.Phy{ .quad = try self.quad.insert(self.gpa, vec.asInt(pos), 3, self.world.nextId().toRaw()) },
                comps.Tmp{@floatCast(rl.GetTime() + 10)},
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
    return @bitCast(rl.GetScreenToWorld2D(rl.GetMousePosition(), self.camera));
}

fn update(self: *Game) !void {
    const delta = rl.GetFrameTime();

    {
        var to_delete = std.ArrayList(Id).init(self.arena.allocator());
        var tmps = self.world.select(struct { tmp: comps.Tmp, id: Id });
        while (tmps.next()) |pb| {
            if (pb.tmp[0] < rl.GetTime()) try to_delete.append(pb.id.*);
        }
        for (to_delete.items) |id| {
            if (self.world.selectOne(id, struct { phy: comps.Phy })) |n|
                self.quad.remove(n.phy.quad, @bitCast(id));
            std.debug.assert(self.world.remove(id));
        }
    }

    {
        var quds = self.world.select(struct {
            id: Id,
            stats: comps.Stats,
            pos: comps.Pos,
            vel: comps.Vel,
            phy: comps.Phy,
        });
        while (quds.next()) |qds| {
            const pos = vec.asInt(qds.pos[0] + qds.vel[0] * vec.splat(0.5));
            const size: i32 = @intFromFloat(qds.stats[0].size * 2 + vec.len(qds.vel[0]));
            try self.quad.update(self.gpa, &qds.phy.quad, pos, size, qds.id.toRaw());
        }
    }

    {
        const Q = struct {
            id: Id,
            vel: comps.Vel,
            pos: comps.Pos,
            stats: comps.Stats,
            phy: comps.Phy,
        };
        var pbodies = self.world.select(Q);

        var collisions = std.ArrayList(struct { a: Id, b: Id, t: f32 }).init(self.arena.allocator());
        var matches = std.ArrayList(u64).init(self.arena.allocator());

        while (pbodies.next()) |pb| {
            const pos = vec.asInt(pb.pos[0] + pb.vel[0] * vec.splat(0.5));
            const size: i32 = @intFromFloat(pb.stats[0].size * 2 + vec.len(pb.vel[0]));
            matches.items.len = 0;
            try self.quad.query(.{
                pos[0] - size,
                pos[1] - size,
                pos[0] + size,
                pos[1] + size,
            }, &matches);

            for (matches.items) |id| {
                if (id == @as(u64, @bitCast(pb.id.*))) continue;
                const opb = self.world.selectOne(@bitCast(id), Q).?;

                const g = pb.stats[0].size + opb.stats[0].size;

                const dist = vec.dist2(pb.pos[0], opb.pos[0]);
                if (g * g > dist) {
                    if (pb.stats[0].size > opb.stats[0].size) {
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

                if (pb.phy.coll_id != std.math.maxInt(u32)) if (collisions.items[pb.phy.coll_id].t > t) {
                    collisions.items[pb.phy.coll_id].t = delta;
                } else continue;

                if (opb.phy.coll_id != std.math.maxInt(u32)) if (collisions.items[opb.phy.coll_id].t > t) {
                    collisions.items[opb.phy.coll_id].t = delta;
                } else continue;

                pb.phy.coll_id = @intCast(collisions.items.len);
                opb.phy.coll_id = @intCast(collisions.items.len);
                try collisions.append(.{ .a = pb.id.*, .b = opb.id.*, .t = t });
            }
        }

        for (collisions.items) |col| {
            const pb = self.world.selectOne(col.a, Q).?;
            const opb = self.world.selectOne(col.b, Q).?;

            pb.phy.coll_id = std.math.maxInt(u32);
            opb.phy.coll_id = std.math.maxInt(u32);

            if (col.t == delta) continue;

            pb.pos[0] += pb.vel[0] * vec.splat(col.t);
            opb.pos[0] += opb.vel[0] * vec.splat(col.t);

            const dist = vec.dist(pb.pos[0], opb.pos[0]);

            const mass = pb.stats[0].mass();
            const amass = opb.stats[0].mass();

            const norm = (opb.pos[0] - pb.pos[0]) / vec.splat(dist);
            const p = 2 * (vec.dot(pb.vel[0], norm) - vec.dot(opb.vel[0], norm)) / (mass + amass);
            pb.vel[0] -= vec.splat(p * amass) * norm;
            opb.vel[0] += vec.splat(p * mass) * norm;

            pb.pos[0] += pb.vel[0] * vec.splat(delta - col.t);
            opb.pos[0] += opb.vel[0] * vec.splat(delta - col.t);

            pb.pos[0] -= pb.vel[0] * vec.splat(delta);
            opb.pos[0] -= opb.vel[0] * vec.splat(delta);
        }
    }

    {
        var bodies = self.world.select(struct {
            vel: comps.Vel,
            pos: comps.Pos,
            stats: comps.Stats,
        });
        while (bodies.next()) |ent| {
            ent.pos[0] += ent.vel[0] * vec.splat(delta);
            ent.vel[0] *= vec.splat(1 - ent.stats[0].fric * delta);
        }
    }
}

fn closestPointOnLine(l1: Vec, l2: Vec, p: Vec) Vec {
    const a = l2[1] - l1[1];
    const b = l1[0] - l2[0];
    const c1 = a * l1[0] + b * l1[1];
    const c2 = -b * p[0] + a * p[1];
    const det = a * a + b * b;
    if (det == 0) return p;
    return .{ (a * c1 - b * c2) / det, (a * c2 - -b * c1) / det };
}

fn draw(self: *Game) !void {
    rl.ClearBackground(rl.BLACK);

    rl.BeginMode2D(self.camera);

    rl.DrawLine(0, 0, 0, 10000, rl.WHITE);

    b: {
        const player = self.world.selectOne(self.player, struct { pos: comps.Pos }) orelse break :b;
        const scale = 5.0;
        const dir = vec.ang(self.mousePos() - player.pos[0]);
        drawCenteredTexture(self.player_sprite, player.pos[0], dir, scale);
    }

    if (false) {
        var pbodies = self.world.select(struct {
            pos: comps.Pos,
            stats: comps.Stats,
            phy: comps.Phy,
        });
        while (pbodies.next()) |pb| {
            rl.DrawCircleV(vec.asRl(pb.pos[0]), pb.stats[0].size, rl.RED);
        }
    }

    rl.EndMode2D();

    rl.DrawFPS(20, 20);
}

inline fn drawCenteredTexture(texture: rl.Texture2D, pos: Vec, rot: f32, scale: f32) void {
    const real_width = tof(texture.width) * scale;
    const real_height = tof(texture.height) * scale;
    rl.DrawTexturePro(
        texture,
        rl.Rectangle{ .x = 0, .y = 0, .width = tof(texture.width), .height = tof(texture.height) },
        rl.Rectangle{ .x = pos[0], .y = pos[1], .width = real_width, .height = real_height },
        rl.Vector2{ .x = real_width / 2, .y = real_height / 2 },
        rot / std.math.tau * 360,
        rl.WHITE,
    );
}

inline fn angleOf(v: rl.Vector2) f32 {
    return std.math.atan2(v.y, v.x);
}

inline fn tof(value: anytype) f32 {
    return @floatFromInt(value);
}

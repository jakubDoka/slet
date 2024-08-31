gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
stat_arena: std.heap.ArenaAllocator,

world: World = .{},
quad: Quad,

player: Id,
player_reload: f64 = 0.0,
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
const World = @import("ecs.zig").World(cms);
const Quad = @import("QuadTree.zig");
const Game = @This();
const Id = World.Id;

const Stats = struct {
    fric: f32 = 0,
    size: f32 = 15,
    texture: ?rl.Texture2D = null,

    pub fn mass(self: *const @This()) f32 {
        return std.math.pow(f32, self.size, 2) * std.math.pi;
    }
};

const cms = struct {
    pub const Stt = struct { *const Stats };
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
    rl.SetTargetFPS(60);

    rl.InitWindow(800, 600, "slet");
    defer rl.CloseWindow();

    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = alloc.deinit();
    var self = try Game.init(alloc.allocator());
    defer self.deinit();

    for (0..2) |i| {
        for (0..2) |j| {
            const pos = .{ 100 * @as(f32, @floatFromInt(i + 1)), 100 * @as(f32, @floatFromInt(j + 1)) };
            _ = try self.world.create(self.gpa, .{
                cms.Stt{&.{
                    .fric = 1,
                    .size = 30,
                }},
                cms.Pos{pos},
                cms.Vel{vec.zero},
                cms.Phy{ .quad = try self.quad.insert(self.gpa, vec.asInt(pos), 15, self.world.nextId().toRaw()) },
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
    var stat_arena = std.heap.ArenaAllocator.init(gpa);
    const player_sprite = rl.LoadTexture("assets/player.png");

    const stats = try stat_arena.allocator().create(Stats);
    stats.* = .{ .fric = 1, .texture = player_sprite };

    return .{
        .player_sprite = player_sprite,

        .player = try world.create(gpa, .{
            cms.Stt{stats},
            cms.Pos{.{ 0, 0 }},
            cms.Vel{vec.zero},
            cms.Phy{ .quad = try quad.insert(gpa, .{ 0, 0 }, 15, world.nextId().toRaw()) },
        }),
        .camera = rl.Camera2D{ .zoom = 1.0, .offset = .{ .x = 400, .y = 300 } },

        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .stat_arena = stat_arena,
        .world = world,
        .quad = quad,
    };
}

fn deinit(self: *Game) void {
    self.arena.deinit();
    self.stat_arena.deinit();

    self.world.deinit(self.gpa);
    self.quad.deinit(self.gpa);

    rl.UnloadTexture(self.player_sprite);
}

fn createStats(self: *Game, stats: Stats) !cms.Stt {
    const alloc = try self.stat_arena.allocator().create(Stats);
    alloc.* = stats;
    return cms.Stt{alloc};
}

fn input(self: *Game) !void {
    b: {
        const player = self.world.selectOne(
            self.player,
            struct { cms.Stt, cms.Vel, cms.Pos },
        ) orelse break :b;

        const face = vec.norm(self.mousePos() - player.pos[0]);

        if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
            const acc = 700.0;
            const trust = face * vec.splat(acc * rl.GetFrameTime());
            player.vel[0] += trust;
        }

        if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_RIGHT) and self.player_reload < rl.GetTime()) {
            self.player_reload = rl.GetTime() + 0.5;
            const pos = face * vec.splat(player.stt[0].size + 10) + player.pos[0];
            const vel = face * vec.splat(1000);
            _ = try self.world.create(self.gpa, .{
                cms.Stt{&.{ .fric = 0.5, .size = 4 }},
                cms.Pos{pos},
                cms.Vel{vel},
                cms.Phy{ .quad = try self.quad.insert(self.gpa, vec.asInt(pos), 3, self.world.nextId().toRaw()) },
                cms.Tmp{@floatCast(rl.GetTime() + 2)},
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
        var tmps = self.world.select(struct { cms.Tmp, Id });
        while (tmps.next()) |pb| {
            if (pb.tmp[0] < rl.GetTime()) try to_delete.append(pb.id.*);
        }
        for (to_delete.items) |id| {
            if (self.world.selectOne(id, struct { cms.Phy })) |n|
                self.quad.remove(n.phy.quad, @bitCast(id));
            std.debug.assert(self.world.remove(id));
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
            while (query.next()) |qid| for (self.quad.entities(qid)) |id| {
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

                if (pb.phy.coll_id != std.math.maxInt(u32)) if (collisions.items[pb.phy.coll_id].t > t) {
                    collisions.items[pb.phy.coll_id].t = delta;
                } else continue;

                if (opb.phy.coll_id != std.math.maxInt(u32)) if (collisions.items[opb.phy.coll_id].t > t) {
                    collisions.items[opb.phy.coll_id].t = delta;
                } else continue;

                pb.phy.coll_id = @intCast(collisions.items.len);
                opb.phy.coll_id = @intCast(collisions.items.len);
                try collisions.append(.{ .a = pb.id.*, .b = opb.id.*, .t = t });
            };
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

            const mass = pb.stt[0].mass();
            const amass = opb.stt[0].mass();

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
        var bodies = self.world.select(struct { cms.Vel, cms.Pos, cms.Stt });
        while (bodies.next()) |ent| {
            ent.pos[0] += ent.vel[0] * vec.splat(delta);
            ent.vel[0] *= vec.splat(1 - ent.stt[0].fric * delta);
        }
    }
}

fn draw(self: *Game) !void {
    rl.ClearBackground(rl.BLACK);

    rl.BeginMode2D(self.camera);

    rl.DrawLine(0, 0, 0, 10000, rl.WHITE);

    const player = self.world.selectOne(self.player, struct { cms.Pos }) orelse return;
    {
        const scale = 5.0;
        const dir = vec.ang(self.mousePos() - player.pos[0]);
        drawCenteredTexture(self.player_sprite, player.pos[0], dir, scale);
    }

    const width = @divFloor(rl.GetScreenWidth(), 2);
    const height = @divFloor(rl.GetScreenHeight(), 2);
    const cx, const cy = vec.asInt(player.pos[0]);
    const bounds: [4]i32 = .{ cx - width, cy - height, cx + width, cy + height };

    var iter = self.quad.queryIter(bounds, 0);
    while (iter.next()) |quid| for (self.quad.entities(quid)) |id| {
        const pb = self.world.selectOne(@bitCast(id), struct { cms.Pos, cms.Stt, cms.Phy }).?;
        rl.DrawCircleV(vec.asRl(pb.pos[0]), pb.stt[0].size, rl.RED);
    };

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

const std = @import("std");
const ecs = @import("ecs.zig");

const Quad = @import("QuadTree.zig");
const Id = ecs.Id;

const assets = @import("assets.zig");

pub fn Level(comptime Spec: type) type {
    return @TypeOf(level(Spec, undefined));
}

const ColisionRec = struct { a: Id, b: Id, t: f32 };

pub fn level(comptime Spec: type, gpa: std.mem.Allocator) struct {
    sheet: rl.Texture2D = undefined,
    spec: Spec = .{},
    world: World,
    quad: Quad,

    time: u32 = 0,
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),
    player: Id = undefined,
    camera: rl.Camera2D = .{ .zoom = 1, .offset = .{ .x = 400, .y = 300 } },
    to_delete: std.ArrayList(Id),
    collisions: std.ArrayList(ColisionRec),

    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    const rl = @import("main.zig").rl;
    const vec = @import("vec.zig");
    const tof = @import("main.zig").tof;

    const Self = @This();
    const Vec = vec.T;
    const World = ecs.World(Spec.Ents);

    pub const Hralth = struct {
        points: u32,
        hit_tween: u32 = 0,

        pub fn draw(self: *@This(), ctx: anytype, game: *Self) f32 {
            var tone: f32 = 1;

            if (game.timeRem(self.hit_tween)) |n| {
                tone -= @import("main.zig").divToFloat(n, Spec.hit_tween_duration);
            }

            if (self.points != @TypeOf(ctx.*).max_health) {
                const end = 360 * @import("main.zig").divToFloat(self.points, @TypeOf(ctx.*).max_health);
                const size = @TypeOf(ctx.*).size;
                rl.DrawRing(vec.asRl(ctx.pos), size + 5, size + 8, 0.0, end, 50, rl.GREEN);
            }

            return tone;
        }
    };

    pub const Phy = struct {
        coll_id: u32 = std.math.maxInt(u32),
        quad: Quad.Id = undefined,
    };

    pub const Turret = struct {
        rot: f32 = 0,
        reload: u32 = 0,
        target: Id = Id.invalid,

        pub fn update(self: *@This(), ctx: anytype, game: *Self) void {
            const bullet_tag = .enemy_bullet;
            const Bullet = std.meta.TagPayload(Spec.Ents, bullet_tag);

            if (self.target != Id.invalid) if (game.world.field(self.target, .pos)) |target| b: {
                var pos = target.*;

                if (vec.dist(pos, ctx.pos) > @TypeOf(ctx.*).sight) {
                    break :b;
                }

                if (game.world.field(self.target, .vel)) |vel| {
                    pos = vec.predictTarget(ctx.pos, pos, vel.*, Bullet.speed) orelse break :b;
                }

                const dir = vec.norm(pos - ctx.pos);
                self.rot = vec.ang(dir);

                if (game.timer(&self.reload, @TypeOf(ctx.*).reload)) {
                    const bull = game.world.add(bullet_tag, .{
                        .pos = ctx.pos,
                        .vel = ctx.vel + vec.rad(self.rot, Bullet.speed),
                        .live_until = game.time + Bullet.lifetime,
                    });
                    game.initPhy(bull, bullet_tag);
                }

                return;
            };

            self.target = game.findEnemy(ctx) orelse Id.invalid;
        }
    };

    pub fn findEnemy(self: *Self, ctx: anytype) ?Id {
        const pos = vec.asInt(ctx.pos);
        const size: i32 = @intFromFloat(@TypeOf(ctx.*).sight);
        const bds = .{ pos[0] - size, pos[1] - size, pos[0] + size, pos[1] + size };
        var iter = self.quad.queryIter(bds, 0);
        while (iter.next()) |quid| for (self.quad.entities(quid)) |rid| {
            const id: Id = @enumFromInt(rid);
            if (World.cnst(ctx.id, .team) == World.cnst(id, .team)) continue;
            const opos = (self.world.field(id, .pos) orelse continue).*;
            if (vec.dist(opos, ctx.pos) > @TypeOf(ctx.*).sight) continue;
            return id;
        };
        return null;
    }

    pub fn mousePos(self: *Self) Vec {
        return vec.fromRl(rl.GetScreenToWorld2D(rl.GetMousePosition(), self.camera));
    }

    pub fn drawTexture(self: *Self, texture: *const assets.Frame, pos: Vec, scale: f32, color: rl.Color) void {
        const real_width = texture.r.f.width * scale;
        const real_height = texture.r.f.height * scale;
        const dst = .{ .x = pos[0], .y = pos[1], .width = real_width, .height = real_height };
        const origin = .{ .x = 0, .y = 0 };
        rl.DrawTexturePro(self.sheet, texture.r.f, dst, origin, 0, color);
    }

    pub fn drawCenteredTexture(self: *Self, texture: assets.Frame, pos: Vec, rot: f32, size: f32, color: rl.Color) void {
        const scale = size / (texture.width / 2);
        const real_width = texture.width * scale;
        const real_height = texture.height * scale;
        const dst = .{ .x = pos[0], .y = pos[1], .width = real_width, .height = real_height };
        const origin = .{ .x = real_width / 2, .y = real_height / 2 };
        rl.DrawTexturePro(self.sheet, texture, dst, origin, rot / std.math.tau * 360, color);
    }

    pub fn deinit(self: *Self) void {
        if (@hasDecl(Spec, "deinit")) self.spec.deinit(self.gpa);
        self.arena.deinit();
        self.world.deinit();
        self.quad.deinit(self.gpa);
        self.to_delete.deinit();
        self.collisions.deinit();

        self.* = undefined;
    }

    pub fn initPhy(self: *Self, id: Id, comptime tag: anytype) void {
        const ent = self.world.get(id, tag).?;
        ent.phys.quad = self.quad.insert(
            self.gpa,
            vec.asInt(ent.pos),
            @intFromFloat(World.cnst(id, .size)),
            @intFromEnum(id),
        ) catch unreachable;
    }

    pub fn run(self: *Self) void {
        while (!rl.WindowShouldClose()) {
            Spec.init(self);

            while (!rl.WindowShouldClose() and self.world.get(self.player, .player) != null) {
                std.debug.assert(self.arena.reset(.retain_capacity));
                self.time = @intFromFloat(rl.GetTime() * 1000);

                self.update();
                self.input();

                rl.BeginDrawing();
                defer rl.EndDrawing();
                self.draw();
            }

            self.reset();
        }
    }

    pub fn reset(self: *Self) void {
        if (@hasDecl(Spec, "reset")) Spec.reset(self);
        self.world.deinit();
        self.quad.deinit(self.gpa);
        self.world = .{ .gpa = self.gpa };
        self.quad = Quad.init(self.gpa, 20) catch unreachable;
        self.prng = std.Random.DefaultPrng.init(0);
    }

    pub fn update(self: *Self) void {
        self.world.invokeForAll(.update, .{self});
        if (@hasDecl(Spec, "update")) Spec.update(self);

        for (self.to_delete.items) |id| {
            _ = self.world.invoke(id, .onDelete, .{self});
            if (self.world.field(id, .phys)) |phys| {
                self.quad.remove(self.gpa, phys.quad, @intFromEnum(id));
            }
            std.debug.assert(self.world.remove(id));
        }
        self.to_delete.items.len = 0;
    }

    pub fn queueDelete(self: *Self, id: Id) void {
        self.to_delete.append(id) catch unreachable;
    }

    pub fn folowWithCamera(self: *Self, pos: Vec) void {
        self.camera.target = vec.asRl(std.math.lerp(pos, vec.fromRl(self.camera.target), vec.splat(0.4)));
        self.camera.offset = .{
            .x = tof(@divFloor(rl.GetScreenWidth(), 2)),
            .y = tof(@divFloor(rl.GetScreenHeight(), 2)),
        };
    }

    pub fn updatePhysics(self: *Self) void {
        const delta = rl.GetFrameTime();
        inline for (self.world.slct(enum { pos, vel })) |s| for (s) |*ent| {
            ent.pos += ent.vel * vec.splat(delta);
            ent.vel *= vec.splat(1 - @TypeOf(ent.*).friction * delta);
        };
    }

    pub fn killTemporaryEnts(self: *Self) void {
        inline for (self.world.slct(enum { live_until })) |s| for (s) |tmp| {
            if (self.timeRem(tmp.live_until) == null) self.queueDelete(tmp.id);
        };
    }

    pub fn input(self: *Self) void {
        if (@hasDecl(Spec, "input")) Spec.input(self);
    }

    fn draw(self: *Self) void {
        rl.ClearBackground(rl.BLACK);

        rl.BeginMode2D(self.camera);

        if (@hasDecl(Spec, "drawWorld")) Spec.drawWorld(self);

        rl.EndMode2D();

        if (@hasDecl(Spec, "drawUi")) Spec.drawUi(self);

        rl.DrawFPS(20, 20);
    }

    pub fn drawParticles(self: *Self) void {
        inline for (self.world.slct(enum { particle })) |s| for (s) |*pt| {
            pt.draw(self);
        };
    }

    pub fn drawVisibleEntities(self: *Self) void {
        const player = self.world.get(self.player, .player) orelse return;
        const width = @divFloor(rl.GetScreenWidth(), 2);
        const height = @divFloor(rl.GetScreenHeight(), 2);
        const cx, const cy = vec.asInt(player.pos);
        const bounds: [4]i32 = .{ cx - width, cy - height, cx + width, cy + height };

        var iter = self.quad.queryIter(bounds, 0);
        while (iter.next()) |quid| for (self.quad.entities(quid)) |uid| {
            const id: Id = @enumFromInt(uid);

            if (self.world.invoke(id, .draw, .{self}) == null) {
                rl.DrawCircleV(vec.asRl(self.world.field(id, .pos).?.*), World.cnst(id, .size), rl.RED);
            }
        };
    }

    pub fn drawOffScreenEnemyIndicators(self: *Self) void {
        const pos = self.world.get(self.player, .player) orelse return;

        const tl = vec.fromRl(rl.GetScreenToWorld2D(vec.asRl(vec.zero), self.camera));
        const r = tof(rl.GetScreenWidth());
        const b = tof(rl.GetScreenHeight());
        const br = vec.fromRl(rl.GetScreenToWorld2D(vec.asRl(.{ r, b }), self.camera));
        const radius = 20;
        const font_size = 14;

        var dots = std.ArrayList(struct { Vec, usize }).init(self.arena.allocator());
        inline for (self.world.slct(enum { pos, indicated_enemy })) |s| for (s) |el| {
            const point =
                vec.intersect(0, el.pos, pos, tl[1], tl[0], br[0]) orelse
                vec.intersect(0, el.pos, pos, br[1], tl[0], br[0]) orelse
                vec.intersect(1, el.pos, pos, tl[0], tl[1], br[1]) orelse
                vec.intersect(1, el.pos, pos, br[0], tl[1], br[1]);

            if (point) |p| {
                for (dots.items) |*op| {
                    const diameter = radius * 2;
                    if (vec.dist2(op[0], p) < tof(diameter * diameter)) {
                        op[1] += 1;
                        break;
                    }
                } else try dots.append(.{ p, 1 });
            }
        };

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

    pub fn handleCircleCollisions(self: *Self) void {
        const delta = rl.GetFrameTime();
        const Q = enum { pos, vel, phys };

        const util = enum {
            pub fn mass(size: f32) f32 {
                return size * size * std.math.pi;
            }
        };

        inline for (self.world.slct(Q)) |s| for (s) |*pb| {
            const pos = vec.asInt(pb.pos + pb.vel * vec.splat(0.5));
            const size: i32 = @intFromFloat(@TypeOf(pb.*).size * 2 + vec.len(pb.vel));
            const bb = .{ pos[0] - size, pos[1] - size, pos[0] + size, pos[1] + size };

            var query = self.quad.queryIter(bb, pb.phys.quad);
            while (query.next()) |qid| o: for (self.quad.entities(qid)) |rid| {
                const id: Id = @enumFromInt(rid);
                if (id == pb.id) continue;
                const opb = self.world.fields(id, Q) orelse continue;

                if (World.cnst(id, .team) == World.cnst(pb.id, .team) and
                    World.cnst(pb.id, .max_health) == 0 and
                    World.cnst(id, .max_health) == 0) continue;

                const g = @TypeOf(pb.*).size + World.cnst(id, .size);

                const dist = vec.dist2(pb.pos, opb.pos.*);
                if (g * g > dist) {
                    if (@TypeOf(pb.*).size > World.cnst(id, .size)) {
                        opb.pos.* = pb.pos + vec.norm(opb.pos.* - pb.pos) * vec.splat(g);
                    } else {
                        pb.pos = opb.pos.* + vec.norm(pb.pos - opb.pos.*) * vec.splat(g);
                    }
                }

                const d = opb.pos.* - pb.pos;
                const dv = opb.vel.* - pb.vel;

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
                    if (p.phys.coll_id != std.math.maxInt(u32))
                        if (self.collisions.items[p.phys.coll_id].t > t) {
                            self.collisions.items[p.phys.coll_id].t = delta;
                        } else continue :o;
                }

                pb.phys.coll_id = @intCast(self.collisions.items.len);
                opb.phys.coll_id = @intCast(self.collisions.items.len);

                self.collisions.append(.{ .a = pb.id, .b = id, .t = t }) catch unreachable;
            };
        };

        for (self.collisions.items) |col| {
            const pb = self.world.fields(col.a, Q).?;
            const opb = self.world.fields(col.b, Q).?;

            pb.phys.coll_id = std.math.maxInt(u32);
            opb.phys.coll_id = std.math.maxInt(u32);

            if (col.t == delta) continue;

            pb.pos.* += pb.vel.* * vec.splat(col.t);
            opb.pos.* += opb.vel.* * vec.splat(col.t);

            const dist = vec.dist(pb.pos.*, opb.pos.*);

            {
                const mass = util.mass(World.cnst(col.a, .size));
                const amass = util.mass(World.cnst(col.b, .size));

                const norm = (opb.pos.* - pb.pos.*) / vec.splat(dist);
                const p = 2 * (vec.dot(pb.vel.*, norm) - vec.dot(opb.vel.*, norm)) / (mass + amass);

                inline for (.{ pb, opb }, .{ -amass, mass }) |c, m| {
                    c.vel.* += vec.splat(p * m) * norm;
                    c.pos.* += c.vel.* * vec.splat(delta - col.t);
                    c.pos.* -= c.vel.* * vec.splat(delta);
                }
            }

            _ = self.world.invoke(col.a, .onCollision, .{ self, col.b });
            _ = self.world.invoke(col.b, .onCollision, .{ self, col.a });
        }
        self.collisions.items.len = 0;
    }

    pub fn timer(self: *Self, state: *u32, duration: u32) bool {
        if (state.* > self.time) return false;
        state.* = self.time + duration;
        return true;
    }

    pub fn timeRem(self: *Self, until: u32) ?u32 {
        return std.math.sub(u32, until, self.time) catch null;
    }
} {
    return .{
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .world = .{ .gpa = gpa },
        .to_delete = std.ArrayList(Id).init(gpa),
        .collisions = std.ArrayList(ColisionRec).init(gpa),
        .quad = Quad.init(gpa, Spec.world_size_pow) catch unreachable,
    };
}

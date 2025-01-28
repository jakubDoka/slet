pub const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
    @cInclude("rlgl.h");
});

pub fn main() !void {
    // const Ent = struct {
    //     id: @import("ecs2.zig").Id = undefined,
    // };
    // const World = @import("ecs2.zig").World(union(enum) {
    //     ent: Ent,
    // });

    // var w = World{ .gpa = @import("std").heap.page_allocator };

    // {
    //     const id = w.add(Ent{});
    //     @import("std").debug.assert(w.remove(id));
    //     @import("std").debug.assert(!w.remove(id));
    // }

    // const id = w.add(Ent{});
    // @import("std").debug.assert(w.ents.ent.items.len == 1);

    // inline for (w.slct(enum { id })) |s| for (s) |e| {
    //     @import("std").debug.print("{any}", .{e});
    // };

    // @import("std").debug.assert(w.fields(id, enum { id }).?.id.* == id);

    try @import("Game.zig").run();
}

pub inline fn tof(value: anytype) f32 {
    return @floatFromInt(value);
}

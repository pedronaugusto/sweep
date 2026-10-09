const Set = @import("sweep.glob").Set;
export fn reject() void {
    const options: Set.Cache.Options = .{ .capacity = Set.Index.fromRaw(1) };
    _ = options;
}

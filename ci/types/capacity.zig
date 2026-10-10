const Set = @import("sweep").Set;
export fn reject() void {
    const options: Set.Cache.Options = .{ .capacity = Set.Index.fromRaw(1) };
    _ = options;
}

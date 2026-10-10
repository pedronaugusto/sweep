const Set = @import("sweep").Set;
export fn reject() void {
    const index: Set.Index = Set.Count.fromRaw(1);
    _ = index;
}

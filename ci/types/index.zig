const Set = @import("sweep.glob").Set;
export fn reject() void {
    const index: Set.Index = Set.Count.fromRaw(1);
    _ = index;
}

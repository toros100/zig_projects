const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mod = b.addModule("nbt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // usage: zig build test -Dtest-filter=someTest -Dtest-filter=otherTest
    const filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests matching these names",
    ) orelse &.{};

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = filters,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    run_mod_tests.setCwd(b.path("."));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // to get build on save to work
    // https://zigtools.org/zls/guides/build-on-save/
    const check_tests = b.addTest(.{ .root_module = mod });
    const check = b.step("check", "Check if code compiles");
    check.dependOn(&check_tests.step);
    // i had this as check.dependOn(&mod_tests.step), which is a good trick to remember in case
    // you ever have too much free disk space
}

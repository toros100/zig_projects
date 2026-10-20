const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // usage: zig build test -Dtest-filter=someTest -Dtest-filter=otherTest
    const filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests matching these names",
    ) orelse &.{};

    const mod = b.addModule("nbt", .{
        .root_source_file = b.path("src/nbt.zig"),
        .target = target,
    });

    // module without safety checks to run tests and get check on save and tests for both branches
    // of mode-specific code
    const mod_fast = b.createModule(.{
        .root_source_file = b.path("src/nbt.zig"),
        .target = target,
        .optimize = .fast,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = filters,
    });

    const fast_tests = b.addTest(.{
        .root_module = mod_fast,
        .filters = filters,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_fast_tests = b.addRunArtifact(fast_tests);

    run_mod_tests.setCwd(b.path("."));
    run_fast_tests.setCwd(b.path("."));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const fast_test_step = b.step("test-fast", "Run tests without safety checks");
    fast_test_step.dependOn(&run_fast_tests.step);

    // to get build on save to work
    // https://zigtools.org/zls/guides/build-on-save/
    const check_tests = b.addTest(.{ .root_module = mod });
    const check_tests_fast = b.addTest(.{ .root_module = mod_fast });
    const check = b.step("check", "Check if code compiles");
    check.dependOn(&check_tests.step);
    check.dependOn(&check_tests_fast.step);
    // i had this as check.dependOn(&mod_tests.step), which is a good trick to remember in case
    // you ever have too much free disk space
}

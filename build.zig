const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_module = b.addModule("hushpin_core", .{
        .root_source_file = b.path("src/recording-core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core = b.addLibrary(.{ .name = "hushpin_core", .linkage = .static, .root_module = core_module });
    addMacCaptureBridge(core, b);
    b.installArtifact(core);

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/hushpin-main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "hushpin_core", .module = core_module }},
    });
    const cli = b.addExecutable(.{ .name = "hushpin", .root_module = cli_module });
    b.installArtifact(cli);
    const app_executable = b.addInstallFile(cli.getEmittedBin(), "Hushpin.app/Contents/MacOS/hushpin");
    const app_info = b.addInstallFile(b.path("Info.plist"), "Hushpin.app/Contents/Info.plist");
    const sign_app = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", b.getInstallPath(.prefix, "Hushpin.app") });
    sign_app.step.dependOn(&app_executable.step);
    sign_app.step.dependOn(&app_info.step);
    b.getInstallStep().dependOn(&sign_app.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/recording-core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_module });
    addMacCaptureBridge(tests, b);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Hushpin core tests");
    test_step.dependOn(&run_tests.step);
    const cli_tests = b.addTest(.{ .root_module = cli_module });
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);
}

fn addMacCaptureBridge(step: *std.Build.Step.Compile, b: *std.Build) void {
    step.root_module.addIncludePath(b.path("src"));
    step.root_module.addCSourceFile(.{ .file = b.path("src/mac-audio-capture.m"), .flags = &.{ "-fobjc-arc", "-fblocks" } });
    step.root_module.link_libc = true;
    step.root_module.linkFramework("Foundation", .{});
    step.root_module.linkFramework("AVFoundation", .{});
    step.root_module.linkFramework("ScreenCaptureKit", .{});
    step.root_module.linkFramework("CoreAudio", .{});
    step.root_module.linkFramework("CoreMedia", .{});
}

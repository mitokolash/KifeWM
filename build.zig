const std = @import("std");
const Build = std.Build;

const Scanner = @import("wayland").Scanner;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));

    scanner.generate("river_xkb_bindings_v1", 2);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_compositor", 6);
    scanner.generate("river_window_manager_v1", 1);

    const exe = b.addExecutable(.{
        .name = "kifewm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addImport("wayland", wayland);
    exe.root_module.linkSystemLibrary("wayland-client", .{});

    b.installArtifact(exe);

    const run_cmd = b.addSystemCommand(&.{ "river", "-c" });

    // run_cmd.setEnvironmentVariable("WAYLAND_DISPLAY", "wayland-1");
    run_cmd.addArtifactArg(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run River with this window manager as the controller");
    run_step.dependOn(&run_cmd.step);
}

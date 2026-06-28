const std = @import("std");
const Build = std.Build;

const Scanner = @import("wayland").Scanner;

pub fn build(zig: *Build) !void {
    const scanner = Scanner.create(zig, .{});
    const wayland = zig.createModule(.{ .root_source_file = scanner.result });

    scanner.addCustomProtocol(zig.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(zig.path("protocol/river-window-management-v1.xml"));

    scanner.generate("river_xkb_bindings_v1", 2);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_compositor", 6);
    scanner.generate("river_window_manager_v1", 1);

    const exe = zig.addExecutable(.{
        .name = "kifewm",
        .root_module = zig.createModule(.{
            .root_source_file = zig.path("src/main.zig"),
            .target = zig.standardTargetOptions(.{}),
            .optimize = zig.standardOptimizeOption(.{}),
            .link_libc = true,
        }),
    });

    exe.root_module.addImport("wayland", wayland);
    exe.root_module.linkSystemLibrary("wayland-client", .{});

    zig.installArtifact(exe);

    const run_cmd = zig.addSystemCommand(&.{ "river", "-c" });
    run_cmd.addArtifactArg(exe);
    run_cmd.step.dependOn(zig.getInstallStep());

    const run_step = zig.step("run", "Run River with this window manager as the controller");
    run_step.dependOn(&run_cmd.step);
}

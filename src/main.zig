const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

const Seat = @import("seat.zig").Seat;
const Binding = @import("seat.zig").Binding;
const Key = @import("seat.zig").Key;

pub const bindings = [_]Binding{
    .{
        .mods = .{
            .mod1 = true,
        },
        .key = Key.enter,
        .action = .spawn_terminal,
    },
    .{
        .mods = .{ .mod1 = true },
        .key = Key.char('w'),
        .action = .spawn_browser,
    },
};

const AppData = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Display,
    registry: *wl.Registry,

    river_wm: ?*river.WindowManagerV1 = null,
    river_bindings: ?*river.XkbBindingsV1 = null,

    wl_seat: ?*wl.Seat = null,

    wm: WindowManager,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !AppData {
        const display = try wl.Display.connect(null);
        errdefer display.disconnect();

        const registry = try wl.Display.getRegistry(display);
        errdefer registry.destroy();

        return AppData{
            .allocator = allocator,
            .io = io,
            .display = display,
            .registry = registry,
            .wm = WindowManager.init(),
        };
    }

    pub fn deinit(self: *AppData) void {
        if (self.river_wm) |wm| wm.destroy();
        if (self.river_bindings) |binds| binds.destroy();
        if (self.wl_seat) |s| s.destroy();

        self.wm.deinit(self.allocator);

        self.registry.destroy();
        self.display.disconnect();
    }

    pub fn registryCallback(registry: *wl.Registry, event: wl.Registry.Event, self: *AppData) void {
        _ = registry;

        switch (event) {
            .global => |global| {
                const interface_name = std.mem.span(global.interface);

                std.log.info("Global found: {s} (id: {}, v{})", .{ interface_name, global.name, global.version });

                const interfaces = .{
                    .{ river.WindowManagerV1, 1, &self.river_wm },
                    .{ river.XkbBindingsV1, 1, &self.river_bindings },
                    .{ wl.Seat, 9, &self.wl_seat },
                };

                inline for (interfaces) |interface| {
                    // Version = interface[1];
                    // Field pointer = interface[2];

                    // Don't waste memory!!!

                    const T = interface[0];

                    if (std.mem.eql(u8, interface_name, std.mem.span(T.interface.name))) {
                        interface[2].* = wl.Registry.bind(self.registry, global.name, T, interface[1]) catch |err| {
                            std.log.err("Failed to bind {s}: {}", .{ T.interface.name, err });
                            return;
                        };

                        if (comptime T == river.WindowManagerV1) T.setListener(self.river_wm.?, *AppData, &AppData.riverCallback, self);
                    }
                }
            },
            .global_remove => |global_remove| {
                _ = global_remove;
            },
        }
    }

    pub fn riverCallback(
        river_wm: *river.WindowManagerV1,
        event: river.WindowManagerV1.Event,
        self: *AppData,
    ) void {
        switch (event) {
            .manage_start => {
                std.log.info("River started a management cycle.", .{});

                const windows_len = self.wm.windows.items.len;
                if (windows_len > 0) {
                    const top_window = self.wm.windows.items[windows_len - 1];

                    top_window.id.proposeDimensions(1280, 720);
                    top_window.node.setPosition(0, 0);
                    top_window.node.placeTop();

                    if (self.wm.seats.items.len > 0) {
                        const active_seat = self.wm.seats.items[0];
                        active_seat.id.focusWindow(top_window.id);
                    }
                }

                river_wm.manageFinish();
            },

            .render_start => {
                river_wm.renderFinish();
            },

            .window => |w| {
                std.log.info("Window event received. Pointer address: {*}", .{w.id});

                const node = w.id.getNode() catch |err| {
                    std.log.err("Failed to get window node: {}", .{err});
                    return;
                };

                self.wm.windows.append(self.allocator, .{
                    .id = w.id,
                    .node = node,
                }) catch |err| {
                    std.log.err("Failed to add a new window to the list: {}", .{err});
                };
            },

            .seat => |s| {
                std.log.info("Seat event received. Pointer address: {*}", .{s.id});

                if (self.wl_seat == null or self.river_bindings == null) {
                    std.log.err("Cannot initialize seat: wl_seat or river_bindings is not seat!", .{});
                    return;
                }

                const new_seat = self.allocator.create(Seat) catch |err| {
                    std.log.err("Failed to allocate memory: {}", .{err});
                    return;
                };
                new_seat.* = Seat.init(self.allocator, self.io, s.id, self.wl_seat.?);

                inline for (bindings) |bind| {
                    new_seat.addKeyBinding(self.river_bindings.?, bind.key, bind.mods, bind.action) catch |err| {
                        std.log.err("Failed to add new binding ({s}) to seat: {}", .{ @tagName(bind.action), err });
                    };
                }

                const wl_pointer = wl.Seat.getPointer(self.wl_seat.?) catch |err| {
                    std.log.err("Failed to get wl_pointer from seat: {}", .{err});
                    return;
                };

                wl.Pointer.setListener(wl_pointer, *Seat, &Seat.pointerCallback, new_seat);

                self.wm.seats.append(self.allocator, new_seat) catch |err| {
                    std.log.err("Failed to add a new seat to the list: {}", .{err});
                };
            },

            .output => |o| {
                std.log.info("Output event received! Pointer address: {*}", .{o.id});
                self.wm.outputs.append(self.allocator, .{ .id = o.id }) catch {};
            },

            .finished => {},
            .session_locked => std.log.info("Session locked. I think no one will see your pc now.", .{}),
            .session_unlocked => std.log.info("Session unlocked. Be careful. There are spies everywhere.", .{}),
            .unavailable => std.log.info("River window manager interface became unavailable! FIX NOW!!!", .{}),
        }
    }
};

const Window = struct {
    id: *river.WindowV1,
    node: *river.NodeV1,
    width: i32 = 0,
    height: i32 = 0,
    focused: bool = true,
};
const Output = struct { id: *river.OutputV1 };

const WindowManager = struct {
    windows: std.ArrayList(Window),
    outputs: std.ArrayList(Output),
    seats: std.ArrayList(*Seat),

    pub fn init() WindowManager {
        return .{
            .windows = std.ArrayList(Window).empty,
            .outputs = std.ArrayList(Output).empty,
            .seats = std.ArrayList(*Seat).empty,
        };
    }

    pub fn deinit(self: *WindowManager, allocator: std.mem.Allocator) void {
        self.windows.deinit(allocator);
        self.outputs.deinit(allocator);
        for (self.seats.items) |*seat| {
            seat.*.deinit();
        }
        self.seats.deinit(allocator);
    }
};

pub fn main(init: std.process.Init) !void {
    var app = try AppData.init(init.gpa, init.io);
    defer app.deinit();

    std.log.info("Connected to Wayland!", .{});

    wl.Registry.setListener(app.registry, *AppData, &AppData.registryCallback, &app);

    std.log.info("Starting kifewm event loop...", .{});
    while (true) {
        while (app.display.flush() == .AGAIN) {}

        const dispatch_res = app.display.dispatch();
        if (dispatch_res != .SUCCESS) {
            std.log.err("Wayland dispatch error: {}", .{dispatch_res});
            break;
        }
    }
}

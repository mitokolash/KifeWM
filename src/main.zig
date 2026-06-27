const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

const bindings = .{
    .{ river.SeatV1.Modifiers{ .mod1 = true }, Key.enter, .spawn_terminal },
    .{ river.SeatV1.Modifiers{ .mod1 = true }, Key.char('w'), .spawn_browser },
};

const Action = enum {
    spawn_terminal,
    spawn_browser,
    close_window,
    focus_window,
};

const PointerButtons = struct {
    pub const left = 272;
    pub const right = 273;
    pub const middle = 274;
};

const Key = struct {
    pub const enter = 0xff0d;
    pub const escape = 0xff1b;
    pub const backspace = 0xff08;
    pub const tab = 0xff09;

    pub const left = 0xff51;
    pub const up = 0xff52;
    pub const right = 0xff53;
    pub const down = 0xff54;

    inline fn char(comptime c: u8) u32 {
        return @as(u32, c);
    }
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
                    new_seat.addKeyBinding(self.river_bindings.?, bind[1], bind[0], bind[2]) catch |err| {
                        std.log.err("Failed to add new binding ({s}) to seat: {}", .{ @tagName(bind[2]), err });
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

const KeyBinding = struct {
    proxy: *river.XkbBindingV1,
    action: Action,
};

const Seat = struct {
    id: *river.SeatV1,
    wl_id: *wl.Seat,
    key_bindings: std.ArrayList(KeyBinding),
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, id: *river.SeatV1, wl_id: *wl.Seat) Seat {
        return .{
            .id = id,
            .wl_id = wl_id,
            .key_bindings = std.ArrayList(KeyBinding).empty,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *Seat) void {
        for (self.key_bindings.items) |bind| {
            bind.proxy.destroy();
        }

        self.key_bindings.deinit(self.allocator);
    }

    pub fn addKeyBinding(
        self: *Seat,
        river_bindings: *river.XkbBindingsV1,
        keysym: u32,
        mods: river.SeatV1.Modifiers,
        action: Action,
    ) !void {
        const binding_proxy = try river.XkbBindingsV1.getXkbBinding(river_bindings, self.id, keysym, mods);
        errdefer binding_proxy.destroy();

        try self.key_bindings.append(self.allocator, .{
            .proxy = binding_proxy,
            .action = action,
        });

        river.XkbBindingV1.setListener(binding_proxy, *Seat, &Seat.keyCallback, self);
        binding_proxy.enable();
    }

    fn keyCallback(binding: *river.XkbBindingV1, event: river.XkbBindingV1.Event, self: *Seat) void {
        switch (event) {
            .pressed => {
                for (self.key_bindings.items) |kb| {
                    if (kb.proxy == binding) {
                        self.executeAction(kb.action);
                        break;
                    }
                }
            },
            else => {},
        }
    }

    fn pointerCallback(
        pointer: *wl.Pointer,
        event: wl.Pointer.Event,
        self: *Seat,
    ) void {
        _ = pointer;
        _ = self;
        switch (event) {
            .enter => |e| {
                std.log.info("Mouse entered surface: {*}", .{e.surface});
                //TODO: Focus window;
            },
            .button => |b| {
                if (b.button == 272 and b.state == .pressed) {
                    std.log.info("Mouse left button pressed.", .{});
                }
            },
            else => {},
        }
    }

    inline fn spawnProcess(io: std.Io, comptime argv: []const []const u8) !void {
        _ = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            std.log.err("Could not initialize the process {s}: {}", .{ argv[0], err });
            return err;
        };
    }

    fn executeAction(self: *Seat, action: Action) void {
        switch (action) {
            .spawn_terminal => {
                std.log.info("Launching kitty terminal.", .{});
                spawnProcess(self.io, &.{"kitty"}) catch return;
            },
            .spawn_browser => {
                std.log.info("Launching Zen Browser.", .{});
                spawnProcess(self.io, &.{"zen"}) catch return;
            },
            .close_window => {
                std.log.info("Logic is not defined yet. Sorry, but you have 32 gb of ram anyways.", .{});
            },
            .focus_window => {
                std.log.info("Suffer.", .{});
            },
        }
    }
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

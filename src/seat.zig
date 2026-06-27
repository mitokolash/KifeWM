const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

pub const Binding = struct {
    mods: river.SeatV1.Modifiers,
    key: u32,
    action: Action,
};

const Action = enum {
    spawn_terminal,
    spawn_browser,
    close_window,
    focus_window,
};

const Xkb = struct {
    proxy: *river.XkbBindingV1,
    action: Action,
};

pub const Key = struct {
    pub const enter = 0xff0d;
    pub const escape = 0xff1b;
    pub const backspace = 0xff08;
    pub const tab = 0xff09;

    pub const left = 0xff51;
    pub const up = 0xff52;
    pub const right = 0xff53;
    pub const down = 0xff54;

    pub inline fn char(comptime c: u8) u32 {
        return @as(u32, std.ascii.toLower(c));
    }
};

const PointerButtons = struct {
    pub const left = 272;
    pub const right = 273;
    pub const middle = 274;
};

pub const Seat = struct {
    id: *river.SeatV1,
    wl_id: *wl.Seat,
    key_bindings: std.ArrayList(Xkb),
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, id: *river.SeatV1, wl_id: *wl.Seat) Seat {
        return .{
            .id = id,
            .wl_id = wl_id,
            .key_bindings = std.ArrayList(Xkb).empty,
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

    pub fn pointerCallback(
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

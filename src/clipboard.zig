const std = @import("std");
const fs = std.fs;
const daemon = @import("daemon.zig");
// All c imports MUST be placed here
pub const c = @cImport({
    @cInclude("dlfcn.h");
    @cInclude("signal.h");
    @cInclude("poll.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/extensions/Xfixes.h");
    @cDefine("XFIXES", "1");
});

const Display = opaque {};
const OpenDisplayFn = *const fn (?[*:0]const u8) callconv(.C) ?*c.Display;

pub const ClipboardContext = struct {
    display: ?*c.Display,
    window: c.Window,
    xopen: OpenDisplayFn,
    xclose: *const fn (*c.Display) callconv(.C) void,

    pub fn init() !ClipboardContext {
        const lib = c.dlopen("libX11.so.6", c.RTLD_LAZY);
        if (lib == null) return error.LibraryNotFound;
        const open_sym = c.dlsym(lib, "XOpenDisplay");
        const close_sym = c.dlsym(lib, "XCloseDisplay");
        if (open_sym == null or close_sym == null) return error.SymbolNotFound;
        const xopen = @as(OpenDisplayFn, @ptrCast(open_sym));
        const xclose = @as(*const fn (*c.Display) callconv(.C) void, @ptrCast(close_sym));
        const display = xopen(null);
        if (display == null) return error.FailedToOpenDisplay;
        const screen = c.XDefaultScreen(display);
        const window = c.XCreateSimpleWindow(display, c.XRootWindow(display, screen), 0, 0, 1, 1, 0, 0, 0);
        return ClipboardContext{
            .display = display,
            .window = window,
            .xopen = xopen,
            .xclose = xclose,
        };
    }

    pub fn deinit(self: *ClipboardContext) void {
        self.xclose(self.display.?);
    }

    pub fn captureClipboard(self: *ClipboardContext, allocator: *const std.mem.Allocator) ![]const u8 {
        const display = self.display;
        const clipboard = c.XInternAtom(display, "CLIPBOARD", 0);
        const utf8 = c.XInternAtom(display, "UTF8_STRING", 0);
        const property = c.XInternAtom(display, "ZCLIP_PROP", 0);
        _ = c.XConvertSelection(display, clipboard, utf8, property, self.window, c.CurrentTime);
        _ = c.XFlush(display);
        var event: c.XEvent = undefined;
        while (true) {
            _ = c.XNextEvent(display, &event);
            if (event.type == c.SelectionNotify) break;
        }
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: ?*c.u_char = null;
        const status = c.XGetWindowProperty(
            self.display,
            self.window,
            property,
            0, // offset
            1024, // long length
            0, // delete = False
            c.AnyPropertyType, // expected type
            &actual_type,
            &actual_format,
            &nitems,
            &bytes_after,
            &prop,
        );
        if (status != c.Success or prop == null) {
            return error.ClipboardReadFailed;
        }
        const len = @as(usize, @intCast(nitems));
        const slice = @as([*]u8, @ptrCast(prop.?))[0..len];
        // Make a copy into Zig-managed memory
        const temp = try allocator.alloc(u8, slice.len);
        std.mem.copyForwards(u8, temp, slice);
        const copied = std.mem.trimEnd(u8, temp, "\n");
        // Free the X11-allocated memory
        _ = c.XFree(prop);
        return copied;
    }

    pub fn setClipboard(self: *ClipboardContext, text: []const u8) !void {
        const display = self.display orelse return error.FailedToOpenDisplay;
        const screen = c.XDefaultScreen(display);
        const window = c.XCreateSimpleWindow(display, c.XRootWindow(display, screen), 0, 0, 1, 1, 0, 0, 0);
        defer _ = c.XDestroyWindow(display, window);
        const clipboard = c.XInternAtom(display, "CLIPBOARD", 0);
        const utf8 = c.XInternAtom(display, "UTF8_STRING", 0);
        const targets = c.XInternAtom(display, "TARGETS", 0);
        _ = c.XInternAtom(display, "INCR", 0); 
        _ = c.XSetSelectionOwner(display, clipboard, window, c.CurrentTime);
        _ = c.XFlush(display);
        if (c.XGetSelectionOwner(display, clipboard) != window) {
            return error.FailedToTakeClipboard;
        }
        // Store your data locally so you can respond to SelectionRequests
        const text_copy = try std.heap.page_allocator.dupe(u8, text);
        _ = c.XInternAtom(display, "ZCLIP_TEMP_PROP", 0); // prop_name
        var event: c.XEvent = undefined;
        var got_request = false;
        const max_wait_ns = std.time.ns_per_s * 5;
        const post_request_delay_ns = std.time.ns_per_ms * 100;
        var start_time = try std.time.Instant.now();
        while (true) {
            if (c.XPending(display) == 0) {
                const now = try std.time.Instant.now();
                if (!got_request and now.since(start_time) > max_wait_ns) {
                    std.debug.print("Timeout: no SelectionRequest received.\n", .{});
                    break;
                }
                if (got_request and now.since(start_time) > post_request_delay_ns) {
                    std.debug.print("Exiting after serving SelectionRequest.\n", .{});
                    break;
                }
                std.time.sleep(std.time.ns_per_ms * 10);
                continue;
            }
            _ = c.XNextEvent(display, &event);
            if (event.type == c.SelectionRequest) {
                got_request = true;
                start_time = try std.time.Instant.now(); // reset to measure post-request delay
                const sel_req = event.xselectionrequest;
                var response: c.XSelectionEvent = .{
                    .type = c.SelectionNotify,
                    .serial = sel_req.serial,
                    .send_event = 1,
                    .display = sel_req.display,
                    .requestor = sel_req.requestor,
                    .selection = sel_req.selection,
                    .target = sel_req.target,
                    .property = sel_req.property,
                    .time = sel_req.time,
                };
                if (sel_req.target == targets) {
                    const supported: [2]c.Atom = .{ utf8, targets };
                    _ = c.XChangeProperty(
                        display,
                        sel_req.requestor,
                        sel_req.property,
                        c.XA_ATOM,
                        32,
                        c.PropModeReplace,
                        @ptrCast(&supported),
                        supported.len,
                    );
                }
                else if (sel_req.target == utf8) {
                    _ = c.XChangeProperty(
                        display,
                        sel_req.requestor,
                        sel_req.property,
                        utf8,
                        8,
                        c.PropModeReplace,
                        @ptrCast(text_copy.ptr),
                        @intCast(text_copy.len),
                    );
                }
                else {
                    response.property = 0; // unsupported target
                }
                _ = c.XSendEvent(display, sel_req.requestor, 0, 0, @ptrCast(&response));
                _ = c.XFlush(display);
            }
        }
    }
};


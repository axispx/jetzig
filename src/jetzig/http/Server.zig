const std = @import("std");

const jetzig = @import("../../jetzig.zig");
const zmpl = @import("zmpl");

pub const ServerOptions = struct {
    logger: jetzig.loggers.Logger,
    bind: []const u8,
    port: u16,
    secret: []const u8,
    detach: bool,
};

allocator: std.mem.Allocator,
logger: jetzig.loggers.Logger,
options: ServerOptions,
routes: []*jetzig.views.Route,
mime_map: *jetzig.http.mime.MimeMap,
std_net_server: std.net.Server = undefined,
initialized: bool = false,

const Self = @This();

pub fn init(
    allocator: std.mem.Allocator,
    options: ServerOptions,
    routes: []*jetzig.views.Route,
    mime_map: *jetzig.http.mime.MimeMap,
) Self {
    return .{
        .allocator = allocator,
        .logger = options.logger,
        .options = options,
        .routes = routes,
        .mime_map = mime_map,
    };
}

pub fn deinit(self: *Self) void {
    if (self.initialized) self.std_net_server.deinit();
    self.allocator.free(self.options.secret);
    self.allocator.free(self.options.bind);
}

pub fn listen(self: *Self) !void {
    const address = try std.net.Address.parseIp(self.options.bind, self.options.port);
    self.std_net_server = try address.listen(.{ .reuse_port = true });

    self.initialized = true;

    try self.logger.INFO("Listening on http://{s}:{}", .{ self.options.bind, self.options.port });
    try self.processRequests();
}

fn processRequests(self: *Self) !void {
    // TODO: Keepalive
    while (true) {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        const connection = try self.std_net_server.accept();

        var buf: [jetzig.config.get(usize, "http_buffer_size")]u8 = undefined;
        var std_http_server = std.http.Server.init(connection, &buf);
        errdefer std_http_server.connection.stream.close();

        self.processNextRequest(allocator, &std_http_server) catch |err| {
            if (isBadHttpError(err)) {
                std_http_server.connection.stream.close();
                continue;
            } else return err;
        };

        std_http_server.connection.stream.close();
        arena.deinit();
    }
}

fn processNextRequest(self: *Self, allocator: std.mem.Allocator, std_http_server: *std.http.Server) !void {
    const start_time = std.time.nanoTimestamp();

    const std_http_request = try std_http_server.receiveHead();
    if (std_http_server.state == .receiving_head) return error.JetzigParseHeadError;

    var response = try jetzig.http.Response.init(allocator);
    var request = try jetzig.http.Request.init(allocator, self, start_time, std_http_request, &response);

    try request.process();

    var middleware_data = try jetzig.http.middleware.afterRequest(&request);

    try self.renderResponse(&request);
    try request.response.headers.append("content-type", response.content_type);

    try jetzig.http.middleware.beforeResponse(&middleware_data, &request);

    try request.respond();

    try jetzig.http.middleware.afterResponse(&middleware_data, &request);
    jetzig.http.middleware.deinit(&middleware_data, &request);

    try self.logger.logRequest(&request);
}

fn renderResponse(self: *Self, request: *jetzig.http.Request) !void {
    const static_resource = self.matchStaticResource(request) catch |err| {
        if (isUnhandledError(err)) return err;

        const rendered = try self.renderInternalServerError(request, err);

        request.response.content = rendered.content;
        request.response.status_code = rendered.view.status_code;
        request.response.content_type = "text/html";

        return;
    };

    if (static_resource) |resource| {
        try renderStatic(resource, request.response);
        return;
    }

    const route = try self.matchRoute(request, false);

    switch (request.requestFormat()) {
        .HTML => try self.renderHTML(request, route),
        .JSON => try self.renderJSON(request, route),
        .UNKNOWN => try self.renderHTML(request, route),
    }
}

fn renderStatic(resource: StaticResource, response: *jetzig.http.Response) !void {
    response.status_code = .ok;
    response.content = resource.content;
    response.content_type = resource.mime_type;
}

fn renderHTML(
    self: *Self,
    request: *jetzig.http.Request,
    route: ?*jetzig.views.Route,
) !void {
    if (route) |matched_route| {
        if (zmpl.find(matched_route.template)) |template| {
            const rendered = self.renderView(matched_route, request, template) catch |err| {
                if (isUnhandledError(err)) return err;
                const rendered_error = try self.renderInternalServerError(request, err);
                request.response.content = rendered_error.content;
                request.response.status_code = rendered_error.view.status_code;
                request.response.content_type = "text/html";
                return;
            };
            request.response.content = rendered.content;
            request.response.status_code = rendered.view.status_code;
            request.response.content_type = "text/html";
            return;
        }
    }

    request.response.content = "";
    request.response.status_code = .not_found;
    request.response.content_type = "text/html";
}

fn renderJSON(
    self: *Self,
    request: *jetzig.http.Request,
    route: ?*jetzig.views.Route,
) !void {
    if (route) |matched_route| {
        const rendered = try self.renderView(matched_route, request, null);
        var data = rendered.view.data;

        if (data.value) |_| {} else _ = try data.object();
        try request.headers.append("Content-Type", "application/json");

        request.response.content = try data.toJson();
        request.response.status_code = rendered.view.status_code;
        request.response.content_type = "application/json";
    } else {
        request.response.content = "";
        request.response.status_code = .not_found;
        request.response.content_type = "application/json";
    }
}

const RenderedView = struct { view: jetzig.views.View, content: []const u8 };

fn renderView(
    self: *Self,
    route: *jetzig.views.Route,
    request: *jetzig.http.Request,
    template: ?zmpl.manifest.Template,
) !RenderedView {
    // View functions return a `View` to help encourage users to return from a view function with
    // `return request.render(.ok)`, but the actual rendered view is stored in
    // `request.rendered_view`.
    _ = route.render(route.*, request) catch |err| {
        try self.logger.ERROR("Encountered error: {s}", .{@errorName(err)});
        if (isUnhandledError(err)) return err;
        if (isBadRequest(err)) return try self.renderBadRequest(request);
        return try self.renderInternalServerError(request, err);
    };

    if (request.rendered_multiple) return error.JetzigMultipleRenderError;

    if (request.rendered_view) |rendered_view| {
        if (request.redirected) return .{ .view = rendered_view, .content = "" };

        if (template) |capture| {
            return .{
                .view = rendered_view,
                .content = try self.renderTemplateWithLayout(request, capture, rendered_view, route),
            };
        } else {
            // We are rendering JSON, content is the result of `toJson` on view data.
            return .{ .view = rendered_view, .content = "" };
        }
    } else {
        try self.logger.WARN("`request.render` was not invoked. Rendering empty content.", .{});
        request.response_data.reset();
        return .{
            .view = .{ .data = request.response_data, .status_code = .no_content },
            .content = "",
        };
    }
}

fn renderTemplateWithLayout(
    self: *Self,
    request: *jetzig.http.Request,
    template: zmpl.manifest.Template,
    view: jetzig.views.View,
    route: *jetzig.views.Route,
) ![]const u8 {
    try view.data.addConst("jetzig_view", view.data.string(route.view_name));
    try view.data.addConst("jetzig_action", view.data.string(@tagName(route.action)));

    if (request.getLayout(route)) |layout_name| {
        // TODO: Allow user to configure layouts directory other than src/app/views/layouts/
        const prefixed_name = try std.mem.concat(self.allocator, u8, &[_][]const u8{ "layouts_", layout_name });
        defer self.allocator.free(prefixed_name);

        if (zmpl.manifest.find(prefixed_name)) |layout| {
            return try template.renderWithLayout(layout, view.data);
        } else {
            try self.logger.WARN("Unknown layout: {s}", .{layout_name});
            return try template.render(view.data);
        }
    } else return try template.render(view.data);
}

fn isBadRequest(err: anyerror) bool {
    return switch (err) {
        error.JetzigBodyParseError, error.JetzigQueryParseError => true,
        else => false,
    };
}

fn isUnhandledError(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory => true,
        else => false,
    };
}

fn isBadHttpError(err: anyerror) bool {
    return switch (err) {
        error.JetzigParseHeadError,
        error.UnknownHttpMethod,
        error.HttpHeadersInvalid,
        error.HttpHeaderContinuationsUnsupported,
        error.HttpTransferEncodingUnsupported,
        error.HttpConnectionHeaderUnsupported,
        error.InvalidContentLength,
        error.CompressionUnsupported,
        error.MissingFinalNewline,
        error.HttpConnectionClosing,
        error.ConnectionResetByPeer,
        => true,
        else => false,
    };
}

fn renderInternalServerError(self: *Self, request: *jetzig.http.Request, err: anyerror) !RenderedView {
    request.response_data.reset();

    var object = try request.response_data.object();
    try object.put("error", request.response_data.string(@errorName(err)));

    const stack = @errorReturnTrace();
    if (stack) |capture| try self.logStackTrace(capture, request);

    return .{
        .view = jetzig.views.View{ .data = request.response_data, .status_code = .internal_server_error },
        .content = "Internal Server Error\n",
    };
}

fn renderBadRequest(self: *Self, request: *jetzig.http.Request) !RenderedView {
    _ = self;
    request.response_data.reset();

    var object = try request.response_data.object();
    try object.put("error", request.response_data.string("Bad Request"));

    return .{
        .view = jetzig.views.View{ .data = request.response_data, .status_code = .bad_request },
        .content = "Bad Request\n",
    };
}

fn logStackTrace(
    self: *Self,
    stack: *std.builtin.StackTrace,
    request: *jetzig.http.Request,
) !void {
    try self.logger.ERROR("\nStack Trace:\n{}", .{stack});
    var buf = std.ArrayList(u8).init(request.allocator);
    defer buf.deinit();
    const writer = buf.writer();
    try stack.format("", .{}, writer);
    try self.logger.ERROR("{s}\n", .{buf.items});
}

fn matchRoute(self: *Self, request: *jetzig.http.Request, static: bool) !?*jetzig.views.Route {
    for (self.routes) |route| {
        // .index routes always take precedence.
        if (route.static == static and route.action == .index and try request.match(route.*)) return route;
    }

    for (self.routes) |route| {
        if (route.static == static and try request.match(route.*)) return route;
    }

    return null;
}

const StaticResource = struct { content: []const u8, mime_type: []const u8 = "application/octet-stream" };

fn matchStaticResource(self: *Self, request: *jetzig.http.Request) !?StaticResource {
    // TODO: Map public and static routes at launch to avoid accessing the file system when
    // matching any route - currently every request causes file system traversal.
    const public_resource = try self.matchPublicContent(request);
    if (public_resource) |resource| return resource;

    const static_content = try self.matchStaticContent(request);
    if (static_content) |content| return .{
        .content = content,
        .mime_type = switch (request.requestFormat()) {
            .HTML, .UNKNOWN => "text/html",
            .JSON => "application/json",
        },
    };

    return null;
}

fn matchPublicContent(self: *Self, request: *jetzig.http.Request) !?StaticResource {
    if (request.path.file_path.len <= 1) return null;
    if (request.method != .GET) return null;

    var iterable_dir = std.fs.cwd().openDir(
        jetzig.config.get([]const u8, "public_content_path"),
        .{ .iterate = true, .no_follow = true },
    ) catch |err| {
        switch (err) {
            error.FileNotFound => return null,
            else => return err,
        }
    };
    defer iterable_dir.close();

    var walker = try iterable_dir.walk(request.allocator);
    defer walker.deinit();

    while (try walker.next()) |file| {
        if (file.kind != .file) continue;

        if (std.mem.eql(u8, file.path, request.path.file_path[1..])) {
            const content = try iterable_dir.readFileAlloc(
                request.allocator,
                file.path,
                jetzig.config.get(usize, "max_bytes_public_content"),
            );
            const extension = std.fs.path.extension(file.path);
            const mime_type = if (self.mime_map.get(extension)) |mime| mime else "application/octet-stream";
            return .{
                .content = content,
                .mime_type = mime_type,
            };
        }
    }

    return null;
}

fn matchStaticContent(self: *Self, request: *jetzig.http.Request) !?[]const u8 {
    var static_dir = std.fs.cwd().openDir("static", .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return null,
            else => return err,
        }
    };
    defer static_dir.close();

    const matched_route = try self.matchRoute(request, true);

    if (matched_route) |route| {
        const static_path = try staticPath(request, route.*);

        if (static_path) |capture| {
            return static_dir.readFileAlloc(
                request.allocator,
                capture,
                jetzig.config.get(usize, "max_bytes_static_content"),
            ) catch |err| {
                switch (err) {
                    error.FileNotFound => return null,
                    else => return err,
                }
            };
        } else return null;
    }

    return null;
}

fn staticPath(request: *jetzig.http.Request, route: jetzig.views.Route) !?[]const u8 {
    const params = try request.params();
    defer params.deinit();

    const extension = switch (request.requestFormat()) {
        .HTML, .UNKNOWN => ".html",
        .JSON => ".json",
    };

    for (route.params.items, 0..) |static_params, index| {
        if (try static_params.getValue("params")) |expected_params| {
            switch (route.action) {
                .index, .post => {},
                inline else => {
                    if (try static_params.getValue("id")) |id| {
                        switch (id.*) {
                            .string => |capture| {
                                if (!std.mem.eql(u8, capture.value, request.path.resource_id)) continue;
                            },
                            // Should be unreachable - this means generated `routes.zig` is incoherent:
                            inline else => return error.JetzigRouteError,
                        }
                    }
                },
            }
            if (!expected_params.eql(params)) continue;

            const index_fmt = try std.fmt.allocPrint(request.allocator, "{}", .{index});
            defer request.allocator.free(index_fmt);

            return try std.mem.concat(
                request.allocator,
                u8,
                &[_][]const u8{ route.name, "_", index_fmt, extension },
            );
        }
    }

    switch (route.action) {
        .index, .post => return try std.mem.concat(
            request.allocator,
            u8,
            &[_][]const u8{ route.name, extension },
        ),
        else => return null,
    }
}

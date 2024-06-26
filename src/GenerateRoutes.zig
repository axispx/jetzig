const std = @import("std");
const jetzig = @import("jetzig.zig");

ast: std.zig.Ast = undefined,
allocator: std.mem.Allocator,
views_path: []const u8,
buffer: std.ArrayList(u8),
dynamic_routes: std.ArrayList(Function),
static_routes: std.ArrayList(Function),
data: *jetzig.data.Data,

const Self = @This();

const Function = struct {
    name: []const u8,
    view_name: []const u8,
    args: []Arg,
    path: []const u8,
    source: []const u8,
    params: std.ArrayList([]const u8),

    /// The full name of a route. This **must** match the naming convention used by static route
    /// compilation.
    /// path: `src/app/views/iguanas.zig`, action: `index` => `iguanas_index`
    pub fn fullName(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
        // XXX: Currently we do not support nested routes, so we will need to adjust this if we
        // add nested routes in future.
        const extension = std.fs.path.extension(self.path);
        const basename = std.fs.path.basename(self.path);
        const name = basename[0 .. basename.len - extension.len];

        return std.mem.concat(allocator, u8, &[_][]const u8{ name, "_", self.name });
    }

    /// The path used to match the route. Resource ID and extension is not included here and is
    /// appended as needed during matching logic at run time.
    pub fn uriPath(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
        const basename = std.fs.path.basename(self.path);
        const name = basename[0 .. basename.len - std.fs.path.extension(basename).len];
        if (std.mem.eql(u8, name, "root")) return try allocator.dupe(u8, "/");

        return try std.mem.concat(allocator, u8, &[_][]const u8{ "/", name });
    }

    pub fn lessThanFn(context: void, lhs: @This(), rhs: @This()) bool {
        _ = context;
        return std.mem.order(u8, lhs.name, rhs.name).compare(std.math.CompareOperator.lt);
    }
};

// An argument passed to a view function.
const Arg = struct {
    name: []const u8,
    type_name: []const u8,

    pub fn typeBasename(self: @This()) ![]const u8 {
        if (std.mem.indexOfScalar(u8, self.type_name, '.')) |_| {
            var it = std.mem.splitBackwardsScalar(u8, self.type_name, '.');
            while (it.next()) |capture| {
                return capture;
            }
        }

        const pointer_start = std.mem.indexOfScalar(u8, self.type_name, '*');
        if (pointer_start) |index| {
            if (self.type_name.len < index + 1) return error.JetzigAstParserError;
            return self.type_name[index + 1 ..];
        } else {
            return self.type_name;
        }
    }
};

pub fn init(allocator: std.mem.Allocator, views_path: []const u8) !Self {
    const data = try allocator.create(jetzig.data.Data);
    data.* = jetzig.data.Data.init(allocator);

    return .{
        .allocator = allocator,
        .views_path = views_path,
        .buffer = std.ArrayList(u8).init(allocator),
        .static_routes = std.ArrayList(Function).init(allocator),
        .dynamic_routes = std.ArrayList(Function).init(allocator),
        .data = data,
    };
}

pub fn deinit(self: *Self) void {
    self.ast.deinit(self.allocator);
    self.buffer.deinit();
    self.static_routes.deinit();
    self.dynamic_routes.deinit();
}

/// Generates the complete route set for the application
pub fn generateRoutes(self: *Self) !void {
    const writer = self.buffer.writer();

    var views_dir = try std.fs.cwd().openDir(self.views_path, .{ .iterate = true });
    defer views_dir.close();

    var walker = try views_dir.walk(self.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const extension = std.fs.path.extension(entry.path);

        if (!std.mem.eql(u8, extension, ".zig")) continue;

        const view_routes = try self.generateRoutesForView(views_dir, entry.path);

        for (view_routes.static) |view_route| {
            try self.static_routes.append(view_route);
        }

        for (view_routes.dynamic) |view_route| {
            try self.dynamic_routes.append(view_route);
        }
    }

    std.sort.pdq(Function, self.static_routes.items, {}, Function.lessThanFn);
    std.sort.pdq(Function, self.dynamic_routes.items, {}, Function.lessThanFn);

    try writer.writeAll(
        \\pub const routes = struct {
        \\    pub const static = .{
        \\
    );

    for (self.static_routes.items) |static_route| {
        try self.writeRoute(writer, static_route);
    }

    try writer.writeAll(
        \\    };
        \\
        \\    pub const dynamic = .{
        \\
    );

    for (self.dynamic_routes.items) |dynamic_route| {
        try self.writeRoute(writer, dynamic_route);
        const name = try dynamic_route.fullName(self.allocator);
        defer self.allocator.free(name);
        std.debug.print("[jetzig] Imported route: {s}\n", .{name});
    }

    try writer.writeAll("    };\n");
    try writer.writeAll("};");

    // std.debug.print("routes.zig\n{s}\n", .{self.buffer.items});
}

fn writeRoute(self: *Self, writer: std.ArrayList(u8).Writer, route: Function) !void {
    const full_name = try route.fullName(self.allocator);
    defer self.allocator.free(full_name);

    const uri_path = try route.uriPath(self.allocator);
    defer self.allocator.free(uri_path);

    const output_template =
        \\        .{{
        \\            .name = "{s}",
        \\            .action = "{s}",
        \\            .view_name = "{s}",
        \\            .uri_path = "{s}",
        \\            .template = "{s}",
        \\            .module = @import("{s}"),
        \\            .function = @import("{s}").{s},
        \\            .params = {s},
        \\        }},
        \\
    ;

    var params_buf = std.ArrayList(u8).init(self.allocator);
    const params_writer = params_buf.writer();
    defer params_buf.deinit();
    if (route.params.items.len > 0) {
        try params_writer.writeAll(".{\n");
        for (route.params.items) |item| {
            try params_writer.writeAll("                ");
            try params_writer.writeAll(item);
            try params_writer.writeAll(",\n");
        }
        try params_writer.writeAll("            }");
    } else {
        try params_writer.writeAll(".{}");
    }

    const module_path = try self.allocator.dupe(u8, route.path);
    defer self.allocator.free(module_path);

    const view_name = try self.allocator.dupe(u8, route.view_name);
    defer self.allocator.free(view_name);

    std.mem.replaceScalar(u8, module_path, '\\', '/');

    const output = try std.fmt.allocPrint(self.allocator, output_template, .{
        full_name,
        route.name,
        route.view_name,
        uri_path,
        full_name,
        module_path,
        module_path,
        route.name,
        params_buf.items,
    });

    defer self.allocator.free(output);
    try writer.writeAll(output);
}

const RouteSet = struct {
    dynamic: []Function,
    static: []Function,
};

fn generateRoutesForView(self: *Self, views_dir: std.fs.Dir, path: []const u8) !RouteSet {
    const stat = try views_dir.statFile(path);
    const source = try views_dir.readFileAllocOptions(self.allocator, path, stat.size, null, @alignOf(u8), 0);
    defer self.allocator.free(source);

    self.ast = try std.zig.Ast.parse(self.allocator, source, .zig);

    var static_routes = std.ArrayList(Function).init(self.allocator);
    var dynamic_routes = std.ArrayList(Function).init(self.allocator);
    var static_params: ?*jetzig.data.Value = null;

    for (self.ast.nodes.items(.tag), 0..) |tag, index| {
        switch (tag) {
            .fn_proto_multi => {
                const function = try self.parseFunction(index, path, source);
                if (function) |capture| {
                    for (capture.args) |arg| {
                        if (std.mem.eql(u8, try arg.typeBasename(), "StaticRequest")) {
                            try static_routes.append(capture);
                        }
                        if (std.mem.eql(u8, try arg.typeBasename(), "Request")) {
                            try dynamic_routes.append(capture);
                        }
                    }
                }
            },
            .simple_var_decl => {
                const decl = self.ast.simpleVarDecl(asNodeIndex(index));
                if (self.isStaticParamsDecl(decl)) {
                    const params = try self.data.object();
                    try self.parseStaticParamsDecl(decl, params);
                    static_params = self.data.value;
                }
            },
            else => {},
        }
    }

    for (static_routes.items) |*static_route| {
        var encoded_params = std.ArrayList([]const u8).init(self.allocator);
        defer encoded_params.deinit();

        if (static_params) |capture| {
            if (capture.get(static_route.name)) |params| {
                for (params.array.array.items) |item| { // XXX: Use public interface for Data.Array here ?
                    var json_buf = std.ArrayList(u8).init(self.allocator);
                    defer json_buf.deinit();
                    const json_writer = json_buf.writer();
                    try item.toJson(json_writer);
                    var encoded_buf = std.ArrayList(u8).init(self.allocator);
                    defer encoded_buf.deinit();
                    const writer = encoded_buf.writer();
                    try std.json.encodeJsonString(json_buf.items, .{}, writer);
                    try static_route.params.append(try self.allocator.dupe(u8, encoded_buf.items));
                }
            }
        }
    }

    return .{
        .dynamic = dynamic_routes.items,
        .static = static_routes.items,
    };
}

// Parse the `pub const static_params` definition and into a `jetzig.data.Value`.
fn parseStaticParamsDecl(self: *Self, decl: std.zig.Ast.full.VarDecl, params: *jetzig.data.Value) !void {
    const init_node = self.ast.nodes.items(.tag)[decl.ast.init_node];
    switch (init_node) {
        .struct_init_dot_two, .struct_init_dot_two_comma => {
            try self.parseStruct(decl.ast.init_node, params);
        },
        else => return,
    }
}
// Recursively parse a struct into a jetzig.data.Value so it can be serialized as JSON and stored
// in `routes.zig` - used for static param comparison at runtime.
fn parseStruct(self: *Self, node: std.zig.Ast.Node.Index, params: *jetzig.data.Value) anyerror!void {
    var struct_buf: [2]std.zig.Ast.Node.Index = undefined;
    const maybe_struct_init = self.ast.fullStructInit(&struct_buf, node);

    if (maybe_struct_init == null) {
        std.debug.print("Expected struct node.\n", .{});
        return error.JetzigAstParserError;
    }

    const struct_init = maybe_struct_init.?;

    for (struct_init.ast.fields) |field| try self.parseField(field, params);
}

// Array of param sets for a route, e.g. `.{ .{ .foo = "bar" } }
fn parseArray(self: *Self, node: std.zig.Ast.Node.Index, params: *jetzig.data.Value) anyerror!void {
    var array_buf: [2]std.zig.Ast.Node.Index = undefined;
    const maybe_array = self.ast.fullArrayInit(&array_buf, node);

    if (maybe_array == null) {
        std.debug.print("Expected array node.\n", .{});
        return error.JetzigAstParserError;
    }

    const array = maybe_array.?;

    const main_token = self.ast.nodes.items(.main_token)[node];
    const field_name = self.ast.tokenSlice(main_token - 3);

    const params_array = try self.data.createArray();
    try params.put(field_name, params_array);

    for (array.ast.elements) |element| {
        const elem = self.ast.nodes.items(.tag)[element];
        switch (elem) {
            .struct_init_dot, .struct_init_dot_two, .struct_init_dot_two_comma => {
                const route_params = try self.data.createObject();
                try params_array.append(route_params);
                try self.parseStruct(element, route_params);
            },
            .array_init_dot, .array_init_dot_two, .array_init_dot_comma, .array_init_dot_two_comma => {
                const route_params = try self.data.createObject();
                try params_array.append(route_params);
                try self.parseField(element, route_params);
            },
            .string_literal => {
                const string_token = self.ast.nodes.items(.main_token)[element];
                const string_value = self.ast.tokenSlice(string_token);

                // Strip quotes: `"foo"` -> `foo`
                try params_array.append(self.data.string(string_value[1 .. string_value.len - 1]));
            },
            .number_literal => {
                const number_token = self.ast.nodes.items(.main_token)[element];
                const number_value = self.ast.tokenSlice(number_token);
                try params_array.append(try parseNumber(number_value, self.data));
            },
            inline else => {
                const tag = self.ast.nodes.items(.tag)[element];
                std.debug.print("Unexpected token: {}\n", .{tag});
                return error.JetzigStaticParamsParseError;
            },
        }
    }
}

// Parse the value of a param field (recursively when field is a struct/array)
fn parseField(self: *Self, node: std.zig.Ast.Node.Index, params: *jetzig.data.Value) anyerror!void {
    const tag = self.ast.nodes.items(.tag)[node];
    switch (tag) {
        // Route params, e.g. `.index = .{ ... }`
        .array_init_dot, .array_init_dot_two, .array_init_dot_comma, .array_init_dot_two_comma => {
            try self.parseArray(node, params);
        },
        .struct_init_dot, .struct_init_dot_two, .struct_init_dot_two_comma => {
            const nested_params = try self.data.createObject();
            const main_token = self.ast.nodes.items(.main_token)[node];
            const field_name = self.ast.tokenSlice(main_token - 3);
            try params.put(field_name, nested_params);
            try self.parseStruct(node, nested_params);
        },
        // Individual param in a params struct, e.g. `.foo = "bar"`
        .string_literal => {
            const main_token = self.ast.nodes.items(.main_token)[node];
            const field_name = self.ast.tokenSlice(main_token - 2);
            const field_value = self.ast.tokenSlice(main_token);

            try params.put(
                field_name,
                // strip outer quotes
                self.data.string(field_value[1 .. field_value.len - 1]),
            );
        },
        .number_literal => {
            const main_token = self.ast.nodes.items(.main_token)[node];
            const field_name = self.ast.tokenSlice(main_token - 2);
            const field_value = self.ast.tokenSlice(main_token);

            try params.put(field_name, try parseNumber(field_value, self.data));
        },
        else => {
            std.debug.print("Unexpected token: {}\n", .{tag});
            return error.JetzigStaticParamsParseError;
        },
    }
}

fn parseNumber(value: []const u8, data: *jetzig.data.Data) !*jetzig.data.Value {
    if (std.mem.containsAtLeast(u8, value, 1, ".")) {
        return data.float(try std.fmt.parseFloat(f64, value));
    } else {
        return data.integer(try std.fmt.parseInt(i64, value, 10));
    }
}

fn isStaticParamsDecl(self: *Self, decl: std.zig.Ast.full.VarDecl) bool {
    if (decl.visib_token) |token_index| {
        const visibility = self.ast.tokenSlice(token_index);
        const mutability = self.ast.tokenSlice(decl.ast.mut_token);
        const identifier = self.ast.tokenSlice(decl.ast.mut_token + 1); // FIXME
        return (std.mem.eql(u8, visibility, "pub") and
            std.mem.eql(u8, mutability, "const") and
            std.mem.eql(u8, identifier, "static_params"));
    } else {
        return false;
    }
}

fn parseFunction(
    self: *Self,
    index: usize,
    path: []const u8,
    source: []const u8,
) !?Function {
    const fn_proto = self.ast.fnProtoMulti(@as(u32, @intCast(index)));
    if (fn_proto.name_token) |token| {
        const function_name = try self.allocator.dupe(u8, self.ast.tokenSlice(token));
        var it = fn_proto.iterate(&self.ast);
        var args = std.ArrayList(Arg).init(self.allocator);
        defer args.deinit();

        if (!isActionFunctionName(function_name)) {
            self.allocator.free(function_name);
            return null;
        }

        while (it.next()) |arg| {
            if (arg.name_token) |arg_token| {
                const arg_name = self.ast.tokenSlice(arg_token);
                const node = self.ast.nodes.get(arg.type_expr);
                const type_name = try self.parseTypeExpr(node);
                try args.append(.{ .name = arg_name, .type_name = type_name });
            }
        }

        const view_name = path[0 .. path.len - std.fs.path.extension(path).len];

        return .{
            .name = function_name,
            .view_name = try self.allocator.dupe(u8, view_name),
            .path = try std.fs.path.join(self.allocator, &[_][]const u8{ "src", "app", "views", path }),
            .args = try self.allocator.dupe(Arg, args.items),
            .source = try self.allocator.dupe(u8, source),
            .params = std.ArrayList([]const u8).init(self.allocator),
        };
    }

    return null;
}

fn parseTypeExpr(self: *Self, node: std.zig.Ast.Node) ![]const u8 {
    switch (node.tag) {
        // Currently all expected params are pointers, keeping this here in case that changes in future:
        .identifier => {},
        .ptr_type_aligned => {
            var buf = std.ArrayList([]const u8).init(self.allocator);
            defer buf.deinit();

            for (0..(self.ast.tokens.len - node.main_token)) |index| {
                const token = self.ast.tokens.get(node.main_token + index);
                switch (token.tag) {
                    .asterisk, .period, .identifier => {
                        try buf.append(self.ast.tokenSlice(@as(u32, @intCast(node.main_token + index))));
                    },
                    else => return try std.mem.concat(self.allocator, u8, buf.items),
                }
            }
        },
        else => {},
    }

    return error.JetzigAstParserError;
}

fn asNodeIndex(index: usize) std.zig.Ast.Node.Index {
    return @as(std.zig.Ast.Node.Index, @intCast(index));
}

fn isActionFunctionName(name: []const u8) bool {
    inline for (@typeInfo(jetzig.views.Route.Action).Enum.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }

    return false;
}

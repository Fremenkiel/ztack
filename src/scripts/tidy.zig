//! Tidy enforces the mechanical rules of `docs/STYLE.md` and `docs/LAYOUT.md`.
//!
//! Tidy reads every file that git lists, tracked or untracked but not ignored, and reports each
//! problem as `path:line: message`. Code review enforces the rules that a program cannot decide.

const std = @import("std");
const assert = std.debug.assert;

const Ast = std.zig.Ast;
const Io = std.Io;

pub const line_length_max = 100;
pub const function_line_count_max = 70;
pub const file_count_max = 100_000;
pub const file_size_max = 16 * 1024 * 1024;

/// Functions that are longer than `function_line_count_max`. This list can only shrink. Tidy
/// fails if an entry is short enough, or if it no longer exists.
const function_exceptions = [_]FunctionException{};

/// The strings are split with `++`, so that this file does not match its own rules.
const banned_constructs = [_]Banned{
    .{ .text = "using" ++ "namespace", .replacement = "explicit declarations" },
    .{ .text = "std.debug." ++ "assert(", .replacement = "`assert(` with a direct import" },
    .{ .text = "== " ++ "error.", .replacement = "a `switch` on the error" },
    .{ .text = "!= " ++ "error.", .replacement = "a `switch` on the error" },
    .{
        .text = "catch " ++ "unreachable",
        .replacement = "a returned error",
        .scope = .target_and_debug_info,
    },
    .{ .text = "@mem" ++ "cpy(", .replacement = "`stdx.copy_disjoint`" },
    .{ .text = "FIX" ++ "ME", .replacement = "nothing: remove it before merge" },
    .{ .text = "dbg" ++ "(", .replacement = "nothing: remove it before merge" },
    .{
        .text = "std.debug." ++ "print(",
        .replacement = "`std.log` with a scope",
        .scope = .outside_scripts,
    },
};

const todo_marker = "TO" ++ "DO";

/// Abbreviations that `docs/STYLE.md` names, plus common ones. The exceptions in the style guide
/// (`pc`, `sp`, `id`, `i`, `j` and others) are not on this list.
const abbreviations = [_][]const u8{
    "addr", "buf", "cfg", "cnt", "ctx",  "dest", "dst", "idx", "len",
    "msg",  "num", "ptr", "reg", "regs", "src",  "tmp",
};

const allocator_names = [_][]const u8{ "gpa", "arena" };
const allocator_type_names = [_][]const u8{ "std.mem.Allocator", "mem.Allocator", "Allocator" };

/// Standard library interfaces that require a camelCase method name.
const function_names_interface = [_][]const u8{
    "jsonParse",
    "jsonParseFromValue",
    "jsonStringify",
};

const folders_top_level = [_][]const u8{ "docs", "lib", "src", "testdata", "vendor", "zig" };
const file_stems_generic = [_][]const u8{
    "common", "helper", "helpers", "misc", "types", "util", "utils",
};
const shell_extensions = [_][]const u8{ ".bash", ".sh", ".zsh" };
const shell_scripts_allowed = [_][]const u8{"zig/download.sh"};

/// Files in `src/` that the build starts from. No other file imports them.
const entry_points = [_][]const u8{
    "src/fuzz_tests.zig",
    "src/integration_tests.zig",
    "src/main.zig",
    "src/scripts.zig",
    "src/unit_tests.zig",
};

/// The layers of `docs/ARCHITECTURE.md`. A module can import only the modules in its list.
/// A `null` list means that the module is an entry point and can import any module.
const modules = [_]Module{
    .{ .name = "alloc_trace", .imports = &.{ "constants", "stdx" } },
    .{ .name = "constants", .imports = &.{"stdx"} },
    .{ .name = "debug_info", .imports = &.{ "constants", "stdx" } },
    .{ .name = "disasm", .imports = &.{ "constants", "stdx" } },
    .{
        .name = "engine",
        .imports = &.{
            "alloc_trace", "constants", "debug_info", "disasm",
            "launch",      "profile",   "stdx",       "target",
        },
    },
    .{ .name = "fuzz_tests", .imports = null, .imports_internal = true },
    .{ .name = "integration_tests", .imports = null, .imports_internal = true },
    .{ .name = "launch", .imports = &.{ "constants", "stdx" } },
    .{ .name = "main", .imports = null },
    .{ .name = "profile", .imports = &.{ "constants", "stdx" } },
    .{ .name = "scripts", .imports = null },
    .{ .name = "stdx", .imports = &.{"constants"} },
    .{ .name = "target", .imports = &.{ "constants", "stdx" } },
    .{ .name = "testing", .imports = null, .module_file = false },
    .{ .name = "ui", .imports = &.{ "constants", "engine", "stdx" } },
    .{ .name = "unit_tests", .imports = null, .imports_internal = true },
};

/// Each dependency is wrapped in one module (`docs/DEPENDENCIES.md`).
const package_owners = [_]PackageOwner{
    .{ .package = "capstone", .module = "disasm" },
    .{ .package = "dvui", .module = "ui" },
    .{ .package = "glfw", .module = "ui" },
    .{ .package = "sdl3", .module = "ui" },
    .{ .package = "zgui", .module = "ui" },
};

arena: std.mem.Allocator,
problem_count: u32,
quiet: bool,
function_exceptions_found: [function_exceptions.len]bool,

const Banned = struct {
    text: []const u8,
    replacement: []const u8,
    scope: enum { everywhere, target_and_debug_info, outside_scripts } = .everywhere,
};

const FunctionException = struct {
    path: []const u8,
    name: []const u8,
};

const Module = struct {
    name: []const u8,
    imports: ?[]const []const u8,
    /// True for the test registries, which import files inside other modules.
    imports_internal: bool = false,
    /// False for a folder of helpers that has no module file.
    module_file: bool = true,
};

const PackageOwner = struct {
    package: []const u8,
    module: []const u8,
};

const Import = struct {
    /// The resolved path for a file import. The package name for a package import.
    path: []const u8,
    line: u32,
    kind: enum { file, package },
};

const SourceFile = struct {
    path: []const u8,
    imports: []const Import,
    has_tests: bool,
    has_main: bool,
};

const NameKind = enum { function, variable, field, parameter };

const Tidy = @This();

/// Runs every check in the current directory and returns the number of problems.
pub fn run(arena: std.mem.Allocator, io: Io) !u32 {
    var tidy: Tidy = .{
        .arena = arena,
        .problem_count = 0,
        .quiet = false,
        .function_exceptions_found = @splat(false),
    };

    const paths = try paths_list(arena, io);
    assert(paths.len <= file_count_max);
    try tidy.layout_check(paths);

    var sources: std.ArrayList(SourceFile) = .empty;
    for (paths) |path| {
        if (std.mem.startsWith(u8, path, "vendor/")) continue;

        const content = file_read(arena, io, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (std.mem.indexOfScalar(u8, content, 0) != null) continue;

        tidy.text_check(path, content);
        if (std.mem.endsWith(u8, path, ".md")) tidy.markdown_check(path, content);
        if (std.mem.eql(u8, path, "build.zig.zon")) try tidy.zon_check(io, path, content);
        if (std.mem.endsWith(u8, path, ".zig")) {
            const source = try tidy.zig_check(path, content);
            if (std.mem.startsWith(u8, path, "src/")) try sources.append(arena, source);
            if (std.mem.eql(u8, path, "build.zig")) tidy.build_imports_check(source);
        }
    }
    try tidy.imports_check(sources.items);
    tidy.function_exceptions_check();
    return tidy.problem_count;
}

fn report(
    tidy: *Tidy,
    path: []const u8,
    line: u32,
    comptime format: []const u8,
    arguments: anytype,
) void {
    assert(path.len > 0);
    tidy.problem_count += 1;
    if (tidy.quiet) return;

    if (line == 0) {
        std.debug.print("{s}: ", .{path});
    } else {
        std.debug.print("{s}:{d}: ", .{ path, line });
    }
    std.debug.print(format ++ "\n", arguments);
}

fn paths_list(arena: std.mem.Allocator, io: Io) ![]const []const u8 {
    const result = try std.process.run(arena, io, .{
        .argv = &.{ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
        .stdout_limit = .limited(file_size_max),
        .stderr_limit = .limited(file_size_max),
    });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        .signal, .stopped, .unknown => return error.GitFailed,
    }

    var paths: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, result.stdout, 0);
    while (iterator.next()) |path| {
        if (path.len == 0) continue;
        if (paths.items.len == file_count_max) return error.TooManyFiles;
        try paths.append(arena, path);
    }
    std.mem.sort([]const u8, paths.items, {}, path_less_than);
    return paths.items;
}

fn path_less_than(context: void, a: []const u8, b: []const u8) bool {
    _ = context;
    return std.mem.lessThan(u8, a, b);
}

fn file_read(arena: std.mem.Allocator, io: Io, path: []const u8) ![:0]const u8 {
    return Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        arena,
        .limited(file_size_max),
        .of(u8),
        0,
    );
}

// Layout: folders, file names, modules and vendored code.

fn layout_check(tidy: *Tidy, paths: []const []const u8) !void {
    var path_set: std.StringHashMapUnmanaged(void) = .empty;
    for (paths) |path| try path_set.put(tidy.arena, path, {});

    var reported: std.StringHashMapUnmanaged(void) = .empty;
    for (paths) |path| {
        if (std.mem.startsWith(u8, path, "vendor/")) {
            try tidy.vendor_check(path, &path_set, &reported);
            continue;
        }
        tidy.path_check(path);
        if (std.mem.startsWith(u8, path, "src/")) {
            try tidy.module_path_check(path, &path_set, &reported);
        }
    }
}

fn path_check(tidy: *Tidy, path: []const u8) void {
    if (std.mem.indexOfScalar(u8, path, '/')) |slash| {
        const folder = path[0..slash];
        if (!list_contains(&folders_top_level, folder)) {
            tidy.report(path, 0, "top-level folder '{s}' is not in docs/LAYOUT.md", .{folder});
        }
    }

    const extension = std.fs.path.extension(path);
    if (list_contains(&shell_extensions, extension)) {
        if (!list_contains(&shell_scripts_allowed, path)) {
            tidy.report(path, 0, "shell script: write it in Zig in src/scripts/", .{});
        }
    }

    if (std.mem.eql(u8, extension, ".zig")) {
        const stem = std.fs.path.stem(path);
        if (!is_snake_case(stem)) {
            tidy.report(path, 0, "file name is not snake_case", .{});
        }
        if (list_contains(&file_stems_generic, stem)) {
            tidy.report(path, 0, "generic file name: name the file after its type or job", .{});
        }
    }
}

fn module_path_check(
    tidy: *Tidy,
    path: []const u8,
    path_set: *const std.StringHashMapUnmanaged(void),
    reported: *std.StringHashMapUnmanaged(void),
) !void {
    assert(std.mem.startsWith(u8, path, "src/"));

    var components = std.mem.splitScalar(u8, path["src/".len..], '/');
    while (components.next()) |component| {
        if (components.peek() == null) break;
        if (std.mem.eql(u8, component, "test") or std.mem.eql(u8, component, "tests")) {
            tidy.report(path, 0, "no test/ or tests/ directories in src/", .{});
        }
    }

    const name = module_name(path);
    const module = module_find(name) orelse {
        if (std.mem.endsWith(u8, path, ".zig")) {
            tidy.report(path, 0, "module '{s}' is not in docs/LAYOUT.md", .{name});
        }
        return;
    };

    const in_directory = std.mem.indexOfScalar(u8, path["src/".len..], '/') != null;
    if (!in_directory) return;
    if (!module.module_file) return;

    const module_file = try std.fmt.allocPrint(tidy.arena, "src/{s}.zig", .{name});
    if (path_set.contains(module_file)) return;
    if (reported.contains(module_file)) return;

    try reported.put(tidy.arena, module_file, {});
    tidy.report(path, 0, "directory src/{s}/ has no module file {s}", .{ name, module_file });
}

fn vendor_check(
    tidy: *Tidy,
    path: []const u8,
    path_set: *const std.StringHashMapUnmanaged(void),
    reported: *std.StringHashMapUnmanaged(void),
) !void {
    assert(std.mem.startsWith(u8, path, "vendor/"));

    const rest = path["vendor/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse {
        tidy.report(path, 0, "vendored code lives in vendor/<name>/", .{});
        return;
    };
    const directory = path[0 .. "vendor/".len + slash + 1];
    if (reported.contains(directory)) return;
    try reported.put(tidy.arena, directory, {});

    const version = try std.fmt.allocPrint(tidy.arena, "{s}VERSION", .{directory});
    if (!path_set.contains(version)) {
        tidy.report(directory, 0, "vendored code has no VERSION file", .{});
    }

    var has_license = false;
    var iterator = path_set.keyIterator();
    while (iterator.next()) |other| {
        if (!std.mem.startsWith(u8, other.*, directory)) continue;

        const name = other.*[directory.len..];
        if (std.mem.startsWith(u8, name, "LICENSE")) has_license = true;
        if (std.mem.startsWith(u8, name, "COPYING")) has_license = true;
    }
    if (!has_license) {
        tidy.report(directory, 0, "vendored code has no license file", .{});
    }
}

// Text rules for every file.

fn text_check(tidy: *Tidy, path: []const u8, content: []const u8) void {
    const tabs_allowed = std.mem.endsWith(u8, path, ".go");

    var line_number: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_number += 1;

        if (std.mem.indexOfScalar(u8, line, '\r') != null) {
            tidy.report(path, line_number, "carriage return", .{});
        }
        if (!tabs_allowed) {
            if (std.mem.indexOfScalar(u8, line, '\t') != null) {
                tidy.report(path, line_number, "tab: indent with 4 spaces", .{});
            }
        }
        if (std.mem.endsWith(u8, line, " ") or std.mem.endsWith(u8, line, "\t")) {
            tidy.report(path, line_number, "trailing whitespace", .{});
        }

        const length = std.unicode.utf8CountCodepoints(line) catch line.len;
        if (length > line_length_max) {
            if (std.mem.indexOf(u8, line, "://") == null) {
                tidy.report(path, line_number, "line has {d} columns, the maximum is {d}", .{
                    length,
                    line_length_max,
                });
            }
        }
    }
}

fn markdown_check(tidy: *Tidy, path: []const u8, content: []const u8) void {
    var title_count: u32 = 0;
    var in_code = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) {
            in_code = !in_code;
            continue;
        }
        if (in_code) continue;
        if (std.mem.startsWith(u8, line, "# ")) title_count += 1;
    }
    if (title_count != 1) {
        tidy.report(path, 0, "has {d} '# Title' lines, it needs exactly one", .{title_count});
    }
}

// Dependencies in build.zig.zon.

fn zon_check(tidy: *Tidy, io: Io, path: []const u8, content: [:0]const u8) !void {
    const approved_document = file_read(tidy.arena, io, "docs/DEPENDENCIES.md") catch |err| {
        switch (err) {
            error.FileNotFound => {
                tidy.report(path, 0, "docs/DEPENDENCIES.md does not exist", .{});
                return;
            },
            else => return err,
        }
    };
    const approved = section_find(approved_document, "## Approved");

    const tree = try Ast.parse(tidy.arena, content, .zon);
    if (tree.errors.len > 0) {
        tidy.report(path, 0, "does not parse", .{});
        return;
    }

    var buffer: [2]Ast.Node.Index = undefined;
    const root = tree.fullStructInit(&buffer, tree.rootDecls()[0]) orelse return;
    for (root.ast.fields) |field| {
        if (!std.mem.eql(u8, field_init_name(&tree, field), "dependencies")) continue;

        var dependencies_buffer: [2]Ast.Node.Index = undefined;
        const dependencies = tree.fullStructInit(&dependencies_buffer, field) orelse continue;
        for (dependencies.ast.fields) |dependency| {
            tidy.dependency_check(path, &tree, dependency, approved);
        }
    }
}

fn dependency_check(
    tidy: *Tidy,
    path: []const u8,
    tree: *const Ast,
    dependency: Ast.Node.Index,
    approved: []const u8,
) void {
    const name = field_init_name(tree, dependency);
    const line = line_of(tree, tree.firstToken(dependency));
    if (std.ascii.indexOfIgnoreCase(approved, name) == null) {
        tidy.report(path, line, "dependency '{s}' is not in docs/DEPENDENCIES.md", .{name});
    }

    var has_url = false;
    var has_hash = false;
    var buffer: [2]Ast.Node.Index = undefined;
    const fields = tree.fullStructInit(&buffer, dependency) orelse return;
    for (fields.ast.fields) |field| {
        const field_name = field_init_name(tree, field);
        if (std.mem.eql(u8, field_name, "url")) has_url = true;
        if (std.mem.eql(u8, field_name, "hash")) has_hash = true;
        if (std.mem.eql(u8, field_name, "path")) {
            tidy.report(path, line, "dependency '{s}' uses a path, not a URL", .{name});
        }
    }
    if (!has_url or !has_hash) {
        tidy.report(path, line, "dependency '{s}' needs a fixed URL and hash", .{name});
    }
}

// Zig source files.

fn zig_check(tidy: *Tidy, path: []const u8, content: [:0]const u8) !SourceFile {
    var source: SourceFile = .{
        .path = path,
        .imports = &.{},
        .has_tests = false,
        .has_main = false,
    };

    tidy.banned_check(path, content);
    tidy.todo_check(path, content);
    if (!std.mem.startsWith(u8, content, "//!")) {
        tidy.report(path, 1, "start the file with a '//!' comment that says what it is for", .{});
    }

    const tree = try Ast.parse(tidy.arena, content, .zig);
    if (tree.errors.len > 0) {
        tidy.report(path, 0, "does not parse", .{});
        return source;
    }

    const identifier_counts = try tidy.tokens_check(path, &tree);
    var imports: std.ArrayList(Import) = .empty;
    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        if (try tidy.node_check(path, &tree, node)) |import| try imports.append(tidy.arena, import);
        if (tree.nodeTag(node) == .test_decl) source.has_tests = true;

        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buffer, node)) |container| {
            tidy.container_check(path, &tree, container, &identifier_counts);
        }
    }
    tidy.root_check(path, &tree);

    source.imports = imports.items;
    source.has_main = root_has_main(&tree);
    return source;
}

fn banned_check(tidy: *Tidy, path: []const u8, content: []const u8) void {
    const in_scripts = path_in_module(path, "scripts");
    const in_target = path_in_module(path, "target") or path_in_module(path, "debug_info");

    var line_number: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_number += 1;
        for (banned_constructs) |banned| {
            const applies = switch (banned.scope) {
                .everywhere => true,
                .target_and_debug_info => in_target,
                .outside_scripts => !in_scripts,
            };
            if (!applies) continue;
            if (!contains_word(line, banned.text)) continue;

            tidy.report(path, line_number, "banned '{s}': use {s}", .{
                banned.text,
                banned.replacement,
            });
        }
    }
}

fn todo_check(tidy: *Tidy, path: []const u8, content: []const u8) void {
    var line_number: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_number += 1;

        var offset: usize = 0;
        while (std.mem.indexOfPos(u8, line, offset, todo_marker)) |start| {
            offset = start + todo_marker.len;
            if (!contains_word(line[start..], todo_marker)) continue;
            if (todo_valid(line[offset..])) continue;

            tidy.report(path, line_number, "write '{s}(name): reason'", .{todo_marker});
        }
    }
}

/// Returns true if `rest`, the text after the marker, is `(name): reason`.
fn todo_valid(rest: []const u8) bool {
    if (!std.mem.startsWith(u8, rest, "(")) return false;

    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return false;
    if (close < 2) return false;
    if (!std.mem.startsWith(u8, rest[close + 1 ..], ": ")) return false;
    return rest.len > close + ": ".len + 1;
}

/// Counts each identifier in the file, and rejects the identifier `Self`.
fn tokens_check(
    tidy: *Tidy,
    path: []const u8,
    tree: *const Ast,
) !std.StringHashMapUnmanaged(u32) {
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    const tags = tree.tokens.items(.tag);
    for (tags, 0..) |tag, index| {
        if (tag != .identifier) continue;

        const token: Ast.TokenIndex = @intCast(index);
        const name = tree.tokenSlice(token);
        if (std.mem.eql(u8, name, "Self")) {
            tidy.report(path, line_of(tree, token), "never write Self: name the type", .{});
        }

        const entry = try counts.getOrPut(tidy.arena, name);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
    return counts;
}

/// Checks one node, and returns the import if the node is an `@import`.
fn node_check(tidy: *Tidy, path: []const u8, tree: *const Ast, node: Ast.Node.Index) !?Import {
    switch (tree.nodeTag(node)) {
        .fn_decl => tidy.function_check(path, tree, node),
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
            tidy.variable_check(path, tree, node);
        },
        .container_field, .container_field_init, .container_field_align => {
            tidy.field_check(path, tree, node);
        },
        .test_decl => tidy.test_check(path, tree, node),
        .call_one, .call_one_comma, .call, .call_comma => tidy.assert_check(path, tree, node),
        .if_simple, .@"if" => tidy.if_check(path, tree, node),
        .@"catch" => tidy.catch_check(path, tree, node),
        .builtin_call_two, .builtin_call_two_comma => {
            const import_path = builtin_import_path(tree, node) orelse return null;
            return try import_resolve(tidy.arena, path, import_path, line_of(tree, node_token(
                tree,
                node,
            )));
        },
        else => {},
    }
    return null;
}

fn function_check(tidy: *Tidy, path: []const u8, tree: *const Ast, node: Ast.Node.Index) void {
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, node).?;
    const name_token = proto.name_token orelse return;
    const name = tree.tokenSlice(name_token);
    const line = line_of(tree, name_token);

    const line_count = line_of(tree, tree.lastToken(node)) - line_of(tree, tree.firstToken(node)) +
        1;
    tidy.function_length_check(path, line, name, line_count);

    if (proto.extern_export_inline_token) |token| {
        if (tree.tokenTag(token) != .keyword_inline) return;
    }

    const returns_type = if (proto.ast.return_type.unwrap()) |return_type|
        node_is_identifier(tree, return_type, "type")
    else
        false;
    const name_type = is_title_case(name) and std.mem.endsWith(u8, name, "Type");
    if (returns_type) {
        if (!name_type) {
            tidy.report(path, line, "'{s}' returns a type: use TitleCase that ends in Type", .{
                name,
            });
        }
    } else {
        if (name_type) {
            tidy.report(path, line, "'{s}' ends in Type but does not return a type", .{name});
        }
        if (!list_contains(&function_names_interface, name)) {
            tidy.name_check(path, line, name, .function);
        }
    }

    var parameters = proto.iterate(tree);
    while (parameters.next()) |parameter| {
        const parameter_token = parameter.name_token orelse continue;
        const parameter_name = tree.tokenSlice(parameter_token);
        const parameter_line = line_of(tree, parameter_token);
        tidy.name_check(path, parameter_line, parameter_name, .parameter);
        if (parameter.type_expr) |type_node| {
            tidy.allocator_name_check(path, parameter_line, parameter_name, tree, type_node);
        }
    }
}

fn function_length_check(
    tidy: *Tidy,
    path: []const u8,
    line: u32,
    name: []const u8,
    line_count: u32,
) void {
    assert(line_count > 0);

    for (function_exceptions, 0..) |exception, index| {
        if (!std.mem.eql(u8, exception.path, path)) continue;
        if (!std.mem.eql(u8, exception.name, name)) continue;

        if (line_count > function_line_count_max) {
            tidy.function_exceptions_found[index] = true;
        }
        return;
    }
    if (line_count > function_line_count_max) {
        tidy.report(path, line, "function '{s}' has {d} lines, the maximum is {d}", .{
            name,
            line_count,
            function_line_count_max,
        });
    }
}

fn function_exceptions_check(tidy: *Tidy) void {
    for (function_exceptions, tidy.function_exceptions_found) |exception, found| {
        if (found) continue;
        tidy.report(exception.path, 0, "function '{s}' is short or gone: remove it from " ++
            "function_exceptions in src/scripts/tidy.zig", .{exception.name});
    }
}

fn variable_check(tidy: *Tidy, path: []const u8, tree: *const Ast, node: Ast.Node.Index) void {
    const declaration = tree.fullVarDecl(node).?;
    const name_token = declaration.ast.mut_token + 1;
    const name = tree.tokenSlice(name_token);
    const line = line_of(tree, name_token);

    tidy.name_check(path, line, name, .variable);
    if (declaration.ast.type_node.unwrap()) |type_node| {
        tidy.allocator_name_check(path, line, name, tree, type_node);
    }
}

fn field_check(tidy: *Tidy, path: []const u8, tree: *const Ast, node: Ast.Node.Index) void {
    var field = tree.fullContainerField(node).?;
    field.convertToNonTupleLike(tree);
    if (field.ast.tuple_like) return;

    const name_token = field.ast.main_token;
    if (tree.tokenTag(name_token) != .identifier) return;

    const line = line_of(tree, name_token);
    const name = tree.tokenSlice(name_token);
    tidy.name_check(path, line, name, .field);
    if (field.ast.type_expr.unwrap()) |type_node| {
        tidy.allocator_name_check(path, line, name, tree, type_node);
    }
}

fn name_check(tidy: *Tidy, path: []const u8, line: u32, name: []const u8, kind: NameKind) void {
    if (std.mem.startsWith(u8, name, "@")) return;
    if (std.mem.eql(u8, name, "_")) return;

    const has_upper = for (name) |character| {
        if (std.ascii.isUpper(character)) break true;
    } else false;
    if (has_upper) {
        const title_allowed = kind != .function;
        if (!title_allowed or !is_title_case(name)) {
            tidy.report(path, line, "'{s}': use snake_case, or TitleCase for a type", .{name});
        }
        return;
    }
    assert(!has_upper);

    if (std.mem.eql(u8, name, "allocator")) {
        tidy.report(path, line, "'allocator': name it by its lifetime, such as gpa or arena", .{});
    }

    var words = std.mem.splitScalar(u8, name, '_');
    var word_index: u32 = 0;
    while (words.next()) |word| : (word_index += 1) {
        if (list_contains(&abbreviations, word)) {
            tidy.report(path, line, "'{s}': do not abbreviate '{s}'", .{ name, word });
        }
        if (word_index > 0) continue;
        if (kind == .function) continue;
        if (words.peek() == null) continue;
        if (std.mem.eql(u8, word, "max") or std.mem.eql(u8, word, "min")) {
            tidy.report(path, line, "'{s}': put '{s}' last, for example 'count_{s}'", .{
                name,
                word,
                word,
            });
        }
    }
}

fn allocator_name_check(
    tidy: *Tidy,
    path: []const u8,
    line: u32,
    name: []const u8,
    tree: *const Ast,
    type_node: Ast.Node.Index,
) void {
    const type_source = tree.getNodeSource(type_node);
    if (!list_contains(&allocator_type_names, type_source)) return;
    if (list_contains(&allocator_names, name)) return;
    if (std.mem.eql(u8, name, "allocator")) return; // The name check reports it.
    if (std.mem.endsWith(u8, name, "_arena")) return;

    tidy.report(path, line, "allocator '{s}': name it gpa, arena or <lifetime>_arena", .{name});
}

fn test_check(tidy: *Tidy, path: []const u8, tree: *const Ast, node: Ast.Node.Index) void {
    const data = tree.nodeData(node).opt_token_and_node;
    const name_token = data[0].unwrap() orelse return;
    if (tree.tokenTag(name_token) != .string_literal) return;

    const line = line_of(tree, name_token);
    const name = tree.tokenSlice(name_token);
    assert(name.len >= 2);
    if (std.mem.indexOf(u8, name, ": ") == null) {
        tidy.report(path, line, "test {s}: name it 'Subject: behavior'", .{name});
    }

    const body_start = tree.nodeMainToken(data[1]);
    assert(tree.tokenTag(body_start) == .l_brace);
    const gap = tree.source[tree.tokenStart(body_start) + 1 .. tree.tokenStart(body_start + 1)];
    const gap_trimmed = std.mem.trimStart(u8, gap, " \n");
    if (!std.mem.startsWith(u8, gap_trimmed, "//")) {
        tidy.report(path, line, "test {s}: start with a comment that says what and how", .{name});
    }
}

fn assert_check(tidy: *Tidy, path: []const u8, tree: *const Ast, node: Ast.Node.Index) void {
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node).?;
    if (!node_is_identifier(tree, call.ast.fn_expr, "assert")) return;
    if (call.ast.params.len != 1) return;
    if (tree.nodeTag(call.ast.params[0]) != .bool_and) return;

    tidy.report(path, line_of(tree, call.ast.lparen), "split 'assert(a and b)' into " ++
        "'assert(a); assert(b);'", .{});
}

fn if_check(tidy: *Tidy, path: []const u8, tree: *const Ast, node: Ast.Node.Index) void {
    const statement = tree.fullIf(node).?;
    const line = line_of(tree, statement.ast.if_token);
    const condition = statement.ast.cond_expr;

    if (tree.nodeTag(condition) == .bool_not) {
        const operand = tree.nodeData(condition).node;
        if (tree.nodeTag(operand) == .grouped_expression) {
            tidy.report(path, line, "state the condition positively, not 'if (!(...))'", .{});
        }
    }
    if (tree.nodeTag(condition) == .bool_and) {
        if (statement.ast.else_expr == .none) {
            tidy.report(path, line, "split 'if (a and b)' into nested if statements", .{});
        }
    }

    const then_is_block = switch (tree.nodeTag(statement.ast.then_expr)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => true,
        else => false,
    };
    if (then_is_block) return;
    // An if with an else can be a value, which cannot take braces.
    if (statement.ast.else_expr != .none) return;
    if (tree.tokensOnSameLine(tree.firstToken(node), tree.lastToken(node))) return;

    tidy.report(path, line, "use braces on an if that does not fit on one line", .{});
}

fn catch_check(tidy: *Tidy, path: []const u8, tree: *const Ast, node: Ast.Node.Index) void {
    const handler = tree.nodeData(node).node_and_node[1];
    switch (tree.nodeTag(handler)) {
        .block_two, .block_two_semicolon => {},
        else => return,
    }

    const statements = tree.nodeData(handler).opt_node_and_opt_node;
    if (statements[0] != .none) return;
    if (statements[1] != .none) return;

    tidy.report(path, line_of(tree, tree.nodeMainToken(node)), "never discard an error with " ++
        "an empty catch: switch on the error", .{});
}

fn container_check(
    tidy: *Tidy,
    path: []const u8,
    tree: *const Ast,
    container: Ast.full.ContainerDecl,
    identifier_counts: *const std.StringHashMapUnmanaged(u32),
) void {
    var function_index: u32 = 0;
    var init_index: ?u32 = null;
    var deinit_index: ?u32 = null;

    for (container.ast.members) |member| {
        const name_token = declaration_private_name(tree, member) orelse continue;
        const name = tree.tokenSlice(name_token);
        if (identifier_counts.get(name).? <= 1) {
            tidy.report(path, line_of(tree, name_token), "'{s}' is private and unused", .{name});
        }
    }

    for (container.ast.members) |member| {
        if (tree.nodeTag(member) != .fn_decl) continue;

        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, member).?;
        const name_token = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_token);
        if (std.mem.eql(u8, name, "init")) init_index = function_index;
        if (std.mem.eql(u8, name, "deinit")) deinit_index = function_index;
        function_index += 1;
    }

    const line = line_of(tree, container.ast.main_token);
    if (init_index) |index| {
        if (index != 0) tidy.report(path, line, "make init the first function", .{});
    }
    if (deinit_index) |index| {
        const expected: u32 = if (init_index == null) 0 else 1;
        if (index != expected) {
            tidy.report(path, line, "put deinit right after init", .{});
        }
    }
}

/// Checks the order of the top-level declarations, imports and the file-as-struct rules.
fn root_check(tidy: *Tidy, path: []const u8, tree: *const Ast) void {
    const members = tree.rootDecls();
    var field_last: ?usize = null;
    var function_first: ?usize = null;
    var test_first: ?usize = null;
    var main_first = true;

    for (members, 0..) |member, index| {
        switch (tree.nodeTag(member)) {
            .container_field, .container_field_init, .container_field_align => {
                field_last = index;
                if (function_first != null) {
                    tidy.report(path, line_of(tree, tree.firstToken(member)), "put the fields " ++
                        "of a file-as-struct before its functions", .{});
                }
            },
            .fn_decl => {
                if (function_first == null) {
                    function_first = index;
                    main_first = function_name_is(tree, member, "main");
                }
            },
            .test_decl => if (test_first == null) {
                test_first = index;
            },
            else => {},
        }
        if (test_first != null) {
            if (tree.nodeTag(member) != .test_decl) {
                tidy.report(path, line_of(tree, tree.firstToken(member)), "put tests at the " ++
                    "end of the file", .{});
            }
        }
    }

    if (!main_first) {
        if (root_has_main(tree)) {
            tidy.report(path, 0, "in an entry-point file, main comes first", .{});
        }
    }
    if (field_last) |last| tidy.this_check(path, tree, last);
    tidy.imports_order_check(path, tree);
}

fn this_check(tidy: *Tidy, path: []const u8, tree: *const Ast, field_last: usize) void {
    const members = tree.rootDecls();
    for (members, 0..) |member, index| {
        const declaration = tree.fullVarDecl(member) orelse continue;
        const init_node = declaration.ast.init_node.unwrap() orelse continue;
        if (!node_is_builtin(tree, init_node, "@This")) continue;

        const name_token = declaration.ast.mut_token + 1;
        const name = tree.tokenSlice(name_token);
        const line = line_of(tree, name_token);
        if (index < field_last) {
            tidy.report(path, line, "put 'const {s} = @This();' after the fields", .{name});
        }
        if (!names_match(name, std.fs.path.stem(path))) {
            tidy.report(path, line, "'{s}' does not match the file name", .{name});
        }
        return;
    }
    tidy.report(path, 0, "a file-as-struct needs 'const Name = @This();'", .{});
}

fn imports_order_check(tidy: *Tidy, path: []const u8, tree: *const Ast) void {
    var rank_previous: u8 = 0;
    for (tree.rootDecls()) |member| {
        const declaration = tree.fullVarDecl(member) orelse continue;
        const init_node = declaration.ast.init_node.unwrap() orelse continue;
        const name_token = declaration.ast.mut_token + 1;
        const name = tree.tokenSlice(name_token);
        const line = line_of(tree, name_token);

        const rank: u8 = if (builtin_import_path(tree, init_node)) |import_path| rank: {
            if (std.mem.endsWith(u8, import_path, ".zig")) {
                if (!names_match(name, std.fs.path.stem(import_path))) {
                    tidy.report(path, line, "import '{s}' as the file name, not '{s}'", .{
                        import_path,
                        name,
                    });
                }
            }
            break :rank import_rank(path, import_path);
        } else if (std.mem.eql(u8, tree.getNodeSource(init_node), "std.debug.assert"))
            2
        else
            continue;

        if (rank < rank_previous) {
            tidy.report(path, line, "imports go in this order: std, builtin, assert, stdx, " ++
                "constants, other modules, this module", .{});
        }
        rank_previous = rank;
    }
}

fn import_rank(path: []const u8, import_path: []const u8) u8 {
    if (std.mem.eql(u8, import_path, "std")) return 0;
    if (std.mem.eql(u8, import_path, "builtin")) return 1;
    if (!std.mem.endsWith(u8, import_path, ".zig")) return 5;

    const stem = std.fs.path.stem(import_path);
    if (std.mem.eql(u8, stem, "stdx")) return 3;
    if (std.mem.eql(u8, stem, "constants")) return 4;
    if (!std.mem.startsWith(u8, path, "src/")) return 6;

    var resolved_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&resolved_buffer);
    const resolved = path_resolve(fixed.allocator(), path, import_path) catch return 5;
    if (!std.mem.startsWith(u8, resolved, "src/")) return 5;

    const same = std.mem.eql(u8, module_name(path), module_name(resolved));
    return if (same) 6 else 5;
}

fn build_imports_check(tidy: *Tidy, source: SourceFile) void {
    assert(std.mem.eql(u8, source.path, "build.zig"));
    for (source.imports) |import| {
        if (import.kind != .file) continue;
        if (!std.mem.startsWith(u8, import.path, "src/")) continue;
        tidy.report(source.path, import.line, "build.zig does not import from src/", .{});
    }
}

// Rules across files in src/: imports, layers and test registries.

fn imports_check(tidy: *Tidy, sources: []const SourceFile) !void {
    var imported: std.StringHashMapUnmanaged(void) = .empty;
    var unit_tests: std.StringHashMapUnmanaged(void) = .empty;
    var integration_tests: std.StringHashMapUnmanaged(void) = .empty;
    var fuzz_tests: std.StringHashMapUnmanaged(void) = .empty;

    for (sources) |source| {
        for (source.imports) |import| {
            tidy.import_check(source.path, import);
            if (import.kind != .file) continue;

            try imported.put(tidy.arena, import.path, {});
            if (std.mem.eql(u8, source.path, "src/unit_tests.zig")) {
                try unit_tests.put(tidy.arena, import.path, {});
            }
            if (std.mem.eql(u8, source.path, "src/integration_tests.zig")) {
                try integration_tests.put(tidy.arena, import.path, {});
            }
            if (std.mem.eql(u8, source.path, "src/fuzz_tests.zig")) {
                try fuzz_tests.put(tidy.arena, import.path, {});
            }
        }
    }

    for (sources) |source| {
        const path = source.path;
        if (list_contains(&entry_points, path)) continue;

        const benchmark = std.mem.endsWith(u8, path, "_benchmark.zig");
        if (!imported.contains(path)) {
            if (!benchmark) tidy.report(path, 0, "no other file imports this file", .{});
        }
        if (source.has_tests) {
            const registered = unit_tests.contains(path) or integration_tests.contains(path);
            if (!registered) {
                tidy.report(path, 0, "file has tests, but src/unit_tests.zig does not " ++
                    "import it", .{});
            }
        }
        if (std.mem.endsWith(u8, path, "_fuzz.zig")) {
            if (!fuzz_tests.contains(path)) {
                tidy.report(path, 0, "src/fuzz_tests.zig does not register this fuzzer", .{});
            }
            if (!source.has_main) {
                tidy.report(path, 0, "a fuzzer exports 'pub fn main'", .{});
            }
        }
    }
}

fn import_check(tidy: *Tidy, path: []const u8, import: Import) void {
    const source_module = module_name(path);
    if (import.kind == .package) {
        for (package_owners) |owner| {
            if (!std.mem.eql(u8, owner.package, import.path)) continue;
            if (std.mem.eql(u8, owner.module, source_module)) continue;
            tidy.report(path, import.line, "only {s} imports '{s}'", .{
                owner.module,
                owner.package,
            });
        }
        return;
    }
    assert(import.kind == .file);

    if (!std.mem.startsWith(u8, import.path, "src/")) return;
    const target_module = module_name(import.path);
    if (std.mem.eql(u8, source_module, target_module)) return;

    const source = module_find(source_module) orelse return;
    const target = module_find(target_module) orelse return;
    if (source.imports) |allowed| {
        const layer_allowed = !target.module_file or list_contains(allowed, target_module);
        if (!layer_allowed) {
            tidy.report(path, import.line, "{s} cannot import {s}: see the layers in " ++
                "docs/ARCHITECTURE.md", .{ source_module, target_module });
        }
    }

    if (!target.module_file) return;
    if (source.imports_internal) return;
    const in_directory = std.mem.indexOfScalar(u8, import.path["src/".len..], '/') != null;
    if (in_directory) {
        tidy.report(path, import.line, "import src/{s}.zig, not {s}", .{
            target_module,
            import.path,
        });
    }
}

// Helpers on the syntax tree.

fn line_of(tree: *const Ast, token: Ast.TokenIndex) u32 {
    const location = tree.tokenLocation(0, token);
    return @intCast(location.line + 1);
}

fn node_token(tree: *const Ast, node: Ast.Node.Index) Ast.TokenIndex {
    return tree.nodeMainToken(node);
}

fn node_is_identifier(tree: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name);
}

fn node_is_builtin(tree: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
        else => return false,
    }
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name);
}

/// Returns the string argument of `@import("...")`, or null for any other node.
fn builtin_import_path(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    if (!node_is_builtin(tree, node, "@import")) return null;
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }

    const argument = tree.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse return null;
    if (tree.nodeTag(argument) != .string_literal) return null;

    const literal = tree.tokenSlice(tree.nodeMainToken(argument));
    assert(literal.len >= 2);
    return literal[1 .. literal.len - 1];
}

/// Returns the import of `import_path` from the file at `path`, or null for std and builtin.
fn import_resolve(
    arena: std.mem.Allocator,
    path: []const u8,
    import_path: []const u8,
    line: u32,
) !?Import {
    if (!std.mem.endsWith(u8, import_path, ".zig")) {
        if (std.mem.eql(u8, import_path, "std")) return null;
        if (std.mem.eql(u8, import_path, "builtin")) return null;
        if (std.mem.eql(u8, import_path, "root")) return null;
        return .{ .path = import_path, .line = line, .kind = .package };
    }
    const resolved = try path_resolve(arena, path, import_path);
    return .{ .path = resolved, .line = line, .kind = .file };
}

fn field_init_name(tree: *const Ast, field: Ast.Node.Index) []const u8 {
    const name_token = tree.firstToken(field) - 2;
    return tree.tokenSlice(name_token);
}

fn function_name_is(tree: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, node) orelse return false;
    const name_token = proto.name_token orelse return false;
    return std.mem.eql(u8, tree.tokenSlice(name_token), name);
}

fn root_has_main(tree: *const Ast) bool {
    for (tree.rootDecls()) |member| {
        if (tree.nodeTag(member) != .fn_decl) continue;
        if (function_name_is(tree, member, "main")) return true;
    }
    return false;
}

/// Returns the name token of a private container-level declaration, or null.
fn declaration_private_name(tree: *const Ast, member: Ast.Node.Index) ?Ast.TokenIndex {
    if (tree.fullVarDecl(member)) |declaration| {
        if (declaration.visib_token != null) return null;
        if (declaration.extern_export_token != null) return null;
        return declaration.ast.mut_token + 1;
    }
    if (tree.nodeTag(member) != .fn_decl) return null;

    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, member).?;
    if (proto.visib_token != null) return null;
    if (proto.extern_export_inline_token) |token| {
        if (tree.tokenTag(token) != .keyword_inline) return null;
    }
    return proto.name_token;
}

// Helpers on names and paths.

fn list_contains(list: []const []const u8, item: []const u8) bool {
    for (list) |element| {
        if (std.mem.eql(u8, element, item)) return true;
    }
    return false;
}

fn is_snake_case(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |character| {
        const valid = std.ascii.isLower(character) or std.ascii.isDigit(character) or
            character == '_';
        if (!valid) return false;
    }
    return true;
}

fn is_title_case(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isUpper(name[0])) return false;
    return std.mem.indexOfScalar(u8, name, '_') == null;
}

/// Compares names without case and without underscores: `GDBRemote` matches `gdb_remote`.
fn names_match(a: []const u8, b: []const u8) bool {
    var index_a: usize = 0;
    var index_b: usize = 0;
    while (true) {
        while (index_a < a.len and a[index_a] == '_') index_a += 1;
        while (index_b < b.len and b[index_b] == '_') index_b += 1;
        if (index_a == a.len or index_b == b.len) break;
        if (std.ascii.toLower(a[index_a]) != std.ascii.toLower(b[index_b])) return false;
        index_a += 1;
        index_b += 1;
    }
    return index_a == a.len and index_b == b.len;
}

/// Returns true if `line` contains `word`, and no identifier character comes right before it.
fn contains_word(line: []const u8, word: []const u8) bool {
    assert(word.len > 0);
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, line, offset, word)) |start| {
        offset = start + 1;
        if (start == 0) return true;

        const before = line[start - 1];
        const identifier_before = std.ascii.isAlphanumeric(before) or before == '_';
        if (!identifier_before) return true;
        if (!std.ascii.isAlphanumeric(word[0])) return true;
    }
    return false;
}

/// Returns the text from the heading to the next heading of the same level.
fn section_find(document: []const u8, heading: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, document, heading) orelse return "";
    const rest = document[start + heading.len ..];
    const end = std.mem.indexOf(u8, rest, "\n## ") orelse rest.len;
    return rest[0..end];
}

/// Returns the module of a path in `src/`: `src/engine/session.zig` is in `engine`.
fn module_name(path: []const u8) []const u8 {
    assert(std.mem.startsWith(u8, path, "src/"));
    const rest = path["src/".len..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| return rest[0..slash];
    return std.fs.path.stem(rest);
}

fn module_find(name: []const u8) ?Module {
    for (modules) |module| {
        if (std.mem.eql(u8, module.name, name)) return module;
    }
    return null;
}

fn path_in_module(path: []const u8, module: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "src/")) return false;
    return std.mem.eql(u8, module_name(path), module);
}

/// Joins the folder of `path` with the relative `import_path`, and removes `.` and `..`.
fn path_resolve(
    arena: std.mem.Allocator,
    path: []const u8,
    import_path: []const u8,
) ![]const u8 {
    var components: std.ArrayList([]const u8) = .empty;
    if (std.fs.path.dirnamePosix(path)) |directory| {
        var iterator = std.mem.splitScalar(u8, directory, '/');
        while (iterator.next()) |component| try components.append(arena, component);
    }

    var iterator = std.mem.splitScalar(u8, import_path, '/');
    while (iterator.next()) |component| {
        if (component.len == 0) continue;
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (components.items.len > 0) {
                _ = components.pop();
                continue;
            }
        }
        try components.append(arena, component);
    }
    return std.mem.join(arena, "/", components.items);
}

fn tidy_test(content: [:0]const u8) !u32 {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var tidy: Tidy = .{
        .arena = arena_state.allocator(),
        .problem_count = 0,
        .quiet = true,
        .function_exceptions_found = @splat(false),
    };
    _ = try tidy.zig_check("src/engine/example.zig", content);
    return tidy.problem_count;
}

test "Tidy: names_match ignores case and underscores" {
    // A file-as-struct name and its file name compare equal under this rule.
    try std.testing.expect(names_match("GDBRemote", "gdb_remote"));
    try std.testing.expect(names_match("Session", "session"));
    try std.testing.expect(!names_match("Session", "sessions"));
}

test "Tidy: path_resolve removes dot segments" {
    // Each import path is joined with the folder of the importing file.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const resolved = try path_resolve(arena, "src/engine/session.zig", "../target.zig");
    try std.testing.expectEqualStrings("src/target.zig", resolved);
}

test "Tidy: todo_valid accepts only the name and reason form" {
    // The text after the marker must be '(name): reason'.
    try std.testing.expect(todo_valid("(name): add the cache"));
    try std.testing.expect(!todo_valid(": add the cache"));
    try std.testing.expect(!todo_valid("(name) add the cache"));
}

test "Tidy: zig_check accepts a clean file" {
    // A small file that follows every rule has zero problems.
    const content =
        \\//! Example.
        \\
        \\const std = @import("std");
        \\const assert = std.debug.assert;
        \\
        \\pub fn count_add(count: u32) u32 {
        \\    assert(count < 10);
        \\    return count + 1;
        \\}
        \\
    ;
    try std.testing.expectEqual(@as(u32, 0), try tidy_test(content));
}

test "Tidy: zig_check reports each broken rule" {
    // Each line breaks one rule: camelCase, abbreviation, compound assert, and an unused name.
    const content =
        \\//! Example.
        \\
        \\const std = @import("std");
        \\const assert = std.debug.assert;
        \\
        \\pub fn countAdd(addr: u32) u32 {
        \\    assert(addr < 10 and addr > 1);
        \\    return addr + 1;
        \\}
        \\
        \\fn unused_helper() void {}
        \\
    ;
    try std.testing.expectEqual(@as(u32, 4), try tidy_test(content));
}

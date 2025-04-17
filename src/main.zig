const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Ast = std.zig.Ast;
const Color = std.zig.Color;
const warn = std.log.warn;
const ThreadPool = std.Thread.Pool;
const cleanExit = std.process.cleanExit;
const native_os = builtin.os.tag;
const Cache = std.Build.Cache;
const Path = std.Build.Cache.Path;
const Directory = std.Build.Cache.Directory;
const EnvVar = std.zig.EnvVar;
const LibCInstallation = std.zig.LibCInstallation;
const AstGen = std.zig.AstGen;
const ZonGen = std.zig.ZonGen;
const Server = std.zig.Server;

const tracy = @import("tracy.zig");
const Compilation = @import("Compilation.zig");
const link = @import("link.zig");
const Package = @import("Package.zig");
const build_options = @import("build_options");
const introspect = @import("introspect.zig");
const wasi_libc = @import("wasi_libc.zig");
const target_util = @import("target.zig");
const crash_report = @import("crash_report.zig");
const Zcu = @import("Zcu.zig");
const mingw = @import("mingw.zig");
const dev = @import("dev.zig");

test {
    _ = Package;
}

const thread_stack_size = 50 << 20;

pub const std_options: std.Options = .{
    .wasiCwd = wasi_cwd,
    .logFn = log,
    .enable_segfault_handler = false,

    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast => .info,
        .ReleaseSmall => .err,
    },
};

pub const panic = crash_report.panic;

var wasi_preopens: fs.wasi.Preopens = undefined;
pub fn wasi_cwd() std.os.wasi.fd_t {
    // Expect the first preopen to be current working directory.
    const cwd_fd: std.posix.fd_t = 3;
    assert(mem.eql(u8, wasi_preopens.names[cwd_fd], "."));
    return cwd_fd;
}

fn getWasiPreopen(name: []const u8) Directory {
    return .{
        .path = name,
        .handle = .{
            .fd = wasi_preopens.find(name) orelse fatal("WASI preopen not found: '{s}'", .{name}),
        },
    };
}

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    process.exit(1);
}

/// Shaming all the locations that inappropriately use an O(N) search algorithm.
/// Please delete this and fix the compilation errors!
pub const @"bad O(N)" = void;

const normal_usage =
    \\Usage: zig [command] [options]
    \\
    \\Commands:
    \\
    \\  build            Build project from build.zig
    \\  fetch            Copy a package into global cache and print its hash
    \\  init             Initialize a Zig package in the current directory
    \\
    \\  build-exe        Create executable from source or object files
    \\  build-lib        Create library from source or object files
    \\  build-obj        Create object from source or object files
    \\  test             Perform unit testing
    \\  run              Create executable and run immediately
    \\
    \\  ast-check        Look for simple compile errors in any set of files
    \\  fmt              Reformat Zig source into canonical form
    \\  reduce           Minimize a bug report
    \\  translate-c      Convert C code to Zig code
    \\
    \\  ar               Use Zig as a drop-in archiver
    \\  cc               Use Zig as a drop-in C compiler
    \\  c++              Use Zig as a drop-in C++ compiler
    \\  dlltool          Use Zig as a drop-in dlltool.exe
    \\  lib              Use Zig as a drop-in lib.exe
    \\  ranlib           Use Zig as a drop-in ranlib
    \\  objcopy          Use Zig as a drop-in objcopy
    \\  rc               Use Zig as a drop-in rc.exe
    \\
    \\  env              Print lib path, std path, cache directory, and version
    \\  help             Print this help and exit
    \\  std              View standard library documentation in a browser
    \\  libc             Display native libc paths file or validate one
    \\  targets          List available compilation targets
    \\  version          Print version number and exit
    \\  zen              Print Zen of Zig and exit
    \\
    \\General Options:
    \\
    \\  -h, --help       Print command-specific usage
    \\
;

const debug_usage = normal_usage ++
    \\
    \\Debug Commands:
    \\
    \\  changelist       Compute mappings from old ZIR to new ZIR
    \\  dump-zir         Dump a file containing cached ZIR
    \\  detect-cpu       Compare Zig's CPU feature detection vs LLVM
    \\  llvm-ints        Dump a list of LLVMABIAlignmentOfType for all integers
    \\
;

const usage = if (build_options.enable_debug_extensions) debug_usage else normal_usage;
const default_local_zig_cache_basename = ".zig-cache";

var log_scopes: std.ArrayListUnmanaged([]const u8) = .empty;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Hide debug messages unless:
    // * logging enabled with `-Dlog`.
    // * the --debug-log arg for the scope has been provided
    if (@intFromEnum(level) > @intFromEnum(std.options.log_level) or
        @intFromEnum(level) > @intFromEnum(std.log.Level.info))
    {
        if (!build_options.enable_logging) return;

        const scope_name = @tagName(scope);
        for (log_scopes.items) |log_scope| {
            if (mem.eql(u8, log_scope, scope_name))
                break;
        } else return;
    }

    const prefix1 = comptime level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    // Print the message to stderr, silently ignoring any errors
    std.debug.print(prefix1 ++ prefix2 ++ format ++ "\n", args);
}

var debug_allocator: std.heap.DebugAllocator(.{
    .stack_trace_frames = build_options.mem_leak_frames,
}) = .init;

pub fn main() anyerror!void {
    crash_report.initialize();

    const gpa, const is_debug = gpa: {
        if (build_options.debug_gpa) break :gpa .{ debug_allocator.allocator(), true };
        if (native_os == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        // For WASI and debug builds: keep existing behavior.
        if (builtin.link_libc) {
            // We would prefer to use raw libc allocator here, but cannot use
            // it if it won't support the alignment we need.
            if (@alignOf(std.c.max_align_t) < @max(@alignOf(i128), std.atomic.cache_line)) {
                break :gpa .{ std.heap.c_allocator, false };
            }
            break :gpa .{ std.heap.raw_c_allocator, false };
        }
        // Use page_allocator for native, non-WASI, non-debug builds for improved performance.
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.page_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };
    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try process.argsAlloc(arena);

    if (tracy.enable_allocation) {
        var gpa_tracy = tracy.tracyAllocator(gpa);
        return mainArgs(gpa_tracy.allocator(), arena, args);
    }

    if (native_os == .wasi) {
        wasi_preopens = try fs.wasi.preopensAlloc(arena);
    }

    return mainArgs(gpa, arena, args);
}

// ...rest of file unchanged...
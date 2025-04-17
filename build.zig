const std = @import("std");
const builtin = std.builtin;
const tests = @import("test/tests.zig");
const BufMap = std.BufMap;
const mem = std.mem;
const ArrayList = std.ArrayList;
const io = std.io;
const fs = std.fs;
const InstallDirectoryOptions = std.Build.InstallDirectoryOptions;
const assert = std.debug.assert;
const DevEnv = @import("src/dev.zig").Env;
const ValueInterpretMode = enum { direct, by_name };

const zig_version: std.SemanticVersion = .{ .major = 0, .minor = 15, .patch = 0 };
const stack_size = 46 * 1024 * 1024;

const DEFAULT_OPTIMIZATION_MODES = [_]builtin.OptimizeMode{
    builtin.OptimizeMode.Debug,
    builtin.OptimizeMode.ReleaseSafe,
    builtin.OptimizeMode.ReleaseFast,
    builtin.OptimizeMode.ReleaseSmall,
};

pub fn build(b: *std.Build) !void {
    const only_c = b.option(bool, "only-c", "Translate the Zig compiler to C code, with only the C backend enabled") orelse false;
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .ofmt = if (only_c) .c else null,
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const flat = b.option(bool, "flat", "Put files into the installation prefix in a manner suited for upstream distribution rather than a posix file system hierarchy standard") orelse false;
    const single_threaded = b.option(bool, "single-threaded", "Build artifacts that run in single threaded mode");
    const use_zig_libcxx = b.option(bool, "use-zig-libcxx", "If libc++ is needed, use zig's bundled version, don't try to integrate with the system") orelse false;

    const test_step = b.step("test", "Run all the tests");
    const skip_install_lib_files = b.option(bool, "no-lib", "skip copying of lib/ files and langref to installation prefix. Useful for development") orelse false;
    const skip_install_langref = b.option(bool, "no-langref", "skip copying of langref to the installation prefix") orelse skip_install_lib_files;
    const std_docs = b.option(bool, "std-docs", "include standard library autodocs") orelse false;
    const no_bin = b.option(bool, "no-bin", "skip emitting compiler binary") orelse false;
    const enable_superhtml = b.option(bool, "enable-superhtml", "Check langref output HTML validity") orelse false;

    const langref_file = generateLangRef(b);
    const install_langref = b.addInstallFileWithDir(langref_file, .prefix, "doc/langref.html");
    const check_langref = superHtmlCheck(b, langref_file);
    if (enable_superhtml) install_langref.step.dependOn(check_langref);

    const check_autodocs = superHtmlCheck(b, b.path("lib/docs/index.html"));
    if (enable_superhtml) {
        test_step.dependOn(check_langref);
        test_step.dependOn(check_autodocs);
    }
    if (!skip_install_langref) {
        b.getInstallStep().dependOn(&install_langref.step);
    }

    const autodoc_test = b.addObject(.{
        .name = "std",
        .zig_lib_dir = b.path("lib"),
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/std/std.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const install_std_docs = b.addInstallDirectory(.{
        .source_dir = autodoc_test.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "doc/std",
    });
    //if (enable_tidy) install_std_docs.step.dependOn(check_autodocs);
    if (std_docs) {
        b.getInstallStep().dependOn(&install_std_docs.step);
    }

    if (flat) {
        b.installFile("LICENSE", "LICENSE");
        b.installFile("README.md", "README.md");
    }

    const langref_step = b.step("langref", "Build and install the language reference");
    langref_step.dependOn(&install_langref.step);

    const std_docs_step = b.step("std-docs", "Build and install the standard library documentation");
    std_docs_step.dependOn(&install_std_docs.step);

    const docs_step = b.step("docs", "Build and install documentation");
    docs_step.dependOn(langref_step);
    docs_step.dependOn(std_docs_step);

    const skip_debug = b.option(bool, "skip-debug", "Main test suite skips debug builds") orelse false;
    const skip_release = b.option(bool, "skip-release", "Main test suite skips release builds") orelse false;
    const skip_release_small = b.option(bool, "skip-release-small", "Main test suite skips release-small builds") orelse skip_release;
    const skip_release_fast = b.option(bool, "skip-release-fast", "Main test suite skips release-fast builds") orelse skip_release;
    const skip_release_safe = b.option(bool, "skip-release-safe", "Main test suite skips release-safe builds") orelse skip_release;
    const skip_non_native = b.option(bool, "skip-non-native", "Main test suite skips non-native builds") orelse false;
    const skip_libc = b.option(bool, "skip-libc", "Main test suite skips tests that link libc") orelse false;
    const skip_single_threaded = b.option(bool, "skip-single-threaded", "Main test suite skips tests that are single-threaded") orelse false;
    const skip_translate_c = b.option(bool, "skip-translate-c", "Main test suite skips translate-c tests") orelse false;
    const skip_run_translated_c = b.option(bool, "skip-run-translated-c", "Main test suite skips run-translated-c tests") orelse false;

    const only_install_lib_files = b.option(bool, "lib-files-only", "Only install library files") orelse false;

    const static_llvm = b.option(bool, "static-llvm", "Disable integration with system-installed LLVM, Clang, LLD, and libc++") orelse false;
    const enable_llvm = b.option(bool, "enable-llvm", "Build self-hosted compiler with LLVM backend enabled") orelse static_llvm;
    const llvm_has_m68k = b.option(
        bool,
        "llvm-has-m68k",
        "Whether LLVM has the experimental target m68k enabled",
    ) orelse false;
    const llvm_has_csky = b.option(
        bool,
        "llvm-has-csky",
        "Whether LLVM has the experimental target csky enabled",
    ) orelse false;
    const llvm_has_arc = b.option(
        bool,
        "llvm-has-arc",
        "Whether LLVM has the experimental target arc enabled",
    ) orelse false;
    const llvm_has_xtensa = b.option(
        bool,
        "llvm-has-xtensa",
        "Whether LLVM has the experimental target xtensa enabled",
    ) orelse false;
    const enable_ios_sdk = b.option(bool, "enable-ios-sdk", "Run tests requiring presence of iOS SDK and frameworks") orelse false;
    const enable_macos_sdk = b.option(bool, "enable-macos-sdk", "Run tests requiring presence of macOS SDK and frameworks") orelse enable_ios_sdk;
    const enable_symlinks_windows = b.option(bool, "enable-symlinks-windows", "Run tests requiring presence of symlinks on Windows") orelse false;
    const config_h_path_option = b.option([]const u8, "config_h", "Path to the generated config.h");

    if (!skip_install_lib_files) {
        b.installDirectory(.{
            .source_dir = b.path("lib"),
            .install_dir = if (flat) .prefix else .lib,
            .install_subdir = if (flat) "lib" else "zig",
            .exclude_extensions = &[_][]const u8{
                // exclude files from lib/std/compress/testdata
                ".gz",
                ".z.0",
                ".z.9",
                ".zst.3",
                ".zst.19",
                "rfc1951.txt",
                "rfc1952.txt",
                "rfc8478.txt",
                // exclude files from lib/std/compress/flate/testdata
                ".expect",
                ".expect-noinput",
                ".golden",
                ".input",
                "compress-e.txt",
                "compress-gettysburg.txt",
                "compress-pi.txt",
                "rfc1951.txt",
                // exclude files from lib/std/compress/lzma/testdata
                ".lzma",
                // exclude files from lib/std/compress/xz/testdata
                ".xz",
                // exclude files from lib/std/tz/
                ".tzif",
                // exclude files from lib/std/tar/testdata
                ".tar",
                // others
                "README.md",
            },
            .blank_extensions = &[_][]const u8{
                "test.zig",
            },
        });
    }

    if (only_install_lib_files)
        return;

    const entitlements = b.option([]const u8, "entitlements", "Path to entitlements file for hot-code swapping without sudo on macOS");
    const tracy = b.option([]const u8, "tracy", "Enable Tracy integration. Supply path to Tracy source");
    const tracy_callstack = b.option(bool, "tracy-callstack", "Include callstack information with Tracy data. Does nothing if -Dtracy is not provided") orelse (tracy != null);
    const tracy_allocation = b.option(bool, "tracy-allocation", "Include allocation information with Tracy data. Does nothing if -Dtracy is not provided") orelse (tracy != null);
    const tracy_callstack_depth: u32 = b.option(u32, "tracy-callstack-depth", "Declare callstack depth for Tracy data. Does nothing if -Dtracy_callstack is not provided") orelse 10;
    const debug_gpa = b.option(bool, "debug-allocator", "Force the compiler to use DebugAllocator") orelse false;
    const link_libc = b.option(bool, "force-link-libc", "Force self-hosted compiler to link libc") orelse (enable_llvm or only_c);
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable thread-sanitization") orelse false;
    const strip = b.option(bool, "strip", "Omit debug information");
    const valgrind = b.option(bool, "valgrind", "Enable valgrind integration");
    const pie = b.option(bool, "pie", "Produce a Position Independent Executable");
    const value_interpret_mode = b.option(ValueInterpretMode, "value-interpret-mode", "How the compiler translates between 'std.builtin' types and its internal datastructures") orelse .direct;
    const value_tracing = b.option(bool, "value-tracing", "Enable extra state tracking to help troubleshoot bugs in the compiler (using the std.debug.Trace API)") orelse false;

    const mem_leak_frames: u32 = b.option(u32, "mem-leak-frames", "How many stack frames to print when a memory leak occurs. Tests get 2x this amount.") orelse blk: {
        if (strip == true) break :blk @as(u32, 0);
        if (optimize != .Debug) break :blk 0;
        break :blk 4;
    };

    const exe = addCompilerStep(b, .{
        .optimize = optimize,
        .target = target,
        .strip = strip,
        .valgrind = valgrind,
        .sanitize_thread = sanitize_thread,
        .single_threaded = single_threaded,
    });
    exe.pie = pie;
    exe.entitlements = entitlements;

    exe.build_id = b.option(
        std.zig.BuildId,
        "build-id",
        "Request creation of '.note.gnu.build-id' section",
    );

    if (no_bin) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        const install_exe = b.addInstallArtifact(exe, .{
            .dest_dir = if (flat) .{ .override = .prefix } else .default,
        });
        b.getInstallStep().dependOn(&install_exe.step);
    }

    test_step.dependOn(&exe.step);

    const use_llvm = b.option(bool, "use-llvm", "Use the llvm backend");
    exe.use_llvm = use_llvm;
    exe.use_lld = use_llvm;

    const exe_options = b.addOptions();
    exe.root_module.addOptions("build_options", exe_options);

    exe_options.addOption(u32, "mem_leak_frames", mem_leak_frames);
    exe_options.addOption(bool, "skip_non_native", skip_non_native);
    exe_options.addOption(bool, "have_llvm", enable_llvm);
    exe_options.addOption(bool, "llvm_has_m68k", llvm_has_m68k);
    exe_options.addOption(bool, "llvm_has_csky", llvm_has_csky);
    exe_options.addOption(bool, "llvm_has_arc", llvm_has_arc);
    exe_options.addOption(bool, "llvm_has_xtensa", llvm_has_xtensa);
    exe_options.addOption(bool, "debug_gpa", debug_gpa);
    exe_options.addOption(DevEnv, "dev", b.option(DevEnv, "dev", "Build a compiler with a reduced feature set for development of specific features") orelse if (only_c) .bootstrap else .full);
    exe_options.addOption(ValueInterpretMode, "value_interpret_mode", value_interpret_mode);

    if (link_libc) {
        exe.root_module.link_libc = true;
    }

    const is_debug = optimize == .Debug;
    const enable_debug_extensions = b.option(bool, "debug-extensions", "Enable commands and options useful for debugging the compiler") orelse is_debug;
    const enable_logging = b.option(bool, "log", "Enable debug logging with --debug-log") orelse is_debug;
    const enable_link_snapshots = b.option(bool, "link-snapshot", "Whether to enable linker state snapshots") orelse false;

    const opt_version_string = b.option([]const u8, "version-string", "Override Zig version string. Default is to find out with git.");
    const version_slice = if (opt_version_string) |version| version else v: {
        if (!std.process.can_spawn) {
            std.debug.print("error: version info cannot be retrieved from git. Zig version must be provided using -Dversion-string\n", .{});
            std.process.exit(1);
        }
        const version_string = b.fmt("{d}.{d}.{d}", .{ zig_version.major, zig_version.minor, zig_version.patch });

        var code: u8 = undefined;
        const git_describe_untrimmed = b.runAllowFail(&[_][]const u8{
            "git",
            "-C", b.build_root.path orelse ".", // affects the --git-dir argument
            "--git-dir", ".git", // affected by the -C argument
            "describe", "--match",    "*.*.*", //
            "--tags",   "--abbrev=9",
        }, &code, .Ignore) catch {
            break :v version_string;
        };
        const git_describe = mem.trim(u8, git_describe_untrimmed, " \n\r");

        switch (mem.count(u8, git_describe, "-")) {
            0 => {
                // Tagged release version (e.g. 0.10.0).
                if (!mem.eql(u8, git_describe, version_string)) {
                    std.debug.print("Zig version '{s}' does not match Git tag '{s}'\n", .{ version_string, git_describe });
                    std.process.exit(1);
                }
                break :v version_string;
            },
            2 => {
                // Untagged development build (e.g. 0.10.0-dev.2025+ecf0050a9).
                var it = mem.splitScalar(u8, git_describe, '-');
                const tagged_ancestor = it.first();
                const commit_height = it.next().?;
                const commit_id = it.next().?;

                const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
                if (zig_version.order(ancestor_ver) != .gt) {
                    std.debug.print("Zig version '{}' must be greater than tagged ancestor '{}'\n", .{ zig_version, ancestor_ver });
                    std.process.exit(1);
                }

                // Check that the commit hash is prefixed with a 'g' (a Git convention).
                if (commit_id.len < 1 or commit_id[0] != 'g') {
                    std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                    break :v version_string;
                }

                // The version is reformatted in accordance with the https://semver.org specification.
                break :v b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
            },
            else => {
                std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                break :v version_string;
            },
        }
    };
    const version = try b.allocator.dupeZ(u8, version_slice);
    exe_options.addOption([:0]const u8, "version", version);

    if (enable_llvm) {
        const cmake_cfg = if (static_llvm) null else blk: {
            if (findConfigH(b, config_h_path_option)) |config_h_path| {
                const file_contents = fs.cwd().readFileAlloc(b.allocator, config_h_path, max_config_h_bytes) catch unreachable;
                break :blk parseConfigH(b, file_contents);
            } else {
                std.log.warn("config.h could not be located automatically. Consider providing it explicitly via \"-Dconfig_h\"", .{});
                break :blk null;
            }
        };

        if (cmake_cfg) |cfg| {
            // Inside this code path, we have to coordinate with system packaged LLVM, Clang, and LLD.
            // That means we also have to rely on stage1 compiled c++ files. We parse config.h to find
            // the information passed on to us from cmake.
            if (cfg.cmake_prefix_path.len > 0) {
                var it = mem.tokenizeScalar(u8, cfg.cmake_prefix_path, ';');
                while (it.next()) |path| {
                    b.addSearchPrefix(path);
                }
            }

            try addCmakeCfgOptionsToExe(b, cfg, exe, use_zig_libcxx);
        } else {
            // Here we are -Denable-llvm but no cmake integration.
            try addStaticLlvmOptionsToModule(exe.root_module, .{
                .llvm_has_m68k = llvm_has_m68k,
                .llvm_has_csky = llvm_has_csky,
                .llvm_has_arc = llvm_has_arc,
                .llvm_has_xtensa = llvm_has_xtensa,
            });
        }
        if (target.result.os.tag == .windows) {
            // LLVM depends on networking as of version 18.
            exe.root_module.linkSystemLibrary("ws2_32", .{});

            exe.root_module.linkSystemLibrary("version", .{});
            exe.root_module.linkSystemLibrary("uuid", .{});
            exe.root_module.linkSystemLibrary("ole32", .{});
        }
    }

    const semver = try std.SemanticVersion.parse(version);
    exe_options.addOption(std.SemanticVersion, "semver", semver);

    exe_options.addOption(bool, "enable_debug_extensions", enable_debug_extensions);
    exe_options.addOption(bool, "enable_logging", enable_logging);
    exe_options.addOption(bool, "enable_link_snapshots", enable_link_snapshots);
    exe_options.addOption(bool, "enable_tracy", tracy != null);
    exe_options.addOption(bool, "enable_tracy_callstack", tracy_callstack);
    exe_options.addOption(bool, "enable_tracy_allocation", tracy_allocation);
    exe_options.addOption(u32, "tracy_callstack_depth", tracy_callstack_depth);
    exe_options.addOption(bool, "value_tracing", value_tracing);
    if (tracy) |tracy_path| {
        const client_cpp = b.pathJoin(
            &[_][]const u8{ tracy_path, "public", "TracyClient.cpp" },
        );

        const tracy_c_flags: []const []const u8 = &.{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" };

        exe.root_module.addIncludePath(.{ .cwd_relative = tracy_path });
        exe.root_module.addCSourceFile(.{ .file = .{ .cwd_relative = client_cpp }, .flags = tracy_c_flags });
        if (!enable_llvm) {
            exe.root_module.linkSystemLibrary("c++", .{ .use_pkg_config = .no });
        }
        exe.root_module.link_libc = true;

        if (target.result.os.tag == .windows) {
            exe.root_module.linkSystemLibrary("dbghelp", .{});
            exe.root_module.linkSystemLibrary("ws2_32", .{});
        }
    }

    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};
    const test_target_filters = b.option([]const []const u8, "test-target-filter", "Skip tests whose target triple do not match any filter") orelse &[0][]const u8{};
    const test_slow_targets = b.option(bool, "test-slow-targets", "Enable running module tests for targets that have a slow compiler backend") orelse false;

    // Standardize build mode (OptimizationModes) logic
    fn computeOptimizationModes(skip_debug: bool, skip_release_safe: bool, skip_release_fast: bool, skip_release_small: bool) []const builtin.OptimizeMode {
        // Returns the list of enabled optimization modes depending on skip flags.
        var buf: [4]builtin.OptimizeMode = undefined;
        var idx: usize = 0;
        if (!skip_debug) {
            buf[idx] = builtin.OptimizeMode.Debug;
            idx += 1;
        }
        if (!skip_release_safe) {
            buf[idx] = builtin.OptimizeMode.ReleaseSafe;
            idx += 1;
        }
        if (!skip_release_fast) {
            buf[idx] = builtin.OptimizeMode.ReleaseFast;
            idx += 1;
        }
        if (!skip_release_small) {
            buf[idx] = builtin.OptimizeMode.ReleaseSmall;
            idx += 1;
        }
        return buf[0..idx];
    }
    const optimization_modes = computeOptimizationModes(skip_debug, skip_release_safe, skip_release_fast, skip_release_small);

    const fmt_include_paths = &.{ "lib", "src", "test", "tools", "build.zig", "build.zig.zon" };
    const fmt_exclude_paths = &.{ "test/cases", "test/behavior/zon" };
    const do_fmt = b.addFmt(.{
        .paths = fmt_include_paths,
        .exclude_paths = fmt_exclude_paths,
    });
    b.step("fmt", "Modify source files in place to have conforming formatting").dependOn(&do_fmt.step);

    const check_fmt = b.step("test-fmt", "Check source files having conforming formatting");
    check_fmt.dependOn(&b.addFmt(.{
        .paths = fmt_include_paths,
        .exclude_paths = fmt_exclude_paths,
        .check = true,
    }).step);
    test_step.dependOn(check_fmt);

    const test_cases_step = b.step("test-cases", "Run the main compiler test cases");
    try tests.addCases(b, test_cases_step, test_filters, test_target_filters, target, .{
        .skip_translate_c = skip_translate_c,
        .skip_run_translated_c = skip_run_translated_c,
    }, .{
        .enable_llvm = enable_llvm,
        .llvm_has_m68k = llvm_has_m68k,
        .llvm_has_csky = llvm_has_csky,
        .llvm_has_arc = llvm_has_arc,
        .llvm_has_xtensa = llvm_has_xtensa,
    });
    test_step.dependOn(test_cases_step);

    const test_modules_step = b.step("test-modules", "Run the per-target module tests");
    test_step.dependOn(test_modules_step);

    test_modules_step.dependOn(tests.addModuleTests(b, .{
        .test_filters = test_filters,
        .test_target_filters = test_target_filters,
        .test_slow_targets = test_slow_targets,
        .root_src = "test/behavior.zig",
        .name = "behavior",
        .desc = "Run the behavior tests",
        .optimize_modes = optimization_modes,
        .include_paths = &.{},
        .skip_single_threaded = skip_single_threaded,
        .skip_non_native = skip_non_native,
        .skip_libc = skip_libc,
        .use_llvm = use_llvm,
        .max_rss = 2 * 1024 * 1024 * 1024,
    }));

    test_modules_step.dependOn(tests.addModuleTests(b, .{
        .test_filters = test_filters,
        .test_target_filters = test_target_filters,
        .test_slow_targets = test_slow_targets,
        .root_src = "test/c_import.zig",
        .name = "c-import",
        .desc = "Run the @cImport tests",
        .optimize_modes = optimization_modes,
        .include_paths = &.{"test/c_import"},
        .skip_single_threaded = true,
        .skip_non_native = skip_non_native,
        .skip_libc = skip_libc,
        .use_llvm = use_llvm,
    }));

    test_modules_step.dependOn(tests.addModuleTests(b, .{
        .test_filters = test_filters,
        .test_target_filters = test_target_filters,
        .test_slow_targets = test_slow_targets,
        .root_src = "lib/compiler_rt.zig",
        .name = "compiler-rt",
        .desc = "Run the compiler_rt tests",
        .optimize_modes = optimization_modes,
        .include_paths = &.{},
        .skip_single_threaded = true,
        .skip_non_native = skip_non_native,
        .skip_libc = true,
        .use_llvm = use_llvm,
        .no_builtin = true,
    }));

    test_modules_step.dependOn(tests.addModuleTests(b, .{
        .test_filters = test_filters,
        .test_target_filters = test_target_filters,
        .test_slow_targets = test_slow_targets,
        .root_src = "lib/c.zig",
        .name = "universal-libc",
        .desc = "Run the universal libc tests",
        .optimize_modes = optimization_modes,
        .include_paths = &.{},
        .skip_single_threaded = true,
        .skip_non_native = skip_non_native,
        .skip_libc = true,
        .use_llvm = use_llvm,
        .no_builtin = true,
    }));

    test_modules_step.dependOn(tests.addModuleTests(b, .{
        .test_filters = test_filters,
        .test_target_filters = test_target_filters,
        .test_slow_targets = test_slow_targets,
        .root_src = "lib/std/std.zig",
        .name = "std",
        .desc = "Run the standard library tests",
        .optimize_modes = optimization_modes,
        .include_paths = &.{},
        .skip_single_threaded = skip_single_threaded,
        .skip_non_native = skip_non_native,
        .skip_libc = skip_libc,
        .use_llvm = use_llvm,
        // I observed a value of 5605064704 on the M2 CI.
        .max_rss = 6165571174,
    }));

    const unit_tests_step = b.step("test-unit", "Run the compiler source unit tests");
    test_step.dependOn(unit_tests_step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .link_libc = link_libc,
            .single_threaded = single_threaded,
        }),
        .filters = test_filters,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
        .zig_lib_dir = b.path("lib"),
    });
    unit_tests.root_module.addOptions("build_options", exe_options);
    unit_tests_step.dependOn(&b.addRunArtifact(unit_tests).step);

    test_step.dependOn(tests.addCompareOutputTests(b, test_filters, optimization_modes));
    test_step.dependOn(tests.addStandaloneTests(
        b,
        optimization_modes,
        enable_macos_sdk,
        enable_ios_sdk,
        enable_symlinks_windows,
    ));
    test_step.dependOn(tests.addCAbiTests(b, .{
        .test_target_filters = test_target_filters,
        .skip_non_native = skip_non_native,
        .skip_release = skip_release,
    }));
    test_step.dependOn(tests.addLinkTests(b, enable_macos_sdk, enable_ios_sdk, enable_symlinks_windows));
    test_step.dependOn(tests.addStackTraceTests(b, test_filters, optimization_modes));
    test_step.dependOn(tests.addCliTests(b));
    test_step.dependOn(tests.addAssembleAndLinkTests(b, test_filters, optimization_modes));
    if (tests.addDebuggerTests(b, .{
        .test_filters = test_filters,
        .test_target_filters = test_target_filters,
        .gdb = b.option([]const u8, "gdb", "path to gdb binary"),
        .lldb = b.option([]const u8, "lldb", "path to lldb binary"),
        .optimize_modes = optimization_modes,
        .skip_single_threaded = skip_single_threaded,
        .skip_non_native = skip_non_native,
        .skip_libc = skip_libc,
    })) |test_debugger_step| test_step.dependOn(test_debugger_step);

    try addWasiUpdateStep(b, version);

    const update_mingw_step = b.step("update-mingw", "Update zig's bundled mingw");
    const opt_mingw_src_path = b.option([]const u8, "mingw-src", "path to mingw-w64 source directory");
    if (opt_mingw_src_path) |mingw_src_path| {
        const update_mingw_exe = b.addExecutable(.{
            .name = "update_mingw",
            .root_module = b.createModule(.{
                .target = b.graph.host,
                .root_source_file = b.path("tools/update_mingw.zig"),
            }),
        });
        const update_mingw_run = b.addRunArtifact(update_mingw_exe);
        update_mingw_run.addDirectoryArg(b.path("lib"));
        update_mingw_run.addDirectoryArg(.{ .cwd_relative = mingw_src_path });

        update_mingw_step.dependOn(&update_mingw_run.step);
    } else {
        update_mingw_step.dependOn(&b.addFail("The -Dmingw-src=... option is required for this step").step);
    }

    const test_incremental_step = b.step("test-incremental", "Run the incremental compilation test cases");
    try tests.addIncrementalTests(b, test_incremental_step);
    test_step.dependOn(test_incremental_step);
}

// ... rest of the file unchanged ...
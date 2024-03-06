const std = @import("std");
const Allocator = std.mem.Allocator;

const pdf_install_prefix = "share/";
const default_install_dir = "lhapdf-data/";
const default_install_dir_share = "lhapdf-data/share/";
const pdf_url_prefix = "https://lhapdfsets.web.cern.ch/current/";
const pdf_url_suffix = ".tar.gz";
const pdfs = [_][]const u8 {
    "EPPS21nlo_CT18Anlo_O16",
    "EPPS21nlo_CT18Anlo_Pb208"
};

 pub fn build(b: *std.Build) !void {
    // Initialise allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    // Get user-supplied target and optimize functions
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add option to set the data directory for LHAPDF
    const data_dir_path = b.option([]const u8, "data-dir", "");
    const install_pdfs = b.option(bool, "download-pdfs", "") orelse false;

    const data_dir = blk: {
        // Try to open user-supplied directory
        if (data_dir_path) |usr_data_dir_path| {
            const data_dir = std.fs.openDirAbsolute(usr_data_dir_path, .{}) catch |err| {
                std.debug.print("Could not open data_dir (path: \"{s}\"). Error: {s}\n", .{
                    usr_data_dir_path, @errorName(err)
                });
                return;
            };
            data_dir.makeDir(pdf_install_prefix) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => std.debug.print("Could not create dir {s}. Error: {s}", .{
                    try data_dir.realpathAlloc(alloc, pdf_install_prefix), @errorName(err) 
                })               
            };
            // Everything is perfect!
            break :blk data_dir.openDir(pdf_install_prefix, .{}) catch unreachable;
        }
        // The user did not specify a directory, we will make one ourselves
        const cwd = std.fs.cwd();
        try cwd.makePath(default_install_dir_share);
        break :blk try cwd.openDir(default_install_dir, .{});
    };

    if (install_pdfs) {
         try download_pdfs(alloc, data_dir);
    }

    // Load dependencies
    const yaml_cpp = b.dependency("yaml_cpp_fortrajectum", .{
        .target = target,
        .optimize = optimize
    });

    // Create compiled static library
    const lhapdf_cpp = b.addStaticLibrary(.{
        .name = "lhapdf-cpp-fortrajectum",
        .target = target,
        .optimize = optimize 
    });

    // Add dependency on yaml-cpp
    lhapdf_cpp.linkLibrary(yaml_cpp.artifact("yaml-cpp-fortrajectum"));

    // Add headers
    lhapdf_cpp.addIncludePath(.{ .path = "include/" });
    lhapdf_cpp.addIncludePath(.{ .path = yaml_cpp.builder.h_dir });

    // Add source files
    const cpp_src = try list_cpp_src(alloc, "src/");
    const cpp_flags = &.{"-std=c++11"};
    lhapdf_cpp.addCSourceFiles(cpp_src.items, cpp_flags);

    // Install headers
    lhapdf_cpp.installHeadersDirectory("include", "");

    //Install artifacts
    b.installArtifact(lhapdf_cpp);
}


/// This function traverses the `src_dir` and produces an `ArrayList` of all
/// non-main source files in the `src_dir`.
fn list_cpp_src(alloc: Allocator, src_dir: []const u8) !std.ArrayList([]u8) {
    var source_files = std.ArrayList([]u8).init(alloc);
    var walker = (try std.fs.cwd().openIterableDir(src_dir, .{})).iterate();
    while (try walker.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".cc")) {
            continue;
        }
        var source_path = std.ArrayList(u8).init(alloc);
        try source_path.appendSlice(src_dir);
        try source_path.appendSlice(entry.name);
        try source_files.append(try source_path.toOwnedSlice());
    }
    return source_files;
}

fn download_pdfs(alloc: Allocator, install_dir: std.fs.Dir) !void {
    var client = std.http.Client { .allocator = alloc };
    defer client.deinit();

    var headers = std.http.Headers.init(alloc);
    defer headers.deinit();
    try headers.append("accept", "*/*");
    
    for (pdfs) |pdf_name| {        
        // Generate the uri to the .tar.gz file on the CERN server
        const url_len = pdf_name.len + pdf_url_suffix.len + pdf_url_prefix.len;
        var url = try std.ArrayList(u8).initCapacity(alloc, url_len);
        defer url.deinit();
        try url.appendSlice(pdf_url_prefix);
        try url.appendSlice(pdf_name);
        try url.appendSlice(pdf_url_suffix);
        const uri = try std.Uri.parse(url.items);
        
        std.debug.print("Downloading {s}. This could take a while...\n", .{url.items});

        //Make the request
        var req = try client.request(std.http.Method.GET, uri, headers, .{});
        try req.start();
        try req.wait();
        const buf = try req.reader().readAllAlloc(alloc, std.math.maxInt(usize));

        std.debug.print("Finished downloading {s}. Received {} bytes.\n", .{pdf_name, buf.len});

        //  Write file to disk
        const path_len = pdf_install_prefix.len + pdf_install_prefix.len + pdf_url_suffix.len;
        var install_path = try std.ArrayList(u8).initCapacity(alloc, path_len);
        defer install_path.deinit();
        try install_path.appendSlice(pdf_install_prefix);
        try install_path.appendSlice(pdf_name);
        try install_path.appendSlice(pdf_url_suffix);
        const out_file = try std.fs.Dir.createFile(install_dir, install_path.items, .{});
        defer out_file.close();
        try out_file.writeAll(buf);

        std.debug.print("Installed {s}. Path: {s}\n", .{
            pdf_name,
            try install_dir.realpathAlloc(alloc, install_path.items) 
        });
    }
}

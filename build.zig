const std = @import("std");
const Allocator = std.mem.Allocator;

const default_ddir = "lhapdf-data";
const pdf_dir_rel = "LHAPDF"; //<- fixed in the cpp source!

const pdf_svr_baseurl = "https://lhapdfsets.web.cern.ch/current/";
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
    const root_dir = b.build_root.handle;
    const ddir_path = b.option([]const u8, "data-dir", "") orelse try init_default_ddir(alloc, root_dir);
    const install_pdfs = b.option(bool, "download-pdfs", "") orelse false;

    const pdf_dir_path = try init_pdfdir(alloc, root_dir, ddir_path);
    defer alloc.free(ddir_path);
    const pdf_dir = try std.fs.openDirAbsolute(pdf_dir_path, .{});

    if (install_pdfs) {
         try download_pdfs(alloc, pdf_dir);
    }

    // Load dependencies
    const yamlcpp = b.dependency("yamlcpp", .{
        .target = target,
        .optimize = optimize
    });

    // Create compiled static library
    const lhapdf = b.addStaticLibrary(.{
        .name = "lhapdf-fortrajectum",
        .target = target,
        .optimize = optimize 
    });

    // Add dependency on yaml-cpp
    lhapdf.linkLibrary(yamlcpp.artifact("yaml-cpp-fortrajectum"));

    // Add headers
    lhapdf.addIncludePath(.{ .path = "include/" });

    // Add source files
    const cpp_src = try list_cpp_src(alloc, try root_dir.openDir("src/", .{}));
    const cpp_flags = &.{
        "-std=c++11",
        b.fmt("-DLHAPDF_DATA_PREFIX=\"{s}\"", .{ ddir_path })
    };
    lhapdf.addCSourceFiles(cpp_src.items, cpp_flags);

    // Install headers
    lhapdf.installHeadersDirectory("include", "");

    //Install artifacts
    b.installArtifact(lhapdf);
}

fn init_default_ddir(alloc: Allocator, root: std.fs.Dir) ![]const u8 {
    const ddir = root.makeOpenPath(default_ddir, .{}) catch |err| {
        std.debug.print("[❌] Could create default data directory {s}. Err: \"{s}\"\n", .{
            default_ddir, @errorName(err)
        });
        return err;
    };
    const ddir_path = try ddir.realpathAlloc(alloc, ".");
    std.debug.print("[ℹ️] Using default data directory {s}\n", .{ ddir_path });
    return ddir_path;
}

fn init_pdfdir(alloc: Allocator, root: std.fs.Dir, ddir_path: []const u8) ![]const u8 {
    const ddir = std.fs.openDirAbsolute(ddir_path, .{}) catch |err| {
        std.debug.print("[❌] Could not open data-dir {s} (is it an absolute path?) Err: \"{s}\"\n", .{
            ddir_path, @errorName(err)
        });
        return err;
    };
    const pdf_dir = ddir.makeOpenPath(pdf_dir_rel, .{}) catch |err| {
        std.debug.print("[❌] Could not open pdf-dir {s}. Err: \"{s}\"", .{
            try ddir.realpathAlloc(alloc, pdf_dir_rel), @errorName(err)
        });
        return err;
    };

    // If pdf_dir/lhapdf.conf and pdf_dir/pdfsets.index do not exist, create them.
    _ = pdf_dir.access("lhapdf.conf", .{}) catch |err| switch (err) {
        error.FileNotFound => root.copyFile("lhapdf.conf", pdf_dir, "lhapdf.conf", .{}) catch |copyerr| {
            // Copy file from package root to pdf dir
            std.debug.print("[💣] THIS IS A BUG: packaging error", .{});
            return copyerr;
        },
        else => {
            std.debug.print("[❌] Cannot read lhapdf.conf file in pdf_dir. Err: \"{s}\"", .{ @errorName(err) });
            return err;
        } 
    };
    _ = pdf_dir.access("pdfsets.index", .{}) catch |err| switch (err) {
        error.FileNotFound => root.copyFile("pdfsets.index", pdf_dir, "pdfsets.index", .{}) catch |copyerr| {
            // Copy file from package root to pdf dir
            std.debug.print("[💣] THIS IS A BUG: packaging error", .{});
            return copyerr;
        },
        else => {
            std.debug.print("[❌] Cannot read pdfsets.index file in pdf_dir. Err: \"{s}\"", .{ @errorName(err) });
            return err;
        } 
    };

    // Return path to pdf_dir
    return try pdf_dir.realpathAlloc(alloc, ".");
}

/// This function traverses the `src_dir` and produces an `ArrayList` of all
/// non-main source files in the `src_dir`.
fn list_cpp_src(alloc: Allocator, src_dir: std.fs.Dir) !std.ArrayList([]u8) {
    var source_files = std.ArrayList([]u8).init(alloc);
    var walker = (try src_dir.openIterableDir(".", .{})).iterate();
    while (try walker.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".cc")) {
            continue;
        }
        try source_files.append(try src_dir.realpathAlloc(alloc, entry.name));
    }    
    return source_files;
}

fn download_pdfs(alloc: Allocator, pdf_dir: std.fs.Dir) !void {
    var client = std.http.Client { .allocator = alloc };
    defer client.deinit();

    var headers = std.http.Headers.init(alloc);
    defer headers.deinit();
    try headers.append("accept", "*/*");
    
    const pdf_dir_path = try pdf_dir.realpathAlloc(alloc, ".");
    defer alloc.free(pdf_dir_path);      
    
    for (pdfs) |pdf_name| {        
        // Generate the uri to the .tar.gz file on the CERN server
        const url = try std.fmt.allocPrint(alloc, "{s}{s}.tar.gz", .{ pdf_svr_baseurl, pdf_name });
        defer alloc.free(url);
        const uri = try std.Uri.parse(url);        
        std.debug.print("[📥] Downloading {s}. This could take a while...\n", .{url});

        //Make the request
        var req = try client.request(std.http.Method.GET, uri, headers, .{});
        try req.start();
        try req.wait();
        const httpreader = req.reader();

        // Decompress the file
        std.debug.print("[📂] Decompressing...\n", .{});
        var decompressed_reader = try std.compress.gzip.decompress(alloc, httpreader);
        defer decompressed_reader.deinit();

        // Write to file system
        try std.tar.pipeToFileSystem(pdf_dir, decompressed_reader.reader(), .{ .mode_mode = .ignore });
      
        std.debug.print("[✔️] Installed PDF \"{s}\" to {s}\n", .{ pdf_name, pdf_dir_path });
    }
}

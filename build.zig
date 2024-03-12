const std = @import("std");
const Allocator = std.mem.Allocator;

const default_ddir = "ddir";
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
    const usr_ddir_path = b.option([]const u8, "data-dir", "");
    const install_pdfs = b.option(bool, "download-pdfs", "") orelse false;

    // `ddir` is the root folder where all LHAPDF data is stored. `ddir/phf_dir` contains the actual
    // pdfs. If the user does not 
    const ddir = blk: {
        if (usr_ddir_path) |path| {
            break :blk std.fs.openDirAbsolute(path, .{}) catch |err| {
                std.debug.print("Could not open data-dir {s} (is it an absolute path?) Err: \"{s}\"\n", .{
                    path, @errorName(err)
                });
                return err;
            };
        } else {
            break :blk root_dir.makeOpenPath(default_ddir, .{}) catch |err| {
                 std.debug.print("Could not open default data-dir {s}. Err: \"{s}\"\n", .{
                    try root_dir.realpathAlloc(alloc, default_ddir), @errorName(err)
                });
                return err;
            };
        }
    };
    const pdf_dir = ddir.makeOpenPath(pdf_dir_rel, .{}) catch |err| {
        std.debug.print("Could not open pdf-dir {s}. Err: \"{s}\"", .{
            try ddir.realpathAlloc(alloc, pdf_dir_rel), @errorName(err)
        });
        return err;
    };
    const ddir_path = try ddir.realpathAlloc(alloc, ".",);
    defer alloc.free(ddir_path);

    if (install_pdfs) {
         try download_pdfs(alloc, pdf_dir);
    }

    // Load dependencies
    const yaml_cpp = b.dependency("yaml_cpp_fortrajectum", .{
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
    lhapdf.linkLibrary(yaml_cpp.artifact("yaml-cpp-fortrajectum"));

    // Add headers
    lhapdf.addIncludePath(.{ .path = "include/" });
    lhapdf.addIncludePath(.{ .path = yaml_cpp.builder.h_dir });

    // Add source files
    const cpp_src = try list_cpp_src(alloc, try root_dir.openDir("src/", .{}));
    const cpp_flags = &.{
        "-std=c++11",
        try std.fmt.allocPrint(alloc, "-DLHAPDF_DATA_PREFIX=\"{s}\"", .{ ddir_path })
    };
    lhapdf.addCSourceFiles(cpp_src.items, cpp_flags);

    // Install headers
    lhapdf.installHeadersDirectory("include", "");

    //Install artifacts
    b.installArtifact(lhapdf);
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
    
    for (pdfs) |pdf_name| {        
        // Generate the uri to the .tar.gz file on the CERN server
        const url = try std.fmt.allocPrint(alloc, "{s}{s}.tar.gz", .{ pdf_svr_baseurl, pdf_name });
        defer alloc.free(url);
        const uri = try std.Uri.parse(url);        
        std.debug.print("Downloading {s}. This could take a while...\n", .{url});

        //Make the request
        var req = try client.request(std.http.Method.GET, uri, headers, .{});
        try req.start();
        try req.wait();
        const buf = try req.reader().readAllAlloc(alloc, std.math.maxInt(usize));
        std.debug.print("Finished downloading {s}. Received {} bytes.\n", .{pdf_name, buf.len});

        //  Write file to disk
        const fout_name = try std.fmt.allocPrint(alloc, "{s}.tar.gz", .{ pdf_name });
        defer alloc.free(fout_name);
        const out_file = try std.fs.Dir.createFile(pdf_dir, fout_name, .{});
        defer out_file.close();
        try out_file.writeAll(buf);
    }
}

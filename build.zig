const std = @import("std");
const Allocator = std.mem.Allocator;

const default_ddir = "lhapdf-data";
const pdf_dir_rel = "LHAPDF"; //<- fixed in the cpp source!

const pdf_svr_baseurl = "https://lhapdfsets.web.cern.ch/current/";
const pdfs = [_][]const u8 {
    "EPPS21nlo_CT18Anlo_O16",
    "EPPS21nlo_CT18Anlo_Pb208"
};

const cpp_src = &.{
    "src/AlphaS_Analytic.cc",
    "src/AlphaS.cc",
    "src/AlphaS_Ipol.cc",
    "src/AlphaS_ODE.cc",
    "src/BicubicInterpolator.cc",
    "src/BilinearInterpolator.cc",
    "src/Config.cc",
    "src/ContinuationExtrapolator.cc",
    "src/ErrExtrapolator.cc",
    "src/Factories.cc",
    "src/FileIO.cc",
    "src/GridPDF.cc",
    "src/Info.cc",
    "src/Interpolator.cc",
    "src/KnotArray.cc",
    "src/LHAGlue.cc",
    "src/LogBicubicInterpolator.cc",
    "src/LogBilinearInterpolator.cc",
    "src/NearestPointExtrapolator.cc",
    "src/Paths.cc",
    "src/PDF.cc",
    "src/PDFIndex.cc",
    "src/PDFInfo.cc",
    "src/PDFSet.cc",
    "src/Utils.cc",
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
    lhapdf.addIncludePath(b.path("include"));

    // Add source files
    const cpp_flags = &.{
        "-std=c++11",
        b.fmt("-DLHAPDF_DATA_PREFIX=\"{s}\"", .{ ddir_path })
    };
    lhapdf.addCSourceFiles(.{.files = cpp_src, .flags = cpp_flags });

    // Install headers
    lhapdf.installHeadersDirectory(b.path("include"), "", .{});

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

fn download_pdfs(alloc: Allocator, pdf_dir: std.fs.Dir) !void {
    var client = std.http.Client { .allocator = alloc };
    defer client.deinit();

    const pdf_dir_path = try pdf_dir.realpathAlloc(alloc, ".");
    defer alloc.free(pdf_dir_path);      
    
    for (pdfs) |pdf_name| {        
        // Generate the uri to the .tar.gz file on the CERN server
        const url = try std.fmt.allocPrint(alloc, "{s}{s}.tar.gz", .{ pdf_svr_baseurl, pdf_name });
        defer alloc.free(url);
        std.debug.print("[📥] Downloading {s}. This could take a while...\n", .{url});

        //Make the request
        var response_buffer = std.ArrayList(u8).init(alloc);
        response_buffer.deinit();
        
        _ = try client.fetch(.{
            .method = std.http.Method.GET,
            .location = .{ .url = url },
            .response_storage = .{ .dynamic = &response_buffer },
            .max_append_size = 1_000_000_000
        });
        
        // Decompress the file
        std.debug.print("[📂] Decompressing...\n", .{});
        var buffer_stream = std.io.fixedBufferStream(response_buffer.items);
        var decomp = std.compress.gzip.decompressor(buffer_stream.reader());
        
        // Write to file system
        try std.tar.pipeToFileSystem(pdf_dir, &decomp.reader(), .{ .mode_mode = .ignore });
      
        std.debug.print("[✔️] Installed PDF \"{s}\" to {s}\n", .{ pdf_name, pdf_dir_path });
    }
}

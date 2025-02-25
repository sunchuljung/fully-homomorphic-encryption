# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Rules for generating FHE-C++."""

load(
    "//transpiler/data:primitives.bzl",
    "FHE_PRIMITIVES",
)

_FHE_TRANSPILER = "//transpiler"
_STRUCT_HEADER_GENERATOR = "//transpiler/struct_transpiler:struct_transpiler"
_XLSCC = "@com_google_xls//xls/contrib/xlscc:xlscc"
_XLSCC_DEFAULT_SYNTHESIS_HEADERS = "@com_google_xls//xls/contrib/xlscc:synth_only_headers"
_AC_DATATYPES = "@com_github_hlslibs_ac_types//:ac_types_as_data"
_XLS_BOOLEANIFY = "@com_google_xls//xls/tools:booleanify_main"
_XLS_OPT = "@com_google_xls//xls/tools:opt_main"
_GET_TOP_FUNC_FROM_PROTO = "@com_google_xls//xls/contrib/xlscc:get_top_func_from_proto"
_XLS_CODEGEN = "@com_google_xls//xls/tools:codegen_main"

_YOSYS = "@yosys//:yosys_bin"
_ABC = "@abc//:abc_bin"
_TFHE_CELLS_LIBERTY = "//transpiler:tfhe_cells.liberty"
_OPENFHE_CELLS_LIBERTY = "//transpiler:openfhe_cells.liberty"

FHE_ENCRYPTION_SCHEMES = {
    "tfhe": _TFHE_CELLS_LIBERTY,
    "openfhe": _OPENFHE_CELLS_LIBERTY,
    "cleartext": _TFHE_CELLS_LIBERTY,
}

FHE_OPTIMIZERS = [
    "xls",
    "yosys",
]

def _executable_attr(label):
    """A helper for declaring internal executable dependencies."""
    return attr.label(
        default = Label(label),
        allow_single_file = True,
        executable = True,
        cfg = "exec",
    )

def _run_with_stem(ctx, stem, inputs, out_ext, tool, args, entry = None):
    """A helper to run a shell script and capture the output.

    ctx:  The blaze context.
    stem: Stem for the output file.
    inputs: A list of files used by the shell.
    out_ext: An extension to add to the current label for the output file.
    tool: What tool to run.
    args: A list of arguments to pass to the tool.
    entry: If specified, it points to a file containing the entry point; that
           information is extracted and provided as value to the --top
           command-line switch.

    Returns:
      The File output.
    """
    out = ctx.actions.declare_file("%s%s" % (stem, out_ext))
    arguments = " ".join(args)
    if entry != None:
        arguments += " --top $(cat {})".format(entry.path)
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [out],
        tools = [tool],
        command = "%s %s > %s" % (tool.path, arguments, out.path),
    )
    return out

def _get_top_func(ctx, library_name, metadata_file):
    """Extract the name of the entry function from the metadata file."""
    return _run_with_stem(
        ctx,
        library_name,
        [metadata_file],
        ".entry",
        ctx.executable._get_top_func_from_proto,
        [metadata_file.path],
    )

def _get_cc_to_xls_ir_library_name(ctx):
    """Derive a stem from a file name (e.g., myfile.cc -- myfile)."""
    (library_name, _, _) = ctx.attr.src.label.name.rpartition(".cc")
    return library_name

def _build_ir(ctx, library_name):
    """Build the XLS IR from a C++ source.

    Args:
      ctx: The Blaze context.
      library_name: The stem for the output file.

    Returns:
      A File containing the generated IR and one containing metadata about
      the translated function (signature, etc.).
    """
    ir_file = ctx.actions.declare_file("%s.ir" % library_name)
    metadata_file = ctx.actions.declare_file("%s_meta.proto" % library_name)

    synth_only_header_dirs = {}
    for f in ctx.files._default_synthesis_header_files:
        synth_only_header_dirs[f.dirname] = True

    ac_datatypes_header_dirs = {}
    for f in ctx.files._ac_datatypes:
        ac_datatypes_header_dirs[f.dirname] = True

    xlscc_default_include_dirs = [
        "transpiler/data",
    ] + synth_only_header_dirs.keys() + [
        ctx.attr._ac_datatypes.label.workspace_root,
    ]  # This must the last directory in the list.

    # Append to user paths.
    xlscc_args = {}
    xlscc_args["include_dirs"] = ",".join(xlscc_default_include_dirs)

    # Append to user defines.
    xlscc_args["defines"] = (
        "__SYNTHESIS__"
    )

    default_args = ""
    for arg in xlscc_args:
        default_args += " --{arg}={val}".format(arg = arg, val = xlscc_args[arg])

    ctx.actions.run_shell(
        inputs = [ctx.file.src] + ctx.files.hdrs + ctx.files._default_synthesis_header_files + ctx.files._ac_datatypes,
        outputs = [ir_file, metadata_file],
        tools = [ctx.executable._xlscc],
        command = "%s %s -meta_out %s %s > %s" % (
            ctx.executable._xlscc.path,
            ctx.file.src.path,
            metadata_file.path,
            default_args,
            ir_file.path,
        ),
    )
    return (ir_file, metadata_file, _get_top_func(ctx, library_name, metadata_file))

def _generate_generic_struct_header(ctx, library_name, metadata, unwrap = []):
    """Transpile XLS C++ structs/classes into generic FHE base classes."""
    generic_struct_h = ctx.actions.declare_file("%s.generic.types.h" % library_name)

    args = [
        "-metadata_path",
        metadata.path,
        "-original_headers",
        ",".join([hdr.path for hdr in ctx.files.hdrs]),
        "-output_path",
        generic_struct_h.path,
    ]
    if len(unwrap):
        args += [
            "-unwrap",
            ",".join(unwrap),
        ]

    args += [
        "-skip",
        ",".join(["__xls_bits", "XlsIntBase"]),
        "-encoded_integer",
        "XlsIntBase",
    ]

    ctx.actions.run(
        inputs = [metadata],
        outputs = [generic_struct_h],
        executable = ctx.executable._struct_header_generator,
        arguments = args,
    )

    return generic_struct_h

XlsCcOutputInfo = provider(
    """The output of compiling C++ using XLScc.""",
    fields = {
        "ir": "XLS IR file generated by XLScc compiler",
        "metadata": "XLS IR protobuf by XLScc compiler",
        "metadata_entry": "Text file containing the entry point for the program",
        "generic_struct_header": "Templates for generic encodings of C++ structs in the source headers",
        "library_name": "Library name; if empty, stem is used to derive names.",
        "stem": "Name stem derived from input source C++ file (e.g., 'myfile' from 'myfile.cc'.)",
        "hdrs": "Input C++ headers",
    },
)

def _cc_to_xls_ir_impl(ctx):
    stem = _get_cc_to_xls_ir_library_name(ctx)
    library_name = ctx.attr.library_name or stem
    ir_file, metadata_file, metadata_entry_file = _build_ir(ctx, library_name)
    generic_struct_h = _generate_generic_struct_header(ctx, library_name, metadata_file, ctx.attr.unwrap)

    outputs = [
        ir_file,
        metadata_file,
        metadata_entry_file,
        generic_struct_h,
    ]

    return [
        DefaultInfo(files = depset(outputs)),
        XlsCcOutputInfo(
            ir = depset([ir_file]),
            metadata = depset([metadata_file]),
            metadata_entry = depset([metadata_entry_file]),
            generic_struct_header = depset([generic_struct_h]),
            library_name = library_name,
            stem = stem,
            hdrs = ctx.attr.hdrs,
        ),
    ]

cc_to_xls_ir = rule(
    doc = """
      This rule uses XLScc to tanspile C++ code to XLS IR.  It emits the IR
      file, the protobuf-metadata file, a file containing the entry point.  It
      also transpiles C++ structs/classes to generic FHE encodings.
      """,
    implementation = _cc_to_xls_ir_impl,
    attrs = {
        "src": attr.label(
            doc = "A single C++ source file to transpile.",
            allow_single_file = [".cc"],
        ),
        "hdrs": attr.label_list(
            doc = "Any headers necessary for conversion to XLS IR.",
            allow_files = [".h"],
        ),
        "library_name": attr.string(
            doc = """
            The name used for the output files (<library_name>.cc and <library_name>.h);
            If not specified, the default is derived from the basename of the source file.
            """,
        ),
        "unwrap": attr.string_list(
            doc = """
            A list of struct names to unwrap.  To unwrap a struct is defined
            only for structs that contain a single field.  When unwrapping a
            struct, its type is replaced by the type of its field.
            """,
        ),
        "_xlscc": _executable_attr(_XLSCC),
        "_default_synthesis_header_files": attr.label(
            doc = "Default synthesis header files for xlscc.",
            default = Label(_XLSCC_DEFAULT_SYNTHESIS_HEADERS),
        ),
        "_ac_datatypes": attr.label(
            doc = "AC datatypes used by default headers in xlscc.",
            default = Label(_AC_DATATYPES),
        ),
        "_get_top_func_from_proto": attr.label(
            default = Label(_GET_TOP_FUNC_FROM_PROTO),
            executable = True,
            cfg = "exec",
        ),
        "_struct_header_generator": _executable_attr(_STRUCT_HEADER_GENERATOR),
    },
)

def _optimize_ir(ctx, stem, src, extension, entry, options = []):
    """Optimize XLS IR."""
    return _run_with_stem(ctx, stem, [src, entry], extension, ctx.executable._xls_opt, [src.path] + options, entry)

def _booleanify_ir(ctx, stem, src, extension, entry):
    """Booleanify XLS IR."""
    return _run_with_stem(ctx, stem, [src, entry], extension, ctx.executable._xls_booleanify, ["--ir_path", src.path], entry)

def _optimize_and_booleanify_repeatedly(ctx, stem, ir_file, entry):
    """Runs several passes of optimization followed by booleanification.

    Returns [%.opt.ir, %.opt.bool.ir, %.opt.bool.opt.ir, %.opt.bool.opt.bool.ir, ...]
    """
    results = [ir_file]
    suffix = ""

    # With zero optimization passes, we still want to run the optimizer with an
    # inlining pass, as the booleanifier expects a single function.
    if ctx.attr.num_opt_passes == 0:
        suffix += ".opt"
        results.append(_optimize_ir(ctx, stem, results[-1], suffix + ".ir", entry, ["--run_only_passes=inlining"]))
        suffix += ".bool"
        results.append(_booleanify_ir(ctx, stem, results[-1], suffix + ".ir", entry))
    else:
        for _ in range(ctx.attr.num_opt_passes):
            suffix += ".opt"
            results.append(_optimize_ir(ctx, stem, results[-1], suffix + ".ir", entry))
            suffix += ".bool"
            results.append(_booleanify_ir(ctx, stem, results[-1], suffix + ".ir", entry))
    return results[1:]

def _pick_last_bool_file(optimized_files):
    """Pick the last booleanifed IR file from a list of file produced by _optimize_and_booleanify_repeatedly().

    The last %.*.bool.ir file may or may not be the smallest one.  For some IR
    inputs, an additional optimization/booleanification pass results in a
    larger file.  This is why we have num_opt_passes.
    """

    # structure is [%.opt.ir, %.opt.bool.ir, %.opt.bool.opt.ir,
    # %.opt.bool.opt.bool.ir, ...], so every other file is the result of an
    # optimization + booleanification pass.
    return optimized_files[-1]

BooleanifiedIrOutputInfo = provider(
    """The output of booleanifying XLS IR emitted by XLScc.""",
    fields = {
        "ir": "XLS IR file generated by XLScc compiler",
        "metadata": "XLS IR protobuf by XLScc compiler",
        "generic_struct_header": "Templates for generic encodings of C++ structs in the source headers",
        "hdrs": "Input C++ headers",
    },
)

BooleanifiedIrInfo = provider(
    """Non-file attributes passed forward from XlsCcOutputInfo.""",
    fields = {
        "library_name": "Library name; if empty, stem is used to derive names.",
        "stem": "Name stem derived from input source C++ file (e.g., 'myfile' from 'myfile.cc'.)",
        "optimizer": "Optimizer used to generate the IR",
    },
)

def _xls_ir_to_bool_ir_impl(ctx):
    src = ctx.attr.src
    ir_input = src[XlsCcOutputInfo].ir.to_list()[0]
    metadata_file = src[XlsCcOutputInfo].metadata.to_list()[0]
    metadata_entry_file = src[XlsCcOutputInfo].metadata_entry.to_list()[0]
    generic_struct_header = src[XlsCcOutputInfo].generic_struct_header.to_list()[0]
    library_name = src[XlsCcOutputInfo].library_name
    stem = src[XlsCcOutputInfo].stem

    optimized_files = _optimize_and_booleanify_repeatedly(ctx, library_name, ir_input, metadata_entry_file)
    ir_output = _pick_last_bool_file(optimized_files)

    return [
        DefaultInfo(files = depset(optimized_files + [ir_output] + src[DefaultInfo].files.to_list())),
        BooleanifiedIrOutputInfo(
            ir = depset([ir_output]),
            metadata = depset([metadata_file]),
            generic_struct_header = depset([generic_struct_header]),
            hdrs = depset(src[XlsCcOutputInfo].hdrs),
        ),
        BooleanifiedIrInfo(
            library_name = library_name,
            stem = stem,
            optimizer = "xls",
        ),
    ]

xls_ir_to_bool_ir = rule(
    doc = """
      This rule takes XLS IR output by XLScc and goes through zero or more
      phases of booleanification and optimization.  The output is an optimized
      booleanified XLS IR file.
      """,
    implementation = _xls_ir_to_bool_ir_impl,
    attrs = {
        "src": attr.label(
            providers = [XlsCcOutputInfo],
            doc = "A single XLS IR source file (emitted by XLScc).",
            mandatory = True,
        ),
        "num_opt_passes": attr.int(
            doc = """
            The number of optimization passes to run on XLS IR (default 1).
            Values <= 0 will skip optimization altogether.
            """,
            default = 1,
        ),
        "_xls_booleanify": _executable_attr(_XLS_BOOLEANIFY),
        "_xls_opt": _executable_attr(_XLS_OPT),
    },
)

VerilogOutputInfo = provider(
    """Files generated by the conversion of XLS IR to Verilog, as well as file
       attributes passed along from other providers.""",
    fields = {
        "verilog_ir_file": "Optimizer used to generate the IR",
        "metadata": "XLS IR protobuf by XLScc compiler",
        "metadata_entry": "Text file containing the entry point for the program",
        "generic_struct_header": "Templates for generic encodings of C++ structs in the source headers",
        "hdrs": "Input C++ headers",
    },
)

VerilogInfo = provider(
    """Non-file attributes passed along from other providers.""",
    fields = {
        "library_name": "Library name; if empty, stem is used to derive names.",
        "stem": "Name stem derived from input source C++ file (e.g., 'myfile' from 'myfile.cc'.)",
    },
)

def _xls_ir_to_verilog_impl(ctx):
    src = ctx.attr.src
    ir_input = src[XlsCcOutputInfo].ir.to_list()[0]
    metadata_file = src[XlsCcOutputInfo].metadata.to_list()[0]
    metadata_entry_file = src[XlsCcOutputInfo].metadata_entry.to_list()[0]
    generic_struct_header = src[XlsCcOutputInfo].generic_struct_header.to_list()[0]
    library_name = src[XlsCcOutputInfo].library_name
    stem = src[XlsCcOutputInfo].stem

    optimized_ir_file = _optimize_ir(ctx, library_name, ir_input, ".opt.ir", metadata_entry_file)
    verilog_ir_file = _generate_verilog(ctx, library_name, optimized_ir_file, ".v", metadata_entry_file)

    return [
        DefaultInfo(files = depset([optimized_ir_file, verilog_ir_file] + src[DefaultInfo].files.to_list())),
        VerilogOutputInfo(
            verilog_ir_file = depset([verilog_ir_file]),
            metadata = depset([metadata_file]),
            metadata_entry = depset([metadata_entry_file]),
            generic_struct_header = depset([generic_struct_header]),
            hdrs = depset(src[XlsCcOutputInfo].hdrs),
        ),
        VerilogInfo(
            library_name = library_name,
            stem = stem,
        ),
    ]

xls_ir_to_verilog = rule(
    doc = """
      This rule takes XLS IR output by XLScc and emits synthesizeable
      combinational Verilog."
      """,
    implementation = _xls_ir_to_verilog_impl,
    attrs = {
        "src": attr.label(
            providers = [XlsCcOutputInfo],
            doc = "A single XLS IR source file (emitted by XLScc).",
            mandatory = True,
        ),
        "_xls_opt": _executable_attr(_XLS_OPT),
        "_xls_codegen": _executable_attr(_XLS_CODEGEN),
    },
)

NetlistEncryptionInfo = provider(
    """Passes along the encryption attribute.""",
    fields = {
        "encryption": "Encryption scheme used",
    },
)

def _verilog_to_netlist_impl(ctx):
    src = ctx.attr.src
    metadata_file = src[VerilogOutputInfo].metadata.to_list()[0]
    metadata_entry_file = src[VerilogOutputInfo].metadata_entry.to_list()[0]
    verilog_ir_file = src[VerilogOutputInfo].verilog_ir_file.to_list()[0]
    generic_struct_header = src[VerilogOutputInfo].generic_struct_header.to_list()[0]
    library_name = src[VerilogInfo].library_name
    stem = src[VerilogInfo].stem

    name = stem + "_" + ctx.attr.encryption
    if stem != library_name:
        name = library_name
    netlist_file, yosys_script_file = _generate_netlist(ctx, name, verilog_ir_file, metadata_entry_file)

    outputs = [netlist_file, yosys_script_file]
    return [
        DefaultInfo(files = depset(outputs + src[DefaultInfo].files.to_list())),
        BooleanifiedIrOutputInfo(
            ir = depset([netlist_file]),
            metadata = depset([metadata_file]),
            generic_struct_header = depset([generic_struct_header]),
            hdrs = depset(src[VerilogOutputInfo].hdrs.to_list()),
        ),
        BooleanifiedIrInfo(
            library_name = library_name,
            stem = stem,
            optimizer = "yosys",
        ),
        NetlistEncryptionInfo(
            encryption = ctx.attr.encryption,
        ),
    ]

_verilog_to_netlist = rule(
    doc = """
      This rule takex XLS IR output by XLScc, and converts it to a Verilog
      netlist using the basic primitives defined in a cell library.
      """,
    implementation = _verilog_to_netlist_impl,
    attrs = {
        "src": attr.label(
            providers = [VerilogOutputInfo, VerilogInfo],
            doc = "A single XLS IR source file (emitted by XLScc).",
            mandatory = True,
        ),
        "encryption": attr.string(
            doc = """
            FHE encryption scheme used by the resulting program. Choices are
            {tfhe, openfhe, cleartext}. 'cleartext' means the program runs in cleartext,
            skipping encryption; this has zero security, but is useful for debugging.
            """,
            values = FHE_ENCRYPTION_SCHEMES.keys(),
            default = "tfhe",
        ),
        "cell_library": attr.label(
            doc = "A single cell-definition library in Liberty format.",
            allow_single_file = [".liberty"],
        ),
        "_yosys": _executable_attr(_YOSYS),
        "_abc": _executable_attr(_ABC),
    },
)

def verilog_to_netlist(name, src, encryption):
    if encryption in FHE_ENCRYPTION_SCHEMES:
        _verilog_to_netlist(name = name, src = src, encryption = encryption, cell_library = FHE_ENCRYPTION_SCHEMES[encryption])
    else:
        fail("Invalid encryption value:", encryption)

def _fhe_transpile_ir(ctx, library_name, stem, src, metadata, optimizer, encryption, encryption_specific_transpiled_structs_header, interpreter, skip_scheme_data_deps, unwrap):
    """Transpile XLS IR into C++ source."""

    if library_name == stem:
        name = stem + ("_yosys" if optimizer == "yosys" else "") + ("_interpreted" if interpreter else "") + "_" + encryption
    else:
        name = library_name
    out_cc = ctx.actions.declare_file("%s.cc" % name)
    out_h = ctx.actions.declare_file("%s.h" % name)

    args = [
        "-ir_path",
        src.path,
        "-metadata_path",
        metadata.path,
        "-cc_path",
        out_cc.path,
        "-header_path",
        out_h.path,
        "-optimizer",
        optimizer,
        "-encryption",
        encryption,
        "-encryption_specific_transpiled_structs_header_path",
        encryption_specific_transpiled_structs_header.short_path,
    ]
    if interpreter:
        args.append("-interpreter")
    if skip_scheme_data_deps:
        args.append("-skip_scheme_data_deps")
    if len(unwrap):
        args += [
            "-unwrap",
            ",".join(unwrap),
        ]

    ctx.actions.run(
        inputs = [src, metadata, encryption_specific_transpiled_structs_header],
        outputs = [out_cc, out_h],
        executable = ctx.executable._fhe_transpiler,
        arguments = args,
    )
    return [out_cc, out_h]

def _fhe_transpile_netlist(ctx, library_name, stem, src, metadata, optimizer, encryption, encryption_specific_transpiled_structs_header, interpreter, unwrap):
    """Transpile XLS IR into C++ source."""

    if library_name == stem:
        name = stem + ("_yosys" if optimizer == "yosys" else "") + ("_interpreted" if interpreter else "") + "_" + encryption
    else:
        name = library_name
    out_cc = ctx.actions.declare_file("%s.cc" % name)
    out_h = ctx.actions.declare_file("%s.h" % name)

    args = [
        "-ir_path",
        src.path,
        "-metadata_path",
        metadata.path,
        "-cc_path",
        out_cc.path,
        "-header_path",
        out_h.path,
        "-optimizer",
        optimizer,
        "-encryption",
        encryption,
        "-encryption_specific_transpiled_structs_header_path",
        encryption_specific_transpiled_structs_header.short_path,
    ]
    if interpreter:
        args.append("-interpreter")

    args += ["-liberty_path", ctx.file.cell_library.path]

    if len(unwrap):
        args += [
            "-unwrap",
            ",".join(unwrap),
        ]

    ctx.actions.run(
        inputs = [src, metadata, encryption_specific_transpiled_structs_header, ctx.file.cell_library],
        outputs = [out_cc, out_h],
        executable = ctx.executable._fhe_transpiler,
        arguments = args,
    )
    return [out_cc, out_h]

def _generate_encryption_specific_transpiled_structs_header_path(ctx, library_name, stem, metadata, generic_struct_header, encryption, unwrap = []):
    """Transpile XLS C++ structs/classes into scheme-specific FHE base classes."""
    header_name = stem + "_" + encryption
    if stem != library_name:
        header_name = library_name
    specific_struct_h = ctx.actions.declare_file("%s.types.h" % header_name)

    args = [
        "-metadata_path",
        metadata.path,
        "-output_path",
        specific_struct_h.path,
        "-generic_header_path",
        generic_struct_header.path,
        "-backend_type",
        encryption,
    ]
    if len(unwrap):
        args += [
            "-unwrap",
            ",".join(unwrap),
        ]

    args += [
        "-skip",
        ",".join(["__xls_bits", "XlsIntBase"]),
    ]

    ctx.actions.run(
        inputs = [metadata, generic_struct_header],
        outputs = [specific_struct_h],
        executable = ctx.executable._struct_header_generator,
        arguments = args,
    )

    return specific_struct_h

XlsCcTranspiledStructsOutputInfo = provider(
    """Provide file attribute representing scheme-specific transpiled-structs header.""",
    fields = {
        "encryption_specific_transpiled_structs_header": "Scheme-specific encodings of XLScc structs",
    },
)

def _xls_cc_transpiled_structs_impl(ctx):
    src = ctx.attr.src
    encryption = ctx.attr.encryption

    metadata = src[XlsCcOutputInfo].metadata.to_list()[0]
    generic_struct_header = src[XlsCcOutputInfo].generic_struct_header.to_list()[0]
    library_name = src[XlsCcOutputInfo].library_name
    stem = src[XlsCcOutputInfo].stem

    specific_struct_h = _generate_encryption_specific_transpiled_structs_header_path(
        ctx,
        library_name,
        stem,
        metadata,
        generic_struct_header,
        encryption,
        ctx.attr.unwrap,
    )

    return [
        DefaultInfo(files = depset([specific_struct_h])),
        XlsCcTranspiledStructsOutputInfo(
            encryption_specific_transpiled_structs_header = depset([specific_struct_h]),
        ),
    ]

xls_cc_transpiled_structs = rule(
    doc = """
      This rule produces transpiled C++ code that can be included in other
      libraries and binaries.
      """,
    implementation = _xls_cc_transpiled_structs_impl,
    attrs = {
        "src": attr.label(
            providers = [XlsCcOutputInfo],
            doc = "A target generated by rule cc_to_xls_ir",
            mandatory = True,
        ),
        "encryption": attr.string(
            doc = """
            FHE encryption scheme used by the resulting program. Choices are
            {tfhe, openfhe, cleartext}. 'cleartext' means the program runs in cleartext,
            skipping encryption; this has zero security, but is useful for debugging.
            """,
            values = FHE_ENCRYPTION_SCHEMES.keys(),
            default = "tfhe",
        ),
        "unwrap": attr.string_list(
            doc = """
            A list of struct names to unwrap.  To unwrap a struct is defined
            only for structs that contain a single field.  When unwrapping a
            struct, its type is replaced by the type of its field.
            """,
        ),
        "_struct_header_generator": _executable_attr(_STRUCT_HEADER_GENERATOR),
    },
)

def _generate_verilog(ctx, stem, src, extension, entry):
    """Convert optimized XLS IR to Verilog."""
    return _run_with_stem(
        ctx,
        stem,
        [src, entry],
        extension,
        ctx.executable._xls_codegen,
        [
            src.path,
            "--delay_model=unit",
            "--clock_period_ps=1000",
            "--generator=combinational",
            "--use_system_verilog=false",  # edit the YS script if this changes
        ],
        entry,
    )

def _generate_yosys_script(ctx, stem, verilog, netlist_path, entry):
    ys_script = ctx.actions.declare_file("%s.ys" % stem)
    sh_cmd = """cat>{script}<<EOF
# read_verilog -sv {verilog} # if we want to use SV
read_verilog {verilog}
hierarchy -check -top $(cat {entry})
proc; opt;
flatten; opt;
fsm; opt;
memory; opt
techmap; opt
dfflibmap -liberty {cell_library}
abc -liberty {cell_library}
opt_clean -purge
clean
write_verilog {netlist_path}
EOF
    """.format(
        script = ys_script.path,
        verilog = verilog.path,
        entry = entry.path,
        cell_library = ctx.file.cell_library.path,
        netlist_path = netlist_path,
    )

    ctx.actions.run_shell(
        inputs = [entry],
        outputs = [ys_script],
        command = sh_cmd,
    )

    return ys_script

def _generate_netlist(ctx, stem, verilog, entry):
    netlist = ctx.actions.declare_file("%s.netlist.v" % stem)

    script = _generate_yosys_script(ctx, stem, verilog, netlist.path, entry)

    yosys_runfiles_dir = ctx.executable._yosys.path + ".runfiles"

    args = ctx.actions.args()
    args.add("-q")  # quiet mode only errors printed to stderr
    args.add("-q")  # second q don't print warnings
    args.add("-Q")  # Don't print header
    args.add("-T")  # Don't print footer
    args.add_all("-s", [script.path])  # command execution

    ctx.actions.run(
        inputs = [verilog, script],
        outputs = [netlist],
        arguments = [args],
        executable = ctx.executable._yosys,
        tools = [ctx.file.cell_library, ctx.executable._abc],
        env = {
            "YOSYS_DATDIR": yosys_runfiles_dir + "/yosys/share/yosys",
        },
    )

    return (netlist, script)

FheIrLibraryOutputInfo = provider(
    """Provides the generates headers by the FHE transpiler, as well as the
       passed-along headers directly provided by the user.""",
    fields = {
        "hdrs": "Input C++ headers",
    },
)

def _cc_fhe_ir_library_impl(ctx):
    interpreter = ctx.attr.interpreter
    encryption = ctx.attr.encryption
    src = ctx.attr.src
    transpiled_structs = ctx.attr.transpiled_structs
    skip_scheme_data_deps = ctx.attr.skip_scheme_data_deps

    all_files = src[DefaultInfo].files
    ir = src[BooleanifiedIrOutputInfo].ir.to_list()[0]
    metadata = src[BooleanifiedIrOutputInfo].metadata.to_list()[0]
    library_name = src[BooleanifiedIrInfo].library_name
    stem = src[BooleanifiedIrInfo].stem
    optimizer = src[BooleanifiedIrInfo].optimizer
    generic_transpiled_structs_header = src[BooleanifiedIrOutputInfo].generic_struct_header.to_list()[0]
    encryption_specific_transpiled_structs_header = transpiled_structs[XlsCcTranspiledStructsOutputInfo].encryption_specific_transpiled_structs_header.to_list()[0]

    # Netlists need to be generated with knowledge of the encryption scheme,
    # since the scheme affects the choice of cell library.  Make sure that the
    # netlist was generated to target the correct encryption scheme.
    if NetlistEncryptionInfo in src:
        src_encryption = src[NetlistEncryptionInfo].encryption
        if encryption != src_encryption:
            fail("Netlist was not generated for the same encryption scheme! Expecting {} but src has {}.".format(encryption, src_encryption))

    if optimizer == "yosys":
        out_cc, out_h = _fhe_transpile_netlist(
            ctx,
            library_name,
            stem,
            ir,
            metadata,
            optimizer,
            encryption,
            encryption_specific_transpiled_structs_header,
            interpreter,
            FHE_PRIMITIVES,
        )
    else:
        out_cc, out_h = _fhe_transpile_ir(
            ctx,
            library_name,
            stem,
            ir,
            metadata,
            optimizer,
            encryption,
            encryption_specific_transpiled_structs_header,
            interpreter,
            skip_scheme_data_deps,
            FHE_PRIMITIVES,
        )

    input_headers = []
    for hdr in src[BooleanifiedIrOutputInfo].hdrs.to_list():
        input_headers.extend(hdr.files.to_list())

    output_hdrs = [
        out_h,
        generic_transpiled_structs_header,
        encryption_specific_transpiled_structs_header,
    ]
    outputs = [out_cc] + output_hdrs
    return [
        DefaultInfo(files = depset(outputs + all_files.to_list())),
        OutputGroupInfo(
            sources = depset([out_cc]),
            headers = depset(output_hdrs),
            input_headers = input_headers,
        ),
    ]

_cc_fhe_bool_ir_library = rule(
    doc = """
      This rule produces transpiled C++ code that can be included in other
      libraries and binaries.
      """,
    implementation = _cc_fhe_ir_library_impl,
    attrs = {
        "src": attr.label(
            providers = [BooleanifiedIrOutputInfo, BooleanifiedIrInfo],
            doc = "A single consumable IR source file.",
            mandatory = True,
        ),
        "transpiled_structs": attr.label(
            providers = [XlsCcTranspiledStructsOutputInfo],
            doc = "Target with scheme-specific encodings of XLScc data types",
            mandatory = True,
        ),
        "encryption": attr.string(
            doc = """
            FHE encryption scheme used by the resulting program. Choices are
            {tfhe, openfhe, cleartext}. 'cleartext' means the program runs in cleartext,
            skipping encryption; this has zero security, but is useful for debugging.
            """,
            values = FHE_ENCRYPTION_SCHEMES.keys(),
            default = "tfhe",
        ),
        "interpreter": attr.bool(
            doc = """
            Controls whether the resulting program executes directly (single-threaded C++),
            or invokes a multi-threaded interpreter.
            """,
            default = False,
        ),
        "skip_scheme_data_deps": attr.bool(
            doc = """
            When set to True, it causes the transpiler to not emit depednencies
            for tfhe_data.h, openfhe_data.h, and cleartext_data.h.  This is used
            to avoid circular dependencies when generating C++ libraries for
            the numeric primitives.
            """,
            default = False,
        ),
        "_fhe_transpiler": _executable_attr(_FHE_TRANSPILER),
    },
)

_cc_fhe_netlist_library = rule(
    doc = """
      This rule produces transpiled C++ code that can be included in other
      libraries and binaries.
      """,
    implementation = _cc_fhe_ir_library_impl,
    attrs = {
        "src": attr.label(
            providers = [BooleanifiedIrOutputInfo, BooleanifiedIrInfo, NetlistEncryptionInfo],
            doc = "A single consumable IR source file.",
            mandatory = True,
        ),
        "transpiled_structs": attr.label(
            providers = [XlsCcTranspiledStructsOutputInfo],
            doc = "Target with scheme-specific encodings of XLScc data types",
            mandatory = False,
        ),
        "encryption": attr.string(
            doc = """
            FHE encryption scheme used by the resulting program. Choices are
            {tfhe, openfhe, cleartext}. 'cleartext' means the program runs in cleartext,
            skipping encryption; this has zero security, but is useful for debugging.
            """,
            values = FHE_ENCRYPTION_SCHEMES.keys(),
            default = "tfhe",
        ),
        "interpreter": attr.bool(
            doc = """
            Controls whether the resulting program executes directly (single-threaded C++),
            or invokes a multi-threaded interpreter.
            """,
            default = False,
        ),
        "skip_scheme_data_deps": attr.bool(
            doc = """
            When set to True, it causes the transpiler to not emit depednencies
            for tfhe_data.h, openfhe_data.h, and cleartext_data.h.  This is used
            to avoid circular dependencies when generating C++ libraries for
            the numeric primitives.

            Always set to False when generating netlist libraries.
            """,
            default = False,
        ),
        "cell_library": attr.label(
            doc = "A single cell-definition library in Liberty format.",
            allow_single_file = [".liberty"],
        ),
        "_fhe_transpiler": _executable_attr(_FHE_TRANSPILER),
    },
)

def _cc_fhe_common_library(name, optimizer, src, transpiled_structs, encryption, interpreter, hdrs = [], copts = [], skip_scheme_data_deps = False, **kwargs):
    tags = kwargs.pop("tags", None)

    transpiled_files = "{}.transpiled_files".format(name)

    if encryption in FHE_ENCRYPTION_SCHEMES:
        if optimizer not in FHE_OPTIMIZERS:
            fail("Invalid optimizer:", optimizer)
        if optimizer == "xls":
            _cc_fhe_bool_ir_library(
                name = transpiled_files,
                src = src,
                transpiled_structs = transpiled_structs,
                encryption = encryption,
                interpreter = interpreter,
                skip_scheme_data_deps = skip_scheme_data_deps,
            )
        else:  # optimizer == "yosys":
            _cc_fhe_netlist_library(
                name = transpiled_files,
                src = src,
                transpiled_structs = transpiled_structs,
                encryption = encryption,
                interpreter = interpreter,
                cell_library = FHE_ENCRYPTION_SCHEMES[encryption],
                skip_scheme_data_deps = False,
            )
    else:
        fail("Invalid encryption value:", encryption)

    transpiled_source = "{}.srcs".format(name)
    native.filegroup(
        name = transpiled_source,
        srcs = [":" + transpiled_files],
        output_group = "sources",
        tags = tags,
    )

    transpiled_headers = "{}.hdrs".format(name)
    native.filegroup(
        name = transpiled_headers,
        srcs = [":" + transpiled_files],
        output_group = "headers",
        tags = tags,
    )

    input_headers = "{}.input.hdrs".format(name)
    native.filegroup(
        name = input_headers,
        srcs = [":" + transpiled_files],
        output_group = "input_headers",
        tags = tags,
    )

    deps = [
        "@com_google_xls//xls/common/logging",
        "@com_google_absl//absl/status",
        "@com_google_absl//absl/types:span",
        "@com_github_hlslibs_ac_types//:ac_int",
        "//transpiler:common_runner",
        "//transpiler/data:cleartext_value",
        "//transpiler/data:fhe_xls_int",
        "//transpiler/data:generic_value",
    ]

    if encryption == "cleartext":
        pass
    elif encryption == "tfhe":
        deps.extend([
            "@tfhe//:libtfhe",
            "//transpiler/data:tfhe_value",
        ])
    elif encryption == "openfhe":
        deps.extend([
            "@openfhe//:binfhe",
            "//transpiler/data:openfhe_value",
        ])

    if not skip_scheme_data_deps:
        if optimizer == "xls":
            if encryption == "cleartext":
                if interpreter:
                    fail("No XLS interpreter for cleartext is currently implemented.")
                deps.extend([
                    "//transpiler/data:cleartext_data",
                ])
            elif encryption == "tfhe":
                deps.extend([
                    "//transpiler/data:cleartext_data",
                    "//transpiler/data:tfhe_data",
                ])
                if interpreter:
                    deps.extend([
                        "@com_google_absl//absl/status:statusor",
                        "//transpiler:tfhe_runner",
                        "@com_google_xls//xls/common/status:status_macros",
                    ])
            elif encryption == "openfhe":
                deps.extend([
                    "//transpiler/data:cleartext_data",
                    "//transpiler/data:openfhe_data",
                ])
                if interpreter:
                    deps.extend([
                        "@com_google_absl//absl/status:statusor",
                        "//transpiler:openfhe_runner",
                        "@com_google_xls//xls/common/status:status_macros",
                    ])
        else:
            if not interpreter:
                fail("The Yosys pipeline only implements interpreter execution.")
            if encryption == "cleartext":
                deps.extend([
                    "@com_google_absl//absl/status:statusor",
                    "//transpiler:yosys_cleartext_runner",
                    "//transpiler/data:cleartext_data",
                    "@com_google_xls//xls/common/status:status_macros",
                ])
            elif encryption == "tfhe":
                deps.extend([
                    "@com_google_absl//absl/status:statusor",
                    "//transpiler:yosys_tfhe_runner",
                    "//transpiler/data:cleartext_data",
                    "//transpiler/data:tfhe_data",
                    "@com_google_xls//xls/common/status:status_macros",
                ])
            elif encryption == "openfhe":
                deps.extend([
                    "@com_google_absl//absl/status:statusor",
                    "//transpiler:yosys_openfhe_runner",
                    "//transpiler/data:cleartext_data",
                    "//transpiler/data:openfhe_data",
                    "@com_google_xls//xls/common/status:status_macros",
                ])

    native.cc_library(
        name = name,
        srcs = [":" + transpiled_source],
        hdrs = [":" + transpiled_headers, ":" + input_headers] + hdrs,
        copts = ["-O0"] + copts,
        tags = tags,
        deps = deps,
        **kwargs
    )

def cc_fhe_bool_ir_library(name, src, transpiled_structs, encryption, interpreter, copts = [], skip_scheme_data_deps = False, **kwargs):
    _cc_fhe_common_library(
        name = name,
        optimizer = "xls",
        src = src,
        transpiled_structs = transpiled_structs,
        encryption = encryption,
        interpreter = interpreter,
        copts = copts,
        skip_scheme_data_deps = skip_scheme_data_deps,
        **kwargs
    )

def cc_fhe_netlist_library(name, src, encryption, transpiled_structs, interpreter, copts = [], **kwargs):
    _cc_fhe_common_library(
        name = name,
        optimizer = "yosys",
        src = src,
        transpiled_structs = transpiled_structs,
        encryption = encryption,
        interpreter = interpreter,
        copts = copts,
        **kwargs
    )

def fhe_cc_library(
        name,
        src,
        hdrs,
        copts = [],
        num_opt_passes = 1,
        encryption = "tfhe",
        optimizer = "xls",
        interpreter = False,
        **kwargs):
    """A rule for building FHE-based cc_libraries.

    Example usage:
        fhe_cc_library(
            name = "secret_computation",
            src = "secret_computation.cc",
            hdrs = ["secret_computation.h"],
            num_opt_passes = 2,
            encryption = "cleartext",
            optimizer = "xls",
        )
        cc_binary(
            name = "secret_computation_consumer",
            srcs = ["main.cc"],
            deps = [":secret_computation"],
        )

    To generate just the transpiled sources, you can build the "<TARGET>.transpiled_files"
    subtarget; in the above example, you could run:
        blaze build :secret_computation.transpiled_files

    Args:
      name: The name of the cc_library target.
      src: The transpiler-compatible C++ file that are processed to create the library.
      hdrs: The list of header files required while transpiling the `src`.
      copts: The list of options to the C++ compilation command.
      num_opt_passes: The number of optimization passes to run on XLS IR (default 1).
            Values <= 0 will skip optimization altogether.
            (Only affects the XLS optimizer.)
      encryption: Defaults to "tfhe"; FHE encryption scheme used by the resulting program.
            Choices are {tfhe, openfhe, cleartext}. 'cleartext' means the program runs in
            cleartext, skipping encryption; this has zero security, but is useful for
            debugging.
      optimizer: Defaults to "xls"; optimizing/lowering pipeline to use in transpilation.
            Choices are {xls, yosys}. 'xls' uses the built-in XLS tools to transform the
            program into an optimized Boolean circuit; 'yosys' uses Yosys to synthesize
            a circuit that targets the given encryption. (In most cases, Yosys's optimizer
            is more powerful.)
      interpreter: Defaults to False; controls whether the resulting program executes
            directly (single-threaded C++), or invokes a multi-threaded interpreter.
      **kwargs: Keyword arguments to pass through to the cc_library target.
    """
    transpiled_xlscc_files = "{}.cc_to_xls_ir".format(name)
    cc_to_xls_ir(
        name = transpiled_xlscc_files,
        library_name = name,
        src = src,
        hdrs = hdrs,
    )

    transpiled_structs_headers = "{}.xls_cc_transpiled_structs".format(name)
    xls_cc_transpiled_structs(
        name = transpiled_structs_headers,
        src = ":" + transpiled_xlscc_files,
        encryption = encryption,
    )

    if optimizer not in FHE_OPTIMIZERS:
        fail("Invalid optimizer:", optimizer)

    if optimizer == "xls":
        optimized_intermediate_files = "{}.optimized_bool_ir".format(name)
        xls_ir_to_bool_ir(
            name = optimized_intermediate_files,
            src = ":" + transpiled_xlscc_files,
            num_opt_passes = num_opt_passes,
        )
        cc_fhe_bool_ir_library(
            name = name,
            src = ":" + optimized_intermediate_files,
            encryption = encryption,
            interpreter = interpreter,
            transpiled_structs = ":" + transpiled_structs_headers,
            copts = copts,
            **kwargs
        )
    else:
        verilog = "{}.verilog".format(name)
        xls_ir_to_verilog(
            name = verilog,
            src = ":" + transpiled_xlscc_files,
        )
        netlist = "{}.netlist".format(name)
        verilog_to_netlist(
            name = netlist,
            src = ":" + verilog,
            encryption = encryption,
        )
        cc_fhe_netlist_library(
            name = name,
            src = ":" + netlist,
            encryption = encryption,
            interpreter = interpreter,
            transpiled_structs = ":" + transpiled_structs_headers,
            copts = copts,
            **kwargs
        )

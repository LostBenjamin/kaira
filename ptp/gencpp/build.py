#
#    Copyright (C) 2011, 2012 Stanislav Bohm
#
#    This file is part of Kaira.
#
#    Kaira is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, version 3 of the License, or
#    (at your option) any later version.
#
#    Kaira is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with Kaira.  If not, see <http://www.gnu.org/licenses/>.
#


import base.utils as utils
import os.path
from writer import CppWriter, const_string

class Builder(CppWriter):

    def __init__(self, project, filename=None):
        CppWriter.__init__(self)
        self.filename = filename
        self.project = project

        # Real class used for thread representation,
        # CaThreadBase is cast to this type
        self.thread_class = "CaThread"

        # Generate operator== and operator!= for generated types
        # If true then all ExternTypes have to implement operator== and operator!=
        self.generate_operator_eq = False

        # Generate hash functions for generated types
        # If true then all ExternTypes have to implement get_hash
        self.generate_hash = False


def get_safe_id(string):
    return "__kaira__" + string

def get_to_string_function_name(project, t):
    """
    if t.name == "":
        return "{0}_as_string".format(t.get_safe_name())
    if len(t.args) == 0:
        etype = project.get_extern_type(t.name)
        if etype:
            return "{0}_getstring".format(etype.name)
    if t == t_string:
        return "ca_string_to_string"
    if t.name == "Array" and len(t.args) == 1:
        return "array_{0}_as_string".format(t.args[0].get_safe_name())
    if t == t_double:
        return "ca_double_to_string"
    if t == t_float:
        return "ca_float_to_string"
    if t == t_bool:
        return "ca_bool_to_string"
    return "ca_int_to_string"
    """

def get_hash_combination(codes):
    if not codes:
        return "113"
    numbers = [1, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71,
              73, 79, 83, 89, 97, 101, 103, 107, 109, 113]
    result = []
    for i, code in enumerate(codes):
        result.append("({0} * {1})".format(numbers[i % len(numbers)], code))

    return "^".join(result)

def get_code_as_string(project, expr, t):
    return "\"VALUE\""
    if t == t_string:
        return expr
    return "{0}({1})".format(get_to_string_function_name(project, t), expr)

def write_header(builder):
    builder.line("/* This file is automatically generated")
    builder.line("   do not edit this file directly! */")
    builder.emptyline()
    builder.line('#include <cailie.h>')
    builder.line('#include <algorithm>')
    builder.line('#include <stdlib.h>')
    builder.line('#include <stdio.h>')
    builder.line('#include <sstream>')
    builder.emptyline()
    write_parameters_forward(builder)
    builder.emptyline()
    if builder.project.get_head_code():
        builder.line_directive("*head", 1)
        builder.raw_text(builder.project.get_head_code())
        builder.line_directive(os.path.basename(builder.filename),
                                             builder.get_next_line_number())
        builder.emptyline()

def write_parameters_forward(builder):
    builder.line("struct param")
    builder.block_begin()
    for p in builder.project.get_parameters():
        builder.line("static CaParameterInt {0};", p.get_name())
    builder.write_class_end()

def write_parameters(builder):
    for p in builder.project.get_parameters():
        policy = "CA_PARAMETER_" + p.get_policy().upper()
        if p.get_policy() == "mandatory":
            default = ""
        else:
            default = ", " + p.default
        builder.line("CaParameterInt param::{0}({1}, {2}, {3}{4});",
                     p.name,
                     const_string(p.name),
                     const_string(p.description),
                     policy,
                     default)

def write_types(builder):
    write_extern_types_functions(builder, True)

def write_trace_user_function(builder, ufunction, type):
    declaration = "void trace_{0}(CaTraceLog *tracelog, const {1} &value)".format(
                                                    ufunction.get_name(), type)
    returntype = builder.emit_type(ufunction.get_returntype())
    code = "\t" + returntype + " result = ufunction_" + ufunction.get_name()
    n = len(ufunction.get_parameters())
    if n == 1:
        code += "(value);\n"
    else:
        code += "(" + ", ".join(["value.t{0}".format(i) for i in xrange(n)]) + ");\n"
    code += "\ttracelog->trace_{0}(result);\n".format(ufunction.get_returntype().name.lower())
    builder.write_function(declaration, code)

def write_trace_value(builder, type):
    """
    declaration = "void trace_value(CaTraceLog *tracelog, const {0} &value)".format(
                                                                        builder.emit_type(type))
    code = "\tstd::string result = {0}(value);\n".format(
            get_to_string_function_name(builder.project, type)) +\
            "\ttracelog->trace_string(result);\n"
    builder.write_function(declaration, code)
    """

def write_trace_user_functions(builder):
    traces = []
    value_traces = []
    for net in builder.project.nets:
        for place in net.places:
            for fn_name in place.tracing:
                if fn_name == "value":
                    if not place.type in value_traces:
                        value_traces.append(place.type)
                    continue
                if not (fn_name, place.type) in traces:
                    traces.append((fn_name, place.type))

    for type in value_traces:
        write_trace_value(builder, type)
    for fn_name, type in traces:
        fn = builder.project.get_user_function(fn_name.replace("fn: ", ""))
        write_trace_user_function(builder, fn, builder.emit_type(type))

def write_extern_types_functions(builder, definitions):
    decls = {
             "getstring" : "std::string {0.name}_getstring(const {0.rawtype} &obj)",
             "pack" : "void {0.name}_pack(CaPacker &packer, {0.rawtype} &obj)",
             "unpack" : "{0.rawtype} {0.name}_unpack(CaUnpacker &unpacker)",
             "hash" : "size_t {0.name}_hash(const {0.rawtype} &obj)",
    }

    def write_fn(etype, name):
        source = ("*{0}/{1}".format(etype.id, name), 1)
        if etype.get_code(name) is None:
            raise utils.PtpException(
                    "Function '{0}' for extern type '{1.name}' has no body defined" \
                        .format(name, etype))
        builder.write_function(decls[name].format(etype), etype.get_code(name), source)

    def declare_fn(etype, name):
        builder.line(decls[name].format(etype) + ";")

    if definitions:
        f = write_fn
    else:
        f = declare_fn

    for etype in builder.project.get_extern_types():
        if definitions and not etype.has_code("getstring"):
            builder.write_function(decls["getstring"].format(etype),
                "return {0};".format(const_string(etype.name)))
        else:
            f(etype, "getstring")

        if etype.get_transport_mode() == "Custom":
            if not etype.has_code("pack") or not etype.has_code("unpack"):
                raise utils.PtpException("Extern type has custom transport mode "
                                         "but pack/unpack missing.")
            f(etype, "pack")
            f(etype, "unpack")

        if etype.has_hash_function():
            f(etype, "hash")

def write_basic_definitions(builder):
    write_parameters(builder)
    write_types(builder)
    write_trace_user_functions(builder)

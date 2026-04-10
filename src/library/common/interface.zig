const std = @import("std");

const Struct = std.builtin.Type.Struct;
const StructField = std.builtin.Type.StructField;

pub const Self = struct {};

fn MapSelfType(comptime T: type, comptime NewSelf: type) type {
    return if (T == Self)
        @compileError("Cannot use Self without pointer")
    else if (T == *Self)
        return *NewSelf
    else if (T == *const Self)
        return *const NewSelf
    else
        T;
}

fn GeneralizedFunc(comptime F: type) type {
    const f_in = @typeInfo(F).@"fn";

    const Fn = std.builtin.Type.Fn;
    var f_out_params: [f_in.params.len]type = undefined;
    var param_attrs: [f_in.params.len]Fn.Param.Attributes = undefined;

    for (f_in.params, f_out_params, param_attrs) |pi, *out_param, *param_attr| {
        var po = pi;
        po.type = MapSelfType(
            pi.type orelse @compileError("No support for generic parameters!"),
            anyopaque,
        );
        out_param.* = po.type;
        param_attr.* = .{ .@"noalias" = po.is_noalias };
    }
    return @Fn(
        &f_out_params,
        &param_attrs,
        f_in.return_type orelse void,
        .{ .@"callconv" = f_in.calling_convention, .varargs = f_in.is_var_args },
    );
}

pub fn Interfaces(comptime spec: anytype) type {
    const Parameter = struct {
        source_type: type,
        generic_type: type,
        is_mapped: bool,
    };

    const Function = struct {
        name: [:0]const u8,
        spec_type: type,
        generic_type: type,
        spec_return: type,
        generic_return: type,
        return_is_mapped: bool,
        params: []const Parameter,
    };
    const spec_fields = comptime std.meta.fields(@TypeOf(spec));

    const functions = comptime blk: {
        var funcs: [spec_fields.len]Function = undefined;

        for (&funcs, spec_fields) |*fun, *sf| {
            const info = @typeInfo(@field(spec, sf.name)).@"fn";

            fun.* = Function{
                .name = sf.name,
                .spec_type = @field(spec, sf.name),
                .generic_type = GeneralizedFunc(@field(spec, sf.name)),
                .spec_return = info.return_type.?,
                .generic_return = MapSelfType(info.return_type.?, anyopaque),
                .params = &.{},
                .return_is_mapped = (info.return_type.? != MapSelfType(info.return_type.?, anyopaque)),
            };

            for (@typeInfo(fun.spec_type).@"fn".params, @typeInfo(fun.generic_type).@"fn".params) |sfn, gfn| {
                const param: Parameter = .{
                    .source_type = sfn.type.?,
                    .generic_type = gfn.type.?,
                    .is_mapped = (sfn.type.? != gfn.type.?),
                };

                fun.params = fun.params ++ [1]Parameter{param};
            }
        }

        break :blk funcs;
    };

    return struct {
        const Intf = @This();

        pub const VTable: type = blk: {
            var field_names: [functions.len][]const u8 = undefined;
            var field_attrs: [functions.len]std.builtin.Type.StructField.Attributes = undefined;
            var field_types: [functions.len]type = undefined;

            for (functions, field_names, field_attrs, field_types) |func, *name, *attrs, *field_type| {
                name.* = func.name;
                attrs.* = .{
                    .@"align" = @alignOf(*const func.generic_type),
                    .@"comptime" = false,
                    .default_value_ptr = null,
                };
                field_type.* = *const func.generic_type;
            }

            break :blk @Struct(
                .auto,
                null,
                &field_names,
                &field_types,
                &field_attrs,
            );
        };

        pub fn createVTable(comptime T: type) *const VTable {
            const Buffer = struct {
                const vtable: VTable = blk: {
                    var vt: VTable = undefined;

                    for (functions) |func| {
                        const src_func = @field(T, func.name);

                        const F = struct {
                            fn MappedArg(comptime i: comptime_int) type {
                                // @compileLog(func.name, i, func.params[i].generic_type, func.params[i].is_mapped);
                                return if (func.params[i].is_mapped)
                                    MapSelfType(func.params[i].source_type, anyopaque)
                                else
                                    func.params[i].generic_type;
                            }

                            fn mapArg(comptime i: comptime_int, value: MappedArg(i)) MapSelfType(func.params[i].source_type, T) {
                                return if (func.params[i].is_mapped)
                                    @ptrCast(@alignCast(value))
                                else
                                    return value;
                            }

                            fn mapResult(value: MapSelfType(func.spec_return, anyopaque)) MapSelfType(func.spec_return, T) {
                                return if (func.return_is_mapped)
                                    @ptrCast(@alignCast(value))
                                else
                                    return value;
                            }

                            const invoke = CallTranslator(
                                src_func,
                                MappedArg,
                                mapArg,
                                MapSelfType(func.spec_return, T),
                                mapResult,
                            ).invoke;
                        };

                        @field(vt, func.name) = F.invoke;
                    }

                    break :blk vt;
                };
            };
            return &Buffer.vtable;
        }
    };
}

fn CallTranslator(
    comptime target_func: anytype,
    comptime MappedArg: anytype,
    comptime mapArg: anytype,
    comptime MappedResult: type,
    comptime mapResult: anytype,
) type {
    const fi = @typeInfo(@TypeOf(target_func)).@"fn";
    return switch (fi.params.len) {
        0 => struct {
            pub fn invoke() MappedResult {
                return mapResult(target_func());
            }
        },
        1 => struct {
            pub fn invoke(a0: MappedArg(0)) MappedResult {
                return mapResult(target_func(mapArg(0, a0)));
            }
        },
        2 => struct {
            pub fn invoke(a0: MappedArg(0), a1: MappedArg(1)) MappedResult {
                return mapResult(target_func(mapArg(0, a0), mapArg(1, a1)));
            }
        },
        3 => struct {
            pub fn invoke(a0: MappedArg(0), a1: MappedArg(1), a2: MappedArg(2)) MappedResult {
                return mapResult(target_func(mapArg(0, a0), mapArg(1, a1), mapArg(2, a2)));
            }
        },
        4 => struct {
            pub fn invoke(a0: MappedArg(0), a1: MappedArg(1), a2: MappedArg(2), a3: MappedArg(3)) MappedResult {
                return mapResult(target_func(mapArg(0, a0), mapArg(1, a1), mapArg(2, a2), mapArg(3, a3)));
            }
        },
        5 => struct {
            pub fn invoke(a0: MappedArg(0), a1: MappedArg(1), a2: MappedArg(2), a3: MappedArg(3), a4: MappedArg(4)) MappedResult {
                return mapResult(target_func(mapArg(0, a0), mapArg(1, a1), mapArg(2, a2), mapArg(3, a3), mapArg(4, a4)));
            }
        },
        6 => struct {
            pub fn invoke(a0: MappedArg(0), a1: MappedArg(1), a2: MappedArg(2), a3: MappedArg(3), a4: MappedArg(4), a5: MappedArg(5)) MappedResult {
                return mapResult(target_func(mapArg(0, a0), mapArg(1, a1), mapArg(2, a2), mapArg(3, a3), mapArg(4, a4), mapArg(5, a5)));
            }
        },
        7 => struct {
            pub fn invoke(a0: MappedArg(0), a1: MappedArg(1), a2: MappedArg(2), a3: MappedArg(3), a4: MappedArg(4), a5: MappedArg(5), a6: MappedArg(6)) MappedResult {
                return mapResult(target_func(mapArg(0, a0), mapArg(1, a1), mapArg(2, a2), mapArg(3, a3), mapArg(4, a4), mapArg(5, a5), mapArg(6, a6)));
            }
        },
        8 => struct {
            pub fn invoke(a0: MappedArg(0), a1: MappedArg(1), a2: MappedArg(2), a3: MappedArg(3), a4: MappedArg(4), a5: MappedArg(5), a6: MappedArg(6), a7: MappedArg(7)) MappedResult {
                return mapResult(target_func(mapArg(0, a0), mapArg(1, a1), mapArg(2, a2), mapArg(3, a3), mapArg(4, a4), mapArg(5, a5), mapArg(6, a6), mapArg(7, a7)));
            }
        },
        9 => struct {
            pub fn invoke(a0: MappedArg(0), a1: MappedArg(1), a2: MappedArg(2), a3: MappedArg(3), a4: MappedArg(4), a5: MappedArg(5), a6: MappedArg(6), a7: MappedArg(7), a8: MappedArg(8)) MappedResult {
                return mapResult(target_func(mapArg(0, a0), mapArg(1, a1), mapArg(2, a2), mapArg(3, a3), mapArg(4, a4), mapArg(5, a5), mapArg(6, a6), mapArg(7, a7), mapArg(8, a8)));
            }
        },
        10 => struct {
            pub fn invoke(a0: MappedArg(0), a1: MappedArg(1), a2: MappedArg(2), a3: MappedArg(3), a4: MappedArg(4), a5: MappedArg(5), a6: MappedArg(6), a7: MappedArg(7), a8: MappedArg(8), a9: MappedArg(9)) MappedResult {
                return mapResult(target_func(mapArg(0, a0), mapArg(1, a1), mapArg(2, a2), mapArg(3, a3), mapArg(4, a4), mapArg(5, a5), mapArg(6, a6), mapArg(7, a7), mapArg(8, a8), mapArg(9, a9)));
            }
        },
        else => @compileError("Functions with more than {} args aren't supported yet!"),
    };
}

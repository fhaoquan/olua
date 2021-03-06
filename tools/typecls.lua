local olua = require "olua"

local typeinfo_map = {}
local class_map = {}

local format = olua.format

local message = ""

function olua.getclass(cls)
    return cls == '*' and class_map or class_map[cls]
end

function olua.message(msg)
    message = msg
end

function olua.error(fmt, ...)
    print("parse => " .. message)
    error(string.format(fmt, ...))
end

function olua.assert(cond, fmt, ...)
    if not cond then
        olua.error(fmt or '', ...)
    end
    return cond
end

local function pretty_typename(tn, trimref)
    tn = string.gsub(tn, '^ *', '') -- trim head space
    tn = string.gsub(tn, ' *$', '') -- trim tail space
    tn = string.gsub(tn, ' +', ' ') -- remove needless space

    -- const type * * => const type **
    tn = string.gsub(tn, ' *%*', '*')
    tn = string.gsub(tn, '%*+', " %1")

    tn = string.gsub(tn, ' *&', '&')
    tn = string.gsub(tn, '%&+', '%1')

    if trimref then
        tn = string.gsub(tn, ' *&+$', '') -- remove '&'
    end

    return tn
end

function olua.typeinfo(tn, cls, silence, variant)
    local ti, ref, subtis -- for tn<T, ...>

    tn = pretty_typename(tn, true)

    -- parse template
    if string.find(tn, '<') then
        subtis = {}
        for subtn in string.gmatch(string.match(tn, '<(.*)>'), '[^,]+') do
            subtis[#subtis + 1] = olua.typeinfo(subtn, cls, silence)
        end
        olua.assert(next(subtis), 'not found subtype')
        tn = pretty_typename(string.gsub(tn, '<.*>', ''))
    end

    ti = typeinfo_map[tn]

    if ti then
        ti = setmetatable({}, {__index = ti})
    else
        if not variant then
            -- try pointee
            if not ti and not string.find(tn, '%*$') then
                ti = olua.typeinfo(tn .. ' *', nil, true, true)
                ref = ti and tn or nil
            end

            -- try reference type
            if not ti and string.find(tn, '%*$') then
                ti = olua.typeinfo(tn:gsub('[ *]+$', ''), nil, true, true)
                ref = ti and tn or nil
            end
        end

        -- search in class namespace
        if not ti and cls and cls.CPPCLS then
            local nsarr = {}
            for ns in string.gmatch(cls.CPPCLS, '[^:]+') do
                nsarr[#nsarr + 1] = ns
            end
            while #nsarr > 0 do
                -- const Object * => const ns::Object *
                local ns = table.concat(nsarr, "::")
                local nstn = pretty_typename(string.gsub(tn, '[%w:_]+ *%**$', ns .. '::%1'), true)
                local nsti = olua.typeinfo(nstn, nil, true)
                nsarr[#nsarr] = nil
                if nsti then
                    ti = nsti
                    tn = nstn
                    break
                end
            end
        end

        -- search in super class namespace
        if not ti and cls and cls.SUPERCLS then
            local super = class_map[cls.SUPERCLS]
            olua.assert(super, "super class '%s' of '%s' is not found", cls.SUPERCLS, cls.CPPCLS)
            local sti, stn = olua.typeinfo(tn, super, true)
            if sti then
                ti = sti
                tn = stn
            end
        end
    end

    if ti then
        ti.SUBTYPES = subtis or ti.SUBTYPES
        ti.VARIANT = (ref ~= nil) or ti.VARIANT
        return ti, tn
    elseif not silence then
        olua.error("type info not found: %s", tn)
    end
end

--[[
    function arg variable must declared with no const type

    eg: Object::call(const std::vector<A *> arg1)

    Object *self = nullptr;
    std::vector<int> arg1;
    olua_to_cppobj(L, 1, (void **)&self, "Object");
    olua_check_std_vector(L, 2, arg1, "A");
    self->call(arg1);
]]
local function todecltype(cls, typename, isvariable)
    local reference = string.match(typename, '&+')
    local ti, tn = olua.typeinfo(typename, cls)

    if ti.SUBTYPES then
        local arr = {}
        for i, v in ipairs(ti.SUBTYPES) do
            arr[i] = v.CPPCLS
        end
        tn = string.format('%s<%s>', tn, table.concat(arr, ', '))
        if isvariable then
            tn = string.gsub(tn, 'const *', '')
        end
    end

    if not isvariable and reference then
        tn = tn .. ' ' .. reference
    end

    return tn
end

--
-- parse type attribute and return the rest of string
-- eg: @delref(cmp children) void removeChild(@addref(map children) child)
-- reutrn: {DELREF={cmp, children}}, void removeChild(@addref(map children) child)
--
local function parse_attr(str)
    local attr = {}
    local static
    str = string.gsub(str, '^ *', '')
    while true do
        local name, value = string.match(str, '^@(%w+)%(([^)]+)%)')
        if name then
            local arr = {}
            for v in string.gmatch(value, '[^ ]+') do
                arr[#arr + 1] = v
            end
            attr[string.upper(name)] = arr
            str = string.gsub(str, '^@(%w+)%(([^)]+)%)', '')
        else
            name = string.match(str, '^@(%w+)')
            if name then
                attr[string.upper(name)] = {}
                str = string.gsub(str, '^@%w+', '')
            else
                break
            end
        end
        str = string.gsub(str, '^ *', '')
    end
    str, static = string.gsub(str, '^ *static *', '')
    attr.STATIC = static > 0
    return attr, str
end

local function parse_type(str)
    local attr, tn
    attr, str = parse_attr(str)
    -- str = std::function <void (float int)> &arg, ...
    tn = string.match(str, '^[%w_: ]+%b<>[ &*]*') -- parse template type
    if not tn then
        local from, to
        while true do
            from, to = string.find(str, ' *[%w_:]+[ &*]*', to)
            if not from then
                break
            end
            tn = pretty_typename(string.sub(str, from, to))
            if tn == 'signed' or tn == 'unsigned' then
                local substr = string.sub(str, to + 1)
                -- str = unsigned count = 1, ... ?
                if not (substr:find('^ *int *')
                    or substr:find('^ *short *')
                    or substr:find('^ *char *')) then
                    tn = string.sub(str, 1, to) .. ' int'
                    str = string.sub(str, to + 1)
                    return pretty_typename(tn), attr, str
                end
            end
            if tn ~= 'const' and tn ~= 'signed' and tn ~= 'unsigned' then
                if tn == 'struct' then
                    str = string.sub(str, to + 1)
                else
                    tn = string.sub(str, 1, to)
                    break
                end
            end
        end
    end
    str = string.sub(str, #tn + 1)
    str = string.gsub(str, '^ *', '')
    return pretty_typename(tn), attr, str
end

local parse_args

local function parse_callback_type(cls, tn)
    local rtn, rtattr
    local declstr = string.match(tn, '<(.*)>') -- match callback function prototype
    rtn, rtattr, declstr = parse_type(declstr)
    declstr = string.gsub(declstr, '^[^(]+', '') -- match callback args

    local args = parse_args(cls, declstr)
    local decltype = {}
    for _, ai in ipairs(args) do
        decltype[#decltype + 1] = ai.RAWDECL
    end
    decltype = table.concat(decltype, ", ")
    decltype = string.format('std::function<%s(%s)>', todecltype(cls, rtn), decltype)

    local RET = {}
    RET.TYPE = olua.typeinfo(rtn, cls)
    RET.DECLTYPE = todecltype(cls, rtn)
    RET.ATTR = rtattr

    return {
        ARGS = args,
        RET = RET,
        DECLTYPE = decltype,
    }
end

--[[
    arg struct: void func(@pack const std::vector<int> &points = value)
    {
        TYPE             -- type info
        DECLTYPE         -- decltype: std::vector<int>
        RAWDECL          -- rawdecl: const std::vector<int> &
        VAR_NAME         -- var name: points
        ATTR             -- attr: {PACK = true}
        CBTYPE = {       -- eg: std::function<void (float, const A *a)>
            ARGS         -- callback functions args: float, A *a
            RET          -- return type info: void type info
            DECLTYPE     -- std::function<void (float, const A *)>
        }
    }
]]
function parse_args(cls, declstr)
    local args = {}
    local count = 0
    declstr = string.match(declstr, '%((.*)%)')
    olua.assert(declstr, 'malformed args string')

    while #declstr > 0 do
        local tn, attr, varname, default, _, to
        tn, attr, declstr = parse_type(declstr)
        if tn == 'void' then
            return args, count
        end

        -- match: x = Point(0, 0), bool b, ...)
        _, to, varname, default = string.find(declstr, '^([^ ]+) *= *([%w_:]+%b())')

        -- match: x = 3, bool b, ...)
        if not varname then
            _, to, varname, default = string.find(declstr, '^([^ ]+) *= *([^ ,]*)')
        end

        -- match: x, bool b, ...)
        if not varname then
            _, to, varname = string.find(declstr, '^([^ ,]+)')
        end

        if varname then
            declstr = string.sub(declstr, to + 1)
        end

        declstr = string.gsub(declstr, '^[^,]*,? *', '') -- skip ','

        if default and not string.find(default, '^"') and string.find(default, '[():]') then
            -- match: Point(0, 2) => Point
            local dtn = string.match(default, '^([^(]+)%(')
            if not dtn then
                -- match: Point::Zero => Point
                dtn = string.match(default, '^(.*)::[%w_]+')
            end
            olua.assert(dtn, 'unknown default value format: %s', default)
            local dti = olua.typeinfo(dtn, cls, true) or olua.typeinfo(dtn .. ' *', cls)
            default = string.gsub(default, dtn, dti.CPPCLS)
        end

        if attr.OUT then
            if string.find(tn, '%*$') then
                attr.OUT = 'pointee'
                tn = string.gsub(tn, '%*$', '')
                tn = pretty_typename(tn)
            end
        end

        if default then
            attr.OPTIONAL = true
        end

        -- is callback
        if string.find(tn, 'std::function<') then
            local cbtype = parse_callback_type(cls, tn)
            args[#args + 1] = {
                TYPE = setmetatable({
                    DECLTYPE = cbtype.DECLTYPE,
                }, {__index = olua.typeinfo('std::function', cls)}),
                DECLTYPE = cbtype.DECLTYPE,
                VAR_NAME = varname or '',
                ATTR = attr,
                CBTYPE = cbtype,
            }
        else
            args[#args + 1] = {
                TYPE = olua.typeinfo(tn, cls),
                DECLTYPE = todecltype(cls, tn, true),
                RAWDECL = todecltype(cls, tn),
                VAR_NAME = varname or '',
                ATTR = attr,
            }
        end

        local num_vars = args[#args].TYPE.NUM_VARS or 1
        if attr.PACK and num_vars > 0 then
            count = count + olua.assert(num_vars, args[#args].TYPE.CPPCLS)
        else
            count = count + 1
        end
    end

    return args, count
end

function olua.funcname(declfunc)
    local _, _, str = parse_type(declfunc)
    return string.match(str, '[^ ()]+')
end

local function gen_func_prototype(cls, fi)
    -- generate function prototype: void func(int, A *, B *)
    local DECL_ARGS = olua.newarray(', ')
    local STATIC = fi.STATIC and "static " or ""
    for _, v in ipairs(fi.ARGS) do
        DECL_ARGS:push(v.DECLTYPE)
    end
    fi.PROTOTYPE = format([[
        ${STATIC}${fi.RET.DECLTYPE} ${fi.CPP_FUNC}(${DECL_ARGS})
    ]])
    cls.PROTOTYPES[fi.PROTOTYPE] = true
end

local function gen_func_pack(cls, fi, funcs)
    local has_pack = false
    for i, arg in ipairs(fi.ARGS) do
        if arg.ATTR.PACK then
            has_pack = true
            break
        end
    end
    -- has @pack? gen one more func
    if has_pack then
        local packarg
        local newfi = olua.copy(fi)
        newfi.RET = olua.copy(fi.RET)
        newfi.RET.ATTR = olua.copy(fi.RET.ATTR)
        newfi.ARGS = {}
        newfi.FUNC_DECL = string.gsub(fi.FUNC_DECL, '@pack *', '')
        for i in ipairs(fi.ARGS) do
            newfi.ARGS[i] = olua.copy(fi.ARGS[i])
            newfi.ARGS[i].ATTR = olua.copy(fi.ARGS[i].ATTR)
            if fi.ARGS[i].ATTR.PACK then
                assert(not packarg, 'too many pack args')
                packarg = fi.ARGS[i]
                newfi.ARGS[i].ATTR.PACK = false
                local num_vars = packarg.TYPE.NUM_VARS
                if num_vars and num_vars > 1 then
                    newfi.MAX_ARGS = newfi.MAX_ARGS + 1 - num_vars
                end
            end
        end
        if packarg.TYPE.CPPCLS == fi.RET.TYPE.CPPCLS then
            newfi.RET.ATTR.UNPACK = fi.RET.ATTR.UNPACK or false
            fi.RET.ATTR.UNPACK = true
        end
        gen_func_prototype(cls, newfi)
        funcs[#funcs + 1] = newfi
        newfi.INDEX = #funcs
    end
end

local function gen_func_overload(cls, fi, funcs)
    local min_args = math.maxinteger
    for i, arg in ipairs(fi.ARGS) do
        if arg.ATTR.OPTIONAL then
            min_args = i - 1
            break
        end
    end
    for i = min_args, #fi.ARGS - 1 do
        local newfi = olua.copy(fi)
        newfi.ARGS = {}
        newfi.INSERT = {}
        for k = 1, i do
            newfi.ARGS[k] = olua.copy(fi.ARGS[k])
        end
        gen_func_prototype(cls, newfi)
        newfi.MAX_ARGS = i
        newfi.INDEX = #funcs + 1
        funcs[newfi.INDEX] = newfi
    end
end

local function parse_func(cls, name, ...)
    local arr = {MAX_ARGS = 0}
    for _, declfunc in ipairs({...}) do
        local fi = {RET = {}}
        olua.message(declfunc)
        if string.find(declfunc, '{') then
            fi.LUA_FUNC = assert(name)
            fi.CPP_FUNC = name
            fi.SNIPPET = olua.trim(declfunc)
            fi.FUNC_DECL = '<function snippet>'
            fi.RET.TYPE = olua.typeinfo('void', cls)
            fi.RET.ATTR = {}
            fi.ARGS = {}
            fi.INSERT = {}
            fi.PROTOTYPE = false
            fi.MAX_ARGS = #fi.ARGS
        else
            local typename, attr, str = parse_type(declfunc)
            local ctor = string.match(cls.CPPCLS, '[^:]+$')
            if typename == ctor and string.find(str, '^%(') then
                typename = typename .. ' *'
                str = 'new' .. str
                fi.CTOR = true
                attr.STATIC = true
            end
            fi.CPP_FUNC = string.match(str, '[^ ()]+')
            fi.LUA_FUNC = name or fi.CPP_FUNC
            fi.STATIC = attr.STATIC
            fi.FUNC_DECL = declfunc
            fi.INSERT = {}
            if string.find(typename, 'std::function<') then
                local cbtype = parse_callback_type(cls, typename, nil)
                fi.RET = {
                    TYPE = setmetatable({
                        DECLTYPE = cbtype.DECLTYPE,
                    }, {__index = olua.typeinfo('std::function', cls)}),
                    DECLTYPE = cbtype.DECLTYPE,
                    ATTR = attr,
                    CBTYPE = cbtype,
                }
            else
                fi.RET.TYPE = olua.typeinfo(typename, cls)
                fi.RET.DECLTYPE = todecltype(cls, typename)
                fi.RET.ATTR = attr
            end
            fi.ARGS, fi.MAX_ARGS = parse_args(cls, string.sub(str, #fi.CPP_FUNC + 1))
            gen_func_prototype(cls, fi)
            gen_func_pack(cls, fi, arr)
        end
        arr[#arr + 1] = fi
        arr.MAX_ARGS = math.max(arr.MAX_ARGS, fi.MAX_ARGS)
        fi.INDEX = #arr
    end

    return arr
end

local function topropfn(cppfunc, prefix)
    return prefix .. string.gsub(cppfunc, '^%w', function (s)
        return string.upper(s)
    end)
end

local function parse_prop(cls, name, declget, declset)
    local pi = {}
    pi.NAME = assert(name, 'no prop name')

    -- eg: name = url
    -- try getUrl and getURL
    -- try setUrl and setURL
    local name2 = string.gsub(name, '^%l+', function (s)
        return string.upper(s)
    end)

    local function test(fi, name, op)
        name = topropfn(name, op)
        if name == fi.CPP_FUNC or name == fi.LUA_FUNC then
            return true
        else
            -- getXXXXS => getXXXXs?
            name = name:sub(1, #name - 1) .. name:sub(#name):lower()
            return name == fi.CPP_FUNC or name == fi.LUA_FUNC
        end
    end

    if declget then
        pi.GET = declget and parse_func(cls, name, declget)[1] or nil
    else
        for _, v in ipairs(cls.FUNCS) do
            local fi = v[1]
            if test(fi, name, 'get') or test(fi, name, 'is') or
                test(fi, name2, 'get') or test(fi, name2, 'is') then
                olua.message(fi.FUNC_DECL)
                olua.assert(#fi.ARGS == 0, "function '%s::%s' has arguments", cls.CPPCLS, fi.CPP_FUNC)
                pi.GET = fi
                break
            end
        end
        assert(pi.GET, name)
    end

    if declset then
        pi.SET = declset and parse_func(cls, name, declset)[1] or nil
    else
        for _, v in ipairs(cls.FUNCS) do
            local fi = v[1]
            if test(fi, name, 'set') or test(fi, name2, 'set') then
                pi.SET = fi
                break
            end
        end
    end

    if not pi.GET.SNIPPET then
        assert(pi.GET.RET.TYPE.CPPCLS ~= 'void', declget)
    elseif declget then
        pi.GET.CPP_FUNC = 'get_' .. pi.GET.CPP_FUNC
    end

    if pi.SET and pi.SET.SNIPPET and declset then
        pi.SET.CPP_FUNC = 'set_' .. pi.SET.CPP_FUNC
    end

    return pi
end

function olua.typecls(cppcls)
    local cls = {
        CPPCLS = cppcls,
        CPP_SYM = string.gsub(cppcls, '[.:]+', '_'),
        FUNCS = {},
        CONSTS = {},
        ENUMS = {},
        PROPS = {},
        VARS = {},
        PROTOTYPES = {},
    }
    class_map[cls.CPPCLS] = cls

    function cls.func(name, ...)
        cls.FUNCS[#cls.FUNCS + 1] = parse_func(cls, name, ...)

        local arr = cls.FUNCS[#cls.FUNCS]
        for idx = 1, #arr do
            gen_func_overload(cls, arr[idx], arr)
        end
    end

    --[[
        {
            ...
            std::function<void (float)> argN = [storeobj, func](float v) {
                ...
                ${CALLBACK_BEFORE}
                olua_callback(L, ...)
                ${CALLBACK_AFTER}
            };
            ...
            ${BEFORE}
            self->callfunc(arg1, arg2, ....);
            ${AFTER}
            ...
        return 1;
        }
    ]]
    function cls.insert(cppfunc, codes)
        local funcs = type(cppfunc) == "string" and {cppfunc} or cppfunc
        local found
        local function format_code(code)
            return code and format(code) or nil
        end
        local function apply_insert(fi, testname)
            if fi and (fi.CPP_FUNC == cppfunc or (testname and fi.LUA_FUNC == cppfunc))then
                found = true
                fi.INSERT.BEFORE = format_code(codes.BEFORE)
                fi.INSERT.AFTER = format_code(codes.AFTER)
                fi.INSERT.CALLBACK_BEFORE = format_code(codes.CALLBACK_BEFORE)
                fi.INSERT.CALLBACK_AFTER = format_code(codes.CALLBACK_AFTER)
            end
        end

        for _, v in ipairs(funcs) do
            cppfunc = v
            for _, arr in ipairs(cls.FUNCS) do
                for _, fi in ipairs(arr) do
                    apply_insert(fi)
                end
            end
            for _, pi in ipairs(cls.PROPS) do
                apply_insert(pi.GET)
                apply_insert(pi.SET)
            end
            for _, vi in ipairs(cls.VARS) do
                apply_insert(vi.GET, true)
                apply_insert(vi.SET, true)
            end
        end

        olua.assert(found, 'function not found: %s::%s', cls.CPPCLS, cppfunc)
    end

    function cls.alias(func, aliasname)
        local funcs = {}
        for _, arr in ipairs(cls.FUNCS) do
            for _, fi in ipairs(arr) do
                if fi.LUA_FUNC == func then
                    funcs[#funcs + 1] = setmetatable({LUA_FUNC = assert(aliasname)}, {__index = fi})
                end
            end
            if #funcs > 0 then
                cls.FUNCS[#cls.FUNCS + 1] = funcs
                return
            end
        end

        error('func not found: ' .. func)
    end

    --[[
        {
            TAG_MAKER    -- make callback key
            TAG_MODE     -- how to store or remove function
            TAG_STORE    -- where to store or remove function
            TAG_SCOPE    -- once, function, object
                            * once      remove after callback invoked
                            * function  remove after function invoked
                            * object    callback will exist until object die
            REMOVE       -- remove function
        }

        TAG: .callback#[id++]@tag

        userdata.uservalue {
            .callback#0@click = clickfunc1,
            .callback#1@click = clickfunc2,
            .callback#2@remove = removefunc,
        }

        remove all callback:
            {TAG_MAKER = "", TAG_MODE = "OLUA_TAG_SUBSTARTWITH", REMOVE = true}

        remove click callback:
            {TAG_MAKER = "click", TAG_MODE = "OLUA_TAG_SUBEQUAL", REMOVE = true}

        add new callback:
            {TAG_MAKER = 'click', TAG_MODE = "OLUA_TAG_NEW"}

        replace previous callback:
            {TAG_MAKER = 'click', TAG_MODE = "OLUA_TAG_REPLACE"}
    ]]
    function cls.callback(opt)
        cls.FUNCS[#cls.FUNCS + 1] = parse_func(cls, nil, table.unpack(opt.FUNCS))
        for i, v in ipairs(cls.FUNCS[#cls.FUNCS]) do
            v.CALLBACK = setmetatable({}, {__index = opt})
            if type(v.CALLBACK.TAG_MAKER) == 'table' then
                v.CALLBACK.TAG_MAKER = assert(v.CALLBACK.TAG_MAKER[i])
            end
            if type(v.CALLBACK.TAG_MODE) == 'table' then
                v.CALLBACK.TAG_MODE = assert(v.CALLBACK.TAG_MODE[i])
            end
        end

        local arr = cls.FUNCS[#cls.FUNCS]
        for idx = 1, #arr do
            gen_func_overload(cls, arr[idx], arr)
        end
    end

    function cls.var(name, declstr)
        local readonly, static
        local rawstr = declstr
        declstr, readonly = string.gsub(declstr, '@readonly *', '')
        declstr = string.gsub(declstr, '[; ]*$', '')
        declstr, static = string.gsub(declstr, '^ *static *', '')

        olua.message(declstr)

        local ARGS = parse_args(cls, '(' .. declstr .. ')')
        name = name or ARGS[1].VAR_NAME

        -- variable is callback?
        local CALLBACK_OPT_GET
        local CALLBACK_OPT_SET
        if ARGS[1].CBTYPE then
            CALLBACK_OPT_SET = {
                TAG_MAKER =  name,
                TAG_MODE = 'OLUA_TAG_REPLACE',
            }
            CALLBACK_OPT_GET = {
                TAG_MAKER = name,
                TAG_MODE = 'OLUA_TAG_SUBEQUAL',
            }
        end

        -- make getter/setter function
        cls.VARS[#cls.VARS + 1] = {
            NAME = assert(name),
            GET = {
                LUA_FUNC = name,
                CPP_FUNC = 'get_' .. ARGS[1].VAR_NAME,
                VAR_NAME = ARGS[1].VAR_NAME,
                INSERT = {},
                FUNC_DECL = rawstr,
                RET = {
                    TYPE = ARGS[1].TYPE,
                    DECLTYPE = ARGS[1].DECLTYPE,
                    ATTR = {},
                },
                STATIC = static > 0,
                VARIABLE = true,
                ARGS = {},
                INDEX = 0,
                CALLBACK = CALLBACK_OPT_GET,
            },
            SET = {
                LUA_FUNC = name,
                CPP_FUNC = 'set_' .. ARGS[1].VAR_NAME,
                VAR_NAME = ARGS[1].VAR_NAME,
                INSERT = {},
                STATIC = static > 0,
                FUNC_DECL = rawstr,
                RET = {
                    TYPE = olua.typeinfo('void', cls),
                    ATTR = {},
                },
                VARIABLE = true,
                ARGS = ARGS,
                INDEX = 0,
                CALLBACK = CALLBACK_OPT_SET,
            },
        }

        if readonly > 0 then
            cls.VARS[#cls.VARS].SET = nil
        end
    end

    function cls.prop(name, get, set)
        assert(not string.find(name, '[^_%w]+'), name)
        cls.PROPS[#cls.PROPS + 1] = parse_prop(cls, name, get, set)
    end

    function cls.const(name, value, typename)
        cls.CONSTS[#cls.CONSTS + 1] = {
            NAME = assert(name),
            VALUE = value,
            TYPE = olua.typeinfo(typename, cls),
        }
    end

    function cls.enum(name, value)
        cls.ENUMS[#cls.ENUMS + 1] = {
            NAME = name,
            VALUE = value or (cls.CPPCLS .. '::' .. name),
        }
    end

    return cls
end

function olua.toluacls(cppcls)
    local ti = typeinfo_map[cppcls .. ' *'] or typeinfo_map[cppcls]
    assert(ti, 'type not found: ' .. cppcls)
    return ti.LUACLS
end

function olua.ispointee(ti)
    if type(ti) == 'string' then
        -- is 'T *'?
        return string.find(ti, '[*]$')
    else
        return ti.LUACLS and not olua.isvaluetype(ti)
    end
end

function olua.isenum(cls)
    local ti = typeinfo_map[cls.CPPCLS] or typeinfo_map[cls.CPPCLS .. ' *']
    return cls.REG_LUATYPE and olua.isvaluetype(ti)
end

local valuetype = {
    ['bool'] = 'false',
    ['const char *'] = 'nullptr',
    ['std::string'] = '',
    ['std::function'] = 'nullptr',
    ['lua_Number'] = '0',
    ['lua_Integer'] = '0',
    ['lua_Unsigned'] = '0',
}

function olua.typespace(ti)
    if type(ti) ~= 'string' then
        ti = ti.DECLTYPE
    end
    return ti:find('[*&]$') and '' or ' '
end

function olua.initialvalue(ti)
    if olua.ispointee(ti) then
        return 'nullptr'
    else
        return valuetype[ti.DECLTYPE] or ''
    end
end

-- enum has cpp cls, but declared as lua_Unsigned
function olua.isvaluetype(ti)
    return valuetype[ti.DECLTYPE]
end

function olua.convfunc(ti, fn)
    return string.gsub(ti.CONV, '[$]+', fn)
end

function olua.typedef(typeinfo)
    for tn in string.gmatch(typeinfo.CPPCLS, '[^\n\r]+') do
        local ti = setmetatable({}, {__index = typeinfo})
        tn = pretty_typename(tn)
        ti.CPPCLS = tn
        ti.DECLTYPE = ti.DECLTYPE or tn
        typeinfo_map[tn] = ti
        typeinfo_map['const ' .. tn] = ti
    end
end

function olua.typeconv(ci)
    ci.PROPS = {}
    ci.CPP_SYM = string.gsub(ci.CPPCLS, '[.:]+', '_')
    for line in string.gmatch(assert(ci.DEF, 'no DEF'), '[^\n\r]+') do
        if line:find('^ *//') then
            goto continue
        end
        olua.message(line)
        line = line:gsub('^ *', ''):gsub('; *$', '')
        local arg = parse_args(ci, '(' .. line .. ')')[1]
        if arg then
            arg.NAME = arg.VAR_NAME
            ci.PROPS[#ci.PROPS + 1] = arg
        end
        ::continue::
    end
    return ci
end

return olua
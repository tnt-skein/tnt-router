--- Дерево маршрутов: поиск за длину пути, а не за число маршрутов.
---
--- Перебор шаблонов на каждый запрос стоит столько, сколько объявлено
--- маршрутов: панель с сотней адресов прогоняет сто сравнений образцом,
--- чтобы ответить один раз. Дерево спускается по участкам пути — шагов
--- столько, сколько участков, сколько бы маршрутов ни объявили.
---
--- Порядок ветвей на каждом шаге один: сначала постоянный участок, потом
--- параметр с ограничением, потом параметр без него, потом хвост. Это
--- не мелочь оформления: при любом другом порядке `/files/new`,
--- объявленный позже `/files/:name`, никогда бы не открылся.
---
--- Спуск умеет возвращаться. Не подошедшая ветвь не заканчивает поиск:
--- `/files/new`, объявленный только для GET, иначе закрывал бы POST
--- и для `/files/:name` — путь совпал, способ нет, и дальше никто
--- не посмотрел.
---
--- Способы хранятся в узле, а не в маршруте: 405 обязан назвать все
--- способы этого адреса, и собирать их обходом всего дерева значит
--- делать это на каждый промах.
---
--- Более длинный путь важнее хвоста. Дошёл спуск до узла, где адрес есть,
--- а способа нет, — хвост, объявленный выше, за этот адрес уже
--- не отвечает. Без этого правила раздача панели на `*path` у корня
--- съедала бы 405 всех адресов под ней: путь верный, способ нет, а ответ
--- приходит успехом и первой страницей.
---
--- Маршрут, объявленный дважды, — промах в строке приложения, и отказ
--- о нём бросается без места (`fail.raise`): место — строку маршрута —
--- приписывает вход роутера (`tnt.router.blame`).

local fail = require('tnt.must.fail')

local path = require('tnt.router.path')

local Module = {}

--- Способ, объявленный на все случаи сразу.
Module.ANY = 'ANY'

--- Пустой узел дерева.
---@return table
function Module.node()
    return { statics = {}, params = {}, methods = {}, constrained = 0 }
end

--- Первые `count` участков шаблона.
---@param segments TntRouterSegment[]
---@param count integer
---@return TntRouterSegment[]
local function head_of(segments, count)
    local taken = {}

    for index, segment in ipairs(segments) do
        if index > count then
            break
        end

        table.insert(taken, segment)
    end

    return taken
end

--- Шаблоны, которые на самом деле объявляет один маршрут.
---
--- Необязательный участок — это два адреса, а не один: `/files/:name?`
--- обязан отвечать и на `/files`. Разворачивать их в дереве проще, чем
--- учить спуск пропускать участки: пропуск пришлось бы пробовать
--- на каждом шаге, а это возврат там, где его быть не должно.
---@param segments TntRouterSegment[]
---@return TntRouterSegment[][]
local function variants_of(segments)
    local variants = { segments }

    for index = #segments, 1, -1 do
        local segment = segments[index]

        -- Хвост не разворачивается: он и так подходит к пустому остатку.
        if segment.kind ~= 'param' or not segment.optional then
            break
        end

        table.insert(variants, head_of(segments, index - 1))
    end

    return variants
end

--- Ветвь узла для участка шаблона; заводится, если её ещё нет.
---@param current table
---@param segment TntRouterSegment
---@return table
local function child_of(current, segment)
    if segment.kind == 'static' then
        local existing = current.statics[segment.text]

        if existing == nil then
            existing = Module.node()
            current.statics[segment.text] = existing
        end

        return existing
    end

    if segment.kind == 'wildcard' then
        if current.wildcard == nil then
            current.wildcard = Module.node()
            current.wildcard.name = segment.name
        elseif current.wildcard.name ~= segment.name then
            fail.raise(
                ('хвост здесь уже назван «%s», а не «%s»'):format(
                    current.wildcard.name,
                    segment.name
                )
            )
        end

        return current.wildcard
    end

    for _, existing in ipairs(current.params) do
        if existing.name == segment.name and existing.constraint == segment.constraint then
            return existing
        end
    end

    local created = Module.node()
    created.name = segment.name
    created.constraint = segment.constraint
    created.check = segment.check

    -- Ограниченный параметр встаёт впереди свободного: `:id<int>` — это
    -- более узкий адрес, чем `:slug`, и проверять его надо первым,
    -- иначе ограничение не отсеет ничего.
    if segment.check ~= nil then
        current.constrained = current.constrained + 1
        table.insert(current.params, current.constrained, created)
    else
        table.insert(current.params, created)
    end

    return created
end

--- Кладёт маршрут в дерево.
---@param root table
---@param segments TntRouterSegment[]
---@param method string
---@param route table
function Module.insert(root, segments, method, route)
    for _, variant in ipairs(variants_of(segments)) do
        local current = root

        for _, segment in ipairs(variant) do
            current = child_of(current, segment)
        end

        if current.methods[method] ~= nil then
            fail.raise(('маршрут %s %s объявлен дважды'):format(method, route.pattern))
        end

        current.methods[method] = route
    end
end

--- Способы, объявленные в узле, по порядку.
---
--- Про `ANY` здесь думать не надо: узел, объявленный на все способы,
--- отвечает на любой, и до перечня дело не доходит.
---@param current table
---@return string[]
local function methods_of(current)
    local names = {}

    for name in pairs(current.methods) do
        table.insert(names, name)
    end

    table.sort(names)

    return names
end

--- Копия разобранных параметров.
---
--- Спуск правит одну таблицу на весь обход и убирает за собой на возврате:
--- отдать её наружу значило бы отдать то, что ещё будет меняться.
---@param params table<string, string>
---@return table<string, string>
local function taken(params)
    local copy = {}

    for name, value in pairs(params) do
        copy[name] = value
    end

    return copy
end

--- Разбирает узел, до которого дошёл путь.
---
--- Спуск отдаёт наверх сам маршрут, а не признак «нашёлся»: признак
--- проверяли бы только на истинность, и `false` с пустотой в нём ничем
--- не различались бы. Маршрут же доходит до ответа, и потерять его
--- по дороге значит не найти.
---@param current table
---@param params table<string, string>
---@param method string
---@param found table Куда складывать разобранное: параметры и перечень способов
---@return table|nil route Найденный маршрут; пустота — поиск идёт дальше
local function arrive(current, params, method, found)
    local route = current.methods[method] or current.methods[Module.ANY]

    if route ~= nil then
        found.params = taken(params)

        return route
    end

    -- Путь есть, способа нет. Набор способов запоминается от первого
    -- такого узла — по нему собирается заголовок Allow, — но поиск
    -- продолжается: следующая ветвь может знать нужный способ.
    if next(current.methods) ~= nil then
        if found.allowed == nil then
            found.allowed = methods_of(current)
        end

        -- Хвост, объявленный выше по дереву, за этот адрес больше
        -- не отвечает: более длинный путь важнее. Иначе раздача панели
        -- на `*path` у корня отвечала бы первой страницей и там, где
        -- адрес верный, а способ нет, — то есть подменяла бы 405 успехом.
        found.settled = true
    end

    return nil
end

--- Пробует отдать остаток пути хвосту.
---@param current table
---@param params table<string, string>
---@param rest string
---@param method string
---@param found table
---@return table|nil route
local function tail(current, params, rest, method, found)
    local child = current.wildcard

    if child == nil then
        return nil
    end

    params[child.name] = rest

    local route = arrive(child, params, method, found)

    -- Нашёлся маршрут — параметры уже скопированы в находку, и рабочую
    -- таблицу можно чистить: следующей ветви остаток не нужен.
    params[child.name] = nil

    return route
end

--- Подходит ли значение участка параметру.
---@param child table
---@param value string
---@return boolean
local function fits(child, value)
    return child.check == nil or child.check(value)
end

--- Спускается по дереву от узла к узлу.
---@param current table
---@param parts string[]
---@param index integer
---@param params table<string, string>
---@param method string
---@param found table
---@return table|nil route
local function descend(current, parts, index, params, method, found)
    if index > #parts then
        return arrive(current, params, method, found) or tail(current, params, '', method, found)
    end

    local part = parts[index] --[[@as string]]
    local static = current.statics[part]

    if static ~= nil then
        local route = descend(static, parts, index + 1, params, method, found)

        if route ~= nil then
            return route
        end
    end

    for _, child in ipairs(current.params) do
        if fits(child, part) then
            params[child.name] = part

            local route = descend(child, parts, index + 1, params, method, found)

            params[child.name] = nil

            if route ~= nil then
                return route
            end
        end
    end

    -- Более точный адрес уже нашёлся ниже — и не тем способом, каким
    -- пришли. Отдать остаток хвосту отсюда значит ответить успехом там,
    -- где ответ один: 405 с перечнем способов того самого адреса.
    if found.settled then
        return nil
    end

    return tail(current, params, table.concat(parts, '/', index), method, found)
end

--- Ищет маршрут по пути и способу.
---@param root table
---@param request_path string
---@param method string
---@return table|nil route Найденный маршрут
---@return table<string, string> params Разобранные параметры пути
---@return string[] allowed Способы адреса, если способ не тот
function Module.find(root, request_path, method)
    local found = { params = {} }
    local route = descend(root, path.segments(request_path), 1, {}, method, found)

    return route, found.params, found.allowed or {}
end

return Module

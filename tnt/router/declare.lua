--- Объявление маршрутов: настройки роутера, области групп и сама запись
--- маршрута в дерево.
---
--- Живёт отдельно от фасада, потому что у объявления своя забота —
--- собрать из шаблона, области группы и настроек готовую запись и
--- отвергнуть негодное при загрузке приложения, — а у фасада своя:
--- раздать способы экземпляру и общему роутеру. Отвечает на запросы
--- `tnt.router.answer`, и объявление о нём не знает.
---
--- Отказ объявления показывает на строку приложения. Настройки роутера
--- винят её уровнем: кадров от входа до их проверки всегда одно число.
--- Маршрут бросает без места (`fail.raise`), а место — строку маршрута —
--- приписывает вход (`tnt.router.blame`): до проверок шаблона, дерева
--- и слоёв кадров всякий раз разное число.

local fail = require('tnt.must.fail')

local address = require('tnt.router.address')
local blame = require('tnt.router.blame')
local constraints = require('tnt.router.constraints')
local errors = require('tnt.router.errors')
local options = require('tnt.router.options')
local path = require('tnt.router.path')
local pipeline = require('tnt.router.pipeline')
local signed = require('tnt.router.signed')
local tree = require('tnt.router.tree')

local Module = {}

--- Настройка нужного вида или отказ.
---
--- Настройки проверяются при заведении роутера, а не при первом запросе:
--- опечатка в имени слоя обязана обнаружиться при загрузке приложения,
--- когда её видит разработчик, а не ночью, когда её видит дежурный.
local expected = options.expected

--- Уровень вины у настроек роутера.
---
--- Отказ показывает на строку приложения: кадр проверки, кадр функции
--- здесь, кадр входа — `router.new` или `router.configure`, — и тот, кто
--- позвал вход. Способы экземпляра и общего роутера передают вызов
--- хвостом, и своих кадров у них нет.
local CALLER = 4

--- Уровень вины у настроек группы: тот, кто позвал `scope`.
---
--- Кадр проверки, кадр функции здесь и её вызывающий. Вход `group` зовёт
--- область под `pcall` (`tnt.router.blame`), и вызывающий здесь — сам
--- `pcall`, кадр без строки: отказ настройки выходит без места, как
--- и отказ шаблона начала группы, и место обоим — строку группы —
--- приписывает вход.
local SCOPE_CALLER = 3

---@class TntRouterScope
---@field prefix string Начало пути, накопленное группами
---@field middleware TntRouterLayer[] Слои, накопленные группами
---@field where table<string, any> Ограничения, накопленные группами
---@field name string Начало имён маршрутов

---@class TntRouterGroup
---@field middleware TntRouterLayer[]|nil Слои всех маршрутов группы
---@field where table<string, any>|nil Ограничения всех параметров группы
---@field name string|nil Начало имён маршрутов группы

---@class TntRouterRoute
---@field name string|nil Имя маршрута для построения адреса
---@field middleware TntRouterLayer[]|nil Слои только этого маршрута
---@field where table<string, any>|nil Ограничения только этого маршрута

--- Проверенные настройки роутера.
---
--- Каждая настройка винит того, кто завёл роутер (`router.new`) либо
--- настроил общий (`router.configure`): у одной функции одно место
--- на все отказы.
---@param opts TntRouterOptions|nil
---@return table
function Module.settings(opts)
    local given = opts or {}

    return {
        prefix = expected(given.prefix, 'string', '', 'prefix', CALLER),
        middleware = expected(given.middleware, 'table', {}, 'middleware', CALLER),
        entry = expected(given.entry, 'table', {}, 'entry', CALLER),
        view = expected(given.view, 'table', nil, 'view', CALLER),
        view_data = expected(given.view_data, 'function', nil, 'view_data', CALLER),
        where = expected(given.where, 'table', {}, 'where', CALLER),
        on_error = expected(given.on_error, 'function', errors.respond, 'on_error', CALLER),
        wrap = expected(given.wrap, 'function', pipeline.wrap, 'wrap', CALLER),
        resolve = expected(given.resolve, 'function', nil, 'resolve', CALLER),
        url = address.base(given.url, CALLER),
        signer = signed.new(given.signing, CALLER),
    }
end

--- Слои группы и маршрута одним списком, в порядке объявления.
---@param outer TntRouterLayer[]
---@param inner TntRouterLayer[]|nil
---@return TntRouterLayer[]
local function layered(outer, inner)
    local layers = {}

    for _, list in ipairs({ outer, inner or {} }) do
        for _, layer in ipairs(list) do
            table.insert(layers, layer)
        end
    end

    return layers
end

--- Ограничения группы и маршрута одной таблицей.
---@param outer table<string, any>
---@param inner table<string, any>|nil
---@return table<string, any>
local function merged(outer, inner)
    local where = {}

    for name, constraint in pairs(outer) do
        where[name] = constraint
    end

    for name, constraint in pairs(inner or {}) do
        where[name] = constraint
    end

    return where
end

--- Область группы внутри внешней области.
---
--- Настройки группы проверяются здесь, до склейки с внешней областью:
--- `where = 1` иначе сорвался бы обходом числа как таблицы, и отказ
--- показал бы внутрь пакета, а не на строку группы.
---@param outer TntRouterScope
---@param prefix string
---@param opts TntRouterGroup|nil
---@return TntRouterScope
function Module.scope(outer, prefix, opts)
    local given = expected(opts, 'table', {}, 'группа', SCOPE_CALLER)
    local middleware = expected(given.middleware, 'table', nil, 'middleware', SCOPE_CALLER)
    local where = expected(given.where, 'table', nil, 'where', SCOPE_CALLER)
    local name = expected(given.name, 'string', '', 'name', SCOPE_CALLER)

    return {
        prefix = path.join(outer.prefix, prefix),
        middleware = layered(outer.middleware, middleware),
        where = merged(outer.where, where),
        name = outer.name .. name,
    }
end

--- Привязывает проверки к участкам шаблона.
---
--- Ограничение из шаблона (`:id<int>`) и ограничение из настроек
--- (`where = { id = ... }`) — одно и то же место, и последнее слово
--- за настройками: шаблон написан один раз, а группа может сузить его
--- для всех своих маршрутов сразу.
---@param segments TntRouterSegment[]
---@param where table<string, any>
local function constrain(segments, where)
    for _, segment in ipairs(segments) do
        local constraint = segment.constraint

        if segment.name ~= nil and where[segment.name] ~= nil then
            constraint = where[segment.name]
        end

        if constraint ~= nil then
            segment.check = constraints.resolve(constraint)
        end
    end
end

--- Объявляет маршрут.
---
--- Отказ бросается без места: место — строку маршрута — приписывает
--- вход роутера. Разрешение обработчика и сборка слоёв — функции того,
--- кто собрал роутер, и зовутся через `blame.bare`: позванные напрямую,
--- они, виня своего вызывающего, назвали бы строку здесь.
---@param self table
---@param method string
---@param pattern string
---@param handler function
---@param opts TntRouterRoute|nil
---@return table route
function Module.route(self, method, pattern, handler, opts)
    -- Запись не-функцией — `{ объект, 'метод' }`, строка — разрешается
    -- при объявлении, а не при первом запросе: опечатка в имени метода
    -- обязана обнаружиться при загрузке приложения. Что значат такие
    -- записи, роутер не знает — это дело того, кто его собрал.
    if type(handler) ~= 'function' and self.settings.resolve ~= nil then
        handler = blame.bare(self.settings.resolve, handler)
    end

    if type(handler) ~= 'function' then
        fail.raise(('маршруту %s %s нужен обработчик'):format(method, tostring(pattern)))
    end

    local given = opts or {}
    local scope = self.scope
    local full = path.join(scope.prefix, pattern)
    local segments = path.compile(full)

    constrain(segments, merged(scope.where, given.where))

    local route = {
        method = method,
        pattern = full,
        segments = segments,
        run = blame.bare(self.settings.wrap, layered(scope.middleware, given.middleware), handler),
    }

    if given.name ~= nil then
        route.name = scope.name .. given.name
    end

    tree.insert(self.root, segments, method, route)

    if route.name ~= nil then
        if self.named[route.name] ~= nil then
            fail.raise(('маршрут с именем «%s» уже объявлен'):format(route.name))
        end

        self.named[route.name] = route
    end

    table.insert(self.declared, route)

    return route
end

return Module

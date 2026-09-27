--- Общие средства тестов пакета маршрутизации.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must`, `tnt.hash`, `tnt.clock`, `tnt.context`, `tnt.date`,
--- `tnt.id`, `tnt.log`, `tnt.fs`, `tnt.external`, `tnt.metrics` и рок
--- `http` — берутся из `.rocks` обычным `require`: проверяется этот пакет,
--- а не они.
---
--- Оснастка в `test/testing/` — загрузчик исходников, часы-двойник
--- и ловушка журнала — грузится так же, файлами, и один раз на процесс:
--- второй экземпляр загрузчика не знал бы, что вытеснил первый, и не вернул
--- бы вытесненное на место.
---
--- Проверки роутера берут всё через помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в наборе, где пакет живёт рядом со своими зависимостями.

local fio = require('fio')
local t = require('luatest')

--- Реестр встроенного metrics: его методов в аннотациях ядра нет.
---@type any
local registry = require('metrics')

--- Модули оснастки в порядке зависимостей: ловушка журнала берёт
--- загрузчик.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.clock', path = 'test/testing/clock.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

local sources = package.loaded['tnt.testing.sources']

--- Соседи, которых роутер берёт по имени, если они стоят.
---
--- Берутся сразу и без `pcall`: проверки ограничений и слоёв идут против
--- настоящих пакетов, а без соседа ограничение `:id<int>` проверялось бы
--- запасным образцом — то есть не тем, чем оно проверяется на самом деле,
--- и проверки слоёв, названных именем, молча пропускались бы. Нет соседа —
--- `make deps` не сделан, и сказать об этом надо сразу.
require('tnt.validate')
require('tnt.middleware')

local helper = {}

--- Модули пакета в порядке зависимостей.
helper.MODULES = {
    { name = 'tnt.router.neighbour', path = 'tnt/router/neighbour.lua' },
    -- Проверка настроек — раньше всех, кто её спрашивает: модуль из
    -- исходников, позвавший её до загрузки, взял бы установленную копию.
    { name = 'tnt.router.options', path = 'tnt/router/options.lua' },
    -- Место отказа объявления — тоже раньше всех, кто его приписывает.
    { name = 'tnt.router.blame', path = 'tnt/router/blame.lua' },
    { name = 'tnt.router.path', path = 'tnt/router/path.lua' },
    { name = 'tnt.router.constraints', path = 'tnt/router/constraints.lua' },
    { name = 'tnt.router.tree', path = 'tnt/router/tree.lua' },
    { name = 'tnt.router.multipart', path = 'tnt/router/multipart.lua' },
    { name = 'tnt.router.upload', path = 'tnt/router/upload.lua' },
    { name = 'tnt.router.form', path = 'tnt/router/form.lua' },
    { name = 'tnt.router.request', path = 'tnt/router/request.lua' },
    { name = 'tnt.router.response', path = 'tnt/router/response.lua' },
    { name = 'tnt.router.takeover', path = 'tnt/router/takeover.lua' },
    { name = 'tnt.router.errors', path = 'tnt/router/errors.lua' },
    { name = 'tnt.router.signed', path = 'tnt/router/signed.lua' },
    { name = 'tnt.router.address', path = 'tnt/router/address.lua' },
    { name = 'tnt.router.files.caching', path = 'tnt/router/files/caching.lua' },
    { name = 'tnt.router.files.store', path = 'tnt/router/files/store.lua' },
    { name = 'tnt.router.files', path = 'tnt/router/files.lua' },
    { name = 'tnt.router.etag', path = 'tnt/router/etag.lua' },
    { name = 'tnt.router.view', path = 'tnt/router/view.lua' },
    { name = 'tnt.router.pipeline', path = 'tnt/router/pipeline.lua' },
    { name = 'tnt.router.declare', path = 'tnt/router/declare.lua' },
    { name = 'tnt.router.series', path = 'tnt/router/series.lua' },
    { name = 'tnt.router.answer', path = 'tnt/router/answer.lua' },
    { name = 'tnt.router', path = 'tnt/router.lua' },
}

--- Общий способ объявить ряд, из `.rocks`, — заново на каждую проверку.
---
--- Повторное объявление ряда отдаёт тот же ряд вместе с его счётом,
--- и счёт одной проверки достался бы следующей: ряды сверяются точным
--- числом. Снятые отсюда модули роутер, загруженный заново, берёт свежими
--- обычным `require`, а прежний сборщик в реестре новый снимает сам.
local SERIES = { 'tnt.metrics.series', 'tnt.metrics.series.collector', 'tnt.metrics.series.labels' }

--- Ловушка журнала: записи `tnt-log` на время проверки.
helper.capture_log = package.loaded['tnt.testing.journal'].capture

--- Часы-двойник: двигаются только от паузы, перевода и чтения с шагом.
helper.clock = package.loaded['tnt.testing.clock'].new

--- Совпадают ли метки: одинаковый набор имён с одинаковыми значениями.
---@param left table
---@param right table
---@return boolean
local function same_labels(left, right)
    for name, value in pairs(left) do
        if right[name] ~= value then
            return false
        end
    end

    for name in pairs(right) do
        if left[name] == nil then
            return false
        end
    end

    return true
end

--- Что увидит сборщик: число ряда с ровно такими метками.
---
--- Реестр читается после обработчиков сбора, как его читает сборщик.
---@param name string
---@param labels table|nil
---@return number|nil
function helper.value(name, labels)
    for _, observation in ipairs(registry.collect({ invoke_callbacks = true })) do
        if observation.metric_name == name and same_labels(observation.label_pairs, labels or {}) then
            return observation.value
        end
    end

    return nil
end

--- Заводит группу проверок со свежими исходниками пакета.
---
--- Исходники грузятся заново перед каждой проверкой: общий на процесс
--- роутер живёт в модуле, и маршруты, объявленные одной проверкой,
--- достались бы следующей.
---@param name string
---@return table g Группа luatest; фасад пакета лежит в `g.router`
function helper.group(name)
    local g = t.group(name)

    g.before_each(function()
        for _, module in ipairs(SERIES) do
            package.loaded[module] = nil
        end

        g.router = sources.load(helper.MODULES, 'tnt.router')
    end)

    g.after_each(function()
        sources.unload(helper.MODULES)
        -- Файловая система одна на процесс — из `.rocks`, а не исходниками
        -- с каждой проверкой, — и подмена `fio` под ней пережила бы
        -- проверку, которая её поставила: следующая писала бы присланные
        -- файлы через чужого двойника.
        require('tnt.fs')._set_source(nil)
    end)

    return g
end

--- Отдельный модуль пакета, уже загруженный группой.
helper.part = sources.module

--- Подменяет названные действия `fio` под файловой системой роутера;
--- прочие остаются настоящими.
---
--- Подменяется `fio` под `tnt-fs`, а не сам фасад: роутер зовёт фасад
--- как есть, и проверка отказа диска идёт через тот же разбор отказа,
--- что и в бою. Подмена живёт до конца проверки — её снимает группа.
---@param overrides table<string, function> Действия `fio`, которые надо подменить
function helper.faked_fio(overrides)
    require('tnt.fs')._set_source({
        fio = setmetatable(overrides, { __index = require('fio') }),
    })
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

--- Пакета слоёв рядом нет: слой, объявленный именем, разбирает запасная
--- сборка роутера.
---
--- Подменяется намеренно, а не «как получится»: пакет то поставлен,
--- то нет, и проверка запасной сборки, зависящая от этого, проверяла бы
--- в разные дни разное. Подмена живёт до конца проверки — исходники
--- грузятся заново перед каждой.
function helper.without_middleware()
    sources.module('tnt.router.neighbour')._set_source({
        load = function(name)
            return false, ('модуля %s нет'):format(name)
        end,
    })
end

--- Ключ подписи ровно той длины, с которой её ставят.
helper.KEY = string.rep('k', 32)

--- Запрос: то, что роутер получает на вход.
---
--- Способ и путь — единственное, что нужно почти всякой проверке,
--- остальное дописывается по надобности.
---@param method string
---@param request_path string
---@param overrides table|nil Прочие поля запроса
---@return table
function helper.request(method, request_path, overrides)
    local built = { method = method, path = request_path }

    for name, value in pairs(overrides or {}) do
        built[name] = value
    end

    return built
end

--- Обработчик, отвечающий тем, что ему дали.
---@param body any Что вернуть телом
---@param status integer|nil
---@return fun(request: table): table
function helper.answering(body, status)
    return function()
        return { status = status or 200, headers = {}, body = body }
    end
end

--- Обработчик, отвечающий разобранными параметрами пути.
---@return fun(request: table): table
function helper.echoing()
    return function(request)
        return { status = 200, headers = {}, body = require('json').encode(request.params) }
    end
end

--- Тело многочастной формы из описанных частей.
---
--- Помощник один на пакет: собирать тело руками в каждой проверке значит
--- однажды написать в одной из них `\n` вместо `\r\n` и проверять
--- не то, что приходит от браузера.
---@param boundary string Метка границы
---@param parts table[] Части: `name`, `body` и по надобности `filename`, `type`
---@return string
function helper.multipart(boundary, parts)
    local written = {}

    for _, part in ipairs(parts) do
        local disposition = ('form-data; name=%q'):format(part.name)

        if part.filename ~= nil then
            disposition = disposition .. ('; filename=%q'):format(part.filename)
        end

        local headers = { 'content-disposition: ' .. disposition }

        if part.type ~= nil then
            table.insert(headers, 'content-type: ' .. part.type)
        end

        table.insert(written, ('--%s\r\n%s\r\n\r\n%s'):format(boundary, table.concat(headers, '\r\n'), part.body))
    end

    return table.concat(written, '\r\n') .. ('\r\n--%s--\r\n'):format(boundary)
end

--- Источник байтов из кусков: так проверяется разбор потоком.
---@param ... string Куски тела по порядку
---@return fun(): string
function helper.sourced(...)
    local chunks = { ... }
    local index = 0

    return function()
        index = index + 1

        return chunks[index] or ''
    end
end

--- Обходит тело потока так же, как его обходит сервер.
---
--- Помощник один на пакет: обход у потока ровно один, и вторая его копия
--- в соседнем наборе однажды разошлась бы с первой.
---@param sent table
---@return string[]
function helper.drained(sent)
    local parts = {}

    for _, part in sent.body do
        table.insert(parts, part)
    end

    return parts
end

--- Поднимает роутер на живом сервере — на петле, на случайном порту.
---
--- Помощник один на пакет: проверки поверх настоящего сервера есть и у
--- пакета, и у стыков с соседями, и сервер у них обязан быть одним и тем
--- же — без строки журнала на каждый запрос и со сроком простоя.
---@param web table Роутер
---@param limits table|nil Пределы тела для `attach`
---@return table httpd
---@return string address Адрес, по которому к нему ходить
function helper.served(web, limits)
    local httpd =
        require('http.server').new('127.0.0.1', 0, { log_requests = false, log_errors = false, idle_timeout = 5 })

    web.attach(httpd, limits)
    httpd:start()

    return httpd, ('http://127.0.0.1:%d'):format(httpd.tcp_server:name().port)
end

--- Разобранное тело ответа.
---@param response table
---@return any
function helper.decoded(response)
    return require('json').decode(response.body)
end

--- Слой, отмечающийся в общем списке на входе и на выходе.
---
--- Порядок слоёв виден только записями: слой, сделавший своё дело
--- и на входе, и на выходе, иначе неотличим от слоя, который просто
--- позвал следующего.
---
--- Отказ парой слой отдаёт целиком, как требует договор слоёв: слой,
--- съевший вторую половину, превращал бы отказ обработчика в пустоту,
--- а пустоту роутер читает поломкой.
---@param marks string[] Куда отмечаться
---@param name string
---@return fun(request: table, next: function): any, any
function helper.marking(marks, name)
    return function(request, next)
        table.insert(marks, name .. ':до')

        local answer, failure = next(request)

        table.insert(marks, name .. ':после')

        return answer, failure
    end
end

return helper

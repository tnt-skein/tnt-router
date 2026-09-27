--- Ряды метрик границы HTTP: запросы по способу, маршруту и коду ответа
--- и длительность ответа.
---
--- Меткой идёт шаблон маршрута (`/customers/:id<int>`), а не путь:
--- путей столько, сколько опознавателей в адресах, а шаблонов — сколько
--- объявлено маршрутов. Запрос, которому маршрут не нашёлся, — 404,
--- 405, тело не в пределах — идёт под словом `_unmatched`: путь сканера
--- в метке завёл бы по ряду на каждую его попытку. Способ — из списка:
--- его пишет клиент, и незнакомый идёт словом `_other`.
---
--- Длительность — от разбора запроса до готового ответа, монотонными
--- часами. Поток (`router.stream`) меряется до ответа с головой: тело
--- потока пишет сервер уже после.

local clock = require('tnt.clock')
local series = require('tnt.metrics.series')
local external = require('tnt.external')

local Module = {}

--- Сколько разных маршрутов видно в рядах: сверх потолка маршрут идёт
--- словом `_other`. Маршруты объявляет код, и пяти сотен приложению
--- хватает с запасом.
Module.ROUTES = 500

--- Сколько разных кодов ответа видно в рядах: код называет и обработчик,
--- но разных кодов HTTP у одного приложения — десятки.
Module.CODES = 60

--- Слово маршрута у запроса, которому маршрут не нашёлся.
Module.UNMATCHED = '_unmatched'

--- Способы, которые видны в рядах своим именем.
Module.METHODS = { 'GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS' }

--- Внешние средства: монотонные часы для длительности.
local source = external.install(Module, { monotonic = clock.monotonic })

local requests = series.counter('http_requests_total', {
    help = 'Сколько запросов обслужено: по способу, шаблону маршрута и коду ответа',
    labels = { method = Module.METHODS, route = Module.ROUTES, code = Module.CODES },
})

local durations = series.histogram('http_request_duration_seconds', {
    help = 'Сколько шёл ответ на запрос: от разбора до готового ответа',
    labels = { method = Module.METHODS, route = Module.ROUTES },
})

--- Отметка начала ответа.
---@return number
function Module.started()
    return source().monotonic()
end

--- Считает ответ и меряет, сколько он шёл.
---
--- Код без статуса — 200: так его отдаёт сервер. Статус обработчика идёт
--- строкой, что бы в нём ни лежало, — ряд не вправе уронить ответ.
---@param request table Разобранный запрос; `route` у него есть, если маршрут нашёлся
---@param response table Ответ
---@param started number Отметка `started`
function Module.answered(request, response, started)
    local route = request.route ~= nil and request.route.pattern or Module.UNMATCHED
    local method = request.method

    requests:inc(1, { method = method, route = route, code = tostring(response.status or 200) })
    durations:observe(source().monotonic() - started, { method = method, route = route })
end

return Module

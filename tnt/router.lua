--- Маршрутизация HTTP-запросов: адрес — обработчик.
---
--- Прикладной код не должен разбирать путь руками. Разбор `/customers/7`
--- на «клиент» и «семь» пишется в десять строк, и эти десять строк потом
--- лежат в каждом приложении — каждый раз чуть иначе, каждый раз со своим
--- ответом на путь, которого нет.
---
--- Пользоваться так:
---
---     local router = require('tnt.router')
---
---     router.get('/customers/:id<int>', function(request)
---         return router.json({ id = request.params.id })
---     end, { name = 'customer.show' })
---
---     router.group('/api/v1', { middleware = { authenticated } }, function(r)
---         r.post('/customers', create)
---         r.delete('/customers/:id<int>', remove)
---     end)
---
---     local panel = '/panel/' .. '*path'
---
---     router.get(panel, router.files({ bundle = panel_files }))
---     router.serve('/build', 'public/build', { immutable = true })
---
---     router.url('customer.show', { id = 7 })  --> /customers/7
---
---     -- log_requests = false: строку запроса сервер пишет мимо фасада,
---     -- с ?token=…, и по умолчанию уровнем info. idle_timeout: без него
---     -- соединение, шлющее заголовки по байту, держит файбер бессрочно.
---     local httpd = require('http.server').new('0.0.0.0', 8080, { log_requests = false, idle_timeout = 60 })
---
---     router.attach(httpd)
---
--- Страница, её кусок и страница потоком — от экземпляра с движком
--- страниц (`tnt.router.view`); метку версии ответа ставит слой `etag`:
---
---     local web = router.new({ view = views, middleware = { router.etag() } })
---
---     web.view('customers.index', data)                  --> страница целиком
---     web.fragment('customers.index', 'rows', data)      --> только кусок rows
---     web.view_stream('reports.year', data)              --> страница кусками
---
--- Данные, нужные каждой странице, — токен формы, вошедший посетитель, —
--- кладутся одним местом, функцией от запроса; данные обработчика главнее:
---
---     local web = router.new({ view = views, view_data = function(request)
---         return { csrf_token = request.session:token() }
---     end })
---
--- Полный адрес и подписанная ссылка — от экземпляра с адресом приложения
--- и ключом подписи (`tnt.router.address`, `tnt.router.signed`):
---
---     local web = router.new({ url = 'https://shop.example.org', signing = { key = key } })
---
---     web.full_url('customer.show', { id = 7 })   --> https://shop.example.org/customers/7
---     web.signed_url('invoice', { id = 7 }, { expires = 3600, full = true })
---     web.get('/invoices/:id', show, { name = 'invoice', middleware = { web.signed() } })
---
--- Хвост в примере склеен из двух строк не для красоты: пара знаков
--- «косая черта со звёздочкой» в комментарии — это начало блочного
--- комментария для языконезависимого мутационного прогона, и всё, что
--- стоит за ней, он перестаёт видеть. Файл при этом молча остаётся
--- без мутантов, то есть без гейта.
---
--- Решения, о которых стоит знать заранее.
---
--- Запрос — таблица `{ method, path, query, headers, body }`, ответ —
--- таблица `{ status, headers, body }`. Роутер проверяется без сервера:
--- запрос пишется таблицей и отдаётся в `dispatch`. Настоящий
--- `http.server` приводится к тому же виду в `attach`. Поля, которых
--- роутер не знает, — опознанный оператор, адрес клиента, метка
--- развёртывания, — доезжают до обработчика как есть: приложение кладёт
--- их в запрос, а не носит мимо него.
---
--- Маршруты объявляются вызовом с точкой, а не с двоеточием:
--- `router.get(...)` снаружи и `r.get(...)` внутри группы — одно и то же
--- письмо. Вызов через двоеточие тоже понят: разнобой в примерах хуже,
--- чем лишняя строка в заведении экземпляра.
---
--- Обработчик возвращает ответ таблицей. Пустота — поломка, а не «нет
--- такого адреса»: `nil` в одиночку превращается в 500. Упавший
--- обработчик не роняет узел. Иначе один и тот же промах отвечал бы
--- то 404, то 500 — смотря обёрнут маршрут слоями или нет: проход
--- `tnt.middleware` читает ту же пустоту как «слой потерял ответ».
--- Отказать 404-м обязан тот, кто знает, что искомого нет: «нет такого
--- маршрута» роутер собирает сам, до обработчика, а «нет такого файла» —
--- раздача `router.files`.
---
--- Пара `nil, err` — тоже поломка, но с одной оговоркой: отказ, который
--- назвал свой статус по договору границы HTTP, при этом статусе
--- и остаётся. Чужая строка и объект `box.error` статуса не называют
--- и становятся 500, а сам `err` наружу не уходит ни в каком случае.
---
--- Обработка отказов — минимум: 404, 405 с заголовком `Allow` и 500
--- с одним опознавателем происшествия. Единый вид отказов для всего
--- приложения — дело отдельного пакета, и он подставляется вызовом
--- `router.on_error`. Отказ идёт ему первым аргументом, запрос — вторым:
--- обработчик отказов про отказ, и запрос нужен ему не всегда.
---
--- Сам отказ — договор, общий с пакетом отказов: таблица с числовым
--- `status`, слово для человека в `message`, заголовки в `headers`,
--- опознаватель в `incident`. Слово и заголовок живут в отказе, а не
--- только в ответе роутера, именно потому, что ответ собирает не всегда
--- роутер: обработчик пакета отказов ставится одной строкой
--- `router.on_error(обработчик)`, и 405 обязан остаться 405 вместе
--- с `Allow`.
--- Подробности отказа (`reason`) наружу не уходят никогда — они уходят
--- в журнал, и пишет их роутер до того, как позовёт обработчика.
---
--- Слои — тоже отдельный пакет (`tnt.middleware`); роутер только собирает
--- их список по группам и маршрутам и отдаёт ему.
---
--- Ответ с полем `takeover` — смена протокола (WebSocket): подключение
--- к серверу пишет голову такого ответа само и отдаёт соединение функции
--- `takeover` в файбере соединения (`tnt.router.takeover`). Сервер писал бы
--- её по-своему — с `Connection: close` вместо `Upgrade`.
---
--- Обработчик — функция запроса. Запись иного вида — `{ объект, 'метод' }`,
--- строка `'имя@метод'` — роутер отдаёт настройке `resolve`, если её дали:
--- что она значит, знает тот, кто собрал роутер (ядро приложения —
--- контейнер), а не роутер.
---
--- Ошибка объявления — исключение, и место в нём — строка приложения,
--- которая позвала способ роутера: опечатка в шаблоне `router.get(…)`
--- показывает на эту строку, а не на разбор шаблона внутри пакета.
--- Проверки бросают без места, а способ зовёт работу под `pcall`
--- и приписывает место своего вызывающего (`tnt.router.blame`).

-- Фасад только раздаёт способы экземпляру и общему роутеру: объявление
-- маршрутов живёт в `tnt.router.declare`, ответ на запрос —
-- в `tnt.router.answer`, и правка одного не задевает другого.
local fail = require('tnt.must.fail')

local address = require('tnt.router.address')
local answer = require('tnt.router.answer')
local blame = require('tnt.router.blame')
local declare = require('tnt.router.declare')
local errors = require('tnt.router.errors')
local etag = require('tnt.router.etag')
local files = require('tnt.router.files')
local form = require('tnt.router.form')
local request_of = require('tnt.router.request')
local response = require('tnt.router.response')
local takeover = require('tnt.router.takeover')
local tree = require('tnt.router.tree')
local view = require('tnt.router.view')

local log = require('tnt.log').new('tnt.router')

local Module = {}

--- Части: доступны тем, кто собирает своё поведение.
Module.request = request_of
Module.response = response

--- Готовые ответы.
Module.json = response.json
Module.text = response.text
Module.html = response.html
Module.redirect = response.redirect
Module.no_content = response.no_content
Module.stream = response.stream

--- Готовый обработчик раздачи файлов.
Module.files = files.handler

--- Слой метки версии ответа: ETag по отпечатку тела и 304 на
--- `If-None-Match` (`tnt.router.etag`).
Module.etag = etag.layer

--- Готовый ответ об отказе: тот самый, которым роутер отвечает сам.
---
--- Нужен своему обработчику отказов: 404 и 405 — слово роутера, и каталог
--- отказов приложения о них ничего не знает, а собирать их заново ради
--- одной ветки незачем.
Module.refusal = errors.respond

--- Способы, объявляемые своим вызовом.
---
--- HEAD объявляется явно только там, где он отвечает иначе, чем GET:
--- обычный HEAD роутер обслуживает сам.
local METHODS = { 'GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS' }

--- Слой прохода в том виде, в каком его объявляют на группе и маршруте.
---
--- Не только функция: `tnt.middleware` понимает и имя объявленного слоя,
--- и пару «имя с настройками», и разворачивает их сам. Роутер в это
--- не вникает — он складывает список по группам и маршрутам и отдаёт его
--- целиком, — но объявить список функциями значило бы заставить каждое
--- приложение приводить тип руками.
---@alias TntRouterLayerFn fun(request: table, nxt: fun(request: table): any): any
---@alias TntRouterLayer TntRouterLayerFn|string|table

---@class TntRouterOptions
---@field prefix string|nil Общее начало всех путей
---@field middleware TntRouterLayer[]|nil Слои, общие для всех маршрутов
---@field entry TntRouterLayer[]|nil Слои на входе: вокруг всего, чем отвечает роутер, — и 404, и тела не в пределах
---@field view TntRouterView|nil Движок страниц для помощников `view`, `fragment` и `view_stream`
---@field view_data TntRouterViewData|nil Общие данные страниц: функция от запроса, её таблица — под данными обработчика
---@field where table<string, any>|nil Ограничения, общие для всех параметров
---@field on_error TntRouterOnError|nil Свой обработчик отказов
---@field wrap (fun(layers: TntRouterLayer[], handler: function): function)|nil Своя сборка слоёв
---@field resolve (fun(handler: any): function)|nil Обработчик из записи не-функции: `{ объект, 'метод' }`, строка
---@field url string|nil Адрес приложения для полного адреса: `https://shop.example.org`, по надобности с путём
---@field signing TntRouterSigning|nil Ключ подписи ссылок и прежние ключи

--- Движок страниц: что угодно с `render(name, data)`, например `tnt.template`.
--- Кусок страницы и страница потоком — по надобности (`tnt.router.view`).
---@class TntRouterView
---@field render fun(self: TntRouterView, name: string, data: table|nil): string
---@field fragment (fun(self: TntRouterView, name: string, section: string, data: table|nil): string)|nil
---@field stream (fun(self: TntRouterView, name: string, data: table|nil): fun(): string|nil)|nil

--- Общие данные страниц: зовётся на каждый вызов помощника страниц
--- в ответе на запрос (`tnt.router.view`). Отказ — пара `nil, err`:
--- помощник отдаёт её обработчику как есть.
---@alias TntRouterViewData fun(request: TntRouterRequest): table|nil, any

--- Свой обработчик отказов.
---
--- Отказ первым аргументом, запрос вторым: обработчик отказов про отказ,
--- а запроса у него может и не быть вовсе — неразобранный запрос
--- отвергается до того, как станет запросом.
---@alias TntRouterOnError fun(failure: TntRouterFailure, request: TntRouterRequest|nil): table

local Methods = {}

--- Что сказать о группе без тела.
local NO_BODY = 'группе нужна функция, в которой объявляются её маршруты'

--- Объявляет группу маршрутов с общим началом пути и общими слоями.
---
--- Отказ группы — без тела, с негодной настройкой, с началом пути без
--- косой черты — винит строку, где группу объявили: способы экземпляра
--- и общего роутера передают вызов сюда хвостом, и второй уровень — тот,
--- кто позвал `group`.
---@param self table
---@param prefix string
---@param opts TntRouterGroup|fun(router: table)
---@param body (fun(router: table))|nil
---@return table self
function Methods.group(self, prefix, opts, body)
    if type(opts) == 'function' then
        body = opts
        opts = {}
    end

    if type(body) ~= 'function' then
        error(NO_BODY, 2)
    end

    ---@type TntRouterScope
    local outer = self.scope

    self.scope = blame.call(declare.scope, outer, prefix, opts)

    -- Объявление внутри группы может упасть — шаблон с опечаткой падает
    -- на месте. Область всё равно обязана закрыться, иначе следующий
    -- маршрут за пределами группы получит её начало пути. Тело зовётся
    -- мимо `blame.call`: маршрут в нём уже назвал свою строку, и строка
    -- группы рядом с ней была бы вторым местом.
    local ok, err = pcall(body, self)

    self.scope = outer

    -- Исключение тела уходит дальше тем же значением и без места:
    -- шаблон с опечаткой уже назвал себя сам.
    if not ok then
        fail.raise(err)
    end

    return self
end

--- Подставляет свой обработчик отказов.
---
--- Не функция — промах в строке, которая его подставляла, и отказ винит
--- её: способ передан сюда хвостом, второй уровень — вызывающий.
---@param self table
---@param handler TntRouterOnError
---@return table self
function Methods.on_error(self, handler)
    if type(handler) ~= 'function' then
        error(
            ('обработчиком отказов бывает функция, а не %s'):format(type(handler)),
            2
        )
    end

    self.settings.on_error = handler

    return self
end

--- Обслуживает запрос.
---
--- Запрос не таблицей — единственное, что отвечается до слоёв входа:
--- отдать им нечего, а 400 тут — промах вызывающего, не клиента.
---@param self table
---@param input table Запрос: method, path, query, headers, body
---@return table response
function Methods.dispatch(self, input)
    local request, err = request_of.normalize(input, self.limits)

    if request == nil then
        return answer.refuse(self, nil, { status = 400, reason = err })
    end

    local answered = answer.served(self, request)

    -- Временный файл живёт ровно до конца обработки запроса и убирается
    -- при всяком исходе — в том числе когда обработчик упал или отказал.
    -- Обработчику, которому файл нужен дальше, есть `move`: перенесённый
    -- файл уборка уже не трогает.
    form.cleanup(request.files)

    return answered
end

--- Подключает роутер к серверу `http.server`.
---
--- Подменяется обработчик сервера целиком, а не заводится маршрут
--- на все пути: собственные маршруты сервера сравнивают путь образцом
--- по одному, и это ровно то, ради чего дерево и написано.
---
--- Здесь же — граница, которой сервер не держит сам: тело запроса
--- читается в пределах `opts` (см. `request.body_of`), и запрос не
--- в пределах получает отказ до маршрута — 400, 408, 411 или 413, —
--- но не до слоёв входа: у него есть голова, и журналу с опознавателем
--- есть что записать. Пределы проверяются при подключении: негодный
--- падает при загрузке.
---
--- Срок простоя соединения ставит не роутер, а сам сервер
--- (`idle_timeout` в `http.server.new`). По умолчанию у сервера его нет,
--- и соединение, шлющее заголовки по байту, держит файбер бессрочно;
--- о таком сервере роутер предупреждает при подключении, но срок за
--- владельца не выбирает.
---
--- Отказ подключения — не сервер, негодный предел — винит строку, которая
--- подключала. Пределы разбирает `request.limits`, винящая своего
--- вызывающего: под `blame.call` это кадр без строки, и место — ту же
--- строку подключения — приписывает этот вход.
---@param self table
---@param httpd table Сервер http.server
---@param opts TntRouterBodyLimits|nil Пределы тела запроса
---@return table httpd
function Methods.attach(self, httpd, opts)
    if type(httpd) ~= 'table' or type(httpd.options) ~= 'table' then
        error('подключать роутер надо к серверу http.server', 2)
    end

    local limits = blame.call(request_of.limits, opts)

    -- Пределы запоминаются на роутере: по ним разбирается и форма,
    -- написанная таблицей в `dispatch`, — иначе у запроса по сети и
    -- у запроса из проверки были бы разные границы.
    self.limits = limits

    local idle_timeout = tonumber(httpd.idle_timeout)

    if idle_timeout == nil or idle_timeout <= 0 then
        log.warn(
            'у сервера нет срока простоя: медленное соединение держит файбер бессрочно',
            {
                hint = 'idle_timeout в настройках http.server.new',
            }
        )
    end

    httpd.options.handler = function(_, incoming)
        local input, failure, head = request_of.from_server(incoming, limits)

        if input == nil then
            -- Отказ идёт той же дорогой, что и промах по адресу: через слои
            -- входа, ту же запись в журнал и тот же обработчик отказов
            -- приложения. Голова запроса — всегда таблица, разбор её
            -- не отвергает.
            local request = request_of.normalize(head, limits) --[[@as table]]

            request.refusal = failure

            return answer.served(self, request)
        end

        return takeover.served(incoming, self.dispatch(input))
    end

    return httpd
end

--- Объявленные маршруты: способ, шаблон, имя.
---
--- Порядок — по шаблону, а при равных шаблонах по способу. Сортируются
--- строки ключей встроенным порядком, а не записи своим сравнением:
--- у сравнения `<` мутант `<=` неотличим — дерево не пускает двух
--- маршрутов с одним шаблоном и способом, — и строки сравнения пришлось
--- бы исключать из проверки целиком.
---
--- Части ключа разделены нулевым байтом: он меньше любого знака
--- шаблона, поэтому `/a` встаёт раньше `/a-b` и `/a/b`, как и при
--- сравнении по полям. Номер объявления в хвосте держит ключ
--- единственным, даже если дерево однажды пустит двойников.
---@param self table
---@return table[]
function Methods.routes(self)
    local keys = {}
    local by_key = {}

    for index, route in ipairs(self.declared) do
        local key = table.concat({ route.pattern, route.method, index }, '\0')

        table.insert(keys, key)
        by_key[key] = { method = route.method, pattern = route.pattern, name = route.name }
    end

    table.sort(keys)

    local listed = {}

    for _, key in ipairs(keys) do
        table.insert(listed, by_key[key])
    end

    return listed
end

--- Страницы: целиком, одним куском и потоком (`tnt.router.view`).
---
--- Движок приходит настройкой `view` при заведении: роутер не знает,
--- чем рисуют страницы, он знает только, что движок умеет.
for name, method in pairs(view.METHODS) do
    Methods[name] = method
end

--- Готовые ответы — и у экземпляра: маршрутам приходит он, а не модуль,
--- и `return web.html(…)` пишется без второго `require`.
for _, name in ipairs({ 'json', 'text', 'html', 'redirect', 'no_content', 'stream' }) do
    Methods[name] = function(_, ...)
        return response[name](...)
    end
end

--- Что настроено. Ключа подписи здесь нет — только признак, что он задан:
--- состояние уходит в журнал и в консоль, а ключ — тайна.
---@param self table
---@return table
function Methods.status(self)
    local names = {}

    for name in pairs(self.named) do
        table.insert(names, name)
    end

    table.sort(names)

    return {
        routes = #self.declared,
        names = names,
        prefix = self.settings.prefix,
        middleware = #self.settings.middleware,
        entry = #self.settings.entry,
        view = self.settings.view ~= nil,
        view_data = self.settings.view_data ~= nil,
        custom_errors = self.settings.on_error ~= errors.respond,
        url = self.settings.url,
        signing = self.settings.signer ~= nil,
    }
end

--- Маршрут на свой способ: отказ объявления винит строку маршрута.
for _, method in ipairs(METHODS) do
    Methods[method:lower()] = function(self, pattern, handler, opts)
        local route = blame.call(declare.route, self, method, pattern, handler, opts)

        return route
    end
end

--- Объявляет маршрут на любой способ.
---@param self table
---@param pattern string
---@param handler function
---@param opts TntRouterRoute|nil
---@return table route
function Methods.any(self, pattern, handler, opts)
    local route = blame.call(declare.route, self, tree.ANY, pattern, handler, opts)

    return route
end

--- Объявляет раздачу каталога под началом пути: `serve('/build', 'public/build')`.
---
--- Маршрут объявляется на `GET` и только на него: `HEAD` роутер
--- обслуживает сам, тем же обработчиком и без тела, а на прочие способы
--- дерево отвечает 405 с перечнем — раздача о них не знает и знать
--- не должна. Шаблон с хвостом собирает сама раздача (`files.route`).
---
--- Негодная настройка раздачи винит строку, где её объявили: первый
--- уровень — сборка раздачи, второй — эта функция, третий — её вызывающий.
--- Ту же строку винит и отказ маршрута — начало пути без косой черты,
--- раздача, объявленная дважды: его место приписывает `blame.call`.
---@param self table
---@param prefix string Начало пути: `/build`; `/` — весь корень
---@param root string Каталог на диске
---@param opts TntRouterFilesOptions|nil Настройки раздачи; `name` — имя маршрута
---@return table route
function Methods.serve(self, prefix, root, opts)
    local pattern, handler, declared = files.route(prefix, root, opts, 3)
    local route = blame.call(declare.route, self, 'GET', pattern, handler, declared)

    return route
end

--- Адреса: путь по имени, полный адрес, подписанная ссылка, её сверка
--- и канонический адрес страницы (`tnt.router.address`).
for name, method in pairs(address.METHODS) do
    Methods[name] = method
end

--- Экземпляр роутера: способы вызываются и с точкой, и с двоеточием.
---
--- У помощников страниц необязательное записано знаком `?`, а не `|nil`:
--- тип функции на вторую строку не переносится, а с `|nil` он не
--- помещается в предел длины строки.
---@class TntRouter
---@field get fun(pattern: string, handler: function, opts: TntRouterRoute|nil): table
---@field head fun(pattern: string, handler: function, opts: TntRouterRoute|nil): table
---@field post fun(pattern: string, handler: function, opts: TntRouterRoute|nil): table
---@field put fun(pattern: string, handler: function, opts: TntRouterRoute|nil): table
---@field patch fun(pattern: string, handler: function, opts: TntRouterRoute|nil): table
---@field delete fun(pattern: string, handler: function, opts: TntRouterRoute|nil): table
---@field options fun(pattern: string, handler: function, opts: TntRouterRoute|nil): table
---@field any fun(pattern: string, handler: function, opts: TntRouterRoute|nil): table
---@field serve fun(prefix: string, root: string, opts: TntRouterFilesOptions|nil): table
---@field group fun(prefix: string, opts: any, body: (fun(router: TntRouter))|nil): TntRouter
---@field url fun(name: string, params: table|nil, query: table|nil): string|nil, string|nil
---@field full_url fun(name: string, params: table|nil, query: table|nil): string|nil, string|nil
---@field signed_url fun(name: string, params: table|nil, opts: TntRouterLinkOptions|nil): string|nil, string|nil
---@field verify fun(request: TntRouterRequest): true|nil, table|nil
---@field signed fun(): fun(request: table, nxt: fun(request: table): any): any
---@field canonical fun(request: TntRouterRequest, opts: { query: string[]|nil }|nil): string
---@field dispatch fun(input: table): table
---@field attach fun(httpd: table, opts: TntRouterBodyLimits|nil): table
---@field on_error fun(handler: TntRouterOnError): TntRouter
---@field routes fun(): table[]
---@field status fun(): table
---@field view fun(name: string, data: table?, status: integer?, headers: table?): table?, any
---@field fragment fun(name: string, section: string, data: table?, status: integer?, headers: table?): table?, any
---@field view_stream fun(name: string, data: table?, status: integer?, headers: table?): table?, any
---@field json fun(data: any, status: integer|nil, headers: table|nil): table
---@field text fun(body: string, status: integer|nil, headers: table|nil): table
---@field html fun(body: string, status: integer|nil, headers: table|nil): table
---@field redirect fun(location: string, status: integer|nil): table
---@field no_content fun(headers: table|nil): table
---@field stream fun(produce: function, status: integer|nil, headers: table|nil): table

--- Заводит отдельный роутер со своими маршрутами и настройками.
---
--- Отказ винит строку, которая завела роутер: настройки — уровнем
--- (`declare.settings`), сборка слоёв входа — через `blame.call`.
---@param opts TntRouterOptions|nil
---@return TntRouter
function Module.new(opts)
    local settings = declare.settings(opts)

    -- `any`, а не `table`: методы кладутся по имени из списка, и рядом
    -- с ними лежит функция входа с иной сигнатурой.
    ---@type any
    local self = {
        root = tree.node(),
        named = {},
        declared = {},
        settings = settings,
        -- Пределы тела и формы до подключения к серверу — умолчания:
        -- `dispatch` зовут и без сервера, а разбор формы без пределов
        -- отдал бы узел первой же нарочно собранной форме.
        limits = request_of.DEFAULT_LIMITS,
        scope = {
            prefix = settings.prefix,
            middleware = settings.middleware,
            where = settings.where,
            name = '',
        },
    }

    -- Вызов с точкой и вызов с двоеточием понимаются одинаково: примеры
    -- пишут то так, то так, и разнобой здесь стоит дороже трёх строк.
    for name, method in pairs(Methods) do
        self[name] = function(first, ...)
            if first == self then
                return method(self, ...)
            end

            return method(self, first, ...)
        end
    end

    -- Слои входа собираются один раз, при заведении: негодный слой
    -- обязан упасть здесь, а не на первом запросе. Без слоёв сборка
    -- не зовётся вовсе: своя сборка (`wrap`) — про слои маршрутов,
    -- и пустой список ей не о чем сообщить. Обёрнутый вход — один
    -- на все запросы: и на те, что идут искать маршрут, и на отвергнутые
    -- до него, — иначе отказ тела собирал бы цепочку заново на каждый
    -- запрос, а фабрики слоёв зовутся при объявлении, не при ответе.
    self.entered = function(request)
        return answer.routed(self, request)
    end

    if #settings.entry > 0 then
        self.entered = blame.call(settings.wrap, settings.entry, self.entered)
    end

    return self --[[@as TntRouter]]
end

--- Настройки общего на процесс роутера.
---@type TntRouterOptions|nil
local configured

---@type TntRouter|nil
local shared

--- Настраивает общий на процесс роутер.
---
--- Прежний забывается вместе с объявленными в нём маршрутами: настройка,
--- сделанная после первого объявления, обязана менять поведение,
--- а не оставаться словами.
---
--- Настройки проверяются здесь же, а не при первом обращении: иначе
--- негодный адрес приложения или короткий ключ винил бы того, кто первым
--- позвал общий роутер, а не того, кто его настроил.
---@param opts TntRouterOptions|nil
function Module.configure(opts)
    declare.settings(opts)

    configured = opts
    shared = nil
end

--- Общий на процесс роутер; заводится при первом обращении.
---
--- Настройки уже проверены в `configure`, а слои входа собираются только
--- здесь: пакет слоёв настраивают и после роутера. Их отказ винит строку,
--- которая позвала общий роутер первой, — `router.default()` или
--- `router.get(…)`, — а не заведение внутри пакета: `Module.new` зовётся
--- под `blame.call` и винит кадр без строки.
---@return TntRouter
function Module.default()
    if shared == nil then
        shared = blame.call(Module.new, configured)
    end

    return shared
end

-- Общий роутер берётся под `blame.call`, а не прямым вызовом: иначе отказ
-- его заведения винил бы эту строку. Сам способ зовётся хвостом, и своего
-- кадра у обёртки для него нет.
for name in pairs(Methods) do
    Module[name] = function(...)
        local instance = blame.call(Module.default)

        return instance[name](...)
    end
end

return Module

--- Запрос в том виде, в каком его видят маршруты.
---
--- Договор один на весь стек: `{ method, url, path, query, headers, body }`,
--- и разобранные параметры пути в `params`. Его держат и клиент, и слои,
--- и роутер — потому запрос можно написать таблицей и проверить маршрут
--- без сервера вовсе. Настоящий `http.server` приводится к тому же виду
--- здесь, а не в каждом обработчике.
---
--- Путь остаётся таким, каким пришёл: раскодировать его целиком нельзя,
--- иначе `%2F` внутри значения развалит путь на два участка. Раскодирует
--- участки разбор шаблона, и только их.
---
--- Заголовки приводятся к нижнему регистру: по RFC 9110 их имена
--- нечувствительны к регистру, и обработчик, спрашивающий
--- `headers['content-type']`, не должен угадывать, как их написал клиент.
---
--- Поля, которых здесь не знают, приложение кладёт в запрос само:
--- опознанный оператор, адрес клиента, метка развёртывания. Они доезжают
--- до обработчика как есть. Иначе приложение вынуждено носить их мимо
--- запроса — хранилищем файбера или общей переменной, — а такой довесок
--- теряется на первом же обходе: `dispatch`, позванный без `handle`,
--- приходит без личности, и виновата в этом не ошибка вызова, а договор.

local clock = require('tnt.clock')
local external = require('tnt.external')

local form = require('tnt.router.form')
local options = require('tnt.router.options')

local Module = {}

--- Средства снаружи: пара часов для срока чтения тела.
---
--- Через внешнюю зависимость, а не прямым вызовом: срок собран из двух показаний часов —
--- настоящего мига окончания и отметки планировщика, — и проверить
--- границу «срок вышел ровно» можно только назначив оба показания.
local DEFAULTS = {
    monotonic = clock.monotonic,
    scheduler_now = clock.scheduler_now,
}

local source = external.install(Module, DEFAULTS)

--- Способ по умолчанию.
---
--- GET, а не отказ: запрос, собранный таблицей в тесте, чаще всего
--- именно GET, и требовать способ там, где он очевиден, — лишний шум.
local DEFAULT_METHOD = 'GET'

--- Разбирает строку запроса.
---
--- Разбор общий с формой браузера (`tnt.router.form`): пары `имя=значение`
--- с `%XX` и «+» — это одна и та же запись, и написать её дважды значит
--- однажды раскодировать адрес не так, как тело.
---
--- Пределов у строки запроса нет: её длину держит сервер, а отказать
--- по числу полей адреса значило бы отвечать 413 на осмысленный запрос.
---@param text string|nil
---@return table<string, any>
function Module.parse_query(text)
    -- Вид называется отдельной строкой, а не приведением в самом
    -- возврате: приведение — обычный комментарий посреди строки кода,
    -- и мутации правят в нём угловые скобки, порождая мутантов, которых
    -- нечем убить. Без пределов разбор не отказывает вовсе, и второго
    -- ответа у него здесь не бывает.
    ---@type any
    local fields = form.pairs_of(text)

    return fields
end

--- Кодирует знак для строки запроса.
---@param char string
---@return string
local function escaped(char)
    return ('%%%02X'):format(char:byte())
end

--- Собирает строку запроса из полей.
---
--- Порядок полей задан именами: без сортировки один и тот же набор
--- даёт разные адреса от запуска к запуску, а по адресам сверяют
--- ответы, считают кэш и пишут ожидания в тестах.
---
--- Значение-список — повторённое имя, в порядке списка: так его собирает
--- разбор (`tag=a&tag=b` — это `{ 'a', 'b' }`), и собранное обратно
--- разбирается в то же самое. На этом стоит подпись ссылки: подписывается
--- строка, собранная из полей, и у запроса, разобранного узлом, она
--- обязана выйти той же.
---@param query table<string, any>|nil
---@return string
function Module.build_query(query)
    local names = {}

    for name in pairs(query or {}) do
        table.insert(names, tostring(name))
    end

    table.sort(names)

    local pairs_of = {}

    for _, name in ipairs(names) do
        local value = (query or {})[name]
        local encoded = name:gsub('[^%w%-%._~]', escaped)

        for _, item in ipairs(type(value) == 'table' and value or { value }) do
            table.insert(pairs_of, encoded .. '=' .. tostring(item):gsub('[^%w%-%._~]', escaped))
        end
    end

    return table.concat(pairs_of, '&')
end

--- Путь и строка запроса из того, что дали.
---
--- Путь берётся отдельным полем, если оно есть, и выкраивается из адреса,
--- если его нет: клиент присылает адрес целиком, тест пишет путь.
---@param input table
---@return string request_path
---@return string search
local function locate(input)
    local raw = input.path

    if type(raw) ~= 'string' or raw == '' then
        -- Схема и узел отрезаются: маршруты объявлены путями, и адрес,
        -- дошедший до дерева целиком, не совпадёт ни с одним. Схема
        -- описана по RFC 3986: буква, а дальше буквы, цифры, «+», «-»
        -- и точка. Имя узла бывает и пустым — «http:///заметки» тоже
        -- адрес.
        raw = tostring(input.url or '/'):gsub('^%a[%w+.%-]*://[^/]*', '')
    end

    -- Обрывок после решётки браузер до узла не доносит, но написать его
    -- в тесте руками может кто угодно, и в пути ему делать нечего.
    local addressed = raw:match('^([^#]*)') --[[@as string]]
    local request_path = addressed:match('^([^?]*)') --[[@as string]]
    local search = addressed:match('%?(.*)$') or ''

    if request_path:find('/') ~= 1 then
        -- Путь без ведущей косой черты — это `customers/7` из теста,
        -- написанного второпях, и пустой путь из адреса без пути.
        -- Дописать черту дешевле, чем отказать.
        request_path = '/' .. request_path
    end

    return request_path, search
end

--- Заголовки с именами в нижнем регистре.
---@param headers table<string, any>|nil
---@return table<string, string>
local function lowered(headers)
    local sent = {}

    for name, value in pairs(headers or {}) do
        sent[tostring(name):lower()] = tostring(value)
    end

    return sent
end

--- Строка запроса как она есть: поля таблицей собираются обратно.
---@param input table
---@param search string
---@return table<string, any>
local function query_of(input, search)
    if type(input.query) == 'table' then
        return input.query
    end

    if type(input.query) == 'string' then
        return Module.parse_query(input.query)
    end

    return Module.parse_query(search)
end

---@class TntRouterRequest
---@field method string Способ, заглавными
---@field url string Адрес целиком
---@field path string Путь, как пришёл
---@field query table<string, any> Поля строки запроса
---@field headers table<string, string> Заголовки, имена в нижнем регистре
---@field body string|nil Тело
---@field peer table|nil Адрес клиента, как его назвал сервер
---@field form table<string, string|string[]> Поля формы из тела запроса
---@field files table<string, TntRouterUpload|TntRouterUpload[]> Присланные файлы
---@field params table<string, string> Разобранные параметры пути
---@field route table|nil Чем запрос обслужен: имя, шаблон, способ
---@field refusal TntRouterFailure|nil Отказ до маршрута: тело не в пределах, битая форма; до обработчика не доходит

--- Приводит запрос к общему виду.
---
--- Форма разбирается здесь же, а не в обработчике: вид её называет сам
--- клиент заголовком, разбор у всех один, и отказ по ней — такой же отказ
--- на границе, как тело не в пределах. Тело, которое формой не назвали,
--- остаётся телом.
---@param input table|nil
---@param limits table|nil Проверенные пределы; по умолчанию `Module.DEFAULT_LIMITS`
---@return TntRouterRequest|nil request
---@return string|nil err
function Module.normalize(input, limits)
    if type(input) ~= 'table' then
        return nil, 'запрос должен быть таблицей'
    end

    local request_path, search = locate(input)
    local headers = lowered(input.headers)
    local query = query_of(input, search)

    local request = {}

    -- Сначала переносится всё, что дали: поля, которых роутер не знает,
    -- положило туда приложение — опознанный оператор, адрес клиента,
    -- метка развёртывания, — и терять их нельзя. Списка разрешённых имён
    -- нет намеренно: он потребовал бы от каждого приложения объявлять
    -- свои поля роутеру, который ими не пользуется.
    for name, value in pairs(input) do
        request[name] = value
    end

    -- А потом — своё, поверх принесённого: имена ниже принадлежат
    -- роутеру, и подложить ему снаружи разобранный путь, параметры
    -- маршрута или имя маршрута, которым запрос якобы обслужен, нельзя.
    request.method = tostring(input.method or DEFAULT_METHOD):upper()
    request.url = input.url or Module.url_of(headers.host, request_path, Module.build_query(query))
    request.path = request_path
    request.query = query
    request.headers = headers
    request.body = input.body
    request.params = {}
    request.route = nil

    local parsed, failure = form.of(request, limits or Module.DEFAULT_LIMITS)

    request.form = parsed.fields
    request.files = parsed.files
    request.refusal = failure

    return request
end

--- Собирает адрес целиком из того, что известно узлу.
---
--- Строка запроса собирается из разобранных полей, а не берётся как
--- пришла: этот адрес идёт в журнал и в ссылки, и предсказуемый порядок
--- полей в нём дороже дословного повторения того, что прислал клиент.
---
--- Узел не знает своего имени снаружи: за обратным прокси и схема,
--- и порт другие. Поэтому берётся заголовок `Host`, а без него —
--- то самое `localhost`, по которому сразу видно, что имени не было.
---@param host string|nil
---@param request_path string
---@param search string
---@return string
function Module.url_of(host, request_path, search)
    local address = ('http://%s%s'):format(host or 'localhost', request_path)

    if search == '' then
        return address
    end

    return address .. '?' .. search
end

--- Предел тела входящего запроса по умолчанию, в байтах.
---
--- Мегабайт — с запасом для JSON любого API и панели, но не столько,
--- чтобы десяток одновременных запросов съел память узла: тело читается
--- в память целиком, и потолок здесь — единственный, сервер своего не знает.
Module.DEFAULT_MAX_BODY = 1024 * 1024

--- Срок на чтение тела по умолчанию, в секундах.
---
--- Мегабайт на медленной связи (50 КБ/с) идёт двадцать секунд — втрое
--- больше хватит честному клиенту, а капельный останется без файбера
--- через минуту, а не никогда.
Module.DEFAULT_BODY_TIMEOUT = 60

--- Пределы формы по умолчанию.
---
--- Числа выбраны так, чтобы обычная форма браузера в них не упиралась
--- никогда, а нарочно собранная — упиралась сразу.
---
--- Полей и частей в форме бывает много — анкета с полусотней граф
--- обычна, — но не тысячи: таблица на тысячу ключей строится на каждый
--- запрос, и предел здесь стережёт не размер, а работу разбора.
--- Текстовое поле в четверть мегабайта — это длинная статья; всё, что
--- больше, присылают файлом. Файлов в одной форме больше десятка не
--- выбирают руками, а размер файла упирается в `max_body` и без своего
--- предела: он нужен затем, чтобы один файл не съел весь бюджет тела,
--- когда их в форме несколько.
Module.DEFAULT_MAX_FIELDS = 256
Module.DEFAULT_MAX_PARTS = 64
Module.DEFAULT_MAX_FIELD_SIZE = 256 * 1024
Module.DEFAULT_MAX_FILES = 16

--- С какого размера часть уходит во временный файл, в байтах.
---
--- Шестьдесят четыре килобайта: аватар и вложение в письмо обычно меньше,
--- и платить за них системным вызовом, уборкой и правами на файл незачем.
--- Всё, что больше, в памяти узла не держится вовсе.
Module.DEFAULT_IN_MEMORY = 64 * 1024

---@class TntRouterBodyLimits
---@field max_body integer|nil Сколько байт тела принять; по умолчанию мегабайт
---@field body_timeout number|nil Сколько секунд ждать тело целиком; по умолчанию минута
---@field max_fields integer|nil Сколько полей принять у обычной формы; по умолчанию 256
---@field max_parts integer|nil Сколько частей принять у многочастного тела; по умолчанию 64
---@field max_field_size integer|nil Сколько байт на одно текстовое поле; по умолчанию 256 КБ
---@field max_files integer|nil Сколько присланных файлов принять; по умолчанию 16
---@field max_file_size integer|nil Сколько байт на один файл; по умолчанию столько же, сколько на тело
---@field in_memory integer|nil С какого размера файл уходит во временный; по умолчанию 64 КБ
---@field temp_dir string|nil Куда класть временные файлы; по умолчанию системный каталог

--- Уровень вины у предела, проверенного отдельной функцией: кадр
--- проверки, кадр `limits` и тот, кто позвал `limits`.
local LIMIT_CALLER = 3

--- Целый предел больше нуля или отказ на месте.
---
--- Негодный предел — промах того, кто подключает сервер, и падает при
--- подключении: ноль или минус в `max_body` отказывали бы каждому
--- запросу с телом.
---@param value any
---@param name string Имя настройки
---@param what string Чего именно столько: «байт», «полей», «частей»
---@return integer
local function whole(value, name, what)
    if type(value) ~= 'number' or value % 1 ~= 0 or value < 1 then
        error(
            ('настройка «%s» должна быть целым числом %s больше нуля, а не %s'):format(
                name,
                what,
                tostring(value)
            ),
            LIMIT_CALLER
        )
    end

    return value --[[@as integer]]
end

--- Проверенные пределы тела и формы.
---
--- Отказ винит того, кто позвал `limits`, — у всех пределов одно место.
--- Зовут её и подключение к серверу, и ядро приложения, и тот, кто читает
--- тело сам, без роутера. Подключение и ядро зовут её под `pcall`:
--- вызывающий там — кадр без строки, и отказ выходит без места.
--- Подключение приписывает ему строку, которая подключала, а ядро
--- пишет его оператору как есть, с именем раздела.
---@param opts TntRouterBodyLimits|nil
---@return table
function Module.limits(opts)
    local given = opts or {}
    local max_body = whole(given.max_body or Module.DEFAULT_MAX_BODY, 'max_body', 'байт')
    local body_timeout = given.body_timeout or Module.DEFAULT_BODY_TIMEOUT

    -- NaN не равен сам себе и сравнения с нулём не проходит ни в какую
    -- сторону, поэтому отсекается отдельно; бесконечность — тоже: она
    -- вернула бы ту самую дыру, ради которой срок и заведён.
    if
        type(body_timeout) ~= 'number'
        or body_timeout ~= body_timeout
        or body_timeout <= 0
        or body_timeout == math.huge
    then
        error(
            ('настройка «body_timeout» должна быть конечным числом секунд больше нуля, а не %s'):format(
                tostring(body_timeout)
            ),
            2
        )
    end

    return {
        max_body = max_body,
        body_timeout = body_timeout,
        max_fields = whole(given.max_fields or Module.DEFAULT_MAX_FIELDS, 'max_fields', 'полей'),
        max_parts = whole(given.max_parts or Module.DEFAULT_MAX_PARTS, 'max_parts', 'частей'),
        max_field_size = whole(given.max_field_size or Module.DEFAULT_MAX_FIELD_SIZE, 'max_field_size', 'байт'),
        max_files = whole(given.max_files or Module.DEFAULT_MAX_FILES, 'max_files', 'файлов'),
        -- Предел файла по умолчанию — предел всего тела: файл больше него
        -- не пройдёт и так, а своё число здесь заставляло бы поднимать
        -- два предела вместо одного.
        max_file_size = whole(given.max_file_size or max_body, 'max_file_size', 'байт'),
        in_memory = whole(given.in_memory or Module.DEFAULT_IN_MEMORY, 'in_memory', 'байт'),
        -- Проверка вида зовётся отсюда, и вина у неё та же, что у целых
        -- пределов: кадр проверки, кадр `limits` и её вызывающий.
        temp_dir = options.expected(given.temp_dir, 'string', nil, 'temp_dir', LIMIT_CALLER),
    }
end

--- Сколько знаков чужого заголовка показывать в подробности отказа.
---
--- Заголовки сервер не ограничивает, а подробность уходит в журнал
--- и клиенту роли приложения: строка в мегабайт уехала бы туда целиком.
local SHOWN = 32

--- Значение заголовка, обрезанное для подробности.
---@param value any
---@return string
local function shown(value)
    local text = tostring(value)

    -- Начало среза — отрицательным индексом: у `sub(1, n)` мутанты `0`
    -- и `1-1` дают ту же строку, а у `-#text` единственный мутант `+#text`
    -- не проходит загрузку. У пустой строки оба среза тоже пусты.
    return text:sub(-#text, SHOWN)
end

--- Отказ чтения тела: статус по договору границы и подробность для журнала.
---@param incoming table Запрос http.server
---@param status integer
---@param reason string
---@return nil
---@return TntRouterFailure
local function spoiled(incoming, status, reason)
    -- Недочитанное тело остаётся в соединении, и сервер разобрал бы его
    -- следующим запросом. Поэтому соединение закрывается (`broken`),
    -- а остаток сервер не дочитывает (`_remaining`): иначе после отказа
    -- он сам прочёл бы всё, что назвал `Content-Length`, одной строкой —
    -- ту самую память, ради которой отказ и нужен.
    rawset(incoming, 'broken', true)
    rawset(incoming, '_remaining', 0)

    return nil, { status = status, reason = reason }
end

--- Длина тела, названная запросом, — если она в пределах.
---
--- Сервер читает тело столько, сколько назвал `Content-Length`, и без
--- срока: `read_cached` слурпит заявленные гигабайты, а клиент, шлющий
--- по байту, держит файбер бессрочно — `idle_timeout` сервера стережёт
--- только заголовки. Поэтому длина сверяется с пределом до чтения.
---
--- Длина — только цифры. `tonumber` сервера читает и «0x10», и «1e3»,
--- и два заголовка, склеенные запятой, отказом не считает: принять
--- от клиента число, прочитанное не так, как его прочтёт прокси перед
--- узлом, — это разбор тела на границе запросов.
---
--- Тело кусками (`Transfer-Encoding`) сервер не читает вовсе: оно осталось
--- бы в соединении и ушло бы в разбор следующим запросом. На него — 411.
---@param incoming table Запрос http.server
---@param limits table Проверенные ` Module.limits`
---@return integer|nil length Сколько байт тела обещано; ноль — тела нет
---@return TntRouterFailure|nil failure
function Module.length_of(incoming, limits)
    local headers = incoming.headers or {}

    if headers['transfer-encoding'] ~= nil then
        return spoiled(incoming, 411, 'тело кусками без Content-Length не принимается')
    end

    local declared = headers['content-length']

    if declared == nil then
        return 0
    end

    if tostring(declared):match('^%d+$') == nil then
        return spoiled(incoming, 400, ('Content-Length не число байт: %q'):format(shown(declared)))
    end

    -- Число из сотни цифр читается неточно, но всё равно огромным
    -- (или бесконечностью) и предел не проходит; точность теряется
    -- только за 2^53 байт, а таких пределов не бывает.
    local length = tonumber(declared) --[[@as number]]

    if length > limits.max_body then
        return spoiled(
            incoming,
            413,
            ('тело в %s байт больше предела в %d'):format(shown(declared), limits.max_body)
        )
    end

    return length --[[@as integer]]
end

--- Отказ «тело пришло не целиком»: сколько ждали и сколько дождались.
---@param incoming table
---@param timeout number
---@param taken integer
---@param length integer
---@return nil
---@return TntRouterFailure
local function overdue(incoming, timeout, taken, length)
    return spoiled(
        incoming,
        408,
        ('тело пришло не целиком за %s с: %d байт из %d'):format(timeout, taken, length)
    )
end

--- Тело целиком, в срок.
---@param incoming table
---@param length integer
---@param timeout number
---@return string|nil body
---@return TntRouterFailure|nil failure
local function whole_body(incoming, length, timeout)
    -- Тела нет — и читать нечего: сервер на `read` без тела отвечает
    -- пустой строкой сам, но спрашивать его об этом незачем.
    if length == 0 then
        return ''
    end

    local body = incoming:read(length, timeout)

    -- Сервер отдаёт пустую строку и на истёкший срок, и на ошибку чтения,
    -- а на обрыв — то, что успело прийти. Отличить их нечем, и не нужно:
    -- тело короче заявленного обработчику не отдаётся ни в одном случае.
    if #body < length then
        return overdue(incoming, timeout, #body, length)
    end

    return body
end

--- Тело запроса `http.server` в пределах и в срок.
---
--- Длина сверяется с пределом до чтения, а само чтение идёт со сроком
--- (см. ` Module.length_of`).
---@param incoming table Запрос http.server
---@param limits table Проверенные ` Module.limits`
---@return string|nil body
---@return TntRouterFailure|nil failure
function Module.body_of(incoming, limits)
    local length, failure = Module.length_of(incoming, limits)

    if length == nil then
        return nil, failure
    end

    return whole_body(incoming, length, limits.body_timeout)
end

--- Сколько байт просить у соединения за раз.
---
--- Шестьдесят четыре килобайта — обычный размер куска ответа и тут же
--- потолок памяти на один разбираемый запрос: больше этого разбор
--- многочастного тела в памяти не держит.
local CHUNK = 64 * 1024

--- Источник тела кусками: то, чем кормится разбор многочастного тела.
---
--- Срок один на всё тело, а не на кусок: клиент, присылающий по байту
--- раз в полсекунды, иначе держал бы файбер вечно — каждый кусок
--- приходил бы «вовремя». Миг окончания отмечается настоящими часами,
--- а остаток, уходящий в ожидание сокета, считается от времени
--- планировщика: от него сокет и отсчитывает свой срок
--- (`docs/packages.md`, «Часы: длительность и срок»).
---@param incoming table Запрос http.server
---@param length integer Сколько байт тела обещано
---@param timeout number Срок на всё тело, секунд
---@return fun(): string|nil, TntRouterFailure|nil
function Module.reader(incoming, length, timeout)
    local deadline = source().monotonic() + timeout
    local left = length

    return function()
        if left <= 0 then
            return ''
        end

        local rest = deadline - source().scheduler_now()

        if rest <= 0 then
            return overdue(incoming, timeout, length - left, length)
        end

        local part = incoming:read(math.min(CHUNK, left), rest)

        -- Пустая строка — это и обрыв, и истёкший срок сокета: тела
        -- обещано больше, чем пришло, и разбирать неполное нельзя.
        if part == '' then
            return overdue(incoming, timeout, length - left, length)
        end

        left = left - #part

        return part
    end
end

--- Многочастное тело: разбор потоком, с уборкой за собой при отказе.
---@param incoming table
---@param length integer
---@param params table<string, string> Параметры заголовка `Content-Type`
---@param limits table
---@return TntRouterForm|nil
---@return TntRouterFailure|nil
local function form_of(incoming, length, params, limits)
    local parsed, problem = form.multipart_of(Module.reader(incoming, length, limits.body_timeout), params, limits)

    if parsed == nil then
        local refusal = problem --[[@as TntRouterFailure]]

        return spoiled(incoming, refusal.status, refusal.reason)
    end

    return parsed
end

--- Приводит запрос `http.server` к общему виду.
---
--- Берётся `path_raw`, а не `path`: сервер раскодирует путь целиком,
--- и `%2F` из значения к этому времени уже стал разделителем.
---
--- Адрес клиента переносится вместе с остальным: по нему считают неудачные
--- попытки входа и пишут аудит, а знает его один сервер — дальше по цепочке
--- взять его уже неоткуда.
---
--- Тело читается в пределах `limits` (см. ` Module.length_of`). Тело
--- не в пределах — отказ парой: заголовки запроса без тела и отказ
--- с его статусом.
---
--- Многочастное тело разбирается прямо из соединения, кусками: держать
--- в памяти форму с вложением целиком — а её присылают десятками
--- мегабайт — значит отдать узел первому же, кто пришлёт десять таких
--- сразу. Само тело обработчику после этого не достаётся: оно уже
--- разобрано на поля и файлы, и второй его копии нет нигде.
---@param incoming table Запрос http.server
---@param limits table Проверенные ` Module.limits`
---@return table|nil request
---@return TntRouterFailure|nil failure
---@return table|nil head Тот же запрос без тела: его пишет журнал отказа
function Module.from_server(incoming, limits)
    local head = {
        method = incoming.method,
        path = incoming.path_raw or incoming.path,
        query = incoming.query,
        headers = incoming.headers,
        peer = incoming.peer,
    }

    local length, failure = Module.length_of(incoming, limits)

    if length == nil then
        return nil, failure, head
    end

    local kind, params = form.kind_of(incoming.headers)

    if kind == form.MULTIPART then
        local parsed, problem = form_of(incoming, length, params, limits)

        if parsed == nil then
            return nil, problem, head
        end

        head.body = ''
        head.form = parsed.fields
        head.files = parsed.files

        return head
    end

    local body, spoilt = whole_body(incoming, length, limits.body_timeout)

    if body == nil then
        return nil, spoilt, head
    end

    head.body = body

    return head
end

--- Пределы по умолчанию: один набор на все запросы, которым своих не дали.
---
--- Считаются один раз, а не на каждый разбор: `normalize` зовётся на
--- каждый запрос, и собирать ему таблицу пределов заново незачем.
Module.DEFAULT_LIMITS = Module.limits()

return Module

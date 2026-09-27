--- Ответы: то, что обработчик возвращает роутеру.
---
--- Ответ — таблица `{ status, headers, body }` и ничего больше. Ни класса,
--- ни цепочки вызовов: такую таблицу пишут в тесте руками и сравнивают
--- целиком, а объект пришлось бы сначала разобрать. Тело — строка,
--- а у потока (`stream`) — функция, которую сервер обходит кусками.
---
--- Тип содержимого проставляется всегда. Браузер не станет исполнять
--- сценарий, отданный без типа, а JSON без `charset` он читает в кодировке
--- страницы — и кириллица в ответе превращается в вопросительные знаки.
---
--- Имена заголовков хранятся в нижнем регистре: их сравнивают, а сравнивать
--- по-разному написанное значит однажды проставить `Content-Type` рядом
--- с `content-type` и отправить оба.

local json = require('json')

local clock = require('tnt.clock')
local context = require('tnt.context')
local external = require('tnt.external')
local fail = require('tnt.must.fail')

local log = require('tnt.log').new('tnt.router')

local Module = {}

--- Внешние средства: монотонные часы для длительности потока.
local source = external.install(Module, { monotonic = clock.monotonic })

--- Типы содержимого готовых ответов.
local TYPES = {
    json = 'application/json; charset=utf-8',
    text = 'text/plain; charset=utf-8',
    html = 'text/html; charset=utf-8',
}

--- Код ответа по умолчанию.
local OK = 200

--- Куда отсылать, если про код перенаправления ничего не сказали.
---
--- 302, а не 301: постоянное перенаправление браузер запоминает навсегда
--- и больше не спрашивает, и ошибка в нём чинится только у каждого
--- клиента по отдельности.
local FOUND = 302

--- Заголовки с именами в нижнем регистре поверх готовых.
---@param prepared table<string, string>
---@param headers table<string, string>|nil
---@return table<string, string>
local function lowered(prepared, headers)
    for name, value in pairs(headers or {}) do
        prepared[tostring(name):lower()] = value
    end

    return prepared
end

--- Ответ с телом и типом содержимого.
---@param kind string Ключ типа содержимого
---@param body string
---@param status integer|nil
---@param headers table<string, string>|nil
---@return table
local function sent(kind, body, status, headers)
    local prepared = lowered({
        ['content-type'] = TYPES[kind] --[[@as string]],
    }, headers)

    return { status = status or OK, headers = prepared, body = body }
end

--- Ответ данными в JSON.
---@param data any
---@param status integer|nil Код ответа; по умолчанию 200
---@param headers table<string, string>|nil Дополнительные заголовки
---@return table
function Module.json(data, status, headers)
    return sent('json', json.encode(data), status, headers)
end

--- Ответ обычным текстом.
---@param body any
---@param status integer|nil
---@param headers table<string, string>|nil
---@return table
function Module.text(body, status, headers)
    return sent('text', tostring(body), status, headers)
end

--- Ответ страницей.
---@param body any
---@param status integer|nil
---@param headers table<string, string>|nil
---@return table
function Module.html(body, status, headers)
    return sent('html', tostring(body), status, headers)
end

--- Ответ «сделано, показывать нечего».
---
--- Ни тела, ни типа содержимого: по RFC 9110 у 204 их не бывает,
--- а прокси, увидевший `content-type` при пустом теле, вправе решить,
--- что ответ обрезали.
---@param headers table<string, string>|nil
---@return table
function Module.no_content(headers)
    return { status = 204, headers = lowered({}, headers) }
end

--- Ответ «иди туда».
---
--- Пустой адрес — ошибка кода, а не отказ: перенаправление в никуда
--- уводит браузер на ту же страницу, и круг повторяется, пока он
--- не сдастся. Такое обязано падать там, где написано.
---@param location string Куда отправить
---@param status integer|nil Код; по умолчанию 302
---@return table
function Module.redirect(location, status)
    if type(location) ~= 'string' or location == '' then
        error('перенаправлению нужен адрес')
    end

    return { status = status or FOUND, headers = { location = location }, body = '' }
end

--- Тип содержимого потока, если о нём не сказали.
---
--- Роутер не знает, что в кусках, и называть их текстом значило бы
--- соврать браузеру: он показал бы выгрузку страницей, а не сохранил.
local OCTETS = 'application/octet-stream'

--- Что писать в журнал, когда поток оборвался.
local BROKEN_STREAM = 'поток ответа оборван'

--- Что писать в журнал, когда поток отдан до конца.
local SENT_STREAM = 'поток ответа отдан'

--- Шаг потока в том виде, в каком его ждёт `http.server`.
---
--- Сервер зовёт тело-функцию как итератор `for _, part in body do` и шлёт
--- второе значение куском. Первое — управляющее значение цикла: он идёт,
--- пока оно не nil, — и кусок годится на эту роль сам. Пустой кусок он отправил бы как «0\r\n\r\n» —
--- это конец тела по RFC 9112, и всё, что пошло бы следом, клиент прочёл
--- бы началом следующего ответа. Поэтому пустые куски пропускаются здесь.
---
--- Отказ источника (`nil, err`, бросок, кусок не строкой) бросается
--- наружу, а не кончает цикл: кончившийся цикл сервер закрывает
--- завершающим куском, и клиент получил бы обрезанную выгрузку как
--- целую. Брошенное сервер не ловит — файбер соединения закрывает сокет
--- без завершающего куска, и клиент видит обрыв. Подробность отказа
--- уходит в журнал фасадом здесь же, а наружу бросается одно общее
--- слово: брошенное ядро пишет своим журналом как есть.
---
--- Шаг идёт в контексте запроса, собравшего ответ (`context.bind`).
--- Тело сервер обходит, когда обработчик уже вернул ответ, а слои входа
--- вышли из своих областей, и контекст файбера соединения к этому мигу
--- пуст. Без снимка запись об обрыве не несла бы ни `request_id`,
--- ни `trace_id`, и обрыв выгрузки не связать было бы ни с запросом,
--- ни с клиентом; то же — записи самого источника и его обращения
--- к соседям. Снимок берётся при сборке ответа, а не при обходе: ответ
--- принадлежит запросу, который его собрал.
---
--- Итог потока пишется здесь же: «поток ответа отдан» на конце,
--- «поток ответа оборван» на обрыве — обе с длительностью от сборки
--- ответа (`seconds`) и числом байт, отданных источником (`bytes`). Запись
--- слоя журнала и ряды метрик кончаются в миг возврата обработчика,
--- и выгрузка длиной в минуты числилась бы там запросом в десятки
--- микросекунд. Клиент, ушедший посреди потока, не оставляет ни той,
--- ни другой записи: сервер узнаёт об уходе на записи куска и просто
--- перестаёт звать шаг.
---@param produce fun(): string|nil, any
---@return fun(): string|nil, string|nil
local function stepping(produce)
    local started = source().monotonic()
    local bytes = 0

    --- Поля итоговой записи: сколько поток шёл и сколько отдал.
    ---@param fields table<string, any>
    ---@return table<string, any>
    local function summed(fields)
        fields.seconds = source().monotonic() - started
        fields.bytes = bytes

        return fields
    end

    return context.bind(function()
        while true do
            local ok, part, err = pcall(produce)

            if not ok then
                -- `error()` без аргумента приносит nil, и отказ не должен
                -- от этого стать «куском nil» и крутить цикл дальше.
                err = tostring(part)
            elseif part == nil and err == nil then
                log.info(SENT_STREAM, summed({}))

                return nil
            elseif type(part) == 'string' and part ~= '' then
                bytes = bytes + #part

                return part, part
            elseif type(part) ~= 'string' then
                err = err or ('кусок ответа не строка, а %s'):format(type(part))
            end

            if err ~= nil then
                log.error(BROKEN_STREAM, summed({ reason = tostring(err) }))
                fail.raise(BROKEN_STREAM)
            end
        end
    end)
end

--- Ответ по кускам с типом содержимого по умолчанию.
---@param content_type string
---@param produce any
---@param status integer|nil
---@param headers table<string, string>|nil
---@return table
local function streamed(content_type, produce, status, headers)
    if type(produce) ~= 'function' then
        error(
            ('потоку ответа нужна функция, отдающая куски, а не %s'):format(
                type(produce)
            )
        )
    end

    return {
        status = status or OK,
        headers = lowered({ ['content-type'] = content_type }, headers),
        body = stepping(produce),
    }
end

--- Ответ телом по кускам (`Transfer-Encoding: chunked`).
---
--- Для того, что нельзя или незачем держать в памяти целиком: выгрузки
--- журнала, большого списка. `produce` зовётся за каждым куском, пока
--- не вернёт `nil`; отказ посреди — `nil, err`. Между кусками сервер
--- пишет в сокет и уступает, так что медленный клиент тормозит источник,
--- а не копит память.
---
--- Длина заранее не известна, и заголовка `content-length` у ответа нет.
--- Для проверки без сервера тело обходится так же, как его обходит
--- сервер: `for _, part in response.body do ... end`.
---
--- Источник зовётся в контексте запроса, собравшего ответ, — его записи
--- журнала несут `request_id` и `trace_id` запроса. Итог потока фасад
--- пишет сам: «поток ответа отдан» или «поток ответа оборван», с полями
--- `seconds` (от сборки ответа) и `bytes`.
---@param produce fun(): string|nil, any Следующий кусок; nil — конец, nil, err — обрыв
---@param status integer|nil Код ответа; по умолчанию 200
---@param headers table<string, string>|nil Заголовки; тип по умолчанию application/octet-stream
---@return table
function Module.stream(produce, status, headers)
    return streamed(OCTETS, produce, status, headers)
end

--- Страница по кускам: поток с типом страницы.
---
--- У потока тип по умолчанию — поток байтов, и страница, отданная им,
--- ушла бы браузеру файлом на скачивание. Кусок страницы — тот же HTML
--- в UTF-8, что и страница строкой (`html`), и тип у них один.
---@param produce fun(): string|nil, any Следующий кусок; nil — конец, nil, err — обрыв
---@param status integer|nil Код ответа; по умолчанию 200
---@param headers table<string, string>|nil Заголовки поверх типа страницы
---@return table
function Module.html_stream(produce, status, headers)
    return streamed(TYPES.html --[[@as string]], produce, status, headers)
end

return Module

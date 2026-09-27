--- Слой `etag`: метка версии ответа по отпечатку тела и 304 на
--- `If-None-Match`.
---
---     web.group('/', { middleware = { router.etag() } }, function(r)
---         r.get('/customers', list)
---     end)
---
--- Страница, собранная заново на каждый запрос, без метки уходит целиком
--- всякий раз: браузеру, у которого та же страница уже есть, не с чем
--- сравнить, и спросить «не изменилась ли» он не может. С меткой он
--- приходит с ней в `If-None-Match` и получает 304 без тела.
---
--- Метка — crc32 тела тем же видом, что у раздачи файлов
--- (`files.store.tag_of`), и сверяется тем же правилом RFC 9110
--- (`files.caching.matched`): списком, слабая пометка `W/` не мешает,
--- `*` — любая. Метку, которую обработчик поставил сам, слой не
--- пересчитывает, а сверяет: версия данных бывает известна и без тела.
---
--- Сберегается сеть, а не узел: тело известно, только когда страница
--- нарисована, и рисуется она на каждый запрос, как и без слоя.
---
--- Слой трогает только ответ 200 с телом-строкой на GET и HEAD. У потока
--- тела заранее нет, а 304 бывает лишь вместо 200 на чтение — на прочие
--- способы совпавшее условие RFC велит отвечать 412, и это дело
--- обработчика, а не слоя. Место слоя — маршрут или группа
--- (`middleware`): на входе роутера ответ на HEAD уже без тела, и слой
--- его пропускает — метка пустоты разошлась бы с меткой ответа на GET.
---
--- Под слоем сжатия, стоящим на входе, клиент с gzip получает метку
--- слабой (`W/`): сжатое тело — другое представление. Сверка снимает
--- пометку, и 304 по слабой метке приходит так же, как по сильной.

local caching = require('tnt.router.files.caching')
local store = require('tnt.router.files.store')

local Module = {}

--- Код ответа, вместо которого бывает 304.
local OK = 200

--- Годится ли ответ под метку.
---@param request table
---@param response any
---@return boolean
local function eligible(request, response)
    -- Одним выражением, без ветки «нет»: у ветки `return false` мутант
    -- `return nil` неотличим — условие читает оба одинаково.
    --
    -- Пустое тело у HEAD — тело, которое роутер уже снял: слой стоит
    -- на входе. Метки для него нет, и 304 тоже.
    return type(response) == 'table'
        and response.status == OK
        and type(response.body) == 'string'
        and (request.method == 'GET' or (request.method == 'HEAD' and response.body ~= ''))
end

--- Собирает слой.
---
--- Заголовки ответа копируются: таблица принадлежит обработчику, и он
--- вправе отдавать одну и ту же на каждый запрос — метка уехала бы
--- в следующий ответ.
---@return fun(request: table, nxt: fun(request: table): any, any): any, any
function Module.layer()
    return function(request, nxt)
        local response, failed = nxt(request)

        if not eligible(request, response) then
            return response, failed
        end

        local headers = {}

        for name, value in pairs(response.headers or {}) do
            headers[name] = value
        end

        headers.etag = headers.etag or store.tag_of(response.body)

        local given = request.headers['if-none-match']

        -- Заголовки 304 — те же, что у 200: по RFC 9110 (15.4.5) он несёт
        -- всё, чем клиент обновит запись в кэше, а заголовки обработчика
        -- (кука) клиент ждёт и здесь. Тип — тоже: без него `http.server`
        -- подставил бы `text/plain`, и кэш, обновляющий запись по 304
        -- (RFC 9111, 3.2), отдавал бы страницу текстом. Длину тела сервер
        -- у 304 ставит свою.
        if given ~= nil and caching.matched(given, headers.etag) then
            return { status = 304, headers = headers }
        end

        return { status = OK, headers = headers, body = response.body }
    end
end

return Module

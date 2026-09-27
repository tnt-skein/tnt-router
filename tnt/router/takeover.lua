--- Ответ, который забирает соединение себе: смена протокола.
---
--- Обычный ответ пишет сам `http.server`: строку статуса, заголовки, тело,
--- — а потом ждёт на том же соединении следующий запрос. Смене протокола
--- (WebSocket, RFC 6455) так нельзя. Заголовок `Connection` сервер выводит
--- сам, из заголовков запроса, и `Upgrade` у него становится `close`;
--- дописывает `Content-Length: 0`; а после ответа читает из соединения
--- новый запрос HTTP там, где уже идут кадры.
---
--- Поэтому ответ с полем `takeover` — функцией, которой отдаётся
--- соединение, — пишет не сервер, а подключение роутера: голову ответа
--- прямо в сокет, и сразу зовёт `takeover(socket)` в том же файбере
--- соединения. Пока она идёт, сервер соединения не трогает; когда она
--- вернулась, сервер получает свой знак `DETACHED` и закрывает сокет,
--- ничего в него не дописав. Жизнь соединения — это жизнь вызова
--- `takeover`: вернуться из неё раньше конца разговора значит его кончить.
---
--- Слои видят такой ответ как всякий другой: журнал пишет статус 101,
--- заголовок опознавателя уезжает в голову ответа. Без сервера — `dispatch`
--- в проверке — поле едет в ответе как есть, и проверка зовёт `takeover`
--- сама, двойником сокета.

local http_codes = require('http.codes')
local http_server = require('http.server')

local log = require('tnt.log').new('tnt.router')

local Module = {}

--- Знак серверу: соединение забрали, отвечать и читать дальше не надо.
Module.DETACHED = http_server.DETACHED

--- Голова ответа: строка статуса и заголовки, без тела.
---
--- Заголовки идут по порядку имён: одна и та же таблица даёт одни и те же
--- байты, и проверка сверяет их строкой. Значение-список — несколько строк
--- с одним именем, как у самого сервера (`set-cookie`). Слово статуса
--- берётся из таблицы рока; незнакомому статусу слова нет, и по RFC 9112
--- оно вправе быть пустым.
---@param response table Ответ роутера: `status` и `headers`
---@return string
function Module.head_of(response)
    local status = response.status
    local headers = response.headers or {}
    local lines = { ('HTTP/1.1 %d %s\r\n'):format(status, http_codes[status] or '') }
    local names = {}

    for name in pairs(headers) do
        table.insert(names, name)
    end

    table.sort(names)

    for _, name in ipairs(names) do
        local value = headers[name]

        if type(value) ~= 'table' then
            value = { value }
        end

        for _, each in ipairs(value) do
            table.insert(lines, ('%s: %s\r\n'):format(name, tostring(each)))
        end
    end

    table.insert(lines, '\r\n')

    return table.concat(lines)
end

--- Отдаёт серверу ответ роутера: обычный — как есть, смену протокола — сам.
---
--- Упавший `takeover` соединение просто кончает: ответ уже ушёл, и сказать
--- клиенту по HTTP больше нечего, — подробность уходит в журнал. Клиент,
--- ушедший до головы ответа, до `takeover` не доходит вовсе: отдавать ему
--- нечего, а разговаривать не с кем.
---@param incoming table Запрос `http.server`: сокет в поле `s`
---@param response table Ответ роутера
---@return table|integer answer Ответ серверу либо его знак `DETACHED`
function Module.served(incoming, response)
    local takeover = response.takeover

    if type(takeover) ~= 'function' then
        return response
    end

    local socket = incoming.s

    if socket:write(Module.head_of(response)) == nil then
        log.warn('клиент ушёл до смены протокола', {
            path = incoming.path,
            reason = tostring(socket:error()),
        })

        return Module.DETACHED
    end

    local ok, err = pcall(takeover, socket)

    if not ok then
        log.error('соединение после смены протокола кончилось отказом', {
            path = incoming.path,
            reason = tostring(err),
        })
    end

    return Module.DETACHED
end

return Module

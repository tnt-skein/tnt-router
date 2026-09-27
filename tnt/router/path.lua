--- Путь и шаблон: разбор на участки и сборка обратно.
---
--- Путь режется на участки до раскодирования, а раскодируется каждый
--- участок отдельно. Порядок здесь важнее, чем кажется: «%2F» — это косая
--- черта внутри одного участка, а не разделитель, и роутер, начавший
--- с раскодирования всего пути, найдёт по `/files/a%2Fb` два участка
--- вместо одного и уедет не в тот маршрут. На этом обжигались все, у кого
--- разбор начинался с unescape.
---
--- Участки шаблона бывают трёх видов: постоянный (`customers`), параметр
--- (`:id`, он же `:id?` необязательный и `:id<int>` с ограничением)
--- и хвост (`*path`). Хвост забирает остаток пути вместе с косыми чертами
--- и потому бывает только последним — иначе «остаток» кончался бы там,
--- где начинается следующий участок, а это уже не хвост.
---
--- Ошибка в шаблоне — исключение, а не пара `nil, err`: шаблон пишется
--- кодом, и опечатка в нём обязана обнаружиться при загрузке модуля,
--- а не в ответе клиенту. Бросается она без места (`fail.raise`): место —
--- строку маршрута или группы — приписывает вход роутера
--- (`tnt.router.blame`), а кадров от него до разбора участка разное число.

local fail = require('tnt.must.fail')

local Module = {}

--- Знаки, которые в пути не кодируются: незарезервированные по RFC 3986.
---
--- Всё остальное уходит в `%XX`. Кодировать с запасом безопаснее, чем
--- недокодировать: лишний `%2C` браузер разберёт, а непрошенная косая
--- черта внутри значения превратит один участок в два.
local UNRESERVED = '%w%-%._~'

--- Режет путь на участки, не трогая их содержимое.
---
--- Пустые участки пропадают: `//customers//7` и `/customers/7` — один
--- и тот же адрес, и заводить на них два маршрута незачем.
---@param text string
---@return string[]
function Module.split(text)
    local parts = {}

    for part in text:gmatch('[^/]+') do
        table.insert(parts, part)
    end

    return parts
end

--- Раскодирует `%XX` в участке пути.
---@param text string
---@return string
function Module.decode(text)
    return (
        text:gsub('%%(%x%x)', function(hex)
            return string.char(tonumber(hex, 16) --[[@as integer]])
        end)
    )
end

--- Кодирует значение для подстановки в путь.
---@param text string
---@param keep_slash boolean Оставить ли косую черту (для хвоста)
---@return string
function Module.encode(text, keep_slash)
    local safe = keep_slash and ('[^' .. UNRESERVED .. '/]') or ('[^' .. UNRESERVED .. ']')

    return (text:gsub(safe, function(char)
        return ('%%%02X'):format(char:byte())
    end))
end

--- Участки пути запроса, раскодированные по одному.
---@param text string
---@return string[]
function Module.segments(text)
    local parts = Module.split(text)

    for index, part in ipairs(parts) do
        parts[index] = Module.decode(part)
    end

    return parts
end

--- Путь одной записью: по ней подписывают ссылку и пишут канонический адрес.
---
--- Один и тот же адрес приходит разными записями: `%7e` и `~`, `%d0%bf`
--- и `%D0%BF`, `//a/` и `/a`. Прокси, почтовый клиент и браузер вправе
--- переписать запись, не меняя адреса, и подпись, посчитанная по записи,
--- отказывала бы честной ссылке. Поэтому участки раскодируются по одному
--- и кодируются заново — тем же кодированием, что у сборки адреса
--- по имени, — а пустые пропадают, как и при поиске маршрута. Косая черта
--- внутри участка (`%2F`) остаётся закодированной: `/a%2Fb` и `/a/b` —
--- разные адреса и разные маршруты.
---@param text string Путь, как пришёл
---@return string
function Module.canonical(text)
    local parts = Module.segments(text)

    for index, part in ipairs(parts) do
        parts[index] = Module.encode(part, false)
    end

    return '/' .. table.concat(parts, '/')
end

---@class TntRouterSegment
---@field kind string Вид участка: static, param или wildcard
---@field text string|nil Содержимое постоянного участка
---@field name string|nil Имя параметра или хвоста
---@field optional boolean Можно ли обойтись без участка
---@field constraint string|nil Имя ограничения из шаблона
---@field check (fun(value: string): boolean)|nil Готовая проверка значения

--- Разбирает один участок шаблона.
---@param part string
---@param pattern string Весь шаблон: нужен в тексте ошибки
---@return TntRouterSegment
local function segment_of(part, pattern)
    if part:find('%*') == 1 then
        local tail = part:match('^%*([%w_]+)$')

        if tail == nil then
            -- Безымянный хвост — это забытое имя, а не участок «звёздочка»:
            -- значение такого хвоста обработчику взять неоткуда.
            fail.raise(('хвост «%s» в «%s» остался без имени'):format(part, pattern))
        end

        -- Хвост подходит и к пустому остатку: шаблон файлов со
        -- звёздочкой обязан отвечать и на путь без неё, иначе корень
        -- раздачи открыть нечем.
        return { kind = 'wildcard', name = tail, optional = true }
    end

    -- Двоеточие и ничего после него — тоже параметр, просто безымянный:
    -- принять его постоянным участком значит завести маршрут, которого
    -- никто не объявлял.
    local body = part:match('^:(.*)$')

    if body == nil then
        return { kind = 'static', text = Module.decode(part), optional = false }
    end

    -- Знак вопроса снимается вместе с пометкой: оставленный, он вошёл бы
    -- в имя параметра, и обработчик спрашивал бы `params['id?']`.
    local trimmed, marks = body:gsub('%?$', '')
    local optional = marks == 1

    local name, constraint = trimmed:match('^([%w_]+)<([%w_]+)>$')

    if name == nil then
        name = trimmed:match('^([%w_]+)$')
    end

    if name == nil then
        fail.raise(('участок «%s» шаблона «%s» не разобран'):format(part, pattern))
    end

    return { kind = 'param', name = name, optional = optional, constraint = constraint }
end

--- Требует, чтобы шаблон начинался с косой черты.
---@param pattern any
local function absolute(pattern)
    if type(pattern) ~= 'string' or pattern:find('/') ~= 1 then
        fail.raise(
            ('шаблон маршрута начинается с косой черты, а не «%s»'):format(
                tostring(pattern)
            )
        )
    end
end

--- Склеивает начало группы с шаблоном маршрута.
---
--- Проверка нужна именно здесь: `/api` и `customers` склеились бы
--- в `/apicustomers` — путь, который с косой черты начинается и потому
--- разбирается молча, а открыть его нельзя ничем.
---@param prefix string
---@param pattern string
---@return string
function Module.join(prefix, pattern)
    absolute(pattern)

    return prefix .. pattern
end

--- Разбирает шаблон маршрута.
---@param pattern string
---@return TntRouterSegment[]
function Module.compile(pattern)
    absolute(pattern)

    local parts = Module.split(pattern)
    local segments = {}
    local seen = {}
    local skippable = false

    for index, part in ipairs(parts) do
        local segment = segment_of(part, pattern)

        if segment.kind == 'wildcard' and index ~= #parts then
            fail.raise(
                ('хвост «%s» бывает только последним в «%s»'):format(part, pattern)
            )
        end

        -- Необязательный участок посреди пути — всегда обязательный:
        -- выкинуть его нельзя, не склеив соседей в другой адрес.
        -- Молчать об этом значит отдать разработчику маршрут, который
        -- он считает необязательным, а тот требует участок.
        if skippable and not segment.optional then
            fail.raise(
                ('за необязательным участком в «%s» стоит обязательный'):format(
                    pattern
                )
            )
        end

        skippable = skippable or segment.optional

        if segment.name ~= nil then
            if seen[segment.name] then
                fail.raise(
                    ('параметр «%s» в «%s» назван дважды'):format(segment.name, pattern)
                )
            end

            seen[segment.name] = true
        end

        table.insert(segments, segment)
    end

    return segments
end

--- Что подставить вместо участка при сборке адреса.
---@param segment TntRouterSegment
---@param given table<string, any>
---@return string|nil piece
---@return string|nil err
local function piece_of(segment, given)
    if segment.kind == 'static' then
        return Module.encode(segment.text --[[@as string]], false)
    end

    local value = given[segment.name]

    if value == nil then
        if segment.optional then
            return nil
        end

        return nil, ('не задан параметр «%s»'):format(segment.name)
    end

    return Module.encode(tostring(value), segment.kind == 'wildcard')
end

--- Собирает путь по разобранному шаблону и значениям параметров.
---@param segments TntRouterSegment[]
---@param params table<string, any>|nil
---@return string|nil path
---@return string|nil err
function Module.render(segments, params)
    local given = params or {}
    local parts = {}

    for _, segment in ipairs(segments) do
        local piece, err = piece_of(segment, given)

        if err ~= nil then
            return nil, err
        end

        if piece ~= nil then
            table.insert(parts, piece)
        end
    end

    return '/' .. table.concat(parts, '/')
end

return Module

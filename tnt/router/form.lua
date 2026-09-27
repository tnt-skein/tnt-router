--- Форма из тела запроса: поля браузера и присланные файлы.
---
--- Браузер шлёт форму двумя видами, и оба приходят телом: обычную —
--- парами `имя=значение` (`application/x-www-form-urlencoded`), форму
--- с файлом — частями с границей (`multipart/form-data`). Пока разбор
--- живёт в обработчике, каждое приложение пишет его заново: где-то
--- забывают про повторённое имя, где-то про `%D1%84`, а файл не умеет
--- принять никто.
---
--- Разобранное лежит в двух местах, а не в одном: `request.form` — поля,
--- `request.files` — присланные файлы. Одна таблица на оба смысла
--- заставляла бы обработчик проверять, что пришло под именем `avatar` —
--- строка или файл, — и промах в этой проверке уезжает в хранилище молча.
---
--- Решения, о которых стоит знать.
---
--- **Повторённое имя собирается в список**, как и в строке запроса:
--- `tag=a&tag=b` — это два значения одного поля, и молчаливая потеря
--- первого однажды теряет половину выбранных галочек.
---
--- **Пределы приходят оттуда же, откуда предел тела.** Форма разбирается
--- на границе, до маршрута, и защищать узел от неё должен тот же, кто
--- защищает от тела: числа полей, частей и размеров задаются при
--- подключении роутера к серверу (`attach`).
---
--- **Часть без выбранного файла пропускается.** Пустое поле `<input
--- type="file">` браузер шлёт как часть с пустым именем файла и пустым
--- телом. Положить её в `files` значило бы отдать обработчику файл
--- в ноль байт с именем `file` — и он сохранил бы его как настоящий.
---
--- **Перекодировки нет.** Поле приходит байтами в кодировке формы,
--- и это UTF-8 у всякого браузера с прошлого десятилетия. Кодировка,
--- названная частью, доезжает до обработчика полем `charset`, но
--- содержимое не трогается: перекодировать вслепую — значит испортить
--- то, что пришло правильным.

local log = require('tnt.log').new('tnt.router')

local multipart = require('tnt.router.multipart')
local upload = require('tnt.router.upload')

local Module = {}

--- Обычная форма браузера.
Module.URLENCODED = 'application/x-www-form-urlencoded'

--- Форма с файлами.
Module.MULTIPART = 'multipart/form-data'

--- Пустая форма: таблицы новые на каждый запрос.
---
--- Общая таблица уехала бы в обработчик, и дописанное им поле досталось бы
--- следующему запросу — тому, который формы не присылал вовсе.
---@return TntRouterForm
local function empty()
    return { fields = {}, files = {} }
end

---@class TntRouterForm
---@field fields table<string, string|string[]> Поля формы
---@field files table<string, TntRouterUpload|TntRouterUpload[]> Присланные файлы

--- Раскодирует `%XX` и «+».
---
--- Плюс — пробел: так его пишет форма браузера и так же его пишет строка
--- запроса. В пути он значит сам себя, и там раскодировать его нельзя.
---@param text string
---@return string
function Module.decode(text)
    local plus = text:gsub('%+', ' ')

    return (
        plus:gsub('%%(%x%x)', function(hex)
            return string.char(tonumber(hex, 16) --[[@as integer]])
        end)
    )
end

--- Добавляет разобранное значение к полям.
---
--- Повторённое имя собирается в список: `tag=a&tag=b` — это два значения
--- одного поля.
---@param fields table<string, any>
---@param name string
---@param value any
function Module.gather(fields, name, value)
    local previous = fields[name]

    if previous == nil then
        fields[name] = value
    -- Присланный файл — тоже таблица, и дописать в него второе значение
    -- значило бы испортить первый файл. Список узнаётся по отсутствию
    -- поля, которое есть у всякого файла.
    elseif type(previous) == 'table' and previous.field == nil then
        table.insert(previous, value)
    else
        fields[name] = { previous, value }
    end
end

--- Отказ разбора формы: код по договору границы, подробность для журнала.
---@param status integer
---@param reason string
---@return nil
---@return TntRouterFailure
local function refuse(status, reason)
    return nil, { status = status, reason = reason }
end

--- Предел, который не задан: с ним сравнение проходит всегда.
---
--- Строка запроса разбирается тем же кодом, что и тело формы, а пределы
--- у неё свои: длину строки запроса держит сервер, и отказать по числу
--- полей адреса значило бы отвечать 413 на осмысленный запрос.
local NO_LIMIT = math.huge

--- Разбирает пары `имя=значение`.
---@param text string|nil
---@param limits table|nil Пределы формы; `nil` — без пределов
---@return table<string, any>|nil fields
---@return TntRouterFailure|nil failure
function Module.pairs_of(text, limits)
    local fields = {}
    local max_fields = limits and limits.max_fields or NO_LIMIT
    local max_size = limits and limits.max_field_size or NO_LIMIT
    local count = 0

    for _, pair in ipairs(tostring(text or ''):split('&')) do
        local name, value = pair:match('^([^=]*)=?(.*)$')

        if name ~= '' then
            count = count + 1

            if count > max_fields then
                return refuse(413, ('полей в форме больше предела в %d'):format(max_fields))
            end

            if #pair > max_size then
                return refuse(413, ('поле формы больше предела в %d байт'):format(max_size))
            end

            Module.gather(fields, Module.decode(name --[[@as string]]), Module.decode(value --[[@as string]]))
        end
    end

    return fields
end

--- Приёмник текстовой части: значение копится строкой.
---@param part TntRouterPart
---@param fields table<string, any>
---@param limits table
---@return TntRouterPartSink
local function texted(part, fields, limits)
    local chunks = {}
    local size = 0

    return {
        write = function(chunk)
            size = size + #chunk

            if size > limits.max_field_size then
                return false,
                    {
                        status = 413,
                        reason = ('поле «%s» больше предела в %d байт'):format(
                            part.name,
                            limits.max_field_size
                        ),
                    }
            end

            table.insert(chunks, chunk)

            return true
        end,

        close = function()
            Module.gather(fields, part.name, table.concat(chunks))

            return true
        end,

        -- Бросать нечего: значение копится в памяти и уходит вместе
        -- с приёмником.
        abort = function() end,
    }
end

--- Приёмник части с файлом: память, пока она помещается, дальше — диск.
---@param part TntRouterPart
---@param files table<string, any>
---@param limits table
---@return TntRouterPartSink
local function filed(part, files, limits)
    local sink = upload.sink({
        field = part.name,
        filename = part.filename --[[@as string]],
        type = part.type,
        charset = part.charset,
        in_memory = limits.in_memory,
        max_size = limits.max_file_size,
        temp_dir = limits.temp_dir,
    })

    return {
        write = sink.write,
        abort = sink.abort,

        close = function()
            local file, failure = sink.close()

            if file == nil then
                return false, failure
            end

            -- Поле `<input type="file">`, в котором ничего не выбрали,
            -- браузер всё равно шлёт: часть с пустым именем и пустым телом.
            if file.client_name == '' and file.size == 0 then
                return true
            end

            Module.gather(files, part.name, file)

            return true
        end,
    }
end

--- Убирает временные файлы запроса.
---
--- Уборка идёт после ответа и при всяком исходе. Отказ уборки — не отказ
--- запроса: клиенту уже ответили, а знать о неубранном должен дежурный,
--- потому что такие файлы копятся молча.
---@param files table<string, any>|nil
function Module.cleanup(files)
    for _, value in pairs(files or {}) do
        local kept = value.remove ~= nil and { value } or value

        for _, file in ipairs(kept) do
            -- Убирается только то, что умеет убираться: под именем поля
            -- приложение вправе написать в запрос свою таблицу, и ронять
            -- из-за неё ответ, который уже ушёл клиенту, нельзя.
            if type(file.remove) == 'function' then
                local removed, err = file:remove()

                if not removed then
                    log.warn('временный файл не убран', { reason = err })
                end
            end
        end
    end
end

--- Разбирает многочастное тело в поля и файлы.
---@param read fun(): string|nil, TntRouterFailure|nil Источник байтов
---@param params table<string, string> Параметры заголовка `Content-Type`
---@param limits table Проверенные пределы
---@return TntRouterForm|nil
---@return TntRouterFailure|nil
function Module.multipart_of(read, params, limits)
    local boundary, failure = multipart.boundary_of(params)

    if boundary == nil then
        return nil, failure
    end

    local form = empty()
    local taken = 0

    --- Куда писать очередную часть.
    ---@param part TntRouterPart
    ---@return TntRouterPartSink|nil
    ---@return TntRouterFailure|nil
    local function open(part)
        if part.filename == nil then
            return texted(part, form.fields, limits)
        end

        taken = taken + 1

        if taken > limits.max_files then
            return refuse(
                413,
                ('файлов в форме больше предела в %d'):format(limits.max_files)
            )
        end

        return filed(part, form.files, limits)
    end

    local parsed, problem = multipart.parse(read, boundary, limits.max_parts, open)

    if not parsed then
        -- Отказ не должен оставлять за собой временные файлы: до него
        -- части могли уже уехать на диск, а ответ пойдёт мимо уборки.
        Module.cleanup(form.files)

        return nil, problem
    end

    return form
end

--- Какой формой назвали тело и с какими параметрами.
---
--- Спрашивают об этом и разбор тела из строки, и подключение к серверу:
--- многочастное тело читается потоком из соединения, а обычное — целиком,
--- и решает это один и тот же заголовок.
---@param headers table<string, any>|nil Заголовки, имена в нижнем регистре
---@return string kind Вид содержимого в нижнем регистре
---@return table<string, string> params Параметры заголовка
function Module.kind_of(headers)
    return multipart.media((headers or {})['content-type'])
end

--- Источник байтов из строки: тело, написанное в проверке или пришедшее целиком.
---@param body string
---@return fun(): string|nil, TntRouterFailure|nil
function Module.from_string(body)
    local given = false

    return function()
        if given then
            return ''
        end

        given = true

        return body
    end
end

--- Форма запроса: поля и файлы.
---
--- Разбирается то, что пришло телом, и только если клиент назвал вид
--- формы. Тело JSON, текста и чего угодно ещё остаётся телом: разбирать
--- его по догадке значит однажды прочитать как форму то, что ею не было.
---@param request table Разобранный запрос: заголовки в нижнем регистре
---@param limits table Проверенные пределы
---@return TntRouterForm
---@return TntRouterFailure|nil
function Module.of(request, limits)
    -- Форма таблицей — уже разобранная: многочастное тело разбирает
    -- подключение к серверу, а проверка пишет форму руками.
    if type(request.form) == 'table' then
        local files = type(request.files) == 'table' and request.files or {}

        return { fields = request.form, files = files }
    end

    if type(request.body) ~= 'string' then
        return empty()
    end

    local kind, params = Module.kind_of(request.headers)

    if kind == Module.URLENCODED then
        local fields, failure = Module.pairs_of(request.body, limits)

        if fields == nil then
            return empty(), failure
        end

        return { fields = fields, files = {} }
    end

    if kind ~= Module.MULTIPART then
        return empty()
    end

    local form, problem = Module.multipart_of(Module.from_string(request.body), params, limits)

    if form == nil then
        return empty(), problem
    end

    -- Тело съедено разбором: второй копии формы с вложением в памяти
    -- не держат ни по сети, ни в проверке, написанной таблицей.
    request.body = ''

    return form
end

return Module

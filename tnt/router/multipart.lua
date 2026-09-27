--- Многочастное тело (RFC 7578): разбор потоком, без второй копии в памяти.
---
--- Форма с файлом приходит одним телом, в котором части разделены меткой
--- границы. Разобрать его строкой нельзя: тело с вложением — это десятки
--- мегабайт, и строка с ними жила бы в памяти узла целиком, да ещё
--- дважды — сырым телом и кусками частей.
---
--- Поэтому разбор идёт над источником байтов: `read()` отдаёт очередной
--- кусок, а разбор держит в памяти только этот кусок и хвост длиной
--- с границу. Куда уходит тело части, решает не он: `open(part)` отдаёт
--- приёмник, и приёмник сам выбирает между памятью и временным файлом
--- (`tnt.router.upload`). Так один и тот же разбор служит и телу
--- из сокета, и телу, написанному строкой в проверке.
---
--- Решения, о которых стоит знать.
---
--- **Перед первой границей стоит пустая строка, которой в теле нет.**
--- Граница по RFC — это `CRLF--метка`, и у самой первой границы этого
--- `CRLF` в теле нет. Буфер поэтому начинается с `CRLF`: одно правило
--- на все границы дешевле отдельной ветки для первой.
---
--- **Расширенная запись имени файла (RFC 5987, `filename*`) не читается.**
--- RFC 7578 (§4.2) прямо запрещает её в форме, а браузеры её и не шлют:
--- имя приходит параметром `filename` байтами в кодировке формы.
---
--- **Кодировка части не раскодируется.** `Content-Transfer-Encoding`
--- в форме запрещён тем же RFC; часть с кодировкой, отличной от `binary`,
--- `7bit` и `8bit`, — отказ, а не молча принятый base64. Принять его
--- за байты значило бы записать в файл текст вместо картинки.

local Module = {}

--- Разделитель строк: им отделены и границы, и заголовки частей.
local CRLF = '\r\n'

--- Начало границы: два дефиса перед меткой.
local DASHES = '--'

--- Конец заголовков части: пустая строка.
local HEADERS_END = CRLF .. CRLF

--- Сколько байт заголовков части принимать.
---
--- Не настройка: заголовки части пишет не человек, а клиент формы, и
--- восьми килобайт хватает самому длинному имени файла с запасом.
--- Предел нужен от обратного — от части, у которой конца заголовков
--- нет вовсе: без него разбор копил бы её в памяти до конца тела.
local HEADERS_LIMIT = 8192

--- Кодировки части, которые значат «байты как есть».
---@type table<string, boolean>
local PLAIN_ENCODINGS = { binary = true, ['7bit'] = true, ['8bit'] = true }

--- Кодировка по умолчанию: заголовка в форме не бывает.
local PLAIN_ENCODING = 'binary'

--- Какое расположение части считается полем формы.
local FORM_DATA = 'form-data'

--- Отказ разбора: код по договору границы HTTP и подробность для журнала.
---@param status integer
---@param reason string
---@return nil
---@return TntRouterFailure
local function refuse(status, reason)
    return nil, { status = status, reason = reason }
end

--- Отказ «тело не разобрано»: подробность уходит в журнал, наружу — 400.
---@param reason string
---@return nil
---@return TntRouterFailure
local function broken(reason)
    return refuse(400, reason)
end

--- Режет значение заголовка по точкам с запятой, не трогая их в кавычках.
---
--- Кавычки снимаются здесь же: `filename="отчёт; за год.pdf"` — это одно
--- значение с точкой с запятой внутри, и разрезать его по ней значит
--- потерять половину имени. Обратная косая черта в кавычках экранирует
--- следующий знак (RFC 9110, quoted-string).
---@param text string
---@return string[]
local function pieces(text)
    local parts = {}
    local current = {}
    local quoted = false
    local escaped = false

    -- Обход знаками, а не по номерам: у `gmatch('.')` нет ни начала,
    -- ни конца, которые можно сдвинуть на единицу незаметно.
    for char in text:gmatch('.') do
        if escaped then
            table.insert(current, char)
            escaped = false
        elseif quoted and char == '\\' then
            escaped = true
        elseif char == '"' then
            quoted = not quoted
        elseif char == ';' and not quoted then
            table.insert(parts, table.concat(current))
            current = {}
        else
            table.insert(current, char)
        end
    end

    table.insert(parts, table.concat(current))

    return parts
end

--- Пробелы по краям прочь.
---
--- Одним образцом, а не двумя заменами: у `gsub('^%s+', '')` подмена
--- повтора на «ноль и больше» даёт ту же строку на любом входе, и такого
--- мутанта нечем убить. Здесь же образец обязан совпасть целиком, и любая
--- его подмена оставляет строку без совпадения — то есть `nil`.
---@param text string
---@return string
local function trimmed(text)
    return text:match('^%s*(.-)%s*$') --[[@as string]]
end

--- Значение заголовка с параметрами: `multipart/form-data; boundary=x`.
---
--- Имя вида и имена параметров приводятся к нижнему регистру: по RFC 9110
--- они нечувствительны к регистру, а сравнивают их потом с написанным
--- строчными. Значения параметров остаются как есть — имя файла регистр
--- различает.
---@param value any Значение заголовка; `nil` читается как пустое
---@return string kind Вид содержимого в нижнем регистре
---@return table<string, string> params Параметры
function Module.media(value)
    local parts = pieces(tostring(value or ''))
    -- Вид снимается первым куском, а не читается обходом с двойки:
    -- сдвинутое начало обхода прочло бы сам вид как параметр, и заметить
    -- это было бы нечем — знака равенства в нём обычно нет.
    local kind = trimmed(table.remove(parts, 1))
    local params = {}

    for _, piece in ipairs(parts) do
        local name, text = piece:match('^%s*([^=%s]+)%s*=%s*(.-)%s*$')

        if name ~= nil then
            params[name:lower()] = text
        end
    end

    return kind:lower(), params
end

--- Метка границы, если тело многочастное и метка у него есть.
---
--- Тело `multipart/form-data` без `boundary` разобрать нечем: делить его
--- не на что. Это не поломка узла, а негодный запрос — отказ 400.
---@param params table<string, string> Параметры заголовка `Content-Type`
---@return string|nil boundary
---@return TntRouterFailure|nil failure
function Module.boundary_of(params)
    local boundary = params.boundary

    -- Метка длиннее семидесяти знаков запрещена RFC 2046, но отвергать
    -- по ней незачем: разбору длина безразлична, а пустая метка сделала бы
    -- границей всякий `CRLF--` в теле.
    if boundary == nil or boundary == '' then
        return broken('в multipart/form-data нет метки границы')
    end

    return boundary
end

--- Поток тела: буфер поверх источника байтов.
---
--- Буфер начинается с `CRLF` — той самой пустой строки, которой перед
--- первой границей в теле нет (см. шапку модуля).
---@class TntRouterMultipartStream
---@field read fun(): string|nil, TntRouterFailure|nil
---@field buffer string
local Stream = {}
Stream.__index = Stream

--- Заводит поток над источником.
---@param read fun(): string|nil, TntRouterFailure|nil Кусок тела; `''` — конец
---@return TntRouterMultipartStream
local function streamed(read)
    return setmetatable({ read = read, buffer = CRLF }, Stream)
end

--- Дочитывает очередной кусок в буфер.
---
--- Своей отметки «поток кончился» здесь нет: источник, кончившийся
--- однажды, отвечает пустой строкой и дальше — и тот, что читает
--- соединение, и тот, что отдаёт строку. Отметка была бы вторым знанием
--- об одном и том же, и разойтись они могут только молча.
---@return boolean more Есть ли что дочитывать дальше
---@return TntRouterFailure|nil failure Отказ источника: обрыв, срок
function Stream:fill()
    local part, failure = self.read()

    if part == nil then
        return false, failure
    end

    self.buffer = self.buffer .. part

    -- Ответ — длина куска, а не отметка: у `return false` мутант `nil`
    -- неотличим — оба ложны, — а у сравнения с нулём всякая подмена
    -- либо кончает разбор раньше времени, либо не кончает его никогда.
    return #part > 0
end

--- Читает до разделителя, отдавая прочитанное приёмнику.
---
--- Разделитель из буфера снимается: после вызова буфер начинается с того,
--- что стоит за ним. Хвост короче разделителя приёмнику не отдаётся —
--- он может оказаться началом разделителя, разрезанного на два куска.
---@param text string Разделитель
---@param consume fun(chunk: string): boolean, TntRouterFailure|nil
---@param lost string Что сказать, если разделителя в теле так и не нашлось
---@return true|nil
---@return TntRouterFailure|nil
function Stream:until_(text, consume, lost)
    while true do
        -- Начало поиска и начало среза — отрицательным отсчётом: у единицы
        -- мутанты `0` и `1-1` дают то же самое, а сдвиг от конца буфера
        -- уводит поиск за него и виден сразу.
        local at = self.buffer:find(text, -#self.buffer, true)

        if at ~= nil then
            local taken, refusal = consume(self.buffer:sub(-#self.buffer, at - 1))

            if not taken then
                return nil, refusal
            end

            self.buffer = self.buffer:sub(at + #text)

            return true
        end

        local safe = #self.buffer - #text + 1

        if safe > 0 then
            local taken, refusal = consume(self.buffer:sub(-#self.buffer, safe))

            if not taken then
                return nil, refusal
            end

            self.buffer = self.buffer:sub(safe + 1)
        end

        local more, failure = self:fill()

        if not more then
            return nil, failure or { status = 400, reason = lost }
        end
    end
end

--- Гарантирует в буфере нужное число байт, пока их даёт источник.
---@param size integer
---@return boolean enough
---@return TntRouterFailure|nil failure
function Stream:need(size)
    while #self.buffer < size do
        local more, failure = self:fill()

        if not more then
            return false, failure
        end
    end

    return true
end

--- Дочитывает и выбрасывает остаток тела.
---
--- После закрывающей границы идёт эпилог, и длина его ограничена только
--- `Content-Length`. Оставить его в соединении нельзя: сервер дочитал бы
--- его сам — одной строкой, то есть целиком в память, — а это ровно то,
--- ради чего разбор и сделан потоковым.
---@return true|nil
---@return TntRouterFailure|nil
function Stream:drain()
    self.buffer = ''

    while true do
        local more, failure = self:fill()

        if not more then
            if failure ~= nil then
                return nil, failure
            end

            return true
        end

        self.buffer = ''
    end
end

--- Приёмник, который ничего не делает: так читается преамбула.
---@return boolean
local function ignore()
    return true
end

--- Заголовки части одной строкой.
---@param stream TntRouterMultipartStream
---@return string|nil raw
---@return TntRouterFailure|nil failure
local function headers_of(stream)
    local collected = {}
    local size = 0

    local taken, failure = stream:until_(HEADERS_END, function(chunk)
        size = size + #chunk

        if size > HEADERS_LIMIT then
            return false,
                {
                    status = 413,
                    reason = ('заголовки части больше %d байт'):format(HEADERS_LIMIT),
                }
        end

        table.insert(collected, chunk)

        return true
    end, 'часть без конца заголовков')

    if not taken then
        return nil, failure
    end

    return table.concat(collected)
end

---@class TntRouterPart
---@field name string Имя поля формы
---@field filename string|nil Имя файла, как прислал клиент; `nil` — часть не файл
---@field type string Тип содержимого части; пустая строка — не назван
---@field charset string|nil Кодировка, названная частью

--- Разбирает заголовки части в её описание.
---@param raw string
---@return TntRouterPart|nil part
---@return TntRouterFailure|nil failure
local function described(raw)
    local headers = {}

    for _, line in ipairs(raw:split(CRLF)) do
        -- Делением по первому двоеточию, а не образцом: у образца с
        -- повтором в имени подмена повтора даёт то же самое на всяком
        -- заголовке, какой шлёт клиент формы. Делить надо ровно раз:
        -- двоеточие бывает и в имени файла.
        local named = line:split(':', 1)

        -- Строка, не похожая на заголовок, пропускается: разбирать её
        -- нечем, а отказывать по ней значило бы отвергнуть часть из-за
        -- пустой строки, которой начинается блок заголовков.
        if named[2] ~= nil then
            headers[
                trimmed(named[1] --[[@as string]]):lower()
            ] = trimmed(named[2])
        end
    end

    local encoding = (headers['content-transfer-encoding'] or PLAIN_ENCODING):lower()

    if not PLAIN_ENCODINGS[encoding] then
        return broken(
            ('часть закодирована %q, а такое в форме не принимается'):format(
                encoding
            )
        )
    end

    local disposition, params = Module.media(headers['content-disposition'])

    if disposition ~= FORM_DATA then
        return broken(('часть без «Content-Disposition: form-data», а с %q'):format(disposition))
    end

    if params.name == nil then
        return broken('часть без имени поля')
    end

    local kind, extra = Module.media(headers['content-type'])

    return {
        name = params.name,
        filename = params.filename,
        type = kind,
        charset = extra.charset,
    }
end

--- Что стоит за границей: конец тела или новая часть.
---
--- Транспортный отступ (RFC 2046 разрешает пробелы за меткой) не
--- принимается: его не шлёт ни один клиент формы, а лишняя ветка здесь —
--- лишний способ принять за границу то, что ею не было.
---
--- Конец строки из буфера не снимается: он достаётся заголовкам части
--- пустой первой строкой, а её разбор пропускает. Снимать его отдельной
--- строкой значило бы завести число, сдвиг которого на единицу оставляет
--- разбор рабочим, — и убить такого мутанта нечем.
---@param stream TntRouterMultipartStream
---@return boolean|nil closing
---@return TntRouterFailure|nil failure
local function closing_of(stream)
    local enough, failure = stream:need(#CRLF)

    if not enough then
        return nil, failure or { status = 400, reason = 'тело оборвалось на границе' }
    end

    local mark = stream.buffer:sub(-#stream.buffer, #CRLF)

    if mark == DASHES then
        return true
    end

    if mark ~= CRLF then
        return broken(('за границей стоит %q, а не конец части'):format(mark))
    end

    return false
end

--- Разбирает многочастное тело.
---
--- Каждая часть отдаётся `open`: он решает, куда её писать, и отвечает
--- приёмником — таблицей с `write(chunk)`, `close()` и `abort()`. Первые
--- два отвечают парой «удалось и отказ», и отказ приёмника кончает разбор:
--- превышенный предел размера — это отказ всему запросу, а не одной части.
---
--- Часть, не дошедшая до своей границы, бросается `abort`: тело оборвалось,
--- не пришло вовремя или приёмник сам отказал посреди. До `close` такая
--- часть не доходит, и без `abort` её недописанный временный файл остался
--- бы в каталоге навсегда — в форме его нет, и уборке запроса его не найти.
---@param read fun(): string|nil, TntRouterFailure|nil Источник байтов; `''` — конец
---@param boundary string Метка границы
---@param max_parts integer Сколько частей принять
---@param open fun(part: TntRouterPart): table|nil, TntRouterFailure|nil
---@return true|nil
---@return TntRouterFailure|nil
function Module.parse(read, boundary, max_parts, open)
    local stream = streamed(read)
    local delimiter = CRLF .. DASHES .. boundary
    local found, failure = stream:until_(delimiter, ignore, 'границы нет в теле вовсе')

    if not found then
        return nil, failure
    end

    local count = 0

    while true do
        local closing, problem = closing_of(stream)

        if closing == nil then
            return nil, problem
        end

        if closing then
            return stream:drain()
        end

        count = count + 1

        if count > max_parts then
            return refuse(413, ('частей в теле больше предела в %d'):format(max_parts))
        end

        local raw, spoiled = headers_of(stream)

        if raw == nil then
            return nil, spoiled
        end

        local part, wrong = described(raw)

        if part == nil then
            return nil, wrong
        end

        local sink, denied = open(part)

        if sink == nil then
            return nil, denied
        end

        local taken, lost = stream:until_(delimiter, sink.write, 'часть оборвалась до границы')

        if not taken then
            sink.abort()

            return nil, lost
        end

        local closed, refusal = sink.close()

        if not closed then
            return nil, refusal
        end
    end
end

return Module

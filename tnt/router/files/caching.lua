--- Кэш раздачи: метка версии, время правки и ответ 304 без тела.
---
--- Браузер, получивший файл однажды, приходит за ним снова с меткой
--- (`If-None-Match`) или со временем (`If-Modified-Since`), и узел,
--- который на это не отвечает, шлёт всю панель заново на каждое
--- открытие страницы.
---
--- Метка сверяется по правилу RFC 9110 (13.1.2), а не строкой целиком:
--- клиент шлёт список меток, а посредник вправе пометить метку слабой
--- (`W/"…"`) — и равенство строк на таком заголовке даёт 200 с телом
--- там, где хватило бы 304 без него. Звёздочка значит «любая метка,
--- лишь бы файл был».
---
--- Время сверяется только тогда, когда метки нет вовсе: по RFC метка
--- главнее времени, потому что время в заголовке — целые секунды,
--- а метка меняется вместе с содержимым.
---
--- Срок жизни — настройкой, и по умолчанию короткий. `no-cache` — это
--- не «не кэшировать», а «спроси, не изменилось ли»: браузер держит
--- файл у себя и приходит с меткой. Вечный кэш выдаётся только тем
--- файлам, у которых отпечаток стоит в имени: такой файл не меняется
--- никогда — меняется его имя, — и год кэша ему ничем не грозит.
--- Ошибиться тут дорого: `max-age=31536000` у файла без отпечатка
--- оставляет половину браузеров на прошлой версии до конца года,
--- и починить это у клиента нечем.

local date = require('tnt.date')

local Module = {}

--- Кэширование по умолчанию: держи у себя, но спрашивай.
Module.DEFAULT = 'no-cache'

--- Кэширование файла с отпечатком в имени: год и «больше не спрашивай».
---
--- Год — предел `max-age`, записанный в RFC 9111 как разумный потолок;
--- `immutable` избавляет и от условного запроса при обновлении страницы.
Module.IMMUTABLE = 'public, max-age=31536000, immutable'

--- Чем отпечаток отделён от имени: чертой или точкой.
local SEPARATOR = '[%-%.]'

--- Знаки отпечатка: азбука base64url, которой его пишут сборщики.
local MARK = '[%w_%-]'

--- Расширение после отпечатка: без него это не имя файла.
local EXTENSION = '%.[%w]+$'

--- Как узнаётся отпечаток в имени: `app-BX7Yy2Qk.css`, `app.9f1c2ad3.js`.
---
--- Отпечаток — то, что стоит перед расширением, отделено чертой или
--- точкой и написано азбукой base64url. Скобка выделяет сам отпечаток:
--- по его длине правило и решает.
---
--- Образец собран из частей, а не написан одной строкой, чтобы каждая
--- часть проверялась сама по себе: повторитель в сборке мутанты `*`
--- и `-` делают неотличимым (пустой отпечаток всё равно короче восьми
--- знаков), и строка целиком ушла бы из-под мутационного гейта вместе
--- с разделителем, азбукой и расширением.
Module.FINGERPRINT = SEPARATOR .. '(' .. MARK .. '+)' .. EXTENSION

--- Сколько знаков делает хвост имени отпечатком.
---
--- Восемь — короче не бывает ни у одного сборщика, а слов такой длины
--- в именах частей сборки почти не встречается. Правило намеренно
--- строгое: лишний год кэша у файла без отпечатка чинится только
--- у каждого клиента по отдельности.
Module.FINGERPRINT_LENGTH = 8

--- Стоит ли в имени отпечаток содержимого.
---@param name string Имя файла
---@param pattern string Образец отпечатка
---@return boolean
function Module.fingerprinted(name, pattern)
    local mark = name:match(pattern)

    return mark ~= nil and #mark >= Module.FINGERPRINT_LENGTH
end

--- Значение `cache-control` для этого файла.
---@param settings table Настройки раздачи
---@param name string Имя файла
---@return string
function Module.control(settings, name)
    if settings.immutable and Module.fingerprinted(name, settings.fingerprint) then
        return Module.IMMUTABLE
    end

    return settings.cache
end

--- Есть ли метка файла среди присланных клиентом (RFC 9110, 13.1.2).
---
--- Список режется по запятой, а метка со слабой пометкой сравнивается
--- без неё. Запятая внутри самой метки разрезала бы её надвое — такая
--- метка просто не совпадёт, а своих меток с запятой раздача не
--- выдаёт: в них шестнадцатеричные знаки и дефис.
---@param header string Значение `if-none-match`
---@param tag string Метка файла
---@return boolean
function Module.matched(header, tag)
    for item in (header .. ','):gmatch('(.-),') do
        local given = item:match('^%s*(.-)%s*$') --[[@as string]]

        if given == '*' or (given:gsub('^W/', '')) == tag then
            return true
        end
    end

    return false
end

--- Не менялся ли файл с названного времени.
---
--- Мусор вместо даты — это 200 с телом, а не отказ: заголовок пишет
--- клиент, и неразобранная дата значит только то, что свежести
--- по ней не подтвердить.
---@param header any Значение `if-modified-since`
---@param modified integer|nil Время правки файла, секунды эпохи
---@return boolean
function Module.unchanged_since(header, modified)
    if type(header) ~= 'string' or modified == nil then
        return false
    end

    local moment = date.parse_http(header)

    if moment == nil then
        return false
    end

    return modified <= date.seconds(moment)
end

--- Есть ли у клиента свежая копия файла: тогда ответ — 304 без тела.
---
--- Метка главнее времени: когда клиент прислал `if-none-match`, время
--- не спрашивается вовсе — так велит RFC 9110 (13.1.3).
---@param request table Запрос
---@param file TntRouterFile
---@return boolean
function Module.fresh(request, file)
    local given = request.headers['if-none-match']

    if given ~= nil then
        return Module.matched(given, file.tag)
    end

    return Module.unchanged_since(request.headers['if-modified-since'], file.modified)
end

--- Заголовки кэширования ответа: метка, время правки, срок жизни.
---
--- Те же и у 200, и у 304: по RFC 9110 ответ 304 обязан нести всё, чем
--- клиент обновит свою запись в кэше, иначе срок жизни копии у него
--- не продлится и следующий запрос придёт снова.
---@param settings table Настройки раздачи
---@param file TntRouterFile
---@param name string Имя файла
---@return table<string, string>
function Module.headers(settings, file, name)
    local headers = { etag = file.tag, ['cache-control'] = Module.control(settings, name) }

    if file.modified ~= nil then
        headers['last-modified'] = date.http(file.modified)
    end

    return headers
end

return Module

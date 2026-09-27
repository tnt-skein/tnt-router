--- Раздача файлов: панель, собранные стили и всё, что лежит рядом.
---
--- Приложению нужен не только JSON: страница, сценарий, стили, шрифт,
--- картинка. Ставить ради них отдельный веб-сервер — это второе место,
--- где живёт версия приложения, и второй повод разойтись с версией
--- кластера.
---
--- Файлы берутся из каталога (`root`) или прямо из памяти процесса
--- (`bundle`): упакованная в модуль панель приезжает вместе с кодом,
--- и брать её с диска на боевом узле неоткуда, а собранные из SCSS
--- стили пересобираются на каждую правку, и паковать их в модуль
--- значило бы пересобирать вместе с ними узел.
---
--- Переход вверх по дереву отвергается по участкам, а не поиском «..»
--- в строке: имя `v1..2.js` — обычный файл, а `a/../../etc/passwd` —
--- попытка выйти наружу, и различать их надо до того, как путь дойдёт
--- до файловой системы. Скрытые файлы (`.env`, `.git/config`) наружу
--- не отдаются вовсе, ссылки не отдаются тоже (`files.store`).
---
--- У каждого файла есть метка версии, и браузер, получивший её однажды,
--- просит файл заново только после того, как тот изменился. Метка,
--- время правки и срок жизни копии — в `files.caching`, откуда берётся
--- и ответ 304 без тела.
---
--- «Файла нет» раздача говорит сама, а не пустотой роутеру: пустота —
--- поломка везде, и проход слоёв читает её как «слой потерял ответ».
--- Знает, что файла нет, только раздача: для роутера маршрут нашёлся.
--- Говорит она отказом парой `nil, отказ`, а не готовым ответом: отказ
--- рисует обработчик отказов приложения — тот же, что рисует промах
--- по адресу, — и он же пишет о нём в журнал. Готовый ответ миновал бы
--- его, и браузер на промах по файлу получил бы JSON роутера вместо
--- страницы 404 приложения. Свой ответ на промах задаётся настройкой
--- `missing`.
---
--- Способ не тот — 405 той же парой. Слово для человека лежит в обоих
--- отказах, а не только в ответе роутера: слой-страж приложения собирает
--- ответ из отказа раньше, чем роутер допишет своё, и отказ без слова
--- он назвал бы общими словами. Раздача отвечает на `GET` и `HEAD`,
--- а `HEAD` — это `GET` без тела: ни поток, ни файл на диске ради него
--- не читаются, а длину тела раздача называет сама — размер файла ей
--- известен и без чтения.
---
--- Сжатие приходит настройкой-слоем (`compress`), а не пакетом сжатия
--- внутри: роутеру незачем знать, чем сжимают, а раздача нужна и там,
--- где сжатия в системе нет вовсе. Слой сжатия уже знает, какие типы
--- сжимаются, что делать с `vary` и как сжимать поток кусками, — вторая
--- копия этих правил разошлась бы с первой молча.
---
--- Хвост `*path` у корня ловит и чужие адреса: `/api/v1/нет-такого`
--- доходит до раздачи, и запасная страница ответила бы на него первой
--- страницей с кодом 200 — то есть HTML тому, кто ждал JSON. Поэтому
--- есть `except`: начала путей, под которыми запасной страницы нет,
--- а есть честный отказ.

local fs = require('tnt.fs')

local caching = require('tnt.router.files.caching')
local errors = require('tnt.router.errors')
local options = require('tnt.router.options')
local response = require('tnt.router.response')
local store = require('tnt.router.files.store')

local Module = {}

--- Общая таблица типов по расширению: полтысячи записей из рока `http`.
---
--- Своя таблица знала одиннадцать расширений панели, и всё прочее —
--- `pdf`, `jpg`, `csv` — уходило потоком байтов: отчёт, открытый
--- ссылкой, браузер скачивал вместо того, чтобы показать. Таблица
--- берётся у сервера, на который роутер и так ставится, а не
--- переписывается: две копии одного списка однажды расходятся,
--- и расходятся молча.
local COMMON_TYPES = require('http.mime_types')

--- Наши поправки поверх общей таблицы; они важнее её.
---
--- Кодировка названа там, где она известна заранее: сценарии, стили
--- и JSON панели пишутся в UTF-8, а без `charset` браузер читает стили
--- в кодировке страницы и портит русские строки. Общей таблице её
--- взять неоткуда — про произвольный текстовый файл с диска кодировка
--- неизвестна, и там она не приписывается. Остальные строки — то, чего
--- в общей таблице нет (`map`, `webmanifest`, `woff2`) или что там
--- записано устаревшим видом (`ico` — `image/vnd.microsoft.icon`).
local OWN_TYPES = {
    css = 'text/css; charset=utf-8',
    html = 'text/html; charset=utf-8',
    ico = 'image/x-icon',
    js = 'application/javascript; charset=utf-8',
    json = 'application/json; charset=utf-8',
    map = 'application/json; charset=utf-8',
    txt = 'text/plain; charset=utf-8',
    webmanifest = 'application/manifest+json',
    woff2 = 'font/woff2',
}

--- Тип незнакомого файла: пусть браузер скачает, но не исполнит.
local DEFAULT_TYPE = 'application/octet-stream'

--- Что отдавать, когда путь не назван.
local DEFAULT_INDEX = 'index.html'

--- Имя хвоста в шаблоне маршрута: звёздочка с именем в конце пути,
--- например `*path` в шаблоне панели.
Module.PARAM = 'path'

--- Больше этого, байт, файл в память не читается, а уходит кусками.
---
--- Мегабайт: собранные стили и сценарии в него укладываются, а видео
--- и выгрузка — нет, и держать их строкой значит отдать память узла
--- тому, кто попросил файл.
local DEFAULT_IN_MEMORY = 1024 * 1024

--- Статусы двух отказов раздачи: «файла нет» и «способ не тот».
local NOT_FOUND = 404
local NOT_ALLOWED = 405

--- Способы, на которые раздача отвечает.
---
--- HEAD здесь же: сервер и роутер отдают его тем же обработчиком,
--- и отвечать на него 405 значило бы сломать проверку доступности.
local ALLOWED = 'GET, HEAD'

--- Тип содержимого по имени файла.
---@param name string
---@return string
function Module.content_type(name)
    local extension = name:match('%.([%w]+)$')

    if extension == nil then
        return DEFAULT_TYPE
    end

    extension = extension:lower()

    return OWN_TYPES[extension] or COMMON_TYPES[extension] or DEFAULT_TYPE
end

--- Приводит путь запроса к имени файла внутри раздачи.
---
--- Имя проверяется участками, а не строкой целиком: «..» участком —
--- это шаг вверх, а внутри имени (`v1..2.js`) — обычные знаки. Тем же
--- проходом отсеиваются пустые участки — ведущая косая черта (то есть
--- абсолютный путь), двойная черта и черта в конце — и участки, чьё имя
--- начинается с точки: `.env`, `.git/config`, `.ssh/id_rsa` лежат рядом
--- с отдаваемыми файлами чаще, чем хотелось бы.
---@param requested string|nil Что пришло хвостом маршрута
---@param index string Первая страница
---@return string|nil name Имя файла; nil — просьба выйти за пределы раздачи
function Module.resolve(requested, index)
    -- Ведущая косая черта снимается одна: хвост маршрута её не приносит
    -- вовсе, а рука человека приносит ровно одну.
    local name = tostring(requested or ''):gsub('^/', '')

    if name == '' then
        return index
    end

    -- Нулевой байт обрывает имя в системном вызове: `app.js%00.png`
    -- открыл бы `app.js`, а тип содержимого раздача взяла бы по `png`.
    if name:find('%z') ~= nil then
        return nil
    end

    for part in ('/' .. name):gmatch('/([^/]*)') do
        -- Ведущая точка ищется образцом, а не срезом: у среза `sub(1, 1)`
        -- мутант `sub(0, 1)` в Lua значит то же самое, и строка выглядела
        -- бы проверенной, не будучи ею.
        if part == '' or part:find('^%.') ~= nil then
            return nil
        end
    end

    return name
end

--- Файл раздачи: из набора в памяти либо с диска.
---@param settings table
---@param name string
---@return TntRouterFile|nil
local function file_of(settings, name)
    if settings.files ~= nil then
        return settings.files[name]
    end

    return store.from_disk(settings.root, name, settings.in_memory)
end

--- Отказ «такого файла нет» по умолчанию.
---
--- Тот же, которым роутер отказывает на несуществующий маршрут: клиенту
--- всё равно, чего именно нет по этому адресу — маршрута или файла, —
--- и два разных вида ответа на один и тот же промах ему только мешают.
---
--- Таблица новая на каждый промах: отказ уходит слоям маршрута, и слой,
--- дописавший в него своё — номер происшествия, заголовок, — в общей
--- на все запросы таблице дописал бы это и всем следующим промахам.
---@return nil
---@return TntRouterFailure failure
local function gone()
    return nil, { status = NOT_FOUND, message = errors.message_of(NOT_FOUND) }
end

--- Лежит ли путь под этим началом.
---
--- Черта дописывается обоим: без неё начало `/api` накрыло бы и `/apiary`,
--- то есть чужую раздачу, а с ней сравниваются только целые участки.
---
--- `startswith`, а не поиск с начала: «найти подстроку, начиная с первого
--- знака, и убедиться, что нашлась она на первом знаке» — это три шага
--- там, где смысл один, и ошибиться можно в каждом.
---@param request_path string
---@param prefix string
---@return boolean
local function under(request_path, prefix)
    return (request_path .. '/'):startswith(prefix .. '/')
end

--- Запасная страница для этого пути, если она есть.
---
--- Под началами из `except` её нет: туда ходят за данными, и первая
--- страница вместо отказа читается там как успех.
---
--- Отдаётся имя страницы, а не признак «есть ли»: `false` и `nil` в
--- условии неотличимы, и признак, подменённый пустотой, не заметила бы
--- ни одна проверка. Без настройки `fallback` имя и так пусто, отдельной
--- ветки для этого не нужно.
---
--- Путь берётся пустым, когда его не дали: запрос пакет обещает проверять
--- таблицей и без сервера, а требовать ради одной настройки поле, которое
--- всегда проставляет сам роутер, значит ломать это обещание. Ни под
--- какое начало пустой путь не попадает — и правильно: под `/api` он
--- не лежит.
---@param settings table
---@param request_path string|nil
---@return string|nil
local function spare(settings, request_path)
    request_path = request_path or ''

    for _, prefix in ipairs(settings.except) do
        if under(request_path, prefix) then
            return nil
        end
    end

    return settings.fallback
end

---@class TntRouterFilesOptions
---@field root string|nil Каталог на диске
---@field bundle table<string, string>|nil Файлы в памяти процесса
---@field param string|nil Имя хвоста маршрута; по умолчанию path
---@field index string|nil Первая страница; по умолчанию index.html
---@field fallback string|nil Что отдать вместо отказа: страница для панели
---@field except string[]|nil Начала путей, под которыми запасной страницы нет
---@field missing (fun(request: TntRouterRequest): table|nil, table|nil)|nil Ответ или отказ, когда файла нет
---@field cache string|nil Значение заголовка cache-control; по умолчанию no-cache
---@field immutable boolean|nil Вечный кэш файлам с отпечатком в имени; по умолчанию нет
---@field fingerprint string|nil Образец отпечатка в имени файла
---@field in_memory integer|nil Больше этого, байт, файл уходит кусками
---@field chunk integer|nil Размер куска, байт
---@field compress TntRouterLayerFn|nil Слой сжатия ответа: получает запрос и раздачу следующим шагом

--- Кусок ответа по кускам: число от одного байта до предела читателя.
---
--- Кусок читает читатель `tnt-fs`, и кусок вне его границ он встречает
--- броском — то есть на первом запросе большого файла, в бою. Поэтому
--- границы его сверяются здесь, при объявлении маршрута. По умолчанию —
--- кусок читателя по умолчанию, 64 КБ.
---@param value any
---@param level integer Уровень вины, как у `error`: 1 — эта функция
---@return integer
local function chunk_of(value, level)
    local chunk = options.expected(value, 'number', fs.CHUNK, 'chunk', level + 1)

    if chunk < 1 or chunk > fs.MAX_CHUNK then
        error(
            ('настройка «chunk» должна быть числом от 1 до %d, а не %s'):format(
                fs.MAX_CHUNK,
                chunk
            ),
            level
        )
    end

    return chunk
end

--- Проверенные настройки раздачи.
---
--- Вид настройки спрашивается при объявлении маршрута, как и у самого
--- роутера: `missing = 'строка'` дожил бы до первого промаха по файлу
--- и сорвался обращением к строке как к функции внутри боевого запроса —
--- то есть 500 вместо объявленного отказа, и ночью.
---
--- Отказ любой настройки винит одну строку — того, кто объявил раздачу:
--- `router.files` или `serve`. Кадров до него у них разное число, и уровень
--- приходит от входа.
---@param opts TntRouterFilesOptions|nil
---@param level integer Уровень вины, как у `error`: 1 — эта функция
---@return table
local function validated(opts, level)
    -- Уровень для проверок, которые зовутся отсюда: у них кадром больше.
    local nested = level + 1
    local given = options.expected(opts, 'table', {}, 'раздача', nested)

    -- Либо каталог, либо набор в памяти: заданные оба означают, что автор
    -- не решил, откуда берутся файлы, и однажды получит два разных ответа
    -- на один адрес.
    if (given.root == nil) == (given.bundle == nil) then
        error('раздаче нужен ровно один источник: root или bundle', level)
    end

    local root = options.expected(given.root, 'string', nil, 'root', nested)

    -- Пустой каталог не называет ничего, а склейка его с именем файла дала
    -- бы корень файловой системы: `'' .. '/' .. 'etc/passwd'`.
    if root == '' then
        error('настройка «root» должна быть непустой строкой', level)
    end

    local bundle = options.expected(given.bundle, 'table', nil, 'bundle', nested)
    local files = nil

    if bundle ~= nil then
        files = store.snapshot(bundle, nested)
    end

    return {
        root = root,
        files = files,
        param = options.expected(given.param, 'string', Module.PARAM, 'param', nested),
        index = options.expected(given.index, 'string', DEFAULT_INDEX, 'index', nested),
        fallback = options.expected(given.fallback, 'string', nil, 'fallback', nested),
        except = options.expected(given.except, 'table', {}, 'except', nested),
        missing = options.expected(given.missing, 'function', gone, 'missing', nested),
        cache = options.expected(given.cache, 'string', caching.DEFAULT, 'cache', nested),
        immutable = options.expected(given.immutable, 'boolean', false, 'immutable', nested),
        fingerprint = options.expected(given.fingerprint, 'string', caching.FINGERPRINT, 'fingerprint', nested),
        in_memory = options.positive(given.in_memory, DEFAULT_IN_MEMORY, 'in_memory', nested),
        chunk = chunk_of(given.chunk, nested),
        compress = options.expected(given.compress, 'function', nil, 'compress', nested),
    }
end

--- Ответ файлом: строкой либо кусками.
---
--- HEAD отвечает теми же заголовками и пустым телом: файл ради него
--- не читается вовсе — ни с диска, ни кусками. Длину при этом называет
--- раздача, а не сервер: по RFC 9110 (9.3.2) заголовки ответа на HEAD —
--- заголовки ответа на GET, а размер файла известен из снимка набора
--- или из `lstat`, и мерить для этого нечего. У ответа на GET длины
--- в заголовках нет: строку меряет сервер, а у ответа по кускам длины
--- не бывает вовсе.
---@param settings table
---@param request table
---@param file TntRouterFile
---@param headers table<string, string>
---@return table|nil
---@return table|nil failure Отказ `missing`, когда файл убрали до чтения
local function answered(settings, request, file, headers)
    if request.method == 'HEAD' then
        headers['content-length'] = tostring(file.size)

        return { status = 200, headers = headers, body = '' }
    end

    if file.body ~= nil then
        return { status = 200, headers = headers, body = file.body }
    end

    -- Пути нет только у файла, чьё тело уже в памяти: его отдали выше.
    local chunks = store.chunks(file.path --[[@as string]], settings.chunk)

    -- Файл убрали между опросом и открытием: это «файла нет», как и у
    -- файла, который не прочитался в память, а не 200 с пустым телом.
    if chunks == nil then
        return settings.missing(request)
    end

    return response.stream(chunks, 200, headers)
end

--- Отвечает на запрос файла: 200, 304, 404 или 405.
---@param settings table
---@param request table
---@return table|nil
---@return table|nil failure
local function served(settings, request)
    -- Способа нет вовсе у запроса, написанного таблицей: пакет обещает
    -- проверку без сервера, и такой запрос обслуживается как GET.
    if request.method ~= nil and request.method ~= 'GET' and request.method ~= 'HEAD' then
        -- Отказ парой: 405 рисует обработчик отказов приложения — тот же,
        -- что рисует 405 от дерева маршрутов, — и он же пишет о нём
        -- в журнал. Слово — по той же причине, что у «файла нет» (`gone`).
        local refusal = {
            status = NOT_ALLOWED,
            message = errors.message_of(NOT_ALLOWED),
            headers = { allow = ALLOWED },
        }

        return nil, refusal
    end

    local name = Module.resolve(request.params[settings.param], settings.index)
    local file = nil

    if name ~= nil then
        file = file_of(settings, name)
    end

    -- Панель — одна страница со своими адресами внутри: `/panel/nodes`
    -- открывают ссылкой, и файла с таким именем нет. Отдаётся сама
    -- страница, а разбирается адрес уже в браузере.
    if file == nil then
        name = spare(settings, request.path)

        if name ~= nil then
            file = file_of(settings, name)
        end
    end

    if file == nil then
        -- Отказ собирает раздача: только она знает, что файла нет.
        return settings.missing(request)
    end

    local headers = caching.headers(settings, file, name --[[@as string]])

    -- Тип — и у 304: без него `http.server` подставил бы `text/plain`,
    -- а кэш, обновляющий запись по 304 (RFC 9111, 3.2), стал бы отдавать
    -- стили текстом, и браузер их не применил бы.
    headers['content-type'] = Module.content_type(name --[[@as string]])

    if caching.fresh(request, file) then
        return { status = 304, headers = headers }
    end

    return answered(settings, request, file, headers)
end

--- Обработчик раздачи по настройкам.
---@param opts TntRouterFilesOptions|nil
---@param level integer Уровень вины, как у `error`: 1 — эта функция
---@return fun(request: TntRouterRequest): table|nil, table|nil
local function handler_of(opts, level)
    local settings = validated(opts, level + 1)

    local serve = function(request)
        return served(settings, request)
    end

    if settings.compress == nil then
        return serve
    end

    -- Слой получает раздачу как обычный следующий шаг: обрабатывается
    -- всё, чем она отвечает, включая ответ по кускам.
    return function(request)
        return settings.compress(request, serve)
    end
end

--- Объявление раздачи каталога: шаблон маршрута, обработчик и имя.
---
--- Собрано здесь, а не у роутера: про хвост и его имя знает раздача,
--- а роутеру остаётся объявить обычный маршрут на `GET` — `HEAD` он
--- обслуживает сам, а на прочие способы отвечает 405 с перечнем.
---@param prefix string Начало пути: `/build`; `/` — весь корень раздачи
---@param root string Каталог на диске
---@param opts TntRouterFilesOptions|nil Настройки раздачи; `name` — имя маршрута
---@param level integer Уровень вины, как у `error`: 1 — эта функция
---@return string pattern Шаблон маршрута с хвостом
---@return fun(request: TntRouterRequest): table|nil, table|nil handler
---@return table route Настройки маршрута
function Module.route(prefix, root, opts, level)
    ---@type table
    local given = {}

    for key, value in pairs(options.expected(opts, 'table', {}, 'раздача', level + 1)) do
        given[key] = value
    end

    given.root = root

    -- Обработчик собирается до шаблона: в шаблон уходит имя хвоста,
    -- и `param` таблицей сорвался бы склейкой здесь, а не отказом
    -- проверки настроек.
    local handler = handler_of(given, level + 1)

    -- Хвостовая черта снимается: `/build/` и `/build` — одно и то же
    -- начало, а склеенный шаблон дал бы участок из одной черты. Ровно
    -- одна, без повторителя: у образца с повторителем мутанты «ноль или
    -- больше» и «лениво» дают на любом начале тот же ответ. Лишние черты
    -- дерево и так пропускает — участков из пустоты в пути не бывает.
    ---@type string
    local start = options.expected(prefix, 'string', '', 'prefix', level + 1)

    -- Хвост склеен из кусков не для красоты: пара «косая черта
    -- со звёздочкой» в исходнике — это начало блочного комментария для
    -- языконезависимого мутационного прогона, и всё, что стоит за ней,
    -- он перестаёт видеть (см. шапку `tnt.router`).
    local pattern = start:gsub('/$', '') .. '/' .. '*' .. (given.param or Module.PARAM)

    return pattern, handler, { name = given.name }
end

--- Собирает обработчик раздачи для маршрута с хвостом.
---
--- Негодная настройка винит строку, которая позвала раздачу.
---@param opts TntRouterFilesOptions|nil
---@return fun(request: TntRouterRequest): table|nil, table|nil
function Module.handler(opts)
    -- Первый уровень — сборка, второй — эта функция, третий — её вызывающий.
    local handler = handler_of(opts, 3)

    return handler
end

return Module

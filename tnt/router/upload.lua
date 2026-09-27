--- Присланный файл: предмет с договором, а не строка в таблице.
---
--- Обработчику нужны о файле пять вещей, и все пять — разные: имя, каким
--- его назвал клиент; имя, которое не страшно положить на диск; размер;
--- тип содержимого; и сам файл — прочитать или перенести на место.
--- Строка в таблице полей даёт из этого одно — байты, — и каждое
--- приложение дописывает к ней остальное по-своему.
---
--- Решения, о которых стоит знать.
---
--- **Имя клиента и безопасное имя — разные поля.** `client_name` — байты,
--- как их прислали: там бывает и `../../etc/passwd`, и `C:\Users\...`,
--- и нулевой байт, и не UTF-8. Класть их на диск нельзя, а показать
--- человеку иногда нужно, поэтому они остаются — отдельно и с именем,
--- которое само говорит, что им верить нельзя. На диск кладут `name`:
--- в нём нет ни черты, ни управляющих байтов, ни ведущей точки.
---
--- **Большая часть живёт во временном файле, а не в памяти.** Пока часть
--- меньше `in_memory`, она копится строкой: файл под аватар в сорок
--- килобайт не стоит ни системного вызова, ни уборки. Как только она
--- перерастает предел, накопленное уходит во временный файл, и дальше
--- байты идут прямо туда.
---
--- **Временный файл убирается после ответа.** Уборку делает роутер
--- (`tnt.router.form`), и делает при всяком исходе — в том числе при
--- отказе. Обработчику, которому файл нужен дольше одного запроса, нужен
--- `move`: он переносит файл на место, и уборка его уже не трогает.
---
--- **Файл пишется писателем `tnt-fs` кусками.** В памяти лежит один
--- кусок, а отказ — пара с родом, как у всякого действия с файлом:
--- кончившееся место отличается от негодного каталога словом `full`,
--- а не разбором текста. Писатель заодно даёт уборку недописанного:
--- его `abort` убирает временный файл при всяком исходе.

local digest = require('digest')
local fs = require('tnt.fs')

local external = require('tnt.external')

local Module = {}

--- Средства снаружи: случайность для имени.
local DEFAULTS = {
    random = digest.urandom,
}

local source = external.install(Module, DEFAULTS)

--- Длина знаков в безопасном имени: средство то же, что в отказах.
---@type any
local letters = rawget(_G, 'utf8')

--- Права временного файла: читает и пишет только владелец.
---
--- Во временном файле лежит то, что прислал посетитель: паспорт, договор,
--- выписка. Каталог для них общий на машину, и `0600` — единственное, что
--- отделяет их от всякого, у кого есть на ней учётная запись.
local TEMP_MODE = tonumber('600', 8)

--- Сколько случайных байт в имени временного файла.
---
--- Двенадцать байт — это 2^96 имён: угадать имя заранее и подложить
--- на его место свой файл нельзя. Угаданное не поможет тоже: писатель
--- пишет в свой файл рядом, открытый с `O_EXCL`, и переименование
--- в конце кладёт его поверх подложенного, а не пишет сквозь ссылку.
local TEMP_RANDOM = 12

--- Начало и конец имени временного файла.
---
--- Имя скрытое: уборщик, чистящий общий каталог по образцу `*`, не унесёт
--- файл, который прямо сейчас принимается.
local TEMP_PREFIX = '.tnt-upload-'
local TEMP_SUFFIX = '.tmp'

--- Куда класть временные файлы, когда каталог не назван.
---
--- Окружение пакет не читает: переменные — дело приложения, оно берёт их
--- через `tnt-env` при сборке настроек и передаёт сюда настройкой
--- `temp_dir`. Узлу, у которого `/tmp` мал или только для чтения, каталог
--- называют явно.
local SYSTEM_TEMP = '/tmp'

--- Сколько знаков оставлять в безопасном имени.
---
--- Предел файловой системы — 255 байт на имя, и в него должно влезть ещё
--- и то, что допишет приложение: номер записи, отпечаток, расширение.
local NAME_LIMIT = 100

--- Чем зовётся файл, от имени которого ничего не осталось.
local NAMELESS = 'file'

--- Знаки, которые остаются в безопасном имени как есть.
---
--- Буквы, цифры, точка, дефис и подчёркивание — и байты со старшим битом,
--- то есть кириллица и всё прочее не из латиницы. Косая черта, обратная
--- косая, управляющие байты, пробелы и кавычки становятся подчёркиванием:
--- имя уходит и в путь на диске, и в заголовок ответа, и в страницу.
local KEPT = '[^%w%.%-_\128-\255]'

--- Безопасное имя файла: то, что не страшно положить на диск.
---
--- Путь отрезается по последней черте — и прямой, и обратной: браузеры
--- старых версий слали имя вместе с путём windows целиком, и `..\..\`
--- в нём — не редкость, а обычный вид такого имени.
---
--- Ведущие точки снимаются: файл с точки — скрытый, и загрузка, которая
--- умеет положить в каталог `.htaccess` или `.env`, — это не загрузка
--- файла, а подмена настроек.
---@param filename any Имя, как прислал клиент
---@return string
function Module.safe_name(filename)
    -- Хвост после последней черты: образец без якоря берёт самое правое
    -- совпадение, потому что пустое совпадение в конце тоже годится.
    local base = tostring(filename or ''):match('[^/\\]*$') --[[@as string]]
    -- Ведущие точки снимаются образцом, а не заменой: у `gsub('^[%._]+')`
    -- подмена повтора на «ноль и больше» даёт ту же строку на любом
    -- входе, и убить такого мутанта нечем.
    local cleaned = base:gsub(KEPT, '_'):gsub('_+', '_'):match('^[%._]*(.*)$') --[[@as string]]

    if cleaned == '' then
        return NAMELESS
    end

    -- Резать приходится по знакам: срез по байтам разрубил бы
    -- кириллическую букву пополам, и обрывок сорвал бы сборку JSON
    -- в ответе. Начало среза — отрицательным отсчётом: у единицы
    -- мутанты `0` и `1-1` дают тот же срез.
    local length = letters.len(cleaned)
    local cut = length and letters.sub(cleaned, -length, NAME_LIMIT) or cleaned:sub(-#cleaned, NAME_LIMIT)

    return cut
end

---@class TntRouterUpload
---@field field string Имя поля формы, в котором пришёл файл
---@field client_name string Имя, как прислал клиент; ему не верят
---@field name string Безопасное имя: без пути, без управляющих байтов
---@field size integer Размер, байт
---@field type string Тип содержимого, названный клиентом
---@field charset string|nil Кодировка, названная клиентом
---@field path string|nil Где файл лежит; `nil` — файл в памяти
---@field temporary boolean Убирать ли файл после ответа
---@field body string|nil Содержимое, пока файл не вырос до временного
local Upload = {}
Upload.__index = Upload

--- Содержимое файла целиком.
---
--- Память здесь уже не бережётся: тот, кто зовёт `read`, просит именно
--- содержимое. Размер его ограничен пределом части, и предел этот выбрал
--- владелец узла.
---@return string|nil body
---@return TntFsFailure|nil err
function Upload:read()
    if self.body ~= nil then
        return self.body
    end

    return fs.read(self.path --[[@as string]])
end

--- Копирует файл на место кусками и убирает исходник.
---
--- Копия ложится подменой: читающий место видит либо прежний файл, либо
--- новый целиком, — как и после переименования. Исходник убирается,
--- только когда копия на месте: иначе отказ переноса терял бы файл.
--- Не убрался исходник — перенос всё равно состоялся, а остаток лежит
--- в каталоге временных файлов со скрытым именем.
---@param from string
---@param to string
---@return true|nil
---@return TntFsFailure|nil err
local function copied(from, to)
    local reader, err = fs.reader(from)

    if reader == nil then
        return nil, err
    end

    local writer, write_err = fs.writer(to, { mode = TEMP_MODE })

    if writer == nil then
        reader:close()

        return nil, write_err
    end

    local piped, pipe_err = fs.pipe(reader, writer)

    if not piped then
        return nil, pipe_err
    end

    fs.remove(from)

    return true
end

--- Переносит файл на место.
---
--- Переименование работает только в пределах одной файловой системы:
--- временные файлы лежат в системном каталоге, а он на боевой машине
--- обычно отдельный том. Поэтому отказ переименования — не отказ
--- переноса: дальше идёт копия кусками с удалением исходника. Файл
--- из памяти ложится подменой сразу. Права у места — `0600` всяким путём:
--- переименование несёт права временного файла, и копия с записью
--- из памяти обязаны сказать то же.
---
--- После переноса предмет остаётся годным: `read` читает файл с нового
--- места, а уборка его уже не трогает — файл теперь принадлежит тому,
--- кто его перенёс.
---@param destination string Куда положить
---@return true|nil
---@return TntFsFailure|nil err
function Upload:move(destination)
    if type(destination) ~= 'string' or destination == '' then
        error('переносить присланный файл надо в названный путь', 2)
    end

    local moved, err

    if self.path == nil then
        moved, err = fs.replace(destination, self.body --[[@as string]], { mode = TEMP_MODE })
    else
        moved = fs.rename(self.path, destination)

        if not moved then
            moved, err = copied(self.path, destination)
        end
    end

    if not moved then
        return nil, err
    end

    self.path = destination
    self.temporary = false

    return true
end

--- Убирает временный файл.
---
--- Убирать нечего дважды: уборка идёт после ответа и по всем файлам
--- запроса разом, а обработчик мог перенести файл сам.
---@return true|nil
---@return TntFsFailure|nil err
function Upload:remove()
    if not self.temporary then
        return true
    end

    self.temporary = false

    return fs.remove(self.path --[[@as string]])
end

--- Путь нового временного файла.
---
--- Каталог и имя склеены чертой как есть: имя своё и без черты, а каталог
--- назвал владелец узла, и черта на его конце даёт `//`, которое система
--- читает как одну.
---@param root string
---@return string
local function temp_path(root)
    return root .. '/' .. TEMP_PREFIX .. string.hex(source().random(TEMP_RANDOM)) .. TEMP_SUFFIX
end

--- Каталог для временных файлов.
---
--- Пустая строка — тоже «не назван»: так приезжает переменная окружения,
--- заданная пустой, а склейка пустоты с именем положила бы временный
--- файл в корень файловой системы.
---@param given string|nil Каталог из настроек
---@return string
function Module.root_of(given)
    return given ~= '' and given or SYSTEM_TEMP
end

---@class TntRouterPartSink
---@field write fun(chunk: string): boolean, TntRouterFailure|nil
---@field close fun(): TntRouterUpload|nil, TntRouterFailure|nil
---@field abort fun() Бросить часть: тело оборвалось до её конца

---@class TntRouterUploadOptions
---@field field string Имя поля формы
---@field filename string Имя файла, как прислал клиент
---@field type string Тип содержимого части
---@field charset string|nil Кодировка части
---@field in_memory integer С какого размера часть уходит во временный файл
---@field max_size integer Сколько байт принять
---@field temp_dir string|nil Куда класть временный файл

--- Приёмник части: память, пока она помещается, дальше — временный файл.
---
--- Временный файл пишет писатель `tnt-fs`: куски идут в его собственный
--- файл рядом, и на место временного он встаёт только в `close`. Отказ
--- записи писатель убирает сам, а брошенную часть убирает `abort`.
--- Причина отказа — словами системы — уходит в журнал, наружу — код.
---@param opts TntRouterUploadOptions
---@return TntRouterPartSink
function Module.sink(opts)
    local chunks = {}
    local size = 0

    ---@type TntFsWriter|nil
    local writer = nil
    ---@type string|nil
    local path = nil

    --- Бросает часть: недописанный временный файл убирается.
    ---
    --- Убирается здесь же, а не общей уборкой запроса: брошенная
    --- и отказавшая часть до неё не доходят — их предмета нет в форме,
    --- и убрать файл потом будет некому. Звать можно сколько угодно раз:
    --- писатель после конца и отказа уже ничего не убирает.
    local function abort()
        if writer ~= nil then
            writer:abort()
        end
    end

    --- Отказ приёмника: часть брошена, подробность уходит в журнал.
    ---@param status integer
    ---@param reason string
    ---@return boolean
    ---@return TntRouterFailure
    local function refuse(status, reason)
        abort()

        return false, { status = status, reason = reason }
    end

    --- Пишет кусок во временный файл.
    ---@param chunk string
    ---@return boolean
    ---@return TntRouterFailure|nil
    local function put(chunk)
        local written, err = (writer --[[@as TntFsWriter]]):write(chunk)

        if not written then
            ---@cast err TntFsFailure
            return refuse(500, ('временный файл %s не записан: %s'):format(path, err.reason))
        end

        return true
    end

    --- Заводит временный файл и сбрасывает в него накопленное.
    ---@return boolean
    ---@return TntRouterFailure|nil
    local function spill()
        path = temp_path(Module.root_of(opts.temp_dir))

        local opened, err = fs.writer(path, { mode = TEMP_MODE })

        if opened == nil then
            ---@cast err TntFsFailure
            return refuse(
                500,
                ('временный файл %s для части не заведён: %s'):format(path, err.reason)
            )
        end

        writer = opened

        local kept = table.concat(chunks)

        chunks = {}

        return put(kept)
    end

    --- Принимает очередной кусок части.
    ---@param chunk string
    ---@return boolean
    ---@return TntRouterFailure|nil
    local function write(chunk)
        size = size + #chunk

        if size > opts.max_size then
            return refuse(
                413,
                ('файл в поле «%s» больше предела в %d байт'):format(
                    opts.field,
                    opts.max_size
                )
            )
        end

        if writer ~= nil then
            return put(chunk)
        end

        table.insert(chunks, chunk)

        if size <= opts.in_memory then
            return true
        end

        return spill()
    end

    --- Закрывает часть и отдаёт готовый предмет.
    ---@return TntRouterUpload|nil
    ---@return TntRouterFailure|nil
    local function close()
        local body = nil

        if writer == nil then
            body = table.concat(chunks)
        else
            local finished, err = writer:finish()

            if not finished then
                ---@cast err TntFsFailure
                -- Файл не закрылся — значит, записан он не весь: сетевая
                -- файловая система сообщает об отказе записи именно здесь.
                -- Отказать может и сброс каталога, когда файл уже на месте;
                -- отдавать его обработчику нельзя ни целым, ни обрывком,
                -- а убрать его больше некому. Убирать нечего — тоже исход.
                fs.remove(path --[[@as string]])

                return nil,
                    {
                        status = 500,
                        reason = ('временный файл %s не закрыт: %s'):format(path, err.reason),
                    }
            end
        end

        return setmetatable({
            field = opts.field,
            client_name = opts.filename,
            name = Module.safe_name(opts.filename),
            size = size,
            type = opts.type,
            charset = opts.charset,
            path = path,
            temporary = path ~= nil,
            body = body,
        }, Upload)
    end

    return { write = write, close = close, abort = abort }
end

return Module

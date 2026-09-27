--- Тесты раздачи файлов: имена, типы, метки версии и выход за пределы.

local t = require('luatest')

local fio = require('fio')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.files')

--- Раздача файлов.
---@return any
local function files()
    return helper.part('tnt.router.files')
end

--- Источник файлов: у него живут внешняя зависимость чтения с диска и подсчёт метки.
---@return any
local function store()
    return helper.part('tnt.router.files.store')
end

--- Запрос к раздаче: хвост маршрута и заголовки.
---
--- Путь собирается из хвоста: по нему раздача решает, есть ли под этим
--- адресом запасная страница, и запрос без пути был бы не тем запросом,
--- который приносит роутер.
---@param tail string|nil
---@param headers table<string, string>|nil
---@param method string|nil Способ; без него запрос обслуживается как GET
---@return table
local function asked(tail, headers, method)
    return {
        method = method,
        params = { path = tail },
        path = '/' .. tostring(tail or ''):gsub('^/', ''),
        headers = headers or {},
    }
end

--- Отказ «такого файла нет», как его отдаёт сама раздача: парой и со словом.
---
--- Сверяется весь отказ, а не статус: лишнее поле уехало бы в обработчик
--- отказов приложения, а без слова страж приложения назвал бы промах
--- общими словами.
---@param sent table|nil
---@param failure table|nil
local function assert_gone(sent, failure)
    t.assert_equals(sent, nil)
    t.assert_equals(failure, { status = 404, message = 'нет такого адреса' })
end

--- Отказ «способ не тот»: парой, со словом и перечнем способов.
local NOT_ALLOWED = {
    status = 405,
    message = 'этот способ здесь не поддерживается',
    headers = { allow = 'GET, HEAD' },
}

--- Панель из двух файлов: этого хватает всем проверкам здесь.
local PANEL = {
    ['index.html'] = '<h1>панель</h1>',
    ['app.js'] = 'const a = 1;',
}

g.test_file_goes_out_with_its_type_and_version_mark = function()
    local sent = files().handler({ bundle = PANEL })(asked('app.js'))

    t.assert_equals(sent.status, 200)
    t.assert_equals(sent.body, 'const a = 1;')
    t.assert_equals(sent.headers['content-type'], 'application/javascript; charset=utf-8')
    t.assert_equals(sent.headers['cache-control'], 'no-cache')
    -- Метка — crc32 содержимого восемью шестнадцатеричными знаками
    -- в кавычках: без кавычек по RFC 9110 это не метка.
    t.assert_equals(sent.headers.etag, ('"%08x"'):format(require('digest').crc32('const a = 1;')))
end

g.test_unnamed_path_opens_the_first_page = function()
    t.assert_equals(files().handler({ bundle = PANEL })(asked('')).body, '<h1>панель</h1>')
    t.assert_equals(files().handler({ bundle = PANEL })(asked(nil)).body, '<h1>панель</h1>')
    t.assert_equals(files().handler({ bundle = PANEL })(asked('/')).body, '<h1>панель</h1>')
end

g.test_first_page_can_be_named_otherwise = function()
    local sent = files().handler({ bundle = { ['start.html'] = 'начало' }, index = 'start.html' })(asked(''))

    t.assert_equals(sent.body, 'начало')
end

g.test_missing_file_is_refused_by_the_delivery_itself = function()
    -- Пустотой отказать нельзя: проход слоёв читает её как «слой потерял
    -- ответ» и отвечает 500. А знает, что файла нет, только раздача:
    -- для роутера маршрут нашёлся. Отказ парой: его рисует обработчик
    -- отказов приложения, как и промах по адресу.
    local handler = files().handler({ bundle = PANEL })

    assert_gone(handler(asked('нет.js')))
end

g.test_each_miss_gets_a_refusal_of_its_own = function()
    -- Слой маршрута вправе дописать в отказ своё — номер происшествия,
    -- заголовок: в отказе, общем на все промахи, это досталось бы
    -- и ответу на следующий запрос.
    local handler = files().handler({ bundle = PANEL })
    local _, first = handler(asked('нет.js'))

    first.incident = '4KJ7-QW9M'

    assert_gone(handler(asked('нет.js')))
end

g.test_own_answer_can_be_put_in_place_of_the_refusal = function()
    -- Вид отказа один на приложение: панель со своим каталогом отказов
    -- отвечает на «файла нет» тем же телом, что и на всё остальное.
    local seen = {}

    local handler = files().handler({
        bundle = PANEL,
        missing = function(request)
            seen.path = request.path

            return { status = 404, headers = {}, body = 'своё' }
        end,
    })

    t.assert_equals(handler(asked('нет.js')).body, 'своё')
    t.assert_equals(seen.path, '/нет.js')
end

g.test_own_refusal_goes_out_as_a_pair_whole = function()
    -- Свой отказ парой раздача отдаёт как есть: обе половины доходят
    -- до обработчика отказов, и код каталога приложения не теряется.
    local handler = files().handler({
        bundle = PANEL,
        missing = function()
            return nil, { status = 404, code = 'file.gone' }
        end,
    })
    local sent, failure = handler(asked('нет.js'))

    t.assert_equals(sent, nil)
    t.assert_equals(failure, { status = 404, code = 'file.gone' })
end

g.test_step_out_of_the_directory_is_refused_before_the_disk = function()
    -- Шаг вверх отвергается, где бы он ни стоял: в начале имени,
    -- в середине, в конце и вместо всего имени. Пропустить любой из них
    -- значит отдать наружу файл, которого в раздаче нет.
    for _, requested in ipairs({
        '..',
        '../etc/passwd',
        '../../etc/passwd',
        'assets/../../etc/passwd',
        'assets/..',
    }) do
        t.assert_equals(files().resolve(requested, 'index.html'), nil, requested)
    end

    assert_gone(files().handler({ bundle = PANEL })(asked('../etc/passwd')))
end

g.test_two_dots_inside_a_name_are_not_a_step_out = function()
    -- `v1..2.js` — обычное имя, и отвергать его значит не отдать файл,
    -- который лежит на месте.
    t.assert_equals(files().resolve('v1..2.js', 'index.html'), 'v1..2.js')
end

g.test_unchanged_file_is_not_sent_twice = function()
    local handler = files().handler({ bundle = PANEL })
    local first = handler(asked('app.js'))
    local again = handler(asked('app.js', { ['if-none-match'] = first.headers.etag }))

    -- В 304 уходит и срок жизни копии: по RFC 9110 ответ без тела обязан
    -- нести всё, чем клиент обновит свою запись в кэше. И тип: без него
    -- сервер подставил бы `text/plain`, и кэш, обновивший запись по 304,
    -- отдавал бы сценарий текстом.
    t.assert_equals(again, {
        status = 304,
        headers = {
            etag = first.headers.etag,
            ['cache-control'] = 'no-cache',
            ['content-type'] = 'application/javascript; charset=utf-8',
        },
    })
end

g.test_changed_file_gets_a_new_mark = function()
    local first = files().handler({ bundle = PANEL })(asked('app.js'))
    local other = files().handler({ bundle = { ['app.js'] = 'const a = 2;' } })(asked('app.js'))

    t.assert_not_equals(first.headers.etag, other.headers.etag)
end

g.test_marks_of_the_bundle_are_counted_once_when_the_delivery_is_built = function()
    -- Метка на каждый запрос — это crc32 по всей панели для каждого, кто
    -- пришёл, в том числе для того, кто получит 304 без тела.
    local real = require('digest')
    local counted = 0

    store()._set_source({
        digest = function()
            return {
                crc32 = function(body)
                    counted = counted + 1

                    return real.crc32(body)
                end,
            }
        end,
    })

    local handler = files().handler({ bundle = PANEL })

    t.assert_equals(counted, 2)

    local first = handler(asked('app.js'))

    handler(asked('app.js', { ['if-none-match'] = first.headers.etag }))
    handler(asked(''))

    t.assert_equals(first.headers.etag, ('"%08x"'):format(real.crc32('const a = 1;')))
    t.assert_equals(counted, 2)
end

g.test_bundle_changed_after_the_build_does_not_leak_into_the_delivery = function()
    -- Раздача держит снимок: подменённый в таблице файл отдавался бы
    -- со старой меткой, и браузер с прошлой копией получал бы 304
    -- на новое содержимое.
    local bundle = { ['app.js'] = 'const a = 1;' }
    local handler = files().handler({ bundle = bundle })
    local first = handler(asked('app.js'))

    bundle['app.js'] = 'const a = 2;'
    bundle['new.js'] = 'const b = 1;'

    local again = handler(asked('app.js'))

    t.assert_equals(again.body, 'const a = 1;')
    t.assert_equals(again.headers.etag, first.headers.etag)
    assert_gone(handler(asked('new.js')))
end

g.test_a_page_of_its_own_is_given_out_instead_of_a_refusal = function()
    -- Панель — одна страница со своими адресами внутри: `/panel/nodes`
    -- открывают ссылкой, и файла с таким именем нет.
    local handler = files().handler({ bundle = PANEL, fallback = 'index.html' })
    local sent = handler(asked('nodes'))

    t.assert_equals(sent.status, 200)
    t.assert_equals(sent.body, '<h1>панель</h1>')
    t.assert_equals(sent.headers['content-type'], 'text/html; charset=utf-8')
end

g.test_missing_page_of_its_own_is_still_a_refusal = function()
    local handler = files().handler({ bundle = PANEL, fallback = 'нет.html' })

    assert_gone(handler(asked('nodes')))
end

g.test_named_beginnings_get_a_refusal_instead_of_the_page = function()
    -- Хвост у корня ловит и адреса API: без этого клиент, ошибшийся
    -- в адресе, получал бы первую страницу с кодом 200 — то есть HTML
    -- вместо JSON, и разбирал бы его как отказ.
    local handler = files().handler({
        bundle = PANEL,
        fallback = 'index.html',
        except = { '/api', '/metrics' },
    })

    assert_gone(handler(asked('api/v1/нет-такого')))
    assert_gone(handler(asked('metrics')))
    t.assert_equals(handler(asked('nodes')).body, '<h1>панель</h1>')
end

g.test_named_beginning_is_matched_by_whole_segments = function()
    -- Иначе начало `/api` накрыло бы и `/apiary` — чужую раздачу,
    -- у которой первая страница как раз на месте.
    local handler = files().handler({
        bundle = PANEL,
        fallback = 'index.html',
        except = { '/api' },
    })

    t.assert_equals(handler(asked('apiary/мёд')).body, '<h1>панель</h1>')
    assert_gone(handler(asked('api')))
end

g.test_named_beginning_is_read_letter_by_letter = function()
    -- Начало сравнивается как строка, а не как образец: точка в нём —
    -- это точка, и раздача, объявившая `/a.b`, не должна отказывать
    -- по адресу `/axb`.
    local handler = files().handler({
        bundle = PANEL,
        fallback = 'index.html',
        except = { '/a.b' },
    })

    t.assert_equals(handler(asked('axb/что-то')).body, '<h1>панель</h1>')
    assert_gone(handler(asked('a.b/что-то')))
end

g.test_named_beginnings_mean_nothing_without_a_spare_page = function()
    -- Без запасной страницы отказ и так отказ: отдельного разбора
    -- начал пути для этого не нужно.
    local handler = files().handler({ bundle = PANEL, except = { '/api' } })

    assert_gone(handler(asked('api/v1/нет-такого')))
    t.assert_equals(handler(asked('app.js')).status, 200)
end

g.test_tail_can_be_named_otherwise = function()
    local handler = files().handler({ bundle = PANEL, param = 'rest' })

    t.assert_equals(handler({ params = { rest = 'app.js' }, headers = {} }).status, 200)
end

g.test_caching_can_be_asked_for_out_loud = function()
    local handler = files().handler({ bundle = PANEL, cache = 'max-age=3600' })

    t.assert_equals(handler(asked('app.js')).headers['cache-control'], 'max-age=3600')
end

--- Тип содержимого каждого расширения, какое раздача знает.
---
--- Проверяется каждый по отдельности и целиком: браузер не исполнит
--- сценарий, отданный как обычный текст, не применит таблицу стилей
--- и не покажет шрифт — а опечатка в одной букве типа выглядит
--- в исходнике ровно как правильная запись.
local CONTENT_TYPES = {
    { name = 'style.css', kind = 'text/css; charset=utf-8' },
    { name = 'index.html', kind = 'text/html; charset=utf-8' },
    { name = 'favicon.ico', kind = 'image/x-icon' },
    { name = 'app.js', kind = 'application/javascript; charset=utf-8' },
    { name = 'data.json', kind = 'application/json; charset=utf-8' },
    { name = 'app.js.map', kind = 'application/json; charset=utf-8' },
    { name = 'logo.png', kind = 'image/png' },
    { name = 'logo.svg', kind = 'image/svg+xml' },
    { name = 'readme.txt', kind = 'text/plain; charset=utf-8' },
    { name = 'panel.webmanifest', kind = 'application/manifest+json' },
    { name = 'шрифт.woff2', kind = 'font/woff2' },
    -- Дальше — из общей таблицы: своих строк у раздачи для них нет.
    { name = 'report.pdf', kind = 'application/pdf' },
    { name = 'photo.jpg', kind = 'image/jpeg' },
    { name = 'nodes.csv', kind = 'text/csv' },
}

g.test_type_is_told_by_the_extension_and_nothing_else = function()
    for _, case in ipairs(CONTENT_TYPES) do
        t.assert_equals(files().content_type(case.name), case.kind, case.name)
    end
end

g.test_extension_is_read_regardless_of_its_case = function()
    t.assert_equals(files().content_type('style.CSS'), 'text/css; charset=utf-8')
    t.assert_equals(files().content_type('PHOTO.JPG'), 'image/jpeg')
end

g.test_own_line_wins_over_the_common_table = function()
    -- В общей таблице значок записан устаревшим видом, а сценарий —
    -- без кодировки; отданы должны быть наши строки.
    local common = require('http.mime_types')

    t.assert_equals(common.ico, 'image/vnd.microsoft.icon')
    t.assert_equals(common.js, 'application/javascript')
    t.assert_equals(files().content_type('favicon.ico'), 'image/x-icon')
    t.assert_equals(files().content_type('app.js'), 'application/javascript; charset=utf-8')
end

g.test_unknown_and_nameless_things_are_bytes_and_not_a_script = function()
    -- Браузер не исполнит то, чего не понял, — и это ровно то, что нужно.
    t.assert_equals(files().content_type('dump.bin'), 'application/octet-stream')
    t.assert_equals(files().content_type('LICENSE'), 'application/octet-stream')
end

g.test_empty_extension_is_no_extension = function()
    -- Точка в конце имени не называет расширения. На этом держится
    -- исключение мутантов повтора в tools/mutate.ignore: пустое расширение
    -- ищется в таблицах и не находится, поэтому пустого ключа в общей
    -- таблице быть не должно.
    local common = require('http.mime_types') --[[@as table<string, string>]]

    t.assert_equals(common[''], nil)
    t.assert_equals(files().content_type('archive.'), 'application/octet-stream')
    t.assert_equals(files().content_type('a.b.'), 'application/octet-stream')
end

g.test_source_of_files_is_named_exactly_once = function()
    helper.assert_blamed({
        {
            function()
                files().handler({})
            end,
            'раздаче нужен ровно один источник: root или bundle',
        },
        {
            function()
                files().handler({ root = '/tmp', bundle = PANEL })
            end,
            'раздаче нужен ровно один источник: root или bundle',
        },
    })
end

g.test_a_setting_of_the_wrong_kind_is_refused_where_it_is_written = function()
    -- `missing = 'строка'` дожил бы до первого промаха по файлу и сорвался
    -- обращением к строке как к функции внутри боевого запроса — то есть
    -- 500 вместо объявленного отказа, и ночью. Отказ любой настройки
    -- винит строку, где раздачу объявили, а не строку пакета.
    local wrong = {
        {
            { bundle = PANEL, missing = 'потом' },
            'настройка «missing» должна быть функцией, а не string',
        },
        {
            { bundle = PANEL, except = '/api' },
            'настройка «except» должна быть таблицей, а не string',
        },
        {
            { bundle = PANEL, fallback = true },
            'настройка «fallback» должна быть строкой, а не boolean',
        },
        {
            { bundle = PANEL, param = 7 },
            'настройка «param» должна быть строкой, а не number',
        },
        {
            { bundle = PANEL, index = {} },
            'настройка «index» должна быть строкой, а не table',
        },
        {
            { bundle = PANEL, cache = 60 },
            'настройка «cache» должна быть строкой, а не number',
        },
        {
            { bundle = PANEL, immutable = 'да' },
            'настройка «immutable» должна быть true или false, а не string',
        },
        {
            { bundle = PANEL, fingerprint = 8 },
            'настройка «fingerprint» должна быть строкой, а не number',
        },
        {
            { bundle = PANEL, compress = 'gzip' },
            'настройка «compress» должна быть функцией, а не string',
        },
        {
            { bundle = PANEL, in_memory = '1M' },
            'настройка «in_memory» должна быть числом, а не string',
        },
        -- Ноль и отрицательное проходят проверку вида и срываются уже
        -- в ответе: кусок в ноль байт кончает чтение на первом же шаге,
        -- и клиент получает пустое тело вместо файла.
        {
            { bundle = PANEL, in_memory = 0 },
            'настройка «in_memory» должна быть больше нуля, а не 0',
        },
        -- Кусок сверяется с границами читателя `tnt-fs` при объявлении:
        -- иначе читатель бросил бы на первом запросе большого файла.
        {
            { bundle = PANEL, chunk = -1 },
            'настройка «chunk» должна быть числом от 1 до 67108864, а не -1',
        },
        {
            { bundle = PANEL, chunk = 0 },
            'настройка «chunk» должна быть числом от 1 до 67108864, а не 0',
        },
        {
            { bundle = PANEL, chunk = 0.5 },
            'настройка «chunk» должна быть числом от 1 до 67108864, а не 0.5',
        },
        {
            { bundle = PANEL, chunk = 64 * 1024 * 1024 + 1 },
            'настройка «chunk» должна быть числом от 1 до 67108864, а не 67108865',
        },
        {
            { bundle = PANEL, chunk = '64K' },
            'настройка «chunk» должна быть числом, а не string',
        },
        { { root = 7 }, 'настройка «root» должна быть строкой, а не number' },
        -- Пустой каталог склеился бы с именем в корень файловой системы.
        { { root = '' }, 'настройка «root» должна быть непустой строкой' },
        {
            { bundle = 'панель' },
            'настройка «bundle» должна быть таблицей, а не string',
        },
        -- Список вместо набора: имена числами молча не нашлись бы
        -- ни по одному адресу.
        {
            { bundle = { 'app.js' } },
            'имя файла в bundle должно быть строкой, а не number',
        },
        {
            { bundle = { ['app.js'] = { 'const a = 1;' } } },
            'файл «app.js» в bundle должен быть строкой, а не table',
        },
    }

    local cases = {}

    for _, case in ipairs(wrong) do
        table.insert(cases, {
            function()
                files().handler(case[1])
            end,
            case[2],
        })
    end

    -- Настройки не таблицей — тоже отказ на строке объявления, а не
    -- обращение к числу как к таблице внутри пакета.
    table.insert(cases, {
        function()
            files().handler(7)
        end,
        'настройка «раздача» должна быть таблицей, а не number',
    })

    helper.assert_blamed(cases)
end

g.test_delivery_works_on_a_request_written_by_hand_without_a_path = function()
    -- Пакет обещает, что запрос пишется таблицей и проверяется без
    -- сервера; требовать ради одной настройки поле, которое всегда
    -- проставляет сам роутер, значит это обещание сломать.
    local serve = files().handler({ bundle = PANEL, fallback = 'index.html', except = { '/api' } })

    t.assert_equals(serve({ params = {}, headers = {} }).body, '<h1>панель</h1>')
end

-- ── Настоящий диск ───────────────────────────────────────────────────

--- Пишет файл целиком, заменяя прежнее содержимое.
---@param path string
---@param text string
local function written(path, text)
    local handle = fio.open(path, { 'O_WRONLY', 'O_CREAT', 'O_TRUNC' }, tonumber('0644', 8))

    handle:write(text)
    handle:close()
end

g.test_file_is_read_from_the_directory_it_was_given = function()
    local root = fio.tempdir()
    written(fio.pathjoin(root, 'app.js'), 'const b = 2;')

    local sent = files().handler({ root = root })(asked('app.js'))

    t.assert_equals(sent.body, 'const b = 2;')
    t.assert_equals(sent.headers['content-type'], 'application/javascript; charset=utf-8')

    fio.rmtree(root)
end

g.test_file_rewritten_on_disk_is_given_out_anew_with_a_new_mark = function()
    -- С диска метка не запоминается: время правки у `fio.stat` в целых
    -- секундах, и файл, переписанный за ту же секунду, получил бы 304
    -- на новое содержимое. Здесь обе записи делаются подряд, без паузы.
    local root = fio.tempdir()
    local path = fio.pathjoin(root, 'app.js')

    written(path, 'const b = 2;')

    local handler = files().handler({ root = root })
    local first = handler(asked('app.js'))

    written(path, 'const b = 3;')

    local again = handler(asked('app.js', { ['if-none-match'] = first.headers.etag }))

    t.assert_equals(again.status, 200)
    t.assert_equals(again.body, 'const b = 3;')
    t.assert_equals(again.headers.etag, ('"%08x"'):format(require('digest').crc32('const b = 3;')))

    fio.rmtree(root)
end

g.test_missing_file_on_disk_is_left_to_the_router = function()
    local root = fio.tempdir()

    assert_gone(files().handler({ root = root })(asked('нет.js')))

    fio.rmtree(root)
end

g.test_directory_is_not_a_file_and_is_not_given_out = function()
    -- Каталог открывается, а читается пустотой: без этой ветки раздача
    -- ответила бы двумястами на `/panel/assets`.
    local root = fio.tempdir()

    fio.mkdir(fio.pathjoin(root, 'assets'))

    assert_gone(files().handler({ root = root })(asked('assets')))

    fio.rmtree(root)
end

g.test_file_system_is_asked_through_tnt_fs = function()
    -- Путь склеен из корня и имени, опрошен без раскрытия ссылки
    -- и прочитан — всё через `tnt-fs`, под которым подменён `fio`.
    local asked_about = {}

    helper.faked_fio({
        lstat = function(path)
            table.insert(asked_about, path)

            return {
                size = 12,
                mode = tonumber('644', 8),
                mtime = 0,
                is_reg = function()
                    return true
                end,
            }
        end,

        open = function(full)
            return {
                read = function()
                    return 'прочитано из ' .. full
                end,

                close = function()
                    return true
                end,
            }
        end,
    })

    t.assert_equals(
        files().handler({ root = 'корень' })(asked('app.js')).body,
        'прочитано из корень/app.js'
    )
    t.assert_equals(asked_about, { 'корень/app.js' })
end

-- ── Способы: GET, HEAD и всё остальное ───────────────────────────────

g.test_another_method_is_refused_with_the_list_of_allowed = function()
    -- Отказ парой: 405 рисует обработчик отказов приложения — тот же,
    -- что рисует 405 от дерева маршрутов, — и он же пишет о нём в журнал.
    -- Слово в самом отказе: страж приложения читает отказ раньше роутера.
    local sent, failure = files().handler({ bundle = PANEL })(asked('app.js', {}, 'POST'))

    t.assert_equals(sent, nil)
    t.assert_equals(failure, NOT_ALLOWED)
end

g.test_head_answers_with_the_same_headers_and_without_a_body = function()
    local handler = files().handler({ bundle = PANEL })
    local head = handler(asked('app.js', {}, 'HEAD'))
    local get = handler(asked('app.js', {}, 'GET'))

    t.assert_equals(head.status, 200)
    t.assert_equals(head.body, '')
    -- Длина названа раздачей: по RFC 9110 (9.3.2) заголовки ответа
    -- на HEAD — заголовки ответа на GET, а нулём длину дорисовал бы
    -- сервер по пустому телу.
    t.assert_equals(head.headers['content-length'], '12')
    t.assert_equals(get.headers['content-length'], nil)

    -- Длина дописывается ответу на GET, чтобы сравнить всё остальное
    -- целиком: заголовки HEAD и GET расходятся только ею.
    get.headers['content-length'] = '12'

    t.assert_equals(head.headers, get.headers)
    t.assert_equals(get.body, 'const a = 1;')
end

-- ── Выход за пределы раздачи ─────────────────────────────────────────

g.test_hidden_files_are_not_given_out_at_all = function()
    -- `.env` с паролями и `.git` с историей лежат рядом с отдаваемыми
    -- файлами чаще, чем хотелось бы.
    for _, requested in ipairs({ '.env', '.git/config', 'assets/.env', '.' }) do
        t.assert_equals(files().resolve(requested, 'index.html'), nil, requested)
    end

    assert_gone(files().handler({ bundle = { ['.env'] = 'SECRET=1' } })(asked('.env')))
end

g.test_empty_segment_is_a_step_out_of_the_delivery = function()
    -- `//etc/passwd` — это абсолютный путь, у которого сняли одну черту:
    -- оставшийся пустой участок и есть признак корня файловой системы.
    for _, requested in ipairs({ '//etc/passwd', 'assets//app.js', 'assets/' }) do
        t.assert_equals(files().resolve(requested, 'index.html'), nil, requested)
    end
end

g.test_null_byte_cuts_the_name_in_the_system_call = function()
    -- `app.js%00.png` открыл бы `app.js`, а тип содержимого раздача
    -- взяла бы по `png`: браузер получил бы сценарий под видом картинки.
    t.assert_equals(files().resolve('app.js\0.png', 'index.html'), nil)
end

-- ── Метка версии и время правки ──────────────────────────────────────

g.test_mark_is_matched_by_the_rule_of_the_specification = function()
    -- Клиент шлёт список меток, а посредник вправе пометить метку слабой:
    -- равенство строк целиком дало бы 200 с телом там, где хватает 304.
    local handler = files().handler({ bundle = PANEL })
    local tag = handler(asked('app.js')).headers.etag

    for _, given in ipairs({ tag, 'W/' .. tag, '"чужая", ' .. tag, '*' }) do
        t.assert_equals(handler(asked('app.js', { ['if-none-match'] = given })).status, 304, given)
    end

    t.assert_equals(handler(asked('app.js', { ['if-none-match'] = '"чужая"' })).status, 200)
end

g.test_bundle_has_no_time_of_change = function()
    -- У файла в памяти процесса времени правки нет вовсе, и сверять
    -- по нему свежесть нечем: остаётся метка.
    local handler = files().handler({ bundle = PANEL })
    local sent = handler(asked('app.js'))

    t.assert_equals(sent.headers['last-modified'], nil)

    local asking = asked('app.js', { ['if-modified-since'] = 'Sun, 06 Nov 2094 08:49:37 GMT' })

    t.assert_equals(handler(asking).status, 200)
end

-- ── Срок жизни копии ─────────────────────────────────────────────────

--- Файлы с отпечатком в имени и без него.
local FINGERPRINTED = {
    ['app-BX7Yy2Qk.css'] = 'body{}',
    ['app-BX7Yy2Q.css'] = 'body{}',
    ['app.min.css'] = 'body{}',
    ['9f1c2ad3-app.css'] = 'body{}',
}

g.test_file_with_a_fingerprint_in_its_name_is_cached_forever = function()
    -- Отпечаток в имени значит, что содержимое больше не изменится:
    -- изменится имя. Год кэша такому файлу ничем не грозит.
    local handler = files().handler({ bundle = FINGERPRINTED, immutable = true })

    t.assert_equals(handler(asked('app-BX7Yy2Qk.css')).headers['cache-control'], 'public, max-age=31536000, immutable')

    -- Семь знаков — ещё не отпечаток, а `min` и подавно: вечный кэш
    -- файлу без отпечатка чинится только у каждого клиента отдельно.
    t.assert_equals(handler(asked('app-BX7Yy2Q.css')).headers['cache-control'], 'no-cache')
    t.assert_equals(handler(asked('app.min.css')).headers['cache-control'], 'no-cache')
end

g.test_forever_cache_is_off_until_it_is_asked_for = function()
    local handler = files().handler({ bundle = FINGERPRINTED })

    t.assert_equals(handler(asked('app-BX7Yy2Qk.css')).headers['cache-control'], 'no-cache')
end

g.test_the_look_of_a_fingerprint_can_be_told_otherwise = function()
    -- Сборщик, ставящий отпечаток в начало имени, умолчанию не подходит:
    -- образец — настройка, а не встроенное знание про один сборщик.
    local handler = files().handler({
        bundle = FINGERPRINTED,
        immutable = true,
        fingerprint = '^([%w]+)%-',
    })

    t.assert_equals(handler(asked('9f1c2ad3-app.css')).headers['cache-control'], 'public, max-age=31536000, immutable')
    t.assert_equals(handler(asked('app-BX7Yy2Qk.css')).headers['cache-control'], 'no-cache')
end

-- ── Сжатие ───────────────────────────────────────────────────────────

--- Слой-двойник на месте сжатия: записывает, что ему дали, и отвечает
--- своим.
---
--- Сжатие приходит слоем: правила «что сжимать» живут в одном месте,
--- а роутер не знает, чем сжимают, и работает там, где сжатия нет. Его
--- сторона договора — отдать слою запрос как есть, дать раздачу следующим
--- шагом и вернуть то, что слой сделал с её ответом. Это и проверяется
--- здесь; настоящее сжатие поверх роутера сверяют проверки пакета сжатия.
---@param calls table[] Куда записывать: запрос и то, чем ответила раздача
---@param reply fun(served: table|nil, failure: table|nil): (table|nil, table|nil) Что слой делает с ответом
---@return fun(request: table, next: function): table|nil, table|nil
local function layer(calls, reply)
    return function(request, next)
        local served, failure = next(request)

        table.insert(calls, { request = request, served = served, failure = failure })

        return reply(served, failure)
    end
end

g.test_the_compress_layer_gets_the_request_and_the_answer_of_the_delivery = function()
    local body = string.rep('const a = 1;\n', 200)
    local calls = {}
    local compressed = { status = 200, headers = { ['content-encoding'] = 'gzip' }, body = 'сжатое' }
    local handler = files().handler({
        bundle = { ['app.js'] = body },
        compress = layer(calls, function()
            return compressed
        end),
    })
    local asking = asked('app.js', { ['accept-encoding'] = 'gzip' })
    local sent = handler(asking)

    -- Отдан ответ слоя, а не раздачи: сжатый ответ собирает он.
    t.assert_is(sent, compressed)
    t.assert_equals(#calls, 1)

    -- Слою — тот же запрос: сжимать ли, он решает по его заголовкам.
    t.assert_is(calls[1].request, asking)

    -- Следующий шаг слоя — сама раздача: тело файла и его заголовки,
    -- по типу которых слой решает, сжимается ли такое вообще.
    ---@type any
    local served = calls[1].served
    local plain = files().handler({ bundle = { ['app.js'] = body } })(asked('app.js'))

    t.assert_equals(served, plain)
    t.assert_equals(served.body, body)
    t.assert_equals(served.headers['content-type'], 'application/javascript; charset=utf-8')
end

g.test_the_refusal_of_the_delivery_goes_through_the_compress_layer_as_a_pair = function()
    -- Отказ парой идёт через слой, как и ответ: 405 рисует обработчик
    -- отказов приложения, и слой, съевший вторую половину пары, оставил
    -- бы роутер с пустотой вместо отказа.
    local calls = {}
    local handler = files().handler({
        bundle = PANEL,
        compress = layer(calls, function(served, failure)
            return served, failure
        end),
    })
    local sent, failure = handler(asked('app.js', {}, 'POST'))

    t.assert_equals(sent, nil)
    t.assert_equals(failure, NOT_ALLOWED)
    t.assert_equals(calls[1].failure, failure)

    -- И отказ «файла нет»: он той же породы.
    assert_gone(handler(asked('нет.js')))
    t.assert_equals(calls[2].failure, { status = 404, message = 'нет такого адреса' })
end

-- ── Объявление раздачи маршрутом ─────────────────────────────────────

g.test_delivery_builds_the_route_it_needs = function()
    local pattern, handler, route = files().route('/build/', 'public/build', { name = 'assets' }, 2)

    -- Хвостовая черта снимается: `/build/` и `/build` — одно начало.
    t.assert_equals(pattern, '/build/*path')
    t.assert_equals(route, { name = 'assets' })
    t.assert_equals(type(handler), 'function')

    -- Корень: хвост ловит всё, чего не поймали объявленные маршруты.
    t.assert_equals((files().route('/', 'public', nil, 2)), '/*path')
    t.assert_equals((files().route('/build', 'public/build', { param = 'rest' }, 2)), '/build/*rest')
end

g.test_settings_of_the_declared_delivery_are_checked_too = function()
    -- Уровень вины приходит от того, кто объявляет раздачу маршрутом:
    -- второй — строка, позвавшая `route`, то есть эта.
    helper.assert_blamed({
        {
            function()
                files().route('/build', 'public/build', 'сразу', 2)
            end,
            'настройка «раздача» должна быть таблицей, а не string',
        },
        {
            function()
                files().route(7, 'public', nil, 2)
            end,
            'настройка «prefix» должна быть строкой, а не number',
        },
        {
            function()
                files().route('/build', 'public/build', { cache = 60 }, 2)
            end,
            'настройка «cache» должна быть строкой, а не number',
        },
        -- Имя хвоста проверяется до склейки шаблона: таблица сорвалась бы
        -- склейкой строки внутри пакета.
        {
            function()
                files().route('/build', 'public/build', { param = {} }, 2)
            end,
            'настройка «param» должна быть строкой, а не table',
        },
        {
            function()
                files().route('/build', 7, nil, 2)
            end,
            'настройка «root» должна быть строкой, а не number',
        },
    })
end

-- ── Время правки файла на диске ──────────────────────────────────────

--- Каталог с одним файлом и путь к нему.
---@param name string
---@param text string
---@return string root
---@return string path
local function with_file(name, text)
    local root = fio.tempdir()
    local path = fio.pathjoin(root, name)

    written(path, text)

    return root, path
end

g.test_file_from_disk_tells_when_it_was_changed = function()
    local date = require('tnt.date')
    local root, path = with_file('app.js', 'const b = 2;')
    local sent = files().handler({ root = root })(asked('app.js'))

    t.assert_equals(sent.headers['last-modified'], date.http(fio.lstat(path).mtime))

    fio.rmtree(root)
end

g.test_file_unchanged_since_the_named_time_is_not_sent_again = function()
    local date = require('tnt.date')
    local root, path = with_file('app.js', 'const b = 2;')
    local handler = files().handler({ root = root })
    local mtime = fio.lstat(path).mtime

    local fresh = handler(asked('app.js', { ['if-modified-since'] = date.http(mtime) }))

    t.assert_equals(fresh.status, 304)
    t.assert_equals(fresh.body, nil)
    -- В 304 уходит и время правки: по нему клиент продлевает свою копию.
    t.assert_equals(fresh.headers['last-modified'], date.http(mtime))

    -- Копия старше файла — значит, у клиента не тот файл.
    local older = handler(asked('app.js', { ['if-modified-since'] = date.http(mtime - 10) }))

    t.assert_equals(older.status, 200)

    -- Мусор вместо даты — это 200 с телом, а не отказ: заголовок пишет
    -- клиент, и неразобранная дата значит лишь, что свежести не видно.
    local nonsense = handler(asked('app.js', { ['if-modified-since'] = 'вчера' }))

    t.assert_equals(nonsense.status, 200)

    fio.rmtree(root)
end

g.test_fraction_of_a_second_does_not_hide_an_unchanged_file = function()
    -- На Linux `fio.lstat` отдаёт время правки с дробью, а заголовки несут
    -- целые секунды: без округления файл был бы новее любой даты, которую
    -- браузер присылает назад, и 304 не приходил бы никогда. Округляет
    -- `tnt-fs`, а проверка держит то, что раздача берёт время у него.
    -- Дробь подставлена явно: на macOS `fio` её не отдаёт.
    local root, path = with_file('app.js', 'const b = 2;')
    local stat = setmetatable({ mtime = 1790190195.706 }, { __index = fio.lstat(path) })

    helper.faked_fio({
        lstat = function()
            return stat
        end,
    })

    -- В памяти и кусками: время правки каждый путь кладёт сам.
    for _, in_memory in ipairs({ 1024, 4 }) do
        local handler = files().handler({ root = root, in_memory = in_memory })
        local seen = 'Wed, 23 Sep 2026 19:03:15 GMT'

        t.assert_equals(handler(asked('app.js')).headers['last-modified'], seen)
        t.assert_equals(handler(asked('app.js', { ['if-modified-since'] = seen })).status, 304)

        local earlier = asked('app.js', { ['if-modified-since'] = 'Wed, 23 Sep 2026 19:03:14 GMT' })

        t.assert_equals(handler(earlier).status, 200)
    end

    fio.rmtree(root)
end

g.test_the_mark_is_asked_before_the_time = function()
    -- По RFC 9110 метка главнее времени: время в заголовке — целые
    -- секунды, а метка меняется вместе с содержимым.
    local date = require('tnt.date')
    local root, path = with_file('app.js', 'const b = 2;')
    local handler = files().handler({ root = root })
    local asking = asked('app.js', {
        ['if-none-match'] = '"чужая"',
        ['if-modified-since'] = date.http(fio.lstat(path).mtime),
    })

    t.assert_equals(handler(asking).status, 200)

    fio.rmtree(root)
end

-- ── Ссылки и прочее, что не обычный файл ─────────────────────────────

g.test_symbolic_link_is_not_given_out = function()
    -- `realpath` в fio нет, и отличить ссылку внутрь раздачи от ссылки
    -- на `/etc/passwd` нечем: наружу не уходит ни та, ни другая.
    local root = fio.tempdir()

    fio.symlink('/etc/hosts', fio.pathjoin(root, 'hosts.txt'))

    assert_gone(files().handler({ root = root })(asked('hosts.txt')))

    fio.rmtree(root)
end

-- ── Большой файл: ответ по кускам ────────────────────────────────────

--- Тело ответа, собранное так же, как его собирает сервер.
local drained = helper.drained

g.test_file_bigger_than_the_limit_goes_out_in_chunks = function()
    -- Иначе гигабайт лёг бы в память узла одной строкой — ровно то,
    -- ради чего ответ и режется на куски.
    local body = string.rep('a', 5000)
    local root, path = with_file('big.css', body)
    local stat = fio.lstat(path)
    local sent = files().handler({ root = root, in_memory = 1024, chunk = 1024 })(asked('big.css'))

    t.assert_equals(sent.status, 200)
    t.assert_equals(sent.headers['content-type'], 'text/css; charset=utf-8')
    -- Метка большого файла — размер и время правки: читать его целиком
    -- ради crc32 значит сделать то, чего отдача кусками и избегает.
    t.assert_equals(sent.headers.etag, ('"%x-%x"'):format(stat.size, stat.mtime))

    local parts = drained(sent)

    t.assert_equals(table.concat(parts), body)
    t.assert_equals(#parts, 5)

    fio.rmtree(root)
end

g.test_the_compress_layer_gets_a_big_file_as_chunks = function()
    -- Большой файл доходит до слоя сжатия ответом по кускам, а не строкой:
    -- поток слой сжимает кусок за куском, и память узла на целый файл
    -- не уходит и под ним.
    local body = string.rep('a', 5000)
    local root = with_file('big.css', body)
    local calls = {}
    local handler = files().handler({
        root = root,
        in_memory = 1024,
        chunk = 1024,
        compress = layer(calls, function(served)
            return served
        end),
    })
    local sent = handler(asked('big.css'))

    t.assert_is(calls[1].served, sent)
    t.assert_equals(type(sent.body), 'function')
    t.assert_equals(table.concat(drained(sent)), body)

    fio.rmtree(root)
end

g.test_file_of_exactly_the_limit_still_fits_in_memory = function()
    -- Граница включающая: предел — это «сколько можно держать в памяти»,
    -- а не «с какого размера резать», и файл ровно в предел уходит
    -- строкой, с меткой по содержимому.
    local body = string.rep('a', 1024)
    local root = with_file('edge.css', body)
    local handler = files().handler({ root = root, in_memory = 1024 })
    local sent = handler(asked('edge.css'))

    t.assert_equals(sent.body, body)
    t.assert_equals(sent.headers.etag, ('"%08x"'):format(require('digest').crc32(body)))

    fio.rmtree(root)
end

g.test_the_limit_and_the_chunk_have_their_own_defaults = function()
    -- Умолчания названы в документе, и стоят они не «примерно»: файл
    -- ровно в мегабайт ещё читается строкой, а больший уходит кусками
    -- по 64 КБ. Проверка держит оба числа.
    local limit = 1024 * 1024
    local root, path = with_file('fits.css', string.rep('a', limit))
    local handler = files().handler({ root = root })

    t.assert_equals(#handler(asked('fits.css')).body, limit)

    written(path, string.rep('a', limit + 1))

    local streamed = handler(asked('fits.css'))
    local parts = drained(streamed)

    t.assert_equals(type(streamed.body), 'function')
    t.assert_equals(#parts[1], 64 * 1024)
    t.assert_equals(#table.concat(parts), limit + 1)

    fio.rmtree(root)
end

g.test_a_single_byte_is_a_lawful_limit_and_a_lawful_chunk = function()
    -- Единица больше нуля, и отвергать её значило бы врать в тексте
    -- отказа — там сказано «больше нуля».
    local root = with_file('tiny.css', 'body')
    local sent = files().handler({ root = root, in_memory = 1, chunk = 1 })(asked('tiny.css'))

    t.assert_equals(drained(sent), { 'b', 'o', 'd', 'y' })

    fio.rmtree(root)
end

g.test_the_largest_chunk_of_the_reader_is_a_lawful_chunk = function()
    -- Граница включающая: кусок ровно в предел читателя `tnt-fs` —
    -- обычная настройка, а не отказ.
    local root = with_file('big.css', string.rep('a', 5000))
    local sent = files().handler({ root = root, in_memory = 1024, chunk = 64 * 1024 * 1024 })(asked('big.css'))

    t.assert_equals(drained(sent), { string.rep('a', 5000) })

    fio.rmtree(root)
end

g.test_hidden_name_is_told_by_the_leading_dot_and_nothing_else = function()
    -- Черта и подчёркивание в начале имени — обычные знаки: файл
    -- `-dash.css` лежит на месте и отдаётся.
    t.assert_equals(files().resolve('-dash.css', 'index.html'), '-dash.css')
    t.assert_equals(files().resolve('_dash.css', 'index.html'), '_dash.css')
end

g.test_big_file_answers_304_by_its_mark = function()
    local root = with_file('big.css', string.rep('a', 5000))
    local handler = files().handler({ root = root, in_memory = 1024 })
    local first = handler(asked('big.css'))
    local again = handler(asked('big.css', { ['if-none-match'] = first.headers.etag }))

    t.assert_equals(again.status, 304)

    fio.rmtree(root)
end

g.test_head_of_a_big_file_tells_its_length_without_opening_it = function()
    -- Файл сверх предела памяти уходит кусками, и длины у такого ответа
    -- нет вовсе: на GET её не бывает, а на HEAD она берётся у `lstat`.
    local root = with_file('big.css', string.rep('a', 5000))
    local handler = files().handler({ root = root, in_memory = 1024 })

    t.assert_equals(handler(asked('big.css', {}, 'HEAD')).headers['content-length'], '5000')
    t.assert_equals(handler(asked('big.css')).headers['content-length'], nil)

    fio.rmtree(root)
end

g.test_head_of_a_big_file_opens_nothing = function()
    local root = with_file('big.css', string.rep('a', 5000))
    local sent = files().handler({ root = root, in_memory = 1024 })(asked('big.css', {}, 'HEAD'))

    t.assert_equals(sent.body, '')
    t.assert_equals(sent.headers['content-type'], 'text/css; charset=utf-8')

    fio.rmtree(root)
end

g.test_file_taken_away_after_the_answer_was_built_goes_out_whole = function()
    -- Файл открыт до ответа, и открытый файл переживает удаление: клиент
    -- получает его целиком, а не оборванным посередине.
    local root = with_file('big.css', string.rep('a', 5000))
    local sent = files().handler({ root = root, in_memory = 1024 })(asked('big.css'))

    fio.rmtree(root)

    t.assert_equals(table.concat(drained(sent)), string.rep('a', 5000))
end

g.test_file_that_stopped_reading_breaks_the_answer_too = function()
    -- Кончившийся источник сервер закрывает завершающим куском, и клиент
    -- принял бы обрезанный файл за целый: поэтому обрыв — отказ парой.
    local root = with_file('big.css', string.rep('a', 5000))

    helper.faked_fio({
        open = function()
            return {
                read = function()
                    return nil, { errno = require('errno').EIO }
                end,

                close = function()
                    return true
                end,
            }
        end,
    })

    local journal = helper.capture_log()
    local sent = files().handler({ root = root, in_memory = 1024 })(asked('big.css'))

    t.assert_error_msg_contains('поток ответа оборван', function()
        drained(sent)
    end)

    -- В журнал уходит отказ `tnt-fs`: что не прочитано и почему.
    local found = journal.find('поток ответа оборван')

    t.assert_not_equals(found, nil)
    t.assert_str_contains(found.line, fio.pathjoin(root, 'big.css') .. ' не прочитан: Input/output error')
    journal.release()

    fio.rmtree(root)
end

g.test_file_that_disappeared_between_stat_and_reading_is_missing = function()
    -- Между опросом и чтением файл успевают убрать: раздача отвечает
    -- «нет такого файла», а не пустым телом или оборванным потоком
    -- с кодом 200 — и в памяти, и кусками.
    local root = with_file('app.js', string.rep('a', 5000))

    helper.faked_fio({
        open = function()
            return nil, { errno = require('errno').ENOENT }
        end,
    })

    for _, in_memory in ipairs({ 1024 * 1024, 1024 }) do
        assert_gone(files().handler({ root = root, in_memory = in_memory })(asked('app.js')))
    end

    -- Свой ответ на промах раздача зовёт и здесь.
    local missing = files().handler({
        root = root,
        in_memory = 1024,
        missing = function()
            return { status = 410, body = 'ушёл' }
        end,
    })

    t.assert_equals(missing(asked('app.js')), { status = 410, body = 'ушёл' })

    fio.rmtree(root)
end

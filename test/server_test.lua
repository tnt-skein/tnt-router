--- Тесты поверх настоящего сервера: роутер, поднятый на живом порту.
---
--- Всё остальное проверяется запросом-таблицей, и это правильно: так
--- проверка быстрая и в ней видно, что именно проверяется. Но роутер,
--- который безупречен на таблицах и не умеет ответить настоящему
--- браузеру, бесполезен — а разойтись они могут в мелочах: в том, как
--- сервер отдаёт путь, строку запроса и заголовки.
---
--- Сервер поднимается тут же, на случайном порту: докер для этого
--- не нужен, и гейт от него не зависит.

local t = require('luatest')

local clock = require('clock')
local http_client = require('http.client')
local socket = require('socket')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.server')

--- Поднятый сервер и адрес, по которому к нему ходить.
---@param limits table|nil Пределы тела для `attach`
---@return table httpd
---@return string address
local function serving(limits)
    local httpd, address = helper.served(g.router, limits)

    return httpd, address
end

--- Сырой разговор с сервером: что послано, то и прочитано до закрытия.
---
--- Клиент HTTP здесь не годится: он сам шлёт тело целиком и сам собирает
--- куски, а проверяется как раз то, что сервер делает с недосланным телом
--- и что шлёт в сокет.
---@param httpd table
---@param sent string
---@return string answer Всё, что пришло до закрытия соединения
---@return number seconds Сколько ждали закрытия
local function talked(httpd, sent)
    local connection = socket.tcp_connect('127.0.0.1', httpd.tcp_server:name().port)
    local started = clock.monotonic()
    local parts = {}

    connection:write(sent)

    while true do
        local part = connection:read(4096, 3)

        if part == nil or part == '' then
            break
        end

        table.insert(parts, part)
    end

    connection:close()

    return table.concat(parts), clock.monotonic() - started
end

--- Запрос к поднятому серверу.
---@param address string
---@param method string
---@param where string
---@param body string|nil
---@return table
local function asked(address, method, where, body)
    return http_client.new():request(method, address .. where, body, { timeout = 5 })
end

g.test_real_browser_gets_the_answer_of_the_declared_route = function()
    g.router.get('/customers/:id<int>', function(request)
        return g.router.json({ id = request.params.id, page = request.query.page })
    end)

    local httpd, address = serving()
    local answer = asked(address, 'GET', '/customers/7?page=2')

    t.assert_equals(answer.status, 200)
    t.assert_equals(answer.headers['content-type'], 'application/json; charset=utf-8')
    t.assert_equals(require('json').decode(answer.body), { id = '7', page = '2' })

    httpd:stop()
end

g.test_body_and_headers_reach_the_handler_over_the_wire = function()
    g.router.post('/customers', function(request)
        return g.router.text(('%s|%s'):format(request.body, request.headers['content-type']))
    end)

    local httpd, address = serving()
    local answer = http_client.new():request('POST', address .. '/customers', '{"name":"тот"}', {
        headers = { ['Content-Type'] = 'application/json' },
        timeout = 5,
    })

    t.assert_equals(answer.body, '{"name":"тот"}|application/json')

    httpd:stop()
end

g.test_missing_address_is_a_real_404_and_not_a_page_of_the_server = function()
    -- Без подмены обработчика сервер отвечал бы своей раздачей статики.
    local httpd, address = serving()
    local answer = asked(address, 'GET', '/customers')

    t.assert_equals(answer.status, 404)
    t.assert_equals(require('json').decode(answer.body).error.message, 'нет такого адреса')

    httpd:stop()
end

g.test_wrong_method_brings_the_allow_header_to_the_client = function()
    g.router.get('/customers', helper.answering('список'))

    local httpd, address = serving()
    local answer = asked(address, 'DELETE', '/customers')

    t.assert_equals(answer.status, 405)
    t.assert_equals(answer.headers.allow, 'GET, HEAD, OPTIONS')

    httpd:stop()
end

g.test_head_comes_back_without_a_body = function()
    g.router.get('/customers', helper.answering('список'))

    local httpd, address = serving()
    local answer = asked(address, 'HEAD', '/customers')

    t.assert_equals(answer.status, 200)
    t.assert_equals(answer.body, nil)
    -- Роутер называет настоящую длину (`dispatch` выше), а до клиента
    -- доезжает ноль: `http.server` 1.9.1 пересчитывает `content-length`
    -- по телу, которое пишет в сокет, и затирает названное обработчиком.
    -- Правка рока заготовлена обращением № 25 (docs/upstream.md); когда
    -- она приедет, здесь станет длина ответа на GET, и проверка об этом
    -- скажет падением.
    t.assert_equals(g.router.dispatch(helper.request('HEAD', '/customers')).headers['content-length'], '12')
    t.assert_equals(answer.headers['content-length'], '0')

    httpd:stop()
end

g.test_panel_files_are_given_out_to_a_real_client = function()
    g.router.get(
        '/panel/*path',
        g.router.files({
            bundle = { ['index.html'] = '<h1>панель</h1>', ['app.js'] = 'const a = 1;' },
            fallback = 'index.html',
        })
    )

    local httpd, address = serving()

    t.assert_equals(asked(address, 'GET', '/panel/app.js').body, 'const a = 1;')
    t.assert_equals(asked(address, 'GET', '/panel/nodes').body, '<h1>панель</h1>')

    local first = asked(address, 'GET', '/panel/app.js')
    local again = http_client.new():request('GET', address .. '/panel/app.js', nil, {
        headers = { ['If-None-Match'] = first.headers.etag },
        timeout = 5,
    })

    t.assert_equals(again.status, 304)

    httpd:stop()
end

g.test_fallen_handler_does_not_take_the_server_down = function()
    g.router.get('/customers', function()
        error('таблицы нет')
    end)

    g.router.get('/health', helper.answering('живой'))

    local httpd, address = serving()

    t.assert_equals(asked(address, 'GET', '/customers').status, 500)
    t.assert_equals(asked(address, 'GET', '/health').body, 'живой')

    httpd:stop()
end

g.test_body_over_the_limit_gets_413_without_being_waited_for = function()
    -- Тело заявлено, но не послано. Отказ приходит сразу и соединение
    -- закрывается: дочитывай сервер заявленное, он ждал бы его без срока.
    g.router.post('/customers', helper.answering('заведён'))

    local httpd = serving({ max_body = 10 })
    local answer, seconds = talked(httpd, 'POST /customers HTTP/1.1\r\nHost: a\r\nContent-Length: 100000\r\n\r\nabc')

    t.assert_str_matches(answer, '^HTTP/1.1 413 .*')
    t.assert_str_contains(answer:lower(), 'connection: close')
    t.assert_str_contains(answer, 'тело запроса слишком велико')
    t.assert_lt(seconds, 1)

    httpd:stop()
end

g.test_body_that_drips_gets_408_when_its_time_is_out = function()
    g.router.post('/customers', helper.answering('заведён'))

    local httpd = serving({ body_timeout = 0.2 })
    local answer, seconds = talked(httpd, 'POST /customers HTTP/1.1\r\nHost: a\r\nContent-Length: 10\r\n\r\nabc')

    t.assert_str_matches(answer, '^HTTP/1.1 408 .*')
    t.assert_str_contains(answer:lower(), 'connection: close')
    t.assert_ge(seconds, 0.2)
    t.assert_lt(seconds, 1)

    httpd:stop()
end

g.test_empty_body_is_answered_and_the_connection_is_kept = function()
    g.router.post('/customers', function(request)
        return g.router.text(('[%s]'):format(request.body))
    end)

    local httpd = serving()
    local connection = socket.tcp_connect('127.0.0.1', httpd.tcp_server:name().port)

    connection:write('POST /customers HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n')

    local answer = connection:read({ delimiter = '[]' }, 3)

    t.assert_str_matches(answer, '^HTTP/1.1 200 .*%[%]$')
    t.assert_str_contains(answer:lower(), 'connection: keep-alive')

    connection:close()
    httpd:stop()
end

g.test_stream_reaches_a_real_client_in_pieces = function()
    local lines = { '{"n":1}\n', '{"n":2}\n', '{"n":3}\n' }

    g.router.get('/audit', function()
        local index = 0

        return g.router.stream(function()
            index = index + 1

            return lines[index]
        end, 200, { ['content-type'] = 'application/x-ndjson' })
    end)

    local httpd, address = serving()
    local answer = asked(address, 'GET', '/audit')

    t.assert_equals(answer.status, 200)
    t.assert_equals(answer.headers['transfer-encoding'], 'chunked')
    t.assert_equals(answer.headers['content-type'], 'application/x-ndjson')
    t.assert_equals(answer.body, table.concat(lines))

    -- HEAD того же адреса — заголовки без тела, а не поток.
    t.assert_equals(asked(address, 'HEAD', '/audit').status, 200)

    httpd:stop()
end

g.test_broken_stream_is_cut_off_without_the_final_piece = function()
    -- Клиент обязан увидеть обрыв: завершающий кусок сказал бы ему,
    -- что выгрузка целая.
    g.router.get('/audit', function()
        local given = false

        return g.router.stream(function()
            if given then
                return nil, 'курсор потерян'
            end

            given = true

            return 'первая\n'
        end)
    end)

    local httpd = serving()
    local answer = talked(httpd, 'GET /audit HTTP/1.1\r\nHost: a\r\n\r\n')

    t.assert_str_contains(answer, 'первая\n')
    t.assert_not_str_contains(answer, '\r\n0\r\n\r\n')

    httpd:stop()
end

g.test_broken_stream_names_the_request_the_client_was_told = function()
    -- Тело потока сервер обходит, когда слои входа уже вернули ответ
    -- и вышли из своих областей. Номер, названный клиенту
    -- в `x-request-id`, обязан найтись в записи об обрыве — иначе обрыв
    -- выгрузки не связать ни с запросом, ни с клиентом.
    local ok = pcall(require, 'tnt.middleware')

    t.skip_if(not ok, 'пакет слоёв не установлен')

    g.router.get('/audit', function()
        local given = false

        return g.router.stream(function()
            if given then
                return nil, 'спейс снесён посреди выгрузки'
            end

            given = true

            return 'первая\n'
        end)
    end, { middleware = { 'request_id_header', 'request_id', 'log' } })

    local journal = helper.capture_log()

    journal.forget()

    local httpd = serving()
    local answer = talked(httpd, 'GET /audit HTTP/1.1\r\nHost: a\r\n\r\n')

    httpd:stop()

    local told = answer:match('\r\n[Xx]%-[Rr]equest%-[Ii]d: ([^\r]+)\r\n')
    local passed = journal.find('запрос прошёл')
    local cut = journal.find('поток ответа оборван')

    journal.release()

    t.assert_not_equals(told, nil)
    t.assert_equals(passed.record.request_id, told)
    t.assert_equals(cut.record.request_id, told)
    t.assert_equals(cut.record.fields.reason, 'спейс снесён посреди выгрузки')
    t.assert_equals(cut.record.fields.bytes, #'первая\n')
end

--- Каталог сборки на диске: файл с отпечатком, скрытый файл и большой.
---@return string root
local function build_directory()
    local fio = require('fio')
    local root = fio.tempdir()

    --- Пишет файл целиком.
    ---@param name string
    ---@param text string
    local function written(name, text)
        local handle = fio.open(fio.pathjoin(root, name), { 'O_WRONLY', 'O_CREAT' }, tonumber('0644', 8))

        handle:write(text)
        handle:close()
    end

    written('app-BX7Yy2Qk.css', 'body{background:#fff}')
    written('.env', 'APP_SECRET=1')
    written('big.js', string.rep('const a = 1;\n', 500))

    return root
end

g.test_built_files_are_given_out_to_a_real_client = function()
    local fio = require('fio')
    local root = build_directory()

    g.router.serve('/build', root, { immutable = true, in_memory = 1024, chunk = 512 })

    local httpd, address = serving()
    local sent = asked(address, 'GET', '/build/app-BX7Yy2Qk.css')

    t.assert_equals(sent.status, 200)
    t.assert_equals(sent.body, 'body{background:#fff}')
    t.assert_equals(sent.headers['content-type'], 'text/css; charset=utf-8')
    t.assert_equals(sent.headers['cache-control'], 'public, max-age=31536000, immutable')
    t.assert_not_equals(sent.headers.etag, nil)
    t.assert_not_equals(sent.headers['last-modified'], nil)

    --- Тот же запрос с условием: браузер приходит с тем, что получил.
    ---@param name string
    ---@param value string
    ---@return table
    local function conditional(name, value)
        return http_client.new():request('GET', address .. '/build/app-BX7Yy2Qk.css', nil, {
            headers = { [name] = value },
            timeout = 5,
        })
    end

    t.assert_equals(conditional('If-None-Match', sent.headers.etag).status, 304)
    t.assert_equals(conditional('If-Modified-Since', sent.headers['last-modified']).status, 304)

    -- HEAD — те же заголовки, тела нет.
    local head = asked(address, 'HEAD', '/build/app-BX7Yy2Qk.css')

    t.assert_equals(head.status, 200)
    t.assert_equals(head.body, nil)
    t.assert_equals(head.headers['content-type'], 'text/css; charset=utf-8')
    t.assert_equals(head.headers.etag, sent.headers.etag)

    -- Способ не тот — 405 с перечнем.
    local refused = asked(address, 'POST', '/build/app-BX7Yy2Qk.css')

    t.assert_equals(refused.status, 405)
    t.assert_equals(refused.headers.allow, 'GET, HEAD, OPTIONS')

    -- Шаг вверх и скрытый файл — обычный промах по адресу: устройство
    -- диска наружу не показывается. Открытый шаг вверх схлопывает сам
    -- клиент (libcurl шлёт уже `/etc/passwd`), а закодированный до узла
    -- и вовсе не доходит: `http.server` отвергает такой адрес своим 400
    -- «invalid uri» ещё до роутера. 404 на него отвечает роутер, когда
    -- запрос приходит не по сети (см. tnt.router: раздача под началом).
    t.assert_equals(asked(address, 'GET', '/build/../etc/passwd').status, 404)
    t.assert_equals(asked(address, 'GET', '/build/%2e%2e/etc/passwd').status, 400)
    t.assert_equals(asked(address, 'GET', '/build/.env').status, 404)

    -- Большой файл идёт кусками и приходит целым.
    local big = asked(address, 'GET', '/build/big.js')

    t.assert_equals(big.status, 200)
    t.assert_equals(big.headers['transfer-encoding'], 'chunked')
    t.assert_equals(big.body, string.rep('const a = 1;\n', 500))

    httpd:stop()
    fio.rmtree(root)
end

--- Метка границы для проверок формы.
local BOUNDARY = 'ГРАНИЦА-42'

--- Запрос формой к поднятому серверу.
---@param address string
---@param body string
---@param boundary string|nil Метка в заголовке; по умолчанию настоящая
---@return table
local function submitted(address, body, boundary)
    return http_client.new():request('POST', address .. '/customers', body, {
        headers = {
            ['Content-Type'] = 'multipart/form-data; boundary=' .. (boundary or BOUNDARY),
        },
        timeout = 10,
    })
end

g.test_browser_form_reaches_the_handler_over_the_wire = function()
    g.router.post('/customers', function(request)
        return g.router.text(('%s|%s'):format(request.form.name, request.form.city))
    end)

    local httpd, address = serving()
    local answer = http_client.new():request(
        'POST',
        address .. '/customers',
        'name=%D0%98%D0%B2%D0%B0%D0%BD&city=Нижний+Новгород',
        {
            headers = { ['Content-Type'] = 'application/x-www-form-urlencoded' },
            timeout = 5,
        }
    )

    t.assert_equals(answer.status, 200)
    t.assert_equals(answer.body, 'Иван|Нижний Новгород')

    httpd:stop()
end

g.test_uploaded_file_comes_over_the_wire_whole = function()
    local fio = require('fio')
    local root = fio.tempdir()
    local seen = {}

    g.router.post('/customers', function(request)
        local file = request.files.doc

        seen = {
            name = file.name,
            client_name = file.client_name,
            size = file.size,
            kind = file.type,
            body = file:read(),
            title = request.form.title,
            -- Часть без имени файла — это текстовое поле, а не файл.
            files = request.files.title == nil,
        }

        return g.router.text('принято')
    end)

    local httpd, address = serving({ in_memory = 512, temp_dir = root })
    local body = helper.multipart(BOUNDARY, {
        { name = 'title', body = 'отчёт за год' },
        {
            name = 'doc',
            filename = '../отчёт.pdf',
            type = 'application/pdf',
            body = string.rep('P', 1024),
        },
    })

    t.assert_equals(submitted(address, body).body, 'принято')
    t.assert_equals(seen.title, 'отчёт за год')
    t.assert_equals(seen.files, true)
    t.assert_equals(seen.client_name, '../отчёт.pdf')
    t.assert_equals(seen.name, 'отчёт.pdf')
    t.assert_equals(seen.kind, 'application/pdf')
    t.assert_equals(seen.size, 1024)
    t.assert_equals(seen.body, string.rep('P', 1024))
    -- Временные файлы убраны после ответа.
    t.assert_equals(fio.listdir(root), {})

    -- Соединение после разобранного тела остаётся годным: остатка в нём
    -- не осталось.
    t.assert_equals(asked(address, 'GET', '/nowhere').status, 404)

    httpd:stop()
    fio.rmtree(root)
end

g.test_ten_megabyte_upload_does_not_stay_in_memory = function()
    local fio = require('fio')
    local root = fio.tempdir()
    local sent = string.rep('x', 10 * 1024 * 1024)
    local seen = {}

    g.router.post('/customers', function(request)
        local file = request.files.doc

        seen = { size = file.size, path = file.path, name = file.name }

        -- Читается не содержимое, а место: десять мегабайт лежат
        -- на диске, и поднимать их в память ради проверки незачем.
        return g.router.text(tostring(fio.lstat(file.path).size))
    end)

    local httpd, address = serving({
        max_body = 12 * 1024 * 1024,
        in_memory = 64 * 1024,
        temp_dir = root,
    })

    local body = helper.multipart(BOUNDARY, {
        { name = 'doc', filename = 'большой.bin', type = 'application/octet-stream', body = sent },
    })

    t.assert_equals(submitted(address, body).body, tostring(#sent))
    t.assert_equals(seen.size, #sent)
    t.assert_equals(seen.name, 'большой.bin')
    t.assert_equals(fio.dirname(seen.path), root)
    t.assert_equals(fio.listdir(root), {})

    httpd:stop()
    fio.rmtree(root)
end

g.test_broken_boundary_is_answered_with_400 = function()
    g.router.post('/customers', helper.answering('заведён'))

    local httpd, address = serving()
    local body = helper.multipart(BOUNDARY, { { name = 'title', body = 'отчёт' } })
    -- Метка в заголовке одна, а в теле другая: делить тело нечем.
    local answer = submitted(address, body, 'ДРУГАЯ-ГРАНИЦА')

    t.assert_equals(answer.status, 400)
    t.assert_equals(require('json').decode(answer.body).error.message, 'запрос не разобран')

    httpd:stop()
end

g.test_file_over_the_limit_is_answered_with_413 = function()
    local fio = require('fio')
    local root = fio.tempdir()

    g.router.post('/customers', helper.answering('заведён'))

    local httpd, address = serving({ in_memory = 64, max_file_size = 128, temp_dir = root })
    local body = helper.multipart(BOUNDARY, {
        { name = 'doc', filename = 'большой.bin', body = string.rep('x', 1024) },
    })
    local answer = submitted(address, body)

    t.assert_equals(answer.status, 413)
    t.assert_equals(
        require('json').decode(answer.body).error.message,
        'тело запроса слишком велико'
    )
    -- Отказ не оставляет за собой недописанного временного файла.
    t.assert_equals(fio.listdir(root), {})

    httpd:stop()
    fio.rmtree(root)
end

--- Тесты приведения запроса к общему виду.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.request')

--- Приведение запроса.
---@return any
local function request()
    return helper.part('tnt.router.request')
end

g.test_query_string_becomes_a_table = function()
    t.assert_equals(request().parse_query('page=2&sort=name'), { page = '2', sort = 'name' })
end

g.test_field_without_a_value_is_still_a_field = function()
    -- `?debug` — это «поле есть», и терять его нельзя: по нему включают
    -- подробности.
    t.assert_equals(request().parse_query('debug'), { debug = '' })
end

g.test_field_without_a_name_is_dropped = function()
    t.assert_equals(request().parse_query('=7&page=2'), { page = '2' })
end

g.test_repeated_field_becomes_a_list = function()
    t.assert_equals(request().parse_query('tag=a&tag=b&tag=c'), { tag = { 'a', 'b', 'c' } })
end

g.test_plus_is_a_space_in_the_query_string = function()
    t.assert_equals(request().parse_query('name=%D0%98%D0%B2%D0%B0%D0%BD+%D0%9F'), { name = 'Иван П' })
end

g.test_empty_query_string_gives_no_fields = function()
    t.assert_equals(request().parse_query(nil), {})
end

g.test_fields_are_written_back_in_a_settled_order = function()
    -- Порядок задан именами: без него один и тот же набор даёт разные
    -- адреса от запуска к запуску, а по адресам сверяют ответы.
    t.assert_equals(request().build_query({ sort = 'name', page = 2 }), 'page=2&sort=name')
end

g.test_special_characters_are_escaped_on_both_sides_of_the_equals_sign = function()
    t.assert_equals(request().build_query({ ['по ле'] = 'а/б' }), '%D0%BF%D0%BE%20%D0%BB%D0%B5=%D0%B0%2F%D0%B1')
end

g.test_unreserved_characters_are_written_back_as_they_are = function()
    -- Дефис незарезервирован по RFC 3986, плюс — нет: плюс в строке
    -- запроса значит пробел, и уехать неэкранированным он не должен.
    t.assert_equals(request().build_query({ ['a-b'] = 'c-d' }), 'a-b=c-d')
    t.assert_equals(request().build_query({ ['a+b'] = 'c+d' }), 'a%2Bb=c%2Bd')
end

g.test_nothing_to_write_gives_an_empty_string = function()
    t.assert_equals(request().build_query(nil), '')
end

g.test_list_is_written_back_as_the_repeated_name = function()
    -- Список — повторённое имя в порядке списка, как его и разбирают:
    -- собранное обратно разбирается в то же самое.
    local query = { tag = { 'b', 'а' }, page = 2, none = {} }

    t.assert_equals(request().build_query(query), 'page=2&tag=b&tag=%D0%B0')
    t.assert_equals(request().parse_query(request().build_query(query)), { page = '2', tag = { 'b', 'а' } })
end

g.test_address_of_a_request_keeps_the_repeated_names = function()
    local built = request().normalize({ path = '/customers', query = 'tag=a&tag=b', headers = { host = 'node' } })

    t.assert_equals(built.url, 'http://node/customers?tag=a&tag=b')
end

g.test_request_is_a_table_and_nothing_else = function()
    local built, err = request().normalize('GET /customers')

    t.assert_equals(built, nil)
    t.assert_equals(err, 'запрос должен быть таблицей')
end

g.test_method_is_written_in_capitals = function()
    t.assert_equals(request().normalize({ method = 'post', path = '/x' }).method, 'POST')
end

g.test_request_without_a_method_is_a_get = function()
    t.assert_equals(request().normalize({ path = '/x' }).method, 'GET')
end

g.test_path_is_taken_out_of_the_whole_address = function()
    local built = request().normalize({ url = 'https://node:8080/customers/7?page=2' })

    t.assert_equals(built.path, '/customers/7')
    t.assert_equals(built.query, { page = '2' })
end

g.test_scheme_is_cut_off_the_way_rfc_3986_writes_it = function()
    -- Схема по RFC 3986 — буква, а дальше буквы, цифры, «+», «-»
    -- и точка; имя узла бывает и пустым. Всё это отрезается целиком:
    -- маршруты объявлены путями, и адрес, дошедший до дерева со схемой,
    -- не совпал бы ни с одним.
    t.assert_equals(request().normalize({ url = 'a://node/customers' }).path, '/customers')
    t.assert_equals(request().normalize({ url = 'my-scheme://node/customers' }).path, '/customers')
    t.assert_equals(request().normalize({ url = 'http:///customers' }).path, '/customers')
end

g.test_query_string_of_the_path_is_cut_off = function()
    local built = request().normalize({ path = '/customers?page=2#top' })

    t.assert_equals(built.path, '/customers')
    t.assert_equals(built.query, { page = '2' })
end

g.test_path_without_a_leading_slash_gets_one = function()
    t.assert_equals(request().normalize({ path = 'customers/7' }).path, '/customers/7')
end

g.test_address_without_a_path_at_all_is_the_root = function()
    t.assert_equals(request().normalize({ url = 'http://node:8080' }).path, '/')
end

g.test_request_written_without_anything_is_a_get_of_the_root = function()
    local built = request().normalize({})

    t.assert_equals(built.method, 'GET')
    t.assert_equals(built.path, '/')
    t.assert_equals(built.url, 'http://localhost/')
end

g.test_escaped_path_is_not_read_back_before_the_route_is_looked_for = function()
    -- `%2F` раскодируется разбором участков, а не здесь: иначе путь
    -- развалился бы на два участка ещё до поиска маршрута.
    t.assert_equals(request().normalize({ path = '/files/a%2Fb' }).path, '/files/a%2Fb')
end

g.test_header_names_are_lowered = function()
    local built = request().normalize({ path = '/x', headers = { ['Content-Type'] = 'text/plain' } })

    t.assert_equals(built.headers, { ['content-type'] = 'text/plain' })
end

g.test_fields_given_as_a_table_are_taken_as_they_are = function()
    t.assert_equals(request().normalize({ path = '/x', query = { page = 2 } }).query, { page = 2 })
end

g.test_fields_given_as_a_string_are_parsed = function()
    t.assert_equals(request().normalize({ path = '/x', query = 'page=2' }).query, { page = '2' })
end

g.test_address_is_put_together_from_the_host_header = function()
    local built = request().normalize({ path = '/customers', query = 'page=2', headers = { Host = 'node:8080' } })

    t.assert_equals(built.url, 'http://node:8080/customers?page=2')
end

g.test_given_address_is_kept_as_it_came = function()
    local built = request().normalize({ url = 'https://node/customers', path = '/customers' })

    t.assert_equals(built.url, 'https://node/customers')
end

g.test_body_is_carried_over_untouched = function()
    local built = request().normalize({ path = '/x', body = '{"name":"тот"}' })

    t.assert_equals(built.body, '{"name":"тот"}')
    t.assert_equals(built.params, {})
end

g.test_fields_put_there_by_the_application_come_over_as_they_are = function()
    -- Опознанный оператор и адрес клиента кладёт в запрос приложение:
    -- потерять их значит заставить его носить довесок мимо запроса —
    -- хранилищем файбера, которое теряется на первом же обходе.
    local built = request().normalize({
        path = '/x',
        identity = { username = 'admin', readonly = false },
        peer = { host = '10.0.0.7' },
        deployment = 'прод',
    })

    t.assert_equals(built.identity, { username = 'admin', readonly = false })
    t.assert_equals(built.peer, { host = '10.0.0.7' })
    t.assert_equals(built.deployment, 'прод')
end

g.test_own_fields_are_not_taken_from_the_outside = function()
    -- Разобранный путь, параметры маршрута и то, чем запрос обслужен, —
    -- слово роутера: подложить их снаружи нельзя, иначе обработчик
    -- прочитал бы имя маршрута, которого не было.
    local built = request().normalize({
        path = '/customers',
        params = { id = 'подложенный' },
        route = { name = 'подложенный' },
    })

    t.assert_equals(built.params, {})
    t.assert_equals(built.route, nil)
end

--- Пределы тела, какими их ставит `attach` без настроек.
---@return table
local function defaults()
    return request().limits()
end

--- Двойник запроса `http.server` с телом.
---
--- Тело отдаётся так, как отдаёт сервер: не больше заявленного, со сроком,
--- а недошедшее — пустой строкой. Что спросили и сколько раз, запоминается.
---@param fields table Поля запроса
---@param arrived string|nil Что успело прийти от клиента
---@return table incoming
---@return table asked Аргументы каждого чтения
local function incoming_with(fields, arrived)
    local asked = {}
    local incoming = {
        method = 'POST',
        path = '/customers',
        headers = {},
        read = function(_, size, timeout)
            table.insert(asked, { size = size, timeout = timeout })

            return (arrived or ''):sub(1, size)
        end,
    }

    for name, value in pairs(fields) do
        incoming[name] = value
    end

    return incoming, asked
end

g.test_server_request_comes_over_with_its_raw_path = function()
    local incoming, asked = incoming_with({
        path = '/files/a/b',
        path_raw = '/files/a%2Fb',
        query = 'page=2',
        headers = { host = 'node', ['content-length'] = '8' },
        peer = { host = '10.0.0.7', port = 51234 },
    }, 'тело')

    local built = request().from_server(incoming, defaults())

    t.assert_equals(built, {
        method = 'POST',
        path = '/files/a%2Fb',
        query = 'page=2',
        headers = { host = 'node', ['content-length'] = '8' },
        peer = { host = '10.0.0.7', port = 51234 },
        body = 'тело',
    })
    -- Читается ровно заявленное и со сроком: без срока капельный клиент
    -- держал бы файбер бессрочно.
    t.assert_equals(asked, { { size = 8, timeout = 60 } })
    t.assert_equals(incoming.broken, nil)
end

g.test_address_of_the_client_comes_over_from_the_server = function()
    -- По адресу клиента считают неудачные попытки входа и пишут аудит,
    -- а знает его один сервер: дальше по цепочке взять его неоткуда.
    local built = request().from_server({
        method = 'POST',
        path = '/login',
        headers = {},
        peer = { host = '10.0.0.7', port = 51234 },
    }, defaults())

    t.assert_equals(built.peer, { host = '10.0.0.7', port = 51234 })
    t.assert_equals(request().normalize(built).peer, { host = '10.0.0.7', port = 51234 })
end

g.test_server_request_without_a_raw_path_falls_back_to_the_read_one = function()
    -- Своё поле есть не у всякого двойника, а промах здесь стоил бы
    -- пустого пути и 404 на всё подряд. Без `Content-Length` тела нет,
    -- и читать нечего: так же отвечает и сам сервер.
    local built = request().from_server({ method = 'GET', path = '/customers', headers = {} }, defaults())

    t.assert_equals(built.path, '/customers')
    t.assert_equals(built.body, '')
end

g.test_limits_have_their_defaults = function()
    t.assert_equals(defaults(), {
        max_body = 1024 * 1024,
        body_timeout = 60,
        max_fields = 256,
        max_parts = 64,
        max_field_size = 256 * 1024,
        max_files = 16,
        -- Предел файла по умолчанию — предел всего тела: два числа вместо
        -- одного пришлось бы поднимать вдвоём.
        max_file_size = 1024 * 1024,
        in_memory = 64 * 1024,
    })

    -- Заданное возвращается как заданное: сравнивать есть с чем одной
    -- таблицей, потому что `limits` отдаёт ровно эти имена и ничего сверх.
    local asked = {
        max_body = 1,
        body_timeout = 0.5,
        max_fields = 2,
        max_parts = 3,
        max_field_size = 4,
        max_files = 5,
        max_file_size = 6,
        in_memory = 7,
        temp_dir = '/var/tmp',
    }

    t.assert_equals(request().limits(asked), asked)
end

g.test_wrong_form_limits_fail_where_they_are_written = function()
    local named = {
        max_fields = 'полей',
        max_parts = 'частей',
        max_field_size = 'байт',
        max_files = 'файлов',
        in_memory = 'байт',
        max_file_size = 'байт',
    }

    for name, what in pairs(named) do
        for _, wrong in ipairs({ 0, -1, 1.5, '10' }) do
            t.assert_error_msg_content_equals(
                ('настройка «%s» должна быть целым числом %s больше нуля, а не %s'):format(
                    name,
                    what,
                    wrong
                ),
                request().limits,
                { [name] = wrong }
            )
        end
    end

    t.assert_error_msg_content_equals(
        'настройка «temp_dir» должна быть строкой, а не number',
        request().limits,
        { temp_dir = 7 }
    )
end

g.test_wrong_limits_blame_the_one_who_asked_for_them = function()
    -- Пределы разбирает и тот, кто читает тело сам, без роутера: отказ
    -- винит его строку, а не разбор внутри пакета, — у всех пределов одну.
    local limits = request().limits

    helper.assert_blamed({
        {
            function()
                limits({ max_parts = 0 })
            end,
            'настройка «max_parts» должна быть целым числом частей больше нуля, а не 0',
        },
        {
            function()
                limits({ body_timeout = -1 })
            end,
            'настройка «body_timeout» должна быть конечным числом секунд больше нуля, а не -1',
        },
        {
            function()
                limits({ temp_dir = true })
            end,
            'настройка «temp_dir» должна быть строкой, а не boolean',
        },
    })
end

g.test_wrong_limits_fail_where_they_are_written = function()
    -- Ноль отказал бы всякому телу, дробь — непонятно чему, а бесконечный
    -- срок вернул бы ту дыру, ради которой срок и заведён.
    for _, max_body in ipairs({ 0, -1, 1.5, '10' }) do
        t.assert_error_msg_content_equals(
            ('настройка «max_body» должна быть целым числом байт больше нуля, а не %s'):format(
                max_body
            ),
            request().limits,
            { max_body = max_body }
        )
    end

    for _, body_timeout in ipairs({ 0, -1, 0 / 0, math.huge, '5' }) do
        t.assert_error_msg_content_equals(
            ('настройка «body_timeout» должна быть конечным числом секунд больше нуля, а не %s'):format(
                tostring(body_timeout)
            ),
            request().limits,
            { body_timeout = body_timeout }
        )
    end
end

--- Отказ `from_server` целиком: пустота, отказ и голова запроса.
---@param incoming table
---@param limits table|nil
---@return table
local function refused(incoming, limits)
    local built, failure, head = request().from_server(incoming, limits or defaults())

    t.assert_equals(built, nil)

    return { failure = failure, head = head }
end

g.test_body_over_the_limit_is_refused_before_it_is_read = function()
    local incoming, asked = incoming_with({ headers = { ['content-length'] = '11' } }, ('x'):rep(11))
    local result = refused(incoming, request().limits({ max_body = 10 }))

    t.assert_equals(
        result.failure,
        { status = 413, reason = 'тело в 11 байт больше предела в 10' }
    )
    t.assert_equals(asked, {})
    -- Остаток сервер не дочитывает, а соединение закрывает: иначе он сам
    -- прочёл бы заявленное одной строкой, а недочитанное тело разобрал бы
    -- следующим запросом.
    t.assert_equals(incoming.broken, true)
    t.assert_equals(incoming._remaining, 0)
    -- Голова уходит в журнал отказа: без неё не сказать, куда шли.
    t.assert_equals(result.head, {
        method = 'POST',
        path = '/customers',
        headers = { ['content-length'] = '11' },
    })
end

g.test_body_exactly_at_the_limit_is_taken = function()
    local incoming = incoming_with({ headers = { ['content-length'] = '10' } }, ('x'):rep(10))
    local built = request().from_server(incoming, request().limits({ max_body = 10 }))

    t.assert_equals(built.body, ('x'):rep(10))
end

g.test_enormous_length_is_refused_as_too_large = function()
    local incoming = incoming_with({ headers = { ['content-length'] = ('9'):rep(400) } })

    -- Длина в подробности обрезана так же, как негодная: она уходит в журнал.
    t.assert_equals(refused(incoming).failure, {
        status = 413,
        reason = ('тело в %s байт больше предела в 1048576'):format(('9'):rep(32)),
    })
end

g.test_length_that_is_not_plain_digits_is_a_broken_request = function()
    -- Сервер читает длину `tonumber`, а он понимает и «0x10», и «1e3»:
    -- прокси перед узлом прочтёт их иначе.
    for _, declared in ipairs({ '0x10', '1e3', ' 7', '7 ', '-1', '', '5, 5' }) do
        local incoming, asked = incoming_with({ headers = { ['content-length'] = declared } }, 'x')
        local result = refused(incoming)

        t.assert_equals(result.failure, {
            status = 400,
            reason = ('Content-Length не число байт: %q'):format(declared),
        })
        t.assert_equals(asked, {})
        t.assert_equals(incoming.broken, true)
    end
end

g.test_broken_length_is_journaled_cut_short = function()
    local incoming = incoming_with({ headers = { ['content-length'] = ('я'):rep(20) .. 'хвост' } })

    t.assert_equals(
        refused(incoming).failure.reason,
        ('Content-Length не число байт: %q'):format(('я'):rep(16))
    )
end

g.test_body_in_pieces_without_a_length_is_refused = function()
    -- Сервер тело кусками не читает, и оно ушло бы в разбор следующим
    -- запросом.
    local incoming, asked = incoming_with({
        headers = { ['transfer-encoding'] = 'chunked', ['content-length'] = '3' },
    }, 'abc')
    local result = refused(incoming)

    t.assert_equals(
        result.failure,
        { status = 411, reason = 'тело кусками без Content-Length не принимается' }
    )
    t.assert_equals(asked, {})
    t.assert_equals(incoming.broken, true)
    t.assert_equals(incoming._remaining, 0)
end

g.test_body_that_did_not_arrive_in_time_is_refused = function()
    local incoming, asked = incoming_with({ headers = { ['content-length'] = '5' } }, 'abc')
    local result = refused(incoming, request().limits({ body_timeout = 0.25 }))

    t.assert_equals(
        result.failure,
        { status = 408, reason = 'тело пришло не целиком за 0.25 с: 3 байт из 5' }
    )
    t.assert_equals(asked, { { size = 5, timeout = 0.25 } })
    t.assert_equals(incoming.broken, true)
end

g.test_empty_body_is_read_as_empty = function()
    local incoming = incoming_with({ headers = { ['content-length'] = '0' } })

    t.assert_equals(request().from_server(incoming, defaults()).body, '')
    t.assert_equals(incoming.broken, nil)
end

--- Соединение, отдающее тело кусками: так его отдаёт настоящий сокет.
---@param fields table Поля запроса поверх обычных
---@param arrived string Тело целиком
---@param piece integer|nil По сколько байт отдавать за раз
---@return table incoming
---@return table asked Что и с каким сроком спрашивали
local function streaming_with(fields, arrived, piece)
    local asked = {}
    local taken = 0
    local incoming = {
        method = 'POST',
        path = '/customers',
        headers = { ['content-length'] = tostring(#arrived) },
        read = function(_, size, timeout)
            table.insert(asked, { size = size, timeout = timeout })

            local want = math.min(size, piece or size)
            local part = arrived:sub(taken + 1, taken + want --[[@as integer]])

            taken = taken + #part

            return part
        end,
    }

    for name, value in pairs(fields) do
        incoming[name] = value
    end

    return incoming, asked
end

--- Метка границы для проверок многочастного тела.
local BOUNDARY = 'ГРАНИЦА-42'

--- Заголовок многочастного тела.
local MULTIPART = 'multipart/form-data; boundary=' .. BOUNDARY

g.test_multipart_body_is_parsed_out_of_the_connection_in_pieces = function()
    local body = helper.multipart(BOUNDARY, {
        { name = 'title', body = 'отчёт' },
        { name = 'avatar', filename = 'кот.png', type = 'image/png', body = 'PNG-данные' },
    })

    local incoming, asked = streaming_with({
        headers = { ['content-type'] = MULTIPART, ['content-length'] = tostring(#body) },
    }, body, 16)

    local built, failure = request().from_server(incoming, defaults())

    t.assert_equals(failure, nil)
    -- Тело обработчику не достаётся: оно уже разобрано, и второй его
    -- копии в памяти нет.
    t.assert_equals(built.body, '')
    t.assert_equals(built.form, { title = 'отчёт' })
    t.assert_equals(built.files.avatar.client_name, 'кот.png')
    t.assert_equals(built.files.avatar:read(), 'PNG-данные')
    -- Спрашивали кусками, а не всё тело одной строкой.
    t.assert_gt(#asked, 1)
    t.assert_equals(asked[1].size, math.min(64 * 1024, #body))
    t.assert_equals(incoming.broken, nil)
end

g.test_broken_multipart_body_closes_the_connection = function()
    local incoming = streaming_with({
        headers = { ['content-type'] = MULTIPART, ['content-length'] = '11' },
    }, 'тело без гр')

    local built, failure, head = request().from_server(incoming, defaults())

    t.assert_equals(built, nil)
    t.assert_equals(failure, { status = 400, reason = 'границы нет в теле вовсе' })
    -- Недочитанное тело сервер не дочитывает, а соединение закрывает:
    -- остаток иначе разобрался бы следующим запросом.
    t.assert_equals(incoming.broken, true)
    t.assert_equals(incoming._remaining, 0)
    t.assert_equals(head.method, 'POST')
end

g.test_multipart_body_over_the_limit_is_refused_before_it_is_read = function()
    local incoming, asked = streaming_with({
        headers = { ['content-type'] = MULTIPART, ['content-length'] = '11' },
    }, ('x'):rep(11))

    local _, failure = request().from_server(incoming, request().limits({ max_body = 10 }))

    t.assert_equals(failure.status, 413)
    t.assert_equals(asked, {})
end

g.test_reader_gives_the_body_in_pieces_and_stops_at_its_length = function()
    -- Длина нечётная нарочно: последним куском остаётся один байт,
    -- и он обязан доехать.
    local incoming, asked = streaming_with({}, 'abcde', 2)
    local read = request().reader(incoming, 5, 5)
    local taken = {}

    for _ = 1, 4 do
        table.insert(taken, (read()))
    end

    t.assert_equals(table.concat(taken), 'abcde')
    -- Больше заявленного у соединения не просят: остаток принадлежит
    -- следующему запросу.
    t.assert_equals(#asked, 3)
    t.assert_equals(asked[3].size, 1)
    t.assert_equals(taken[4], '')
end

g.test_reader_stops_even_when_the_connection_gave_more_than_asked = function()
    -- Соединение отдало больше, чем просили: остаток чужой, и просить
    -- дальше нечего — иначе читатель не кончил бы тело никогда.
    local incoming = {
        read = function()
            return 'больше, чем просили'
        end,
    }

    local read = request().reader(incoming, 3, 5)

    t.assert_equals(read(), 'больше, чем просили')
    t.assert_equals(read(), '')
end

g.test_reader_asks_the_connection_by_pieces_of_a_settled_size = function()
    -- Кусок — шестьдесят четыре килобайта: это и обычный размер куска
    -- ответа, и потолок памяти на один разбираемый запрос.
    local body = string.rep('x', 70 * 1024)
    local incoming, asked = streaming_with({}, body)
    local read = request().reader(incoming, #body, 5)

    t.assert_equals(#read(), 64 * 1024)
    t.assert_equals(#read(), 70 * 1024 - 64 * 1024)
    t.assert_equals(read(), '')
    -- Срок у каждого куска свой — остаток от общего, — а размер задан
    -- куском чтения.
    t.assert_equals({ asked[1].size, asked[2].size }, { 64 * 1024, 70 * 1024 - 64 * 1024 })
    t.assert_equals(#asked, 2)
end

g.test_reader_refuses_the_body_that_was_cut = function()
    local incoming = streaming_with({}, 'аб')
    local read = request().reader(incoming, 10, 5)

    t.assert_equals(read(), 'аб')

    local part, failure = read()

    t.assert_equals(part, nil)
    t.assert_equals(
        failure,
        { status = 408, reason = 'тело пришло не целиком за 5 с: 4 байт из 10' }
    )
end

g.test_reader_refuses_the_body_at_the_very_deadline = function()
    -- Срок вышел ровно в миг вызова: остатка нет, и просить у соединения
    -- нечего — сокет с нулевым сроком всё равно вернул бы пустоту.
    request()._set_source({
        monotonic = function()
            return 1000
        end,

        scheduler_now = function()
            return 1005
        end,
    })

    local read = request().reader(streaming_with({}, 'абв'), 10, 5)
    local part, failure = read()

    t.assert_equals(part, nil)
    t.assert_equals(
        failure,
        { status = 408, reason = 'тело пришло не целиком за 5 с: 0 байт из 10' }
    )
end

g.test_reader_refuses_the_body_that_did_not_fit_the_deadline = function()
    -- Часы — двойник, и двигает их только ожидание соединения. На настоящих
    -- соединение спало дольше срока, и всё же под нагрузкой второй кусок
    -- просился: миг срока отмечается настоящими часами, а сон отсчитывается
    -- от отметки цикла, которая отстаёт на всю работу без уступки перед
    -- проверкой — загрузку исходников пакета, — и сон кончался раньше срока.
    -- Читатель при этом прав: время на тело ещё было. Двойник задаёт
    -- отставание сам.
    local clock = helper.clock({ lag = 0.25 })
    local asked = {}

    request()._set_source({ monotonic = clock.monotonic, scheduler_now = clock.scheduler_now })

    local incoming = {
        -- Медленный клиент: сокет выжидает дольше данного ему остатка и
        -- отдаёт единственный байт, успевший прийти. Сон — уступка: часы
        -- уходят на секунду, отметка их догоняет, и остаток следующего
        -- чтения уже меньше нуля. Нулевой остаток — отдельная проверка выше;
        -- здесь отказ обязан быть и после срока.
        read = function(_, size, rest)
            table.insert(asked, { size = size, rest = rest })
            clock.sleep(1)

            return 'x'
        end,
    }

    -- Доли секунды — степени двойки: сумма с отсчётом часов двойника
    -- должна быть точной в двоичной записи, иначе остаток не сравнить
    -- равенством.
    local read = request().reader(incoming, 10, 0.5)

    t.assert_equals(read(), 'x')

    local part, failure = read()

    t.assert_equals(part, nil)
    t.assert_equals(
        failure,
        { status = 408, reason = 'тело пришло не целиком за 0.5 с: 1 байт из 10' }
    )
    -- Остаток первого куска — от отметки цикла: срок плюс её отставание.
    -- Второго куска у соединения не просили — срок вышел раньше.
    t.assert_equals(asked, { { size = 10, rest = 0.75 } })
end

g.test_form_of_the_body_is_parsed_into_the_request = function()
    local built = request().normalize({
        method = 'POST',
        path = '/customers',
        headers = { ['Content-Type'] = 'application/x-www-form-urlencoded' },
        body = 'name=Иван&tag=a&tag=b',
    })

    t.assert_equals(built.form, { name = 'Иван', tag = { 'a', 'b' } })
    t.assert_equals(built.files, {})
    t.assert_equals(built.refusal, nil)
    -- Тело остаётся телом: разбор его не съедает.
    t.assert_equals(built.body, 'name=Иван&tag=a&tag=b')
end

g.test_request_without_a_form_still_has_one = function()
    local built = request().normalize({ method = 'GET', path = '/customers' })

    t.assert_equals(built.form, {})
    t.assert_equals(built.files, {})
end

g.test_broken_form_becomes_a_refusal_of_the_request = function()
    local built = request().normalize({
        method = 'POST',
        path = '/customers',
        headers = { ['content-type'] = 'multipart/form-data' },
        body = 'что угодно',
    })

    t.assert_equals(built.refusal, {
        status = 400,
        reason = 'в multipart/form-data нет метки границы',
    })
end

g.test_form_limits_of_the_request_are_the_defaults_without_others = function()
    local many = {}

    for index = 1, 300 do
        table.insert(many, ('n%d=%d'):format(index, index))
    end

    -- Умолчание — 256 полей, и оно действует и без явных пределов.
    local built = request().normalize({
        method = 'POST',
        headers = { ['content-type'] = 'application/x-www-form-urlencoded' },
        body = table.concat(many, '&'),
    })

    t.assert_equals(
        built.refusal,
        { status = 413, reason = 'полей в форме больше предела в 256' }
    )
end

g.test_body_of_reads_the_whole_body_for_those_who_serve_without_the_router = function()
    -- `body_of` берут те, кто обслуживает `http.server` своими маршрутами:
    -- тело надо читать первым делом и в пределах, иначе сервер дочитает
    -- заявленное сам — одной строкой и без срока.
    local incoming, asked = incoming_with({ headers = { ['content-length'] = '8' } }, 'тело')

    t.assert_equals(request().body_of(incoming, defaults()), 'тело')
    t.assert_equals(asked, { { size = 8, timeout = 60 } })

    local body, failure = request().body_of(
        incoming_with({ headers = { ['content-length'] = '11' } }, ('x'):rep(11)),
        request().limits({ max_body = 10 })
    )

    t.assert_equals(body, nil)
    t.assert_equals(failure, { status = 413, reason = 'тело в 11 байт больше предела в 10' })
end

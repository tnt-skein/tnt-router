--- Тесты ответа, который забирает соединение: смена протокола.

local t = require('luatest')

local http_server = require('http.server')
local socket = require('socket')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.takeover')

--- Модуль захвата соединения.
---@return any
local function takeover()
    return helper.part('tnt.router.takeover')
end

--- Двойник сокета сервера: помнит записанное, отказывает по просьбе.
---@param broken string|nil Текст ошибки, с которой запись не удаётся
---@return table
local function wire(broken)
    local double = { written = {} }

    function double.write(_, data)
        if broken ~= nil then
            return nil
        end

        table.insert(double.written, data)

        return #data
    end

    function double.error()
        return broken
    end

    return double
end

g.test_head_names_the_status_and_lists_headers_in_order = function()
    local head = takeover().head_of({
        status = 101,
        headers = { upgrade = 'websocket', connection = 'Upgrade', ['sec-websocket-accept'] = 'abc=' },
    })

    t.assert_equals(
        head,
        'HTTP/1.1 101 Switching Protocols\r\n'
            .. 'connection: Upgrade\r\n'
            .. 'sec-websocket-accept: abc=\r\n'
            .. 'upgrade: websocket\r\n'
            .. '\r\n'
    )
end

g.test_list_value_becomes_one_line_per_item = function()
    local head = takeover().head_of({ status = 101, headers = { ['set-cookie'] = { 'a=1', 'b=2' } } })

    t.assert_equals(head, 'HTTP/1.1 101 Switching Protocols\r\nset-cookie: a=1\r\nset-cookie: b=2\r\n\r\n')
end

g.test_unknown_status_has_an_empty_word_and_no_headers_are_fine = function()
    t.assert_equals(takeover().head_of({ status = 599 }), 'HTTP/1.1 599 \r\n\r\n')
end

g.test_ordinary_answer_goes_to_the_server_untouched = function()
    local answer = { status = 200, headers = {}, body = 'готово' }

    t.assert_is(takeover().served({ s = wire() }, answer), answer)
end

g.test_taken_connection_gets_the_head_and_the_socket = function()
    local double = wire()
    local given
    local result = takeover().served({ s = double }, {
        status = 101,
        headers = { upgrade = 'websocket' },
        takeover = function(connection)
            given = connection
        end,
    })

    t.assert_equals(result, http_server.DETACHED)
    t.assert_equals(takeover().DETACHED, 101)
    t.assert_is(given, double)
    t.assert_equals(double.written, { 'HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\n\r\n' })
end

g.test_client_gone_before_the_head_is_not_taken_over = function()
    local journal = helper.capture_log()
    local called = false

    journal.forget()

    local result = takeover().served({ s = wire('Broken pipe'), path = '/ws' }, {
        status = 101,
        takeover = function()
            called = true
        end,
    })

    t.assert_equals(result, http_server.DETACHED)
    t.assert_equals(called, false)

    local found = journal.find('WARN [tnt.router] клиент ушёл до смены протокола')

    t.assert_not_equals(found, nil)
    t.assert_equals(found.record.fields, { path = '/ws', reason = 'Broken pipe' })
    journal.release()
end

g.test_failed_takeover_ends_the_connection_and_leaves_a_record = function()
    local journal = helper.capture_log()

    journal.forget()

    local result = takeover().served({ s = wire(), path = '/ws' }, {
        status = 101,
        takeover = function()
            error('кадр не разобран', 0)
        end,
    })

    t.assert_equals(result, http_server.DETACHED)

    local found = journal.find(
        'ERROR [tnt.router] соединение после смены протокола кончилось отказом'
    )

    t.assert_not_equals(found, nil)
    t.assert_equals(found.record.fields, { path = '/ws', reason = 'кадр не разобран' })
    journal.release()
end

g.test_real_server_hands_the_connection_over_after_the_head = function()
    -- Сервер сам не пишет ни Content-Length, ни своё имя, ни Connection:
    -- голова уходит та, что в ответе, а дальше говорит `takeover`.
    g.router.get('/echo', function()
        return {
            status = 101,
            headers = { upgrade = 'echo', connection = 'Upgrade' },
            takeover = function(connection)
                connection:write('эхо:' .. connection:read(4, 5))
            end,
        }
    end)

    local httpd = http_server.new('127.0.0.1', 0, { log_requests = false, log_errors = false, idle_timeout = 5 })

    g.router.attach(httpd)
    httpd:start()

    local client = socket.tcp_connect('127.0.0.1', httpd.tcp_server:name().port)

    client:write('GET /echo HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: echo\r\n\r\n')

    local head = client:read({ delimiter = '\r\n\r\n' }, 5)

    client:write('ping')

    local rest = {}

    while true do
        local part = client:read(4096, 5)

        if part == nil or part == '' then
            break
        end

        table.insert(rest, part)
    end

    client:close()
    httpd:stop()

    t.assert_equals(head, 'HTTP/1.1 101 Switching Protocols\r\nconnection: Upgrade\r\nupgrade: echo\r\n\r\n')
    t.assert_equals(table.concat(rest), 'эхо:ping')
end

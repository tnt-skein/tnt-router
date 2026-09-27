--- Ряды границы HTTP: каждый ответ роутера считается по способу,
--- шаблону маршрута и коду и меряется длительностью.
---
--- Исходники пакета и рядов грузятся заново на каждую проверку, поэтому
--- счёт у каждой свой и сверяется точным числом.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.series')

--- Сколько ответов с такими метками насчитал ряд запросов.
---@param method string
---@param route string
---@param code string
---@return number|nil
local function answered(method, route, code)
    return helper.value('http_requests_total', { method = method, route = route, code = code })
end

g.test_answers_are_counted_by_method_route_and_code = function()
    local r = g.router.new()

    r.get('/customers/:id<int>', helper.answering('клиент'))
    r.post('/customers', helper.answering('создан', 201))
    r.dispatch(helper.request('GET', '/customers/7'))
    r.dispatch(helper.request('GET', '/customers/8'))
    r.dispatch(helper.request('POST', '/customers'))
    r.dispatch(helper.request('HEAD', '/customers/9'))

    t.assert_equals(
        answered('GET', '/customers/:id<int>', '200'),
        2,
        'путь с опознавателем идёт шаблоном'
    )
    t.assert_equals(answered('POST', '/customers', '201'), 1)
    t.assert_equals(answered('HEAD', '/customers/:id<int>', '200'), 1, 'HEAD обслужен маршрутом GET')
end

g.test_a_request_without_a_route_goes_as_unmatched = function()
    local r = g.router.new()

    r.get('/customers', helper.answering('список'))
    r.dispatch(helper.request('GET', '/wp-login.php'))
    r.dispatch(helper.request('GET', '/.env'))
    r.dispatch(helper.request('DELETE', '/customers'))

    t.assert_equals(answered('GET', '_unmatched', '404'), 2, 'путь сканера в метку не идёт')
    t.assert_equals(answered('DELETE', '_unmatched', '405'), 1)
end

g.test_an_unknown_method_goes_as_other = function()
    local r = g.router.new()

    r.any('/health', helper.answering('живой'))
    r.dispatch(helper.request('BREW', '/health'))

    t.assert_equals(answered('_other', '/health', '200'), 1)
end

g.test_a_response_without_a_status_is_counted_as_200 = function()
    local r = g.router.new()

    r.get('/bare', function()
        return { body = 'без статуса' }
    end)
    r.dispatch(helper.request('GET', '/bare'))

    t.assert_equals(answered('GET', '/bare', '200'), 1)
end

g.test_a_broken_handler_and_a_broken_entry_are_counted_as_500 = function()
    local r = g.router.new({
        entry = {
            function(request, nxt)
                if request.path == '/closed' then
                    error('слой входа упал')
                end

                return nxt(request)
            end,
        },
    })

    r.get('/broken', function()
        error('обработчик упал')
    end)
    r.dispatch(helper.request('GET', '/broken'))
    r.dispatch(helper.request('GET', '/closed'))

    t.assert_equals(answered('GET', '/broken', '500'), 1)
    t.assert_equals(
        answered('GET', '_unmatched', '500'),
        1,
        'до маршрута слой входа не дошёл'
    )
end

g.test_the_duration_runs_from_the_request_to_the_ready_answer = function()
    local series = helper.part('tnt.router.series')
    local moments = { 10, 10.5, 20, 20.25 }
    local r = g.router.new()

    series._set_source({
        monotonic = function()
            return table.remove(moments, 1)
        end,
    })

    r.get('/slow', helper.answering('медленно'))
    r.dispatch(helper.request('GET', '/slow'))
    r.dispatch(helper.request('GET', '/slow'))
    series._set_source(nil)

    local labels = { method = 'GET', route = '/slow' }

    t.assert_equals(helper.value('http_request_duration_seconds_count', labels), 2)
    t.assert_equals(helper.value('http_request_duration_seconds_sum', labels), 0.75)
    t.assert_equals(
        helper.value('http_request_duration_seconds_bucket', { method = 'GET', route = '/slow', le = 0.5 }),
        2
    )
    t.assert_equals(
        helper.value('http_request_duration_seconds_bucket', { method = 'GET', route = '/slow', le = 0.25 }),
        1
    )
end

g.test_the_bounds_of_the_labels = function()
    local series = helper.part('tnt.router.series')

    t.assert_equals(series.ROUTES, 500)
    t.assert_equals(series.CODES, 60)
    t.assert_equals(series.METHODS, { 'GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS' })
end

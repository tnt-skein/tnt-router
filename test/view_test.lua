--- Тесты помощников страниц: страница, её кусок и страница потоком.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.view')

--- Тип содержимого всех трёх помощников.
local HTML = 'text/html; charset=utf-8'

--- Движок-двойник: что просили, то и отдаёт, и помнит, о чём просили.
---@return table engine
local function engine()
    local asked = {}

    return {
        asked = asked,
        render = function(_, name, data)
            table.insert(asked, { 'render', name, data })

            return '<html>' .. name .. '</html>'
        end,
        fragment = function(_, name, section, data)
            table.insert(asked, { 'fragment', name, section, data })

            return '<tr>' .. section .. '</tr>'
        end,
        stream = function(_, name, data)
            table.insert(asked, { 'stream', name, data })

            local pieces = { '<head>', '', '<body>' }
            local index = 0

            return function()
                index = index + 1

                return pieces[index]
            end
        end,
    }
end

g.test_a_fragment_is_the_section_answered_as_a_page = function()
    local views = engine()
    local web = g.router.new({ view = views })
    local data = { q = 'мар' }

    web.get('/customers', function(request)
        -- Кусок выбирает обработчик, по заголовку, — и называет его в vary.
        if request.headers['x-fragment'] == 'rows' then
            return web.fragment('customers.index', 'rows', data, nil, { Vary = 'x-fragment' })
        end

        return web.view('customers.index', data, nil, { vary = 'x-fragment' })
    end)

    local piece = web.dispatch(helper.request('GET', '/customers', { headers = { ['x-fragment'] = 'rows' } }))
    local page = web.dispatch(helper.request('GET', '/customers'))

    t.assert_equals(piece, {
        status = 200,
        headers = { ['content-type'] = HTML, vary = 'x-fragment' },
        body = '<tr>rows</tr>',
    })
    t.assert_equals(page.body, '<html>customers.index</html>')
    t.assert_equals(page.headers, piece.headers, 'тип и vary у обоих видов одни')
    t.assert_equals(views.asked, {
        { 'fragment', 'customers.index', 'rows', data },
        { 'render', 'customers.index', data },
    })
    t.assert_equals(web:fragment('customers.index', 'rows', nil, 206).status, 206)
end

g.test_a_page_stream_goes_in_pieces_as_a_page = function()
    local views = engine()
    local web = g.router.new({ view = views })
    local sent = web.view_stream('reports.year', { year = 2026 }, 201, { ['X-Accel-Buffering'] = 'no' })

    t.assert_equals(sent.status, 201)
    t.assert_equals(sent.headers, { ['content-type'] = HTML, ['x-accel-buffering'] = 'no' })
    t.assert_equals(helper.drained(sent), { '<head>', '<body>' })
    t.assert_equals(views.asked, { { 'stream', 'reports.year', { year = 2026 } } })
    t.assert_equals(g.router.new({ view = engine() }):view_stream('reports.year').status, 200)
end

g.test_a_stream_of_bytes_keeps_its_own_type = function()
    -- Поток страницы назван страницей, а поток выгрузки остаётся потоком
    -- байтов: договор о типе — у помощника, а не у ответа по кускам.
    local response = helper.part('tnt.router.response')
    local page = response.html_stream(function() end, nil, { ['Content-Type'] = 'text/html; charset=koi8-r' })

    t.assert_equals(page.headers['content-type'], 'text/html; charset=koi8-r')
    t.assert_equals(response.stream(function() end).headers['content-type'], 'application/octet-stream')
    t.assert_error_msg_contains(
        'потоку ответа нужна функция, отдающая куски, а не nil',
        response.html_stream
    )
end

g.test_a_helper_the_engine_cannot_serve_refuses_naming_what_is_missing = function()
    local plain = g.router.new({
        view = {
            render = function()
                return '<p>'
            end,
        },
    })

    t.assert_equals(plain.view('about').body, '<p>')
    t.assert_error_msg_equals('движок страниц не умеет fragment', plain.fragment, 'about', 'rows')
    t.assert_error_msg_equals('движок страниц не умеет stream', plain.view_stream, 'about')
    t.assert_error_msg_equals(
        'движок страниц не умеет render',
        g.router.new({ view = {} }).view,
        'about'
    )

    for _, method in ipairs({ 'view', 'fragment', 'view_stream' }) do
        t.assert_error_msg_equals(
            'страницы не настроены: нужен view в router.new',
            g.router.new()[method],
            'about'
        )
    end
end

-- ── Общие данные страниц: view_data ──────────────────────────────────

--- Роутер с общими данными страниц над движком-двойником.
---
--- Общие данные — токен из запроса и одно поле, которое страница вправе
--- перебить; каждый вызов `view_data` помнится вместе с запросом.
---@param opts table|nil Настройки роутера поверх обычных
---@return table web
---@return table views Движок-двойник
---@return table[] seen Запросы, с которыми звали view_data
local function shared_router(opts)
    local views = engine()
    local seen = {}
    local settings = {
        view = views,
        view_data = function(request)
            table.insert(seen, request)

            return { csrf_token = request.token, title = 'общий' }
        end,
    }

    for name, value in pairs(opts or {}) do
        settings[name] = value
    end

    return g.router.new(settings), views, seen
end

g.test_shared_data_reach_every_page_without_the_handler_naming_them = function()
    local web, views = shared_router()

    -- Два обработчика рисуют форму и не кладут токен руками, третий
    -- кладёт своё значение — и оно перебивает подмешанное.
    web.get('/customers/new', function()
        return web.view('customers.form', { name = 'Мария' })
    end)
    web.get('/orders/new', function()
        return web.view('orders.form')
    end)
    web.get('/preview', function()
        return web.view('customers.form', { csrf_token = 'своё', title = 'свой' })
    end)

    local first = web.dispatch(helper.request('GET', '/customers/new', { token = 'T1' }))
    local second = web.dispatch(helper.request('GET', '/orders/new', { token = 'T2' }))
    local own = web.dispatch(helper.request('GET', '/preview', { token = 'T3' }))

    t.assert_equals({ first.status, second.status, own.status }, { 200, 200, 200 })
    t.assert_equals(views.asked, {
        { 'render', 'customers.form', { csrf_token = 'T1', title = 'общий', name = 'Мария' } },
        { 'render', 'orders.form', { csrf_token = 'T2', title = 'общий' } },
        { 'render', 'customers.form', { csrf_token = 'своё', title = 'свой' } },
    })
    t.assert_equals(web.status().view_data, true)
end

g.test_a_fragment_and_a_page_stream_get_the_shared_data_too = function()
    local web, views = shared_router()
    local sent = {}

    web.get('/customers', function()
        sent.fragment = web.fragment('customers.index', 'rows', { q = 'мар' })

        return web.view_stream('customers.index')
    end)

    local streamed = web.dispatch(helper.request('GET', '/customers', { token = 'T' }))

    t.assert_equals(sent.fragment.body, '<tr>rows</tr>')
    t.assert_equals(helper.drained(streamed), { '<head>', '<body>' })
    t.assert_equals(views.asked, {
        { 'fragment', 'customers.index', 'rows', { csrf_token = 'T', title = 'общий', q = 'мар' } },
        { 'stream', 'customers.index', { csrf_token = 'T', title = 'общий' } },
    })
end

g.test_view_data_gets_the_very_request_the_handler_answers = function()
    local web, _, seen = shared_router()
    local handled = {}

    web.get('/customers', function(request)
        table.insert(handled, request)

        return web.view('customers.index')
    end)

    web.dispatch(helper.request('GET', '/customers', { token = 'T' }))

    t.assert_equals(#seen, 1)
    t.assert_is(seen[1], handled[1])
end

g.test_neither_the_handler_data_nor_the_shared_table_are_touched = function()
    -- Обработчик вправе отдавать одну и ту же таблицу на каждый запрос,
    -- а view_data — одну и ту же таблицу на каждую страницу: токен,
    -- дописанный в любую из них, уехал бы в страницу другому посетителю.
    local views = engine()
    local constant = { title = 'общий' }
    local names = { names = { 'Мария' } }
    local web = g.router.new({
        view = views,
        view_data = function()
            return constant
        end,
    })

    web.get('/customers', function()
        return web.view('customers.index', names)
    end)

    web.dispatch(helper.request('GET', '/customers'))

    t.assert_equals(constant, { title = 'общий' })
    t.assert_equals(names, { names = { 'Мария' } })
    t.assert_equals(views.asked[1][3], { title = 'общий', names = { 'Мария' } })
end

g.test_outside_an_answer_there_is_nothing_to_mix_in = function()
    -- Помощник, позванный не из ответа на запрос, — из проверки или после
    -- ответа, — запроса не видит, и данные идут как есть.
    local web, views, seen = shared_router()
    local data = { name = 'Мария' }

    web.get('/customers', function()
        return web.view('customers.index')
    end)

    web.dispatch(helper.request('GET', '/customers', { token = 'T' }))
    web.view('customers.form', data)

    t.assert_equals(#seen, 1, 'после ответа запрос в файбере не остался')
    t.assert_is(views.asked[2][3], data)
end

g.test_a_nested_dispatch_gives_the_outer_page_its_own_request_back = function()
    local web, views = shared_router()

    web.get('/inner', function()
        return web.view('inner')
    end)
    web.get('/outer', function()
        web.dispatch(helper.request('GET', '/inner', { token = 'вложенный' }))

        return web.view('outer')
    end)

    web.dispatch(helper.request('GET', '/outer', { token = 'внешний' }))

    t.assert_equals(views.asked, {
        { 'render', 'inner', { csrf_token = 'вложенный', title = 'общий' } },
        { 'render', 'outer', { csrf_token = 'внешний', title = 'общий' } },
    })
end

g.test_the_helper_of_another_router_does_not_see_the_request = function()
    local web = g.router.new()
    local other, views, seen = shared_router()

    web.get('/customers', function()
        return other.view('customers.index')
    end)

    t.assert_equals(web.dispatch(helper.request('GET', '/customers', { token = 'T' })).status, 200)
    t.assert_equals(#seen, 0)
    t.assert_equals(views.asked, { { 'render', 'customers.index' } })
end

g.test_the_error_page_and_an_entry_layer_get_the_shared_data = function()
    -- Запрос держится на весь ответ: страницу рисуют и слой входа,
    -- и обработчик отказов, и данные у них те же, что у обработчика.
    -- Роутер нужен своему же слою и обработчику отказов, поэтому
    -- объявляется до заведения.
    ---@type any
    local web
    local views

    web, views = shared_router({
        entry = {
            function(request, nxt)
                if request.path == '/closed' then
                    return web.view('closed', nil, 503)
                end

                return nxt(request)
            end,
        },
        on_error = function(failure)
            return web.view('errors.page', { status = failure.status }, failure.status)
        end,
    })

    t.assert_equals(web.dispatch(helper.request('GET', '/closed', { token = 'T1' })).status, 503)
    t.assert_equals(web.dispatch(helper.request('GET', '/missing', { token = 'T2' })).status, 404)
    t.assert_equals(views.asked, {
        { 'render', 'closed', { csrf_token = 'T1', title = 'общий' } },
        { 'render', 'errors.page', { csrf_token = 'T2', title = 'общий', status = 404 } },
    })
end

g.test_a_refusal_of_view_data_comes_back_as_the_pair = function()
    -- Отказ view_data — отказ страницы: обработчик возвращает пару как
    -- есть, и роутер отвечает статусом, который отказ назвал.
    local refusal = { status = 503, message = 'сессия недоступна' }
    local views = engine()
    local web = g.router.new({
        view = views,
        view_data = function()
            return nil, refusal
        end,
    })
    local pairs_of = {}

    web.get('/customers', function()
        pairs_of.fragment = { web.fragment('customers.index', 'rows') }
        pairs_of.stream = { web.view_stream('customers.index') }

        return web.view('customers.index')
    end)

    t.assert_equals(web.dispatch(helper.request('GET', '/customers')).status, 503)
    t.assert_equals(pairs_of, { fragment = { nil, refusal }, stream = { nil, refusal } })
    t.assert_equals(views.asked, {}, 'страницу с отказом не рисовали')
end

g.test_view_data_without_a_table_is_a_bug_named_out_loud = function()
    -- Первый ответ — пустота: её в список не положить, и ответы идут
    -- по номеру вызова.
    local answers = { [2] = 'токен' }
    local called = 0
    local web = g.router.new({
        view = engine(),
        view_data = function()
            called = called + 1

            return answers[called]
        end,
    })
    local failures = {}

    web.get('/customers', function()
        for _, method in ipairs({ 'view', 'view_stream' }) do
            local _, err = pcall(web[method], 'customers.index')

            table.insert(failures, err)
        end

        return web.text('ok')
    end)

    web.dispatch(helper.request('GET', '/customers'))

    t.assert_equals(failures, {
        'view_data вернула nil, а не таблицу данных страницы',
        'view_data вернула string, а не таблицу данных страницы',
    })
end

g.test_view_data_is_checked_when_the_router_is_made = function()
    t.assert_error_msg_contains(
        'настройка «view_data» должна быть функцией, а не table',
        g.router.new,
        {
            view_data = { csrf_token = 'T' },
        }
    )
    t.assert_equals(g.router.new().status().view_data, false)
end

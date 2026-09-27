--- Тесты дерева маршрутов: порядок ветвей, возврат и перечень способов.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.tree')

--- Дерево маршрутов.
---@return any
local function tree()
    return helper.part('tnt.router.tree')
end

--- Кладёт маршрут в дерево; сам маршрут — просто метка.
---
--- Что именно лежит в маршруте, дереву безразлично: оно хранит и отдаёт.
---@param root table
---@param method string
---@param pattern string
---@param checks table<string, fun(value: string): boolean>|nil Проверки параметров
---@return table root
local function put(root, method, pattern, checks)
    local segments = helper.part('tnt.router.path').compile(pattern)
    local given = checks or {}

    for _, segment in ipairs(segments) do
        if segment.name ~= nil and given[segment.name] ~= nil then
            segment.check = given[segment.name]
            segment.constraint = segment.constraint or segment.name
        end
    end

    tree().insert(root, segments, method, { pattern = pattern })

    return root
end

--- Только цифры: ограничение, которого хватает всем проверкам здесь.
---@param value string
---@return boolean
local function numeric(value)
    return value:match('^%d+$') ~= nil
end

g.test_static_path_finds_its_route = function()
    local root = put(tree().node(), 'GET', '/customers/all')

    local route, params = tree().find(root, '/customers/all', 'GET')

    t.assert_equals(route.pattern, '/customers/all')
    t.assert_equals(params, {})
end

g.test_parameter_is_taken_from_the_path = function()
    local root = put(tree().node(), 'GET', '/customers/:id/orders/:order')

    local route, params = tree().find(root, '/customers/7/orders/42', 'GET')

    t.assert_equals(route.pattern, '/customers/:id/orders/:order')
    t.assert_equals(params, { id = '7', order = '42' })
end

g.test_static_part_wins_over_a_parameter_declared_earlier = function()
    local root = put(tree().node(), 'GET', '/files/:name')

    put(root, 'GET', '/files/new')

    t.assert_equals(tree().find(root, '/files/new', 'GET').pattern, '/files/new')
    t.assert_equals(tree().find(root, '/files/7', 'GET').pattern, '/files/:name')
end

g.test_constrained_parameter_is_tried_before_a_free_one = function()
    local root = put(tree().node(), 'GET', '/customers/:slug')

    put(root, 'GET', '/customers/:id', { id = numeric })

    t.assert_equals(tree().find(root, '/customers/7', 'GET').pattern, '/customers/:id')
    t.assert_equals(tree().find(root, '/customers/тот', 'GET').pattern, '/customers/:slug')
end

g.test_unmatched_constraint_is_not_a_dead_end = function()
    -- Ограничение не подошло — поиск идёт дальше, а не заканчивается:
    -- за числом стоит слово, и оно-то и подойдёт.
    local root = put(tree().node(), 'GET', '/customers/:id', { id = numeric })

    t.assert_equals(tree().find(root, '/customers/тот', 'GET'), nil)
end

g.test_search_comes_back_when_the_static_branch_knows_no_such_method = function()
    -- `/files/new` объявлен только для GET. Без возврата POST на него
    -- закрыл бы и `/files/:name`, у которого POST есть.
    local root = put(tree().node(), 'GET', '/files/new')

    put(root, 'POST', '/files/:name')

    t.assert_equals(tree().find(root, '/files/new', 'POST').pattern, '/files/:name')
end

g.test_tail_takes_everything_left_as_one_value = function()
    local root = put(tree().node(), 'GET', '/files/*rest')

    local route, params = tree().find(root, '/files/a/b/c.txt', 'GET')

    t.assert_equals(route.pattern, '/files/*rest')
    t.assert_equals(params, { rest = 'a/b/c.txt' })
end

g.test_tail_matches_an_empty_remainder_too = function()
    -- Корень раздачи иначе было бы нечем открыть.
    local root = put(tree().node(), 'GET', '/files/*rest')

    t.assert_equals(select(2, tree().find(root, '/files', 'GET')), { rest = '' })
end

g.test_tail_is_the_last_branch_tried = function()
    local root = put(tree().node(), 'GET', '/files/*rest')

    put(root, 'GET', '/files/new')
    put(root, 'GET', '/files/:name/raw')

    t.assert_equals(tree().find(root, '/files/new', 'GET').pattern, '/files/new')
    t.assert_equals(tree().find(root, '/files/7/raw', 'GET').pattern, '/files/:name/raw')
    t.assert_equals(tree().find(root, '/files/7/raw/more', 'GET').pattern, '/files/*rest')
end

g.test_tail_does_not_answer_for_a_method_it_was_not_given = function()
    local root = put(tree().node(), 'GET', '/files/*rest')

    t.assert_equals(tree().find(root, '/files/a/b', 'POST'), nil)
end

g.test_skippable_parameter_makes_two_addresses_out_of_one = function()
    local root = put(tree().node(), 'GET', '/files/:name?')

    t.assert_equals(tree().find(root, '/files/readme', 'GET').pattern, '/files/:name?')
    t.assert_equals(select(2, tree().find(root, '/files/readme', 'GET')), { name = 'readme' })
    t.assert_equals(tree().find(root, '/files', 'GET').pattern, '/files/:name?')
    t.assert_equals(select(2, tree().find(root, '/files', 'GET')), {})
end

g.test_two_skippable_parameters_give_three_addresses = function()
    local root = put(tree().node(), 'GET', '/years/:year?/:month?')

    for _, where in ipairs({ '/years/2026/09', '/years/2026', '/years' }) do
        t.assert_equals(tree().find(root, where, 'GET').pattern, '/years/:year?/:month?', where)
    end

    t.assert_equals(select(2, tree().find(root, '/years/2026/09', 'GET')), { year = '2026', month = '09' })
    t.assert_equals(select(2, tree().find(root, '/years/2026', 'GET')), { year = '2026' })
    t.assert_equals(select(2, tree().find(root, '/years', 'GET')), {})
end

g.test_address_made_entirely_of_skippable_parts_still_has_a_root = function()
    -- Шаблон, у которого необязательно всё, разворачивается до самого
    -- корня: `/:page?` обязан отвечать и на `/`.
    local root = put(tree().node(), 'GET', '/:page?')

    t.assert_equals(tree().find(root, '/выгрузка', 'GET').pattern, '/:page?')
    t.assert_equals(tree().find(root, '/', 'GET').pattern, '/:page?')
end

g.test_any_answers_for_a_method_nobody_declared = function()
    local root = put(tree().node(), tree().ANY, '/health')

    t.assert_equals(tree().find(root, '/health', 'DELETE').pattern, '/health')
end

g.test_declared_method_wins_over_any = function()
    local root = put(tree().node(), tree().ANY, '/health')

    put(root, 'GET', '/health')

    t.assert_equals(tree().find(root, '/health', 'GET').pattern, '/health')
end

g.test_nothing_is_found_where_nothing_was_declared = function()
    local route, params, allowed = tree().find(tree().node(), '/customers', 'GET')

    t.assert_equals(route, nil)
    t.assert_equals(params, {})
    t.assert_equals(allowed, {})
end

g.test_known_path_with_a_wrong_method_names_the_known_ones = function()
    local root = put(tree().node(), 'GET', '/customers')

    put(root, 'POST', '/customers')

    local route, _, allowed = tree().find(root, '/customers', 'DELETE')

    t.assert_equals(route, nil)
    t.assert_equals(allowed, { 'GET', 'POST' })
end

g.test_address_declared_for_everything_never_refuses_a_method = function()
    -- Перечень способов у такого адреса не спрашивают: он отвечает
    -- на любой, и до 405 дело не доходит.
    local root = put(tree().node(), tree().ANY, '/health')

    local route, _, allowed = tree().find(root, '/health', 'TRACE')

    t.assert_equals(route.pattern, '/health')
    t.assert_equals(allowed, {})
end

g.test_methods_are_named_by_the_first_branch_that_has_any = function()
    -- Путь совпал с двумя ветвями, и обе без нужного способа. Названа
    -- первая: она и обслуживала бы этот адрес.
    local root = put(tree().node(), 'GET', '/files/new')

    put(root, 'DELETE', '/files/:name')

    t.assert_equals(select(3, tree().find(root, '/files/new', 'POST')), { 'GET' })
end

g.test_longer_path_is_more_important_than_a_tail_above_it = function()
    -- Раздача панели объявлена хвостом у корня и отвечает на всё. Но адрес
    -- `/api/v1/cluster` есть, и способ у него один: ответить сюда первой
    -- страницей с кодом 200 значило бы подменить 405 успехом.
    local root = put(tree().node(), 'GET', '/api/v1/cluster')

    put(root, tree().ANY, '/*path')

    local route, _, allowed = tree().find(root, '/api/v1/cluster', 'DELETE')

    t.assert_equals(route, nil)
    t.assert_equals(allowed, { 'GET' })
end

g.test_tail_still_answers_where_there_is_no_longer_path = function()
    -- Правило про длинный путь не должно закрыть хвост там, ради чего он
    -- и объявлен: `/nodes` открывают ссылкой, и адреса такого нет.
    local root = put(tree().node(), 'GET', '/api/v1/cluster')

    put(root, tree().ANY, '/*path')

    t.assert_equals(tree().find(root, '/nodes', 'GET').pattern, '/*path')
    t.assert_equals(tree().find(root, '/api/v1/нет-такого', 'GET').pattern, '/*path')
end

g.test_tail_of_the_same_node_answers_its_own_address = function()
    -- Хвост своего узла — это не «хвост выше»: `/files` и `/files/*path`
    -- стоят на одной глубине, и пустой остаток достаётся хвосту.
    local root = put(tree().node(), 'POST', '/files')

    put(root, 'GET', '/files/*path')

    t.assert_equals(tree().find(root, '/files', 'GET').pattern, '/files/*path')
    t.assert_equals(select(2, tree().find(root, '/files', 'GET')), { path = '' })
end

g.test_nearer_tail_is_more_important_than_a_farther_one = function()
    -- Два хвоста на разной глубине — тот же спор: побеждает тот, под чьим
    -- началом путь длиннее.
    local root = put(tree().node(), 'GET', '/panel/*path')

    put(root, tree().ANY, '/*rest')

    local route, _, allowed = tree().find(root, '/panel/nodes', 'POST')

    t.assert_equals(route, nil)
    t.assert_equals(allowed, { 'GET' })
end

g.test_tail_found_below_is_not_replaced_by_a_tail_above = function()
    -- Нашёлся хвост под `/files` — поиск кончен. Хвост у корня тоже
    -- принял бы этот путь, но спуск до него уже не доходит: иначе
    -- раздача каталога отвечала бы запасной страницей корня.
    local root = put(tree().node(), 'GET', '/files/*path')

    put(root, 'GET', '/*all')

    local route, params = tree().find(root, '/files/a/b', 'GET')

    t.assert_equals(route.pattern, '/files/*path')
    t.assert_equals(params, { path = 'a/b' })
end

g.test_route_found_under_a_parameter_is_not_replaced_by_a_tail_above = function()
    -- То же про параметр не у корня: маршрут, найденный под ним, — конец
    -- поиска, и хвост выше за этот адрес уже не отвечает.
    local root = put(tree().node(), 'GET', '/p/:x/b')

    put(root, 'GET', '/*all')

    local route, params = tree().find(root, '/p/a/b', 'GET')

    t.assert_equals(route.pattern, '/p/:x/b')
    t.assert_equals(params, { x = 'a' })
end

g.test_tail_with_another_method_does_not_stop_the_search_above = function()
    -- Хвост под `/a` знает только POST, и на GET он не отвечает. Поиск
    -- при этом не кончен: параметр у корня знает `/:x/b` на GET. Взятое
    -- хвостом значение в ответ не попадает.
    local root = put(tree().node(), 'POST', '/a/*rest')

    put(root, 'GET', '/:x/b')

    local route, params = tree().find(root, '/a/b', 'GET')

    t.assert_equals(route.pattern, '/:x/b')
    t.assert_equals(params, { x = 'a' })
end

g.test_known_address_with_another_method_does_not_stop_the_search_above = function()
    -- `/a/b` есть, но только на POST, и узлу `/a` нечего предложить сверх
    -- этого. Хвосты выше молчат, но параметр у корня — не хвост: `/:x/b`
    -- на GET отвечает.
    local root = put(tree().node(), 'POST', '/a/b')

    put(root, 'GET', '/:x/b')

    local route, params = tree().find(root, '/a/b', 'GET')

    t.assert_equals(route.pattern, '/:x/b')
    t.assert_equals(params, { x = 'a' })
end

g.test_same_route_declared_twice_is_refused = function()
    local root = put(tree().node(), 'GET', '/customers')

    -- Без места: строку маршрута приписывает вход роутера.
    t.assert_error_msg_equals(
        'маршрут GET /customers объявлен дважды',
        put,
        root,
        'GET',
        '/customers'
    )
end

g.test_tail_named_differently_in_the_same_place_is_refused = function()
    local root = put(tree().node(), 'GET', '/files/*rest')

    t.assert_error_msg_contains('хвост здесь уже назван «rest», а не «path»', function()
        put(root, 'POST', '/files/*path')
    end)
end

g.test_same_parameter_shares_one_branch = function()
    local root = put(tree().node(), 'GET', '/customers/:id')

    put(root, 'POST', '/customers/:id')

    t.assert_equals(tree().find(root, '/customers/7', 'POST').pattern, '/customers/:id')
    t.assert_equals(select(3, tree().find(root, '/customers/7', 'DELETE')), { 'GET', 'POST' })
end

g.test_parameters_named_alike_but_constrained_differently_are_two_branches = function()
    local root = put(tree().node(), 'GET', '/customers/:id')

    put(root, 'GET', '/customers/:id/orders', { id = numeric })

    t.assert_equals(tree().find(root, '/customers/7', 'GET').pattern, '/customers/:id')
    t.assert_equals(tree().find(root, '/customers/7/orders', 'GET').pattern, '/customers/:id/orders')

    -- Ветви именно две: заказы объявлены под ограниченным параметром,
    -- и словом вместо числа до них не дойти.
    t.assert_equals(tree().find(root, '/customers/тот/orders', 'GET'), nil)
end

g.test_parameters_of_a_failed_branch_do_not_leak_into_the_answer = function()
    -- Спуск правит одну таблицу на весь обход: значение, взятое веткой,
    -- которая не подошла, обязано исчезнуть.
    local root = put(tree().node(), 'GET', '/files/:name/raw')

    put(root, 'GET', '/files/*rest')

    t.assert_equals(select(2, tree().find(root, '/files/a/b', 'GET')), { rest = 'a/b' })
end

g.test_found_parameters_are_a_copy_and_not_the_working_table = function()
    local root = put(tree().node(), 'GET', '/customers/:id')

    local first = select(2, tree().find(root, '/customers/7', 'GET'))
    local second = select(2, tree().find(root, '/customers/8', 'GET'))

    t.assert_equals(first, { id = '7' })
    t.assert_equals(second, { id = '8' })
end

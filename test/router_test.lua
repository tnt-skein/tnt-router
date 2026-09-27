--- Тесты фасада: объявление, группы, адреса по имени и обслуживание.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router')

--- Отдельный роутер: общий на процесс проверяется своими тестами.
---@param opts table|nil
---@return any
local function router(opts)
    return g.router.new(opts)
end

--- Место первой строки тела функции: там стоит вызов, который винят.
---@param fn function
---@return string
local function first_line_of(fn)
    local info = debug.getinfo(fn, 'S') --[[@as { short_src: string, linedefined: integer }]]

    return ('%s:%d'):format(info.short_src, info.linedefined + 1)
end

g.test_every_method_has_its_own_call = function()
    local r = router()

    for _, method in ipairs({ 'get', 'post', 'put', 'patch', 'delete', 'options', 'head' }) do
        r[method]('/customers', helper.answering(method))
    end

    for _, method in ipairs({ 'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS', 'HEAD' }) do
        t.assert_equals(r.dispatch(helper.request(method, '/customers')).body, method:lower())
    end
end

g.test_route_for_any_method_answers_the_unexpected_one = function()
    local r = router()

    r.any('/health', helper.answering('живой'))

    t.assert_equals(r.dispatch(helper.request('TRACE', '/health')).body, 'живой')
end

g.test_route_without_a_handler_falls_where_it_is_declared = function()
    -- Отказ винит строку маршрута — у экземпляра, через двоеточие,
    -- у общего роутера и у маршрута на любой способ.
    local r = router()

    helper.assert_blamed({
        {
            function()
                r.get('/customers', nil)
            end,
            'маршруту GET /customers нужен обработчик',
        },
        {
            function()
                r:post('/customers', 'обработчик')
            end,
            'маршруту POST /customers нужен обработчик',
        },
        {
            function()
                g.router.put('/customers/:id', {})
            end,
            'маршруту PUT /customers/:id нужен обработчик',
        },
        {
            function()
                r.any('/health')
            end,
            'маршруту ANY /health нужен обработчик',
        },
    })
end

g.test_colon_call_is_understood_as_well_as_the_dot_one = function()
    -- Примеры пишут то так, то так, и разнобой здесь стоит дороже
    -- трёх строк в заведении экземпляра.
    local r = router()

    r:get('/customers', helper.answering('через двоеточие'))

    t.assert_equals(r:dispatch(helper.request('GET', '/customers')).body, 'через двоеточие')
    t.assert_equals(r.status().routes, 1)
    t.assert_equals(r:status().routes, 1)
end

g.test_path_parameters_reach_the_handler = function()
    local r = router()

    r.get('/customers/:id/orders/:order', helper.echoing())

    local sent = r.dispatch(helper.request('GET', '/customers/7/orders/42'))

    t.assert_equals(helper.decoded(sent), { id = '7', order = '42' })
end

g.test_escaped_value_reaches_the_handler_as_written = function()
    local r = router()

    r.get('/files/:name', helper.echoing())

    t.assert_equals(helper.decoded(r.dispatch(helper.request('GET', '/files/a%2Fb'))), { name = 'a/b' })
end

g.test_constraint_from_the_pattern_turns_a_miss_into_a_missing_address = function()
    -- Не 500 из глубины обработчика, которому подсунули слово вместо
    -- числа, и не 400: этого адреса просто нет.
    local r = router()

    r.get('/customers/:id<int>', helper.echoing())

    t.assert_equals(r.dispatch(helper.request('GET', '/customers/7')).status, 200)
    t.assert_equals(r.dispatch(helper.request('GET', '/customers/новый')).status, 404)
end

g.test_constraint_can_be_named_beside_the_pattern = function()
    local r = router()

    r.get('/customers/:id', helper.echoing(), { where = { id = 'uuid' } })

    t.assert_equals(r.dispatch(helper.request('GET', '/customers/7')).status, 404)
    t.assert_equals(r.dispatch(helper.request('GET', '/customers/4f1e4d1e-0a2b-4c3d-8e9f-0a1b2c3d4e5f')).status, 200)
end

g.test_constraint_beside_the_pattern_has_the_last_word = function()
    -- Шаблон написан один раз, а группа сужает его для всех своих
    -- маршрутов сразу.
    local r = router()

    r.get('/customers/:id<int>', helper.echoing(), {
        where = {
            id = function(value)
                return value == 'тот'
            end,
        },
    })

    t.assert_equals(r.dispatch(helper.request('GET', '/customers/7')).status, 404)
    t.assert_equals(r.dispatch(helper.request('GET', '/customers/тот')).status, 200)
end

g.test_group_puts_its_beginning_before_every_path = function()
    local r = router()

    r.group('/api/v1', function(inner)
        inner.get('/customers', helper.answering('список'))
    end)

    t.assert_equals(r.dispatch(helper.request('GET', '/api/v1/customers')).body, 'список')
    t.assert_equals(r.dispatch(helper.request('GET', '/customers')).status, 404)
end

g.test_groups_nest_and_their_beginnings_add_up = function()
    local r = router()

    r.group('/api', function(outer)
        outer.group('/v1', function(inner)
            inner.get('/customers', helper.answering('список'))
        end)

        outer.get('/health', helper.answering('живой'))
    end)

    t.assert_equals(r.dispatch(helper.request('GET', '/api/v1/customers')).body, 'список')
    t.assert_equals(r.dispatch(helper.request('GET', '/api/health')).body, 'живой')
end

g.test_group_layers_wrap_its_routes_and_nobody_else = function()
    local marks = {}
    local r = router()

    r.group('/api', { middleware = { helper.marking(marks, 'вход') } }, function(inner)
        inner.get('/customers', helper.answering('список'))
    end)

    r.get('/health', helper.answering('живой'))

    r.dispatch(helper.request('GET', '/api/customers'))
    t.assert_equals(marks, { 'вход:до', 'вход:после' })

    r.dispatch(helper.request('GET', '/health'))
    t.assert_equals(marks, { 'вход:до', 'вход:после' })
end

g.test_layers_of_router_group_and_route_go_in_that_order = function()
    local marks = {}
    local r = router({ middleware = { helper.marking(marks, 'общий') } })

    r.group('/api', { middleware = { helper.marking(marks, 'группа') } }, function(inner)
        inner.get('/customers', helper.answering('список'), {
            middleware = { helper.marking(marks, 'маршрут') },
        })
    end)

    r.dispatch(helper.request('GET', '/api/customers'))

    t.assert_equals(marks, {
        'общий:до',
        'группа:до',
        'маршрут:до',
        'маршрут:после',
        'группа:после',
        'общий:после',
    })
end

g.test_group_constraints_reach_every_route_inside = function()
    local r = router()

    r.group('/api', { where = { id = 'int' } }, function(inner)
        inner.get('/customers/:id', helper.echoing())
    end)

    t.assert_equals(r.dispatch(helper.request('GET', '/api/customers/семь')).status, 404)
    t.assert_equals(r.dispatch(helper.request('GET', '/api/customers/7')).status, 200)
end

g.test_group_closes_even_when_a_route_inside_falls = function()
    -- Иначе следующий маршрут за пределами группы получил бы её начало
    -- пути, и нашлось бы это в другом месте и в другой день.
    local r = router()
    local function body(inner)
        inner.get('customers', helper.answering('список'))
    end

    local ok, err = pcall(r.group, '/api', body)

    -- Отказ маршрута в теле называет строку маршрута, а не группы:
    -- тело зовётся мимо приписки места, и второго места у отказа нет.
    t.assert_equals(ok, false)
    t.assert_equals(
        err,
        first_line_of(body)
            .. ': шаблон маршрута начинается с косой черты, а не «customers»'
    )

    r.get('/health', helper.answering('живой'))

    t.assert_equals(r.dispatch(helper.request('GET', '/health')).body, 'живой')
end

g.test_group_passes_the_fall_of_its_body_on_as_it_was = function()
    -- Исключение объявления уходит дальше тем же, каким его бросили:
    -- приписка места внутри роутера увела бы человека искать опечатку
    -- в чужом пакете.
    local ok, err = pcall(router().group, '/api', function()
        error('опечатка в объявлении', 0)
    end)

    t.assert_equals(ok, false)
    t.assert_equals(err, 'опечатка в объявлении')
end

g.test_group_without_a_body_is_refused_at_once = function()
    -- Группа без объявлений — это забытый третий аргумент, и молчать
    -- о нём значит потерять все маршруты, которые в ней собирались.
    -- Отказ винит строку группы — и у экземпляра, и у общего роутера.
    local r = router()
    local no_body =
        'группе нужна функция, в которой объявляются её маршруты'

    helper.assert_blamed({
        {
            function()
                r.group('/api', { name = 'api.' })
            end,
            no_body,
        },
        {
            function()
                r:group('/api', { name = 'api.' })
            end,
            no_body,
        },
        {
            function()
                g.router.group('/api')
            end,
            no_body,
        },
    })
end

g.test_settings_of_a_group_blame_the_line_of_the_group = function()
    -- Настройки группы проверяются до склейки с внешней областью:
    -- `where = 1` иначе сорвался бы обходом числа как таблицы внутри
    -- пакета. Место у всех отказов группы одно — её строка.
    local r = router()
    local body = function() end

    helper.assert_blamed({
        {
            function()
                r.group('/a', { where = 1 }, body)
            end,
            'настройка «where» должна быть таблицей, а не number',
        },
        {
            function()
                r.group('/a', { middleware = 'log' }, body)
            end,
            'настройка «middleware» должна быть таблицей, а не string',
        },
        {
            function()
                r.group('/a', { name = 7 }, body)
            end,
            'настройка «name» должна быть строкой, а не number',
        },
        {
            function()
                r.group('/a', 7, body)
            end,
            'настройка «группа» должна быть таблицей, а не number',
        },
        {
            function()
                g.router.group('/a', { where = 1 }, body)
            end,
            'настройка «where» должна быть таблицей, а не number',
        },
    })

    -- Промах группы не оставил её области: следующий маршрут объявлен
    -- от корня. А группа без настроек — то же, что с пустыми.
    r.group('/b', nil, function(inner)
        inner.get('/c', helper.answering('в группе'))
    end)
    r.get('/d', helper.answering('снаружи'))

    t.assert_equals(r.dispatch(helper.request('GET', '/b/c')).body, 'в группе')
    t.assert_equals(r.dispatch(helper.request('GET', '/d')).body, 'снаружи')
end

g.test_group_name_is_put_before_the_names_of_its_routes = function()
    local r = router()

    r.group('/api/v1', { name = 'api.' }, function(inner)
        inner.get('/customers/:id', helper.echoing(), { name = 'customer.show' })
    end)

    t.assert_equals(r.url('api.customer.show', { id = 7 }), '/api/v1/customers/7')
end

g.test_address_is_built_by_the_route_name = function()
    local r = router()

    r.get('/customers/:id', helper.echoing(), { name = 'customer.show' })

    t.assert_equals(r.url('customer.show', { id = 7 }), '/customers/7')
end

g.test_address_by_name_carries_the_query_string_too = function()
    local r = router()

    r.get('/customers', helper.echoing(), { name = 'customer.index' })

    t.assert_equals(r.url('customer.index', nil, { page = 2 }), '/customers?page=2')
end

g.test_unknown_name_is_a_refusal_and_not_a_fall = function()
    local built, err = router().url('нет.такого')

    t.assert_equals(built, nil)
    t.assert_equals(err, 'нет маршрута с именем «нет.такого»')
end

g.test_missing_parameter_is_a_refusal_and_names_itself = function()
    local r = router()

    r.get('/customers/:id', helper.echoing(), { name = 'customer.show' })

    local built, err = r.url('customer.show', {})

    t.assert_equals(built, nil)
    t.assert_equals(err, 'не задан параметр «id»')
end

g.test_one_name_belongs_to_one_route = function()
    local r = router()

    r.get('/customers/:id', helper.echoing(), { name = 'customer.show' })

    -- Отказ винит строку второго объявления: первое было правильным.
    helper.assert_blamed({
        {
            function()
                r.post('/customers/:id/copy', helper.echoing(), { name = 'customer.show' })
            end,
            'маршрут с именем «customer.show» уже объявлен',
        },
    })
end

g.test_what_the_application_put_in_the_request_reaches_the_handler = function()
    -- Иначе приложение носит свой довесок мимо запроса — хранилищем
    -- файбера или общей переменной, — и `dispatch`, позванный в обход
    -- обёртки, приходит без личности.
    local seen = {}
    local r = router()

    r.get('/customers', function(request)
        seen.identity = request.identity
        seen.peer = request.peer

        return { status = 200, headers = {}, body = '' }
    end)

    r.dispatch(helper.request('GET', '/customers', {
        identity = { username = 'admin' },
        peer = { host = '10.0.0.7' },
    }))

    t.assert_equals(seen.identity, { username = 'admin' })
    t.assert_equals(seen.peer, { host = '10.0.0.7' })
end

g.test_layers_see_the_same_additions_as_the_handler = function()
    -- Слой опознания смотрит на адрес клиента до обработчика: если
    -- довесок доезжает только до обработчика, слою приходится добывать
    -- его самому.
    local seen = {}
    local r = router({
        middleware = {
            function(request, next)
                seen.peer = request.peer

                return next(request)
            end,
        },
    })

    r.get('/login', helper.answering('вошли'))
    r.dispatch(helper.request('GET', '/login', { peer = { host = '10.0.0.7' } }))

    t.assert_equals(seen.peer, { host = '10.0.0.7' })

    -- До слоя доходит только тот запрос, которому нашёлся маршрут: 405
    -- собирается раньше, и слой опознания его не видит.
    seen.peer = nil

    r.dispatch(helper.request('POST', '/login', { peer = { host = '10.0.0.7' } }))

    t.assert_equals(seen.peer, nil)
end

g.test_handler_learns_which_route_brought_the_request = function()
    local r = router()

    r.get('/customers/:id', function(request)
        return { status = 200, headers = {}, body = require('json').encode(request.route) }
    end, { name = 'customer.show' })

    t.assert_equals(helper.decoded(r.dispatch(helper.request('GET', '/customers/7'))), {
        name = 'customer.show',
        pattern = '/customers/:id',
        method = 'GET',
    })
end

-- ── Место отказа объявления ─────────────────────────────────────────

--- Пакета слоёв рядом нет: слой, объявленный именем, разбирает запасная
--- сборка роутера.
local without_middleware = helper.without_middleware

--- Пакет слоёв-двойник: его вход винит своего вызывающего, как
--- настоящий, и не знает ни одного имени.
local function with_blaming_middleware()
    helper.part('tnt.router.neighbour')._set_source({
        load = function(name)
            if name ~= 'tnt.middleware' then
                return false, ('модуля %s нет'):format(name)
            end

            return true,
                {
                    chain = function(layers)
                        error(('слой или группа «%s» не объявлены'):format(layers[1]), 2)
                    end,
                }
        end,
    })
end

g.test_a_typo_in_a_pattern_blames_the_line_of_the_route = function()
    -- Разбор шаблона стоит на разной глубине от входа, и уровень, посчитанный
    -- на месте, указал бы внутрь пакета. Место приписывает вход: строку
    -- маршрута — у каждого способа, у общего роутера и в теле группы.
    local r = router()
    local cases = {
        {
            function()
                r.get('/a/:id?/b', helper.echoing())
            end,
            'за необязательным участком в «/a/:id?/b» стоит обязательный',
        },
        {
            function()
                r:post('api', helper.echoing())
            end,
            'шаблон маршрута начинается с косой черты, а не «api»',
        },
        {
            function()
                r.any('/files/*', helper.echoing())
            end,
            'хвост «*» в «/files/*» остался без имени',
        },
        {
            function()
                g.router.patch('/files/*rest/meta', helper.echoing())
            end,
            'хвост «*rest» бывает только последним в «/files/*rest/meta»',
        },
        {
            function()
                r.delete('/a/:id/b/:id', helper.echoing())
            end,
            'параметр «id» в «/a/:id/b/:id» назван дважды',
        },
        {
            function()
                r.options('/a/:', helper.echoing())
            end,
            'участок «:» шаблона «/a/:» не разобран',
        },
        {
            function()
                r.head('/a/:id<number>', helper.echoing())
            end,
            'нет такого ограничения: number',
        },
        {
            function()
                r.put('/a/:id', helper.echoing(), { where = { id = 'цифры' } })
            end,
            'нет такого ограничения: цифры',
        },
    }

    helper.assert_blamed(cases)

    -- Отказ маршрута в группе называет строку маршрута внутри её тела.
    r.group('/api', function(inner)
        helper.assert_blamed({
            {
                function()
                    inner.get('customers', helper.echoing())
                end,
                'шаблон маршрута начинается с косой черты, а не «customers»',
            },
        })
    end)
end

g.test_a_route_declared_twice_blames_the_second_line = function()
    -- Первое объявление было правильным: чинить надо второе.
    local r = router()

    r.get('/customers', helper.answering('список'))
    r.get('/files/*path', helper.answering('файл'))

    helper.assert_blamed({
        {
            function()
                r.get('/customers', helper.answering('ещё список'))
            end,
            'маршрут GET /customers объявлен дважды',
        },
        {
            function()
                r.post('/files/*rest', helper.answering('другой хвост'))
            end,
            'хвост здесь уже назван «path», а не «rest»',
        },
    })
end

g.test_a_prefix_of_a_group_blames_the_line_of_the_group = function()
    -- Начало группы без косой черты склеилось бы с внешним в путь, который
    -- открыть нельзя. Отказ о нём винит ту же строку группы, что её
    -- настройки, — и у экземпляра, и у общего роутера.
    local r = router()
    local body = function() end

    helper.assert_blamed({
        {
            function()
                r.group('api', body)
            end,
            'шаблон маршрута начинается с косой черты, а не «api»',
        },
        {
            function()
                r:group('api', { name = 'api.' }, body)
            end,
            'шаблон маршрута начинается с косой черты, а не «api»',
        },
        {
            function()
                g.router.group(7, body)
            end,
            'шаблон маршрута начинается с косой черты, а не «7»',
        },
    })

    -- Отказ группы не оставил её области: следующий маршрут — от корня.
    r.get('/health', helper.answering('живой'))

    t.assert_equals(r.dispatch(helper.request('GET', '/health')).body, 'живой')
end

g.test_a_route_of_a_delivery_blames_the_line_of_serve = function()
    -- У `serve` два рода отказов — настройки раздачи и сам маршрут, — и
    -- место у них одно: строка объявления раздачи.
    local r = router()

    r.serve('/build', 'public/build')

    helper.assert_blamed({
        {
            function()
                r.serve('build', 'public/build')
            end,
            'шаблон маршрута начинается с косой черты, а не «build/*path»',
        },
        {
            function()
                r:serve('/build', 'public/other')
            end,
            'маршрут GET /build/*path объявлен дважды',
        },
    })
end

g.test_a_layer_by_name_without_the_package_blames_the_line_of_the_route = function()
    -- Без пакета слоёв имя слоя не значит ничего, и запасная сборка
    -- отказывает. Место — строка маршрута, а не сборка внутри пакета.
    without_middleware()

    local r = router()

    helper.assert_blamed({
        {
            function()
                r.get('/a', helper.echoing(), { middleware = { 'log' } })
            end,
            'слой №1 объявлен string: имена слоёв разворачивает tnt.middleware, а его нет',
        },
    })
end

g.test_an_unknown_layer_of_the_package_blames_the_line_of_the_route = function()
    -- Вход пакета слоёв винит того, кто его позвал. Позови его роутер
    -- напрямую, отказ назвал бы строку роутера; через `bare` он без места,
    -- и место — строку маршрута — приписывает вход.
    with_blaming_middleware()

    local r = router()

    helper.assert_blamed({
        {
            function()
                r.get('/a', helper.echoing(), { middleware = { 'lgo' } })
            end,
            'слой или группа «lgo» не объявлены',
        },
    })

    -- Слой группы собирается у маршрута: отказ называет строку маршрута
    -- в её теле.
    r.group('/api', { middleware = { 'tmiing' } }, function(inner)
        helper.assert_blamed({
            {
                function()
                    inner.get('/b', helper.echoing())
                end,
                'слой или группа «tmiing» не объявлены',
            },
        })
    end)
end

g.test_an_unknown_layer_of_the_real_package_blames_the_line_of_the_route = function()
    -- Та же вина с настоящим пакетом слоёв, если он стоит: двойник мог
    -- бы разойтись с ним в том, кого винит вход.
    local ok = pcall(require, 'tnt.middleware')

    t.skip_if(not ok, 'пакет слоёв не установлен')

    local r = router()
    local function declare()
        r.get('/a', helper.echoing(), { middleware = { 'lgo' } })
    end

    local _, err = pcall(declare)
    local blamed = first_line_of(declare) .. ': слой или группа «lgo» не объявлены'

    -- Перечень объявленных слоёв у пакета свой, поэтому сверяется начало
    -- отказа: место маршрута и ни одного второго места перед словом.
    t.assert_equals(tostring(err):find(blamed, 1, true), 1)
end

g.test_entry_layers_blame_the_line_that_made_the_router = function()
    -- Слои входа собираются при заведении, и отказ их сборки винит ту же
    -- строку, что и настройки `router.new`.
    without_middleware()

    helper.assert_blamed({
        {
            function()
                g.router.new({ entry = { helper.answering('первый'), 'log' } })
            end,
            'слой №2 объявлен string: имена слоёв разворачивает tnt.middleware, а его нет',
        },
    })
end

g.test_entry_layers_of_the_shared_router_blame_its_first_use = function()
    -- Настройки общего роутера проверены в `configure`, а слои входа
    -- собираются при первом обращении: пакет слоёв настраивают и после
    -- роутера. Отказ сборки винит строку, которая обратилась первой, —
    -- не заведение внутри пакета.
    without_middleware()

    local refused =
        'слой №1 объявлен string: имена слоёв разворачивает tnt.middleware, а его нет'

    g.router.configure({ entry = { 'log' } })

    helper.assert_blamed({
        {
            function()
                g.router.get('/a', helper.echoing())
            end,
            refused,
        },
        {
            function()
                g.router.default()
            end,
            refused,
        },
    })
end

g.test_resolve_and_wrap_that_blame_their_caller_name_the_line_of_the_route = function()
    -- Разрешение обработчика и сборку слоёв приносит тот, кто собрал
    -- роутер. Функция, винящая своего вызывающего, назвала бы строку
    -- роутера; позванная через `bare`, она оставляет место входу.
    local resolving = router({
        resolve = function(handler)
            error(('обработчика «%s» нет'):format(handler), 2)
        end,
    })
    local wrapping = router({
        wrap = function()
            error('слои не собрать', 2)
        end,
    })

    helper.assert_blamed({
        {
            function()
                resolving.get('/a', 'pages@shwo')
            end,
            'обработчика «pages@shwo» нет',
        },
        {
            function()
                wrapping.get('/a', helper.echoing())
            end,
            'слои не собрать',
        },
    })
end

g.test_scope_of_a_group_blames_the_one_who_asked_for_it = function()
    -- Вход `group` зовёт область под `pcall`, и отказ её настройки там
    -- выходит без места. Позванная напрямую, она винит своего вызывающего.
    local scope = helper.part('tnt.router.declare').scope
    local outer = { prefix = '', middleware = {}, where = {}, name = '' }

    helper.assert_blamed({
        {
            function()
                scope(outer, '/a', { where = 1 })
            end,
            'настройка «where» должна быть таблицей, а не number',
        },
    })
end

-- ── Отказы ───────────────────────────────────────────────────────────

g.test_unknown_address_is_answered_with_404 = function()
    local sent = router().dispatch(helper.request('GET', '/customers'))

    t.assert_equals(sent.status, 404)
    t.assert_equals(helper.decoded(sent).error.message, 'нет такого адреса')
end

g.test_wrong_method_names_the_right_ones = function()
    local r = router()

    r.get('/customers', helper.answering('список'))
    r.post('/customers', helper.answering('заведён'))

    local journal = helper.capture_log()

    journal.forget()

    local sent = r.dispatch(helper.request('DELETE', '/customers'))

    t.assert_equals(sent.status, 405)
    t.assert_equals(sent.headers.allow, 'GET, HEAD, OPTIONS, POST')
    t.assert_equals(journal.logged('WARN [tnt.router]'), true)
end

g.test_declared_options_and_head_are_named_in_allow_only_once = function()
    -- Способ, объявленный руками, роутер добавляет и от себя: повтор
    -- в `Allow` — это заголовок, по которому клиент считает, что узел
    -- сломан.
    local r = router()

    r.get('/customers', helper.answering('список'))
    r.head('/customers', helper.answering('своё'))
    r.options('/customers', helper.answering('своё'))

    t.assert_equals(r.dispatch(helper.request('DELETE', '/customers')).headers.allow, 'GET, HEAD, OPTIONS')
end

g.test_head_is_served_by_the_get_handler_without_a_body = function()
    local r = router()

    r.get('/customers', helper.answering('список'))

    local sent = r.dispatch(helper.request('HEAD', '/customers'))

    t.assert_equals(sent.status, 200)
    t.assert_equals(sent.body, '')
    -- Длина — та, что была бы у GET: по RFC 9110 (9.3.2) заголовки
    -- ответа на HEAD совпадают с заголовками ответа на GET, и ноль
    -- вместо длины — ложь, а не умолчание.
    t.assert_equals(sent.headers, { ['content-length'] = '12' })
    t.assert_equals(#r.dispatch(helper.request('GET', '/customers')).body, 12)
end

g.test_head_of_a_stream_has_no_length_at_all = function()
    -- У тела по кускам длины заранее не бывает: назвать её нечем,
    -- а выдумать — то же враньё, только с другим числом.
    local r = router()

    r.get('/audit', function()
        return g.router.stream(function()
            return nil
        end)
    end)

    local sent = r.dispatch(helper.request('HEAD', '/audit'))

    t.assert_equals(sent.status, 200)
    t.assert_equals(sent.body, '')
    t.assert_equals(sent.headers['content-length'], nil)
    t.assert_equals(sent.headers['content-type'], 'application/octet-stream')
end

g.test_head_keeps_the_length_the_handler_told_itself = function()
    -- Раздача файлов знает размер, не открывая файла, и называет его
    -- сама: перемерить пустое тело значило бы ответить нулём.
    local r = router()

    r.get('/build/app.css', function()
        return { status = 200, headers = { ['content-length'] = '237167' }, body = '' }
    end)

    local sent = r.dispatch(helper.request('HEAD', '/build/app.css'))

    t.assert_equals(sent.headers['content-length'], '237167')
end

g.test_length_of_the_handler_is_not_remeasured_by_the_router = function()
    -- Мерить роутеру нечего: тело у обработчика, и длина, которую тот
    -- назвал, важнее меры по тому, что доехало до роутера. Здесь они
    -- разошлись нарочно — соврал бы обработчик, а не роутер.
    local r = router()

    r.get('/build/app.css', function()
        return { status = 200, headers = { ['content-length'] = '237167' }, body = 'огрызок' }
    end)

    t.assert_equals(r.dispatch(helper.request('HEAD', '/build/app.css')).headers, {
        ['content-length'] = '237167',
    })
end

g.test_head_leaves_no_trace_in_the_headers_of_the_handler = function()
    -- Обработчик вправе отдавать одну и ту же таблицу заголовков на
    -- каждый запрос: приписанная ей длина уехала бы в следующий ответ.
    local r = router()
    local headers = { ['content-type'] = 'text/plain; charset=utf-8' }

    r.get('/customers', function()
        return { status = 200, headers = headers, body = 'список' }
    end)

    local sent = r.dispatch(helper.request('HEAD', '/customers'))

    t.assert_equals(sent.headers['content-length'], '12')
    t.assert_equals(headers, { ['content-type'] = 'text/plain; charset=utf-8' })
end

g.test_head_of_an_answer_without_headers_brings_only_the_length = function()
    -- Заголовков у ответа может не быть вовсе, и длина — это первый
    -- заголовок, который он получит.
    local r = router()

    r.get('/customers', function()
        return { status = 200, body = 'список' }
    end)

    t.assert_equals(r.dispatch(helper.request('HEAD', '/customers')).headers, {
        ['content-length'] = '12',
    })
end

g.test_head_of_an_answer_without_a_body_stays_without_a_length = function()
    -- Ответу без тела длина не дописывается: у 204 её по RFC 9110 (8.6)
    -- не бывает, и приписанный ноль прочёлся бы как обрезанный ответ.
    local r = router()

    r.get('/customers', function()
        return g.router.no_content({ ['x-mark'] = 'есть' })
    end)

    t.assert_equals(r.dispatch(helper.request('HEAD', '/customers')).headers, { ['x-mark'] = 'есть' })
end

g.test_head_declared_on_its_own_keeps_its_answer = function()
    local r = router()

    r.get('/customers', helper.answering('список'))
    r.head('/customers', helper.answering('своё'))

    t.assert_equals(r.dispatch(helper.request('HEAD', '/customers')).body, 'своё')
end

g.test_head_of_a_missing_address_is_still_a_missing_address = function()
    t.assert_equals(router().dispatch(helper.request('HEAD', '/customers')).status, 404)
end

g.test_question_about_methods_is_answered_by_the_router_itself = function()
    -- Обработчика на OPTIONS никто не пишет, а ответить обязаны.
    local r = router()

    r.post('/customers', helper.answering('заведён'))

    t.assert_equals(r.dispatch(helper.request('OPTIONS', '/customers')), {
        status = 204,
        headers = { allow = 'OPTIONS, POST' },
    })
end

g.test_declared_options_handler_answers_instead_of_the_router = function()
    local r = router()

    r.options('/customers', helper.answering('своё'))

    t.assert_equals(r.dispatch(helper.request('OPTIONS', '/customers')).body, 'своё')
end

g.test_fallen_handler_does_not_take_the_node_down_with_it = function()
    local r = router()

    r.get('/customers', function()
        error('таблицы нет')
    end)

    local sent = r.dispatch(helper.request('GET', '/customers'))

    t.assert_equals(sent.status, 500)
    t.assert_equals(helper.decoded(sent).error.message, 'внутренняя ошибка')
    t.assert_equals(sent.body:find('таблицы нет', 1, true), nil)
end

g.test_refusal_of_the_handler_does_not_leak_outside = function()
    local r = router()

    r.get('/customers', function()
        return nil, 'соединение с хранилищем потеряно'
    end)

    local sent = r.dispatch(helper.request('GET', '/customers'))

    t.assert_equals(sent.status, 500)
    t.assert_equals(sent.body:find('хранилищем', 1, true), nil)
end

--- Причина отказа, с которой роутер ответил на такой запрос.
---@param r any Роутер
---@param asked table Запрос
---@return any reason
---@return table response
local function reason_of(r, asked)
    local seen = {}

    r.on_error(function(failure)
        seen.reason = failure.reason

        return { status = failure.status, headers = {}, body = '' }
    end)

    local sent = r.dispatch(asked)

    return seen.reason, sent
end

g.test_handler_that_answered_nothing_at_all_is_an_internal_failure = function()
    -- Пустота — поломка, а не «нет такого адреса»: маршрут-то нашёлся.
    -- Читать её как 404 значит отвечать на один и тот же промах то 404,
    -- то 500 — смотря обёрнут маршрут слоями или нет: проход слоёв читает
    -- ту же пустоту как «слой потерял ответ».
    local r = router()

    r.get('/files/*path', function()
        return nil
    end)

    local _, sent = reason_of(r, helper.request('GET', '/files/нет.js'))

    t.assert_equals(sent.status, 500)
end

g.test_silence_is_worded_the_same_as_in_the_package_of_layers = function()
    -- Главное утверждение здесь — совпадение двух договоров, а не текст
    -- сам по себе: дежурный, ищущий запись, не должен знать, обёрнут
    -- маршрут слоями или нет. Строка потому и берётся у соседнего пакета,
    -- а не переписывается третьей копией: разойтись копии могут молча,
    -- и не заметит этого ни один гейт.
    local ok, middleware = pcall(require, 'tnt.middleware')

    t.skip_if(not ok, 'пакет слоёв не установлен')

    local _, said = middleware
        .chain({})
        :wrap(function()
            return nil
        end)({})

    t.assert_equals(type(said), 'string')

    local r = router()

    r.get('/files/*path', function()
        return nil
    end)

    local reason = reason_of(r, helper.request('GET', '/files/нет.js'))

    t.assert_equals(reason, said)
end

g.test_handler_that_answered_not_an_answer_is_an_internal_failure = function()
    local r = router()

    r.get('/customers', function()
        return 'список'
    end)

    local reason, sent = reason_of(r, helper.request('GET', '/customers'))

    t.assert_equals(sent.status, 500)
    t.assert_equals(reason, 'обработчик вернул не ответ')
end

g.test_request_that_is_not_a_table_is_refused_and_not_dispatched = function()
    t.assert_equals(router().dispatch('GET /customers').status, 400)
end

g.test_incident_of_a_failure_is_written_to_the_journal_and_to_the_answer = function()
    -- По опознавателю запись находится в журнале — подробности лежат там,
    -- а не в ответе. Вместе с ними записано и то, о каком запросе речь.
    local journal = helper.capture_log()

    journal.forget()

    local r = router()

    r.get('/customers/:id', function()
        error('таблицы нет')
    end)

    local sent = r.dispatch(helper.request('GET', '/customers/7'))

    t.assert_equals(journal.logged(helper.decoded(sent).error.incident), true)
    t.assert_equals(journal.logged('таблицы нет'), true)
    t.assert_equals(journal.logged('method=GET'), true)
    t.assert_equals(journal.logged('path=/customers/7'), true)
    t.assert_equals(journal.logged('ERROR [tnt.router]'), true)
end

--- Начало стека, снятого на месте броска: первым кадром — сам `error`.
local THROWN = "\nstack traceback:\n\t[C]: in function 'error'\n\t"

--- Стек, который несёт отказ соседа: кадр обработчика под кадром броска.
local CARRIED = "\nstack traceback:\n\t[C]: in function 'error'"
    .. '\n\tsrc/app/handlers.lua:12: in function <src/app/handlers.lua:10>'

--- Печать отказа упавшего шага — его слово, без стека.
local SPOKEN = {
    __tostring = function(self)
        return self.message
    end,
}

--- Поля записи роутера об отказе.
---@param journal table Ловушка журнала
---@return table
local function refused_fields(journal)
    return journal.find('запрос отклонён').record.fields
end

--- Кадр строки этого файла в стеке.
---@param line integer
---@return string
local function frame_of(line)
    return ('router_test.lua:%d: in function'):format(line)
end

g.test_fall_of_a_bare_handler_is_written_with_the_stack_of_the_throw = function()
    -- Бросок маршрута без слоёв ловит сам роутер, и стек снимает ловушка
    -- на месте броска: после перехвата он размотан, и запись говорила бы,
    -- что сломалось, но не как туда пришли.
    local journal = helper.capture_log()

    journal.forget()

    local r = router()
    local thrown_at = 0

    r.get('/customers/:id', function()
        thrown_at = assert(debug.getinfo(1, 'l')).currentline + 1
        error('таблицы нет')
    end)

    local sent = r.dispatch(helper.request('GET', '/customers/7'))
    local fields = refused_fields(journal)

    -- Первый кадр — сам бросок: ни ловушки, ни `debug.traceback` в стеке нет.
    t.assert_equals(fields.traceback:find(THROWN, 1, true), 1)
    t.assert_str_contains(fields.traceback, frame_of(thrown_at))
    -- Причина — прежней строкой, стек лежит своим полем.
    t.assert_str_contains(fields.reason, 'таблицы нет')
    t.assert_not_str_contains(fields.reason, 'stack traceback')
    -- Наружу не уходит ни стек, ни причина.
    t.assert_equals(sent.status, 500)
    t.assert_not_str_contains(sent.body, 'stack traceback')
    t.assert_not_str_contains(sent.body, 'router_test.lua')
end

g.test_fall_under_layers_is_written_with_the_stack_the_layers_brought = function()
    -- Конвейер слоёв ловит бросок сам и отдаёт его отказом со стеком
    -- в поле `traceback`: снять стек роутеру уже нечем, и запись берёт
    -- принесённый. Проверяется против установленного пакета слоёв —
    -- ровно им маршруты и обёрнуты в бою.
    local ok = pcall(require, 'tnt.middleware')

    t.skip_if(not ok, 'пакет слоёв не установлен')

    local journal = helper.capture_log()

    journal.forget()

    local r = router()
    local thrown_at = 0

    -- Слой отдаёт пару следующего как есть: отказ упавшего обработчика
    -- доходит до роутера тем, что собрал конвейер.
    local passing = function(request, next)
        return next(request)
    end

    r.get('/customers/:id', function()
        thrown_at = assert(debug.getinfo(1, 'l')).currentline + 1
        error('таблицы нет')
    end, { middleware = { passing } })

    local sent = r.dispatch(helper.request('GET', '/customers/7'))
    local fields = refused_fields(journal)

    t.assert_equals(fields.traceback:find(THROWN, 1, true), 1)
    t.assert_str_contains(fields.traceback, frame_of(thrown_at))
    t.assert_str_contains(fields.reason, 'обработчик упал: ')
    t.assert_not_str_contains(fields.reason, 'stack traceback')
    t.assert_equals(sent.status, 500)
    t.assert_not_str_contains(sent.body, 'stack traceback')
end

g.test_fall_of_the_entry_is_written_with_the_stack_of_the_throw = function()
    -- Сборка входа, которая бросок не ловит, роняет его до роутера,
    -- и ловушка роутера снимает стек и здесь.
    local journal = helper.capture_log()

    journal.forget()

    local thrown_at = 0
    local r = router({
        -- Слой — только повод позвать сборку: своя сборка его не смотрит.
        entry = { print },
        wrap = function()
            return function()
                thrown_at = assert(debug.getinfo(1, 'l')).currentline + 1
                error('сборка входа сломана')
            end
        end,
    })

    t.assert_equals(r.dispatch(helper.request('GET', '/customers')).status, 500)

    local fields = refused_fields(journal)

    t.assert_equals(fields.traceback:find(THROWN, 1, true), 1)
    t.assert_str_contains(fields.traceback, frame_of(thrown_at))
    t.assert_str_contains(fields.reason, 'сборка входа сломана')
end

g.test_trap_that_failed_itself_still_leaves_a_refusal_with_a_reason = function()
    -- Сорвись сама ловушка — кончилась память, — `xpcall` отдаёт слово
    -- Lua строкой. Ответ всё равно 500, а в записи — это слово: стека нет,
    -- но и пустой записи нет. Память по заказу не кончается, поэтому
    -- ловушку срывает подмена `debug.traceback` на время одного запроса.
    local journal = helper.capture_log()

    journal.forget()

    local r = router()

    r.get('/customers', function()
        error('таблицы нет')
    end)

    local traceback = debug.traceback

    rawset(debug, 'traceback', function()
        error('стек не снять')
    end)

    local ok, sent = pcall(r.dispatch, helper.request('GET', '/customers'))

    rawset(debug, 'traceback', traceback)

    t.assert_equals(ok, true)
    t.assert_equals(sent.status, 500)

    local fields = refused_fields(journal)

    t.assert_equals(fields.reason, 'error in error handling')
    t.assert_equals(fields.traceback, nil)
end

--- Роутер, отвечающий на `/:kind` отказом из списка.
---@param refusals table<string, any> Отказы по имени
---@return any
local function refusing(refusals)
    local r = router()

    r.get('/:kind', function(request)
        return nil, refusals[request.params.kind]
    end)

    return r
end

g.test_stack_a_refusal_brought_is_written_by_the_router = function()
    -- Отказ без номера о себе в журнал ещё не писал, и принесённый им
    -- стек идёт в запись роутера — и у отказа со статусом, и у отказа
    -- упавшего шага, статуса не называющего.
    local journal = helper.capture_log()
    local fallen = { message = 'обработчик упал: нет поля', traceback = CARRIED }
    local r = refusing({
        declared = { status = 503, traceback = CARRIED },
        fallen = setmetatable(fallen, SPOKEN),
    })

    journal.forget()
    t.assert_equals(r.dispatch(helper.request('GET', '/declared')).status, 503)
    t.assert_equals(refused_fields(journal).traceback, CARRIED)

    journal.forget()
    t.assert_equals(r.dispatch(helper.request('GET', '/fallen')).status, 500)
    t.assert_equals(refused_fields(journal).traceback, CARRIED)
    t.assert_equals(refused_fields(journal).reason, 'обработчик упал: нет поля')
end

g.test_stack_of_a_refusal_already_written_is_not_written_twice = function()
    -- Отказ с номером уже описан в журнале тем, кто отказал: вторая копия
    -- его стека — вдвое больше строк без нового смысла.
    local journal = helper.capture_log()

    journal.forget()

    local sent = refusing({
        written = { status = 503, incident = 'ABCD-EFGH', traceback = CARRIED },
    }).dispatch(helper.request('GET', '/written'))

    t.assert_equals(sent.status, 503)
    t.assert_equals(refused_fields(journal).incident, 'ABCD-EFGH')
    t.assert_equals(refused_fields(journal).traceback, nil)
end

g.test_stack_taken_by_the_router_goes_before_the_one_the_throw_brought = function()
    -- Снятый ловушкой — стек заведомо, а поле брошенной таблицы — стек
    -- только по договору.
    local journal = helper.capture_log()

    journal.forget()

    local r = router()
    local thrown_at = 0

    r.get('/customers', function()
        thrown_at = assert(debug.getinfo(1, 'l')).currentline + 1
        error({ message = 'таблицы нет', traceback = CARRIED })
    end)

    r.dispatch(helper.request('GET', '/customers'))

    local fields = refused_fields(journal)

    t.assert_str_contains(fields.traceback, frame_of(thrown_at))
    t.assert_not_str_contains(fields.traceback, 'src/app/handlers.lua')
end

g.test_only_a_string_is_taken_for_a_brought_stack = function()
    -- Признак один и явный — строка в поле `traceback`. Поле читается
    -- мимо метатаблицы: чужой `__index`, бросив, унёс бы с собой запись
    -- о поломке.
    local journal = helper.capture_log()
    local r = refusing({
        number = { status = 503, traceback = 42 },
        list = { status = 503, traceback = { CARRIED } },
        hidden = setmetatable({ status = 503 }, { __index = { traceback = CARRIED } }),
        hostile = setmetatable({ status = 503 }, {
            __index = function(_, key)
                if key == 'traceback' then
                    error('метатаблица бросила')
                end
            end,
        }),
    })

    for _, kind in ipairs({ 'number', 'list', 'hidden', 'hostile' }) do
        journal.forget()

        t.assert_equals(r.dispatch(helper.request('GET', '/' .. kind)).status, 503, kind)
        t.assert_equals(refused_fields(journal).traceback, nil, kind)
        t.assert_equals(journal.logged('метатаблица бросила'), false, kind)
    end
end

g.test_refusal_short_of_a_failure_is_written_more_quietly = function()
    -- Поднимать тревогу по каждому сканеру, постучавшему в несуществующий
    -- адрес, значит утопить в них настоящие ошибки.
    local journal = helper.capture_log()

    journal.forget()

    router().dispatch(helper.request('GET', '/customers'))

    t.assert_equals(journal.logged('запрос отклонён'), true)
    t.assert_equals(journal.logged('WARN [tnt.router]'), true)
    t.assert_equals(journal.logged('ERROR [tnt.router]'), false)
end

g.test_request_that_was_not_even_parsed_is_written_without_its_path = function()
    -- Записать путь неразобранного запроса неоткуда: самого запроса нет.
    local journal = helper.capture_log()

    journal.forget()

    t.assert_equals(router().dispatch(nil).status, 400)
    t.assert_equals(journal.logged('запрос отклонён'), true)
    t.assert_equals(journal.logged('WARN [tnt.router]'), true)
    t.assert_equals(journal.logged('path='), false)
end

g.test_own_handler_answers_instead_of_the_default_one = function()
    -- Отказ первым аргументом, запрос вторым: обработчик отказов пишется
    -- про отказ, а запрос идёт довеском.
    local r = router()

    r.on_error(function(failure, request)
        return {
            status = failure.status,
            headers = {},
            body = ('%s %s'):format(failure.status, request.path),
        }
    end)

    t.assert_equals(r.dispatch(helper.request('GET', '/customers')).body, '404 /customers')
    t.assert_equals(r.status().custom_errors, true)
end

g.test_own_handler_of_one_argument_is_enough = function()
    -- Обработчик, написанный соседним пакетом отказов, берёт один аргумент —
    -- сам отказ. Запрос ему не нужен, и требовать его подписью значило бы
    -- не пустить внутрь ровно то, ради чего настройка и заведена.
    local r = router()

    r.on_error(function(failure)
        return { status = failure.status, headers = {}, body = 'по одному аргументу' }
    end)

    t.assert_equals(r.dispatch(helper.request('GET', '/customers')).body, 'по одному аргументу')
end

g.test_own_handler_receives_the_refusal_as_it_came = function()
    -- Решать, что из отказа показать человеку, — не работа роутера.
    local seen = {}
    local r = router()

    r.get('/customers', function()
        return nil, { code = 'STORAGE_DOWN' }
    end)

    r.on_error(function(failure)
        seen.reason = failure.reason
        seen.incident = failure.incident

        return { status = 503, headers = {}, body = '' }
    end)

    t.assert_equals(r.dispatch(helper.request('GET', '/customers')).status, 503)
    t.assert_equals(seen.reason, { code = 'STORAGE_DOWN' })
    t.assert_str_matches(seen.incident, '%w%w%w%w%-%w%w%w%w')
end

g.test_own_handler_is_told_there_was_no_request_at_all = function()
    -- Неразобранный запрос отвергается до того, как станет запросом:
    -- второй аргумент у обработчика отказов бывает и пустым, и обещать
    -- его подписью нельзя.
    local seen = { request = 'ещё не спрашивали' }
    local r = router()

    r.on_error(function(failure, request)
        seen.request = request

        return { status = failure.status, headers = {}, body = '' }
    end)

    t.assert_equals(r.dispatch('GET /customers').status, 400)
    t.assert_equals(seen.request, nil)
end

g.test_own_handler_may_be_given_at_the_very_beginning = function()
    local r = router({
        on_error = function(failure)
            return { status = failure.status, headers = {}, body = 'своё' }
        end,
    })

    t.assert_equals(r.dispatch(helper.request('GET', '/customers')).body, 'своё')
end

g.test_ready_refusal_is_at_hand_for_the_own_handler = function()
    -- 404 и 405 — слово роутера: у каталога отказов приложения ни кода
    -- для них, ни статуса, и собирать их заново ради одной ветки незачем.
    local r = router()

    r.on_error(function(failure, request)
        if failure.status ~= 500 then
            return g.router.refusal(failure, request)
        end

        return { status = 500, headers = {}, body = 'своё' }
    end)

    local sent = r.dispatch(helper.request('GET', '/customers'))

    t.assert_equals(sent.status, 404)
    t.assert_equals(helper.decoded(sent).error.message, 'нет такого адреса')
end

g.test_catalog_of_the_neighbour_plugs_in_as_the_handler_of_refusals = function()
    -- Ровно то, что обещает документ: каталог отказов соседнего пакета
    -- подставляется одной строкой и отвечает за всё сразу — и за 404
    -- роутера, и за отказ из обработчика, и за упавший обработчик.
    --
    -- Проверяется против установленной копии, а она может отставать
    -- от исходников; связка целиком, против исходников обоих пакетов,
    -- проверяется у пакета отказов: для него роутер — зависимость.
    local ok, errors = pcall(require, 'tnt.error')

    t.skip_if(not ok, 'пакет отказов не установлен')
    t.skip_if(
        errors.REFUSED == nil,
        'установленная копия старше договора границы'
    )

    ---@type any
    local catalog = errors.registry(nil)

    catalog:define('customer.gone', { status = 410, message = 'клиента №{id} больше нет' })

    local r = router()

    r.get('/customers/:id', function(request)
        return nil, catalog:new('customer.gone', { id = request.params.id })
    end)

    r.get('/orders', function()
        error('таблицы нет')
    end)

    r.on_error(catalog:handler())

    local refused = r.dispatch(helper.request('GET', '/customers/7'))

    t.assert_equals(refused.status, 410)
    t.assert_equals(helper.decoded(refused).title, 'клиента №7 больше нет')

    -- Упавший обработчик каталог тоже узнаёт — и не говорит о нём наружу
    -- ничего, кроме опознавателя.
    local fallen = r.dispatch(helper.request('GET', '/orders'))

    t.assert_equals(fallen.status, 500)
    t.assert_equals(fallen.body:find('таблицы нет', 1, true), nil)

    -- А своё слово роутер оставляет за собой, и 405 остаётся при Allow.
    local missing = r.dispatch(helper.request('GET', '/нет'))

    t.assert_equals(missing.status, 404)
    t.assert_equals(helper.decoded(missing).title, 'нет такого адреса')

    local wrong = r.dispatch(helper.request('POST', '/orders'))

    t.assert_equals(wrong.status, 405)
    t.assert_equals(wrong.headers.allow, 'GET, HEAD, OPTIONS')
end

g.test_header_the_status_owes_travels_in_the_failure_itself = function()
    -- Заголовок Allow при 405 требует RFC 9110 от ответа, а ответ
    -- собирает не всегда роутер: оставленный в его ответе, у чужого
    -- обработчика заголовок пропал бы молча.
    local seen = {}
    local r = router()

    r.get('/customers', helper.answering('список'))

    r.on_error(function(failure)
        seen.headers = failure.headers

        return { status = failure.status, headers = {}, body = '' }
    end)

    t.assert_equals(r.dispatch(helper.request('DELETE', '/customers')).status, 405)
    t.assert_equals(seen.headers, { allow = 'GET, HEAD, OPTIONS' })
end

g.test_word_for_a_human_travels_in_the_failure_itself = function()
    -- У каталога отказов приложения нет ни кода 404, ни слова о нём:
    -- не скажи роутер своего слова в самом отказе, чужой обработчик
    -- ответил бы «внутренняя ошибка» на промах по адресу.
    local seen = {}
    local r = router()

    r.on_error(function(failure)
        seen.message = failure.message

        return { status = failure.status, headers = {}, body = '' }
    end)

    r.dispatch(helper.request('GET', '/customers'))

    t.assert_equals(seen.message, 'нет такого адреса')
end

g.test_refusal_that_named_its_own_status_keeps_it = function()
    -- Договор границы HTTP читается в обе стороны: «клиента больше нет»
    -- с кодом 410 — не поломка узла, и решать это за обработчика роутеру
    -- не по чину. Прежде такой ответ был 500.
    local journal = helper.capture_log()

    journal.forget()

    local r = router()

    r.get('/customers/:id', function()
        return nil,
            {
                status = 410,
                message = 'клиента больше нет',
                code = 'customer.gone',
                headers = { ['retry-after'] = '3600' },
            }
    end)

    local sent = r.dispatch(helper.request('GET', '/customers/7'))
    local shown = helper.decoded(sent).error

    t.assert_equals(sent.status, 410)
    t.assert_equals(sent.headers['retry-after'], '3600')
    t.assert_equals(shown.message, 'клиента больше нет')
    t.assert_equals(shown.code, 'customer.gone')
    -- Уровень записи выбирается правилом, а не перечнем своих кодов:
    -- 410 — обычная жизнь узла, а не повод для тревоги.
    t.assert_equals(journal.logged('WARN [tnt.router]'), true)
    t.assert_equals(journal.logged('ERROR [tnt.router]'), false)
end

g.test_the_line_between_a_refusal_and_a_breakage_is_drawn_at_five_hundred = function()
    -- 4xx — обычная жизнь открытого в сеть узла, 5xx — поломка. Граница
    -- проверяется по обе стороны: соседние коды пишутся разными уровнями,
    -- иначе «утопить тревогу в сканерах» и «промолчать о поломке»
    -- отличались бы только словами в комментарии.
    local journal = helper.capture_log()
    local r = router()

    r.get('/customers/:code', function(request)
        return nil, { status = tonumber(request.params.code), message = 'так вышло' }
    end)

    journal.forget()
    r.dispatch(helper.request('GET', '/customers/499'))

    t.assert_equals(journal.logged('WARN [tnt.router]'), true)
    t.assert_equals(journal.logged('ERROR [tnt.router]'), false)

    journal.forget()
    r.dispatch(helper.request('GET', '/customers/500'))

    t.assert_equals(journal.logged('ERROR [tnt.router]'), true)
    t.assert_equals(journal.logged('WARN [tnt.router]'), false)

    -- И всё, что выше пятисот, — тоже поломка: граница здесь одна,
    -- а не перечень кодов, которым назначили уровень поимённо.
    journal.forget()
    r.dispatch(helper.request('GET', '/customers/503'))

    t.assert_equals(journal.logged('ERROR [tnt.router]'), true)
    t.assert_equals(journal.logged('WARN [tnt.router]'), false)
end

g.test_refusal_that_came_with_an_incident_does_not_get_a_second_one = function()
    -- Второй номер увёл бы человека к записи, в которой ничего нет:
    -- о происшествии уже написал тот, кто отказал.
    local r = router()

    r.get('/customers', function()
        return nil, { status = 503, message = 'хранилище занято', incident = 'ЧУЖОЙ-1' }
    end)

    local sent = r.dispatch(helper.request('GET', '/customers'))

    t.assert_equals(sent.status, 503)
    t.assert_equals(helper.decoded(sent).error.incident, 'ЧУЖОЙ-1')
end

g.test_a_refusal_without_a_status_of_its_own_is_still_a_breakage = function()
    -- Отказ узнаётся по числу в `status`, а не по виду прочих полей:
    -- ни чужая строка, ни запись работы отказом не считаются.
    local r = router()

    for _, returned in ipairs({
        { { code = 'STORAGE_DOWN' } },
        { { status = 'ok' } },
        { { status = 1 } },
        { { status = 200 } },
        { { status = 404.5 } },
        { { status = 600 } },
        { 'хранилище молчит' },
    }) do
        r.get('/customers/' .. tostring(returned[1]), function()
            return nil, returned[1]
        end)

        local sent = r.dispatch(helper.request('GET', '/customers/' .. tostring(returned[1])))

        t.assert_equals(sent.status, 500, tostring(returned[1]))
    end
end

g.test_handler_of_refusals_is_a_function_and_nothing_else = function()
    -- Отказ винит строку, которая подставляла обработчик, — у экземпляра,
    -- через двоеточие и у общего роутера.
    local r = router()

    helper.assert_blamed({
        {
            function()
                r.on_error('пусть будет')
            end,
            'обработчиком отказов бывает функция, а не string',
        },
        {
            function()
                r:on_error({})
            end,
            'обработчиком отказов бывает функция, а не table',
        },
        {
            function()
                g.router.on_error()
            end,
            'обработчиком отказов бывает функция, а не nil',
        },
    })

    -- Негодный обработчик не подставлен: отвечает прежний.
    t.assert_equals(r.dispatch(helper.request('GET', '/нет')).status, 404)
end

g.test_fallen_handler_of_refusals_still_leaves_an_answer = function()
    local journal = helper.capture_log()

    journal.forget()

    local r = router()

    r.on_error(function()
        error('и этот упал')
    end)

    local sent = r.dispatch(helper.request('GET', '/customers'))

    t.assert_equals(sent.status, 500)
    t.assert_str_matches(sent.body, '{"error":{"status":500,"incident":"[^"]+"}}')
    t.assert_equals(journal.logged('обработчик отказов не дал ответа'), true)
end

g.test_silent_handler_of_refusals_still_leaves_an_answer = function()
    -- Молчание ушло бы к клиенту пустым ответом с кодом 200, то есть
    -- как успех, — а речь шла об отказе.
    local r = router()

    r.on_error(function() end)

    t.assert_equals(r.dispatch(helper.request('GET', '/customers')).status, 500)
end

-- ── Настройки ────────────────────────────────────────────────────────

g.test_common_beginning_of_paths_is_given_once = function()
    local r = router({ prefix = '/api/v1' })

    r.get('/customers', helper.answering('список'))

    t.assert_equals(r.dispatch(helper.request('GET', '/api/v1/customers')).body, 'список')
    t.assert_equals(r.status().prefix, '/api/v1')
end

g.test_settings_of_a_wrong_kind_are_refused_at_once = function()
    -- Опечатка в настройке обязана обнаружиться при загрузке приложения,
    -- когда её видит разработчик, а не ночью, когда её видит дежурный.
    -- И показывать отказ обязан на строку, где роутер завели или
    -- настроили: у одной функции одно место на все отказы — то же, что
    -- у адреса приложения и ключа подписи.
    local wrong = {
        { { prefix = 7 }, 'настройка «prefix» должна быть строкой, а не number' },
        {
            { middleware = print },
            'настройка «middleware» должна быть таблицей, а не function',
        },
        {
            { entry = 'лишнее' },
            'настройка «entry» должна быть таблицей, а не string',
        },
        { { view = 'нет' }, 'настройка «view» должна быть таблицей, а не string' },
        {
            { view_data = {} },
            'настройка «view_data» должна быть функцией, а не table',
        },
        { { where = 'int' }, 'настройка «where» должна быть таблицей, а не string' },
        { { on_error = {} }, 'настройка «on_error» должна быть функцией, а не table' },
        { { wrap = true }, 'настройка «wrap» должна быть функцией, а не boolean' },
        {
            { resolve = 'позже' },
            'настройка «resolve» должна быть функцией, а не string',
        },
    }
    local cases = {}

    for _, case in ipairs(wrong) do
        table.insert(cases, {
            function()
                g.router.new(case[1])
            end,
            case[2],
        })
        table.insert(cases, {
            function()
                g.router.configure(case[1])
            end,
            case[2],
        })
    end

    helper.assert_blamed(cases)
end

g.test_settings_of_a_delivery_blame_the_line_that_declared_it = function()
    -- Раздачу объявляют двумя путями — маршрутом `serve` и готовым
    -- обработчиком `files`, — и кадров до проверки у них разное число.
    -- Место у обоих одно: строка объявления.
    local r = router()

    helper.assert_blamed({
        {
            function()
                r.serve('/build', 'public/build', { missing = 'x' })
            end,
            'настройка «missing» должна быть функцией, а не string',
        },
        {
            function()
                r:serve('/build', 'public/build', { chunk = 0 })
            end,
            'настройка «chunk» должна быть числом от 1 до 67108864, а не 0',
        },
        {
            function()
                g.router.serve('/build', 'public/build', { in_memory = -1 })
            end,
            'настройка «in_memory» должна быть больше нуля, а не -1',
        },
        {
            function()
                r.serve(7, 'public/build')
            end,
            'настройка «prefix» должна быть строкой, а не number',
        },
        {
            function()
                r.serve('/build', 'public/build', 'сразу')
            end,
            'настройка «раздача» должна быть таблицей, а не string',
        },
        {
            function()
                g.router.files({ missing = 'x' })
            end,
            'раздаче нужен ровно один источник: root или bundle',
        },
        {
            function()
                g.router.files({ bundle = {}, missing = 'x' })
            end,
            'настройка «missing» должна быть функцией, а не string',
        },
        {
            function()
                g.router.files({ bundle = { 'app.js' } })
            end,
            'имя файла в bundle должно быть строкой, а не number',
        },
        {
            function()
                g.router.files({ root = '' })
            end,
            'настройка «root» должна быть непустой строкой',
        },
    })

    t.assert_equals(r.routes(), {})
end

g.test_own_assembly_of_layers_can_be_put_in_place_of_the_externals = function()
    -- Конвейер слоёв — отдельный пакет, и роутер обязан пускать его
    -- внутрь одной настройкой.
    local r = router({
        wrap = function(layers)
            return function()
                return { status = 200, headers = {}, body = ('%d слоя'):format(#layers) }
            end
        end,
        middleware = { print, print },
    })

    r.get('/customers', helper.answering('список'))

    t.assert_equals(r.dispatch(helper.request('GET', '/customers')).body, '2 слоя')
end

g.test_entry_layers_stand_before_the_route_lookup = function()
    -- Слой входа видит и путь, которого нет: закрытое на обслуживание
    -- приложение отвечает 503 на всё, иначе по 404 снаружи читались бы
    -- его маршруты. Слои маршрутов до закрытого обработчика не доходят.
    local closed = false
    local seen = {}
    local r = router({
        entry = {
            function(request, nxt)
                table.insert(seen, 'вход ' .. request.path)

                if closed then
                    return nil,
                        { status = 503, message = 'обслуживание', headers = { ['retry-after'] = '60' } }
                end

                local response = nxt(request)

                response.headers['x-entry'] = 'да'

                return response
            end,
        },
        middleware = {
            function(request, nxt)
                table.insert(seen, 'маршрут ' .. request.path)

                return nxt(request)
            end,
        },
    })

    r.get('/customers', helper.answering('список'))

    local open = r.dispatch(helper.request('GET', '/customers'))

    t.assert_equals(open.body, 'список')
    t.assert_equals(open.headers['x-entry'], 'да')
    t.assert_equals(r.dispatch(helper.request('GET', '/nowhere')).status, 404, 'вход пропускает и 404')
    t.assert_equals(seen, { 'вход /customers', 'маршрут /customers', 'вход /nowhere' })

    closed = true

    local refused = r.dispatch(helper.request('GET', '/nowhere'))

    t.assert_equals(refused.status, 503)
    t.assert_equals(refused.headers['retry-after'], '60')
    t.assert_equals(seen[#seen], 'вход /nowhere')
    t.assert_equals(r.dispatch(helper.request('GET', '/customers')).status, 503)
    t.assert_equals(seen[#seen], 'вход /customers', 'слой маршрута не звался')
    t.assert_equals(r.status().entry, 1)
end

--- Запрос `http.server` с телом в пять байт: под предел в четыре не проходит.
---@return table incoming
local function oversized()
    return {
        method = 'POST',
        path = '/customers',
        path_raw = '/customers',
        query = '',
        headers = { ['content-length'] = '5' },
    }
end

g.test_entry_layers_stand_around_the_refusal_of_the_body_too = function()
    -- Тело не в пределах отвергается до маршрута, но не до слоёв входа:
    -- у запроса есть голова, и опознавателю с журналом есть что записать.
    -- Слой видит отказ в запросе и вправе ответить иначе.
    local seen = {}
    local r = router({
        entry = {
            function(request, nxt)
                table.insert(seen, {
                    method = request.method,
                    path = request.path,
                    refusal = request.refusal ~= nil and request.refusal.status or nil,
                })

                local response = nxt(request)

                response.headers['x-entry'] = 'да'

                return response
            end,
        },
        middleware = {
            function()
                error(
                    'слой маршрута до отвергнутого запроса дойти не должен'
                )
            end,
        },
    })
    local httpd = { options = {}, idle_timeout = 30 }

    r.post('/customers', helper.answering('заведён'))
    r.attach(httpd, { max_body = 4 })

    local incoming = oversized()
    local sent = httpd.options.handler(httpd, incoming)

    t.assert_equals(sent.status, 413)
    t.assert_equals(sent.headers['x-entry'], 'да')
    t.assert_equals(helper.decoded(sent).error.message, 'тело запроса слишком велико')
    t.assert_equals(seen, { { method = 'POST', path = '/customers', refusal = 413 } })
    t.assert_equals(incoming.broken, true)

    -- Слой входа вправе ответить вместо отказа: закрытое приложение
    -- отвечает 503 и на тело не в пределах.
    local closed = router({
        entry = {
            function()
                return nil, { status = 503, message = 'обслуживание' }
            end,
        },
    })
    local sleeping = { options = {}, idle_timeout = 30 }

    closed.attach(sleeping, { max_body = 4 })

    t.assert_equals(sleeping.options.handler(sleeping, oversized()).status, 503)
end

g.test_refusal_put_into_the_request_from_outside_is_dropped = function()
    -- Отказ до маршрута кладёт роутер сам, и подложить его снаружи нельзя:
    -- иначе запрос, собранный таблицей, отвергался бы чужим словом.
    local r = router()

    r.get('/customers', helper.answering('список'))

    local sent = r.dispatch(helper.request('GET', '/customers', { refusal = { status = 418 } }))

    t.assert_equals(sent.status, 200)
    t.assert_equals(sent.body, 'список')
end

g.test_a_broken_entry_layer_is_a_500_and_not_a_dead_node = function()
    local r = router({
        entry = {
            function()
                error('слой входа сломан')
            end,
        },
    })

    r.get('/customers', helper.answering('список'))

    local response = r.dispatch(helper.request('GET', '/customers'))

    t.assert_equals(response.status, 500)

    -- Конвейер слоёв ловит падение слоя сам; сборка, которая этого
    -- не делает, тоже не роняет узел: падение ловит роутер.
    local bare = router({
        entry = { print },
        wrap = function()
            return function()
                error('сборка входа сломана')
            end
        end,
    })

    local reason, sent = reason_of(bare, helper.request('GET', '/customers'))

    t.assert_equals(sent.status, 500)
    t.assert_str_contains(reason, 'сборка входа сломана')

    t.assert_error_msg_contains(
        'настройка «entry» должна быть таблицей, а не string',
        router,
        { entry = 'лишнее' }
    )
end

g.test_instance_answers_with_the_same_helpers_as_the_module = function()
    -- Маршрутам приходит экземпляр, и `return web.html(…)` не должен
    -- требовать второго require ради помощника.
    local r = router()

    t.assert_equals(r.html('<p>привет</p>'), g.router.html('<p>привет</p>'))
    t.assert_equals(r:html('<p>привет</p>', 201).status, 201)
    t.assert_equals(r.json({ a = 1 }), g.router.json({ a = 1 }))
    t.assert_equals(r.text('да', 202).status, 202)
    t.assert_equals(r.redirect('/there').headers.location, '/there')
    t.assert_equals(r.no_content().status, 204)
    t.assert_equals(type(r.stream(function() end).body), 'function')
end

g.test_view_renders_a_page_through_the_engine_given_at_construction = function()
    -- Роутер не знает, чем рисуют страницы, — только что у движка есть
    -- render.
    local engine = {
        render = function(_, name, data)
            return ('<h1>%s: %s</h1>'):format(name, (data or {}).who or 'никто')
        end,
    }
    local r = router({ view = engine })

    r.get('/about', function()
        return r.view('about', { who = 'мир' })
    end)

    local response = r.dispatch(helper.request('GET', '/about'))

    t.assert_equals(response.body, '<h1>about: мир</h1>')
    t.assert_str_contains(response.headers['content-type'], 'text/html')
    t.assert_equals(r:view('about', nil, 404).status, 404)
    t.assert_equals(r:view('about', nil, 404).body, '<h1>about: никто</h1>')
    t.assert_equals(r.status().view, true)

    t.assert_error_msg_equals(
        'страницы не настроены: нужен view в router.new',
        router().view,
        'about'
    )
    t.assert_error_msg_contains(
        'настройка «view» должна быть таблицей, а не string',
        router,
        { view = 'нет' }
    )
end

g.test_a_non_function_handler_goes_through_resolve_at_declaration = function()
    -- Запись `{ объект, 'метод' }` роутер не толкует сам: отдаёт настройке
    -- при объявлении, а не при первом запросе, — опечатка в имени метода
    -- обязана обнаружиться при загрузке приложения.
    local pages = {
        show = function()
            return { status = 200, headers = {}, body = 'страница' }
        end,
    }
    local r = router({
        resolve = function(handler)
            return handler[1][handler[2]]
        end,
    })

    r.get('/page', { pages, 'show' })

    t.assert_equals(r.dispatch(helper.request('GET', '/page')).body, 'страница')

    -- Разрешённое не в функцию — тот же отказ, что и без настройки.
    t.assert_error_msg_contains('маршруту GET /typo нужен обработчик', function()
        r.get('/typo', { pages, 'shwo' })
    end)

    -- Без настройки запись не-функцией — отказ, а не тихое разрешение.
    t.assert_error_msg_contains('маршруту GET /page нужен обработчик', function()
        router().get('/page', { pages, 'show' })
    end)

    t.assert_error_msg_contains('настройка «resolve» должна быть функцией', function()
        router({ resolve = 'позже' })
    end)
end

g.test_every_declared_route_is_named_out_loud = function()
    -- Порядок — по адресу, а при равных адресах по способу: список
    -- маршрутов читают глазами, и порядок объявления для этого негоден.
    -- Адрес, который продолжает другой (`/customers-archive`), встаёт
    -- после него и перед его подпутями: разделитель в ключе сортировки
    -- обязан быть меньше любого знака адреса.
    local r = router()

    r.get('/health', helper.answering('живой'))
    r.put('/customers', helper.answering('заменён'))
    r.get('/customers-archive', helper.answering('архив'))
    r.post('/customers', helper.answering('заведён'))
    r.get('/customers/:id', helper.echoing())
    r.delete('/customers', helper.answering('снесён'))
    r.get('/customers', helper.answering('список'), { name = 'customer.index' })

    t.assert_equals(r.routes(), {
        { method = 'DELETE', pattern = '/customers' },
        { method = 'GET', pattern = '/customers', name = 'customer.index' },
        { method = 'POST', pattern = '/customers' },
        { method = 'PUT', pattern = '/customers' },
        { method = 'GET', pattern = '/customers-archive' },
        { method = 'GET', pattern = '/customers/:id' },
        { method = 'GET', pattern = '/health' },
    })
end

g.test_status_tells_what_is_set_up_and_no_more = function()
    local r = router({ prefix = '/api', middleware = { print } })

    r.get('/customers', helper.answering('список'), { name = 'customer.index' })

    t.assert_equals(r.status(), {
        routes = 1,
        names = { 'customer.index' },
        prefix = '/api',
        middleware = 1,
        entry = 0,
        view = false,
        view_data = false,
        custom_errors = false,
        signing = false,
    })
end

-- ── Общий на процесс ─────────────────────────────────────────────────

g.test_shared_router_is_made_at_the_first_ask_and_kept = function()
    t.assert_equals(g.router.default(), g.router.default())
end

g.test_shared_router_is_reachable_by_the_short_call = function()
    g.router.get('/customers', helper.answering('список'))

    t.assert_equals(g.router.dispatch(helper.request('GET', '/customers')).body, 'список')
    t.assert_equals(g.router.default().status().routes, 1)
end

g.test_settings_made_after_the_first_route_forget_it = function()
    -- Настройка, сделанная после объявления, обязана менять поведение,
    -- а не оставаться словами.
    g.router.get('/customers', helper.answering('список'))
    g.router.configure({ prefix = '/api' })

    t.assert_equals(g.router.dispatch(helper.request('GET', '/customers')).status, 404)
    t.assert_equals(g.router.status().prefix, '/api')
end

g.test_separate_routers_share_nothing = function()
    local first = router()
    local second = router()

    first.get('/customers', helper.answering('список'))

    t.assert_equals(second.dispatch(helper.request('GET', '/customers')).status, 404)
    t.assert_equals(first.status().routes, 1)
    t.assert_equals(second.status().routes, 0)
end

-- ── Поверх http.server ───────────────────────────────────────────────

g.test_router_takes_over_the_server_handler = function()
    local httpd = { options = {} }

    g.router.get('/customers/:id', helper.echoing())
    g.router.attach(httpd)

    local sent = httpd.options.handler(httpd, {
        method = 'GET',
        path = '/customers/7',
        path_raw = '/customers/7',
        query = '',
        headers = {},
    })

    t.assert_equals(helper.decoded(sent), { id = '7' })
end

g.test_address_of_the_client_reaches_the_handler_through_the_server = function()
    -- Адрес клиента знает один сервер. Не перенести его здесь значит
    -- оставить без него и вход, и аудит: взять его дальше неоткуда.
    ---@type any
    local seen

    local httpd = { options = {} }

    g.router.post('/login', function(request)
        seen = request.peer

        return g.router.no_content()
    end)

    g.router.attach(httpd)

    httpd.options.handler(httpd, {
        method = 'POST',
        path = '/login',
        path_raw = '/login',
        query = '',
        headers = {},
        peer = { host = '10.0.0.7', port = 51234 },
    })

    t.assert_equals(seen, { host = '10.0.0.7', port = 51234 })
end

g.test_router_is_attached_to_a_server_and_not_to_anything_else = function()
    -- Отказ винит строку подключения — у общего роутера и у экземпляра.
    local r = router()
    local refused = 'подключать роутер надо к серверу http.server'

    helper.assert_blamed({
        {
            function()
                g.router.attach({})
            end,
            refused,
        },
        {
            function()
                r.attach(7)
            end,
            refused,
        },
        {
            function()
                r:attach({ options = 'нет' })
            end,
            refused,
        },
    })
end

g.test_body_over_the_limit_is_refused_before_the_route = function()
    local reached = false
    local httpd = { options = {}, idle_timeout = 30 }

    g.router.post('/customers', function()
        reached = true

        return g.router.no_content()
    end)

    g.router.attach(httpd, { max_body = 4 })

    local journal = helper.capture_log()

    journal.forget()

    local incoming = oversized()
    local sent = httpd.options.handler(httpd, incoming)

    t.assert_equals(sent.status, 413)
    t.assert_equals(helper.decoded(sent).error.message, 'тело запроса слишком велико')
    t.assert_equals(reached, false)
    t.assert_equals(incoming.broken, true)
    -- Запись та же, что у всякого отказа роутера: куда шли и почему.
    t.assert_equals(journal.logged('WARN [tnt.router]'), true)
    t.assert_equals(journal.logged('path=/customers'), true)
    t.assert_equals(journal.logged('тело в 5 байт больше предела в 4'), true)
end

g.test_refusal_of_the_body_goes_through_the_own_error_handler = function()
    ---@type any
    local seen
    local httpd = { options = {}, idle_timeout = 30 }

    g.router.on_error(function(failure, request)
        seen = { status = failure.status, path = request.path }

        return { status = failure.status, headers = {}, body = 'своё' }
    end)

    g.router.attach(httpd)

    local sent = httpd.options.handler(httpd, {
        method = 'PUT',
        path = '/customers/7',
        headers = { ['transfer-encoding'] = 'chunked' },
    })

    t.assert_equals(sent.body, 'своё')
    t.assert_equals(seen, { status = 411, path = '/customers/7' })
end

g.test_server_without_an_idle_timeout_is_named_at_attach = function()
    local journal = helper.capture_log()

    for _, idle_timeout in ipairs({ 0, -1, false }) do
        journal.forget()

        g.router.attach({ options = {}, idle_timeout = idle_timeout or nil })

        t.assert_equals(
            journal.logged(
                'WARN [tnt.router] у сервера нет срока простоя: медленное соединение держит файбер бессрочно'
            ),
            true
        )
    end

    journal.forget()

    g.router.attach({ options = {}, idle_timeout = 0.001 })

    t.assert_equals(journal.logged('срока простоя'), false)
end

g.test_declarations_hand_back_what_they_made = function()
    -- Цепочку пишут подряд: `r.on_error(...).group(...)`, а маршрут берут
    -- из объявления, чтобы сверить его шаблон.
    local r = router()
    local httpd = { options = {}, idle_timeout = 30 }

    t.assert_is(r.on_error(helper.answering('отказ')), r)
    t.assert_is(r.group('/api', function() end), r)
    t.assert_equals(r.get('/customers', helper.answering('список')).pattern, '/customers')
    t.assert_equals(r.any('/health', helper.answering('живой')).method, 'ANY')
    t.assert_equals(r.serve('/build', 'public/build').pattern, '/build/*path')
    t.assert_is(r.attach(httpd), httpd)
    t.assert_equals(g.router.get('/shared', helper.answering('общий')).pattern, '/shared')
end

g.test_wrong_limits_fail_at_attach = function()
    -- Отказ предела винит строку подключения, а не разбор пределов внутри
    -- пакета: у одной функции одно место на все отказы — то же, что
    -- у сервера не того вида.
    local httpd = { options = {}, idle_timeout = 30 }
    local r = router()

    helper.assert_blamed({
        {
            function()
                g.router.attach(httpd, { max_body = 0 })
            end,
            'настройка «max_body» должна быть целым числом байт больше нуля, а не 0',
        },
        {
            function()
                r.attach(httpd, { body_timeout = 0 })
            end,
            'настройка «body_timeout» должна быть конечным числом секунд больше нуля, а не 0',
        },
        {
            function()
                r:attach(httpd, { temp_dir = 7 })
            end,
            'настройка «temp_dir» должна быть строкой, а не number',
        },
    })

    -- Подключения не случилось: обработчик сервера не подменён.
    t.assert_equals(httpd.options.handler, nil)
end

-- ── Готовые ответы фасада ────────────────────────────────────────────

g.test_ready_answers_are_at_hand_in_the_facade = function()
    -- Иначе каждый обработчик собирает ответ руками и однажды забывает
    -- тип содержимого.
    t.assert_equals(g.router.json({ id = 7 }).headers['content-type'], 'application/json; charset=utf-8')
    t.assert_equals(g.router.text('готово').body, 'готово')
    t.assert_equals(g.router.html('<h1>').headers['content-type'], 'text/html; charset=utf-8')
    t.assert_equals(g.router.no_content().status, 204)
    t.assert_equals(g.router.redirect('/customers').status, 302)
end

g.test_panel_files_are_served_by_one_route = function()
    g.router.get(
        '/panel/*path',
        g.router.files({
            bundle = { ['index.html'] = '<h1>панель</h1>' },
            fallback = 'index.html',
        })
    )

    t.assert_equals(g.router.dispatch(helper.request('GET', '/panel')).body, '<h1>панель</h1>')
    t.assert_equals(g.router.dispatch(helper.request('GET', '/panel/nodes')).body, '<h1>панель</h1>')
end

g.test_missing_file_is_a_404_even_on_a_route_wrapped_in_layers = function()
    -- Раньше раздача отвечала роутеру пустотой, а проход слоёв читал ту же
    -- пустоту как «слой потерял ответ»: один и тот же промах отвечал
    -- то 404, то 500 — смотря обёрнут маршрут слоями или нет. Теперь
    -- раздача отказывает парой, и пара обязана пройти слои целиком.
    --
    -- Цепочку обязан собрать настоящий `tnt.middleware`, а не запасная
    -- сборка роутера: с запасной пустота в отказ не превращается вовсе,
    -- и проверка прошла бы одинаково в обоих случаях, ничего не установив.
    -- Поэтому слой объявлен именем: имена разворачивает только реестр
    -- соседнего пакета, а запасная сборка падает на них при объявлении
    -- маршрута.
    local ok = pcall(require, 'tnt.middleware')

    t.skip_if(not ok, 'пакет слоёв не установлен')

    local marks = {}
    local r = router({ middleware = { 'timing', helper.marking(marks, 'общий') } })

    r.get('/panel/*path', g.router.files({ bundle = { ['app.js'] = 'const a = 1;' } }))

    local sent = r.dispatch(helper.request('GET', '/panel/нет.js'))

    t.assert_equals(sent.status, 404)
    t.assert_equals(helper.decoded(sent).error.message, 'нет такого адреса')
    t.assert_equals(marks, { 'общий:до', 'общий:после' })
end

g.test_panel_at_the_root_does_not_eat_the_refusals_of_the_api = function()
    -- Хвост у корня ловит все адреса разом. Без правила «более длинный
    -- путь важнее» неизвестный адрес API отвечал бы первой страницей
    -- с кодом 200, а верный адрес с другим способом — тем же самым.
    local r = router()

    r.get('/api/v1/cluster', helper.answering('кластер'))
    r.any(
        '/*path',
        g.router.files({
            bundle = { ['index.html'] = '<h1>панель</h1>' },
            fallback = 'index.html',
            except = { '/api' },
        })
    )

    t.assert_equals(r.dispatch(helper.request('GET', '/nodes')).body, '<h1>панель</h1>')

    local refused = r.dispatch(helper.request('DELETE', '/api/v1/cluster'))

    t.assert_equals(refused.status, 405)
    t.assert_equals(refused.headers.allow, 'GET, HEAD, OPTIONS')

    local missing = r.dispatch(helper.request('GET', '/api/v1/нет-такого'))

    t.assert_equals(missing.status, 404)
    t.assert_equals(missing.body:find('панель', 1, true), nil)
end

-- ── Раздача каталога под началом пути ────────────────────────────────

--- Каталог сборки с двумя файлами: этого хватает проверкам здесь.
---@return string
local function built()
    local fio = require('fio')
    local root = fio.tempdir()
    local handle = fio.open(fio.pathjoin(root, 'app.css'), { 'O_WRONLY', 'O_CREAT' }, tonumber('0644', 8))

    handle:write('body{}')
    handle:close()

    return root
end

g.test_directory_is_served_by_one_declaration = function()
    -- Объявлять шаблон с хвостом и собирать обработчик раздачи руками —
    -- две строки, которые пишутся в каждом приложении одинаково.
    local r = router()
    local root = built()

    r.serve('/build', root)

    local sent = r.dispatch(helper.request('GET', '/build/app.css'))

    t.assert_equals(sent.status, 200)
    t.assert_equals(sent.body, 'body{}')
    t.assert_equals(sent.headers['content-type'], 'text/css; charset=utf-8')

    -- Объявлен один маршрут, на GET: HEAD роутер обслуживает сам.
    t.assert_equals(r.routes(), { { method = 'GET', pattern = '/build/*path', name = nil } })

    require('fio').rmtree(root)
end

g.test_served_directory_answers_head_405_and_404_by_the_rules_of_the_router = function()
    local r = router()
    local root = built()

    r.serve('/build', root)

    local head = r.dispatch(helper.request('HEAD', '/build/app.css'))

    t.assert_equals(head.status, 200)
    t.assert_equals(head.body, '')
    t.assert_equals(head.headers['content-type'], 'text/css; charset=utf-8')

    -- Способ не тот — 405 с перечнем: его собирает дерево, раздача
    -- о способах не знает и знать не должна.
    local refused = r.dispatch(helper.request('POST', '/build/app.css'))

    t.assert_equals(refused.status, 405)
    t.assert_equals(refused.headers.allow, 'GET, HEAD, OPTIONS')

    -- Шаг вверх по дереву — обычный промах по файлу, а не подсказка
    -- о том, как устроен диск.
    t.assert_equals(r.dispatch(helper.request('GET', '/build/../etc/passwd')).status, 404)
    t.assert_equals(r.dispatch(helper.request('GET', '/build/%2e%2e/etc/passwd')).status, 404)

    require('fio').rmtree(root)
end

g.test_served_directory_can_be_named_and_addressed_by_that_name = function()
    local r = router()
    local root = built()

    r.serve('/build', root, { name = 'assets', immutable = true })

    t.assert_equals(r.url('assets', { path = 'app-BX7Yy2Qk.css' }), '/build/app-BX7Yy2Qk.css')

    require('fio').rmtree(root)
end

g.test_delivery_at_the_root_yields_to_every_declared_route = function()
    -- `public/` как корень сайта: раздача ловит всё, чего не поймали
    -- объявленные маршруты, а более длинный путь важнее хвоста.
    local r = router()
    local root = built()

    r.get('/api/v1/cluster', helper.answering('кластер'))
    r.serve('/', root)

    t.assert_equals(r.dispatch(helper.request('GET', '/api/v1/cluster')).body, 'кластер')
    t.assert_equals(r.dispatch(helper.request('GET', '/app.css')).body, 'body{}')
    t.assert_equals(r.dispatch(helper.request('GET', '/нет.css')).status, 404)

    require('fio').rmtree(root)
end

g.test_a_miss_by_file_reaches_the_own_handler_of_refusals_as_a_miss_by_address = function()
    -- Промах по файлу и промах по адресу — один и тот же отказ: оба рисует
    -- обработчик отказов приложения, и у браузера одна страница 404 на оба.
    -- Слово едет в самом отказе, а номер происшествия роутер дописывает
    -- и тому, и другому.
    local seen = {}
    local r = router()
    local root = built()

    r.serve('/build', root)
    r.on_error(function(failure, request)
        table.insert(seen, { status = failure.status, message = failure.message, path = request.path })
        -- Номер сверяется снаружи: брошенное в обработчике отказов роутер
        -- превратил бы в 500 и спрятал бы причину.
        seen[#seen].incident = failure.incident

        return { status = failure.status, headers = {}, body = 'своя страница' }
    end)

    for _, path in ipairs({ '/build/нет.css', '/нет' }) do
        local sent = r.dispatch(helper.request('GET', path))

        t.assert_equals({ sent.status, sent.body }, { 404, 'своя страница' }, path)
    end

    for _, case in ipairs(seen) do
        t.assert_str_matches(case.incident, '%w%w%w%w%-%w%w%w%w')

        case.incident = nil
    end

    t.assert_equals(seen, {
        { status = 404, message = 'нет такого адреса', path = '/build/нет.css' },
        { status = 404, message = 'нет такого адреса', path = '/нет' },
    })

    require('fio').rmtree(root)
end

g.test_a_miss_by_file_is_answered_and_written_as_a_miss_by_address = function()
    -- Без своего обработчика отказов тело то же, что у промаха по адресу,
    -- и запись в журнале та же: предупреждение с номером из ответа.
    local journal = helper.capture_log()
    local r = router()
    local root = built()

    r.serve('/build', root)
    journal.forget()

    local file = helper.decoded(r.dispatch(helper.request('GET', '/build/нет.css'))).error
    local address = helper.decoded(r.dispatch(helper.request('GET', '/нет'))).error

    t.assert_equals(file.status, 404)
    t.assert_equals(file.message, 'нет такого адреса')
    t.assert_equals(file.status, address.status)
    t.assert_equals(file.message, address.message)
    t.assert_equals(journal.logged(file.incident), true)
    t.assert_equals(journal.logged('path=/build/нет.css'), true)
    t.assert_equals(journal.logged('WARN [tnt.router]'), true)
    t.assert_equals(journal.logged('ERROR [tnt.router]'), false)

    require('fio').rmtree(root)
end

--- Метка границы для проверок формы.
local BOUNDARY = 'ГРАНИЦА-42'

--- Запрос с многочастным телом.
---@param parts table[]
---@return table
local function with_parts(parts)
    return helper.request('POST', '/customers', {
        headers = { ['content-type'] = 'multipart/form-data; boundary=' .. BOUNDARY },
        body = helper.multipart(BOUNDARY, parts),
    })
end

--- Роутер с пределами формы: временные файлы ложатся в свой каталог.
---@param opts table|nil Пределы поверх обычных
---@return any r
---@return string root Каталог временных файлов
local function accepting(opts)
    local root = require('fio').tempdir()
    local limits = { in_memory = 16, temp_dir = root }

    for name, value in pairs(opts or {}) do
        limits[name] = value
    end

    local r = router()

    r.attach({ options = {}, idle_timeout = 30 }, limits)

    return r, root
end

g.test_form_of_the_body_reaches_the_handler = function()
    local r = router()

    r.post('/customers', function(request)
        return r.text(('%s|%s'):format(request.form.name, table.concat(request.form.tag, ',')))
    end)

    local sent = r.dispatch(helper.request('POST', '/customers', {
        headers = { ['content-type'] = 'application/x-www-form-urlencoded' },
        body = 'name=Иван&tag=a&tag=b',
    }))

    t.assert_equals(sent.body, 'Иван|a,b')
end

g.test_uploaded_file_reaches_the_handler_and_is_swept_after_the_answer = function()
    local fio = require('fio')
    local r, root = accepting()
    local seen = {}

    r.post('/customers', function(request)
        local file = request.files.doc

        seen.path = file.path
        seen.body = file:read()
        seen.name = file.name

        return r.text('принято')
    end)

    local sent = r.dispatch(with_parts({
        { name = 'doc', filename = '../отчёт.pdf', body = string.rep('x', 100) },
    }))

    t.assert_equals(sent.body, 'принято')
    t.assert_equals(seen.body, string.rep('x', 100))
    t.assert_equals(seen.name, 'отчёт.pdf')
    -- Временный файл живёт ровно до конца обработки: держать присланное
    -- посторонним дольше ответа незачем.
    t.assert_equals(fio.path.exists(seen.path), false)
    t.assert_equals(fio.listdir(root), {})

    fio.rmtree(root)
end

g.test_uploaded_file_is_swept_even_when_the_handler_falls = function()
    local fio = require('fio')
    local r, root = accepting()

    r.post('/customers', function()
        error('таблицы нет')
    end)

    t.assert_equals(
        r.dispatch(with_parts({
            { name = 'doc', filename = 'отчёт.pdf', body = string.rep('x', 100) },
        })).status,
        500
    )
    t.assert_equals(fio.listdir(root), {})

    fio.rmtree(root)
end

g.test_moved_file_survives_the_sweep = function()
    local fio = require('fio')
    local r, root = accepting()
    local destination

    r.post('/customers', function(request)
        destination = fio.pathjoin(root, 'сохранённый.pdf')

        local moved, err = request.files.doc:move(destination)

        return r.text(tostring(moved or err))
    end)

    t.assert_equals(
        r.dispatch(with_parts({
            { name = 'doc', filename = 'отчёт.pdf', body = string.rep('x', 100) },
        })).body,
        'true'
    )
    -- Перенесённый файл принадлежит тому, кто его перенёс: уборка его
    -- не трогает.
    t.assert_equals(fio.listdir(root), { 'сохранённый.pdf' })

    fio.rmtree(root)
end

g.test_broken_form_is_refused_before_the_route = function()
    local r = router()

    r.post('/customers', function()
        error('до обработчика битая форма доходить не должна')
    end)

    local sent = r.dispatch(helper.request('POST', '/customers', {
        headers = { ['content-type'] = 'multipart/form-data; boundary=' .. BOUNDARY },
        body = 'тело без границ',
    }))

    t.assert_equals(sent.status, 400)
    t.assert_equals(helper.decoded(sent).error.message, 'запрос не разобран')
end

g.test_form_limits_of_attach_hold_for_the_written_request_too = function()
    local r = accepting({ max_fields = 1 })

    r.post('/customers', helper.answering('заведён'))

    local sent = r.dispatch(helper.request('POST', '/customers', {
        headers = { ['content-type'] = 'application/x-www-form-urlencoded' },
        body = 'a=1&b=2',
    }))

    t.assert_equals(sent.status, 413)
end

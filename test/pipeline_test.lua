--- Тесты стыка под конвейер слоёв.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.pipeline')

--- Стык под слои.
---@return any
local function pipeline()
    return helper.part('tnt.router.pipeline')
end

--- Пакета слоёв рядом нет.
local without_middleware = helper.without_middleware

g.test_without_layers_the_handler_is_left_alone = function()
    -- Лишний вызов на каждый запрос ради одинакового исхода — это то,
    -- что потом ищут профилем.
    local handler = helper.answering('готово')

    t.assert_equals(pipeline().wrap({}, handler), handler)
end

g.test_without_layers_nobody_is_asked_about_the_package_of_layers = function()
    -- Пустой список слоёв не повод искать пакет: поиск идёт на каждое
    -- объявление маршрута, а маршрутов без слоёв в приложении больше
    -- всего.
    local asked = false

    helper.part('tnt.router.neighbour')._set_source({
        load = function()
            asked = true

            return false
        end,
    })

    pipeline().wrap({}, helper.answering('готово'))

    t.assert_equals(asked, false)
end

g.test_layers_go_down_in_order_and_come_back_up_the_other_way = function()
    without_middleware()

    local marks = {}

    local wrapped = pipeline().wrap({
        helper.marking(marks, 'первый'),
        helper.marking(marks, 'второй'),
    }, function()
        table.insert(marks, 'обработчик')

        return { status = 200 }
    end)

    t.assert_equals(wrapped({}).status, 200)
    t.assert_equals(marks, {
        'первый:до',
        'второй:до',
        'обработчик',
        'второй:после',
        'первый:после',
    })
end

g.test_layer_that_answers_itself_stops_the_others = function()
    without_middleware()

    local marks = {}

    local wrapped = pipeline().wrap({
        function()
            return { status = 401 }
        end,
        helper.marking(marks, 'второй'),
    }, helper.answering('готово'))

    t.assert_equals(wrapped({}).status, 401)
    t.assert_equals(marks, {})
end

g.test_request_reaches_the_handler_through_the_layers = function()
    without_middleware()

    local wrapped = pipeline().wrap({
        function(request, next)
            request.marked = true

            return next(request)
        end,
    }, function(request)
        return { status = 200, body = tostring(request.marked) }
    end)

    t.assert_equals(wrapped({}).body, 'true')
end

g.test_name_of_a_layer_falls_where_it_is_written_and_not_in_a_request = function()
    -- Имена слоёв разворачивает реестр `tnt.middleware`, и без него имя
    -- не значит ничего. Дожив до запроса, оно сорвалось бы обращением
    -- к строке как к функции — в бою и без объяснения.
    without_middleware()

    -- Без места: строку маршрута приписывает вход роутера.
    t.assert_error_msg_equals(
        'слой №2 объявлен string: имена слоёв разворачивает tnt.middleware, а его нет',
        pipeline().wrap,
        { helper.marking({}, 'первый'), 'timing' },
        helper.answering('готово')
    )

    t.assert_error_msg_contains('слой №1 объявлен table', function()
        pipeline().wrap({ { 'timing' } }, helper.answering('готово'))
    end)
end

g.test_real_package_of_layers_keeps_the_same_order = function()
    -- Договор слоя один и тот же по обе стороны стыка, и проверяется он
    -- против настоящего пакета, если тот поставлен: разойтись запасной
    -- сборке и пакету нельзя, а разойтись они могут молча.
    local ok, middleware = pcall(require, 'tnt.middleware')

    t.skip_if(not ok, 'пакет слоёв не установлен')
    t.assert_not_equals(middleware, nil)

    local marks = {}
    local wrapped = pipeline().wrap({
        helper.marking(marks, 'первый'),
        helper.marking(marks, 'второй'),
    }, helper.answering('готово'))

    t.assert_equals(wrapped({}).body, 'готово')
    t.assert_equals(
        marks,
        { 'первый:до', 'второй:до', 'второй:после', 'первый:после' }
    )
end

g.test_the_middleware_package_is_used_when_it_is_there = function()
    -- Свой конвейер роутер не изобретает: есть пакет слоёв — работа его.
    local asked = {}

    helper.part('tnt.router.neighbour')._set_source({
        load = function(name)
            asked.name = name

            return true,
                {
                    chain = function(layers)
                        asked.layers = layers

                        return {
                            wrap = function(_, handler)
                                asked.handler = handler

                                return function()
                                    return { status = 204 }
                                end
                            end,
                        }
                    end,
                }
        end,
    })

    local layers = { helper.marking({}, 'первый') }
    local handler = helper.answering('готово')

    t.assert_equals(pipeline().wrap(layers, handler)({}).status, 204)
    t.assert_equals(asked.name, 'tnt.middleware')
    t.assert_equals(asked.layers, layers)
    t.assert_equals(asked.handler, handler)
end

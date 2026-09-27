--- Тесты разбора пути и шаблона.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.path')

--- Разбор путей живёт в отдельном модуле.
---@return any
local function path()
    return helper.part('tnt.router.path')
end

g.test_path_is_cut_into_parts_by_slashes = function()
    t.assert_equals(path().split('/customers/7/orders'), { 'customers', '7', 'orders' })
end

g.test_empty_parts_do_not_become_participants = function()
    -- `//customers//7` и `/customers/7` — один адрес: пустой участок
    -- ничего не значит, и заводить на него отдельный маршрут незачем.
    t.assert_equals(path().split('//customers//7//'), { 'customers', '7' })
end

g.test_root_has_no_parts_at_all = function()
    t.assert_equals(path().split('/'), {})
end

g.test_escaped_characters_are_read_back = function()
    t.assert_equals(path().decode('%D0%BA%D0%BB%D0%B8%D0%B5%D0%BD%D1%82'), 'клиент')
end

g.test_percent_without_two_digits_stays_as_written = function()
    -- `100%` в имени файла — не начало кода, и портить его нельзя.
    t.assert_equals(path().decode('100%'), '100%')
end

g.test_slash_inside_a_part_survives_the_cut = function()
    -- Главное свойство разбора: `%2F` — это косая черта внутри участка,
    -- а не разделитель. Режем до раскодирования, раскодируем по одному.
    t.assert_equals(path().segments('/files/a%2Fb'), { 'files', 'a/b' })
end

g.test_value_is_escaped_back_when_the_address_is_built = function()
    t.assert_equals(path().encode('a/b в', false), 'a%2Fb%20%D0%B2')
end

g.test_only_the_unreserved_characters_are_left_alone = function()
    -- Список незарезервированных по RFC 3986 — дефис в нём есть, плюса
    -- в нём нет: плюс в пути значит сам себя, но по пути домой через
    -- чужие посредники он однажды становится пробелом.
    t.assert_equals(path().encode('a-b_c.d~e', false), 'a-b_c.d~e')
    t.assert_equals(path().encode('a+b', false), 'a%2Bb')
end

g.test_tail_keeps_its_slashes_when_escaped = function()
    t.assert_equals(path().encode('a/b в', true), 'a/b%20%D0%B2')
end

g.test_one_address_written_many_ways_has_one_record = function()
    -- Строчные шестнадцатеричные, лишнее кодирование незарезервированного,
    -- пустые участки — запись другая, адрес тот же.
    t.assert_equals(path().canonical('//a/%7e%d0%b2//b/'), '/a/~%D0%B2/b')
    t.assert_equals(path().canonical('/a/~%D0%B2/b'), '/a/~%D0%B2/b')
    t.assert_equals(path().canonical('/a/b+c d'), '/a/b%2Bc%20d')
    t.assert_equals(path().canonical('/'), '/')
    t.assert_equals(path().canonical(''), '/')
end

g.test_slash_inside_a_part_stays_escaped_in_the_record = function()
    -- `/a%2Fb` — один участок, `/a/b` — два, и адреса это разные.
    t.assert_equals(path().canonical('/a%2fb'), '/a%2Fb')
    t.assert_equals(path().canonical('/a/b'), '/a/b')
end

g.test_pattern_is_read_as_static_parts = function()
    local segments = path().compile('/customers/all')

    t.assert_equals(#segments, 2)
    t.assert_equals(segments[1], { kind = 'static', text = 'customers', optional = false })
end

g.test_parameter_is_told_from_a_static_part_by_the_colon = function()
    local segments = path().compile('/customers/:id')

    t.assert_equals(segments[2], { kind = 'param', name = 'id', optional = false })
end

g.test_question_mark_makes_the_parameter_skippable = function()
    local segments = path().compile('/customers/:id?')

    t.assert_equals(segments[2], { kind = 'param', name = 'id', optional = true })
end

g.test_angle_brackets_hold_the_constraint = function()
    local segments = path().compile('/customers/:id<int>')

    t.assert_equals(segments[2], { kind = 'param', name = 'id', optional = false, constraint = 'int' })
end

g.test_constraint_and_question_mark_go_together = function()
    local segments = path().compile('/customers/:id<uuid>?')

    t.assert_equals(segments[2], { kind = 'param', name = 'id', optional = true, constraint = 'uuid' })
end

g.test_star_starts_the_tail = function()
    local segments = path().compile('/files/*rest')

    t.assert_equals(segments[2], { kind = 'wildcard', name = 'rest', optional = true })
end

g.test_escaped_static_part_is_read_back_at_compile_time = function()
    -- Шаблон пишет разработчик, и пробел в нём он напишет кодом.
    t.assert_equals(path().compile('/о%20нас')[1].text, 'о нас')
end

g.test_pattern_without_a_leading_slash_is_refused_at_once = function()
    -- Без места: строку маршрута или группы приписывает вход роутера,
    -- а разбор шаблона стоит от него на разной глубине.
    t.assert_error_msg_equals(
        'шаблон маршрута начинается с косой черты, а не «customers»',
        path().compile,
        'customers'
    )
end

g.test_pattern_that_is_not_a_string_is_refused_at_once = function()
    t.assert_error_msg_contains('начинается с косой черты', function()
        path().compile(7)
    end)
end

g.test_unreadable_part_names_itself_and_the_whole_pattern = function()
    t.assert_error_msg_contains('участок «:» шаблона «/customers/:»', function()
        path().compile('/customers/:')
    end)
end

g.test_parameter_without_a_name_or_without_a_constraint_is_refused = function()
    -- Пустое имя и пустое ограничение выглядят как описка, потому что
    -- ею и являются: значение такого параметра обработчику не достанется,
    -- а пустого ограничения не существует вовсе.
    for _, pattern in ipairs({ '/customers/:<int>', '/customers/:id<>', '/customers/:?' }) do
        t.assert_error_msg_contains('не разобран', function()
            path().compile(pattern)
        end)
    end
end

g.test_nameless_tail_is_refused = function()
    -- Звёздочка без имени — это забытое имя: значение такого хвоста
    -- обработчику взять неоткуда.
    t.assert_error_msg_contains('остался без имени', function()
        path().compile('/files/*')
    end)
end

g.test_tail_in_the_middle_is_refused = function()
    t.assert_error_msg_contains('бывает только последним', function()
        path().compile('/files/*rest/name')
    end)
end

g.test_same_name_twice_is_refused = function()
    -- Второе значение затёрло бы первое, и обработчик получил бы одно
    -- вместо двух — молча.
    t.assert_error_msg_contains('назван дважды', function()
        path().compile('/customers/:id/orders/:id')
    end)
end

g.test_required_part_after_a_skippable_one_is_refused = function()
    t.assert_error_msg_contains('стоит обязательный', function()
        path().compile('/customers/:id?/orders')
    end)
end

g.test_tail_after_a_skippable_part_is_allowed = function()
    -- Хвост и сам необязателен, и порядок здесь не ломается.
    t.assert_equals(#path().compile('/files/:kind?/*rest'), 3)
end

g.test_address_is_built_back_from_the_pattern = function()
    t.assert_equals(path().render(path().compile('/customers/:id/orders'), { id = 7 }), '/customers/7/orders')
end

g.test_missing_parameter_names_itself_in_the_refusal = function()
    local built, err = path().render(path().compile('/customers/:id'), {})

    t.assert_equals(built, nil)
    t.assert_equals(err, 'не задан параметр «id»')
end

g.test_skippable_parameter_simply_disappears_from_the_address = function()
    t.assert_equals(path().render(path().compile('/customers/:id?'), {}), '/customers')
end

g.test_root_is_built_when_there_is_nothing_to_put_in_it = function()
    t.assert_equals(path().render(path().compile('/'), nil), '/')
end

g.test_slash_written_in_a_static_part_stays_inside_it = function()
    -- Участок `о%2Fнас` — это один участок с косой чертой внутри,
    -- и собранный обратно адрес обязан остаться таким же.
    t.assert_equals(path().render(path().compile('/о%2Fнас'), nil), '/%D0%BE%2F%D0%BD%D0%B0%D1%81')
end

g.test_value_with_a_slash_does_not_become_two_parts = function()
    t.assert_equals(path().render(path().compile('/files/:name'), { name = 'a/b' }), '/files/a%2Fb')
end

g.test_tail_value_keeps_its_slashes = function()
    t.assert_equals(path().render(path().compile('/files/*rest'), { rest = 'a/b' }), '/files/a/b')
end

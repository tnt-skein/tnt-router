--- Тесты ограничений на параметры пути.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.constraints')

--- Ограничения.
---@return any
local function constraints()
    return helper.part('tnt.router.constraints')
end

--- Проверяльщика нет: пакет ставится отдельно и может не стоять.
local function without_validate()
    helper.part('tnt.router.neighbour')._set_source({
        load = function(name)
            return false, ('модуля %s нет'):format(name)
        end,
    })
end

--- Опознаватель, записанный как положено.
local UUID = '4f1e4d1e-0a2b-4c3d-8e9f-0a1b2c3d4e5f'

--- Что каждому ограничению подходит, а что нет.
---
--- Один и тот же список проверяется дважды: правилом проверяльщика
--- и запасным образцом. Расхождение между ними значило бы, что адрес
--- открывается или не открывается смотря по тому, поставлен ли соседний
--- пакет, — а это худший вид неожиданности.
local CASES = {
    { constraint = 'int', value = '7', fits = true },
    { constraint = 'int', value = '-7', fits = true },
    { constraint = 'int', value = '+7', fits = false },
    { constraint = 'int', value = '7.5', fits = false },
    { constraint = 'int', value = '0x10', fits = false },
    { constraint = 'int', value = 'семь', fits = false },
    { constraint = 'int', value = '', fits = false },
    { constraint = 'uuid', value = UUID, fits = true },
    { constraint = 'uuid', value = UUID:upper(), fits = true },
    { constraint = 'uuid', value = '4f1e4d1e-0a2b-4c3d-8e9f', fits = false },
    { constraint = 'uuid', value = '', fits = false },
    { constraint = 'alpha', value = 'client', fits = true },
    { constraint = 'alpha', value = 'client-7', fits = false },
    { constraint = 'alpha', value = '', fits = false },
    { constraint = 'slug', value = 'client-7', fits = true },
    { constraint = 'slug', value = 'client 7', fits = false },
    { constraint = 'slug', value = '', fits = false },
}

--- Прогоняет весь список и называет то, что не сошлось.
local function verify()
    for _, case in ipairs(CASES) do
        local check = constraints().resolve(case.constraint)
        local about = ('%s(«%s»)'):format(case.constraint, case.value)

        t.assert_equals(check(case.value), case.fits, about)
    end
end

g.test_known_constraints_are_named_out_loud = function()
    -- По этому списку пишут шаблоны, и молчаливое исчезновение имени
    -- из него однажды превратило бы маршрут в отказ при загрузке.
    t.assert_equals(constraints().names(), { 'alpha', 'int', 'slug', 'uuid' })
end

g.test_rule_of_the_validator_draws_the_line_where_it_is_drawn = function()
    verify()
end

g.test_spare_check_draws_the_very_same_line = function()
    without_validate()

    verify()
end

g.test_letters_mean_latin_letters_and_this_is_said_out_loud = function()
    -- Образцы Lua считают байтами: кириллица для них не буква. Знать
    -- об этом лучше здесь, чем в день, когда `/города/:name<alpha>`
    -- отвечает 404 на все города разом.
    t.assert_equals(constraints().resolve('alpha')('клиент'), false)
end

g.test_own_check_is_taken_as_it_is = function()
    local check = constraints().resolve(function(value)
        return value == 'тот самый'
    end)

    t.assert_equals(check('тот самый'), true)
    t.assert_equals(check('не тот'), false)
end

g.test_unknown_constraint_falls_where_the_route_is_declared = function()
    -- Без места: строку маршрута приписывает вход роутера.
    t.assert_error_msg_equals(
        'нет такого ограничения: число',
        constraints().resolve,
        'число'
    )
end

g.test_validator_is_asked_for_only_once_per_route = function()
    -- Проверка собирается при объявлении маршрута, а не при запросе:
    -- искать модуль на каждый запрос значит платить за это всегда.
    local asked = 0

    helper.part('tnt.router.neighbour')._set_source({
        load = function()
            asked = asked + 1

            return false
        end,
    })

    local check = constraints().resolve('int')

    check('7')
    check('8')

    t.assert_equals(asked, 1)
end

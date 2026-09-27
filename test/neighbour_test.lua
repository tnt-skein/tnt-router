--- Тесты подключения соседних пакетов.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.neighbour')

--- Подключение соседей.
---@return any
local function neighbour()
    return helper.part('tnt.router.neighbour')
end

g.test_package_that_is_there_comes_back_whole = function()
    t.assert_equals(neighbour().of('tnt.validate'), helper.part('tnt.validate'))
end

g.test_package_that_is_not_there_is_a_nil_and_not_a_fall = function()
    -- Пакеты ставятся по одному, и роутер, потребовавший соседа,
    -- не поднялся бы вовсе.
    t.assert_equals(neighbour().of('tnt.такого.нет'), nil)
end

g.test_loading_goes_through_the_externals = function()
    neighbour()._set_source({
        load = function(name)
            return true, { asked = name }
        end,
    })

    t.assert_equals(neighbour().of('tnt.middleware'), { asked = 'tnt.middleware' })
end

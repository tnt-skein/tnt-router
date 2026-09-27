--- Ограничения на параметр пути.
---
--- `/customers/:id<int>` не должен совпадать с `/customers/новый`. Важно
--- не то, что это отсеивается, а то, чем отвечает узел: несовпавшее
--- ограничение — это «нет такого адреса», код 404, а не 500 из глубины
--- обработчика, которому подсунули строку вместо числа, и не 400,
--- о котором клиенту нечего сказать.
---
--- Отбор идёт до обработчика и не заканчивает поиск: за `:id<int>` может
--- стоять постоянный `/customers/new`, и он-то и подойдёт.
---
--- Проверяет `tnt.validate`: правила, которыми приложение проверяет тело
--- запроса, и правила, которыми роутер отбирает путь, — одни и те же,
--- и расходиться им незачем. Пакета может не оказаться рядом — пакеты
--- ставятся по одному, — поэтому у каждого ограничения есть запасная
--- проверка образцом. Она проще правила и годится ровно на то, чтобы
--- роутер не перестал работать без соседа.
---
--- Незнакомое имя ограничения бросается без места (`fail.raise`): место —
--- строку маршрута — приписывает вход роутера (`tnt.router.blame`).

local fail = require('tnt.must.fail')

local neighbour = require('tnt.router.neighbour')

local Module = {}

--- Запасные проверки образцом: на случай, когда `tnt.validate` не стоит.
---
--- Целое со знаком, а не без: идентификаторы бывают отрицательными,
--- и отсекать минус здесь значит прятать от обработчика половину
--- возможных значений.
---
--- `alpha` — это буквы латиницы и только они: образцы Lua считают
--- байтами, и кириллица для них не буква. Для русских слов в пути
--- ограничение пишется своей функцией.
local PATTERNS = {
    int = '^%-?%d+$',
    uuid = '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$',
    alpha = '^%a+$',
    slug = '^[%w%-_]+$',
}

--- Правило `tnt.validate` по имени ограничения.
---
--- Число в пути — это цифры со знаком, а не всё, что Lua умеет прочесть
--- числом: и `0x10`, и « 7» для `tonumber` числа, но адрес с ними не тот,
--- который имел в виду писавший маршрут. Поэтому число проверяется
--- образцом, а не приведением, — и правило сходится с запасной проверкой
--- знак в знак.
---@param validate any
---@param name string
---@return any
local function rule_of(validate, name)
    if name == 'uuid' then
        -- Опознаватель у проверяльщика свой: он ещё и приводит запись
        -- к нижнему регистру, а образец только сверяет.
        return validate.uuid()
    end

    return validate.string({ pattern = PATTERNS[name] })
end

--- Имена известных ограничений по порядку.
---@return string[]
function Module.names()
    local names = {}

    for name in pairs(PATTERNS) do
        table.insert(names, name)
    end

    table.sort(names)

    return names
end

--- Готовая проверка значения по ограничению.
---
--- Своя проверка функцией разрешена и передаётся как есть: ограничений
--- на все случаи не напасёшься, а «идентификатор существующего склада» —
--- это уже не образец.
---@param constraint string|fun(value: string): boolean
---@return fun(value: string): boolean
function Module.resolve(constraint)
    if type(constraint) == 'function' then
        return constraint
    end

    local pattern = PATTERNS[constraint]

    if pattern == nil then
        fail.raise(('нет такого ограничения: %s'):format(tostring(constraint)))
    end

    local validate = neighbour.of('tnt.validate')

    if validate == nil then
        return function(value)
            return value:find(pattern) ~= nil
        end
    end

    local rule = rule_of(validate, constraint)

    return function(value)
        local _, errors = validate.check(value, rule)

        return errors == nil
    end
end

return Module

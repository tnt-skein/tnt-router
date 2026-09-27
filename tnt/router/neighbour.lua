--- Подключение соседнего пакета, которого может и не быть.
---
--- Роутер отдаёт соседям два дела: проверку значений — `tnt.validate`,
--- сборку слоёв — `tnt.middleware`. Ни того, ни другого может не оказаться
--- рядом: пакеты ставятся по одному, и роутер, потребовавший соседа,
--- не поднялся бы вовсе.
---
--- Отдельным модулем, а не парой строк в каждом месте: подключение идёт
--- через внешнюю зависимость, иначе ветку «пакета нет» нечем проверить — а она и есть
--- та, ради которой написан весь запасной путь.

local external = require('tnt.external')

local Module = {}

--- Средства снаружи: само подключение.
local DEFAULTS = {
    load = function(name)
        return pcall(require, name)
    end,
}

local source = external.install(Module, DEFAULTS)

--- Соседний пакет или `nil`, если его не поставили.
---@param name string
---@return any|nil
function Module.of(name)
    local ok, module = source().load(name)

    if not ok then
        return nil
    end

    return module
end

return Module

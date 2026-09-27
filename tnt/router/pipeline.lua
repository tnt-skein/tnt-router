--- Стык под конвейер слоёв.
---
--- Слои — отдельный пакет (`tnt.middleware`): у него свой порядок, свои
--- имена, свои готовые слои и свои правила перестановки. Роутер знает
--- о них ровно одно: список, объявленный на группе или на маршруте, надо
--- превратить в обёртку вокруг обработчика. Как именно — решает тот
--- пакет, и зовётся он лениво: роутер обязан работать и без него.
---
--- Договор слоя один и тот же по обе стороны стыка: функция
--- `(request, next)`. Всё до `next` случается на входе, всё после —
--- на выходе, а не позвав `next`, слой отвечает сам. Имя объявленного
--- слоя и пара «имя с настройками» тоже годятся — но их разворачивает
--- реестр соседнего пакета, и без него они не значат ничего.
---
--- Запасная сборка — шесть строк ровно того же договора. Без неё роутер,
--- рядом с которым пакета слоёв ещё нет, не смог бы объявить ни одной
--- группы со слоями, а объявляют их в первый же день. Изобретать поверх
--- неё имена, порядок и перестановки не нужно: это чужая работа.
---
--- Негодный слой — промах в строке приложения, и место отказа — строку
--- маршрута, группы или `router.new` — приписывает вход роутера
--- (`tnt.router.blame`). Поэтому здесь отказ бросается без места: и свой,
--- и отказ пакета слоёв.

local fail = require('tnt.must.fail')

local blame = require('tnt.router.blame')
local neighbour = require('tnt.router.neighbour')

local Module = {}

--- Запасная сборка цепочки: слои наизнанку, последний ближе к обработчику.
---
--- Понимает только функции: имя объявленного слоя разворачивает реестр
--- `tnt.middleware`, а его рядом нет — иначе сюда бы не пришли. Имя,
--- дожившее до запроса, сорвалось бы обращением к строке как к функции,
--- и искать причину пришлось бы в бою; здесь оно падает там, где
--- написано, — при объявлении маршрута.
---@param layers TntRouterLayer[]
---@param handler fun(request: table): any
---@return fun(request: table): any
local function stacked(layers, handler)
    local wrapped = handler

    for index = #layers, 1, -1 do
        local layer = layers[index]

        if type(layer) ~= 'function' then
            fail.raise(
                ('слой №%d объявлен %s: имена слоёв разворачивает tnt.middleware, а его нет'):format(
                    index,
                    type(layer)
                )
            )
        end
        local nested = wrapped

        wrapped = function(request)
            return layer(request, nested)
        end
    end

    return wrapped
end

--- Оборачивает обработчик слоями.
---
--- Пустой список отдаёт обработчик как есть: лишний вызов на каждый
--- запрос ради одинакового исхода — это то, что потом ищут профилем.
---@param layers TntRouterLayer[]
---@param handler fun(request: table): any
---@return fun(request: table): any
function Module.wrap(layers, handler)
    if #layers == 0 then
        return handler
    end

    local middleware = neighbour.of('tnt.middleware')

    if middleware == nil then
        return stacked(layers, handler)
    end

    -- Вход пакета слоёв винит того, кто его позвал, и позванный отсюда
    -- назвал бы эту строку. Через `bare` он винит кадр без строки, и его
    -- отказ — незнакомое имя слоя — выходит без места.
    local chain = blame.bare(middleware.chain, layers)

    return chain:wrap(handler)
end

return Module

--- Страницы: ответ страницей по движку, одним её куском и потоком.
---
--- Роутер не знает, чем рисуют страницы: движок приходит настройкой `view`
--- при заведении, и от него нужен только `render(name, data)`. Кусок
--- страницы (`fragment`) и страница потоком (`stream`) — по надобности:
--- движок без них годится для `view`, а помощник, которому их не хватило,
--- отказывает словом, называющим недостающее.
---
--- Договор о типе содержимого у всех трёх один — `text/html;
--- charset=utf-8`. Кусок страницы — тот же HTML, что и страница: браузер
--- вставляет его в открытую страницу и читает в той же кодировке.
--- У страницы потоком тип не выводится из кусков, и без названного она
--- ушла бы потоком байтов — браузер скачал бы её файлом.
---
--- **Общие данные страниц — настройка `view_data`**: функция от запроса,
--- её таблица ложится под данные обработчика у всех трёх помощников.
--- Токен формы, вошедший посетитель, язык страницы нужны каждой странице,
--- и носи их каждый обработчик сам, забытое поле нашлось бы только
--- открытием той самой страницы — ответом 500. Данные обработчика главнее
--- подмешанных: страница, которой нужно своё значение, кладёт его сама.
---
--- Считаются они на каждый вызов помощника, а не при заведении и не на
--- каждый запрос: токен у каждой сессии свой, а ответу JSON незачем
--- заводить сессии токен, которого он не покажет.
---
--- Помощника зовут без запроса — `web.view(name, data)`, — поэтому запрос,
--- на который роутер отвечает, лежит в хранилище файбера (`served`).
--- Ключ — сам роутер: помощник другого роутера чужого запроса не видит.
--- Вне ответа на запрос — помощник позван из проверки или из файбера,
--- заведённого обработчиком, — запроса нет, и подмешивать нечего.
---
--- Способы живут здесь, а не в фасаде: у страниц своя забота — движок
--- и его договор, — и фасад только раздаёт их экземпляру.

local fiber = require('fiber')

local fail = require('tnt.must.fail')

local response = require('tnt.router.response')

local Module = {}

--- Движок страниц роутера, умеющий названное.
---
--- Бросок — ошибка того, кто собирал роутер: страница без движка
--- и кусок у движка без кусков не случаются от запроса, — и бросается
--- словом без места, как у прочих отказов настройки страниц.
---@param self table Роутер
---@param method string Что движок должен уметь
---@return table engine
local function engine_of(self, method)
    local engine = self.settings.view

    if engine == nil then
        fail.raise('страницы не настроены: нужен view в router.new')
    end

    if type(engine[method]) ~= 'function' then
        fail.raise(('движок страниц не умеет %s'):format(method))
    end

    return engine
end

--- Отвечает на запрос, держа его для общих данных страниц.
---
--- Держится запрос на время всего ответа, а не одного обработчика:
--- страницу рисуют и слой входа, и обработчик отказов, и данные у всех
--- обязаны быть одни. Держится тот запрос, что пришёл на вход: слои
--- кладут своё в него же, полями, — сессию, личность, — и `view_data`
--- видит их поля. Прежний запрос возвращается на место: обработчик
--- вправе позвать `dispatch` того же роутера, и после вложенного ответа
--- его собственная страница обязана видеть свой запрос, а не вложенный.
---@param self table Роутер
---@param request table
---@param serve fun(self: table, request: table): table Ответ на запрос; не бросает — всё бросающее под pcall
---@return table response
function Module.served(self, request, serve)
    local storage = fiber.self().storage
    local previous = storage[self]

    storage[self] = request

    local answered = serve(self, request)

    storage[self] = previous

    return answered
end

--- Данные страницы: общие данные запроса, поверх — данные обработчика.
---
--- Сливаются в новую таблицу: обе таблицы чужие, а обработчик вправе
--- отдавать одну и ту же на каждый запрос — токен, подмешанный в неё,
--- уехал бы в страницу другому посетителю.
---
--- Отказ `view_data` парой `nil, err` уходит той же парой: обработчик,
--- вернувший её, отвечает отказом по договору границы HTTP. Пустота же
--- и не таблица — поломка, и она бросается: так её видит тот, кто писал
--- `view_data`, на первом же показе страницы.
---@param self table Роутер
---@param data table|nil Данные обработчика
---@return table|nil data
---@return any err
local function page_data(self, data)
    local view_data = self.settings.view_data

    if view_data == nil then
        return data
    end

    local request = fiber.self().storage[self]

    if request == nil then
        return data
    end

    local shared, err = view_data(request)

    if err ~= nil and shared == nil then
        return nil, err
    end

    if type(shared) ~= 'table' then
        fail.raise(
            ('view_data вернула %s, а не таблицу данных страницы'):format(type(shared))
        )
    end

    local merged = {}

    for name, value in pairs(shared) do
        merged[name] = value
    end

    for name, value in pairs(data or {}) do
        merged[name] = value
    end

    return merged
end

local Methods = {}

--- Страница по имени шаблона — ответом HTML.
---@param self table
---@param name string Имя шаблона
---@param data table|nil Данные страницы
---@param status integer|nil Код ответа; по умолчанию 200
---@param headers table|nil Свои заголовки
---@return table|nil response
---@return any err Отказ `view_data`
function Methods.view(self, name, data, status, headers)
    local engine = engine_of(self, 'render')
    local page, err = page_data(self, data)

    if err ~= nil then
        return nil, err
    end

    return response.html(engine:render(name, page), status, headers)
end

--- Один кусок страницы — ответом HTML: страница рисуется с теми же
--- данными, а уходит только кусок `section`, без рамки.
---
--- Какой кусок нужен, решает обработчик. Выбирает он его по заголовку
--- запроса — тогда тот же адрес отвечает двумя видами, и заголовок
--- называется в `vary`: иначе кэш по дороге отдаст кусок тому, кто
--- открыл страницу, и наоборот.
---@param self table
---@param name string Имя шаблона страницы
---@param section string Имя куска
---@param data table|nil Данные страницы
---@param status integer|nil
---@param headers table|nil
---@return table|nil response
---@return any err Отказ `view_data`
function Methods.fragment(self, name, section, data, status, headers)
    local engine = engine_of(self, 'fragment')
    local page, err = page_data(self, data)

    if err ~= nil then
        return nil, err
    end

    return response.html(engine:fragment(name, section, page), status, headers)
end

--- Страница потоком — ответом по кускам с типом страницы.
---
--- Первый кусок движок рисует сразу: ошибка страницы до него — обычный
--- отказ 500, после — обрыв ответа без завершающего куска. Общие данные
--- считаются тут же, при вызове: остаток страницы движок рисует уже
--- после ответа, когда запроса в файбере нет.
---@param self table
---@param name string Имя шаблона страницы
---@param data table|nil Данные страницы
---@param status integer|nil
---@param headers table|nil
---@return table|nil response
---@return any err Отказ `view_data`
function Methods.view_stream(self, name, data, status, headers)
    local engine = engine_of(self, 'stream')
    local page, err = page_data(self, data)

    if err ~= nil then
        return nil, err
    end

    return response.html_stream(engine:stream(name, page), status, headers)
end

Module.METHODS = Methods

return Module

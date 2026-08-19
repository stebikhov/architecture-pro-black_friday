# Архитектурный документ: Проектирование базы данных для онлайн-магазина «Мобильный мир»

## Задание 7. Проектирование схем коллекций для шардирования данных

Шардированный кластер MongoDB. Используем топологию:
mongos (роутеры) → config-серверы (replica set из 3 узлов) → N шардов, каждый из которых — replica set из 3 узлов (primary + 2 secondary). Это даёт одновременно и масштабирование записи (шардирование), и отказоустойчивость с масштабированием чтения (репликация). Дополнительно применяется Redis для кеширования каталога товаров, чтобы снизить нагрузку на шардированный кластер при частых чтениях по категориям.

### Коллекция products

**Схема:**

```javascript
{
  "_id": ObjectId,           // внутренний идентификатор MongoDB
  "product_id": ObjectId,    // бизнес-идентификатор товара, используется как shard key
  "name": String,
  "category": String,
  "price": Number,
  "stock": [
    { "geo_zone": String, "qty": Number }
  ],
  "attributes": {
    "color": String,
    "size": String
  },
  "created_at": Date,
  "updated_at": Date
}
```

Кандидаты в шард-ключ: product_id, _id, category, {category, price}.

**Шард-ключ:** `{ product_id: "hashed" }`

**Обоснование:**

- `product_id` имеет высокую кардинальность и равномерно распределяет товары по шардам
- Хэширование по `product_id` не привязывает популярную категорию, например «Электроника», к одному диапазону и снижает риск горячего шарда
- Поиск по категории и цене не является targeted-запросом; это компенсируется вторичным индексом {category, price} на каждом шарде и кешированием в Redis (TTL 5–15 минут, инвалидация по событию обновления товара)
- Запросы каталога по `category/price` могут обращаться к нескольким шардам, зато записи и обновления остатков распределяются стабильнее

**Команда шардирования:**

```javascript
sh.shardCollection("shop.products", { product_id: "hashed" });
```

**Индексы для основных операций:**

```javascript
db.products.createIndex({ category: 1, price: 1 });
```

### Коллекция orders

**Схема:**

```javascript
{
  "_id": ObjectId,
  "customer_id": ObjectId,
  "order_date": Date,
  "items": [
    {
      "product_id": ObjectId,
      "price": Number,
      "quantity": Number
    }
  ],
  "status": String,      // created | paid | shipped | delivered | cancelled
  "geo_zone": String,    // msk, spb, ekb, kgd ...
  "total_amount": Number,
  "created_at": Date
}
```

Кандидаты в шард-ключ: customer_id, _id, geo_zone, order_date.

**Шард-ключ:** `{ customer_id: "hashed" }`

**Обоснование:**

- Заказы естественным образом группируются по клиентам
- Хэширование обеспечивает равномерное распределение
- Эффективен поиск истории заказов конкретного пользователя
- Статус заказа лучше запрашивать вместе с `customer_id`
- Для поиска только по `_id` стоит добавить отдельную read model `orders_by_id` или всегда передавать `customer_id` из пользовательского контекста

**Команда шардирования:**

```javascript
sh.shardCollection("shop.orders", { customer_id: "hashed" });
```

**Индексы для основных операций:**

```javascript
db.orders.createIndex({ customer_id: 1, order_date: -1 });
```

### Коллекция carts

**Схема:**

```javascript
{
  "_id": ObjectId,
  "owner_key": String, // ключ: `user:<user_id>` для авторизованного пользователя или `session:<session_id>` для гостя
  "user_id": ObjectId, // optional — только для авторизованных пользователей
  "session_id": String, // optional — только для гостей
  "items": [
    {
      "product_id": ObjectId,
      "quantity": Number
    }
  ],
  "status": String, // active | ordered | abandoned
  "created_at": Date,
  "updated_at": Date,
  "expires_at": Date
}
```

Кандидаты в шард-ключ: user_id, session_id, owner_key, _id.

**Шард-ключ:** `{ owner_key: "hashed" }`

**Обоснование:**

- `owner_key` нормализует владельца корзины в один обязательный ключ: `user:<user_id>` для авторизованного пользователя или `session:<session_id>` для гостя
- Один shard key работает для пользовательских и гостевых корзин, без альтернативных ключей для одной коллекции
- Получение активной корзины по владельцу выполняется эффективно через индекс `{ owner_key: 1, status: 1 }`
- При логине гостевая корзина читается по `session:<session_id>`, товары добавляются в корзину `user:<user_id>`, после чего гостевая корзина устанавливается в `abandoned`
- При записи корзины приложение всегда формирует `owner_key`: для авторизованного пользователя `owner_key = "user:" + user_id`, для гостя `owner_key = "session:" + session_id`

**Команда шардирования:**

```javascript
sh.shardCollection("shop.carts", { owner_key: "hashed" });
```

**Индексы для основных операций:**

```javascript
db.carts.createIndex({ owner_key: 1, status: 1 });
db.carts.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 }); // TTL-очистка
```

**Примечание:** TTL-индекс удалит корзину по достижении `expires_at`, включая активные корзины. Приложение продлевает `expires_at` при каждом обновлении активной корзины, чтобы TTL-очистка затрагивала только заброшенные корзины (`abandoned`).

---

## Задание 8. Выявление и устранение «горячих» шардов

### Метрики мониторинга

**Основные метрики для отслеживания:**

| №   | Метрика                                                                       | Что показывает                                                     | Источник диагностики / команда                                                                                                                      | Порог тревоги                                                                                              |
| --- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| 1   | **Операции в секунду (ops/sec)** на каждом шарде — insert/query/update/delete | Неравномерность нагрузки, «горячий» шард                           | `mongostat --discover`, `db.serverStatus().opcounters`, Prometheus mongodb_exporter (`mongodb_op_counters_total`)                                   | Шард принимает > 1.5× среднего ops/sec по кластеру дольше 10 минут                                         |
| 2   | **Задержка операций (latency)** — p50, p95, p99 по чтениям и записям          | Деградация отклика на конкретном шарде                             | `db.serverStatus().opLatencies`, `db.setProfilingLevel(1, { slowms: 100 })` + `db.system.profile`, экспортер (`mongodb_op_latencies_latency_total`) | p99 > 2× baseline; p95 записи > 100 мс                                                                     |
| 3   | **Использование CPU и памяти** на каждом узле                                 | Насыщение ресурсов узла, риск отказа                               | `node_exporter` (`node_cpu_seconds_total`, `node_memory_*`), `docker stats`, `top`                                                                  | CPU > 80% в течение 5 мин; RSS mongod > 90% лимита                                                         |
| 4   | **Размер данных на каждом шарде**                                             | Перекос хранения (data skew)                                       | `db.products.getShardDistribution()`, `db.products.stats()`, `sh.status()`                                                                          | Разница объёма между шардами > 20%                                                                         |
| 5   | **Количество запросов в очереди** (queued readers/writers, доступные tickets) | Шард не успевает обрабатывать поток операций                       | `db.serverStatus().globalLock.currentQueue`, `serverStatus().wiredTiger.concurrentTransactions` (для MongoDB 7.0+ — `serverStatus().queues.execution`)                                                     | Очередь > 50 операций; доступных tickets < 20%                                                             |
| 6   | **Балансировка данных между шардами** (статус и ошибки балансировщика)        | Работает ли автоперераспределение, нет ли зависших миграций        | `sh.getBalancerState()`, `sh.isBalancerRunning()`, `db.getSiblingDB("config").changelog.find({what: /moveChunk/})`                                  | Миграции падают подряд ≥ 3 раз; балансировщик выключен вне планового окна                                  |
| 7   | **Количество чанков на шард и скорость миграции чанков**                      | Дисбаланс чанков, jumbo chunks, «застрявшие» миграции              | `sh.status()`, агрегация по `config.chunks` (`$group: { _id: "$shard", chunks: { $sum: 1 } }`), флаг `jumbo`                                        | Разница чанков между шардами > порога балансировщика (2/4/8 в зависимости от числа чанков коллекции, для MongoDB < 6.0; начиная с 6.0 балансировка по разнице объёма данных, порог — 3 × 128 МБ = 384 МБ); jumbo chunks > 0; миграция одного чанка > 10 мин |
| 8   | **Replication lag** между primary и secondary в каждом replica set шарда      | Устаревшие чтения с реплик, риск потери данных при failover        | `rs.printSecondaryReplicationInfo()`, `rs.status()`, экспортер (`mongodb_replset_member_optime_date`)                                               | Lag > 10 с; secondary в состоянии RECOVERING/DOWN                                                          |
| 9   | **Disk IOPS и network I/O** на узлах шарда                                    | Узкое место в дисковой или сетевой подсистеме конкретного шарда    | `node_exporter` (`node_disk_io_time_seconds_total`, `node_network_*_bytes_total`), `iostat`, `iftop`                                                | IOPS > 80% лимита диска; disk util > 90%; сеть > 70% пропускной способности                                |
| 10  | **WiredTiger cache** — dirty/used bytes и eviction rate                       | Кеш не справляется, начинается агрессивный eviction и рост latency | `db.serverStatus().wiredTiger.cache` (`bytes currently in the cache`, `tracked dirty bytes`, `pages evicted by application threads`)                | Dirty > 5% кеша; used > 95%; eviction в application threads > 0 стабильно                                  |

Перекос по метрикам 1–2 при нормальных 4 и 7 означает «горячий ключ» (лечится refine/reshard ключа), а перекос одновременно по 4 и 7 — дисбаланс чанков (лечится балансировщиком, split + moveChunk). Метрики 3, 5, 9, 10 показывают, что именно упирается на перегруженном шарде: CPU, очередь, диск или кеш WiredTiger. Метрика 8 обязательна перед включением чтения с реплик (задание 9) — при lag > 10 с срабатывает тревога мониторинга; автоматическое исключение secondary драйвером происходит только при staleness > 90 с (минимально допустимое значение `maxStalenessSeconds`). В диапазоне 10–90 с реагирует дежурный: возможен ручной перевод критичных чтений на primary.

### Механизмы автоматического перераспределения

**1. Балансировщик MongoDB:**

Активируем балансировщик, если он был остановлен. По умолчанию он обычно включён.

```javascript
// Включение автоматической балансировки
sh.startBalancer();

// Проверка состояния балансировщика
sh.getBalancerState(); // текущее состояние балансировщика
sh.status(); // распределение чанков и активные миграции
```

**2. Предварительное разделение данных:**

Разделение диапазонов ключей шардирования (key ranges) и перемещение чанков до массовой загрузки данных, чтобы избежать «горячих точек» (hotspots) при старте: если сначала загрузить все данные, балансировщик будет вынужден массово перемещать чанки, создавая нагрузку. Предварительное разбиение позволяет распределить данные более плавно.

```javascript
// Иллюстрация для range-based шард-ключа (например, { category: 1, price: 1 }):
// sh.splitAt("shop.products", { category: "Электроника", price: 5000 });
// sh.moveChunk("shop.products", { category: "Электроника", price: 5000 }, "shard2");
```

**3. Использование зон (zones) для шардов:**

Механизм зон позволяет назначать шардам зоны и привязывать диапазоны ключей к зонам. Это даёт возможность управлять размещением данных на основе бизнес-правил для географической локализации данных, соблюдения требований регуляторов (например, хранение персональных данных в определённом регионе), оптимизации производительности (размещение «горячих» данных на быстрых дисках) или разделения нагрузки по типам данных.

**Важно:** при `hashed` шард-ключе (`{ product_id: "hashed" }`) зонирование по диапазонам значений невозможно — хэш не сохраняет семантику исходного ключа. Тегирование применимо к шард-ключам на основе диапазонов. Например, если бы заказы шардировались по `{ geo_zone: 1, customer_id: 1 }`, можно было бы привязать гео-зоны к шардам:

```javascript
// Назначение зон шардам (пример для range-based ключа)
sh.addShardToZone("shard1", "msk");
sh.addShardToZone("shard2", "spb");

// Привязка диапазонов к зонам
sh.updateZoneKeyRange(
  "shop.orders",
  { geo_zone: "msk", customer_id: MinKey },
  { geo_zone: "msk", customer_id: MaxKey },
  ["msk"],
);
```

### Профилактика горячих шардов

**1. Правильный выбор шард-ключа:**

- Использовать для хэширования поля с высокой кардинальностью и равномерным распределением
- Избегать для шардирования монотонно возрастающих значений, например время (timestamp) или автоматически увеличивающиеся ID — из‑за них все новые данные будут попадать на один и тот же шард, и он быстро «перегрузится».

**2. Предварительное разделение:**

Для hashed-ключа пре-сплиттинг через `sh.splitAt` с сырыми значениями не работает. Вместо этого используется `numInitialChunks` при создании шардированной коллекции (вариант с `numInitialChunks` также приведён в команде шардирования коллекции `products` в задании 7):

```javascript
// Создание коллекции с предварительным разделением на 100 чанков
// применяется вместо базового sh.shardCollection при первичном создании коллекции
sh.shardCollection("shop.products", { product_id: "hashed" }, false, { numInitialChunks: 100 });
```

**Примечание:** опция `numInitialChunks` применима в MongoDB до версии 6.x; начиная с 7.0 она удалена — начальное распределение hashed-чанков выполняется автоматически, дальнейшее выравнивание обеспечивает балансировщик.

**3. Мониторинг:**

Подсчёт количества чанков для каждого шарда позволяет быстро оценить, насколько равномерно распределены чанки между шардами. Если на одном шарде 10 чанков, а на другом — 100, это явный признак дисбаланса, который может влиять на производительность.

```javascript
// Скрипт для проверки баланса (MongoDB 5.0+, с учётом uuid вместо ns)
var coll = db.getSiblingDB("config").collections.findOne({ _id: "shop.products" });
var chunks = db.getSiblingDB("config").chunks
  .aggregate([
    { $match: { uuid: coll.uuid } },
    { $group: { _id: "$shard", count: { $sum: 1 } } }
  ])
  .toArray();
printjson(chunks);
```

---

## Задание 9. Настройка чтения с реплик и консистентность

### Таблица операций чтения и записи

| Коллекция    | Операция                                 | Primary/Secondary | Read concern / Write concern / допустимый lag | Обоснование                                                                    |
| ------------ | ---------------------------------------- | ----------------- | --------------------------------------------- | ------------------------------------------------------------------------------ |
| **products** | Поиск товаров по категории               | Secondary         | readConcern: `local` / до 90 сек              | readConcern: local; допустима небольшая задержка, данные обновляются редко                         |
| **products** | Чтение остатков при покупке              | Primary           | readConcern: `majority` / 0 сек               | readConcern: majority; требуется актуальная информация об остатке перед покупкой                          |
| **products** | Списание остатков при покупке            | Primary           | writeConcern: `majority` / 0 сек              | writeConcern: majority; требуется подтверждение записи для предотвращения overselling                     |
| **products** | Просмотр карточки товара                 | Secondary         | readConcern: `local` / до 90 сек              | readConcern: local; допустимо показать данные с устареванием до 90 секунд (типично секунды, максимум 90 с по maxStalenessSeconds) |
| **orders**   | Просмотр истории заказов                 | Secondary         | readConcern: `local` / до 90 сек              | readConcern: local; для просмотра истории допустима задержка (аналогично корзинам — кратковременная eventual consistency приемлема, пользователь не ожидает строгой актуальности для прошлых заказов); актуальный статус конкретного заказа читается отдельной операцией с primary                          |
| **orders**   | Проверка статуса последнего заказа       | Primary           | readConcern: `majority` / 0 сек               | readConcern: majority; клиент ожидает актуальный статус                                               |
| **orders**   | Создание нового заказа                   | Primary           | writeConcern: `majority` / 0 сек              | writeConcern: majority; требуется консистентность при записи                                           |
| **carts**    | Просмотр активной корзины                | Primary           | readConcern: `majority` / 0 сек               | readConcern: majority; пользователь ожидает актуальное состояние после добавления или удаления товара |
| **carts**    | Просмотр неактивной/исторической корзины | Secondary         | readConcern: `local` / до 90 сек              | readConcern: local; для `ordered` и `abandoned` допустима небольшая задержка                       |
| **carts**    | Добавление товара в корзину              | Primary           | writeConcern: `majority` / 0 сек              | writeConcern: majority; требуется актуальность для предотвращения конфликтов                           |
| **carts**    | Удаление товара из корзины               | Primary           | writeConcern: `majority` / 0 сек              | writeConcern: majority; требуется немедленное отражение изменений                                      |
| **carts**    | Слияние корзин                           | Primary           | writeConcern: `majority` / 0 сек              | writeConcern: majority; критичная операция, требующая консистентности                                  |

### Допустимая задержка репликации

**Для операций чтения с secondary:**

- **products (просмотр):** до 90 секунд (ограничение `maxStalenessSeconds`)
- **orders (история):** до 90 секунд
- **carts (неактивные/исторические):** до 90 секунд

**Примечание:** минимальное значение `maxStalenessSeconds` в MongoDB — 90 секунд, поэтому фактический порог устаревания для всех secondary-чтений составляет 90 секунд. При lag > 10 секунд срабатывает тревога мониторинга, но исключения secondary из ротации не происходит до достижения 90-секундного порога.

**Настройка read preference и read concern:**

```javascript
// Для чтения с secondary с допустимой задержкой
db.products.find({...}).readPref("secondary")

// Для чтения с primary для критичных операций
db.products.find({...}).readPref("primary")

// Настройка уровня консистентности
db.orders.find({...}).readConcern("majority")
```

Connection string с настройками read preference и maxStalenessSeconds:

```
mongodb://host/?readPreference=secondary&maxStalenessSeconds=90
```

### Обоснование выбора

**Критерии выбора:**

1. **Требования к консистентности:** Операции, влияющие на финансы или доступность товаров, требуют чтения с primary
2. **Частота обновлений:** Редко обновляемые данные (категории товаров) можно читать с secondary
3. **Бизнес-логика:** Риск продажи недоступного товара требует чтения с primary для остатков
4. **Производительность:** Чтение с secondary разгружает primary и улучшает отклик

---

## Задание 10. Миграция на Cassandra

### Задание 10.1: Критически важные данные для Cassandra

**Данные для переноса в Cassandra:**

| Сущность                 | Обоснование                                                                     |
| ------------------------ | ------------------------------------------------------------------------------- |
| **История заказов**      | Высокая интенсивность записи, масштабирование по customer_id, не требует сложных агрегаций и $lookup-связей |
| **Сессии пользователей** | Высокая частота записи/чтения, TTL, горизонтальное масштабирование              |
| **Корзины покупок**      | Масштабируемое чтение по ключу                                                  |
| **Просмотры товаров**    | Write-интенсивно; не требует строгой согласованности, TTL-данные                |
| **Остатки товаров**      | Write-интенсивное списание, атомарность через LWT, масштабируемость             |

Cassandra оптимально подходит для write‑интенсивных данных (история заказов, сессии, корзины, просмотры, остатки) благодаря горизонтальному масштабированию и поддержке TTL.

**Данные, остающиеся в MongoDB:**

MongoDB целесообразно сохранить для сущностей со сложными запросами и транзакционной целостностью.

- **Products (каталог)** — требуются сложные запросы по категориям и фильтрам, многокритериальный поиск. Источником истины для каталога остаётся MongoDB. Таблицы `products_by_id` и `products_by_category` в Cassandra — денормализованные read-модели для горячих путей чтения (карточка по id, каталог "категория + диапазон цен"). Синхронизация — через CDC/события изменения товара. Многокритериальный поиск и админ-операции выполняются в MongoDB. После миграции поле `stock` удаляется из документов коллекции `products`; единственным источником истины по остаткам становится `shop.stock_by_product`.

**Примечание:** при миграции идентификаторов MongoDB (ObjectId, 12 байт) в Cassandra (uuid/timeuuid, 16 байт) прямое преобразование невозможно. Стратегия: либо хранить прежние ObjectId как text, либо генерировать новые uuid и вести таблицу соответствия на время миграции.

**Примечание:** «Текущие заказы» (создание со статусом `created`) и история заказов переносятся в Cassandra (таблицы `orders_by_customer`, `orders_by_id`), так как Cassandra обеспечивает необходимую масштабируемость записи и поддерживает logged BATCH (гарантирует итоговую доставку записи в обе таблицы без изоляции чтения) и LWT (атомарные compare-and-set операции) для консистентного создания заказов.

### Задание 10.2: Модель данных для Cassandra

```sql
-- Keyspace с RF=3 в каждом дата-центре (msk, spb) для отказоустойчивости
CREATE KEYSPACE shop
WITH replication = {
  'class': 'NetworkTopologyStrategy',
  'msk': 3,
  'spb': 3
};

USE shop;
```

Вспомогательные пользовательские типы для вложенных структур:

```sql
CREATE TYPE shop.order_item (
  product_id uuid,
  price      decimal,
  quantity   int
);

CREATE TYPE shop.cart_item (
  product_id uuid,
  quantity   int
);

CREATE TYPE shop.product_attributes (
  color text,
  size  text
);
```

---

#### 10.2.1. Сущность «Заказы» (orders)

##### 10.2.1.1. История заказов клиента — `orders_by_customer`

Основной запрос: «все заказы пользователя, свежие сверху».

```sql
CREATE TABLE shop.orders_by_customer (
  customer_id  uuid,
  order_month  text,          -- бакет вида '2026-06'
  order_date   timestamp,
  order_id     timeuuid,
  status       text,          -- created | paid | shipped | delivered | cancelled
  geo_zone     text,          -- msk, spb, ekb, kgd ...
  items        frozen<list<frozen<order_item>>>,
  total_amount decimal,
  created_at   timestamp,
  PRIMARY KEY ((customer_id, order_month), order_date, order_id)
) WITH CLUSTERING ORDER BY (order_date DESC, order_id DESC);
```

- **Partition key:** `(customer_id, order_month)`
- **Clustering keys:** `order_date DESC, order_id DESC`

**Обоснование.** `customer_id` имеет высокую кардинальность и равномерное распределение по токен-кольцу. Бакет `order_month` защищает от неограниченного роста партиции у постоянных клиентов и от горячих партиций у бизнес-покупателей с тысячами заказов.

```sql
SELECT * FROM shop.orders_by_customer
WHERE customer_id = ? AND order_month = '2026-06'
LIMIT 20;
```

**Примечание:** при недоборе LIMIT приложение переходит к предыдущему бакету `order_month` для получения полной пагинации истории заказов через границы месяцев.

---

##### 10.2.1.2. Заказ и его статус по идентификатору — `orders_by_id`

Аналог read model `orders_by_id` из задания 7.

```sql
CREATE TABLE shop.orders_by_id (
  order_id     timeuuid,
  customer_id  uuid,
  order_date   timestamp,
  status       text,
  geo_zone     text,
  items        frozen<list<frozen<order_item>>>,
  total_amount decimal,
  created_at   timestamp,
  PRIMARY KEY ((order_id))
);
```

- **Partition key:** `order_id` timeuuid — уникален и распределён равномерно

Запись заказа выполняется в обе таблицы через `BATCH` (denormalization-first подход Cassandra):

```sql
BEGIN BATCH
  INSERT INTO shop.orders_by_customer (...) VALUES (...);
  INSERT INTO shop.orders_by_id (...) VALUES (...);
APPLY BATCH;
```

---

#### 10.2.2. Сущность «Корзины» (carts)

Запрос: «активная корзина по владельцу» — `owner_key` = `user:<user_id>` или `session:<session_id>`

```sql
CREATE TABLE shop.carts_by_owner (
  owner_key  text,            -- user:<user_id> | session:<session_id>
  status     text,            -- active | ordered | abandoned
  cart_id    timeuuid,
  user_id    uuid,
  session_id text,
  items      frozen<list<frozen<cart_item>>>,
  created_at timestamp,
  updated_at timestamp,
  expires_at timestamp,   -- информативное поле; фактическое удаление управляется TTL
  PRIMARY KEY ((owner_key), status, cart_id)
) WITH CLUSTERING ORDER BY (status ASC, cart_id DESC)
  AND default_time_to_live = 2592000;   -- 30 дней
```

- **Partition key:** `owner_key`
- **Clustering keys:** `status, cart_id`

**Обоснование.** У каждого гостя/пользователя своя партиция, равномерная нагрузка даже на 50 000 rps. Запрос активной корзины — точечный:

```sql
SELECT * FROM shop.carts_by_owner
WHERE owner_key = 'session:abc123' AND status = 'active';
```

**Примечание:** PK допускает несколько строк со `status = 'active'` у одного владельца. Приложение должно гарантировать не более одной активной корзины: при создании новой активной корзины предыдущая переводится в `abandoned`.

Слияние гостевой корзины при логине: чтение партиции `session:<session_id>`, запись items в партицию `user:<user_id>`, удаление гостевой строки (поскольку `status` — clustering key, его нельзя обновить UPDATE; требуется DELETE + INSERT новой строки с `status = 'abandoned'`). TTL (`default_time_to_live` или per-insert `USING TTL`) обеспечивает автоматическую очистку старых корзин — аналог TTL-индекса MongoDB по `expires_at`, но с фиксированным окном от момента записи, а не от произвольной даты.

---

#### 10.2.3. Сущность «Товары» (products)

##### 10.2.3.1. Карточка товара — `products_by_id`

```sql
CREATE TABLE shop.products_by_id (
  product_id uuid,
  name       text,
  category   text,
  price      decimal,
  attributes frozen<product_attributes>,   -- color, size
  created_at timestamp,
  updated_at timestamp,
  PRIMARY KEY ((product_id))
);
```

- **Partition key:** `product_id` — денормализованная read-модель для горячего пути чтения (страница товара за одно обращение). Источником истины остаётся MongoDB; синхронизация через CDC/события. Многокритериальный поиск и админ-операции выполняются в MongoDB.

##### 10.2.3.2. Каталог по категории — `products_by_category`

Денормализованная read-модель для каталога с фильтром по цене. Популярная категория (например, «Электроника») генерирует непропорционально большую долю трафика (согласно исходным требованиям). Поэтому вводим **синтетический бакет**:

```sql
CREATE TABLE shop.products_by_category (
  category   text,
  bucket     int,             -- hash(product_id) % 16
  price      decimal,
  product_id uuid,
  name       text,
  attributes frozen<product_attributes>,
  PRIMARY KEY ((category, bucket), price, product_id)
) WITH CLUSTERING ORDER BY (price ASC, product_id ASC);
```

- **Partition key:** `(category, bucket)` — популярная категория «размазывается» по 16 партициям и, соответственно, по разным узлам кольца.
- **Clustering keys:** `price, product_id` — фильтрация по диапазону цен внутри партиции.
- **Примечание:** изменение цены товара требует DELETE старой строки и INSERT новой (аналогично смене `status` в корзинах), так как clustering key неизменяем. Изменение `name`/`attributes` также требует обновления обеих таблиц (`products_by_id` и `products_by_category`). Смена категории — DELETE из старой партиции и INSERT в новую.

Запрос каталога — параллельное чтение 16 партиций с последующим merge на стороне приложения:

```sql
SELECT * FROM shop.products_by_category
WHERE category = 'Электроника' AND bucket = ?    -- ? = 0..15
  AND price >= 1000 AND price <= 5000;
```

##### 10.2.3.3. Остатки по геозонам — `stock_by_product`

Списание при каждой покупке, выносится в отдельную таблицу, чтобы при обновлении остатков не переписывали карточку товара:

```sql
CREATE TABLE shop.stock_by_product (
  product_id uuid,
  geo_zone   text,            -- ekb, kgd, msk, spb ...
  qty        int,
  updated_at timestamp,
  PRIMARY KEY ((product_id), geo_zone)
);
```

- **Partition key:** `product_id`; **clustering key:** `geo_zone`.
- Остатки товара по всем геозонам — одна маленькая партиция, чтение за один запрос; запись — точечный upsert строки конкретной геозоны.
- Для защиты от перепродажи списание выполняется через LWT по паттерну compare-and-set: приложение читает текущий `qty`, вычисляет новое значение и выполняет `UPDATE ... SET qty = <новое> ... IF qty = <прочитанное>`. При `[applied] = false` операция повторяется с новым прочтением.
- **Примечание:** Разграничение логических геозон и физических DC описано в примечании к разделу 10.3.2.

#### 10.2.4. Сессии и просмотры

Сессии и просмотры товаров заявлены в 10.1 для хранения в Cassandra. DDL таблиц приведён здесь; уровни согласованности описаны ниже и сведены в таблицу раздела 10.3.2.

```sql
CREATE TABLE shop.sessions_by_id (
  session_id text,
  user_id    uuid,
  data       map<text, text>,
  created_at timestamp,
  updated_at timestamp,
  PRIMARY KEY ((session_id))
) WITH default_time_to_live = 86400
     AND read_repair = 'NONE'
     AND gc_grace_seconds = 14400;
```

```sql
CREATE TABLE shop.product_views (
  product_id uuid,
  session_id text,
  viewed_at  timestamp,
  PRIMARY KEY ((product_id), viewed_at, session_id)
) WITH CLUSTERING ORDER BY (viewed_at DESC, session_id ASC)
     AND default_time_to_live = 604800
     AND read_repair = 'NONE'
     AND gc_grace_seconds = 14400;
```

Запись и чтение сессий выполняются с CL = ONE: потеря или устаревание сессии некритичны (пользователь переавторизуется), а latency минимальна.

Запись просмотров — с CL = ONE (eventual consistency допустима), чтение статистики просмотров по товару — с CL = LOCAL_ONE.

#### 10.2.5. Сводная таблица ключей

| Таблица                | Partition key                | Clustering keys             | Основной запрос               |
| ---------------------- | ---------------------------- | --------------------------- | ----------------------------- |
| `orders_by_customer`   | `(customer_id, order_month)` | `order_date DESC, order_id DESC` | История заказов клиента       |
| `orders_by_id`         | `order_id`                   | —                           | Статус/детали заказа          |
| `carts_by_owner`       | `owner_key`                  | `status, cart_id`           | Активная корзина              |
| `sessions_by_id`       | `session_id`                 | —                           | Сессия по id                  |
| `product_views`        | `product_id`                 | `viewed_at DESC, session_id`| Просмотры товара              |
| `products_by_id`       | `product_id`                 | —                           | Карточка товара               |
| `products_by_category` | `(category, bucket)`         | `price, product_id`         | Каталог + фильтр по цене      |
| `stock_by_product`     | `product_id`                 | `geo_zone`                  | Остатки, списание при покупке |

---

#### 10.2.6. Обоснование: горячие партиции и решардинг

**Равномерность распределения.** Все partition key либо высококардинальны сами по себе (`customer_id`, `product_id`, `owner_key`, `order_id`), либо принудительно бакетированы (`category + bucket`, `customer_id + order_month`). Murmur3-хеш от таких ключей даёт равномерную загрузку токен-кольца — прямой аналог выбранных `hashed`-шард-ключей в MongoDB, но уже на уровне ядра БД.

**Защита от горячих партиций.** Категорийный перекос («Электроника») решён бакетированием на этапе моделирования, а не постфактум балансировщиком, как в MongoDB. Рост партиций во времени ограничен: у заказов — месячным бакетом, у корзин — TTL. Целевой размер партиции держим в пределах ~100 МБ / ~100 тыс. строк.

**Минимизация влияния решардинга.** В отличие от MongoDB, где добавление шарда запускает миграцию чанков через балансировщик (и для hashed-ключей, и для range-based), в Cassandra новый узел получает набор vnode-токенов и стягивает только соответствующую долю данных (~\( 1/N \) кластера) напрямую с соседей, без остановки записи и без участия координатора-балансировщика. Поскольку ни один partition key не привязан к диапазонам «бизнес-значений» (дат, категорий, регионов), изменение топологии не создаёт перекоса: перемещаемые токен-диапазоны статистически содержат одинаковую смесь клиентов, товаров и корзин.

---

### Задание 10.3: Обеспечение согласованности данных в Cassandra

#### 10.3.1. Механизмы согласованности и их настройка

##### 10.3.1.1. Hinted Handoff

Hinted Handoff — базовый механизм доставки записей на временно недоступные узлы. Координатор сохраняет «хинт» и передаёт его узлу после восстановления. Механизм включён по умолчанию и настраивается на уровне узла в `cassandra.yaml`:

```yaml
hinted_handoff_enabled: true
max_hint_window: 3h # окно хранения хинтов (синтаксис Cassandra 4.1+; для 4.0 — max_hint_window_in_ms: 10800000)
hinted_handoff_throttle: 1024KiB  # для 4.0 — hinted_handoff_throttle_in_kb: 1024
max_hints_delivery_threads: 2
```

Окно в 3 часа покрывает типовые сценарии кратковременной недоступности узла (рестарт, обновление, сетевой сбой). Если узел отсутствовал дольше — рассинхронизация устраняется Read Repair и Anti-Entropy Repair.

##### 10.3.1.2. Read Repair

Read Repair устраняет расхождения реплик в момент чтения. Режим задаётся per-table:

```sql
ALTER TABLE shop.orders_by_customer
  WITH read_repair = 'BLOCKING';   -- реплики согласуются до ответа клиенту

ALTER TABLE shop.orders_by_id
  WITH read_repair = 'BLOCKING';   -- статус заказа читается именно отсюда

ALTER TABLE shop.stock_by_product
  WITH read_repair = 'BLOCKING';   -- остатки — критичные данные

ALTER TABLE shop.products_by_id
  WITH read_repair = 'NONE';       -- каталог: latency важнее, чинится repair'ом

ALTER TABLE shop.products_by_category
  WITH read_repair = 'NONE';
```

`BLOCKING` назначен таблицам, где чтение устаревшей версии недопустимо (заказы, остатки). `NONE` — таблицам, где важнее скорость ответа, а согласованность обеспечивается Hinted Handoff и регулярным repair.

##### 10.3.1.3. Anti-Entropy Repair

Фоновая полная синхронизация реплик через сравнение Merkle-деревьев. Запускается вручную или по расписанию (Cassandra 4.x, инкрементальный режим по умолчанию):

```bash
# инкрементальный repair критичных таблиц (частый, лёгкий)
nodetool repair shop orders_by_customer
nodetool repair shop orders_by_id
nodetool repair shop stock_by_product

# полный repair каталога (реже, по расписанию)
nodetool repair -full shop products_by_id
nodetool repair -full shop products_by_category
```

Правила планирования:

- инкрементальный repair критичных таблиц — каждые 1–7 дней;
- полный repair каждой таблицы — не реже одного раза в `gc_grace_seconds` (по умолчанию 10 дней), иначе возможно «воскрешение» удалённых данных (zombie data);
- флаг `-pr` (primary range) на каждом узле по очереди — для полного repair, чтобы не гонять одни и те же диапазоны многократно;
- для TTL-таблиц (`carts_by_owner`, `sessions_by_id`, `product_views`) repair не критичен: данные самоуничтожаются.

---

#### 10.3.2. Стратегии по сущностям

| Сущность (таблицы)                                | CL запись / чтение                           | Hinted Handoff           | Read Repair | Anti-Entropy Repair                                     | Основная гарантия                  |
| ------------------------------------------------- | -------------------------------------------- | ------------------------ | ----------- | ------------------------------------------------------- | ---------------------------------- |
| Заказы: `orders_by_customer`, `orders_by_id`      | LOCAL_QUORUM / LOCAL_QUORUM                  | Вкл.                     | BLOCKING    | Инкрементальный каждые 7 дней + полный раз в `gc_grace` | Строгая согласованность (W+R > RF) |
| Остатки: `stock_by_product`                       | LOCAL_QUORUM / LOCAL_QUORUM, списание через LWT (LOCAL_SERIAL) | Вкл.           | BLOCKING    | Инкрементальный, частый (1–3 дня)                       | LWT + Read Repair                  |
| Каталог: `products_by_id`, `products_by_category` | LOCAL_QUORUM / LOCAL_ONE                     | Вкл.                     | NONE        | Полный, раз в 7–10 дней                                 | Anti-Entropy Repair                |
| Корзины: `carts_by_owner`                         | LOCAL_QUORUM / LOCAL_ONE                     | Вкл. (основной механизм) | NONE        | Не критичен (TTL 30 дней)                               | Hinted Handoff + TTL               |
| Сессии: `sessions_by_id`                          | ONE / ONE                                    | Вкл. (основной механизм) | NONE        | Не требуется (TTL 24 часа)                              | Hinted Handoff + TTL               |
| Просмотры: `product_views`                        | ONE / LOCAL_ONE                              | Вкл.                   | NONE        | Не требуется (TTL 7 дней)                               | Hinted Handoff + TTL               |

**Примечание:** в MongoDB (задание 9) корзины читаются с primary, так как документ корзины обновляется атомарно и пользователь ожидает актуальное состояние. В Cassandra корзины — короткоживущие TTL-данные, где кратковременная eventual consistency допустима: в худшем случае пользователь повторно добавит товар, а запись всё равно идёт с `LOCAL_QUORUM` (не потеряется при падении узла). Оптимизация чтения под `LOCAL_ONE` снижает latency на самом «горячем» пути (каждое добавление/удаление товара → чтение корзины). Для остатков используется LWT с LOCAL_SERIAL (вместо SERIAL) — данные всех геозон реплицируются в оба DC (RF=3+3). Привязка geo_zone → DC существует только на уровне маршрутизации приложения для LWT-списаний: все списания одной геозоны направляются в один назначенный DC, чтобы LOCAL_SERIAL сериализовал конкурентные операции и исключал меж-DC задержки.

Обоснование: при RF = 3 в каждом DC сочетание W = LOCAL_QUORUM (2) и R = LOCAL_QUORUM (2) даёт W + R > RF внутри DC — чтение гарантированно видит последнюю запись без меж-DC задержек. Для заказов (включая историю) используется LOCAL_QUORUM для строгой согласованности в пределах DC. Для каталога и корзин допустимо кратковременное чтение устаревших данных в обмен на низкую задержку.

---

#### 10.3.3. Примеры операций

##### 10.3.3.1. Оформление заказа и списание остатка

```sql
-- запись заказа с кворумом в обе таблицы (denormalization по 10.2)
-- order_id генерируется на клиенте (timeuuid) и передаётся в обе таблицы
CONSISTENCY LOCAL_QUORUM;
BEGIN BATCH
  INSERT INTO shop.orders_by_customer
    (customer_id, order_month, order_date, order_id, status, geo_zone, items, total_amount, created_at)
  VALUES (?, '2026-06', ?, ?, 'created', 'msk', ?, 12500, toTimestamp(now()));
  INSERT INTO shop.orders_by_id
    (order_id, customer_id, order_date, status, geo_zone, items, total_amount, created_at)
  VALUES (?, ?, ?, 'created', 'msk', ?, 12500, toTimestamp(now()));
APPLY BATCH;

-- атомарное списание остатка через LWT (Paxos, LOCAL_SERIAL) — compare-and-set паттерн
-- приложение сначала читает текущий qty, затем выполняет UPDATE с IF qty = <прочитанное>
-- CONSISTENCY LOCAL_QUORUM управляет фазой коммита LWT; SERIAL CONSISTENCY LOCAL_SERIAL задаёт уровень Paxos
CONSISTENCY LOCAL_QUORUM;
SERIAL CONSISTENCY LOCAL_SERIAL;
UPDATE shop.stock_by_product
SET qty = ?, updated_at = toTimestamp(now())
WHERE product_id = ? AND geo_zone = 'msk'
IF qty = ?;
```

LWT возвращает `[applied] = true/false`: приложение обязано проверять результат и повторять операцию либо отказывать в резервировании товара. При повторе выполняется новое чтение текущего `qty` и вычисление нового значения, чтобы исключить потерю списаний при конкурентных запросах.

##### 10.3.3.2. Чтение с разными уровнями согласованности

```sql
-- статус заказа: строго согласованное чтение
CONSISTENCY LOCAL_QUORUM;
SELECT status, total_amount FROM shop.orders_by_id WHERE order_id = ?;

-- карточка товара: быстрое чтение, eventual consistency допустима
CONSISTENCY LOCAL_ONE;
SELECT * FROM shop.products_by_id WHERE product_id = ?;

-- остаток при отображении на витрине: LOCAL_SERIAL-чтение дожидается завершения всех in-flight LWT и видит только закоммиченные данные
CONSISTENCY LOCAL_SERIAL;
SELECT qty FROM shop.stock_by_product WHERE product_id = ? AND geo_zone = 'msk';
```

##### 10.3.3.3. Корзины: донастройка существующей таблицы

Таблица `carts_by_owner` создана в 10.2; ниже задаются только параметры согласованности:

```sql
ALTER TABLE shop.carts_by_owner
  WITH read_repair = 'NONE'
  AND gc_grace_seconds = 14400;   -- repair по таблице не выполняется, tombstones чистим быстрее; значение > max_hint_window (3h) для предотвращения resurrection данных
```

#### 10.3.4. Сравнение требований к согласованности по сущностям

| Сущность                                 | Критичность согласованности (1–10) | Допустимая задержка чтения, мс | Вывод по стратегии                                                               |
| ---------------------------------------- | ---------------------------------- | ------------------------------ | -------------------------------------------------------------------------------- |
| `orders_by_customer`, `orders_by_id`     | 10                                 | 50                             | Строгая согласованность: LOCAL_QUORUM/LOCAL_QUORUM, BLOCKING Read Repair, регулярный repair  |
| `stock_by_product`                       | 10                                 | 30                             | Максимальная строгость: LWT (LOCAL_SERIAL) для списаний, частый инкрементальный repair |
| `products_by_id`, `products_by_category` | 5                                  | 10                             | Eventual consistency: LOCAL_ONE на чтение, фоновый полный repair                 |
| `carts_by_owner`                         | 4                                  | 10                             | Минимальные гарантии: Hinted Handoff + TTL 30 дней, repair не требуется          |
| `sessions_by_id`                         | 2                                  | 5                              | Минимальные CL (ONE/ONE), TTL 24 часа, полная опора на Hinted Handoff            |
| `product_views`                          | 1                                  | 5                              | Минимальные гарантии: LOCAL_ONE на чтение, TTL 7 дней, repair не требуется      |

Закономерность сохраняется: чем выше критичность согласованности, тем строже CL и Read Repair и тем чаще repair; чем ниже — тем агрессивнее оптимизация под задержку (CL = ONE/LOCAL_ONE, `read_repair = NONE`, опора на TTL и Hinted Handoff).

---

#### 10.3.5. Итоговые принципы

1. **Заказы и остатки** — строгая согласованность: LOCAL_QUORUM/LOCAL_QUORUM, LWT (LOCAL_SERIAL) для списаний, BLOCKING Read Repair, регулярный инкрементальный repair.
2. **Каталог** — eventual consistency: быстрые чтения LOCAL_ONE, согласование фоновым полным repair.
3. **Корзины и сессии** — TTL-данные: минимальные CL на чтение (LOCAL_ONE/ONE), запись корзин — LOCAL_QUORUM; Hinted Handoff как основной механизм, repair не требуется.
4. **Полный repair каждой таблицы — не реже раза в `gc_grace_seconds`**, кроме TTL-таблиц с уменьшенным `gc_grace_seconds` и отключённым repair-циклом.

# pymongo-api - MongoDB Sharding, Replication & Caching

Проект реализует отказоустойчивую архитектуру MongoDB с шардированием, репликацией и кешированием для онлайн-магазина «Мобильный мир».

## Архитектурный документ

- Итоговая схема (задания 1-6) — в файле `doc/final-diagram.drawio`
- `docs/architecture-doc.md` — отдельный документ для заданий 7–10: схемы коллекций, стратегии шардирования, чтение с реплик и миграция на Cassandra.
- Ниже в разделе структуры проекта и в самом документе собраны все ключевые решения и примеры команд для проверки.

## Архитектура

- **Шардирование**: 2 шарда для распределения данных
- **Репликация**: 3 реплики в каждом шарде для отказоустойчивости
- **Кеширование**: Redis для ускорения запросов к API
- **API Gateway**: отражён на итоговой схеме как компонент балансировки нагрузки между инстансами приложения
- **Service Discovery**: Consul отражён на итоговой схеме как компонент регистрации сервисов

## Структура проекта

- `mongo-sharding/` - базовое шардирование (2 шарда)
- `mongo-sharding-repl/` - шардирование с репликацией (3 реплики на шард)
- `sharding-repl-cache/` - полная реализация с кешированием Redis
- `docs/architecture-doc.md` - полный архитектурный документ для заданий 7-10

## Как запустить (финальная реализация)

Для проверки используется директория `sharding-repl-cache` — она содержит финальный стенд для ревью (задания 2, 3 и 4): шардирование, репликацию и Redis-кеширование. Директории `mongo-sharding/` и `mongo-sharding-repl/` оставлены как промежуточные решения.

**Требования:** минимум 2 CPU и 4 Гб ОЗУ.

### Запуск

Автоматический запуск и настройка всего кластера командой:

**Windows PowerShell:**

```powershell
cd sharding-repl-cache
.\start.ps1
```

**Windows (Git Bash):**

```bash
cd sharding-repl-cache
& "C:\Program Files\Git\bin\bash.exe" -c "./start.sh"
```

**macOS/Linux:**

```bash
cd sharding-repl-cache
./start.sh
```

После завершения скрипта приложение доступно по адресу http://localhost:8080.

### Проверка статуса сервисов

```bash
docker compose ps
```

Все сервисы должны быть в статусе `Up`.

Скрипт автоматически выполнит все шаги:

- Шаг 0: Остановка ранее запущенных сервисов
- Шаг 1: Запуск Docker-контейнеров
- Шаг 2: Инициализация реплик
- Шаг 3: Добавление шардов в кластер
- Шаг 4: Включение шардирования
- Шаг 5: Инициализация данных (1000 документов)
- Шаг 6: Проверка состояния
- Шаг 7: Проверка кеширования

### Минимальный сценарий проверки финального стенда:

```bash
cd sharding-repl-cache
./start.sh
docker compose ps
curl http://localhost:8080/
curl -w "\nTime: %{time_total}s\n" http://localhost:8080/helloDoc/users
curl -w "\nTime: %{time_total}s\n" http://localhost:8080/helloDoc/users
```

Для Windows используйте `.\start.ps1` или Git Bash (`& "C:\Program Files\Git\bin\bash.exe" -c "./start.sh"`) вместо `./start.sh`.

### Проверка количества документов

```bash
# Общее количество (должно быть 1000)
docker exec sharding-repl-cache-mongos-1 mongosh --port 27021 --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()"

# По шардам
docker exec sharding-repl-cache-shard1-1-1 mongosh --port 27018 --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()"
docker exec sharding-repl-cache-shard2-1-1 mongosh --port 27020 --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()"
```

### Проверка репликации

```bash
# Количество реплик в каждом шарде (должно быть 3)
docker exec sharding-repl-cache-shard1-1-1 mongosh --port 27018 --eval "rs.status().members.length"
docker exec sharding-repl-cache-shard2-1-1 mongosh --port 27020 --eval "rs.status().members.length"
```

### Проверка кеширования

Первый запрос (медленный, ~1000мс):

```bash
curl -w "\nTime: %{time_total}s\n" http://localhost:8080/helloDoc/users
```

Второй запрос (быстрый, <100мс из Redis):

```bash
curl -w "\nTime: %{time_total}s\n" http://localhost:8080/helloDoc/users
```

### Проверка через API

```bash
# Статус системы (должно показать cache_enabled: true)
curl http://localhost:8080/

# Количество документов
curl http://localhost:8080/helloDoc/count
```

## Доступные эндпоинты

- `GET http://localhost:8080/` - общая информация о БД и статусе кеширования
- `GET http://localhost:8080/helloDoc/count` - количество документов
- `GET http://localhost:8080/helloDoc/users` - список пользователей (кешируется 60 сек)
- `GET http://localhost:8080/docs` - Swagger документация

## Компоненты

| Сервис      | Порт  | Описание                              |
| ----------- | ----- | ------------------------------------- |
| pymongo_api | 8080  | API приложение                        |
| mongos      | 27021 | Маршрутизатор шардированного кластера |
| configSrv-1 | 27019 | Конфигурационный сервер 1             |
| configSrv-2 | 27029 | Конфигурационный сервер 2             |
| configSrv-3 | 27039 | Конфигурационный сервер 3             |
| shard1-1    | 27018 | Первичная нода шарда 1                |
| shard1-2    | 27048 | Вторичная нода шарда 1                |
| shard1-3    | 27058 | Вторичная нода шарда 1                |
| shard2-1    | 27020 | Первичная нода шарда 2                |
| shard2-2    | 27060 | Вторичная нода шарда 2                |
| shard2-3    | 27070 | Вторичная нода шарда 2                |
| redis       | 6379  | Кеш для ускорения запросов            |

## Схема архитектуры

Итоговая схема (задания 1, 5, 6) — в файле `docs/final-diagram.drawio`. Включает:

- Шардирование (2 шарда)
- Репликацию (3 ноды на шард)
- Кеширование (Redis)
- API Gateway для балансировки
- Consul для Service Discovery
- CDN и origin статического контента

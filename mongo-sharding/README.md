# MongoDB Sharding Setup

Этот проект реализует шардирование MongoDB с двумя шардами для повышения производительности.

## Архитектура

- **configSrv-1, configSrv-2, configSrv-3** (порты 27019, 27029, 27039) - конфигурационные серверы для шардирования (3 ноды для обеспечения кворума)
- **shard1-1** (порт 27018) - первый шард
- **shard2-1** (порт 27020) - второй шард
- **mongos** (порт 27021) - маршрутизатор запросов
- **pymongo_api** (порт 8080) - API приложение

## Запуск

Запуск и настройка всего кластера:

**Windows PowerShell:**

```powershell
.\start.ps1
```

**Windows через Git Bash:**

```bash
cd mongo-sharding
"/c/Program Files/Git/bin/bash.exe" -c "./start.sh"
```

**macOS/Linux:**

```bash
./start.sh
```

Скрипт автоматически выполнит:

- Шаг 0: Остановка ранее запущенных сервисов
- Шаг 1: Запуск Docker-контейнеров
- Шаг 2: Инициализация реплик (shard1, shard2, config server) и перезапуск mongos
- Шаг 3: Добавление шардов в кластер
- Шаг 4: Включение шардирования
- Шаг 5: Инициализация данных (1000 документов)
- Шаг 6: Проверка состояния

> **Примечание:** Для работы скриптов требуется Docker Desktop и PowerShell (Windows) или bash (macOS/Linux). Скрипты автоматически останавливают старые контейнеры перед запуском новых.

## Проверка состояния

### Статус шардирования

```bash
docker exec mongo-sharding-mongos-1 mongosh --port 27021 --quiet --eval "sh.status()"
```

### Количество документов в каждом шарде

```bash
docker exec mongo-sharding-shard1-1-1 mongosh --port 27018 --quiet --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()"
docker exec mongo-sharding-shard2-1-1 mongosh --port 27020 --quiet --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()"
```

### Общее количество документов

```bash
docker exec mongo-sharding-mongos-1 mongosh --port 27021 --quiet --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()"
```

## API Endpoints

- `GET /` - общая информация о БД и статусе
- `GET /helloDoc/count` - количество документов
- `GET /helloDoc/users` - список пользователей

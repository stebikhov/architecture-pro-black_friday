#!/bin/bash
# Скрипт автоматического запуска и настройки MongoDB кластера с шардированием и репликацией (2 шарда по 3 реплики)
# Использование: ./start.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Шаг 0: Остановка ранее запущенных сервисов и Docker-контейнеров
echo "=== Шаг 0: Остановка ранее запущенных сервисов ==="
cd "$SCRIPT_DIR"
docker compose down -v
docker compose -p mongo-sharding down -v 2>/dev/null || true
docker compose -p sharding-repl-cache down -v 2>/dev/null || true
echo "Контейнеры остановлены"

# Шаг 1: Запуск всех сервисов (MongoDB, API)
echo -e "\n=== Шаг 1: Запуск Docker-контейнеров ==="
docker compose up --build -d
echo "Ожидание запуска сервисов (60 секунд)..."
sleep 60
echo "Сервисы запущены"

# Шаг 2: Инициализация реплик
echo -e "\n=== Шаг 2: Инициализация реплик ==="

# Инициализация Shard 1 replica set
echo "Инициализация shard1..."
docker exec mongo-sharding-repl-shard1-1-1 mongosh --port 27018 --quiet --eval "rs.initiate({_id: 'shard1ReplSet', members: [{_id: 0, host: 'shard1-1:27018'}, {_id: 1, host: 'shard1-2:27048'}, {_id: 2, host: 'shard1-3:27058'}]})"
echo "Shard 1 инициализирован"
sleep 5

# Инициализация Shard 2 replica set
echo "Инициализация shard2..."
docker exec mongo-sharding-repl-shard2-1-1 mongosh --port 27020 --quiet --eval "rs.initiate({_id: 'shard2ReplSet', members: [{_id: 0, host: 'shard2-1:27020'}, {_id: 1, host: 'shard2-2:27060'}, {_id: 2, host: 'shard2-3:27070'}]})"
echo "Shard 2 инициализирован"
sleep 5

# Инициализация Config Server replica set
echo "Инициализация config server..."
docker exec mongo-sharding-repl-configSrv-1-1 mongosh --port 27019 --quiet --eval "rs.initiate({_id: 'configReplSet', configsvr: true, members: [{_id: 0, host: 'configSrv-1:27019'}, {_id: 1, host: 'configSrv-2:27029'}, {_id: 2, host: 'configSrv-3:27039'}]})"
echo "Config server инициализирован"
sleep 10

# Перезапуск mongos после инициализации config server
echo "Перезапуск mongos..."
docker compose restart mongos
sleep 15

# Шаг 3: Добавление шардов в кластер
echo -e "\n=== Шаг 3: Добавление шардов в кластер ==="
docker exec mongo-sharding-repl-mongos-1 mongosh --port 27021 --quiet --eval "sh.addShard('shard1ReplSet/shard1-1:27018')"
docker exec mongo-sharding-repl-mongos-1 mongosh --port 27021 --quiet --eval "sh.addShard('shard2ReplSet/shard2-1:27020')"
echo "Шарды добавлены в кластер"

# Шаг 4: Включение шардирования для базы данных и коллекции
echo -e "\n=== Шаг 4: Включение шардирования ==="
docker exec mongo-sharding-repl-mongos-1 mongosh --port 27021 --quiet --eval "sh.enableSharding('somedb')"
docker exec mongo-sharding-repl-mongos-1 mongosh --port 27021 --quiet --eval "sh.shardCollection('somedb.helloDoc', {age: 'hashed'})"
echo "Шардирование включено"

# Шаг 5: Инициализация данных (1000 документов)
echo -e "\n=== Шаг 5: Инициализация данных (1000 документов) ==="
docker exec mongo-sharding-repl-mongos-1 mongosh --port 27021 --quiet --eval "var bulk = db.getSiblingDB('somedb').helloDoc.initializeUnorderedBulkOp(); for(var i = 0; i < 1000; i++) bulk.insert({age: i, name: 'ly' + i}); bulk.execute();"
echo "Данные инициализированы"

# Шаг 6: Проверка состояния кластера
echo -e "\n=== Шаг 6: Проверка состояния ==="

TotalDocs=$(docker exec mongo-sharding-repl-mongos-1 mongosh --port 27021 --quiet --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()")
echo "Общее количество документов: $TotalDocs"

Shard1Docs=$(docker exec mongo-sharding-repl-shard1-1-1 mongosh --port 27018 --quiet --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()")
echo "Документов в shard1: $Shard1Docs"

Shard2Docs=$(docker exec mongo-sharding-repl-shard2-1-1 mongosh --port 27020 --quiet --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()")
echo "Документов в shard2: $Shard2Docs"

# Проверка количества реплик
echo -e "\n=== Информация о репликах ==="
Shard1Replicas=$(docker exec mongo-sharding-repl-shard1-1-1 mongosh --port 27018 --quiet --eval "rs.status().members.length")
Shard2Replicas=$(docker exec mongo-sharding-repl-shard2-1-1 mongosh --port 27020 --quiet --eval "rs.status().members.length")
echo "Количество реплик в shard1: $Shard1Replicas"
echo "Количество реплик в shard2: $Shard2Replicas"

# Финальное сообщение
echo -e "\n=== Готово! ==="
echo "Приложение доступно по адресу: http://localhost:8080"
echo "API документация: http://localhost:8080/docs"

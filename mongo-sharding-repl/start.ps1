#!/usr/bin/env pwsh
# Скрипт автоматического запуска и настройки MongoDB кластера с шардированием и репликацией (2 шарда по 3 реплики)
# Использование: .\start.ps1

$ComposeDir = "$PSScriptRoot"

# Шаг 0: Остановка ранее запущенных сервисов и Docker-контейнеров
Write-Host "=== Шаг 0: Остановка ранее запущенных сервисов ===" -ForegroundColor Yellow
Push-Location $ComposeDir
docker compose down -v
docker compose -p mongo-sharding down -v 2>$null
docker compose -p sharding-repl-cache down -v 2>$null
Pop-Location
Write-Host "Контейнеры остановлены" -ForegroundColor Green

# Шаг 1: Запуск всех сервисов (MongoDB, API)
Write-Host "`n=== Шаг 1: Запуск Docker-контейнеров ===" -ForegroundColor Yellow
Push-Location $ComposeDir
docker compose up --build -d
Pop-Location
Write-Host "Ожидание запуска сервисов (60 секунд)..." -ForegroundColor Cyan
Start-Sleep -Seconds 60
Write-Host "Сервисы запущены" -ForegroundColor Green

# Шаг 2: Инициализация реплик
Write-Host "`n=== Шаг 2: Инициализация реплик ===" -ForegroundColor Yellow

# Инициализация Shard 1 replica set
Write-Host "Инициализация shard1..." -ForegroundColor Cyan
docker exec mongo-sharding-repl-shard1-1-1 mongosh --port 27018 --quiet --eval "rs.initiate({_id: 'shard1ReplSet', members: [{_id: 0, host: 'shard1-1:27018'}, {_id: 1, host: 'shard1-2:27048'}, {_id: 2, host: 'shard1-3:27058'}]})"
Write-Host "Shard 1 инициализирован" -ForegroundColor Green
Start-Sleep -Seconds 5

# Инициализация Shard 2 replica set
Write-Host "Инициализация shard2..." -ForegroundColor Cyan
docker exec mongo-sharding-repl-shard2-1-1 mongosh --port 27020 --quiet --eval "rs.initiate({_id: 'shard2ReplSet', members: [{_id: 0, host: 'shard2-1:27020'}, {_id: 1, host: 'shard2-2:27060'}, {_id: 2, host: 'shard2-3:27070'}]})"
Write-Host "Shard 2 инициализирован" -ForegroundColor Green
Start-Sleep -Seconds 5

# Инициализация Config Server replica set
Write-Host "Инициализация config server..." -ForegroundColor Cyan
docker exec mongo-sharding-repl-configSrv-1-1 mongosh --port 27019 --quiet --eval "rs.initiate({_id: 'configReplSet', configsvr: true, members: [{_id: 0, host: 'configSrv-1:27019'}, {_id: 1, host: 'configSrv-2:27029'}, {_id: 2, host: 'configSrv-3:27039'}]})"
Write-Host "Config server инициализирован" -ForegroundColor Green
Start-Sleep -Seconds 10

# Перезапуск mongos после инициализации config server
Write-Host "Перезапуск mongos..." -ForegroundColor Cyan
Push-Location $ComposeDir
docker compose restart mongos
Pop-Location
Start-Sleep -Seconds 15

# Шаг 3: Добавление шардов в кластер
Write-Host "`n=== Шаг 3: Добавление шардов в кластер ===" -ForegroundColor Yellow
docker exec mongo-sharding-repl-mongos-1 mongosh --port 27021 --quiet --eval "sh.addShard('shard1ReplSet/shard1-1:27018')"
docker exec mongo-sharding-repl-mongos-1 mongosh --port 27021 --quiet --eval "sh.addShard('shard2ReplSet/shard2-1:27020')"
Write-Host "Шарды добавлены в кластер" -ForegroundColor Green

# Шаг 4: Включение шардирования для базы данных и коллекции
Write-Host "`n=== Шаг 4: Включение шардирования ===" -ForegroundColor Yellow
docker exec mongo-sharding-repl-mongos-1 mongosh --port 27021 --quiet --eval "sh.enableSharding('somedb')"
docker exec mongo-sharding-repl-mongos-1 mongosh --port 27021 --quiet --eval "sh.shardCollection('somedb.helloDoc', {age: 'hashed'})"
Write-Host "Шардирование включено" -ForegroundColor Green

# Шаг 5: Инициализация данных (1000 документов)
Write-Host "`n=== Шаг 5: Инициализация данных (1000 документов) ===" -ForegroundColor Yellow
docker exec mongo-sharding-repl-mongos-1 mongosh --port 27021 --quiet --eval "var bulk = db.getSiblingDB('somedb').helloDoc.initializeUnorderedBulkOp(); for(var i = 0; i < 1000; i++) bulk.insert({age: i, name: 'ly' + i}); bulk.execute();"
Write-Host "Данные инициализированы" -ForegroundColor Green

# Шаг 6: Проверка состояния кластера
Write-Host "`n=== Шаг 6: Проверка состояния ===" -ForegroundColor Yellow

$TotalDocs = docker exec mongo-sharding-repl-mongos-1 mongosh --port 27021 --quiet --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()"
Write-Host "Общее количество документов: $TotalDocs" -ForegroundColor Cyan

$Shard1Docs = docker exec mongo-sharding-repl-shard1-1-1 mongosh --port 27018 --quiet --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()"
Write-Host "Документов в shard1: $Shard1Docs" -ForegroundColor Cyan

$Shard2Docs = docker exec mongo-sharding-repl-shard2-1-1 mongosh --port 27020 --quiet --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()"
Write-Host "Документов в shard2: $Shard2Docs" -ForegroundColor Cyan

# Проверка количества реплик
Write-Host "`n=== Информация о репликах ===" -ForegroundColor Yellow
$Shard1Replicas = docker exec mongo-sharding-repl-shard1-1-1 mongosh --port 27018 --quiet --eval "rs.status().members.length"
$Shard2Replicas = docker exec mongo-sharding-repl-shard2-1-1 mongosh --port 27020 --quiet --eval "rs.status().members.length"
Write-Host "Количество реплик в shard1: $Shard1Replicas" -ForegroundColor Cyan
Write-Host "Количество реплик в shard2: $Shard2Replicas" -ForegroundColor Cyan

# Финальное сообщение
Write-Host "`n=== Готово! ===" -ForegroundColor Green
Write-Host "Приложение доступно по адресу: http://localhost:8080" -ForegroundColor Green
Write-Host "API документация: http://localhost:8080/docs" -ForegroundColor Green

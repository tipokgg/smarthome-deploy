#!/usr/bin/env bash
# Автообновление (таймер smarthome-update.timer): если у тега *_TRACK в GHCR новый образ, переключает сервис на него
# и ждёт healthcheck. Не поднялся - откат на прежний образ (бэкенд - вместе с базой из копии перед обновлением),
# образ запоминается в state/failed и больше не ставится. Новый коммит даст новый образ, и попытка повторится.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

WAIT_TIMEOUT=${WAIT_TIMEOUT:-240}

mkdir -p state
exec 9> state/update.lock
flock -n 9 || exit 0

[[ "${AUTO_UPDATE:-1}" == 1 ]] || exit 0

# update_service <сервис> <префикс переменных в .env>
update_service() {
  local service=$1 prefix=$2
  local image_var=${prefix}_IMAGE track_var=${prefix}_TRACK
  local current=${!image_var} track=${!track_var}

  if ! docker pull -q "$track" > /dev/null; then
    log "$service: не удалось скачать $track"
    return 0
  fi
  local digest
  digest=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$track" | grep -m1 "^${track%:*}@" || true)
  [[ -n "$digest" && "$digest" != "$current" ]] || return 0
  if grep -qxF "$digest" state/failed 2> /dev/null; then
    return 0
  fi

  local from to backup=""
  from=$(revision "$current")
  to=$(revision "$digest")
  log "$service: обновление $from -> $to"
  if [[ "$service" == backend ]]; then
    backup=$(scripts/backup.sh pre-update)
  fi

  env_set "$image_var" "$digest"
  if docker compose up -d --wait --wait-timeout "$WAIT_TIMEOUT" "$service"; then
    notify "$service обновлён: $from → $to"
    docker image prune -f > /dev/null
    return 0
  fi

  echo "$digest" >> state/failed
  local logs
  logs=$(docker compose logs --no-log-prefix --tail 15 "$service" 2>&1 || true)
  env_set "$image_var" "$current"
  if [[ -n "$backup" ]]; then
    # новая версия могла успеть накатить миграции Liquibase, прежняя с ними не заведётся
    docker compose stop "$service"
    rm -f data/smarthome.db-journal data/smarthome.db-wal data/smarthome.db-shm
    gunzip -c "$backup" > data/smarthome.db
    chown 1000:1000 data/smarthome.db
  fi
  if docker compose up -d --wait --wait-timeout "$WAIT_TIMEOUT" "$service"; then
    notify "$service $to не поднялся, откатил на $from${backup:+ (база из $backup)}"$'\n\n'"$logs"
  else
    notify "$service $to не поднялся, и откат на $from тоже не поднялся, нужна помощь"$'\n\n'"$logs"
  fi
}

update_service frontend FRONTEND
update_service backend BACKEND

# BrotatoLocalTogether

LAN/Tailscale-мод для Brotato без использования Steam lobby/UGC API в сетевом ядре.

## Структура

- `flash-BrotatoLocalTogether/` — исходники мода.
- `scripts/install_workshop.ps1` — сборка и установка в Steam Workshop item.
- `build/flash-BrotatoLocalTogether.zip` — итоговый архив для установки.

## Что уже сделано

- Выделен отдельный мод с новым `id/namespace`.
- Сетевой core вынесен в `lan_connection.gd`.
- Конфиги и восстановление сессии изолированы в `user://brotato_local_together/`.
- Safe-bootstrap и rollout сохранены.
- Проблемные extension остаются принудительно отключены:
  - `core_main`
  - `entities/structures/turret/turret.gd`

## Проверка

1. Активируйте мод в `mod_user_profiles.json` через zip из `build/`.
2. Удалите кэш модлоадера: `C:/Users/flash/AppData/Roaming/Brotato/mod_loader_cache.json`.
3. Запустите игру и проверьте `logs/modloader.log`:
   - должен грузиться `BrotatoLocalTogether`.
   - не должно быть `Joined Lobby ... BROTATOGETHER_GLOBAL_CHAT`.

## Быстрая установка (рабочий сценарий)

Скрипт повторяет последний успешный способ установки:

1. Собирает zip с корректным корнем `mods-unpacked/flash-BrotatoLocalTogether/`.
2. Копирует zip в выбранный workshop item.
3. Записывает `compat.cfg` с нужным rollout.
4. Чистит `mod_loader_cache.json`.

Пример запуска:

```powershell
cd D:\GIT\brotatoLocalCoop\project\BrotatoLocalTogether
powershell -ExecutionPolicy Bypass -File .\scripts\install_workshop.ps1 -WorkshopItemId 2985539742
```

Если `-WorkshopItemId` не передан, скрипт пытается выбрать item автоматически.

Проверка без записи файлов:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install_workshop.ps1 -WorkshopItemId 2985539742 -DryRun
```

Полный rollout (все extension-группы, кроме принудительно отключённых в коде):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install_workshop.ps1 -WorkshopItemId 2985539742 -FullMod
```

Ручная настройка rollout:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install_workshop.ps1 -WorkshopItemId 2985539742 -CompatRolloutCount -1
```

## Tailscale host endpoint

В меню Multiplayer добавлено поле `Advertise IP (optional)`.
Если автоподбор адреса выбирает не тот интерфейс, укажи там Tailscale IP вручную.

Без ручного значения мод пытается выбрать адрес так:
1. Tailscale диапазон `100.64.0.0/10`
2. private LAN (`192.168.*`, `10.*`, `172.16-31.*`)
3. первый доступный IPv4

## Профиль мода (один раз вручную)

Скрипт не трогает `mod_user_profiles.json`.
Один раз добавь мод вручную:

```json
{
  "current_profile": "default",
  "profiles": {
    "default": {
      "mod_list": {
        "flash-BrotatoLocalTogether": {
          "is_active": true,
          "zip_path": "D:/steam/steamapps/workshop/content/1942280/2985539742/flash-BrotatoLocalTogether.zip"
        }
      }
    }
  }
}
```

## Конфиг bootstrap

`C:/Users/flash/AppData/Roaming/Brotato/brotato_local_together/compat.cfg`

Ключевые поля:

- `safe_bootstrap_enabled`
- `extension_rollout_count`
- `enabled_extension_groups`
- `disabled_extension_groups`
- `disabled_extension_paths`

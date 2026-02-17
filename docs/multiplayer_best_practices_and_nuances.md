# BrotatoLocalTogether: best practices и системные нюансы (Exa MCP)

Дата: 2026-02-16

## Контекст

Документ собран по результатам поиска через Exa MCP и сопоставления с текущей реализацией в:
- `BrotatoLocalTogether/flash-BrotatoLocalTogether/lan_connection.gd`
- `BrotatoLocalTogether/flash-BrotatoLocalTogether/protocol_connection.gd`

## Источники

- Godot 3.5: High-level multiplayer  
  https://docs.godotengine.org/en/3.5/tutorials/networking/high_level_multiplayer.html
- Godot 3.5: NetworkedMultiplayerPeer  
  https://docs.godotengine.org/en/3.5/classes/class_networkedmultiplayerpeer.html
- Godot 3.5: NetworkedMultiplayerENet  
  https://docs.godotengine.org/en/3.5/classes/class_networkedmultiplayerenet.html
- Godot 3.5: MultiplayerAPI  
  https://docs.godotengine.org/en/3.5/classes/class_multiplayerapi.html
- ENet: Features and Architecture  
  http://enet.bespin.org/Features.html
- Gaffer On Games: Snapshot Interpolation  
  https://gafferongames.com/post/snapshot_interpolation/
- Gaffer On Games: State Synchronization  
  https://gafferongames.com/post/state_synchronization/

## Что уже хорошо в текущей архитектуре

- Есть host-authoritative модель: хост держит состояние сессии и раздаёт sync.  
  См. `create_new_game_lobby`, `send_p2p_packet`, `_send_lobby_sync` в `BrotatoLocalTogether/flash-BrotatoLocalTogether/lan_connection.gd`.
- Есть resume/recovery через `session_id` + `player_token` + TTL сессии.  
  См. `_receive_client_registration` и `_receive_client_registration_ack` в `BrotatoLocalTogether/flash-BrotatoLocalTogether/lan_connection.gd`.
- Есть снимки состояния для восстановления после краша (`_build_snapshot_payload`, `_maybe_store_snapshot`).  
  См. `BrotatoLocalTogether/flash-BrotatoLocalTogether/lan_connection.gd`.
- Блокируется late-join в активный ран без валидного токена (`late_join_blocked`).  
  См. `BrotatoLocalTogether/flash-BrotatoLocalTogether/lan_connection.gd`.

## Ключевые best practices под ваш текущий подход

1. Разделять трафик по критичности и каналам ENet.
- Критичные события (join/ack/scene transition/shop-buy): reliable.
- Частые события (позиции, aim, preview-focus): unreliable или unreliable ordered.
- Не смешивать всё в один поток: это увеличивает head-of-line блокировки.

2. Ввести единый envelope для каждого сообщения.
- Поля: `protocol_version`, `session_id`, `message_type`, `seq`, `tick`, `sent_at_msec`.
- Это упростит дедупликацию, отладку, replay-защиту и migration между версиями.

3. Переходы сцен подтверждать явными ack.
- Для `character -> weapon -> difficulty -> main` нужен подтверждённый протокол:
  `SCENE_PREPARE`, `SCENE_READY`, `SCENE_COMMIT`.
- Это снижает риск soft-lock при потере/задержке единичного пакета.

4. Для gameplay использовать snapshot+interpolation, а не только «мгновенные» state-dump.
- Сервер шлёт снапшоты фиксированно (например, 10-20 Гц) + timestamp/tick.
- Клиент рендерит с интерполяционным буфером (примерно 80-120 мс).
- Для локального игрока оставлять prediction + reconciliation по server state.

5. Ограничить размер и частоту payload.
- Сжатие GZIP на каждый микропакет может быть дорогим по CPU.
- Практика: сжимать только payload выше порога (например, > 512-1024 байт).
- Для мелких сообщений полезнее компактная сериализация без GZIP.

6. Валидировать входящий трафик по sender/phase/state machine.
- Обрабатывать сообщения только если `sender_id`, `session_id` и `game_phase` ожидаемы.
- Невалидные пакеты отбрасывать с кодом причины в лог.

7. Держать совместимость протокола явной.
- Добавить `protocol_version` в handshake.
- При несовместимости давать user-friendly reject (а не молчаливый фриз/десинк).

8. Минимизировать прямые зависимости UI <-> network.
- UI должен реагировать на события state-модели, а не инициировать сетевые переходы напрямую в нескольких местах.
- Это снижает race condition при смене сцены.

## Системные нюансы проекта (критично не забыть)

1. `game/` используется как источник и не редактируется.

2. Проект чувствителен к lifecycle Godot (inside tree / outside tree).
- Вызовы вида `get_node("/root/...")`, `get_tree()`, `grab_focus()` вне корректного момента дают ошибки и подвесы.

3. Script extension может ломаться от двойных connect.
- На практике уже ловили дубли сигналов (`already connected`) и фризы UI.
- Для extension-скриптов обязателен safe connect/disconnect.

4. Safe-bootstrap обязателен для контроля стабильности.
- Есть forced disabled path для проблемных extension.
- Любое новое extension сначала включать через rollout, потом расширять.

5. Resume-сессии привязаны к endpoint + token + session TTL.
- Не менять формат snapshot/session без версии и migration-плана.

6. Для стабильного запуска extension rollout должен быть полным.
- `compat.cfg` с `extension_rollout_count=8` отрезает часть `ui_*` и `singletons` extension.
- Результат: запускаются базовые скрипты без LAN safety-fallback (в т.ч. фокус/scene lifecycle), появляются ошибки типа `Focus emulator signal not triggered`.
- Текущий безопасный дефолт: `extension_rollout_count=-1` и миграция legacy-конфига при загрузке.

## Приоритет внедрения (практический)

### P0 (сначала)
- Ввести message envelope (`protocol_version/session_id/seq/tick`) для всех LAN-пакетов.
- Развести типы сообщений на reliable и unreliable(ordered).
- Добавить handshake-совместимость версии протокола.

### P1
- Ввести state machine переходов сцен с ack.
- Добавить интерполяционный буфер на клиенте для частых update-потоков.
- Ввести пороговое сжатие (не gzip-ить мелкие пакеты).

### P2
- Добавить метрики сети в лог (packet size, resend, jitter, RTT p50/p95).
- Добавить crash-safe flush на ключевых фазах (shop start/end, wave start/end, scene commit).

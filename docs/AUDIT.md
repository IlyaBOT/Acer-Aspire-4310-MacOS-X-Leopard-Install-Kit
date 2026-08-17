# Аудит исходного проекта

Дата аудита: 2026-08-18. До изменений выполнены `pwd`, оба заданных `find`, поиск всех
shell-скриптов, `git status` и `git diff`. Найден один 1032-строчный shell script, README и
пустые рабочие каталоги. EFI, Extra, kext bundles, архивы, retail images и логи в project tree
отсутствовали. Единственным незакоммиченным изменением был executable-bit старого скрипта;
он сохранён.

Перед рефакторингом был создан локальный safety backup; после завершения и проверки он удалён
как воспроизводимая копия файлов, уже сохранённых в Git history. Работа ведётся в ветке
`refactor/aspire4310-legacy-macos` без reset/force.

## Что в старом коде было полезно

- `set -Eeuo pipefail`, quoting путей и cleanup смонтированного образа;
- retail source прикреплялся read-only;
- точное подтверждение `ERASE /dev/diskX`;
- `asr imagescan` как контролируемый retry;
- отсутствие пиратской автоматической загрузки retail image;
- отдельные Chameleon `boot0`/`boot1h`/`boot` и базовые знания о MacBook2,1/i386.

## Критические проблемы

- Архитектура была Chameleon-only, MBR-only и Leopard-only; OpenCore/OpenDuet отсутствовал.
- `http://chameleon.osx86.hu/...` — мёртвый/непроверяемый binary URL.
- `Legacy-Kexts` скачивался с moving `master` без commit pin, SHA-256 и manifest.
- Существующий непустой download принимался без проверки source/hash.
- FakeSMC, NullCPUPM, PS/2, restart, audio и battery слепо смешивались в первый boot set.
- Ни один kext executable не проверялся через `file`/`lipo`; x86_64-only и minimum OS не
  отсекались.
- External-disk guard использовал логическое «хотя бы один признак USB/external/removable» и
  не делал строгий запрет по `Internal: Yes`.
- Не было универсальной защиты объявленных пользователем томов и проверки всех slices
  выбранного whole disk.
- `asr --erase` выполнялся по mount point, а дальнейший код полагался на фиксированные slices
  и имена.
- Опасный генератор установки Chameleon на HDD принимал независимо заданные disk/slice/target;
  их принадлежность одному физическому диску не доказывалась.
- Host detection сводился к `uname -s`, поэтому Monterey Intel не классифицировался и не
  диагностировался полноценно.

## Подключённая флешка

В первоначальной удалённой среде выполнения Codex каталога `/Volumes` не было, поэтому тома
локального Mac фактически были недоступны. Никакая запись, mount или unmount не выполнялись.
Новый read-only audit проверяет boot markers, EFI tree, config plist и названия installer
images командой с явно переданным путём:

```bash
./prepare_aspire4310_macos.sh --audit --volume "/Volumes/BOOT"
```

Названия пользовательских томов намеренно не фиксируются в коде или документации.

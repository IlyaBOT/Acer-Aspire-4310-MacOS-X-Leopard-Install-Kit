# Broadcom BCM5787M

Ethernet имеет высокий post-install приоритет, но физический PCI ID ещё неизвестен.
Исторические кандидаты — patched `AppleBCM5751Ethernet.kext`, BCM57xx patches и старые
ревизии BCM5722D. Ни один binary пока не включён, потому что современная версия может иметь
слишком новый deployment target, отсутствующий i386 slice или чужой device match.

Статус: `POST_INSTALL_UNRESOLVED / RUNTIME_NOT_TESTED`.

Следующее действие — получить `lspci -nnk` с ноутбука, затем отдельно проверить source/tag,
Info.plist match, Mach-O i386 и Darwin 9 dependencies. Отсутствие Ethernet не блокирует
installer build.

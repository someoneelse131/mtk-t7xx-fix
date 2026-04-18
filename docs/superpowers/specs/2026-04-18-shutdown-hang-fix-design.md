# Shutdown-Hang Fix — Design

## Problem

`poweroff` / `reboot` bleibt im Kernel hängen, nachdem systemd-shutdown das
Journal sauber gestoppt hat.  Die Maschine bleibt unter Strom, bis der User
hart abschaltet.

### Beobachtete Signatur (Nacht 2026-04-17 → 2026-04-18)

```
23:38:11  [PM] Resume: L3/INIT detected (prev_state=2), reprobe attempt 1/3
23:38:11  wwan wwan0: port wwan0at0/mbim0 disconnected → re-attached
23:38:34  [PM] SAP suspend timeout, continuing anyway
23:39:13  [PM] Resume: handshake path
23:39:19  [PM] SAP resume timeout, continuing anyway
  <49 min ohne PM-Aktivität — Modem-SAP desynchronisiert>
00:28:23  Logout + poweroff
00:28:27  Stopping ModemManager.service
00:28:27  mtk_t7xx: Failed to send skb: -512 / Write error on AT port, -512
00:28:33.093  ModemManager.service: State 'stop-sigterm' timed out. Aborting.
00:28:33.094  Killing process 134682 (ModemManager) with signal SIGABRT
00:28:33.116  Main process exited, code=dumped, status=6/ABRT
00:28:33.307  Reached target poweroff.target
00:28:33.386  systemd-shutdown[1]: Syncing filesystems and block devices.
00:28:33.427  systemd-shutdown[1]: Sending SIGTERM to remaining processes...
00:28:33.428  systemd-journald: Journal stopped
  <Kernel-Phase wedge — User muss hart resetten>
```

pstore nach Recovery leer — kein Oops/Panic, sondern stiller Busy-/Wait-Hang.

### Root Cause

Der .shutdown-Pfad in `src/t7xx_pci.c:818`:

```c
static void t7xx_pci_shutdown(struct pci_dev *pdev)
{
    __t7xx_pci_pm_suspend(pdev);
    t7xx_md_exit(pci_get_drvdata(pdev));
}
```

läuft den vollen Suspend-Handshake-Pfad (`t7xx_wait_pm_config`,
`entity->suspend`, `H2D_CH_SUSPEND_REQ`, `H2D_CH_SUSPEND_REQ_AP`, FSM
`FSM_CMD_PRE_STOP`) unabhängig davon, ob das Modem noch gesund ist.
Im beobachteten Fall war das Modem-SAP seit 23:39:19 desynchronisiert
(`SAP resume timeout, continuing anyway`); der Shutdown-Handshake auf
einem halbtoten Modem wedget den Kernel in `device_shutdown`.

Der letzte Shutdown-Fix `c52a9aa` (2026-03-02) adressierte einen anderen
konkreten Hang (TX-Thread-Loop "UL add is not ready") durch Hinzufügen
von `t7xx_md_exit`.  Der neuere Hibernate-Fix `5305cb5` (2026-04-17)
führte das Muster "Modem ist kaputt → Mode=UNKNOWN → Handshake
überspringen" für den Resume-Pfad ein.  Der Shutdown-Pfad hat diese
Absicherung bisher nicht.

## Fix

Mode auf `T7XX_UNKNOWN` setzen, bevor `__t7xx_pci_pm_suspend` und
`t7xx_md_exit` laufen.  Die existierenden Early-Return-Guards in beiden
Funktionen übernehmen dann:

- `__t7xx_pci_pm_suspend` (`src/t7xx_pci.c:430–434`):
  `if (... mode != T7XX_READY) return 0` → voller Handshake entfällt.
- `t7xx_md_exit` (`src/t7xx_modem_ops.c:809–810`):
  `if (mode != T7XX_RESET && mode != T7XX_UNKNOWN) t7xx_fsm_append_cmd(... FSM_CMD_PRE_STOP ...)`
  → `FSM_CMD_PRE_STOP` (mit eigenem `WAIT_FOR_COMPLETION`) entfällt.

Nur der lokale Cleanup (`t7xx_port_proxy_uninit`, `t7xx_cldma_exit` ×2
(TX-Thread-Stop via `t7xx_dpmaif_tx_thread_rel` bleibt erhalten),
`t7xx_ccmni_exit`, `t7xx_fsm_uninit`, `destroy_workqueue(handshake_wq)`)
läuft.  Dieser Cleanup redet nicht mit dem Modem;
`t7xx_cldma_stop` benutzt `read_poll_timeout` mit
`CHECK_Q_STOP_TIMEOUT_US = 1 000 000` (1 s).

### Doppelabsicherung: system_state-Check

`system_state` wird vom Kernel auf `SYSTEM_POWER_OFF`, `SYSTEM_RESTART`
oder `SYSTEM_HALT` gesetzt, bevor `device_shutdown()` läuft.  In diesen
Zuständen ist der Strom in Kürze weg und ein sauberer Modem-Handshake
hat keinen Konsumenten.  Wir setzen `T7XX_UNKNOWN` nur, wenn
`system_state` einer dieser drei Werte ist — Defense-in-Depth gegen
zukünftige Kernel-Änderungen, die `.shutdown` in anderen Kontexten
aufrufen könnten.  Fällt der Check durch (sollte heute nie passieren),
bleibt das Alt-Verhalten erhalten.

### Patch (konzeptuell)

```c
static void t7xx_pci_shutdown(struct pci_dev *pdev)
{
    struct t7xx_pci_dev *t7xx_dev = pci_get_drvdata(pdev);

    if (system_state == SYSTEM_POWER_OFF ||
        system_state == SYSTEM_RESTART ||
        system_state == SYSTEM_HALT)
        t7xx_mode_update(t7xx_dev, T7XX_UNKNOWN);

    __t7xx_pci_pm_suspend(pdev);
    t7xx_md_exit(t7xx_dev);
}
```

Kommentar im Code erklärt die Motivation und verweist auf den
5305cb5-Präzedenzfall.

## Scope-Abgrenzung

Nicht adressiert in diesem Fix:

- Die Ursache des ursprünglichen SAP-Timeouts (23:38/23:39).  Die
  Modem-Firmware schleicht sich gelegentlich in einen Zustand, in dem
  der SAP-Handshake nicht mehr antwortet.  Das ist ein eigener Bug und
  wird hier als gegebene Umwelt-Bedingung behandelt.
- Ein möglicher `system-shutdown`-Hook (analog zu den
  `system-sleep`-Hooks aus 8f7fc91), der ModemManager vor dem Shutdown
  stoppt.  Wäre zusätzlich nützlich, ersetzt aber nicht den
  Kernel-seitigen Fix — ModemManager-SIGABRT ist hier Symptom, nicht
  Ursache.

## Verifikation

1. **Build:** `./reinstall.sh` (DKMS baut das Modul und lädt es neu).
2. **Code-Review durch Agenten** (getrennter Schritt nach Commit).
3. **Funktionaler Smoke-Test:**
   - Normaler Poweroff im gesunden Modem-Zustand: muss weiterhin
     vollständig durchlaufen, keine neuen Warnings im Journal.
   - Der "broken SAP"-Fall ist on-demand nicht zuverlässig zu
     reproduzieren; die Code-Logik ist mechanisch äquivalent zum
     bereits funktionierenden 5305cb5-Guard, also keine neue
     Reproduktion erforderlich.

## Commit-Message

Struktur analog zu 5305cb5: Problem-Signatur aus den Logs der Nacht
17./18. April, Begründung des Fix-Ansatzes, explizite Abgrenzung zum
bestehenden `c52a9aa`-Fix, Hinweis auf Spiegelung von `5305cb5`.

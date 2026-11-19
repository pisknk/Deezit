#pragma once

// How the user reaches Deezit's pages, from anywhere in Deezer:
//   three-finger hold        -> settings (temporary; a button on Deezer's own
//                               Settings / player comes later, see docs/ANALYSIS.md)
//   three-finger double tap  -> debug panel (status + live log + kill switch)
void DZSettingsEntryInstall(void);
void DZPresentSettings(void);
void DZPresentDebug(void);

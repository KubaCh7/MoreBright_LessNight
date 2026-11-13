<p align="center">
  <a href="https://github.com/KubaCh7/MoreBright_LessNight/releases/latest/download/MoreBrightLessNight.dmg">
    <img alt="Pobierz na macOS (DMG)" src="https://img.shields.io/badge/Pobierz_na_macOS-DMG-0071e3?style=for-the-badge&logo=apple&logoColor=white" height="44">
  </a>
  <br>
  <sub>macOS 14+ · Apple Silicon · <a href="https://github.com/KubaCh7/MoreBright_LessNight/releases/latest">informacje o wersji</a></sub>
</p>

# MoreBrightLessNight

Aplikacja menu bar na macOS 14+ (Apple Silicon), która podnosi jasność SDR ponad systemowe maksimum (ok. 500 nitów) do jasności utrzymywalnej panelu XDR (ok. 1000 nitów), opcjonalnie do szczytowej (1600 nitów).

## Jak to działa

- Dla każdego ekranu z `maximumPotentialExtendedDynamicRangeColorComponentValue > 1` powstaje pełnoekranowe, przezroczyste okno (`OverlayWindow`) na poziomie `CGShieldingWindowLevel`, click-through, bez fokusu, poza Mission Control i Cmd+Tab, wykluczone z nagrywania ekranu.
- W oknie siedzi `CAMetalLayer` (`rgba16Float`, extended linear sRGB, `wantsExtendedDynamicRangeContent`) wypełniony jedną wartością `m > 1.0`, z `compositingFilter = "multiply"`. WindowServer liczy `piksel × m` osobno dla R, G i B. To czyste liniowe wzmocnienie: bez gammy, bez zmiany white pointa, bez tintu. True Tone, Night Shift i profil ICC zostają nietknięte.
- **macOS daje zapas EDR tylko warstwie, która ciągle prezentuje klatki.** Statyczna warstwa traci headroom w około sekundę i boost spada do 1×. Dlatego podczas boostu overlay prezentuje klatkę 1×1 (sam clear) 5 razy na sekundę, na osobnej kolejce, nigdy na main thread. Tak samo robi BrightIntosh, a BetterDisplay nazywa to „continuous EDR enforcement”. Zmiany idą rampą 200 ms (ease-out). Przy `m = 1` okno znika, a pętla staje.
- Wzmocnienie = `min(żądanie, bieżący headroom)`. macOS podnosi headroom stopniowo, więc aplikacja przez pierwsze 30 s czyta go z częstotliwością 10 Hz, potem 2 Hz, i płynnie za nim podąża. Dopóki headroom < 1,05, renderuje 1,12×, żeby „obudzić” EDR. Gdy po wybudzeniu macOS uparcie zgłasza 1,0, używa wartości potencjalnej.

### Tryby i suwak

Wybór w popoverze: **Standard / 1000 nit / 1600 nit**. Zasada: **100% jasności macOS = 100% wybranego maksimum.**

- Suwak i klawisze F1/F2 to zwykła jasność macOS 0–100% (`DisplayServicesSetBrightness`, zapis tylko przy ruchu suwakiem).
- W trybie 1000 lub 1600 nakładka mnoży cały obraz przez stały czynnik `maks. nity / 500` (×2 lub ×3,2, nigdy powyżej headroomu). macOS 100% daje więc 1000 albo 1600 nitów, a każdy niższy poziom skaluje się proporcjonalnie.
- Klawisze jasności, auto-jasność i Centrum sterowania działają natywnie. Aplikacja niczego nie zapisuje z powrotem i nie przechwytuje klawiszy.
- Tryb 1600 przy pierwszym włączeniu wymaga potwierdzenia. Gdy Mac się nagrzeje (`.fair`), sam schodzi do 1000.

### Zero ingerencji (Vorsaint)

- Brak własnego HUD/OSD/toastu. Jedyny UI to popover i okno Ustawień.
- Brak `CGEventTap`, `IOHIDManager` i jakiejkolwiek obsługi F1/F2/F10-F12 i klawiszy multimedialnych. Skrót globalny to Carbon `RegisterEventHotKey`, który dostaje wyłącznie własną kombinację (domyślnie ⌃⌥⌘B).
- Zero CoreAudio i zero głośności.
- Jasność czytana pasywnie: callback `DisplayServicesRegisterForBrightnessChangeNotifications` plus odczyt kontrolny 1 Hz (2 Hz tylko, gdy callback jest niedostępny). Nigdy nie ma zapisu zwrotnego. Suwak po prostu podąża za systemem.

### Bezpieczeństwo

- Overlay wyłącza się przy `thermalState >= .serious`, na baterii poniżej 20%, przy uśpieniu ekranu lub systemu, blokadzie ekranu, wygaszaczu, przełączeniu użytkownika i podłączeniu lub odłączeniu ekranu, oraz (opcjonalnie) na baterii w ogóle. Po ustąpieniu przyczyny wraca po 5 s, żeby macOS zdążył odbudować EDR.
- Tryb 1600 wyłącza się sam (trwale) od `.fair` w górę. Pierwsze włączenie wymaga potwierdzenia w dialogu.
- Overlay to zwykłe okno procesu. Crash albo kill = okno znika. Aplikacja nie zmienia na stałe niczego poza zwykłą jasnością systemu, którą ustawia użytkownik.

### Test kolorów

Popover → **Test kolorów…**: 12 próbek (R, G, B, C, M, Y, trzy szarości, biel, dwie karnacje). **Zmierz** robi dwa zrzuty przez ScreenCaptureKit (overlay na chwilę wyłączony, potem włączony), dla każdej próbki liczy realne wzmocnienie luminancji i CIEDE2000 po wyrównaniu luminancji, czyli wyłącznie przesunięcie odcienia/nasycenia. Próbki, które nie osiągnęły oczekiwanego wzmocnienia, są oznaczone jako przycięte. Wymaga uprawnienia Nagrywanie ekranu.

## Pobieranie

Najnowszy DMG: [Releases](https://github.com/KubaCh7/MoreBright_LessNight/releases/latest). Otwórz DMG i przeciągnij aplikację do folderu **Aplikacje**.

Aplikacja nie ma podpisu Apple Developer ID ani notaryzacji, więc przy pierwszym uruchomieniu macOS ją zablokuje. Otwórz **Ustawienia systemowe → Prywatność i ochrona → Otwórz mimo to** albo wpisz:

```bash
xattr -dr com.apple.quarantine /Applications/MoreBrightLessNight.app
```

## Aktualizacje

- Aplikacja raz na dobę (15 s po starcie, potem co godzinę sprawdza, czy minęła doba) pyta `api.github.com` o najnowsze wydanie. Wyłączysz to w Ustawienia → Ogólne → Aktualizacje. Tam jest też „Sprawdź teraz”.
- Gdy jest nowsza wersja, popover pokazuje „Zainstaluj”. Instalacja: pobranie DMG, porównanie SHA-256 z plikiem `.sha256` z tego samego wydania, montowanie, sprawdzenie bundle ID i `codesign --verify --strict`, a po zamknięciu aplikacji podmiana bundla (z rollbackiem przy błędzie) i ponowne uruchomienie.
- Działa tylko, gdy aplikacja leży w zapisywalnym folderze (np. /Applications). Z App Translocation (uruchomienie prosto z DMG) aplikacja poprosi o przeniesienie.

### Wydawanie nowej wersji

```bash
git tag v0.2.0
```

```bash
git push origin v0.2.0
```

Workflow `.github/workflows/release.yml` zbuduje aplikację z `MARKETING_VERSION` wziętym z tagu, zrobi `MoreBrightLessNight.dmg` i `MoreBrightLessNight.dmg.sha256` (stała nazwa, więc przycisk na górze README zawsze wskazuje najnowszą wersję) i opublikuje GitHub Release. Można też uruchomić go ręcznie (Actions → Release → Run workflow).

## Diagnostyka

Ustawienia → Ekrany pokazują bieżący headroom, żądane i zastosowane wzmocnienie oraz wiek ostatniej klatki overlayu (powinien być < 300 ms). Logi:

```bash
log stream --predicate 'subsystem == "app.morebrightlessnight"' --level debug
```

## Budowanie

Wymagania: macOS 14+, Xcode 16+ (projekt używa folderów synchronizowanych, `objectVersion 77`), Apple Silicon. Brak zewnętrznych zależności.

```bash
git clone <repo> && cd MoreBright_LessNight
```

```bash
open MoreBrightLessNight.xcodeproj
```

albo z terminala:

```bash
xcodebuild -project MoreBrightLessNight.xcodeproj -scheme MoreBrightLessNight -configuration Release -derivedDataPath build build
```

```bash
open build/Build/Products/Release/MoreBrightLessNight.app
```

Podpis jest ad-hoc (`CODE_SIGN_IDENTITY = -`). Do dystrybucji ustaw własny Team w Signing & Capabilities. Aplikacja nie jest sandboxowana, bo korzysta z prywatnego `DisplayServices.framework` (ładowanego przez `dlopen`, bez linkowania).

CI (`.github/workflows/build.yml`) buduje projekt na `macos-15` przy każdym pushu.

## Znane ograniczenia

1. **Nietestowane na realnym ekranie.** Kod powstał bez dostępu do Maca. CI potwierdza tylko kompilację. Overlay, sync z F1/F2 i test kolorów trzeba sprawdzić ręcznie na MacBooku Pro XDR.
2. **Prywatne API.** `DisplayServices` i filtr `"multiply"` nie są publiczne. Apple może je zmienić w dowolnej aktualizacji. Bez App Store.
3. **Nity to model, nie pomiar.** 500/1000/1600 to domyślny profil MacBooka Pro XDR (edytowalny w Zaawansowanych). Realną jasność decyduje macOS i ABL panelu: przy dużej powierzchni bieli 1600 nitów pełnoekranowo nie wystąpi, system przytnie do ok. 1000. Wtedy aplikacja pokaże „highlights clipped”, bo czyta bieżący headroom.
4. **Headroom rośnie z opóźnieniem.** macOS podnosi `maximumExtendedDynamicRangeColorComponentValue` dopiero po pojawieniu się treści EDR (do kilku sekund). Ostrzeżenie o clippingu pojawia się po 1,5 s stabilizacji i może chwilę mrugnąć na starcie.
5. **Skalowany jest cały zakres.** W trybie 1600 najniższe poziomy jasności są ~3× jaśniejsze niż w trybie Standard. Do ciemnych warunków przełącz na Standard (skrót ⌃⌥⌘B).
6. **Chwilowe spadki headroomu** (Cmd+Tab, przełączanie biurek, Mission Control) są przeczekiwane do 3 s. Dopiero dłuższy spadek obniża wzmocnienie. Jeśli spadek robi sam macOS, krótkie przyciemnienie wciąż może być widoczne, bo kompozytor obcina obraz do realnego headroomu.
7. **Zmiana jasności suwakiem to prawdziwa zmiana jasności macOS**, więc Vorsaint może pokazać swoją animację. To jego reakcja, nie nasz HUD.
8. **Koszt energii.** Overlay prezentuje 5 klatek/s (1×1 piksel, pomijalne dla GPU), WindowServer komponuje multiply na całym ekranie, a panel świeci mocniej. Bateria schodzi wyraźnie szybciej.
9. **Test ΔE zależy od ScreenCaptureKit.** Na macOS 14 SCK zwykle zwraca SDR (wartości przycięte do 1.0), więc pomiar nie zobaczy boostu i UI to jawnie zgłosi. Na macOS 15+ używany jest `captureDynamicRange = .hdrLocalDisplay`. ΔE liczone jest przy założeniu prymarów sRGB w zrzucie. Jeśli system odda linear P3, wartości ΔE będą lekko przesunięte, ale „0 = brak przesunięcia” nadal obowiązuje.
10. **Ekrany zewnętrzne.** Ekrany bez EDR są oznaczone jako niewspierane. Zewnętrzne ekrany z EDR, które nie obsługują `DisplayServices`, mają suwak sterujący siłą overlayu (0% = bez podbicia, 100% = wybrane maksimum).
11. **Suwak w stylu Centrum sterowania jest własnym widokiem**, bo natywny `Slider` nie ma tego wyglądu. Dla VoiceOver i klawiatury ma `accessibilityRepresentation` w postaci standardowego `Slider` oraz obsługę strzałek.
12. **Aktualizacje bez Developer ID.** Weryfikacja opiera się na HTTPS do GitHuba i SHA-256 z tego samego wydania. Chroni to przed uszkodzonym pobraniem, ale nie przed kimś, kto przejmie repozytorium lub konto. Prawdziwa ochrona wymaga Developer ID i sprawdzania Team ID (albo Sparkle z kluczem EdDSA).
13. **Uprawnienie Nagrywanie ekranu znika po każdej aktualizacji**, bo przy podpisie ad-hoc macOS wiąże je z hashem binarki. Dotyczy tylko testu kolorów.
14. **Skrót globalny** to jedna z kilku gotowych kombinacji (⌃⌥⌘B / L / ↑). Brak nagrywarki dowolnego skrótu.

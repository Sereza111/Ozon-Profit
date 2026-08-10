# Flutter Shell

This directory contains the Windows Flutter desktop shell for the unified Chromium agent.

## Run

1. Install Flutter SDK and Visual Studio Desktop development with C++ on Windows.
2. From this folder:
   ```bash
   flutter create --platforms=windows .
   flutter pub get
   flutter run -d windows
   ```

## Backend

Run the Node backend first:
```bash
cd C:\Users\Yozik\projects\ozon-profit-bot
npm run serve
```

The shell launches the backend automatically, opens bundled Playwright Chromium, renders its screenshot stream, and sends mouse/keyboard input back to the same browser page.

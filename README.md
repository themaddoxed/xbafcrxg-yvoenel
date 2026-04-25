# GoPractice — зашифрованный сайт-конспект

Приватный сайт-библиотека с конспектами курса GoPractice, модули 1–9.1. Работает через GitHub Pages; HTML зашифрован staticrypt, пароль в `../SITE_PASSWORD.txt`.

## Что едет на GitHub, а что — нет

**Только шифротекст уходит в публичный репо.** Явно и по слоям:

| Путь в `gopractice_site/`    | Содержимое            | На GitHub? | Где      |
|------------------------------|-----------------------|------------|----------|
| `mkdocs.yml`                 | конфиг сборки         | да         | `main`   |
| `deploy.sh`                  | деплой-скрипт         | да         | `main`   |
| `README.md`                  | этот файл             | да         | `main`   |
| `.gitignore`                 | список исключений     | да         | `main`   |
| `docs/`                      | **исходный markdown** | **нет**    | локально |
| `build/`                     | plaintext сборка MkDocs| **нет**   | локально |
| `build_enc/`                 | зашифрованный HTML    | частично   | `gh-pages` (как orphan branch, без `main`-tree) |
| `../SITE_PASSWORD.txt`       | пароль                | **нет**    | локально |
| `*.docx`                     | word-копии            | **нет**    | локально |

`docs/` **никогда** не пушится. `.gitignore` исключает его явно, и `deploy.sh` имеет два guardrail'а, которые прерывают деплой если случайно что-то из `docs/`, `build_enc/`, `build/`, `SITE_PASSWORD.txt` или `.docx` попадёт в stage под `main`. Шифротекст (`build_enc/`) публикуется только в `gh-pages` через `ghp-import -p -f` — это orphan-бранч, он не наследует tree от `main`.

## Структура

- `docs/` — 19 конспектов + 19 полных версий + landing (`index.md`). **Не коммитится.**
- `mkdocs.yml` — Material theme (dark slate + тумблер, русский UI, search enabled + зашифрован через encrypt_search_index.js).
- `build_enc/` — готовая зашифрованная статика (~11 MB, 40 HTML). **Только в `gh-pages`.**
- `deploy.sh` — один скрипт: gh auth → `main` со scaffolding → `ghp-import` на `gh-pages` → enable Pages → дождаться 200.
- `.gitignore` — жёстко исключает всё с plaintext.

## Быстрый деплой

```bash
brew install gh                   # если не установлен
npm install -g staticrypt         # для пересборки из docs/
cd ~/Desktop/GoPractice/gopractice_site
chmod +x deploy.sh
./deploy.sh                       # создаст репо и задеплоит
# либо, если репо уже создан в браузере:
./deploy.sh --repo-exists
```

В конце напечатает URL.

## Про пароль и пересборку

**Используйте тот же пароль из `../SITE_PASSWORD.txt` на каждой пересборке.** Staticrypt кладёт PBKDF2-соль в `.staticrypt.json` и помнит её между запусками, но если вы смените пароль:

- у пользователей, которые поставили галку «Запомнить на 30 дней», sessionStorage-кэш перестанет подходить и форма логина попросит пароль заново;
- вся предыдущая гипер-ссылка вида `...#staticrypt_pwd=<hash>` (если кто-то ей делился) станет невалидной.

Если действительно нужно ротировать — перегенерируйте `SITE_PASSWORD.txt`, удалите `build_enc/` и `.staticrypt.json`, и запустите `deploy.sh` заново: получится свежий key-derivation, новый набор ciphertext, новый салт.

## Безопасность

- AES-256-GCM, PBKDF2 600 000 раундов (staticrypt 3.x по умолчанию), соль в `.staticrypt.json`.
- `plugins: [search]` + `encrypt_search_index.js` — `search_index.json` генерируется, шифруется, plaintext удаляется до публикации. Навигация через табы/боковое меню + поиск через `/`.
- `SITE_PASSWORD.txt` в `.gitignore`, не коммитится.
- Репо публичный (так задумано — контент зашифрован, Pages бесплатно поднимают сайт).
- `deploy.sh` имеет positive allow-list (на main разрешены только 4 scaffolding-файла) и negative leak-guard (abort если docs//build/*/.docx в stage).

## Пересборка вручную (без деплоя)

```bash
cd gopractice_site
python3 -m venv .venv && source .venv/bin/activate
pip install mkdocs mkdocs-material pymdown-extensions
mkdocs build --clean --site-dir build/           # plaintext в build/, НЕ пушится
PW=$(cat ../SITE_PASSWORD.txt)
staticrypt build/ -p "$PW" -r -d build_enc_tmp \
  --remember 30 --short \
  --template-button "Открыть" \
  --template-title "GoPractice — приватный архив" \
  --template-placeholder "Пароль"
rm -rf build_enc && mv build_enc_tmp/build build_enc && rm -rf build_enc_tmp
```

## Локальная проверка

```bash
python3 -m http.server -d build_enc 8765
open http://127.0.0.1:8765/
```

Ожидаемо: форма ввода пароля; ввод пароля из `../SITE_PASSWORD.txt` → страница расшифровывается; боковое меню показывает «Конспект» и «Полный курс»; урок 4.1 читается по-русски.

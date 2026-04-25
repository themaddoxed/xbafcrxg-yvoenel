#!/usr/bin/env bash
# Deploy the password-gated GoPractice site to GitHub Pages.
#
# Prereqs on this Mac:
#   - gh CLI              (brew install gh)
#   - python3 + pip
#   - staticrypt (optional, for rebuild):  npm install -g staticrypt
#   - network access to github.com
#
# Usage:
#   cd ~/Desktop/GoPractice/gopractice_site
#   ./deploy.sh                    # creates the public repo if missing, then deploys
#   ./deploy.sh --repo-exists      # repo was pre-created in browser; skip gh repo create
#
# Re-run safe.  Invariant: NOTHING from docs/ or build_enc/ ever lands in the
# main branch on github.com.  Only encrypted HTML (build_enc/) is pushed, and it
# goes to gh-pages via ghp-import.

set -euo pipefail

REPO_NAME="xbafcrxg-yvoenel"   # ROT13 of "konspekt-library"
REPO_DESC="private notes"

REPO_EXISTS=0
for arg in "$@"; do
  case "$arg" in
    --repo-exists) REPO_EXISTS=1 ;;
    -h|--help)
      sed -n '1,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 64 ;;
  esac
done

cd "$(dirname "$0")"

# --- 0. sanity ------------------------------------------------------------
command -v gh      >/dev/null || { echo "install gh:    brew install gh";   exit 1; }
command -v git     >/dev/null || { echo "git missing";                      exit 1; }
command -v python3 >/dev/null || { echo "python3 missing";                  exit 1; }
[[ -f ../SITE_PASSWORD.txt ]] || { echo "../SITE_PASSWORD.txt missing";     exit 1; }

# --- 1. GitHub auth -------------------------------------------------------
if ! gh auth status >/dev/null 2>&1; then
  echo ">> gh not authenticated. Launching device-code login..."
  gh auth login -w -h github.com -p https
fi
OWNER=$(gh api user -q .login)
echo ">> authenticated as: $OWNER"

# --- 2. Python deps for ghp-import ---------------------------------------
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet mkdocs mkdocs-material pymdown-extensions ghp-import

# --- 3. (re)build the encrypted site -------------------------------------
# Source markdown sits under docs/.  Mkdocs builds to build/ (plaintext, local
# only), then staticrypt encrypts into build_enc/ which is the ONLY thing that
# ever leaves this machine — to gh-pages, as ciphertext.
#
# Important: same SITE_PASSWORD.txt on every rebuild so the PBKDF2 salt and the
# client-side sessionStorage "Remember me" cache stay compatible.  Rotating the
# password invalidates every user's saved-login cookie.
if ! command -v staticrypt >/dev/null 2>&1; then
  echo ">> staticrypt missing. Install with:  npm install -g staticrypt"
  echo "   Skipping rebuild; using pre-built build_enc/ from the archive."
else
  echo ">> rebuilding site from docs/ ..."
  mkdocs build --clean --site-dir build/
  PW=$(cat ../SITE_PASSWORD.txt)
  rm -rf build_enc_tmp build_enc_new
  staticrypt build/ -p "$PW" -r \
    -d build_enc_tmp \
    --remember 30 --short \
    --template-button "Открыть" \
    --template-title "GoPractice — приватный архив" \
    --template-instructions "Введите пароль. Доступ только по приглашению." \
    --template-placeholder "Пароль" \
    --template-error "Неверный пароль" \
    --template-remember "Запомнить на 30 дней" \
    --template-color-primary "#5e81ac" \
    --template-color-secondary "#2e3440"
  # staticrypt nests under its own build/ — flatten
  mv build_enc_tmp/build build_enc_new
  rm -rf build_enc_tmp build_enc
  mv build_enc_new build_enc

  # Encrypt search_index.json using the same KDF as staticrypt pages, then
  # delete the plaintext. Required so the guardrail below passes.
  if command -v node >/dev/null 2>&1 && [[ -f encrypt_search_index.js ]]; then
    echo ">> encrypting search index ..."
    NPM_GLOBAL_PREFIX="$(npm root -g | sed 's|/lib/node_modules||')" \
      SITE_PASSWORD="$PW" \
      node encrypt_search_index.js build_enc
  else
    echo "!! node or encrypt_search_index.js missing — search index not encrypted"
  fi
fi

[[ -d build_enc ]] || { echo "no build_enc/ — aborting"; exit 1; }
HTML_COUNT=$(find build_enc -name "*.html" | wc -l | tr -d ' ')
echo ">> build_enc/ ready, $HTML_COUNT html files"

# --- 3a. ciphertext guardrails (every HTML staticrypt, no plaintext index) --
if find build_enc -name "*.html" | xargs grep -L "staticrypt-html" 2>/dev/null | grep -q .; then
  echo "!! unencrypted HTML detected in build_enc/ — aborting"
  find build_enc -name "*.html" | xargs grep -L "staticrypt-html"
  exit 2
fi
if find build_enc -name "search_index.json" | grep -q .; then
  echo "!! plaintext search_index.json found in build_enc/ — aborting"
  find build_enc -name "search_index.json"
  exit 3
fi

# --- 4. source repo (main branch) ----------------------------------------
# main MUST be scaffolding only: mkdocs.yml + deploy.sh + README.md + .gitignore.
# docs/ and build_enc/ are gitignored and must never be staged.
if [[ ! -d .git ]]; then
  git init -q -b main
fi

# Re-sync .gitignore defensively (covers the case where the user edits files).
if ! grep -q '^docs/$'      .gitignore 2>/dev/null; then echo 'docs/'      >> .gitignore; fi
if ! grep -q '^build_enc/$' .gitignore 2>/dev/null; then echo 'build_enc/' >> .gitignore; fi
if ! grep -q '^build/$'     .gitignore 2>/dev/null; then echo 'build/'     >> .gitignore; fi

# Stage ONLY the four scaffolding files. Never `git add .` or `git add docs/`.
git rm --cached -r --ignore-unmatch docs/ build_enc/ build/ >/dev/null 2>&1 || true
git add .gitignore mkdocs.yml deploy.sh README.md

# --- 4a. pre-push guardrail: no docs/ or build_enc/ may be staged ---------
# Only inspect added / copied / modified / renamed entries — deletions are fine
# (e.g. our own `git rm --cached docs/` from step 4 above).
STAGED=$(git diff --cached --name-only --diff-filter=ACMR)
LEAK=$(printf '%s\n' "$STAGED" | awk '/^docs\//        { print "docs: "       $0 }
                                       /^build_enc\//   { print "build_enc: "  $0 }
                                       /^build\//       { print "build: "      $0 }
                                       /SITE_PASSWORD/  { print "password: "   $0 }
                                       /\.docx$/        { print "docx: "       $0 }')
if [[ -n "$LEAK" ]]; then
  echo "!! LEAK GUARD: the following plaintext/binary files are staged for main:"
  printf '%s\n' "$LEAK"
  echo "   Refusing to commit.  Fix .gitignore / git rm --cached and re-run."
  exit 4
fi
# Positive check: staged set must be a subset of the 4 scaffolding files.
UNEXPECTED=$(printf '%s\n' "$STAGED" | grep -vE '^(\.gitignore|mkdocs\.yml|deploy\.sh|README\.md)$' || true)
if [[ -n "$UNEXPECTED" ]]; then
  echo "!! LEAK GUARD: unexpected file staged for main:"
  printf '%s\n' "$UNEXPECTED"
  echo "   Allowed on main: .gitignore, mkdocs.yml, deploy.sh, README.md"
  exit 5
fi

# Commit (or amend a no-op).  Use local identity if git config is empty.
if ! git log -1 >/dev/null 2>&1; then
  git -c user.email="$(git config user.email || echo $OWNER@users.noreply.github.com)" \
      -c user.name="$(git config user.name  || echo $OWNER)" \
      commit -q -m "Scaffolding only: mkdocs.yml + deploy.sh + README.md + .gitignore"
elif ! git diff --cached --quiet; then
  git -c user.email="$(git config user.email || echo $OWNER@users.noreply.github.com)" \
      -c user.name="$(git config user.name  || echo $OWNER)" \
      commit -q -m "Update scaffolding"
fi

# --- 5. create remote repo (or attach to pre-created one) ----------------
if [[ "$REPO_EXISTS" -eq 1 ]] || gh repo view "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
  echo ">> repo $OWNER/$REPO_NAME already exists — pushing main"
  if ! git remote | grep -q '^origin$'; then
    git remote add origin "https://github.com/$OWNER/$REPO_NAME.git"
  fi
  git push -u origin main
else
  echo ">> creating public repo $OWNER/$REPO_NAME ..."
  gh repo create "$REPO_NAME" --public \
    --description "$REPO_DESC" \
    --disable-issues --disable-wiki \
    --source=. --remote=origin --push
fi

# --- 6. deploy encrypted build to gh-pages -------------------------------
# ghp-import writes gh-pages as an orphan branch containing ONLY build_enc/'s
# contents — it does not inherit main's tree.  So docs/ cannot leak here either.
echo ">> publishing build_enc/ → gh-pages ..."
ghp-import -p -f -b gh-pages -m "Deploy encrypted site" build_enc

# --- 7. enable Pages (gh-pages branch, / root) ---------------------------
if ! gh api "repos/$OWNER/$REPO_NAME/pages" >/dev/null 2>&1; then
  echo ">> enabling Pages ..."
  gh api -X POST "repos/$OWNER/$REPO_NAME/pages" \
    -f "source[branch]=gh-pages" \
    -f "source[path]=/" >/dev/null
else
  gh api -X PUT "repos/$OWNER/$REPO_NAME/pages" \
    -f "source[branch]=gh-pages" \
    -f "source[path]=/" >/dev/null || true
fi

# --- 8. poll until live ---------------------------------------------------
URL="https://$OWNER.github.io/$REPO_NAME/"
echo ">> waiting for Pages to build (max 3 min) ..."
for i in {1..18}; do
  STATUS=$(gh api "repos/$OWNER/$REPO_NAME/pages/builds/latest" -q .status 2>/dev/null || echo pending)
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$URL" || echo 000)
  echo "   t+${i}0s  pages_status=$STATUS  http=$CODE"
  if [[ "$CODE" == "200" ]]; then break; fi
  sleep 10
done

echo
echo "=============================================="
echo "DONE. Site URL:  $URL"
echo "Password file:   ../SITE_PASSWORD.txt"
echo "=============================================="

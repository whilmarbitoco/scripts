#!/usr/bin/env bash

set -e

echo "Angular → GitHub Pages Workflow Generator"
echo "--------------------------------------------"

# === INPUTS ===
read -p "Angular project name (default: app): " APP_NAME
APP_NAME=${APP_NAME:-app}

read -p "Branch to trigger deployment (default: main): " BRANCH
BRANCH=${BRANCH:-main}

read -p "Output directory (default: dist/app): " OUTPUT_DIR
OUTPUT_DIR=${OUTPUT_DIR:-dist/app}

read -p "Base href (e.g. /skywalker/): " BASE_HREF

if [[ -z "$BASE_HREF" ]]; then
  echo "Base href is required (e.g. /skywalker/)"
  exit 1
fi

read -p "GitHub repo (username/repo): " REPO

if [[ -z "$REPO" ]]; then
  echo "Repository is required"
  exit 1
fi

read -p "GitHub token secret name (default: GH_PAT): " TOKEN
TOKEN=${TOKEN:-GH_PAT}

# === CONFIRMATION ===
echo ""
echo "⚙️ Configuration:"
echo "Project:        $APP_NAME"
echo "Branch:         $BRANCH"
echo "Output Dir:     $OUTPUT_DIR"
echo "Base Href:      $BASE_HREF"
echo "Repo:           $REPO"
echo "Token Secret:   $TOKEN"
echo ""

read -p "Proceed? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
  echo "Cancelled."
  exit 0
fi

# === CREATE WORKFLOW DIR ===
mkdir -p .github/workflows

# === WRITE WORKFLOW FILE ===
WORKFLOW_FILE=".github/workflows/deploy.yml"

cat > $WORKFLOW_FILE <<EOF
name: Angular Deploy to GH Pages

on:
  push:
    branches:
      - $BRANCH

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v3

      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: 20

      - name: Install dependencies
        run: npm ci

      - name: Install Angular CLI
        run: npm install -g @angular/cli

      - name: Build Angular app
        run: npx ng build $APP_NAME --configuration production --output-path=$OUTPUT_DIR --base-href "$BASE_HREF"

      - name: Create 404.html fallback
        run: cp $OUTPUT_DIR/index.html $OUTPUT_DIR/404.html

      - name: Deploy to GitHub Pages
        uses: peaceiris/actions-gh-pages@v3
        with:
          personal_token: \${{ secrets.$TOKEN }}
          external_repository: $REPO
          publish_branch: gh-pages
          publish_dir: ./$OUTPUT_DIR
          force_orphan: true
EOF

echo ""
echo "Workflow created at: $WORKFLOW_FILE"

# === OPTIONAL: FIX angular.json ===
read -p "🔧 Do you want to auto-fix angular.json (remove SSR/server)? (y/n): " FIX_JSON

if [[ "$FIX_JSON" == "y" ]]; then
  if [[ -f angular.json ]]; then
    echo "🛠 Fixing angular.json..."

    # Remove problematic keys
    sed -i '/"server":/d' angular.json
    sed -i '/"ssr":/d' angular.json

    echo "angular.json cleaned (removed server + ssr)"
  else
    echo "angular.json not found, skipping"
  fi
fi

echo ""
echo "Done!"
echo ""
echo "Next steps:"
echo "1. Add your GitHub token as a secret: $TOKEN"
echo "2. git add . && git commit -m 'setup gh pages' && git push"
echo "3. Enable GitHub Pages → gh-pages branch (root)"
echo "4. Visit: https://$(echo $REPO | cut -d'/' -f1).github.io$BASE_HREF"
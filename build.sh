#!/usr/bin/env bash
set -e -x

BRANCH="$1"

# Delete everything from the previous build
git ls-tree --name-only -z HEAD | xargs -0 rm -rf

# Check out files from the source branch
git checkout "$BRANCH" .
git reset

# Build the website
bundle exec jekyll clean
bundle exec jekyll build

git add .gitignore
git clean -fd -e _site

find _site -maxdepth 1 -mindepth 1 -exec mv {} . \;
rm -rf _site

git add .

echo "Please inspect the built site, and commit/push to deploy"

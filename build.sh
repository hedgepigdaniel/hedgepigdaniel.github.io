#!/usr/bin/env bash

set -ex

bundle install
bundle exec jekyll clean
JEKYLL_ENV=production bundle exec jekyll build